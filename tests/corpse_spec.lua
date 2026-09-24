-- A corpse run: released as a ghost, the way back to your corpse replaces the drawn journey in the tombstone's
-- red-orange; the journey waits and comes back when you live again.
local driver = assert(loadfile("tests/journey_driver.lua"))()
local ns, env = driver.ns, driver.env
local ghost, corpse = false, nil -- corpse = { uiMap, x, y }
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
local destination, drawn, arrow
ns.PointGuideArrow = function(_, _, stop)
	arrow = stop
end
ns.SetJourneyRoute = function(point, route)
	destination, drawn = point, route
end
driver.load("Looks.lua")
driver.load("API.lua")
driver.load("Itinerary.lua")
driver.load("Corpse.lua")
local API = env.ShortestPathForever.API

local function event(name)
	driver.fire(name)
	driver.update(0.1)
end
local function corpseAt(x, y)
	-- The driver's maps put world (x, y) at map fraction (0.5 - y / 50000, 0.5 - x / 50000).
	corpse = { 1, 0.5 - y / 50000, 0.5 - x / 50000 }
end
local function red(leg)
	local color = leg.color
	return color and math.abs(color.r - 192 / 255) < 1e-9 and math.abs(color.g - 76 / 255) < 1e-9
end

-- A journey you are on.
driver.begin({ map = 1, x = 0, y = 0, z = 0 }, { map = 1, x = 1200, y = 0 })
local goal = destination
assert(goal and not goal.corpse and drawn.legs[1].color == nil, "the journey draws in its own colours")

-- Dead but not released: you lie at your corpse, so nothing changes.
corpseAt(0, 0)
event("PLAYER_DEAD")
assert(destination == goal and not ns.Corpse.Active())

-- Released at a graveyard: the way back replaces the journey, in the tombstone's red-orange, without its pins.
ghost = true
driver.move({ map = 1, x = 300, y = 400 })
event("PLAYER_ALIVE")
assert(ns.Corpse.Active() and destination.corpse, "the corpse run is drawn")
assert(red(drawn.legs[1]) and drawn.legs[1].mode == "walk", "dotted in the corpse's red-orange")
local points = drawn.legs[1].walkPoints
assert(points[1].x == 300 and points[#points].x == 0 and points[#points].y == 0, "from you to the corpse")
local title, rows = ns.JourneyInfo()
assert(title == "Return to your corpse" and rows[1].text:find("^1%. Walk to your corpse"), rows[1].text)
assert(ns.HasJourney() and ns.IsJourneyGuided(), "the run is guided")
assert(arrow == destination, "Guide steers to the corpse")

-- The journey waits: neither its replans nor its arrival run while you are a ghost.
driver.update(6)
assert(destination.corpse and ns.JourneyStatus() == false)

-- Another addon's route while you are a ghost queues behind the run.
assert(API.Navigate("AGF", 1, 0.5, 0.49), "navigating as a ghost is accepted")
assert(destination.corpse and API.CurrentStop("AGF") == 1, "the corpse run stays until you are alive")
-- Clearing the journey leaves the run.
ns.ClearJourney()
assert(ns.Corpse.Active() and destination.corpse and API.CurrentStop("AGF") == nil)
assert(API.Navigate("AGF", 1, 0.5, 0.49), "queued again")
local queued = API.CurrentStop("AGF")

-- Walking back: the line starts where you stand, and the time counts down.
driver.move({ map = 1, x = 150, y = 200 })
driver.update(0.6)
assert(drawn.legs[1].walkPoints[1].x == 150)

-- Resurrected at the corpse: the run ends and the queued journey plans from here, guided.
ghost = false
event("PLAYER_UNGHOST")
assert(not ns.Corpse.Active() and destination and not destination.corpse, "the journey is back")
assert(queued == 1 and API.CurrentStop("AGF") == 1 and drawn.legs[1].color == nil, "the caller's route resumes")
assert(ns.JourneyInfo() ~= "Return to your corpse" and ns.IsJourneyGuided())

-- The journey you were on comes back as it was, unguided if you had turned Guide off.
ns.ToggleJourneyGuide()
assert(not ns.IsJourneyGuided())
local before = destination
ghost = true
event("PLAYER_ALIVE")
assert(destination.corpse and ns.IsJourneyGuided(), "the run guides even when the journey did not")
ghost = false
event("PLAYER_ALIVE")
assert(destination == before and not ns.IsJourneyGuided(), "restored exactly, Guide still off")

-- The setting turns runs off, and turning it off mid-run brings the journey back.
ghost = true
ns.db.corpse = false
event("PLAYER_ALIVE")
assert(not ns.Corpse.Active() and destination == before)
ns.db.corpse = true
ns.RefreshCorpseRun()
assert(ns.Corpse.Active())
ns.db.corpse = false
ns.RefreshCorpseRun()
assert(not ns.Corpse.Active() and destination == before)
ns.db.corpse = true

-- A corpse only on the continent's map (the next zone over) is still found; one on another world map has no walk.
ghost = false
event("PLAYER_UNGHOST")
ns.ClearJourney()
corpse = { 10, 0.5, 0.5 }
ghost = true
event("PLAYER_ALIVE")
assert(ns.Corpse.Active() and destination.map == 10 and #drawn.legs[1].walkPoints == 0, "no line across maps")
title, rows = ns.JourneyInfo()
assert(title == "Return to your corpse" and rows[1].text:find("no walking path", 1, true))
-- One the client does not place on your maps at all gives no run.
corpse = { 99, 0.5, 0.5 }
event("ZONE_CHANGED_NEW_AREA")
assert(not ns.Corpse.Active() and destination == nil, "no journey to restore")

-- With a walking map, the run follows the searched path, walking on water as a ghost does.
local jobs = {}
ns.Path = {
	HasData = function()
		return true
	end,
	Find = function(_, from, to, callback, water)
		local job = { from = from, to = to, callback = callback, water = water }
		jobs[#jobs + 1] = job
		return job
	end,
	Cancel = function(job)
		job.cancelled = true
	end,
}
driver.move({ map = 1, x = 300, y = 0 })
corpseAt(0, 0)
event("PLAYER_ALIVE")
assert(#jobs == 1 and jobs[1].water == true, "one search, over water")
assert(#drawn.legs[1].walkPoints == 2, "a straight line until it is found")
local path = { { map = 1, x = 300, y = 0 }, { map = 1, x = 150, y = 60 }, { map = 1, x = 0, y = 0 } }
jobs[1].callback(path, 330)
assert(drawn.legs[1].walkPoints[2] == path[2] and red(drawn.legs[1]), "the found path, in red-orange")
-- Straying from it searches again, at most every five seconds.
driver.move({ map = 1, x = 300, y = 200 })
driver.update(5.1)
assert(#jobs == 2 and jobs[1].cancelled ~= true, "strayed: searched again from here")
ghost = false
event("PLAYER_UNGHOST")
assert(jobs[2].cancelled and not ns.Corpse.Active() and destination == nil)
print("corpse: ok")
