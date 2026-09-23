-- A frozen timetable makes the bounded proof and a full endpoint search directly comparable.
local driver = assert(loadfile("tests/journey_driver.lua"))()
local ns = driver.ns
for _, file in ipairs({
	"Data/Routes.lua",
	"Data/Transports.lua",
	"Data/Taxi.lua",
	"Data/Portals.lua",
	"Data/Walks.lua",
	"Path.lua",
}) do
	driver.load(file)
end
for _, map in ipairs({ 0, 1, 2991 }) do
	assert(loadfile("tools/load_nav.lua"))(map)
end
ns.NowMs = function()
	return 123456
end
local nextFrame, options
ns.Path.after = function(fn)
	nextFrame = fn
end
local plan = ns.Planner.Plan
ns.Planner.Plan = function(o)
	options = o
	return plan(o)
end
local seed = 23781
local function random(n)
	seed = seed * 16807 % 2147483647
	return seed % n + 1
end
local function drain()
	local frames = 0
	while nextFrame do
		local fn = nextFrame
		nextFrame = nil
		fn()
		frames = frames + 1
		assert(frames < 20000, "bounded search did not settle")
	end
	assert(not ns.JourneyStatus())
end
local function full(o)
	local places = ns.Planner.Places(o)
	local walks = {}
	for _, reverse in ipairs({ false, true }) do
		local point, targets = reverse and o.to or o.from, {}
		local mass = ns.Planner.Landmass(point, o.landmasses)
		for _, place in ipairs(places) do
			if place.map == point.map and ns.Planner.Landmass(place, o.landmasses) == mass then
				targets[#targets + 1] = place
			end
		end
		if not reverse and o.to.map == point.map and ns.Planner.Landmass(o.to, o.landmasses) == mass then
			targets[#targets + 1] = o.to
		end
		local costs = ns.Path.FindManySync(point.map, point, targets, o.waterWalking, reverse)
		for i, target in ipairs(targets) do
			walks[#walks + 1] =
				{ from = reverse and target or point, to = reverse and point or target, cost = costs[i] }
		end
	end
	o.walks, o.exactMaps = walks, { [0] = true, [1] = true }
	return plan(o)
end
local reachable, findCost = 0, ns.Path.FindCost
for i = 1, 30 do
	local map = i % 2
	ns.Path.FindCost = i % 3 ~= 0 and findCost or nil
	ns.faction, ns.water, ns.speed = i % 3 == 0 and "Horde" or "Alliance", i % 4 < 2, i % 3 == 0 and 14 or 7
	local points = {}
	for _, point in ipairs(ns.Planner.Places({ docks = ns.Docks, taxiNodes = ns.TaxiNodes, faction = ns.faction })) do
		if point.map == map then
			points[#points + 1] = point
		end
	end
	ns.known = {}
	if i % 3 == 0 then
		for id in pairs(ns.TaxiNodes) do
			ns.known[id] = true
		end
	end
	local a, b = points[random(#points)], points[random(#points)]
	while (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 < 1000000 do
		b = points[random(#points)]
	end
	local from = { map = map, x = a.x + random(101) - 51, y = a.y + random(101) - 51 }
	local to = { map = map, x = b.x + random(101) - 51, y = b.y + random(101) - 51 }
	driver.begin(from, to)
	drain()
	local bounded, exact = driver.shown(), full(options)
	assert((bounded ~= nil) == (exact ~= nil), "reachability differs for pair " .. i)
	if bounded then
		reachable = reachable + 1
		assert(
			math.abs(bounded.arrive - exact.arrive) < 1e-5,
			string.format("pair %d map %d: bounded %.9f, full %.9f", i, map, bounded.arrive, exact.arrive)
		)
	end
	ns.ClearJourney()
end
assert(reachable >= 15, "the random sample needs enough reachable pairs")
print(
	string.format("journey_optimal_spec: 30 seeded EK/Kalimdor pairs, %d reachable, exact full-search costs", reachable)
)

ns.Path.FindCost = findCost

-- Reissuing a goal, or refreshing while stationary, must retain both settled costs and drawn points.
local many, batches = ns.Path.FindMany, {}
ns.Path.FindMany = function(...)
	local job = many(...)
	batches[#batches + 1] = job
	return job
end
ns.faction, ns.water, ns.speed, ns.known = "Alliance", false, 7, {}
local from, destination = ns.TaxiNodes[26], ns.TaxiNodes[39]
driver.begin(from, destination)
drain()
local count = #batches
local points = driver.shown().legs[1].walkPoints
for _, batch in ipairs(batches) do
	assert(
		not batch.co and not batch.scratch and not batch.callback and not batch.progress,
		"a settled journey must release its endpoint frontiers and callbacks"
	)
end
assert(count == 2 and #points > 2)
driver.begin(from, destination)
drain()
assert(#batches == count and driver.shown().legs[1].walkPoints[2] == points[2])
driver.update(60)
drain()
assert(#batches == count, "stationary refresh must reuse both searches")
local nearby = { map = from.map, x = from.x + 0.1, y = from.y, z = from.z }
assert(ns.Path.ReuseMany(batches[1], nearby))
driver.begin(nearby, destination)
drain()
assert(#batches == count, "sub-yard moves in the same cell should reuse start costs")
nearby.x = from.x + 30
driver.begin(nearby, destination)
drain()
assert(#batches == count + 1 and not batches[#batches].reverse, "movement invalidates only the start")
ns.water = true
driver.update(5)
drain()
assert(#batches == count + 3 and batches[#batches].waterWalking, "water mode invalidates both searches")
ns.ClearJourney()
driver.begin(nearby, destination)
drain()
assert(#batches == count + 5, "clearing a journey releases both endpoint caches")
ns.ClearJourney()
print("journey cache: repeated goal, stationary refresh, same-cell movement and water invalidation: ok")

-- Rounded baked walks may strengthen bounds at a fixed endpoint, including clicks with no height.
-- They must never replace its exact forward/reverse cost or change the proved optimum.
for _, pair in ipairs({ { 26, 39 }, { 26, 67 }, { 25, 22 }, { 6, 7 } }) do
	for _, water in ipairs({ false, true }) do
		ns.faction, ns.water = pair[1] == 25 and "Horde" or "Alliance", water
		driver.begin(ns.TaxiNodes[pair[1]], ns.TaxiNodes[pair[2]])
		drain()
		local bounded, exact = driver.shown(), full(options)
		assert(
			bounded and exact and math.abs(bounded.arrive - exact.arrive) < 1e-5,
			"baked endpoint bounds must preserve the full-search optimum"
		)
		ns.ClearJourney()
	end
end
print("baked endpoint bounds: four journeys, both water modes, exact full-search costs: ok")

-- The Deeprun Tram's instance has no world map, so a step there cannot fall back to a zone name.
local locate = ns.Locate
driver.env.UNKNOWN = "Unknown"
ns.Locate = function(point)
	return point.map ~= 369 and locate(point) or nil
end
ns.faction, ns.water, ns.speed, ns.known = "Alliance", false, 7, {}
driver.begin(ns.TaxiNodes[6], ns.TaxiNodes[2])
drain()
local modes = {}
for _, leg in ipairs(driver.shown().legs) do
	modes[leg.mode] = true
end
assert(modes.tram and modes.passage, "Ironforge to Stormwind should ride the Deeprun Tram")
for _, row in ipairs(select(2, ns.JourneyInfo())) do
	print("  " .. row.text)
	assert(not row.text:find("Unknown", 1, true), "unnamed step: " .. row.text)
end
ns.ClearJourney()
ns.Locate = locate
-- Docks inside instances (the tram's stations) need a name and a pin on a mapped continent.
for id, dock in pairs(ns.Docks) do
	local mapped = { [0] = true, [1] = true, [2991] = true }
	assert(mapped[dock.map] or dock.name and dock.pin and mapped[dock.pin.map], "dock " .. id .. " has no place name")
end
print("tram journey: every step is named: ok")
