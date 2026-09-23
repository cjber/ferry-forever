local driver = assert(loadfile("tests/journey_driver.lua"))()
local ns, env, checks = driver.ns, driver.env, 0
driver.load("API.lua")
local API = env.ShortestPathForever.API
local function equal(actual, expected, label)
	checks = checks + 1
	assert(actual == expected, label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function near(actual, expected, label)
	checks = checks + 1
	assert(type(actual) == "number" and math.abs(actual - expected) < 1e-6, label)
end

equal(API.version, 1, "version")
near(API.Estimate(1, 0.5, 0.5, 1, 0.5014, 0.5), 10, "world conversion and milliseconds to seconds")
equal(API.Estimate(1, 0.5, 0.5, 2, 0.5, 0.5), nil, "unconnected continents")
for _, value in ipairs({ -1, 1.01, math.huge, 0 / 0, "0.5", false, driver.secret }) do
	equal(API.Estimate(1, value, 0.5, 1, 0.5, 0.5), nil, "bad coordinate")
	equal(API.Navigate("AGF", 1, value, 0.5), false, "bad navigation coordinate")
end
equal(API.Estimate(0, 0.5, 0.5, 1, 0.5, 0.5), nil, "invalid UI map")
equal(API.Navigate("", 1, 0.6, 0.5), false, "empty owner")
equal(API.Navigate(" ", 1, 0.6, 0.5), false, "blank owner")
equal(API.Navigate("AGF", 1, 0.6, 0.5, {}), false, "invalid title")
equal(API.Cancel("AGF"), false, "no journey")
equal(API.Navigate("AGF", 1, 0.6, 0.5, "Quest giver"), true, "start guidance")
equal(ns.IsJourneyGuided(), true, "arrow enabled")
equal(ns.JourneyInfo(), "Journey to Quest giver", "title propagated")
local shown, waypoint = driver.shown(), driver.waypoint()
local _, _, plan, index = ns.JourneyInfo()
near(API.Estimate(1, 0.5, 0.5, 1, 0.5014, 0.5), 10, "estimate during journey")
equal(driver.shown(), shown, "estimate leaves route untouched")
equal(driver.waypoint(), waypoint, "estimate leaves waypoint untouched")
local _, _, after, afterIndex = ns.JourneyInfo()
equal(after, plan, "estimate leaves plan untouched")
equal(afterIndex, index, "estimate leaves progress untouched")
equal(API.Cancel("OtherAddon"), false, "foreign cancellation")
equal(API.Navigate("OtherAddon", 1, 0.7, 0.5), true, "ownership replaced")
equal(API.Cancel("AGF"), false, "old owner cannot cancel")
equal(API.Cancel("OtherAddon"), true, "current owner cancels")
equal(ns.HasJourney(), false, "journey cleared")
equal(API.Cancel("OtherAddon"), false, "cancel is idempotent")
API.Navigate("AGF", 1, 0.6, 0.5)
driver.begin({ map = 1, x = 0, y = 0 }, { map = 1, x = 2000, y = 0 })
equal(API.Cancel("AGF"), false, "manual journey revokes ownership")
equal(ns.HasJourney(), true, "manual journey preserved")
ns.db.journey = false
equal(API.Navigate("AGF", 1, 0.6, 0.5), false, "journey setting respected")
near(API.Estimate(1, 0.5, 0.5, 1, 0.5014, 0.5), 10, "estimate independent of journey setting")
ns.db.journey = true
env.InCombatLockdown = function()
	return true
end
equal(API.Navigate("AGF", 1, 0.6, 0.5), false, "combat navigation deferred to caller")
equal(API.Estimate(1, 0.5, 0.5, 1, 0.6, 0.5), nil, "no combat search")
env.InCombatLockdown = function()
	return false
end
local project = env.C_Map.GetWorldPosFromMapPos
env.C_Map.GetWorldPosFromMapPos = function()
	return nil
end
equal(API.Navigate("AGF", 1, 0.6, 0.5), false, "unprojectable destination")
equal(API.Estimate(1, 0.5, 0.5, 1, 0.6, 0.5), nil, "unprojectable estimate")
env.C_Map.GetWorldPosFromMapPos = project
ns.ClearJourney()

local planner, calls = ns.Planner.Plan, 0
ns.Planner.Plan = function(options)
	calls = calls + 1
	return planner(options)
end
local cached = API.Estimate(1, 0.5, 0.5, 1, 0.61, 0.5)
equal(calls, 1, "cache miss searches once")
near(API.Estimate(1, 0.50001, 0.5, 1, 0.61, 0.5), cached, "rounded origin cache hit")
equal(calls, 1, "cache hit skips planner")
API.Estimate(1, 0.5, 0.5, 1, 0.61001, 0.5)
equal(calls, 2, "destination is not rounded")
ns.speed = 14
near(API.Estimate(1, 0.5, 0.5, 1, 0.61, 0.5), cached / 2, "speed invalidates cache")
equal(calls, 3, "speed change searches")
ns.water = true
API.Estimate(1, 0.5, 0.5, 1, 0.61, 0.5)
equal(calls, 4, "water walking invalidates cache")
ns.faction = "Horde"
API.Estimate(1, 0.5, 0.5, 1, 0.61, 0.5)
equal(calls, 5, "faction invalidates cache")
local anchors = { [1] = { epoch = 10 } }
ns.FreshAnchors = function()
	return anchors
end
API.Estimate(1, 0.5, 0.5, 1, 0.61, 0.5)
equal(calls, 6, "new transport timing invalidates cache")
anchors[1].epoch = 20
API.Estimate(1, 0.5, 0.5, 1, 0.61, 0.5)
equal(calls, 7, "in-place transport timing update invalidates cache")
anchors[1] = nil
API.Estimate(1, 0.5, 0.5, 1, 0.61, 0.5)
equal(calls, 8, "expired transport timing invalidates cache")
driver.update(5)
API.Estimate(1, 0.5, 0.5, 1, 0.61, 0.5)
equal(calls, 9, "five-second cache lifetime")
for i = 1, 257 do
	API.Estimate(1, 0.5, 0.5, 1, 0.4 + i / 10000, 0.5)
end
local beforeEviction = calls
API.Estimate(1, 0.5, 0.5, 1, 0.4001, 0.5)
equal(calls, beforeEviction + 1, "bounded cache evicts oldest destination")
ns.speed, ns.water, ns.faction = nil, nil, "Alliance"
ns.Planner.Plan = planner

-- Real bundled network; the driver's affine projection keeps these world-yard endpoints exact.
for _, file in ipairs({
	"Data/Routes.lua",
	"Data/Transports.lua",
	"Data/Taxi.lua",
	"Data/Portals.lua",
	"Data/Walks.lua",
}) do
	driver.load(file)
end
env.C_Map.GetWorldPosFromMapPos = function(map, point)
	return project(map == 2 and 0 or map, point)
end
local function estimate(fromID, toID)
	local a, b = ns.TaxiNodes[fromID], ns.TaxiNodes[toID]
	return API.Estimate(
		a.map == 0 and 2 or a.map,
		0.5 - a.y / 50000,
		0.5 - a.x / 50000,
		b.map == 0 and 2 or b.map,
		0.5 - b.y / 50000,
		0.5 - b.x / 50000
	)
end
ns.known = {}
local walking = estimate(26, 39)
for id in pairs(ns.TaxiNodes) do
	ns.known[id] = true
end
local flying = estimate(26, 39)
equal(flying < walking, true, "in-place flight discovery invalidates estimator topology")
ns.known = {}
near(estimate(26, 39), walking, "removed discoveries invalidate topology")
for id in pairs(ns.TaxiNodes) do
	ns.known[id] = true
end
local start = os.clock()
local seconds = estimate(26, 67)
local cold = (os.clock() - start) * 1000
equal(type(seconds), "number", "cross-continent estimate known")
equal(ns.HasJourney(), false, "benchmark never starts guidance")
for _ = 1, 50 do
	estimate(26, 67)
end
start = os.clock()
for _ = 1, 250 do
	estimate(26, 67)
end
local long = (os.clock() - start) * 4
start = os.clock()
for _ = 1, 250 do
	estimate(26, 27)
end
local short = (os.clock() - start) * 4
print(
	string.format(
		"api_spec: %d checks passed; Estimate cached short %.3f ms, cross-continent cold %.3f / cached %.3f ms",
		checks,
		short,
		cold,
		long
	)
)
assert(long < 3, "cross-continent Estimate exceeds 3 ms")
