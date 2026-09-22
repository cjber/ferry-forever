local _, ns = ...

-- Walking routes over a continent's collision map: HPA* between ADT-tile clusters, an 8 yd grid inside them,
-- then string-pulling so the drawn line is not jagged. Coordinates are UnitPosition's frame (x north, y west).
-- A cell holds its base surface and, where surfaces overlap (a tunnel under a mountain, a city under ruins, both
-- ends of a lift), floors above or below it. A node is a local cell (the base surface) or C * C + a floor's index.
local Path = {}
ns.Path = Path

Path.budget = 3 -- milliseconds of CPU per frame for Find
Path.clusters = 12 -- decoded cluster grids kept in memory (at least 4)
Path.clock = debugprofilestop or function()
	return os.clock() * 1000
end

local TILE = 1600 / 3
local SNAP = 6 -- cells searched around an off-grid endpoint
local ZTOL = 10 -- an endpoint stands on a surface within this height (yd)
local CHECK = 64 -- expansions between clock reads
local RETRIES = 8 -- other cells tried for an endpoint stuck in a pocket
local DROP = 30 -- how far below its surface a stuck endpoint may move: one can jump down a ledge, never climb one
local SQRT2 = math.sqrt(2)
local START, GOAL = -1, -2

local byte, floor, sqrt, huge, max, abs = string.byte, math.floor, math.sqrt, math.huge, math.max, math.abs
local concat, yield = table.concat, coroutine.yield

local B64 = {}
do
	local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i = 1, 64 do
		B64[byte(alphabet, i)] = i - 1
	end
end

local function num(s, i, width)
	local v = 0
	for j = i, i + width - 1 do
		v = v * 64 + B64[byte(s, j)]
	end
	return v
end

-- Slicing: tick() yields once the frame's deadline passes. Only one search runs at a time (see pump).
local deadline, ops, expansions = huge, 0, 0
local clock = function()
	return Path.clock()
end

local function tick()
	expansions = expansions + 1
	ops = ops + 1
	if ops >= CHECK then
		ops = 0
		if clock() > deadline then
			yield()
		end
	end
end

-- Binary min-heap on parallel arrays, reset per search.
local hk, hv, hn = {}, {}, 0

local function push(k, v)
	hn = hn + 1
	local i = hn
	while i > 1 do
		local p = floor(i / 2)
		if hk[p] <= k then
			break
		end
		hk[i], hv[i] = hk[p], hv[p]
		i = p
	end
	hk[i], hv[i] = k, v
end

local function pop()
	local top = hv[1]
	local k, v = hk[hn], hv[hn]
	hn = hn - 1
	local i = 1
	while true do
		local c = i * 2
		if c > hn then
			break
		end
		if c < hn and hk[c + 1] < hk[c] then
			c = c + 1
		end
		if hk[c] >= k then
			break
		end
		hk[i], hv[i] = hk[c], hv[c]
		i = c
	end
	hk[i], hv[i] = k, v
	return top
end

-- Collision maps ship as one load-on-demand addon per continent (ShortestPathForever_Nav<map>), so only players who
-- walk there pay for them. A separate addon cannot share `ns`, hence the global.
local tried = {}
local function Data(map)
	if not (ShortestPathForeverPathData and ShortestPathForeverPathData[map]) and not tried[map] and C_AddOns then
		tried[map] = true
		C_AddOns.LoadAddOn("ShortestPathForever_Nav" .. map)
	end
	return ShortestPathForeverPathData and ShortestPathForeverPathData[map]
end

-- Per-map state; clusters are decoded on first use.
local states = {}

local function State(map)
	local st = states[map]
	if st == nil then
		local D = Data(map)
		if not D then
			return nil
		end
		local C = D.cells
		st = {
			D = D,
			C = C,
			ny = D.ny,
			GX = D.nx * C,
			GY = D.ny * C,
			x0 = D.cx0 * TILE,
			y0 = D.cy0 * TILE,
			cs = TILE / C,
			swim = D.swim,
			zstep = D.zstep,
			used = {}, -- [k] = last use, for eviction
			decoded = 0,
			val = {}, -- [k] = node values (node + 1), false when the cluster has no data
			moves = {}, -- [k][lc + 1] = open moves inside the cluster + 16 * the data file's step flags
			z = {}, -- [k][node + 1] = height of a walkable node
			at = {}, -- [k][node + 1] = a floor's local cell; [k][-(lc + 1)] = the cell's first floor node
			links = {}, -- [k][node + 1] = { direction, layer, ... } steps besides the base grid's (layer -1: nearest)
			nodes = {}, -- [k] = entrance ids (k * 4096 + i)
			ncell = {}, -- [id] = local cell
			nlayer = {}, -- [id] = 0 for the base surface, i for the cell's ith floor
			ncomp = {},
			nadj = {},
		}
		states[map] = st
	end
	return st
end

-- Directions of floor links: +x, -x, +y, -y, +x+y, +x-y, -x+y, -x-y.
local DX = { [0] = 1, -1, 0, 0, 1, 1, -1, -1 }
local DY = { [0] = 0, 0, 1, -1, 1, -1, 1, -1 }
local OPPOSITE = { [0] = 1, 0, 3, 2, 7, 6, 5, 4 }
local DIRECTION = {} -- [(dx + 1) * 3 + dy + 1] = direction
for d = 0, 7 do
	DIRECTION[(DX[d] + 1) * 3 + DY[d] + 1] = d
end

-- The node on local cell lc for a link layer (0 the base surface, i the ith floor up, -1 the surface nearest
-- height h), with its height gap for -1. The cluster must be decoded.
local function surface(st, k, lc, layer, h)
	local val, z, at = st.val[k], st.z[k], st.at[k]
	local first = at[-(lc + 1)]
	if layer == 0 then
		return val[lc + 1] ~= 0 and lc or nil
	elseif layer > 0 then
		local node = first and first + layer - 1
		return node and at[node + 1] == lc and node or nil
	end
	local best, gap
	if val[lc + 1] ~= 0 then
		best, gap = lc, abs(z[lc + 1] - h)
	end
	local node = first
	while node and at[node + 1] == lc do
		if not gap or abs(z[node + 1] - h) < gap then
			best, gap = node, abs(z[node + 1] - h)
		end
		node = node + 1
	end
	return best, gap
end

local function addLink(links, node, d, layer)
	local l = links[node + 1]
	if not l then
		l = {}
		links[node + 1] = l
	end
	l[#l + 1], l[#l + 2] = d, layer
end

local function decodeHeights(st, k, val, z)
	local s, C, step = concat(st.D.height[k + 1]), st.C, st.zstep
	local q = {}
	local pos, rep, delta, last = 1, 0, 0, 0
	for i = 1, C * C do
		if val[i] ~= 0 then
			local a = i - 1
			local pred = (a % C > 0 and q[i - 1]) or (a >= C and q[i - C]) or last
			local v
			if rep > 0 then
				rep, v = rep - 1, pred + delta
			else
				local sym = B64[byte(s, pos)]
				if sym == 47 then
					v, pos = num(s, pos + 1, 2) - 2048, pos + 3
				else
					delta, pos = sym - 23, pos + 1
					while pos <= #s and B64[byte(s, pos)] >= 48 do
						rep, pos = rep + B64[byte(s, pos)] - 47, pos + 1
					end
					v = pred + delta
				end
			end
			q[i], last, z[i] = v, v, v * step
		end
	end
end

local function decodeFloors(st, k, val, z)
	local at, links = {}, {}
	st.at[k], st.links[k] = at, links
	local chunks = st.D.floor[k + 1]
	if not chunks then
		return
	end
	local s, C = concat(chunks), st.C
	local node, pos = C * C, 4
	for _ = 1, num(s, 1, 3) do
		local lc, count = num(s, pos, 3), B64[byte(s, pos + 3)]
		pos = pos + 4
		at[-(lc + 1)] = node
		for _ = 1, count do
			val[node + 1], z[node + 1], at[node + 1] = B64[byte(s, pos)], num(s, pos + 1, 2) - 2048, lc
			local steps = num(s, pos + 3, 2)
			for d = 0, 7 do
				if floor(steps / 2 ^ d) % 2 == 1 then
					addLink(links, node, d, -1)
				end
			end
			pos, node = pos + 5, node + 1
		end
	end
	local last = node
	for _ = 1, num(s, pos, 3) do
		addLink(links, num(s, pos + 3, 3), B64[byte(s, pos + 6)], B64[byte(s, pos + 7)])
		pos = pos + 5
	end
	-- A base cell's links to floors inside the cluster are the reverse of the floors' own.
	for f = C * C, last - 1 do
		local l, lc = links[f + 1], at[f + 1]
		local layer = f - at[-(lc + 1)] + 1
		for e = 1, #(l or {}), 2 do
			local d = l[e]
			local tx, ty = floor(lc / C) + DX[d], lc % C + DY[d]
			if tx >= 0 and ty >= 0 and tx < C and ty < C then
				local t = surface(st, k, tx * C + ty, l[e + 1], z[f + 1])
				if t and t < C * C then
					addLink(links, t, OPPOSITE[d], layer)
				end
			end
		end
	end
end

local function decodeGrid(st, k)
	local chunks = st.D.grid[k + 1]
	if not chunks then
		st.val[k] = false
		return false
	end
	local s, C = concat(chunks), st.C
	local val, m = {}, {}
	local n, code = 0, 0
	for i = 1, #s do
		local sym = B64[byte(s, i)]
		if sym < 48 then
			code = sym
			n = n + 1
			val[n], m[n] = floor(code / 16), (code % 16) * 16
		else
			for _ = 48, sym do
				n = n + 1
				val[n], m[n] = floor(code / 16), (code % 16) * 16
			end
		end
	end
	-- m[i] packs the open moves (1 = +x, 2 = +y, 4 = +x+y, 8 = +x-y) over the data flags * 16.
	local N = C * C
	for a = 0, N - 1 do
		local i = a + 1
		local f = m[i] / 16
		if val[i] ~= 0 then
			if a + C < N and val[i + C] ~= 0 and f % 2 == 0 then
				m[i] = m[i] + 1
			end
			if a % C < C - 1 and val[i + 1] ~= 0 and f % 4 < 2 then
				m[i] = m[i] + 2
			end
		end
	end
	-- Diagonals: either L-shaped detour open, or an explicit link.
	local function X(j)
		return m[j] % 2 == 1
	end
	local function Y(j)
		return m[j] % 4 >= 2
	end
	for a = 0, N - 1 do
		local i, ly = a + 1, a % C
		if a + C < N and val[i] ~= 0 then
			local f = floor(m[i] / 16)
			if ly < C - 1 and val[i + C + 1] ~= 0 and ((X(i) and Y(i + C)) or (Y(i) and X(i + 1)) or f % 8 >= 4) then
				m[i] = m[i] + 4
			end
			if ly > 0 and val[i + C - 1] ~= 0 and ((X(i) and Y(i + C - 1)) or (Y(i - 1) and X(i - 1)) or f >= 8) then
				m[i] = m[i] + 8
			end
		end
	end
	local z = {}
	st.val[k], st.moves[k], st.z[k] = val, m, z
	decodeHeights(st, k, val, z)
	decodeFloors(st, k, val, z)
	return val
end

-- Decoded clusters cost ~0.25 MB each under Lua 5.1, so only the Path.clusters most recently used stay decoded.
local useClock = 0

local function evict(st)
	local oldest, at = nil, huge
	for k, used in pairs(st.used) do
		if used < at then
			oldest, at = k, used
		end
	end
	st.used[oldest] = nil
	st.val[oldest], st.moves[oldest], st.z[oldest], st.at[oldest], st.links[oldest] = nil, nil, nil, nil, nil
	st.decoded = st.decoded - 1
end

local function grid(st, k)
	local val = st.val[k]
	if val == nil then
		if st.decoded >= max(Path.clusters, 4) then
			evict(st)
		end
		val = decodeGrid(st, k)
		st.decoded = st.decoded + 1
	end
	useClock = useClock + 1
	st.used[k] = useClock
	return val
end

-- A node's local cell.
local function cellOf(st, k, node)
	if node < st.C * st.C then
		return node
	end
	grid(st, k)
	return st.at[k][node + 1]
end

local function decodeGraph(st, k)
	local ids = {}
	st.nodes[k] = ids
	local chunks = st.D.graph[k + 1]
	if not chunks then
		return ids
	end
	local s = concat(chunks)
	local n, pos = num(s, 1, 2), 3
	local degree = {}
	for i = 0, n - 1 do
		local id = k * 4096 + i
		ids[i + 1] = id
		st.ncell[id] = num(s, pos, 3)
		st.nlayer[id] = B64[byte(s, pos + 3)]
		st.ncomp[id] = num(s, pos + 4, 2)
		degree[i + 1] = B64[byte(s, pos + 6)]
		pos = pos + 7
	end
	local ny = st.ny
	for i = 1, n do
		local adj = {}
		for e = 1, degree[i] do
			local offset = B64[byte(s, pos)]
			local target = k + (floor(offset / 3) - 1) * ny + offset % 3 - 1
			adj[e * 2 - 1] = target * 4096 + num(s, pos + 1, 2)
			adj[e * 2] = num(s, pos + 3, 2)
			pos = pos + 5
		end
		st.nadj[ids[i]] = adj
	end
	return ids
end

local function nodesOf(st, k)
	return st.nodes[k] or decodeGraph(st, k)
end

-- An entrance's node in its cluster.
local function entrance(st, id)
	local k = floor(id / 4096)
	grid(st, k)
	return surface(st, k, st.ncell[id], st.nlayer[id])
end

-- Cluster k and local cell of a world point, or nil outside the data.
local function locate(st, x, y)
	local gx, gy = floor((x - st.x0) / st.cs), floor((y - st.y0) / st.cs)
	if gx < 0 or gy < 0 or gx >= st.GX or gy >= st.GY then
		return nil
	end
	local C = st.C
	return floor(gx / C) * st.ny + floor(gy / C), (gx % C) * C + gy % C
end

-- The walkable node of local cell lc a point at height h stands on (the base surface when h is unknown), and the
-- height gap to it.
local function standing(st, k, lc, h)
	local val = grid(st, k)
	if not val then
		return nil
	end
	if h == nil then
		return val[lc + 1] ~= 0 and lc or nil, 0
	end
	return surface(st, k, lc, -1, h)
end

-- The node an endpoint stands on: within SNAP cells, the surface with the least distance plus twice the height gap,
-- among those within ZTOL of its height. A point off every surface (in a lift shaft, mid-jump, deep under water) takes
-- the nearest surface of any height.
local function snap(st, k, lc, x, y, h)
	local C, cs = st.C, st.cs
	local lx, ly = floor(lc / C), lc % C
	local cx, cy = st.x0 + (floor(k / st.ny) * C + lx + 0.5) * cs, st.y0 + ((k % st.ny) * C + ly + 0.5) * cs
	local best, bestCost, any, anyD
	for r = 0, SNAP do
		if best and (r - 1) * cs > bestCost then
			break
		end
		for dx = -r, r do
			for dy = -r, r do
				local nx, ny = lx + dx, ly + dy
				if (dx == r or dx == -r or dy == r or dy == -r) and nx >= 0 and ny >= 0 and nx < C and ny < C then
					local n, gap = standing(st, k, nx * C + ny, h)
					if n then
						local d = r == 0 and 0 or sqrt((cx + dx * cs - x) ^ 2 + (cy + dy * cs - y) ^ 2)
						if gap <= ZTOL and (not bestCost or d + 2 * gap < bestCost) then
							best, bestCost = n, d + 2 * gap
						end
						if not anyD or d < anyD then
							any, anyD = n, d
						end
					end
				end
			end
		end
	end
	return best or any
end

-- Grid search inside one cluster. tree holds g/parent keyed by node + 1. With goal set it is A*, otherwise
-- Dijkstra that stops once every node in targets (a set of nodes) is settled.
local function Tree()
	return { g = {}, par = {}, stamp = {}, closed = {}, gen = 0 }
end

local function search(st, k, source, tree, goal, targets, left)
	local val = grid(st, k)
	local m, z, at, links = st.moves[k], st.z[k], st.at[k], st.links[k]
	local C, cs, swim = st.C, st.cs, st.swim
	local N = C * C
	local g, par, stamp, closed = tree.g, tree.par, tree.stamp, tree.closed
	tree.gen = tree.gen + 1
	local gen = tree.gen
	tree.k = k
	local gx, gy = 0, 0
	if goal then
		local cell = goal < N and goal or at[goal + 1]
		gx, gy = floor(cell / C), cell % C
	end
	hn = 0
	g[source + 1], par[source + 1], stamp[source + 1] = 0, -1, gen
	push(0, source)

	local u, ux, uy, gu
	local function relax(v, length)
		local i = v + 1
		local gv = gu + length * cs * (val[i] == 2 and swim or 1)
		if stamp[i] ~= gen or gv < g[i] then
			g[i], par[i], stamp[i] = gv, u, gen
			local h = 0
			if goal then
				local cell = v < N and v or at[i]
				local ax, ay = floor(cell / C) - gx, cell % C - gy
				if ax < 0 then
					ax = -ax
				end
				if ay < 0 then
					ay = -ay
				end
				h = (ax > ay and ax + (SQRT2 - 1) * ay or ay + (SQRT2 - 1) * ax) * cs
			end
			push(gv + h, v)
		end
	end

	while hn > 0 do
		u = pop()
		local i = u + 1
		if closed[i] ~= gen then
			closed[i] = gen
			tick()
			if u == goal then
				return true
			end
			if targets and targets[u] then
				left = left - 1
				if left <= 0 then
					return true
				end
			end
			local cell = u < N and u or at[i]
			gu, ux, uy = g[i], floor(cell / C), cell % C
			if u < N then
				local mi = m[i] % 16
				local px, mx = mi % 2 == 1, ux > 0 and m[i - C] % 2 == 1
				local py, my = mi % 4 >= 2, uy > 0 and m[i - 1] % 4 >= 2
				if px then
					relax(u + C, 1)
				end
				if mx then
					relax(u - C, 1)
				end
				if py then
					relax(u + 1, 1)
				end
				if my then
					relax(u - 1, 1)
				end
				if mi % 8 >= 4 then
					relax(u + C + 1, SQRT2)
				end
				if mi >= 8 then
					relax(u + C - 1, SQRT2)
				end
				if ux > 0 and uy > 0 and m[i - C - 1] % 8 >= 4 then
					relax(u - C - 1, SQRT2)
				end
				if ux > 0 and uy < C - 1 and m[i - C + 1] % 16 >= 8 then
					relax(u - C + 1, SQRT2)
				end
			end
			local l = links[i]
			if l then
				for e = 1, #l, 2 do
					local d = l[e]
					local tx, ty = ux + DX[d], uy + DY[d]
					if tx >= 0 and ty >= 0 and tx < C and ty < C then
						local v = surface(st, k, tx * C + ty, l[e + 1], z[i])
						if v then
							relax(v, d >= 4 and SQRT2 or 1)
						end
					end
				end
			end
		end
	end
	return goal == nil
end

local function reached(tree, node)
	return tree.stamp[node + 1] == tree.gen and tree.closed[node + 1] == tree.gen
end

-- Node path in a tree from node back to its source (node first).
local function trace(tree, node, out)
	local par = tree.par
	while node >= 0 do
		out[#out + 1] = node
		node = par[node + 1]
	end
	return out
end

-- Global grid helpers for smoothing across clusters.
local function value(st, gx, gy)
	if gx < 0 or gy < 0 or gx >= st.GX or gy >= st.GY then
		return 0
	end
	local C = st.C
	local val = grid(st, floor(gx / C) * st.ny + floor(gy / C))
	return val and val[(gx % C) * C + gy % C + 1] or 0
end

-- Is the base surface's step from (gx, gy) to (gx + dx, gy + dy) open, for an orthogonal unit step?
local function stepOpen(st, gx, gy, dx, dy, water)
	local ax, ay = gx, gy
	if dx < 0 or dy < 0 then
		ax, ay = gx + dx, gy + dy
	end
	local a, b = value(st, ax, ay), value(st, ax + (dx ~= 0 and 1 or 0), ay + (dy ~= 0 and 1 or 0))
	if a == 0 or b == 0 or (not water and (a == 2 or b == 2)) then
		return false
	end
	local C = st.C
	local f = floor(st.moves[floor(ax / C) * st.ny + floor(ay / C)][(ax % C) * C + ay % C + 1] / 16)
	if dx ~= 0 then
		return f % 2 == 0
	end
	return f % 4 < 2
end

-- Is the base surface's diagonal step from (gx, gy) by (sx, sy) open?
local function diagonalOpen(st, gx, gy, sx, sy, water)
	local b = value(st, gx + sx, gy + sy)
	if b == 0 or (not water and b == 2) then
		return false
	end
	if
		(stepOpen(st, gx, gy, sx, 0, water) and stepOpen(st, gx + sx, gy, 0, sy, water))
		or (stepOpen(st, gx, gy, 0, sy, water) and stepOpen(st, gx, gy + sy, sx, 0, water))
	then
		return true
	end
	local ax, ay, up = gx, gy, sy > 0 -- links are stored on the lower-x cell
	if sx < 0 then
		ax, ay, up = gx + sx, gy + sy, sy < 0
	end
	local a = value(st, ax, ay)
	if a == 0 or (not water and a == 2) then
		return false
	end
	local C = st.C
	local f = floor(st.moves[floor(ax / C) * st.ny + floor(ay / C)][(ax % C) * C + ay % C + 1] / 16)
	if up then
		return f % 8 >= 4
	end
	return f >= 8
end

-- The node one step (dx, dy) on from node of cluster k at global cell (gx, gy): the base surface's own step first,
-- then the node's floor links. Nil when the step is closed.
local function neighbour(st, k, node, gx, gy, dx, dy, water)
	local tx, ty = gx + dx, gy + dy
	if tx < 0 or ty < 0 or tx >= st.GX or ty >= st.GY then
		return nil
	end
	local C = st.C
	local tk, tlc = floor(tx / C) * st.ny + floor(ty / C), (tx % C) * C + ty % C
	if node < C * C then
		local open
		if dx == 0 or dy == 0 then
			open = stepOpen(st, gx, gy, dx, dy, water)
		else
			open = diagonalOpen(st, gx, gy, dx, dy, water)
		end
		if open then
			return tk, tlc
		end
	end
	grid(st, k)
	local l = st.links[k][node + 1]
	if not l then
		return nil
	end
	local here, h, d = st.val[k][node + 1], st.z[k][node + 1], DIRECTION[(dx + 1) * 3 + dy + 1]
	for e = 1, #l, 2 do
		if l[e] == d then
			grid(st, tk)
			local v = surface(st, tk, tlc, l[e + 1], h)
			if v and (water or (here ~= 2 and st.val[tk][v + 1] ~= 2)) then
				return tk, v
			end
		end
	end
	return nil
end

-- Line of sight between two path entries, walking every cell the segment between their cell centres crosses and
-- following the surface from node to node, so it cannot jump between floors.
local function sight(st, P, a, b, water)
	local ax, ay, bx, by = P.x[a], P.y[a], P.x[b], P.y[b]
	local k, node = P.k[a], P.n[a]
	local dx, dy = bx - ax, by - ay
	local sx, sy = dx > 0 and 1 or -1, dy > 0 and 1 or -1
	local nx, ny = dx * sx, dy * sy
	local x, y, ix, iy = ax, ay, 0, 0
	while ix < nx or iy < ny do
		tick()
		-- Compare the next x and y boundary crossings: (0.5 + ix) / nx against (0.5 + iy) / ny.
		local d = (1 + 2 * ix) * ny - (1 + 2 * iy) * nx
		local mx, my = 0, 0
		if d == 0 then -- through a corner
			mx, my = sx, sy
		elseif d < 0 then
			mx = sx
		else
			my = sy
		end
		k, node = neighbour(st, k, node, x, y, mx, my, water)
		if not k then
			return false
		end
		x, y = x + mx, y + my
		ix, iy = ix + mx * sx, iy + my * sy
	end
	return k == P.k[b] and node == P.n[b]
end

-- Collapse a node path to its turns, then pull the string: from each anchor, jump to the furthest point in sight.
-- Water may only be crossed where the path itself swam.
local function smooth(st, P)
	local PX, PY, PW = P.x, P.y, P.w
	local n = #PX
	local keep = { 1 }
	for i = 2, n - 1 do
		if PX[i + 1] - PX[i] ~= PX[i] - PX[i - 1] or PY[i + 1] - PY[i] ~= PY[i] - PY[i - 1] or PW[i + 1] ~= PW[i] then
			keep[#keep + 1] = i
		end
	end
	if n > 1 then
		keep[#keep + 1] = n
	end
	local out, a = { keep[1] }, 1
	while a < #keep do
		local b = a + 1
		for j = a + 2, #keep do
			local p, q = keep[a], keep[j]
			if not sight(st, P, p, q, PW[q] - PW[p] > 0) then
				break
			end
			b = j
		end
		out[#out + 1] = keep[b]
		a = b
	end
	return out
end

local trees = { S = Tree(), G = Tree(), R = Tree() }

-- Abstract A* state.
local ag, apar, astamp, aclosed, agen = {}, {}, {}, {}, 0

local function run(map, from, to)
	local st = State(map)
	if not st then
		return nil, "nodata"
	end
	local sk, sc = locate(st, from.x, from.y)
	local gk, gc = locate(st, to.x, to.y)
	if not sk or not gk then
		return nil, "outside"
	end
	sc, gc = snap(st, sk, sc, from.x, from.y, from.z), snap(st, gk, gc, to.x, to.y, to.z)
	if not sc or not gc then
		return nil, "offmesh"
	end
	local C = st.C

	-- Endpoint searches: grid Dijkstra to the cluster's entrances (and the other endpoint when they share it).
	local function endpoint(tree, k, node, other)
		local targets, left = {}, 0
		for _, id in ipairs(nodesOf(st, k)) do
			local e = entrance(st, id)
			if e and not targets[e] then
				targets[e], left = true, left + 1
			end
		end
		if other and not targets[other] then
			targets[other], left = true, left + 1
		end
		search(st, k, node, tree, nil, targets, left)
	end
	-- An endpoint on a rooftop or ledge the grid cannot leave moves to the nearest node that reaches an entrance,
	-- down a ledge but never up one or onto another level.
	local function settle(tree, k, node, other)
		endpoint(tree, k, node, other)
		local function connected()
			if other and reached(tree, other) then
				return true
			end
			for _, id in ipairs(nodesOf(st, k)) do
				local e = entrance(st, id)
				if e and reached(tree, e) then
					return true
				end
			end
			return false
		end
		local tries = 0
		local h = st.z[k][node + 1]
		local cell = cellOf(st, k, node)
		local lx, ly = floor(cell / C), cell % C
		for r = 1, SNAP do
			for dx = -r, r do
				for dy = -r, r do
					if connected() or tries >= RETRIES then
						return node
					end
					local x, y = lx + dx, ly + dy
					local ring = dx == r or dx == -r or dy == r or dy == -r
					if ring and x >= 0 and y >= 0 and x < C and y < C then
						local near = standing(st, k, x * C + y, h)
						local rise = near and st.z[k][near + 1] - h
						if near and rise <= ZTOL and rise >= -DROP and not reached(tree, near) then
							tries, node = tries + 1, near
							endpoint(tree, k, node, other)
						end
					end
				end
			end
		end
		return node
	end
	local S, G = trees.S, trees.G
	local same = sk == gk
	gc = settle(G, gk, gc, nil)
	settle(S, sk, sc, same and gc)
	local direct = same and reached(S, gc) and S.g[gc + 1] or nil

	-- O(1)-ish reject: the endpoints' entrances must share a component.
	local comps, shared = {}, false
	for _, id in ipairs(nodesOf(st, sk)) do
		local e = entrance(st, id)
		if e and reached(S, e) then
			comps[st.ncomp[id]] = true
		end
	end
	for _, id in ipairs(nodesOf(st, gk)) do
		local e = entrance(st, id)
		if e and reached(G, e) and comps[st.ncomp[id]] then
			shared = true
		end
	end
	if not direct and not shared then
		return nil, "unreachable"
	end

	-- Abstract A* from START to GOAL through the entrance graph.
	local x0, y0, cs = st.x0, st.y0, st.cs
	local function world(id)
		local k, lc = floor(id / 4096), st.ncell[id]
		return x0 + (floor(k / st.ny) * C + floor(lc / C) + 0.5) * cs, y0 + ((k % st.ny) * C + lc % C + 0.5) * cs
	end
	local function h(id)
		local x, y = world(id)
		return sqrt((x - to.x) ^ 2 + (y - to.y) ^ 2)
	end
	agen = agen + 1
	local gen = agen
	hn = 0
	local function relax(v, gv, parent)
		if astamp[v] ~= gen or gv < ag[v] then
			ag[v], apar[v], astamp[v] = gv, parent, gen
			push(gv + (v == GOAL and 0 or h(v)), v)
		end
	end
	for _, id in ipairs(nodesOf(st, sk)) do
		local e = entrance(st, id)
		if e and reached(S, e) then
			relax(id, S.g[e + 1], START)
		end
	end
	if direct then
		relax(GOAL, direct, START)
	end
	local found = false
	while hn > 0 do
		local u = pop()
		if aclosed[u] ~= gen then
			aclosed[u] = gen
			tick()
			if u == GOAL then
				found = true
				break
			end
			local gu = ag[u]
			if floor(u / 4096) == gk then
				local e = entrance(st, u)
				if e and reached(G, e) then
					relax(GOAL, gu + G.g[e + 1], u)
				end
			end
			local adj = st.nadj[u]
			for e = 1, #adj, 2 do
				local v = adj[e]
				if aclosed[v] ~= gen then
					nodesOf(st, floor(v / 4096))
					relax(v, gu + adj[e + 1], u)
				end
			end
		end
	end
	if not found then
		return nil, "unreachable"
	end
	local hops = { GOAL }
	while hops[#hops] ~= START do
		hops[#hops + 1] = apar[hops[#hops]]
	end

	-- Refine each hop into nodes with their global cells and a running count of water nodes.
	local P = { x = {}, y = {}, w = {}, k = {}, n = {} }
	local function add(k, node)
		local n = #P.x
		if n == 0 or P.k[n] ~= k or P.n[n] ~= node then
			local cell = cellOf(st, k, node)
			P.x[n + 1], P.y[n + 1] = floor(k / st.ny) * C + floor(cell / C), (k % st.ny) * C + cell % C
			P.k[n + 1], P.n[n + 1] = k, node
			P.w[n + 1] = (P.w[n] or 0) + (grid(st, k)[node + 1] == 2 and 1 or 0)
		end
	end
	local function addAll(k, nodes, first, last, step)
		for i = first, last, step do
			add(k, nodes[i])
		end
	end
	local R = trees.R
	for i = #hops, 2, -1 do
		local a, b = hops[i], hops[i - 1]
		if a == START and b == GOAL then
			local nodes = trace(S, gc, {})
			addAll(sk, nodes, #nodes, 1, -1)
		elseif a == START then
			local nodes = trace(S, entrance(st, b), {})
			addAll(sk, nodes, #nodes, 1, -1)
		elseif b == GOAL then
			local nodes = trace(G, entrance(st, a), {})
			addAll(gk, nodes, 1, #nodes, 1)
		else
			local ka, kb = floor(a / 4096), floor(b / 4096)
			local ea, eb = entrance(st, a), entrance(st, b)
			if ka == kb and search(st, ka, ea, R, eb) then
				local nodes = trace(R, eb, {})
				addAll(ka, nodes, #nodes, 1, -1)
			else -- neighbouring entrances across a cluster border
				add(ka, ea)
				add(kb, eb)
			end
		end
	end

	-- Points carry the height of the surface they stand on; the cost counts swimming at its slower pace.
	local keep = smooth(st, P)
	if #keep == 1 then -- both ends on one node
		keep[2] = keep[1]
	end
	local points = { { map = map, x = from.x, y = from.y, z = from.z } }
	for i = 2, #keep - 1 do
		local j = keep[i]
		grid(st, P.k[j])
		points[#points + 1] = {
			map = map,
			x = x0 + (P.x[j] + 0.5) * cs,
			y = y0 + (P.y[j] + 0.5) * cs,
			z = st.z[P.k[j]][P.n[j] + 1],
		}
	end
	points[#points + 1] = { map = map, x = to.x, y = to.y, z = to.z }
	local cost = 0
	for i = 2, #points do
		local p, q = keep[i - 1], keep[i]
		local wet = q > p and (P.w[q] - P.w[p]) / (q - p) or 0
		local length = sqrt((points[i].x - points[i - 1].x) ^ 2 + (points[i].y - points[i - 1].y) ^ 2)
		cost = cost + length * (1 + (st.swim - 1) * wet)
	end
	return points, cost
end

local function start(job)
	expansions = 0
	return run(job.map, job.from, job.to)
end

-- Synchronous search, for tests and tools. Returns points, cost (or nil, reason) and the expansion count.
function Path.FindSync(map, from, to)
	deadline, ops = huge, 0
	local job = { map = map, from = from, to = to }
	local co = coroutine.create(start)
	local ok, points, cost = coroutine.resume(co, job)
	if not ok then
		error(points)
	end
	return points, cost, expansions
end

-- Jobs run one at a time, each resumed once a frame until Path.budget ms of CPU is spent.
local queue = {}
local scheduled = false
local pump

local function schedule()
	if not scheduled and #queue > 0 then
		scheduled = true
		Path.after(pump)
	end
end

pump = function()
	scheduled = false
	local job = queue[1]
	if not job then
		return
	end
	local t0 = clock()
	deadline, ops = t0 + Path.budget, 0
	expansions = job.expansions or 0
	local ok, points, cost = coroutine.resume(job.co, job)
	job.expansions = expansions
	job.frames = job.frames + 1
	job.cpu = job.cpu + clock() - t0
	deadline = huge
	if not ok or coroutine.status(job.co) == "dead" then
		table.remove(queue, 1)
		if not ok then
			geterrorhandler()(points)
		elseif not job.cancelled then
			job.callback(points, cost, job)
		end
	end
	schedule()
end

-- Next-frame scheduling; tests replace it.
function Path.after(fn)
	C_Timer.After(0, fn)
end

-- Search coroutine-sliced over frames between two { x, y, z } points (z optional: it picks the floor to start or end
-- on). callback(points, cost, job) or callback(nil, reason, job): points are { map, x, y, z } from the start to the
-- goal, and cost is the walk in running yards, with swimming counted at its slower pace. reason is "nodata",
-- "outside", "offmesh" or "unreachable". Returns a handle for Path.Cancel.
function Path.Find(map, from, to, callback)
	local job = {
		map = map,
		from = from,
		to = to,
		callback = callback,
		co = coroutine.create(start),
		frames = 0,
		cpu = 0,
	}
	queue[#queue + 1] = job
	schedule()
	return job
end

function Path.Cancel(job)
	job.cancelled = true
	for i, queued in ipairs(queue) do
		if queued == job and i > 1 then
			table.remove(queue, i)
			return
		end
	end
end

function Path.HasData(map)
	return Data(map) ~= nil
end
