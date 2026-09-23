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
	assert(loadfile("ShortestPathForever_Nav" .. map .. "/Nav" .. map .. ".lua"))()
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
assert(#batches == count + 3, "clearing the UI must not discard destination costs")
ns.ClearJourney()
print("journey cache: repeated goal, stationary refresh, same-cell movement and water invalidation: ok")
