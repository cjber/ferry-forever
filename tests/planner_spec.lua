local ns = {}
assert(loadfile("Model.lua"))("ShortestPathForever", ns)
assert(loadfile("Planner.lua"))("ShortestPathForever", ns)
local Plan = ns.Planner.Plan
local LegPoints = ns.Planner.LegPoints

local function point(map, x, y)
	return { map = map, x = x or 0, y = y or 0 }
end

local function near(actual, expected)
	assert(math.abs(actual - expected) < 0.001, ("%s, expected %s"):format(actual, expected))
end

local function only(result, mode)
	assert(result and #result.legs == 1 and result.legs[1].mode == mode)
	return result.legs[1]
end

local function options()
	return { from = point(1), to = point(1, 70), now = 1000, walkSpeed = 7, faction = "Alliance" }
end

do
	local QuestDestination = ns.Planner.QuestDestination
	local objective = { questID = 7, mapID = 999, x = 0.25, y = 0.75, inProgress = true }
	local turnIn = { questID = 7, x = 0.6, y = 0.4, inProgress = false }
	local hop = { uiMapID = 1439, x = 0.1, y = 0.2 }
	local destination = QuestDestination(7, "The Red Crystal", false, 1414, { objective })
	assert(destination.uiMapID == 1414 and destination.x == objective.x and destination.y == objective.y)
	assert(destination.label == "The Red Crystal", "objective label uses the quest title")
	destination = QuestDestination(7, "The Red Crystal", false, 1414, { objective }, hop)
	assert(destination.uiMapID == hop.uiMapID and destination.x == hop.x, "follow cross-zone waypoints")
	destination = QuestDestination(7, "The Red Crystal", true, 1414, { turnIn }, hop)
	assert(destination.x == turnIn.x and destination.y == turnIn.y, "turn-in POI wins over an old objective waypoint")
	assert(destination.label == "The Red Crystal (turn in)")
	destination = QuestDestination(7, "The Red Crystal", true, nil, nil, hop)
	assert(destination.uiMapID == hop.uiMapID, "native waypoint is usable when no destination POI is reported")
	assert(hop.label == nil and turnIn.label == nil, "do not mutate native data")
	assert(not QuestDestination(8, "Another quest", false, 1414, { objective }))
	assert(
		not QuestDestination(
			7,
			"The Red Crystal",
			false,
			1414,
			{ { questID = 7, isQuestStart = true, x = 0.5, y = 0.5 } }
		)
	)
	assert(not QuestDestination(7, "The Red Crystal", false, 0, { objective }))
	assert(not QuestDestination(7, "The Red Crystal", false, 1414, { { questID = 7, x = -1, y = 0.5 } }))
	assert(not QuestDestination(7, "The Red Crystal", false, nil, nil, { uiMapID = 1414, x = 0.5 }))
	assert(not QuestDestination(7, nil, false, 1414, { objective }))
	local labeled = options()
	labeled.to.label = "The Red Crystal (turn in)"
	assert(only(Plan(labeled), "walk").to.label == labeled.to.label, "leg text keeps the quest goal label")
end

local walk = only(Plan(options()), "walk")
near(walk.depart, 1000)
near(walk.arrive, 11000)
assert(walk.from.kind == "start" and walk.to.kind == "goal" and walk.estimated)

-- A measured detour cannot be bypassed by guessing two adjacent walks through an arbitrary flight master.
-- Its separate transit arrival must still survive when a later flight there can lead to a faster finish.
do
	local detour = options()
	detour.to = point(1, 7000)
	detour.taxiNodes = { point(1, 3500) }
	detour.walks = { { from = detour.from, to = detour.to, cost = 14000 } }
	near(only(Plan(detour), "walk").yards, 14000)
	detour.walks[1].cost = false
	assert(not Plan(detour), "splitting a blocked walk does not make it reachable")
	detour.docks = { point(1, 1000), point(2) }
	detour.routes = {
		[1] = {
			kind = "boat",
			period = 10000,
			stops = { { dock = 1, arrive = 0, depart = 0 }, { dock = 2, arrive = 5000, depart = 5000 } },
		},
	}
	assert(not Plan(detour), "a round trip must not reset a blocked walk into two estimated walks")
	detour.taxiNodes[2] = point(1, 350)
	detour.taxiPaths = { { from = 2, to = 1, seconds = 600 } }
	local result = Plan(detour)
	assert(#result.legs == 3 and result.legs[2].mode == "flight")
	assert(result.legs[1].to.id == 2 and result.legs[3].from.id == 1)
end

-- Same continent, different islands: the mainland cannot be reached by walking across the water.
local boat = options()
boat.to = point(1, 100)
boat.docks = { [1] = point(1), [1001] = point(1, 100) }
boat.landmasses = { { map = 1, minX = 90, maxX = 110, minY = -10, maxY = 10 } }
boat.routes = {
	[7] = {
		kind = "boat",
		period = 60000,
		stops = { { dock = 1, arrive = 0, depart = 10000 }, { dock = 1001, arrive = 20000, depart = 30000 } },
		frames = {
			{ 0, 10000, 1, 0, 0 },
			{ 15000, 15000, 1, 40, 20 },
			{ 20000, 30000, 1, 100, 0 },
			{ 45000, 45000, 1, 80, -20, 1 },
			{ 45000, 45000, 1, 20, -20 },
		},
	},
}
boat.anchors = { [7] = { epoch = 0 } }
local ride = only(Plan(boat), "boat")
near(ride.wait, 9000)
near(ride.arrive, 20000)
assert(ride.route == 7 and not ride.estimated)
local points = LegPoints(ride, boat.routes)
assert(#points == 3 and points[1].map == 1 and points[3].map == 1)
near(points[1].x, boat.docks[1].x)
near(points[1].y, boat.docks[1].y)
near(points[2].x, 40)
near(points[2].y, 20)
near(points[3].x, boat.docks[1001].x)
near(points[3].y, boat.docks[1001].y)
boat.from, boat.to = boat.to, boat.from
points = LegPoints(only(Plan(boat), "boat"), boat.routes)
assert(#points == 4 and points[2].jump == 1 and not points[3].jump)
near(points[1].x, 100)
near(points[2].x, 80)
near(points[3].x, 20)
near(points[4].x, 0)
boat.from, boat.to = boat.to, boat.from
boat.routes[7].kind = "lift"
assert(only(Plan(boat), "lift").route == 7, "lifts ride like any other route")
boat.routes[7].kind = "boat"
boat.anchors = {}
ride = only(Plan(boat), "boat")
near(ride.wait, 30000)
near(ride.arrive, 41000)
assert(ride.estimated)

-- A lift's landings share a spot on the map: only height and the measured walk between them tell them apart.
do
	local lift = options()
	lift.from, lift.to = { map = 1, x = 0, y = 0, z = 0 }, { map = 1, x = 0, y = 0, z = 100 }
	lift.docks = { [1] = { map = 1, x = 0, y = 0, z = 0 }, [2] = { map = 1, x = 0, y = 0, z = 100 } }
	lift.routes = {
		[9] = {
			kind = "lift",
			period = 40000,
			stops = { { dock = 1, arrive = 0, depart = 5000 }, { dock = 2, arrive = 20000, depart = 25000 } },
		},
	}
	lift.anchors = { [9] = { epoch = 0 } }
	-- Unmeasured, the climb is a 100-yard straight line (14 s) and beats waiting for the car.
	walk = only(Plan(lift), "walk")
	near(walk.arrive - walk.depart, 100 / 7 * 1000)
	assert(walk.estimated and walk.yards == 100)
	-- Measured, the way up on foot is long, and the lift wins; costs bind the exact endpoints.
	lift.walks = { { from = lift.from, to = lift.to, cost = 2000 } }
	local result = Plan(lift)
	assert(#result.legs == 1 and result.legs[1].mode == "lift" and result.legs[1].to.id == 2)
	-- Heights keep the landings apart: the bottom's measurement does not stand for the top.
	lift.from = { map = 1, x = 0, y = 0, z = 100 }
	lift.to = { map = 1, x = 0, y = 0, z = 90 }
	assert(only(Plan(lift), "walk").estimated)
	-- The newest record of a walk wins: a later measurement from the same spot corrects an earlier one.
	lift.from, lift.to = { map = 1, x = 0, y = 0, z = 0 }, { map = 1, x = 0, y = 0, z = 100 }
	lift.walks[2] = { from = lift.from, to = lift.to, cost = 70 }
	assert(only(Plan(lift), "walk").yards == 70)
	lift.walks[2] = nil
	-- A blocked walk is never planned; with no ride either, there is no way there.
	lift.from, lift.to = { map = 1, x = 0, y = 0, z = 0 }, { map = 1, x = 0, y = 0, z = 100 }
	lift.walks[1].cost = false
	assert(only(Plan(lift), "lift"))
	lift.routes = nil
	assert(Plan(lift) == nil)
end

-- A long swim measured against a boat: the swim's cost already counts its slower pace.
do
	local swim = options()
	swim.to = point(1, 100)
	swim.docks = { [1] = point(1), [2] = point(1, 100) }
	swim.routes = {
		[3] = {
			kind = "boat",
			period = 20000,
			stops = { { dock = 1, arrive = 0, depart = 2000 }, { dock = 2, arrive = 16000, depart = 18000 } },
		},
	}
	swim.anchors = { [3] = { epoch = 0 } }
	assert(only(Plan(swim), "walk"))
	swim.walks = { { from = point(1), to = point(1, 100), cost = 149 } }
	assert(only(Plan(swim), "boat"))
end

-- Replanning on deck must stay aboard to the known next arrival, even if walking looks faster.
boat.ride = { route = 7, dock = 1001, arrive = 20000 }
boat.from, boat.now = point(1, 20, 10), 12000
ride = only(Plan(boat), "boat")
assert(ride.aboard and ride.to.id == 1001 and not ride.estimated)
near(ride.wait, 0)
near(ride.depart, 12000)
near(ride.arrive, 20000)
points = LegPoints(ride, boat.routes)
assert(#points == 3)
near(points[1].x, 20)
near(points[2].x, 40)
near(points[3].x, 100)
boat.to = boat.from
local returning = Plan(boat)
assert(returning.legs[1].aboard, "even the nearby origin cannot be reached on foot while aboard")
boat.from, boat.to, boat.now = point(1, 90, -10), point(1), 40000
boat.ride = { route = 7, dock = 1, arrive = 60000 }
ride = only(Plan(boat), "boat")
points = LegPoints(ride, boat.routes)
assert(#points == 4 and points[2].jump == 1 and not points[3].jump)
near(points[1].x, 90)
near(points[2].x, 80)
near(points[3].x, 20)
boat.ride, boat.from, boat.to, boat.now = nil, point(1), point(1, 100), 1000

-- Reaching the second dock after departure costs another loop, even though it had not departed at now.
local connection = options()
connection.now, connection.to = 0, point(3)
connection.docks = { point(1), point(2), point(3) }
connection.routes = {
	[1] = {
		kind = "boat",
		period = 100000,
		stops = { { dock = 1, arrive = 0, depart = 1000 }, { dock = 2, arrive = 11000, depart = 12000 } },
	},
	[2] = {
		kind = "zeppelin",
		period = 60000,
		stops = { { dock = 2, arrive = 0, depart = 10000 }, { dock = 3, arrive = 20000, depart = 30000 } },
	},
}
connection.anchors = { [1] = { epoch = 0 }, [2] = { epoch = 0 } }
local result = Plan(connection)
assert(result and #result.legs == 2)
near(result.legs[2].wait, 59000)
near(result.legs[2].depart, 70000)
near(result.arrive, 80000)

-- The boarding dock is reached on foot in the future, too.
boat.anchors = { [7] = { epoch = 0 } }
boat.from, boat.now = point(1, -77), 0
result = Plan(boat)
near(result.legs[2].wait, 59000)
near(result.arrive, 80000)

local flight = options()
flight.to = point(1, 7000)
flight.taxiNodes = { [1] = point(1), [2] = point(1, 7000) }
flight.taxiNodes[1].faction, flight.taxiNodes[2].faction = "Alliance", "Alliance"
flight.taxiPaths = { { from = 1, to = 2, seconds = 10 } }
local flying = only(Plan(flight), "flight")
near(flying.arrive, 14000)
near(flying.wait, 3000)
flight.taxiKnown = { [1] = true }
only(Plan(flight), "walk")
flight.taxiKnown = { [2] = true }
only(Plan(flight), "flight")
flight.from = point(1, -70)
result = Plan(flight)
assert(#result.legs == 2 and result.legs[1].mode == "walk" and result.legs[1].to.undiscovered)
assert(result.legs[2].mode == "flight" and result.legs[2].to.id == 2)
near(result.arrive, 24000)
flight.from = point(1)
flight.taxiKnown = nil
flight.taxiNodes[2].faction = "Horde"
only(Plan(flight), "walk")
flight.taxiNodes[2].faction = nil
only(Plan(flight), "flight")

-- Directed portals cannot be reversed, restricted entries cannot be assumed usable.
local portal = options()
portal.to = point(2)
portal.portals = { { kind = "portal", from = point(1), to = point(2), seconds = 5 } }
near(only(Plan(portal), "portal").arrive, 6000)
portal.from, portal.to = portal.to, portal.from
assert(Plan(portal) == nil)
portal.from, portal.to = portal.to, portal.from
portal.portals[1].faction = "Horde"
assert(Plan(portal) == nil)
portal.portals[1].faction, portal.portals[1].requires = "Alliance", "Alliance Skyborne only"
assert(Plan(portal) == nil)
portal.portals[1].requires, portal.portals[1].kind = nil, "passage"
only(Plan(portal), "passage")

-- Connecting flights are shown as one leg, preserving elapsed time and estimated-duration provenance.
flight.to = point(1, 14000)
flight.taxiNodes[3] = point(1, 14000)
flight.taxiPaths[2] = { from = 2, to = 3, seconds = 20, estimated = true }
flight.taxiPaths[1].points = { 1, 0, 0, 1, 3500, 200, 1, 7000, 0 }
flight.taxiPaths[2].points = { 1, 7000, 0, 1, 10500, -200, 1, 14000, 0 }
flying = only(Plan(flight), "flight")
near(flying.arrive, 34000)
near(flying.wait, 3000)
assert(flying.from.id == 1 and flying.to.id == 3 and flying.estimated)
assert(#flying.hops == 2 and flying.hops[1] == flight.taxiPaths[1] and flying.hops[2] == flight.taxiPaths[2])
points = LegPoints(flying, {})
assert(#points == 8)
near(points[3].x, 3500)
near(points[3].y, 200)
near(points[6].x, 10500)
near(points[6].y, -200)
near(points[8].x, 14000)

-- Unknown connections can be crossed, but cannot end a flight even with a zero-length walk to the goal.
flight.taxiKnown = { [1] = true, [3] = true }
flying = only(Plan(flight), "flight")
assert(#flying.hops == 2 and flying.to.id == 3)
flight.to = point(1, 7000)
result = Plan(flight)
for _, part in ipairs(result.legs) do
	assert(part.mode ~= "flight" or flight.taxiKnown[part.to.id], "cannot land at an unknown connection")
end
flight.taxiKnown = {}
only(Plan(flight), "walk")
flight.taxiKnown = nil
only(Plan(flight), "flight")

-- All walking geometry goes through the replaceable point-list contract.
local straight = ns.Planner.WalkPoints
local detour = { point(1), point(1, 20, 10), point(1, 70) }
ns.Planner.WalkPoints = function(from, to)
	assert(from == walk.from and to == walk.to)
	return detour
end
assert(LegPoints(walk, {}) == detour)
ns.Planner.WalkPoints = straight
assert(#LegPoints(walk, {}) == 2)
walk.walkPoints = detour
assert(LegPoints(walk, {}) == detour, "drawing reuses the prepared Guide path")
walk.walkPoints = nil

-- A slightly later in-flight arrival beats an earlier ground arrival that must pay boarding again.
local competing = options()
competing.to = point(1, 7000)
competing.taxiNodes = { point(1), point(1, 70), point(1, 7000) }
competing.taxiPaths = { { from = 1, to = 2, seconds = 8 }, { from = 2, to = 3, seconds = 10 } }
flying = only(Plan(competing), "flight")
near(flying.arrive, 22000)
assert(#flying.hops == 2)
-- A ground transfer breaks the merged flight and pays a second boarding charge.
competing.taxiNodes[3] = point(1, 140)
competing.taxiNodes[4] = competing.to
competing.taxiPaths[1].seconds = 1
competing.taxiPaths[2] = { from = 3, to = 4, seconds = 10 }
result = Plan(competing)
assert(#result.legs == 3 and result.legs[2].mode == "walk")
near(result.legs[1].wait, 3000)
near(result.legs[3].wait, 3000)
near(result.arrive, 28000)
-- Co-located but disconnected taxi nodes still require landing and boarding another flight.
competing.taxiNodes[3] = point(1, 70)
result = Plan(competing)
assert(#result.legs == 2 and #result.legs[1].hops == 1 and #result.legs[2].hops == 1)
near(result.legs[2].wait, 3000)
near(result.arrive, 18000)

-- Multi-stop rides include the middle dwell, and the final destination may wrap past phase zero.
connection.routes[1].stops[3] = { dock = 3, arrive = 20000, depart = 25000 }
connection.routes[2] = nil
ride = only(Plan(connection), "boat")
near(ride.arrive, 20000)
connection.from, connection.to, connection.now = point(3), point(1), 21000
ride = only(Plan(connection), "boat")
near(ride.depart, 25000)
near(ride.arrive, 100000)

-- The shipped data can route between continents and tram stations using the same pure contract.
for _, file in ipairs({ "Routes", "Transports", "Taxi", "Portals" }) do
	assert(loadfile("Data/" .. file .. ".lua"))("ShortestPathForever", ns)
end
local real = options()
real.from, real.to = ns.Docks[1101], ns.Docks[1102]
real.docks, real.routes = ns.Docks, ns.Routes
real.taxiNodes, real.taxiPaths = ns.TaxiNodes, ns.TaxiPaths
real.portals, real.landmasses = ns.Portals, ns.Landmasses
only(Plan(real), "tram")
points = LegPoints(only(Plan(real), "tram"), real.routes)
assert(#points > 2 and points[1].map == 369 and points[#points].map == 369)
near(points[1].y, ns.Docks[1101].y)
near(points[#points].y, ns.Docks[1102].y)
-- The reported Ratchet regression: 55 seconds out, Booty Bay is still only 52 seconds ahead.
local ratchet = ns.Routes[241]
real.now = ratchet.stops[1].depart + 55000
for index = 1, #ratchet.frames - 1 do
	local a, b = ratchet.frames[index], ratchet.frames[index + 1]
	if a[2] <= real.now and real.now < b[1] then
		local t = (real.now - a[2]) / (b[1] - a[2])
		real.from = point(a[3], a[4] + (b[4] - a[4]) * t, a[5] + (b[5] - a[5]) * t)
		break
	end
end
real.to = ns.Docks[2]
real.ride = { route = 241, dock = 2, arrive = ratchet.stops[2].arrive }
ride = only(Plan(real), "boat")
assert(ride.aboard and ride.route == 241)
near(ride.arrive - real.now, 51854)
points = LegPoints(ride, real.routes)
assert(points[1].map == 1 and points[#points].map == 0)
local jump
for index, p in ipairs(points) do
	if p.jump then
		jump = index
	end
end
assert(jump and points[jump].map == 1 and points[jump + 1].map == 0)
real.ride = nil
real.from, real.to = ns.Docks[7], ns.Docks[10]
assert(Plan(real), "Rut'theran to Auberdine is reachable")
for _, path in ipairs(ns.TaxiPaths) do
	assert(#path.points >= 6 and #path.points % 3 == 0)
end

-- The baked walks name the planner's places: a key that no longer names one (places renumbered, added or moved
-- without rerunning tools/bake_walks.lua) would silently fall back to straight-line guesses.
assert(loadfile("Data/Portals.lua"))("ShortestPathForever", ns)
assert(loadfile("Data/Walks.lua"))("ShortestPathForever", ns)
local places = {}
for id, dock in pairs(ns.Docks) do
	places["dock" .. id] = dock
end
for id, node in pairs(ns.TaxiNodes) do
	places["taxi" .. id] = node
end
for id, entry in ipairs(ns.Portals) do
	places["portal" .. (id * 2 - 1)], places["portal" .. id * 2] = entry.from, entry.to
end
for map, walks in pairs(ns.Walks) do
	for key in pairs(walks) do
		local a, b = key:match("^(%S+) (%S+)$")
		assert(a < b and places[a] and places[b], "stale baked walk " .. key)
		assert(places[a].map == map and places[b].map == map, "baked walk on the wrong map " .. key)
	end
end
for key, place in pairs(places) do
	if place.map == 0 or place.map == 1 or place.map == 2991 then
		local coords = ns.WalkPlaces[place.map] and ns.WalkPlaces[place.map][key]
		assert(coords and (coords[1] - place.x) ^ 2 + (coords[2] - place.y) ^ 2 <= 1, "moved baked place " .. key)
		for otherKey, other in pairs(places) do
			if
				key < otherKey
				and place.map == other.map
				and ns.Planner.Landmass(place, ns.Landmasses) == ns.Planner.Landmass(other, ns.Landmasses)
			then
				local pair = key .. " " .. otherKey
				assert(ns.Walks[place.map] and ns.Walks[place.map][pair], "missing baked walk " .. pair)
			end
		end
	end
end
-- Walking between two fixed places costs what was baked, not the straight line: with the direct way blocked, the
-- walk goes by the docks at their baked cost.
local baked = Plan({
	from = ns.Docks[1009],
	to = ns.Docks[1010],
	now = 0,
	walks = { { from = ns.Docks[1009], to = ns.Docks[1010], cost = false } },
	docks = { [1009] = ns.Docks[1009], [1010] = ns.Docks[1010] },
	baked = { [0] = { ["dock1009 dock1010"] = { 5000, 4000 } } },
	landmasses = ns.Landmasses,
})
near(only(baked, "walk").yards, 5000)
baked = Plan({
	from = ns.Docks[1009],
	to = ns.Docks[1010],
	now = 0,
	waterWalking = true,
	walks = { { from = ns.Docks[1009], to = ns.Docks[1010], cost = false } },
	docks = { [1009] = ns.Docks[1009], [1010] = ns.Docks[1010] },
	baked = { [0] = { ["dock1009 dock1010"] = { 5000, 4000 } } },
	landmasses = ns.Landmasses,
})
near(only(baked, "walk").yards, 4000)

-- Exact endpoint batches are directed and never fall back to a straight estimate for a missing cost.
do
	local exact = options()
	exact.exactMaps = { [1] = true }
	assert(not Plan(exact))
	exact.walks = { { from = exact.to, to = exact.from, cost = 100 } }
	assert(not Plan(exact), "reverse costs do not stand for forward costs")
	exact.walks[2] = { from = exact.from, to = exact.to, cost = 200 }
	near(only(Plan(exact), "walk").yards, 200)
	exact.from = point(1, 1)
	assert(not Plan(exact), "a nearby point cannot inherit an exact measurement")
end
-- Same-cluster water steps can differ in reverse, even though the abstract graph is undirected.
for _, water in ipairs({ false, true }) do
	local a, b = ns.Docks[1010], ns.Docks[1009]
	local reversed = Plan({
		from = a,
		to = b,
		now = 0,
		waterWalking = water,
		walks = { { from = a, to = b, cost = false } },
		docks = { [1009] = b, [1010] = a },
		baked = { [0] = { ["dock1009 dock1010"] = { 5000, 4000, 3000, 2000 } } },
	})
	near(only(reversed, "walk").yards, water and 2000 or 3000)
end

print("planner_spec: ok")
assert(loadfile("tests/journey_spec.lua"))()
