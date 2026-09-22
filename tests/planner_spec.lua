local ns = {}
assert(loadfile("Model.lua"))("FerryForever", ns)
assert(loadfile("Planner.lua"))("FerryForever", ns)
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

local walk = only(Plan(options()), "walk")
near(walk.depart, 1000)
near(walk.arrive, 11000)
assert(walk.from.kind == "start" and walk.to.kind == "goal" and walk.estimated)

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
assert(ride.route == 7 and ride.stops == 1 and not ride.estimated)
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
assert(Plan(boat) == nil, "lifts are countdown-only")
boat.routes[7].kind = "boat"
boat.anchors = {}
ride = only(Plan(boat), "boat")
near(ride.wait, 30000)
near(ride.arrive, 41000)
assert(ride.estimated)

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
only(Plan(flight), "walk")
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
near(flying.arrive, 37000)
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

-- Multi-stop rides include the middle dwell, and the final destination may wrap past phase zero.
connection.routes[1].stops[3] = { dock = 3, arrive = 20000, depart = 25000 }
connection.routes[2] = nil
ride = only(Plan(connection), "boat")
assert(ride.stops == 2)
near(ride.arrive, 20000)
connection.from, connection.to, connection.now = point(3), point(1), 21000
ride = only(Plan(connection), "boat")
near(ride.depart, 25000)
near(ride.arrive, 100000)

-- The shipped data can route between continents and tram stations using the same pure contract.
for _, file in ipairs({ "Routes", "Transports", "Taxi", "Portals" }) do
	assert(loadfile("Data/" .. file .. ".lua"))("FerryForever", ns)
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
real.from, real.to = ns.Docks[7], ns.Docks[10]
assert(Plan(real), "Rut'theran to Auberdine is reachable")
for _, path in ipairs(ns.TaxiPaths) do
	assert(#path.points >= 6 and #path.points % 3 == 0)
end

print("planner_spec: ok")
