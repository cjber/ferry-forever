-- The itinerary asks whether the journey's timed replan is due on frames before the journey's own frame has run
-- once: a route just set or replaced, a caller re-sending fewer stops, one queued while you are a ghost.
local driver = assert(loadfile("tests/journey_driver.lua"))()
local ns, env = driver.ns, driver.env
local ghost, corpse = false, nil
local maps = { [1] = { mapType = 3, parentMapID = 10 }, [10] = { mapType = 2, parentMapID = 0 } }
env.UnitIsGhost = function()
	return ghost
end
env.C_DeathInfo = {
	GetCorpseMapPosition = function(uiMap)
		return corpse and corpse[1] == uiMap and env.CreateVector2D(corpse[2], corpse[3]) or nil
	end,
}
env.C_Map.GetMapInfo = function(uiMap)
	return maps[uiMap]
end
env.Enum = { UIMapType = { Continent = 2 } }
env.C_Timer = {
	After = function(_, fn)
		fn()
	end,
}
env.CreateColor = function(r, g, b)
	return { r = r, g = g, b = b }
end
ns.db.corpse = true
for _, file in ipairs({
	"PathGrid.lua",
	"Path.lua",
	"PathJobs.lua",
	"Looks.lua",
	"API.lua",
	"Itinerary.lua",
	"Corpse.lua",
}) do
	driver.load(file)
end
local frames = {}
ns.Path.after = function(fn)
	frames[#frames + 1] = fn
end
-- One frame of the itinerary's scheduled work, without the journey's own frame.
local function step()
	local due = frames
	frames = {}
	for _, fn in ipairs(due) do
		fn()
	end
end
local API = env.ShortestPathForever.API
local stops = {
	{ map = 1, x = 0.5, y = 0.498, title = "First" },
	{ map = 1, x = 0.5, y = 0.496, title = "Second" },
	{ map = 1, x = 0.5, y = 0.494, title = "Third" },
	{ map = 1, x = 0.5, y = 0.492, title = "Last" },
}

assert(ns.JourneyReplanning() == false, "no replan is due before any journey")

-- Released at a graveyard before any journey this session: the caller's route queues behind the run, and the
-- itinerary plans its hops while the journey waits.
driver.move({ map = 1, x = 300, y = 400 })
corpse, ghost = { 1, 0.5, 0.5 }, true
driver.fire("PLAYER_ALIVE")
assert(ns.Corpse.Active(), "the corpse run is on")
assert(API.NavigateRoute("AGF", stops), "a route is accepted while you are a ghost")
step()
assert(ns.JourneyReplanning() == false, "a queued route has no replan due")
ghost = false
driver.fire("PLAYER_UNGHOST")
assert(not ns.Corpse.Active() and API.CurrentStop("AGF") == 1, "the route resumes")

-- Set, then replaced by the same caller with only the stops after the one you stand in.
driver.move({ map = 1, x = 0, y = 0 })
assert(API.NavigateRoute("AGF", stops))
assert(ns.JourneyReplanning() == false, "a new route has no replan due")
step()
assert(API.NavigateRoute("AGF", { stops[2], stops[3], stops[4] }))
assert(ns.JourneyReplanning() == false, "a shorter route has no replan due")
step()

-- The timed replan still counts from each route's start.
driver.update(4.6)
assert(ns.JourneyReplanning() == true, "due within the margin of the timed replan")
assert(API.NavigateRoute("AGF", { stops[3], stops[4] }))
assert(ns.JourneyReplanning() == false, "a replacement starts the count again")

-- Dying just as a replan came due: the run holds it, so the itinerary is not kept waiting.
driver.update(4.6)
assert(ns.JourneyReplanning() == true)
ghost = true
driver.fire("PLAYER_ALIVE")
assert(ns.Corpse.Active() and ns.JourneyReplanning() == false, "no replan runs while you are a ghost")
print("replan: ok")
