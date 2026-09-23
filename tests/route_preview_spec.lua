-- A route through Darkshore, Redridge and back previews each later crossing as its real boat, never a line at sea.
local driver = assert(loadfile("tests/journey_driver.lua"))()
local ns, env, checks = driver.ns, driver.env, 0
for _, file in ipairs({
	"Data/Routes.lua",
	"Data/Transports.lua",
	"Data/Taxi.lua",
	"Data/Portals.lua",
	"Data/Walks.lua",
	"Path.lua",
	"API.lua",
}) do
	driver.load(file)
end
for _, map in ipairs({ 0, 1 }) do
	assert(loadfile("tools/load_nav.lua"))(map)
end
local function check(value, label)
	checks = checks + 1
	assert(value, label)
end
local frames = {}
ns.Path.after = function(fn)
	frames[#frames + 1] = fn
end
local function step()
	local due = frames
	frames = {}
	for _, fn in ipairs(due) do
		fn()
	end
	return #due > 0
end
local refreshed, planned = 0, {}
local plan = ns.Planner.Plan
ns.Planner.Plan = function(options)
	local started = os.clock()
	local result = plan(options)
	-- Only the preview's estimates plan without endpoint walks.
	if not options.walks then
		planned[#planned + 1] = string.format("%.2f", (os.clock() - started) * 1000)
	end
	return result
end
ns.RefreshJourneyPreview = function()
	refreshed = refreshed + 1
end
ns.faction, ns.speed, ns.known = "Alliance", 7, {}
local API = env.ShortestPathForever.API
-- Kalimdor is continent 1 on uiMap 1439 (Darkshore); the Eastern Kingdoms are continent 0 on uiMap 49 (Redridge).
local project = env.C_Map.GetWorldPosFromMapPos
env.C_Map.GetWorldPosFromMapPos = function(map, point)
	local _, world = project(map, point)
	return map == 49 and 0 or map == 1439 and 1 or map, world
end
local function stop(node, dx, dy)
	return { map = node.map == 0 and 49 or 1439, x = 0.5 - (node.y + dy) / 50000, y = 0.5 - (node.x + dx) / 50000 }
end
local auberdine, lakeshire = ns.TaxiNodes[26], ns.TaxiNodes[5]
local stops = { stop(auberdine, 60, 40), stop(auberdine, -80, 60), stop(lakeshire, 40, 20), stop(auberdine, 100, -50) }

local function crossings(paths)
	local boats, straight = 0, 0
	for _, path in ipairs(paths) do
		for index = 2, #path.points do
			if path.preview and path.points[index - 1].map ~= path.points[index].map then
				straight = straight + 1
			end
		end
		if path.mode == "boat" and path.points[1].map ~= path.points[#path.points].map then
			boats = boats + 1
		end
	end
	return boats, straight
end

driver.move({ map = 1, x = auberdine.x + 20, y = auberdine.y + 10, z = auberdine.z })
check(API.NavigateRoute("Spec", stops), "route starts")
-- The journey's own searches run first; the preview waits for them rather than sharing their frames.
local boats, straight = crossings(ns.JourneyPreview())
check(boats == 0 and straight == 2, "unplanned crossings stay two-point hops for the map's end marks")
local busy = ns.Path.Busy
ns.Path.Busy = function()
	return true
end
step()
check(refreshed == 0, "no crossing planned while searches hold frames")
ns.Path.Busy = busy
env.InCombatLockdown = function()
	return true
end
while step() do
end
check(refreshed == 0 and #frames == 0, "combat stops preview planning without polling")
env.InCombatLockdown = function() end
driver.fire("PLAYER_REGEN_ENABLED")
check(#frames > 0, "leaving combat resumes preview planning")
local slowest = 0
while #frames > 0 do
	local before, started = refreshed, os.clock()
	step()
	if refreshed > before then
		check(refreshed == before + 1, "one crossing planned per frame")
		slowest = math.max(slowest, (os.clock() - started) * 1000)
	end
end
check(refreshed == 2, "both crossings planned once")
boats, straight = crossings(ns.JourneyPreview())
check(straight == 0, "no preview segment spans continents")
check(boats == 2, "both later crossings draw as boat legs")
for _, path in ipairs(ns.JourneyPreview()) do
	check(path.preview or path.mode ~= "walk", "planned walking legs stay dotted previews")
end
ns.JourneyPreview()
check(#frames == 0, "cached crossings plan nothing again")

ns.JourneyChanged(nil)
check(#ns.JourneyPreview() == 0, "a cancelled route previews nothing")

-- A crossing the planner cannot route is remembered as such: it keeps its end marks and is never asked again.
local reachable = ns.Planner.Plan
ns.Planner.Plan = function(options)
	if not options.walks then
		return nil
	end
	return reachable(options)
end
check(API.NavigateRoute("Spec", { stops[1], stops[3] }), "unreachable route starts")
local before = refreshed
ns.JourneyPreview()
-- Bounded: a crossing forgotten after a failed plan would ask again every frame.
for _ = 1, 200 do
	step()
end
check(refreshed == before + 1, "an unreachable crossing is planned once")
ns.JourneyPreview()
step()
boats, straight = crossings(ns.JourneyPreview())
check(refreshed == before + 1 and #frames == 0, "an unreachable crossing is not planned again")
check(boats == 0 and straight == 1, "an unreachable crossing keeps its two-point hop")
ns.Planner.Plan = reachable
print(
	string.format(
		"route_preview_spec: %d checks passed; crossing plans %s ms, slowest frame planning one %.2f ms",
		checks,
		table.concat(planned, " / "),
		slowest
	)
)
