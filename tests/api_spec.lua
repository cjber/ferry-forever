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

local stops = {
	{ map = 1, x = 0.502, y = 0.5, title = "First" },
	{ map = 1, x = 0.504, y = 0.5, title = "Second" },
	{ map = 1, x = 0.506, y = 0.5, title = "Third" },
	{ map = 1, x = 0.508, y = 0.5, title = "Last" },
}
driver.move({ map = 1, x = 0, y = 0 })
equal(API.CurrentStop("AGF"), nil, "no current stop before starting")
equal(API.NavigateRoute("AGF", stops), true, "start four-stop route")
equal(API.CurrentStop("AGF"), 1, "first stop")
equal(API.CurrentStop("OtherAddon"), nil, "foreign current stop")
equal(API.CurrentStop(driver.secret), nil, "secret owner")
equal(ns.JourneyInfo(), "Stop 1 of 4: First", "route progress title")
for _, invalid in ipairs({
	false,
	{},
	{ stops[1], false },
	{ stops[1], { map = 1, x = 2, y = 0.5 } },
	{ stops[1], { map = 1, x = 0.5, y = 0.5, title = {} } },
	{ [1] = stops[1], [100] = stops[2] },
}) do
	equal(API.NavigateRoute("AGF", invalid), false, "invalid route")
	equal(API.CurrentStop("AGF"), 1, "invalid route preserves ownership and progress")
end
local many = {}
for i = 1, 65 do
	many[i] = stops[1]
end
equal(API.NavigateRoute("AGF", many), false, "bounded stop count")
equal(API.Cancel("OtherAddon"), false, "foreign cancel leaves whole route")
stops[2].title, stops[2].x = "Changed by caller", 0.9
-- The existing 15-yard arrival radius applies; merely passing a later stop cannot skip ahead.
driver.move({ map = 1, x = 0, y = -400 })
driver.update(0.1)
equal(API.CurrentStop("AGF"), 1, "later stop does not skip current stop")
driver.move({ map = 1, x = 0, y = -84 })
driver.update(0.1)
equal(API.CurrentStop("AGF"), 1, "outside arrival radius")
driver.move({ map = 1, x = 0, y = -86 })
driver.update(0.1)
equal(API.CurrentStop("AGF"), 2, "arrival advances within radius")
equal(ns.JourneyInfo(), "Stop 2 of 4: Second", "copied title and progress")
local _, _, secondPlan = ns.JourneyInfo()
near(secondPlan.legs[#secondPlan.legs].to.y, -200, "copied coordinates")
env.InCombatLockdown = function()
	return true
end
driver.move({ map = 1, x = 0, y = -200 })
driver.update(0.1)
equal(API.CurrentStop("AGF"), 2, "combat pauses stop advancement")
equal(API.NavigateRoute("AGF", stops), false, "combat refuses replacement")
env.InCombatLockdown = function()
	return false
end
driver.update(0.1)
equal(API.CurrentStop("AGF"), 3, "combat end resumes arrival")
driver.move({ map = 1, x = 0, y = -300 })
driver.update(0.1)
equal(API.CurrentStop("AGF"), 4, "third arrival advances to last")
equal(ns.JourneyInfo(), "Stop 4 of 4: Last", "last stop progress")
driver.move({ map = 1, x = 0, y = -400 })
driver.update(0.1)
equal(API.CurrentStop("AGF"), nil, "final arrival releases ownership")
equal(ns.HasJourney(), false, "final arrival ends journey")
equal(driver.waypoint(), nil, "final arrival clears guidance")

driver.move({ map = 1, x = 0, y = 0 })
for _, startRoute in ipairs({
	function()
		return API.Navigate("AGF", 1, 0.502, 0.5, "Only")
	end,
	function()
		return API.NavigateRoute("AGF", { { map = 1, x = 0.502, y = 0.5, title = "Only" } })
	end,
}) do
	driver.move({ map = 1, x = 0, y = 0 })
	equal(startRoute(), true, "one-stop form starts")
	equal(API.CurrentStop("AGF"), 1, "one-stop index")
	equal(ns.JourneyInfo(), "Journey to Only", "one-stop copy unchanged")
	driver.move({ map = 1, x = 0, y = -100 })
	driver.update(0.1)
	equal(API.CurrentStop("AGF"), nil, "one-stop form finishes")
end
driver.move({ map = 1, x = 0, y = 0 })
equal(API.NavigateRoute("AGF", stops), true, "restart route")
equal(API.Navigate("AGF", 1, 0.51, 0.5), true, "same owner replaces route")
equal(ns.JourneyStops(), nil, "one-stop replacement discards remaining stops")
API.NavigateRoute("AGF", stops)
driver.begin({ map = 1, x = 0, y = 0 }, { map = 1, x = 2000, y = 0 })
equal(API.CurrentStop("AGF"), nil, "manual journey discards entire route")
equal(API.Cancel("AGF"), false, "manual journey cannot be cancelled by former owner")
API.NavigateRoute("AGF", stops)
equal(API.Cancel("AGF"), true, "owner cancels entire route")
driver.move({ map = 1, x = 0, y = -100 })
driver.update(0.1)
equal(ns.HasJourney(), false, "cancelled stops cannot restart")
for i = 1, 64 do
	many[i] = { map = 1, x = 0.502, y = 0.5 }
end
many[65] = nil
equal(API.NavigateRoute("AGF", many), true, "coincident stops accepted")
equal(API.CurrentStop("AGF"), 1, "coincident route does not recurse on start")
driver.update(0.1)
equal(API.CurrentStop("AGF"), 2, "at most one coincident stop starts per update")
API.Cancel("AGF")
driver.update(0.1)
equal(API.CurrentStop("AGF"), nil, "cancel discards pending advancement")
equal(ns.HasJourney(), false, "pending advancement stays cancelled")

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

-- Teleports count only from where you stand: 5000 yards on foot, or a hearth 10 yards short of the goal.
ns.teleports = { { map = 1, x = 0, y = 4990, spell = 8690, item = 6948, cast = 10000, bind = true } }
ns.teleportReady = { ns.NowMs() }
driver.move({ map = 1, x = 0, y = 0 })
near(API.Estimate(1, 0.5, 0.5, 1, 0.4, 0.5), 10 + 10 / 7, "hearth from here")
near(API.Estimate(1, 0.49, 0.5, 1, 0.4, 0.5), 4500 / 7, "no hearth on a later leg")
ns.teleportReady = {}
near(API.Estimate(1, 0.5, 0.5, 1, 0.39, 0.5), 5500 / 7, "no hearth while it cannot be cast")
ns.teleports, ns.teleportReady = nil, nil

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
