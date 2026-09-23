-- A route through Darkshore, Redridge and back draws every later hop along its planned way: walks on the walking
-- map, crossings as their real boat, never a line at sea. Straight dots stand in only until a hop is ready.
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
	"Itinerary.lua",
}) do
	driver.load(file)
end
-- Kalimdor's walking map is loaded up front; the Eastern Kingdoms' loads only when a later hop walks there.
assert(loadfile("tools/load_nav.lua"))(1)
local loaded = {}
env.C_AddOns = {
	DoesAddOnExist = function()
		return true
	end,
	LoadAddOn = function(name)
		loaded[#loaded + 1] = name
		assert(loadfile("tools/load_nav.lua"))(tonumber(name:match("%d+$")))
	end,
}
local function check(value, label)
	checks = checks + 1
	assert(value, label)
end
local frames = {}
ns.Path.after = function(fn)
	frames[#frames + 1] = fn
end
-- The walking map's own load is one atomic client call the search gives a frame of its own; it is left out.
local slowest, frame = 0, 0
local function step()
	local due, started, loads = frames, os.clock(), #loaded
	frames, frame = {}, frame + 1
	for _, fn in ipairs(due) do
		fn()
	end
	if #loaded == loads then
		slowest = math.max(slowest, (os.clock() - started) * 1000)
	end
	return #due > 0
end
local function drain()
	local count = 0
	while step() do
		count = count + 1
		assert(count < 20000, "the itinerary never settled")
	end
end
local refreshed, planned, searched, plannedIn = 0, {}, 0, nil
local plan = ns.Planner.Plan
ns.Planner.Plan = function(options)
	local started = os.clock()
	local result = plan(options)
	-- Only the itinerary's estimates plan without endpoint walks.
	if not options.walks then
		planned[#planned + 1] = string.format("%.2f", (os.clock() - started) * 1000)
		plannedIn = frame
	end
	return result
end
local find = ns.Path.Find
-- The frames each later walk was queued and finished in.
local walked = {}
ns.Path.Find = function(map, from, to, callback, waterWalking)
	searched = searched + 1
	if not debug.traceback():find("Itinerary.lua", 1, true) then
		return find(map, from, to, callback, waterWalking)
	end
	local entry = { queued = frame }
	walked[#walked + 1] = entry
	return find(map, from, to, function(...)
		entry.finished = frame
		return callback(...)
	end, waterWalking)
end
-- Redrawing every later hop is a frame's work of its own: never inside a search slice's callback, nor after a plan.
ns.RefreshJourneyPreview = function()
	refreshed = refreshed + 1
	check(not debug.traceback():find("Path.lua", 1, true), "no redraw inside a search callback")
	check(plannedIn ~= frame, "no redraw in a hop plan's frame")
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
local stops = {
	stop(auberdine, 60, 40),
	stop(auberdine, -80, 60),
	stop(lakeshire, 40, 20),
	stop(auberdine, 100, -50),
}

-- Boats between continents, straight preview segments across them, and walks still drawn as placeholders.
local function count(paths)
	local boats, straight, placeholders, walks = 0, 0, 0, 0
	for _, path in ipairs(paths) do
		for index = 2, #path.points do
			if path.preview and path.points[index - 1].map ~= path.points[index].map then
				straight = straight + 1
			end
		end
		if path.mode == "boat" and path.points[1].map ~= path.points[#path.points].map then
			boats = boats + 1
		end
		if path.preview then
			placeholders = placeholders + 1
		elseif path.mode == "walk" then
			walks = walks + 1
		end
	end
	return boats, straight, placeholders, walks
end

driver.move({ map = 1, x = auberdine.x + 20, y = auberdine.y + 10, z = auberdine.z })
check(API.NavigateRoute("Spec", stops), "route starts")
local boats, straight, placeholders = count(ns.JourneyPreview())
check(boats == 0 and straight == 2 and placeholders == 1, "one straight placeholder until any hop is planned")
local busy = ns.Path.Busy
ns.Path.Busy = function()
	return true
end
step()
check(refreshed == 0, "no hop planned while searches hold frames")
ns.Path.Busy = busy
env.InCombatLockdown = function()
	return true
end
while step() do
end
check(refreshed == 0 and #frames == 0, "combat stops itinerary planning without polling")
env.InCombatLockdown = function() end
driver.fire("PLAYER_REGEN_ENABLED")
check(#frames > 0, "leaving combat resumes itinerary planning")
-- The journey's own search for the first stop settles before any later hop is planned.
while refreshed == 0 do
	check(step(), "the itinerary waits for the journey, then plans")
end
check(not ns.JourneyStatus(), "the current leg settled first")
local first = ns.JourneyPreview()[1]
check(first.mode == "walk" and first.preview and #first.points == 2, "the first hop's walk starts straight")
check(first.points[1].map == first.points[2].map, "a same-continent hop is planned, not left as a chain")
local before = searched
drain()
check(searched > before, "later walks were searched")
for index = 2, #walked do
	check(walked[index].queued == walked[index - 1].finished, "each later walk is queued as the one before finishes")
end
check(refreshed == 2, "within a second, drawn once for the first hop and once when every hop is ready")
check(not first.preview and #first.points > 2, "the placeholder is replaced by the walking-map path")
check(ns.JourneyPreview()[1] == first, "the planned hop draws in place of its placeholder")
check(#loaded == 1 and loaded[1] == "ShortestPathForever_Nav0", "Redridge's walks load their walking map on demand")
local walks
boats, straight, placeholders, walks = count(ns.JourneyPreview())
check(straight == 0, "no preview segment spans continents")
check(boats == 2, "both later crossings draw as boat legs")
check(placeholders == 0, "every later walk follows its walking-map path")
check(walks >= 3, "each hop's walks are drawn")

-- Replanning the current leg, or sending the same stops again, reuses every later hop.
local plans, searches, drawn = #planned, searched, ns.JourneyPreview()
driver.update(0.1)
ns.StartJourney((ns.JourneyStops())[1])
check(API.NavigateRoute("Spec", stops), "the same stops again")
local again = ns.JourneyPreview()
check(#again == #drawn and again[1] == drawn[1] and again[#again] == drawn[#drawn], "later hops kept")
drain()
check(#planned == plans and searched - searches <= 2, "no later hop planned or searched again")

-- A changed stop plans only the hops it touches.
local moved = { stops[1], stops[2], stops[3], stop(auberdine, 140, -90) }
check(API.NavigateRoute("Spec", moved), "one stop moved")
check(ns.JourneyPreview()[1] == drawn[1], "the unchanged hops are reused")
drain()
check(#planned == plans + 1, "only the changed hop is planned again")

-- Cancelling mid-search drops the in-flight walk and every hop.
local jobs = {}
ns.Path.Find = function(...)
	local job = find(...)
	if debug.traceback():find("Itinerary.lua", 1, true) then
		jobs[#jobs + 1] = job
	end
	return job
end
check(API.NavigateRoute("Spec", { stops[2], stops[1], stops[2] }), "a fresh route")
while #jobs == 0 do
	check(step(), "the fresh route searches")
end
local job = jobs[#jobs]
-- A thin slice keeps this short walk in flight across frames.
local budget = ns.Path.budget
ns.Path.budget = 0.01
-- While the journey replans, an in-flight later walk pauses; it resumes once the journey settles.
local status = ns.JourneyStatus
ns.JourneyStatus = function()
	return true
end
step()
check(job.paused and not job.done, "a later walk yields to the journey's search")
ns.JourneyStatus = status
step()
check(not job.paused, "then resumes")
ns.Path.budget = budget
ns.ClearJourney()
check(job.cancelled, "cancelling the journey cancels the later walk")
check(#ns.JourneyPreview() == 0, "a cancelled route previews nothing")
refreshed = 0
drain()
check(refreshed == 0, "nothing is drawn for a cancelled route")
ns.Path.Find = find

-- A crossing the planner cannot route is remembered as such: it keeps its end marks and is never asked again.
local reachable = ns.Planner.Plan
ns.Planner.Plan = function(options)
	if not options.walks then
		return nil
	end
	return reachable(options)
end
check(API.NavigateRoute("Spec", { stops[1], stops[3] }), "unreachable route starts")
refreshed = 0
drain()
check(refreshed == 1, "an unreachable crossing is planned once")
ns.JourneyPreview()
drain()
boats, straight = count(ns.JourneyPreview())
check(refreshed == 1 and #frames == 0, "an unreachable crossing is not planned again")
check(boats == 0 and straight == 1, "an unreachable crossing keeps its two-point hop")
ns.Planner.Plan = reachable
print(
	string.format(
		"route_preview_spec: %d checks passed; hop plans %s ms, slowest frame %.2f ms",
		checks,
		table.concat(planned, " / "),
		slowest
	)
)
