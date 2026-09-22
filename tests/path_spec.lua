local ns = {}
assert(loadfile("ShortestPathForever_Nav0/Nav0.lua"))()
assert(loadfile("Path.lua"))("ShortestPathForever", ns)
local Path = ns.Path

local frames = {}
Path.after = function(fn)
	frames[#frames + 1] = fn
end
local function drain()
	local n = 0
	while #frames > 0 do
		table.remove(frames, 1)()
		n = n + 1
	end
	return n
end

local function dist(ax, ay, bx, by)
	return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end

-- Nearest approach of the polyline to a point.
local function passes(points, x, y)
	local best = math.huge
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local dx, dy = b.x - a.x, b.y - a.y
		local len2 = dx * dx + dy * dy
		local t = len2 > 0 and math.max(0, math.min(1, ((x - a.x) * dx + (y - a.y) * dy) / len2)) or 0
		best = math.min(best, dist(a.x + t * dx, a.y + t * dy, x, y))
	end
	return best
end

local GOLDSHIRE = { x = -9459, y = 43 }
local NORTHSHIRE = { x = -8914, y = -135 }
local STORMWIND_FM = { x = -8840.56, y = 489.7 } -- Data/Taxi.lua node 2

-- Goldshire to Stormwind goes round by the gate, not over the wall or through the moat.
local pts, len = Path.FindSync(0, GOLDSHIRE, STORMWIND_FM)
assert(pts, len)
local straight = dist(GOLDSHIRE.x, GOLDSHIRE.y, STORMWIND_FM.x, STORMWIND_FM.y)
assert(len > straight * 1.3 and len < 1300, len)
assert(passes(pts, -9068, 417) < 30, "misses the gate")
assert(pts[1].x == GOLDSHIRE.x and pts[#pts].y == STORMWIND_FM.y and pts[1].map == 0)

pts, len = Path.FindSync(0, NORTHSHIRE, GOLDSHIRE)
assert(pts and len > 580 and len < 700, len)

-- A rooftop endpoint moves to the street below instead of failing.
assert(Path.FindSync(0, { x = -9010, y = 870 }, STORMWIND_FM))

local none, why = Path.FindSync(0, { x = 0, y = 6000 }, GOLDSHIRE)
assert(none == nil and why == "outside", why)
none, why = Path.FindSync(1, { x = 0, y = 0 }, { x = 1, y = 1 })
assert(none == nil and why == "nodata", why)
assert(Path.HasData(0) and not Path.HasData(1))

-- The sliced search gives the sync result and spreads over frames.
local got, gotLen, gotJob
local job = Path.Find(0, GOLDSHIRE, STORMWIND_FM, function(p, l, j)
	got, gotLen, gotJob = p, l, j
end)
Path.budget = 0.05
drain()
Path.budget = 3
local syncPts, syncLen = Path.FindSync(0, GOLDSHIRE, STORMWIND_FM)
assert(gotJob == job and job.frames > 1, job.frames)
assert(math.abs(gotLen - syncLen) < 1e-6 and #got == #syncPts)

local cancelled = false
local first = Path.Find(0, NORTHSHIRE, GOLDSHIRE, function()
	cancelled = true
end)
Path.Cancel(first)
drain()
assert(not cancelled)

-- Cancelling a partially searched route frees the next frame for its replacement.
Path.budget = -1
local abandoned = Path.Find(0, GOLDSHIRE, STORMWIND_FM, function()
	error("cancelled search called back")
end)
table.remove(frames, 1)()
assert(abandoned.frames == 1 and coroutine.status(abandoned.co) == "suspended")
Path.Cancel(abandoned)
local replacement = Path.Find(0, NORTHSHIRE, GOLDSHIRE, function(p)
	assert(p)
end)
table.remove(frames, 1)()
assert(replacement.frames == 1 and abandoned.frames == 1, "cancelled work must not hold up the queue")
Path.budget = 3
drain()

-- A coroutine error reports a terminal result and leaves subsequent jobs runnable.
local previousHandler, reported, failure = rawget(_G, "geterrorhandler")
rawset(_G, "geterrorhandler", function()
	return function(message)
		reported = message
	end
end)
local failed = Path.Find(0, { x = "invalid", y = 0 }, GOLDSHIRE, function(p, reason, finished)
	assert(p == nil and reason == "error")
	assert(not failure, "a failed job completes only once")
	failure = finished
end)
local recovered
Path.Find(0, NORTHSHIRE, GOLDSHIRE, function(p)
	recovered = p
end)
drain()
rawset(_G, "geterrorhandler", previousHandler)
assert(reported and failure == failed and recovered, "errors must not strand Journey's pending count")

-- Coordinates: the navmesh stands where the addon's pins stand (UnitPosition frame, x north, y west).
-- Taxi.lua Stormwind flight master and Transports.lua tram pin, each with a nearby street point.
for _, pin in ipairs({ { -8840.56, 489.7, 0, -20 }, { -8346.46, 514.031, 8, 0 } }) do
	local p = Path.FindSync(0, { x = pin[1], y = pin[2] }, { x = pin[1] + pin[3], y = pin[2] + pin[4] })
	assert(p, "no mesh at pin " .. pin[1] .. "," .. pin[2])
end

-- Levels: a road through a tunnel under walkable ground, and a city under a city.
-- Ironforge to Menethil goes through Dun Algaz rather than round by Arathi (about 18,600 yards on one level).
local IRONFORGE_FM = { x = -4821.78, y = -1155.44, z = 502.21 } -- Data/Taxi.lua node 6
local MENETHIL_FM = { x = -3792.26, y = -783.29, z = 9.06 } -- node 7
pts, len = Path.FindSync(0, IRONFORGE_FM, MENETHIL_FM)
assert(pts and len < 8000, len)
assert(passes(pts, -4220, -2464) < 30, "misses the Dun Algaz tunnel")
assert(pts[1].z and pts[#pts].z, "points carry heights")

-- Undercity: the flight master stands by the west lift's bottom landing, and its top is a long way round on foot.
local UNDERCITY_FM = { x = 1568.62, y = 267.97, z = -43.1 } -- node 11
local WEST_LIFT = { x = 1596.15, y = 291.8 } -- Data/Transports.lua docks 1009 (top) and 1010 (bottom)
local _, near = Path.FindSync(0, UNDERCITY_FM, { x = WEST_LIFT.x, y = WEST_LIFT.y, z = -40.784 })
local _, far = Path.FindSync(0, UNDERCITY_FM, { x = WEST_LIFT.x, y = WEST_LIFT.y, z = 55.718 })
assert(type(near) == "number" and near < 150, near)
assert(type(far) == "number" and far > 1000, far)
-- From the top, the surface road leads on to Tarren Mill.
assert(Path.FindSync(0, { x = WEST_LIFT.x, y = WEST_LIFT.y, z = 55.718 }, { x = -0.06, y = -859.91, z = 58.83 }))

-- Across Loch Modan: on foot the walk goes round by the shore, walking on water it goes straight over.
local THELSAMAR_SHORE, WEST_SHORE = { x = -5293, y = -3157 }, { x = -5773, y = -3287 }
local round, roundCost = Path.FindSync(0, THELSAMAR_SHORE, WEST_SHORE)
local over, overCost = Path.FindSync(0, THELSAMAR_SHORE, WEST_SHORE, true)
assert(round and over)
assert(round.wet < 50 and over.wet > 300, round.wet .. " " .. over.wet)
assert(overCost < 550 and roundCost > overCost * 1.4, roundCost .. " " .. overCost)

-- The reported Darkshore route: reachable Felwood points go round the mountains; neighbouring map clicks can
-- miss every walkable surface. Both outcomes must arrive through the sliced callback as well as FindSync.
assert(loadfile("ShortestPathForever_Nav1/Nav1.lua"))()
local AUBERDINE = { x = 6341.38, y = 557.68, z = 16.29 }
for _, target in ipairs({
	{ x = 5068.4, y = -337.22 },
	{ x = 6205.88, y = -1949.63 },
	{ x = 5000, y = -2000 },
	{ x = 5500, y = -1500 },
	{ x = 4800, y = -1200 },
}) do
	local expected, cost = Path.FindSync(1, AUBERDINE, target)
	local done
	Path.Find(1, AUBERDINE, target, function(p, c)
		done = true
		assert(c == cost and (p and #p) == (expected and #expected))
		if p then
			assert(#p > 2 and c > dist(AUBERDINE.x, AUBERDINE.y, target.x, target.y) * 2)
		else
			assert(c == "offmesh")
		end
	end)
	drain()
	assert(done)
end

print("path_spec ok")
