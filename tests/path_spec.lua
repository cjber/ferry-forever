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

local GOLDSHIRE = { -9459, 43 }
local NORTHSHIRE = { -8914, -135 }
local STORMWIND_FM = { -8840.56, 489.7 } -- Data/Taxi.lua node 2

-- Goldshire to Stormwind goes round by the gate, not over the wall or through the moat.
local pts, len = Path.FindSync(0, GOLDSHIRE[1], GOLDSHIRE[2], STORMWIND_FM[1], STORMWIND_FM[2])
assert(pts, len)
local straight = dist(GOLDSHIRE[1], GOLDSHIRE[2], STORMWIND_FM[1], STORMWIND_FM[2])
assert(len > straight * 1.3 and len < 1300, len)
assert(passes(pts, -9068, 417) < 30, "misses the gate")
assert(pts[1].x == GOLDSHIRE[1] and pts[#pts].y == STORMWIND_FM[2] and pts[1].map == 0)

pts, len = Path.FindSync(0, NORTHSHIRE[1], NORTHSHIRE[2], GOLDSHIRE[1], GOLDSHIRE[2])
assert(pts and len > 580 and len < 700, len)

-- A rooftop endpoint moves to the street below instead of failing.
assert(Path.FindSync(0, -9010, 870, STORMWIND_FM[1], STORMWIND_FM[2]))

local none, why = Path.FindSync(0, 0, 6000, GOLDSHIRE[1], GOLDSHIRE[2])
assert(none == nil and why == "outside", why)
none, why = Path.FindSync(1, 0, 0, 1, 1)
assert(none == nil and why == "nodata", why)
assert(Path.HasData(0) and not Path.HasData(1))

-- The sliced search gives the sync result and spreads over frames.
local got, gotLen, gotJob
local job = Path.Find(0, GOLDSHIRE[1], GOLDSHIRE[2], STORMWIND_FM[1], STORMWIND_FM[2], function(p, l, j)
	got, gotLen, gotJob = p, l, j
end)
Path.budget = 0.05
drain()
Path.budget = 3
local syncPts, syncLen = Path.FindSync(0, GOLDSHIRE[1], GOLDSHIRE[2], STORMWIND_FM[1], STORMWIND_FM[2])
assert(gotJob == job and job.frames > 1, job.frames)
assert(math.abs(gotLen - syncLen) < 1e-6 and #got == #syncPts)

local cancelled = false
local first = Path.Find(0, NORTHSHIRE[1], NORTHSHIRE[2], GOLDSHIRE[1], GOLDSHIRE[2], function()
	cancelled = true
end)
Path.Cancel(first)
drain()
assert(not cancelled)

-- Coordinates: the navmesh stands where the addon's pins stand (UnitPosition frame, x north, y west).
-- Taxi.lua Stormwind flight master and Transports.lua tram pin, each with a nearby street point.
for _, pin in ipairs({ { -8840.56, 489.7, 0, -20 }, { -8346.46, 514.031, 8, 0 } }) do
	local p = Path.FindSync(0, pin[1], pin[2], pin[1] + pin[3], pin[2] + pin[4])
	assert(p, "no mesh at pin " .. pin[1] .. "," .. pin[2])
end

print("path_spec ok")
