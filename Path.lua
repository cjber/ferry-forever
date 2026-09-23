---@class SPFNamespace
local ns = select(2, ...)

-- Walking routes over a continent's collision map: HPA* between ADT-tile clusters, an 8 yd grid inside them,
-- then string-pulling so the drawn line is not jagged. FindMany resolves costs in one abstract Dijkstra.
-- Costs use the graph and local grid weights; smoothing changes only the drawing.
-- Coordinates are UnitPosition's frame (x north, y west).
-- A cell holds its base surface and, where surfaces overlap (a tunnel under a mountain, a city under ruins, both
-- ends of a lift), floors above or below it. A node is a local cell (the base surface) or C * C + a floor's index.
---@class SPFPath
local Path = {}
ns.Path = Path

Path.budget = 3 -- milliseconds of CPU per frame, shared by Find and FindMany
Path.clusters = 64 -- secondary count ceiling per map (at least 4)
Path.graphKB = 4096 -- decoded entrances/edges across all maps
Path.cacheKB = 24576 -- decoded grids across all maps; active coroutine locals are additional
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
local yield = coroutine.yield

local B64 = {}
do
	local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i = 1, 64 do
		B64[byte(alphabet, i)] = i - 1
	end
end

local function num(s, i, width)
	local a, b, c = byte(s, i, i + width - 1)
	local value = B64[a] * 64 + B64[b]
	return width == 2 and value or value * 64 + B64[c]
end

-- Slicing yields at the shared deadline; pump swaps each coroutine's private search scratch before resuming it.
local deadline, ops, expansions = huge, 0, 0
local clock = function()
	return Path.clock()
end

local function slice()
	if deadline < huge and clock() > deadline then
		yield()
	end
end

Path.Checkpoint = slice

local function tick()
	expansions = expansions + 1
	ops = ops + 1
	if ops >= CHECK then
		ops = 0
		slice()
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
---@param map number
---@return SPFNavData?
local function Data(map)
	if not (ShortestPathForeverPathData and ShortestPathForeverPathData[map]) and not tried[map] and C_AddOns then
		-- LoadAddOn itself is atomic in the client. Give it its own frame before the first decode.
		if deadline < huge then
			yield("load")
		end
		if not tried[map] and not (ShortestPathForeverPathData and ShortestPathForeverPathData[map]) then
			tried[map] = true
			C_AddOns.LoadAddOn("ShortestPathForever_Nav" .. map)
		end
		if deadline < huge then
			yield("load")
		end
	end
	return ShortestPathForeverPathData and ShortestPathForeverPathData[map]
end

-- Per-map state; clusters are decoded on first use.
local states = {}

local function State(map)
	local st = states[map]
	if st == nil then
		local D = Data(map)
		if states[map] then
			return states[map]
		end
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
			sizes = {},
			used = {}, -- [k] = last use, for eviction
			decoded = 0,
			val = {}, -- [k] = node values (node + 1), false when the cluster has no data
			moves = {}, -- [k][lc + 1] = open moves inside the cluster + 16 * the data file's step flags
			z = {}, -- [k][node + 1] = height of a walkable node
			at = {}, -- [k][node + 1] = a floor's local cell; [k][-(lc + 1)] = the cell's first floor node
			links = {}, -- [k][node + 1] = { direction + 8 * (layer + 1), ... } steps besides the base grid's
			graphUsed = {},
			graphSize = {},
			nodes = {}, -- [k] = entrance ids (k * 4096 + i)
			ncell = {}, -- [id] = local cell
			nlayer = {}, -- [id] = 0 for the base surface, i for the cell's ith floor
			ncomp = {},
			ends = {}, -- bounded local connections, shared by successive endpoint batches
			endCount = 0,
			nadj = {}, -- [id] = { target, cost swimming, cost walking on water, ... }
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
local function surface(st, k, lc, layer, h, values, heights, floors)
	local val, z, at = values or st.val[k], heights or st.z[k], floors or st.at[k]
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

-- Floor step masks recur thousands of times. Share the common immutable link sets;
-- the few nodes with additional explicit links copy on write.
local linkSets, directionBits = {}, {}
for _, layer in ipairs({ -1, 1 }) do
	linkSets[layer] = setmetatable({}, {
		__index = function(set, mask)
			if mask == 0 then
				return nil
			end
			local links, bits = { shared = layer, mask = mask }, mask
			for d = 0, 7 do
				if bits % 2 == 1 then
					links[#links + 1] = d + 8 * (layer + 1)
				end
				bits = floor(bits / 2)
			end
			set[mask] = links
			return links
		end,
	})
end
for d = 0, 7 do
	directionBits[d] = 2 ^ d
end
local stepLinks = linkSets[-1]

local function addLink(links, node, d, layer)
	local l = links[node + 1]
	local set = linkSets[layer]
	if set and (not l or l.shared == layer) then
		local mask, bit = l and l.mask or 0, directionBits[d]
		if floor(mask / bit) % 2 == 0 then
			mask = mask + bit
		end
		links[node + 1] = set[mask]
		return
	end
	if not l then
		l = {}
		links[node + 1] = l
	elseif l.shared then
		local copy = {}
		for i = 1, #l do
			copy[i] = l[i]
		end
		l, links[node + 1] = copy, copy
	end
	l[#l + 1] = d + 8 * (layer + 1)
end

local function decodeHeights(st, k, val, z)
	local s, C, step = st.D.height[k + 1], st.C, st.zstep
	local pos, rep, delta, last = 1, 0, 0, 0
	for i = 1, C * C do
		if i % 256 == 0 then
			slice()
		end
		if val[i] ~= 0 then
			local a = i - 1
			local pred = (a % C > 0 and z[i - 1] and z[i - 1] / step)
				or (a >= C and z[i - C] and z[i - C] / step)
				or last
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
			last, z[i] = v, v * step
		end
	end
end

local function decodeFloors(st, k, val, z)
	local at, links = {}, {}
	local chunks = st.D.floor[k + 1]
	if not chunks then
		return at, links
	end
	local s, C = chunks, st.C
	local node, pos = C * C, 4
	for _ = 1, num(s, 1, 3) do
		local lc, count = num(s, pos, 3), B64[byte(s, pos + 3)]
		pos = pos + 4
		at[-(lc + 1)] = node
		for _ = 1, count do
			if node % 64 == 0 then
				slice()
			end
			val[node + 1], z[node + 1], at[node + 1] = B64[byte(s, pos)], num(s, pos + 1, 2) - 2048, lc
			links[node + 1] = stepLinks[num(s, pos + 3, 2)]
			pos, node = pos + 5, node + 1
		end
	end
	local last = node
	for i = 1, num(s, pos, 3) do
		if i % 64 == 0 then
			slice()
		end
		addLink(links, num(s, pos + 3, 3), B64[byte(s, pos + 6)], B64[byte(s, pos + 7)])
		pos = pos + 5
	end
	-- A base cell's links to floors inside the cluster are the reverse of the floors' own.
	for f = C * C, last - 1 do
		if f % 64 == 0 then
			slice()
		end
		local l, lc = links[f + 1], at[f + 1]
		local layer = f - at[-(lc + 1)] + 1
		for e = 1, l and #l or 0 do
			local d = l[e] % 8
			local tx, ty = floor(lc / C) + DX[d], lc % C + DY[d]
			if tx >= 0 and ty >= 0 and tx < C and ty < C then
				local t = surface(st, k, tx * C + ty, floor(l[e] / 8) - 1, z[f + 1], val, z, at)
				if t and t < C * C then
					addLink(links, t, OPPOSITE[d], layer)
				end
			end
		end
	end
	return at, links
end

local function decodeGrid(st, k)
	Path.decodes = (Path.decodes or 0) + 1
	local chunks = st.D.grid[k + 1]
	if not chunks then
		st.val[k] = false
		return false
	end
	local s, C = chunks, st.C
	local val, m = {}, {}
	local n, valueCode, moveCode = 0, 0, 0
	for i = 1, #s do
		if i % 256 == 0 then
			slice()
		end
		local sym = B64[byte(s, i)]
		if sym < 48 then
			valueCode, moveCode = floor(sym / 16), (sym % 16) * 16
			n = n + 1
			val[n], m[n] = valueCode, moveCode
		else
			for _ = 48, sym do
				n = n + 1
				val[n], m[n] = valueCode, moveCode
			end
		end
	end
	-- m[i] packs the open moves (1 = +x, 2 = +y, 4 = +x+y, 8 = +x-y) over the data flags * 16.
	local N = C * C
	-- Descending cells let diagonals reuse their forward neighbours' decoded moves in the same pass.
	for a = N - 1, 0, -1 do
		if a % 256 == 0 then
			slice()
		end
		local i, ly = a + 1, a % C
		local f = m[i] / 16
		if val[i] ~= 0 then
			if a + C < N and val[i + C] ~= 0 and f % 2 == 0 then
				m[i] = m[i] + 1
			end
			if ly < C - 1 and val[i + 1] ~= 0 and f % 4 < 2 then
				m[i] = m[i] + 2
			end
		end
		-- Diagonals: either L-shaped detour open, or an explicit link.
		if a + C < N and val[i] ~= 0 then
			if
				ly < C - 1
				and val[i + C + 1] ~= 0
				and ((m[i] % 2 == 1 and m[i + C] % 4 >= 2) or (m[i] % 4 >= 2 and m[i + 1] % 2 == 1) or f % 8 >= 4)
			then
				m[i] = m[i] + 4
			end
			if
				ly > 0
				and val[i + C - 1] ~= 0
				and (
					(m[i] % 2 == 1 and m[i + C - 1] % 4 >= 2)
					or (val[i - 1] ~= 0 and m[i - 1] % 64 < 32 and m[i - 1] % 32 < 16)
					or f >= 8
				)
			then
				m[i] = m[i] + 8
			end
		end
	end
	local z = {}
	decodeHeights(st, k, val, z)
	local at, links = decodeFloors(st, k, val, z)
	return val, m, z, at, links
end

-- Lua 5.1 array slots occupy 16 bytes and grow by powers of two. Charge sparse floor/link hashes
-- conservatively too; this is a memory ceiling across continents, not a cluster count estimate.
local useClock, decodedKB, decodedCount = 0, 0, 0
local function gridSize(val, at, links)
	local capacity = 1
	while capacity < #val do
		capacity = capacity * 2
	end
	local bytes = capacity * 16 * 3 + 5 * 64
	for _ in pairs(at) do
		bytes = bytes + 64
	end
	for _, link in pairs(links) do
		bytes = bytes + 128 + #link * 32
	end
	return bytes / 1024
end

local function evict(st, oldest)
	decodedKB, decodedCount = decodedKB - st.sizes[oldest], decodedCount - 1
	st.sizes[oldest], st.used[oldest] = nil, nil
	st.val[oldest], st.moves[oldest], st.z[oldest], st.at[oldest], st.links[oldest] = nil, nil, nil, nil, nil
	st.decoded = st.decoded - 1
end

local function trim(st, size)
	while (decodedKB + size > Path.cacheKB and decodedCount >= 4) or st.decoded >= max(Path.clusters, 4) do
		local owner, oldest, age = nil, nil, huge
		for _, candidate in pairs(states) do
			if st.decoded < max(Path.clusters, 4) or candidate == st then
				for k, used in pairs(candidate.used) do
					if used < age then
						owner, oldest, age = candidate, k, used
					end
				end
			end
		end
		if not owner or not oldest then
			break
		end
		evict(owner, oldest)
	end
end

local function grid(st, k)
	local val = st.val[k]
	if val == nil then
		local m, z, at, links
		val, m, z, at, links = decodeGrid(st, k)
		-- Decoding may yield; only complete grids are published to concurrent searches.
		if st.val[k] ~= nil then
			return grid(st, k)
		end
		if not val then
			return false
		end
		local size = gridSize(val, at, links)
		trim(st, size)
		st.val[k], st.moves[k], st.z[k], st.at[k], st.links[k] = val, m, z, at, links
		st.sizes[k], st.decoded, decodedKB = size, st.decoded + 1, decodedKB + size
		decodedCount = decodedCount + 1
	end
	if val then
		useClock = useClock + 1
		st.used[k] = useClock
	end
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

local graphKB, graphClock = 0, 0
local function trimGraphs()
	while graphKB > Path.graphKB do
		local owner, oldest, age = nil, nil, huge
		for _, st in pairs(states) do
			for k, used in pairs(st.graphUsed) do
				if used < age then
					owner, oldest, age = st, k, used
				end
			end
		end
		if not owner or not oldest then
			break
		end
		for _, id in ipairs(owner.nodes[oldest]) do
			owner.ncell[id], owner.nlayer[id], owner.ncomp[id], owner.nadj[id] = nil, nil, nil, nil
		end
		graphKB = graphKB - owner.graphSize[oldest]
		owner.nodes[oldest], owner.graphUsed[oldest], owner.graphSize[oldest] = nil, nil, nil
	end
end

local function decodeGraph(st, k)
	slice()
	if st.nodes[k] then
		return st.nodes[k]
	end
	trimGraphs()
	local ids = {}
	st.nodes[k] = ids
	local chunks = st.D.graph[k + 1]
	if not chunks then
		return ids
	end
	local s = chunks
	local n, pos = num(s, 1, 2), 3
	st.graphSize[k] = (n * 288 + 128) / 1024
	graphKB = graphKB + st.graphSize[k]
	local degree = {}
	for i = 0, n - 1 do
		local id = k * 4096 + i
		ids[i + 1] = id
		degree[i + 1] = B64[byte(s, pos + 6)]
		pos = pos + 7
	end
	for i = 1, n do
		st.nadj[ids[i]] = pos
		pos = pos + degree[i] * 7
	end
	return ids
end

local function nodesOf(st, k)
	local nodes = st.nodes[k] or decodeGraph(st, k)
	if st.graphSize[k] then
		graphClock = graphClock + 1
		st.graphUsed[k] = graphClock
	end
	return nodes
end

local function metadata(st, id)
	if st.ncell[id] == nil then
		local s, pos = st.D.graph[floor(id / 4096) + 1], 3 + (id % 4096) * 7
		st.ncell[id], st.nlayer[id], st.ncomp[id] = num(s, pos, 3), B64[byte(s, pos + 3)], num(s, pos + 4, 2)
	end
	return st.ncell[id], st.nlayer[id], st.ncomp[id]
end

-- Most entrances in a visited cluster are never expanded. Decode their edges only when needed.
local function adjacent(st, id)
	local adj = st.nadj[id]
	if type(adj) == "number" then
		local k, pos = floor(id / 4096), adj
		local s = st.D.graph[k + 1]
		adj = {}
		for e = 1, B64[byte(s, 9 + (id % 4096) * 7)] do
			local offset = B64[byte(s, pos)]
			local target = k + (floor(offset / 3) - 1) * st.ny + offset % 3 - 1
			adj[e * 3 - 2] = target * 4096 + num(s, pos + 1, 2)
			adj[e * 3 - 1] = num(s, pos + 3, 2)
			adj[e * 3] = num(s, pos + 5, 2)
			pos = pos + 7
		end
		st.nadj[id] = adj
		local capacity = 1
		while capacity < #adj do
			capacity = capacity * 2
		end
		local size = (64 + capacity * 16) / 1024
		st.graphSize[k], graphKB = st.graphSize[k] + size, graphKB + size
	end
	return adj
end

-- An entrance's node in its cluster.
local function entrance(st, id)
	local k = floor(id / 4096)
	if not st.nodes[k] then
		nodesOf(st, k)
	end
	local cell, layer = metadata(st, id)
	grid(st, k)
	return surface(st, k, cell, layer)
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

-- Grid search inside one cluster, entering water costing swim times its length. tree holds g/parent keyed by
-- node + 1. With goal set it is A*, otherwise Dijkstra that stops once every node in targets (a set of nodes) is
-- settled.
local function Tree()
	return { g = {}, par = {}, stamp = {}, closed = {}, gen = 0 }
end
-- sift: long-function - one grid search loop; splitting moves its retained arrays to upvalues on the hot path
local function search(st, k, swim, source, tree, goal, targets, left)
	local val = grid(st, k)
	-- Search only enters populated grids, through snapped endpoints or decoded entrances.
	---@cast val number[]
	-- A paused search retains these arrays even if another job evicts its cluster.
	local m, z, at, links = st.moves[k], st.z[k], st.at[k], st.links[k]
	local C, cs = st.C, st.cs
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

	---@type number, number, number, number
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
				for e = 1, #l do
					local d = l[e] % 8
					local tx, ty = ux + DX[d], uy + DY[d]
					if tx >= 0 and ty >= 0 and tx < C and ty < C then
						local v = surface(st, k, tx * C + ty, floor(l[e] / 8) - 1, z[i], val, z, at)
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
		local val = tk == k and grid(st, k)
		-- Most string-pulling steps stay on one base grid. Its decoded moves already check the
		-- same detours; only a dry diagonal beside water needs the stricter surface checks below.
		if
			val
			and (
				water
				or (
					val[node + 1] ~= 2
					and val[tlc + 1] ~= 2
					and (dx == 0 or dy == 0 or (val[node + dx * C + 1] ~= 2 and val[node + dy + 1] ~= 2))
				)
			)
		then
			local m = st.moves[k]
			if dy == 0 then
				open = m[(dx > 0 and node or tlc) + 1] % 2 == 1
			elseif dx == 0 then
				open = m[(dy > 0 and node or tlc) + 1] % 4 >= 2
			elseif dx == dy then
				open = m[(dx > 0 and node or tlc) + 1] % 8 >= 4
			else
				open = m[(dx > 0 and node or tlc) + 1] % 16 >= 8
			end
		elseif dx == 0 or dy == 0 then
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
	for e = 1, #l do
		if l[e] % 8 == d then
			grid(st, tk)
			local v = surface(st, tk, tlc, floor(l[e] / 8) - 1, h)
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

-- Endpoint searches: grid Dijkstra to the cluster's entrances (and the other endpoint when they share it).
local function endpoint(st, swim, tree, k, node, others)
	local targets, left = {}, 0
	for _, id in ipairs(nodesOf(st, k)) do
		local e = entrance(st, id)
		if e and not targets[e] then
			targets[e], left = true, left + 1
		end
	end
	for other in pairs(others or {}) do
		if not targets[other] then
			targets[other], left = true, left + 1
		end
	end
	search(st, k, swim, node, tree, nil, targets, left)
end
-- An endpoint on a rooftop or ledge the grid cannot leave moves to the nearest node that reaches an entrance,
-- down a ledge but never up one or onto another level.
local function settle(st, swim, tree, k, node)
	local C = st.C
	endpoint(st, swim, tree, k, node)
	local function connected()
		for _, id in ipairs(nodesOf(st, k)) do
			local e = entrance(st, id)
			if e and reached(tree, e) then
				return true
			end
		end
		return false
	end
	if connected() then
		return node
	end
	local tries = 0
	grid(st, k)
	local h = st.z[k][node + 1]
	local cell = cellOf(st, k, node)
	local lx, ly = floor(cell / C), cell % C
	for r = 1, SNAP do
		for dx = -r, r do
			for dy = -r, r do
				if tries >= RETRIES then
					return node
				end
				local x, y = lx + dx, ly + dy
				local ring = dx == r or dx == -r or dy == r or dy == -r
				if ring and x >= 0 and y >= 0 and x < C and y < C then
					local near = standing(st, k, x * C + y, h)
					local rise = near and st.z[k][near + 1] - h
					if near and rise <= ZTOL and rise >= -DROP and not reached(tree, near) then
						tries, node = tries + 1, near
						endpoint(st, swim, tree, k, node)
						if connected() then
							return node
						end
					end
				end
			end
		end
	end
	return node
end

-- Both APIs connect endpoints with the same local search. Connections are outward at both ends, as in the
-- baked undirected graph; the same-cluster direct edge retains the grid's entering-water direction.
local function connections(st, tree, k)
	local edges = {}
	for _, id in ipairs(nodesOf(st, k)) do
		local e = entrance(st, id)
		if e and reached(tree, e) then
			edges[id] = tree.g[e + 1]
		end
	end
	return edges
end

local function pointNode(st, point)
	local k, node = locate(st, point.x, point.y)
	if not k then
		return nil, nil, "outside"
	end
	node = snap(st, k, node, point.x, point.y, point.z)
	return k, node, not node and "offmesh" or nil
end

-- Fixed places recur in both batches and in later journeys. Keep their small entrance-cost vectors, not the
-- grid trees; cap the cache so moving start positions cannot grow it for the entire play session.
local function connect(st, swim, k, node)
	nodesOf(st, k)
	local key = k .. ":" .. node .. ":" .. swim
	local entry = st.ends[key]
	if not entry then
		local tree = Tree()
		node = settle(st, swim, tree, k, node)
		entry = { node = node, edges = connections(st, tree, k), tree = tree }
		-- A handful of local trees removes repeated endpoint searches without retaining a continent's grids.
		st.endTrees = st.endTrees or {}
		st.endTrees[#st.endTrees + 1] = entry
		if #st.endTrees > 8 then
			table.remove(st.endTrees, 1).tree = nil
		end
		if st.endCount >= 256 then
			st.ends, st.endCount = {}, 0
		end
		st.ends[key], st.endCount = entry, st.endCount + 1
	end
	return entry.node, entry.edges, entry.tree
end
-- sift: long-function - sliced A* and refinement share scratch trees; splitting adds hot-path calls and upvalues
local function run(map, from, to, waterWalking, costOnly)
	local st = State(map)
	if not st then
		return nil, "nodata"
	end
	-- Walking on water is running, so the search weights water by 1 and reads each edge's second cost.
	local swim, cost2 = st.swim, 1
	if waterWalking then
		swim, cost2 = 1, 2
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

	local S, G = trees.S, trees.G
	local source, target, sourceTree, targetTree
	sc, source, sourceTree = connect(st, swim, sk, sc)
	gc, target, targetTree = connect(st, swim, gk, gc)
	local key = table.concat({ sk, sc, gk, gc, swim }, ":")
	st.paths = st.paths or {}
	local cached = st.paths[key]
	local hops, cost
	local x0, y0, cs = st.x0, st.y0, st.cs
	if cached then
		hops, cost = cached.hops, cached.cost
	else
		local direct
		if sk == gk and search(st, sk, swim, sc, S, gc) then
			direct = S.g[gc + 1]
		end

		local comps, shared = {}, false
		for id in pairs(source) do
			nodesOf(st, floor(id / 4096))
			local _, _, component = metadata(st, id)
			comps[component] = true
		end
		for id in pairs(target) do
			nodesOf(st, floor(id / 4096))
			local _, _, component = metadata(st, id)
			shared = shared or comps[component]
		end
		if not direct and not shared then
			return nil, "unreachable"
		end

		-- Abstract A* from START to GOAL through the entrance graph.
		local function world(id)
			local k, lc = floor(id / 4096), metadata(st, id)
			return x0 + (floor(k / st.ny) * C + floor(lc / C) + 0.5) * cs, y0 + ((k % st.ny) * C + lc % C + 0.5) * cs
		end
		-- Rounded graph edges and snapping must not let the heuristic overstate the remaining cost.
		local goalCell = cellOf(st, gk, gc)
		local goalX = x0 + (floor(gk / st.ny) * C + floor(goalCell / C) + 0.5) * cs
		local goalY = y0 + (gk % st.ny * C + goalCell % C + 0.5) * cs
		local lower = max(0, 1 - 0.5 / cs)
		local function h(id)
			local x, y = world(id)
			local dx, dy = abs(x - goalX), abs(y - goalY)
			return (dx > dy and dx + (SQRT2 - 1) * dy or dy + (SQRT2 - 1) * dx) * lower
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
		for id, distance in pairs(source) do
			relax(id, distance, START)
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
				if target[u] then
					relax(GOAL, gu + target[u], u)
				end
				nodesOf(st, floor(u / 4096))
				local adj = adjacent(st, u)
				for e = 1, #adj, 3 do
					local v = adj[e]
					if aclosed[v] ~= gen then
						nodesOf(st, floor(v / 4096))
						relax(v, gu + adj[e + cost2], u)
					end
				end
			end
		end
		if not found then
			return nil, "unreachable"
		end
		cost = ag[GOAL]
		hops = { GOAL }
		while hops[#hops] ~= START do
			hops[#hops + 1] = apar[hops[#hops]]
		end

		if (st.pathCount or 0) >= 16 then
			st.paths, st.pathCount = {}, 0
		end
		st.paths[key] = { hops = hops, cost = cost }
		st.pathCount = (st.pathCount or 0) + 1
	end
	if costOnly then
		return cost
	end

	-- Refine each hop into nodes with their global cells and a running count of water nodes.
	local P = { x = {}, y = {}, w = {}, k = {}, n = {} }
	local function add(k, node)
		local n = #P.x
		if n == 0 or P.k[n] ~= k or P.n[n] ~= node then
			local cell = node < C * C and node or cellOf(st, k, node)
			P.x[n + 1], P.y[n + 1] = floor(k / st.ny) * C + floor(cell / C), (k % st.ny) * C + cell % C
			P.k[n + 1], P.n[n + 1] = k, node
			P.w[n + 1] = (P.w[n] or 0) + ((st.val[k] or grid(st, k))[node + 1] == 2 and 1 or 0)
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
			search(st, sk, swim, sc, S, gc)
			local nodes = trace(S, gc, {})
			addAll(sk, nodes, #nodes, 1, -1)
		elseif a == START then
			local tree = sourceTree
			if not tree or not reached(tree, entrance(st, b)) then
				search(st, sk, swim, sc, S, entrance(st, b))
				tree = S
			end
			local nodes = trace(tree, entrance(st, b), {})
			addAll(sk, nodes, #nodes, 1, -1)
		elseif b == GOAL then
			local tree = targetTree
			if not tree or not reached(tree, entrance(st, a)) then
				search(st, gk, swim, gc, G, entrance(st, a))
				tree = G
			end
			local nodes = trace(tree, entrance(st, a), {})
			addAll(gk, nodes, 1, #nodes, 1)
		else
			local ka, kb = floor(a / 4096), floor(b / 4096)
			local ea, eb = entrance(st, a), entrance(st, b)
			if ka == kb and search(st, ka, swim, ea, R, eb) then
				local nodes = trace(R, eb, {})
				addAll(ka, nodes, #nodes, 1, -1)
			else -- neighbouring entrances across a cluster border
				add(ka, ea)
				add(kb, eb)
			end
		end
	end

	-- Points carry the height of the surface they stand on; the cost weights water as the search did, and points.wet
	-- is the yards over water, which call for Water Walking.
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
	local wetYards = 0
	for i = 2, #points do
		local p, q = keep[i - 1], keep[i]
		local wet = q > p and (P.w[q] - P.w[p]) / (q - p) or 0
		local length = sqrt((points[i].x - points[i - 1].x) ^ 2 + (points[i].y - points[i - 1].y) ^ 2)
		wetYards = wetYards + length * wet
	end
	points.wet = wetYards
	-- Smoothing only changes drawing: planning and FindMany use the identical graph cost.
	return points, cost
end

-- Lazy terminal-node connections let nearby targets settle without first searching every faraway endpoint.
-- sift: long-function - one sliced Dijkstra owns the heap swap and frontier locals across endpoint searches
local function runMany(map, from, targets, waterWalking, reverse, job)
	local costs = job and job.costs or {}
	local function failed(reason)
		for i = 1, #targets do
			costs[i] = false
		end
		return costs, reason
	end
	local st = State(map)
	if not st then
		return failed("nodata")
	end
	local sk, sc, reason = pointNode(st, from)
	if not sc then
		return failed(reason)
	end
	if job then
		job.valid, job.sourceCluster, job.sourceNode = true, sk, sc
		for i, point in ipairs(targets) do
			if point.x == from.x and point.y == from.y then
				local k, node = pointNode(st, point)
				if k == sk and node == sc then
					costs[i] = 0
					job.revision = job.revision + 1
				end
			end
		end
		-- Publish endpoint validity before doing local Dijkstra work. Invalid goals and co-located
		-- transfers can then settle without launching speculative walks across the continent.
		if job.progress then
			yield()
		end
	end
	local swim, cost2 = waterWalking and 1 or st.swim, waterWalking and 2 or 1
	local source, sourceTree
	sc, source, sourceTree = connect(st, swim, sk, sc)
	local clusters, links, dist, closed, left = {}, {}, {}, {}, #targets
	for i, point in ipairs(targets) do
		local k = locate(st, point.x, point.y)
		if costs[i] ~= nil then
			left = left - 1
		elseif k then
			clusters[k] = clusters[k] or {}
			clusters[k][#clusters[k] + 1] = i
		else
			costs[i], left = false, left - 1
		end
	end
	hn = 0
	local function relax(id, cost)
		if not dist[id] or cost < dist[id] then
			dist[id] = cost
			push(cost, id)
		end
	end
	local function prepare(k)
		local list = clusters[k]
		if not list then
			return
		end
		clusters[k] = nil
		-- Local searches need their own heap, including across a yield midway through a connection.
		local keys, values, size = hk, hv, hn
		hk, hv, hn = {}, {}, 0
		local direct, ends = {}, {}
		for _, i in ipairs(list) do
			local _, node = pointNode(st, targets[i])
			if node then
				local edges, tree
				node, edges, tree = connect(st, swim, k, node)
				ends[i] = edges
				if k == sk then
					local first, last = reverse and node or sc, reverse and sc or node
					if not reverse then
						tree = sourceTree
					end
					if first == last then
						direct[i] = 0
					elseif tree and reached(tree, last) then
						direct[i] = tree.g[last + 1]
					elseif search(st, k, swim, first, trees.R, last) then
						direct[i] = trees.R.g[last + 1]
					end
				end
			else
				costs[i], left = false, left - 1
				if job then
					job.revision = job.revision + 1
				end
			end
		end
		hk, hv, hn = keys, values, size
		for i, cost in pairs(direct) do
			relax(-i, cost)
		end
		for i, edges in pairs(ends) do
			for id, cost in pairs(edges) do
				links[id] = links[id] or {}
				local joined = links[id]
				joined[#joined + 1], joined[#joined + 2] = -i, cost
			end
		end
	end
	prepare(sk)
	for id, cost in pairs(source) do
		relax(id, cost)
	end
	while hn > 0 and left > 0 do
		-- Until the popped node's outgoing edges are relaxed, its key still bounds the frontier.
		if job then
			job.radius = hk[1]
		end
		local u = pop()
		if not closed[u] then
			closed[u] = true
			if u < 0 then
				costs[-u], left = dist[u], left - 1
				if job then
					job.revision = job.revision + 1
				end
			else
				local k = floor(u / 4096)
				prepare(k)
				local ends = links[u]
				for i = 1, ends and #ends or 0, 2 do
					relax(ends[i], dist[u] + ends[i + 1])
				end
				nodesOf(st, k)
				local adj = adjacent(st, u)
				for e = 1, #adj, 3 do
					local v = adj[e]
					if not closed[v] then
						relax(v, dist[u] + adj[e + cost2])
					end
				end
			end
		end
		if job then
			job.radius = hn > 0 and hk[1] or huge
		end
		tick()
	end
	for i = 1, #targets do
		if costs[i] == nil then
			costs[i] = false
		end
	end
	return costs
end

-- Eight-direction grid distance is a lower bound even across clusters. Costs omit snapping and height
-- and round each abstract edge to yards. Each endpoint can snap
-- SNAP cells and then move SNAP more off a ledge; each nonzero grid step is at least cs before rounding.
-- This bound is in running yards for both water modes, before the planner divides by walkSpeed.
---@param map number
---@param from SPFPoint
---@param to SPFPoint
---@return number
function Path.LowerBound(map, from, to)
	---@type SPFNavData?
	local D = ShortestPathForeverPathData and ShortestPathForeverPathData[map]
	-- Unloaded maps need no synchronous addon load just to publish an admissible preview.
	if not D then
		return 0
	end
	local cs = TILE / D.cells
	local dx, dy = abs(from.x - to.x), abs(from.y - to.y)
	local gap = dx > dy and dx + (SQRT2 - 1) * dy or dy + (SQRT2 - 1) * dx
	return max(0, gap - (4 * SNAP + 1) * SQRT2 * cs) * max(0, 1 - 0.5 / cs)
end

---@param job SPFPathJob?
---@param point SPFPoint
---@return boolean
function Path.ReuseMany(job, point)
	if not job or job.map ~= point.map or not job.sourceNode then
		return false
	end
	local from = job.from
	if (from.x - point.x) ^ 2 + (from.y - point.y) ^ 2 > 9 or (from.z and point.z and abs(from.z - point.z) > ZTOL) then
		return false
	end
	local st = State(job.map)
	local k, node = pointNode(st, point)
	return k == job.sourceCluster and node == job.sourceNode
end

local function start(job)
	if job.notify then
		local owner = job.owner
		if not owner.cancelled then
			job.notify(job.points, job.cost, owner)
		end
		return
	end
	expansions = 0
	if job.targets then
		return runMany(job.map, job.from, job.targets, job.waterWalking, job.reverse, job)
	end
	return run(job.map, job.from, job.to, job.waterWalking, job.costOnly)
end

local spare
local function scratch(saved)
	local previous = { hk, hv, hn, trees, ag, apar, astamp, aclosed, agen }
	if not saved and spare then
		saved, spare = spare, nil
		saved[3] = 0
	end
	if saved then
		hk, hv, hn, trees = saved[1], saved[2], saved[3], saved[4]
		ag, apar, astamp, aclosed, agen = saved[5], saved[6], saved[7], saved[8], saved[9]
	else
		hk, hv, hn = {}, {}, 0
		trees = { S = Tree(), G = Tree(), R = Tree() }
		ag, apar, astamp, aclosed, agen = {}, {}, {}, {}, 0
	end
	return previous
end

-- Synchronous search, for tests and tools. Returns points, cost (or nil, reason) and the expansion count.
---@param map number
---@param from SPFPoint
---@param to SPFPoint
---@param waterWalking? boolean
function Path.FindSync(map, from, to, waterWalking)
	deadline, ops = huge, 0
	local job = { map = map, from = from, to = to, waterWalking = waterWalking }
	local co = coroutine.create(start)
	local saved = scratch()
	local ok, points, cost = coroutine.resume(co, job)
	scratch(saved)
	if not ok then
		error(points)
	end
	return points, cost, expansions
end

-- Costs indexed like targets, false for unreachable/off-mesh points; no geometry is built. reverse returns
-- target -> from costs, including the directed same-cluster water step. The shipped abstract edges are symmetric.
---@param map number
---@param from SPFPoint
---@param targets SPFPoint[]
---@param waterWalking? boolean
---@param reverse? boolean
function Path.FindManySync(map, from, targets, waterWalking, reverse)
	deadline, ops, expansions = huge, 0, 0
	local saved = scratch()
	local costs, reason = runMany(map, from, targets, waterWalking, reverse)
	scratch(saved)
	return costs, reason, expansions
end

-- Round-robin slices share one frame budget, including callbacks that replan from newly settled costs.
local queue = {}
local scheduled = false
local pump, combatWait

local function notify(job, callback, points, cost)
	if callback then
		table.insert(queue, 1, {
			co = coroutine.create(start),
			notify = callback,
			owner = job,
			points = points,
			cost = cost,
			frames = 0,
			cpu = 0,
		})
	end
end

local function schedule()
	if not scheduled and #queue > 0 then
		scheduled = true
		Path.after(pump)
	end
end

pump = function()
	scheduled = false
	if InCombatLockdown and InCombatLockdown() then
		if not combatWait then
			combatWait = CreateFrame("Frame")
			combatWait:SetScript("OnEvent", function(self)
				self:UnregisterEvent("PLAYER_REGEN_ENABLED")
				schedule()
			end)
		end
		combatWait:RegisterEvent("PLAYER_REGEN_ENABLED")
		return
	end
	local finish = clock() + Path.budget
	repeat
		local job = table.remove(queue, 1)
		if not job then
			break
		end
		local t0 = clock()
		deadline, ops = math.min(finish, t0 + (not job.notify and #queue > 0 and Path.budget / 2 or Path.budget)), 0
		expansions = job.expansions or 0
		local saved = scratch(job.scratch)
		local ok, points, cost = coroutine.resume(job.co, job)
		job.scratch = scratch(saved)
		job.expansions = expansions
		job.frames = job.frames + 1
		job.cpu = job.cpu + clock() - t0
		deadline = huge
		if not ok or coroutine.status(job.co) == "dead" then
			if not job.targets and not job.notify then
				spare = job.scratch
			end
			job.done, job.scratch, job.co = true, nil, nil
			if not ok then
				geterrorhandler()(points)
				points, cost = nil, "error"
			end
			if not job.cancelled then
				notify(job, job.callback, points, cost)
			end
		else
			if points == "load" then
				finish = 0
			end
			if job.notify then
				table.insert(queue, 1, job)
			else
				queue[#queue + 1] = job
			end
			if job.progress then
				notify(job, job.progress, job.costs)
			end
		end
	until clock() >= finish
	if #queue == 0 then
		-- Exact endpoint costs survive; decoded grids and local trees are only useful during active work.
		for _, st in pairs(states) do
			for _, entry in ipairs(st.endTrees or {}) do
				entry.tree = nil
			end
			st.endTrees = nil
			for k in pairs(st.used) do
				evict(st, k)
			end
		end
		spare = nil
		trimGraphs()
	end
	schedule()
end

-- Next-frame scheduling; tests replace it.
---@param fn fun()
function Path.after(fn)
	C_Timer.After(0, fn)
end

-- Search coroutine-sliced over frames between two { x, y, z } points (z optional: it picks the floor to start or end
-- on). callback(points, cost, job) or callback(nil, reason, job): points are { map, x, y, z } from the start to the
-- goal, with points.wet the drawn yards over water. Cost is the abstract route in running yards, not the smoothed
-- polyline length; a swum grid yard counts as the
-- data's swim (so routes keep out of water) unless waterWalking, when water is ground. reason is "nodata",
-- "outside", "offmesh", "unreachable" or "error". Returns a handle for Path.Cancel.
---@param map number
---@param from SPFPoint
---@param to SPFPoint
---@param callback fun(points: SPFWalkPoints?, cost: number|string, job: SPFPathJob)
---@param waterWalking? boolean
---@return SPFPathJob
function Path.Find(map, from, to, callback, waterWalking)
	local job = {
		map = map,
		from = from,
		to = to,
		waterWalking = waterWalking,
		callback = callback,
		co = coroutine.create(start),
		frames = 0,
		cpu = 0,
	}
	queue[#queue + 1] = job
	schedule()
	return job
end

-- A candidate can be ruled in or out without refining all its intermediate clusters into drawing points.
-- callback(cost, reason, job) uses the same exact graph cost as Find and FindMany.
---@param map number
---@param from SPFPoint
---@param to SPFPoint
---@param callback fun(cost: number?, reason: string?, job: SPFPathJob)
---@param waterWalking? boolean
---@return SPFPathJob
function Path.FindCost(map, from, to, callback, waterWalking)
	local job = Path.Find(map, from, to, callback, waterWalking)
	job.costOnly = true
	return job
end

-- callback(costs, reason, job) completes once; optional progress(costs, nil, job) runs after each slice.
-- costs[i] is nil until settled, an exact running-yard cost afterwards, or false when unreachable. job.radius
-- bounds every unsettled target, including a popped entrance whose expansion has not finished. Pause/Resume
-- retain the frontier. Missing data or an invalid source completes with all false plus a reason.
---@param map number
---@param from SPFPoint
---@param targets SPFPoint[]
---@param callback fun(costs: (number|false)[], reason: string?, job: SPFPathJob)
---@param waterWalking? boolean
---@param reverse? boolean
---@param progress? fun(costs: (number|false)[], reason: nil, job: SPFPathJob)
---@return SPFPathJob
function Path.FindMany(map, from, targets, callback, waterWalking, reverse, progress)
	local job = {
		map = map,
		from = from,
		targets = targets,
		waterWalking = waterWalking,
		reverse = reverse,
		progress = progress,
		costs = {},
		radius = 0,
		revision = 0,
		callback = callback,
		co = coroutine.create(start),
		frames = 0,
		cpu = 0,
	}
	queue[#queue + 1] = job
	schedule()
	return job
end

-- Paused batches retain their settled costs and frontier for later replans, without consuming frames.
---@param job SPFPathJob
function Path.Pause(job)
	job.paused = true
	for i = #queue, 1, -1 do
		local queued = queue[i]
		if queued == job or queued.owner == job then
			table.remove(queue, i)
		end
	end
end

---@param job SPFPathJob
function Path.Resume(job)
	if job.paused and not job.done and not job.cancelled then
		job.paused = false
		job.co = job.co or coroutine.create(start)
		queue[#queue + 1] = job
		schedule()
	end
end

-- A proved journey needs the exact costs and validity/bounds, not a suspended Dijkstra stack.
-- If a later timetable exposes another alternative, Resume rebuilds only the missing frontier.
---@param job SPFPathJob
function Path.ReleaseMany(job)
	Path.Pause(job)
	job.co, job.scratch, job.callback, job.progress = nil, nil, nil, nil
end

function Path.ClearCaches()
	-- Cancellation removes a journey's jobs first; never invalidate another active search's grids.
	if #queue > 0 then
		return
	end
	states, spare = {}, nil
	decodedKB, decodedCount, graphKB = 0, 0, 0
end

---@param job SPFPathJob
function Path.Cancel(job)
	Path.Pause(job)
	job.cancelled, job.scratch, job.co = true, nil, nil
end

-- The walkable height at a global cell nearest height h, within ZTOL.
---@param map number
---@return boolean
function Path.HasData(map)
	if ShortestPathForeverPathData and ShortestPathForeverPathData[map] then
		return true
	end
	return not tried[map]
			and C_AddOns
			and C_AddOns.DoesAddOnExist
			and C_AddOns.DoesAddOnExist("ShortestPathForever_Nav" .. map)
		or false
end
