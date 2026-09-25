-- Each case boots a fresh addon against Blizzard's real waypoint provider, without a game client.
local dir = arg[0]:match("^(.*)/") or "tests"
local source = ""
for _, part in ipairs({ "ui_client.lua", "ui_map.lua" }) do
	local file = assert(io.open(dir .. "/" .. part))
	source = source .. file:read("*a")
	file:close()
end
local setup = [[
visible, WorldMapFrame.shown = true, true
posX, posY, posMap, facing = 0, 0, 1, 0
ns.CurrentRide = noop
ns.Planner.Plan = function(o)
 return {now=o.now, arrive=o.now+200000, legs={{mode="walk", from=o.from, to=o.to,
  yards=1400, depart=o.now, arrive=o.now+200000}}}
end
ns.Planner.WalkPoints = function(a, b)
 return {a, {map=1,x=100,y=100}, {map=1,x=300,y=100}, b}
end
local function start()
 posX, posY, posMap = 0, 0, 1
 mapID, cursorX, cursorY = 1414, 0.5, 0.452
 assert(clickHandlers[1](map, "LeftButton"))
 assert(ns.IsJourneyGuided() and waypoint and supertracked)
end
local function record()
 local saved = assert(ns.charDB.guideWaypoint, "Guide must persist ownership of its last write")
 assert(saved.uiMapID == waypoint.uiMapID and saved.x == waypoint.position.x and saved.y == waypoint.position.y)
end
local function pin(shown)
 assert(waypointProvider.pin and waypointProvider.pin:IsShown() == shown, "native pin visibility")
end
local function manual()
 C_SuperTrack.SetSuperTrackedQuestID(71)
 C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(1414, 0.7, 0.8, 42))
 C_SuperTrack.SetSuperTrackedUserWaypoint(true)
end
local function restored()
 assert(waypoint and waypoint.uiMapID == 1414 and waypoint.position.x == 0.7 and waypoint.position.y == 0.8)
 assert(waypoint.z == 42 and supertracked and trackedQuest == 71, "restore the player's pin and tracking")
 assert(not ns.charDB.guideWaypoint, "restored player pins must not retain Guide ownership")
 pin(true)
end
]]
local failures = {}
local function check(name, beforeLogin, body)
	local fixture = source:gsub('fireEvent%("ADDON_LOADED", "ShortestPathForever"%)', function()
		return beforeLogin
			.. '\nwaypointProvider:RefreshAllData()\nfireEvent("ADDON_LOADED", "ShortestPathForever")\nfireEvent("PLAYER_LOGIN")'
	end, 1)
	local run = assert(
		loadstring(
			"_G.ShortestPathForeverDB, _G.ShortestPathForeverCharDB = nil, nil\n"
				.. fixture
				.. setup
				.. body
				.. '\nassert(#errors == 0, table.concat(errors, "\\n"))',
			name
		)
	)
	local ok, err = pcall(run)
	if ok then
		print("waypoint_ui: " .. name .. " ok")
	else
		failures[#failures + 1] = name .. ": " .. err
	end
end

local orphan = [[
ShortestPathForeverCharDB = {guideWaypoint={uiMapID=1414,x=0.4,y=0.3}}
waypoint = UiMapPoint.CreateFromCoordinates(1414, 0.4, 0.3)
supertracked = true
]]
check(
	"reload orphan cleanup",
	orphan,
	[[
assert(not waypoint and not supertracked, "login must clear Guide's persisted waypoint and tracking")
assert(not ns.charDB.guideWaypoint)
start() record() ns.ClearJourney()
assert(not waypoint and not supertracked, "a new journey must not restore the orphan")
]]
)

check(
	"entering world and active journey",
	"",
	[[
ns.charDB.guideWaypoint = {uiMapID=1414,x=0.4,y=0.3}
waypoint = UiMapPoint.CreateFromCoordinates(1414, 0.4, 0.3)
supertracked = true
fireEvent("PLAYER_ENTERING_WORLD")
assert(not waypoint and not supertracked, "entering world must clear an orphan")
start()
local current = waypoint
fireEvent("PLAYER_ENTERING_WORLD")
assert(waypoint == current and ns.IsJourneyGuided(), "zone transitions must preserve an active journey")
record() ns.ClearJourney()
]]
)

check(
	"login preserves a different player pin",
	orphan .. [[
waypoint = UiMapPoint.CreateFromCoordinates(1414, 0.7, 0.8, 42)
trackedQuest = 71
]],
	[[
restored()
start() ns.ClearJourney() restored()
]]
)

check(
	"quantized read-back stays owned",
	"",
	[[
-- Turn by turn, so Guide moves along the walk's bends (step-end marks are the default since #44).
ns.db.guideStops = false
start()
waypoint = UiMapPoint.CreateFromCoordinates(1414, waypoint.position.x + 0.00001, waypoint.position.y)
fireEvent("USER_WAYPOINT_UPDATED")
assert(ns.IsJourneyGuided(), "a quarter-yard read-back change must not end Guide")
pin(false)
posX, posY = 100, 100
arrowFrame.scripts.OnUpdate(arrowFrame, 0.1)
local _, world = C_Map.GetWorldPosFromMapPos(waypoint.uiMapID, waypoint.position)
assert(math.abs(world.x - 300) < 0.001, "Guide must still move to the next bend")
record() ns.ClearJourney()
assert(not waypoint and not supertracked and not ns.charDB.guideWaypoint)
]]
)

local reproject = [[
local worldFromMap = C_Map.GetWorldPosFromMapPos
C_Map.GetWorldPosFromMapPos = function(m, v)
 if m == 777 then return worldFromMap(1414, CreateVector2D(v.x / 2, v.y / 2)) end
 return worldFromMap(m, v)
end
]]
check(
	"reprojected read-back clears on end",
	reproject,
	[[
start()
waypoint = UiMapPoint.CreateFromCoordinates(777, waypoint.position.x * 2, waypoint.position.y * 2)
fireEvent("USER_WAYPOINT_UPDATED")
assert(ns.IsJourneyGuided(), "a different map ID for the same world point is still ours")
pin(false)
ns.ClearJourney()
assert(not waypoint and not supertracked, "ending must remove the reprojected Guide point")
assert(not ns.charDB.guideWaypoint)
]]
)

check(
	"reprojected reload orphan",
	reproject .. orphan .. [[
waypoint = UiMapPoint.CreateFromCoordinates(777, 0.8, 0.6)
]],
	[[
assert(not waypoint and not supertracked and not ns.charDB.guideWaypoint)
]]
)

check(
	"yield clears Guide immediately",
	"",
	[[
start()
C_SuperTrack.SetSuperTrackedQuestID(99)
assert(not waypoint and not supertracked, "yield must remove the stale bend immediately")
assert(ns.IsJourneyGuided() and trackedQuest == 99 and not ns.charDB.guideWaypoint)
local calls = waypointCalls
posX, posY = 100, 100
arrowFrame.scripts.OnUpdate(arrowFrame, 0.1)
assert(waypointCalls == calls and arrowFrame.alpha == 1, "yield keeps the existing fallback behavior")
ns.ClearJourney()
assert(not waypoint and trackedQuest == 99)
]]
)

check(
	"yield preserves later tracking and restores a genuine pin",
	"",
	[[
manual() start()
C_SuperTrack.SetSuperTrackedQuestID(99)
assert(not waypoint and not ns.charDB.guideWaypoint)
ns.ClearJourney()
assert(waypoint and waypoint.position.x == 0.7 and waypoint.z == 42 and not supertracked and trackedQuest == 99)
pin(true)
]]
)

check(
	"end restores player pin",
	"",
	[[
manual() start() record() pin(false)
ns.ClearJourney() restored()
start() ns.ToggleJourneyGuide() restored() ns.ClearJourney()
start()
posX = 1190
ShortestPathForeverJourneyDriver.scripts.OnUpdate(ShortestPathForeverJourneyDriver, 0.1)
assert(not ns.HasJourney(), "arrival must end the journey")
restored()
]]
)

check(
	"quest turn-in restores player pin",
	"",
	[[
manual()
C_QuestLog.GetNextWaypointForMap = function() return 0.5, 0.452 end
C_QuestLog.GetTitleForQuestID = function() return "Test quest" end
local quest = {pinTemplate="QuestPinTemplate", GetMap=function() return map end,
 GetQuestID=function() return 7 end, GetStyle=function() return POIButtonUtil.Style.Waypoint end}
mouseFoci = {quest}
assert(pinHandlers[1](map, MapCanvasMixin.MouseAction.Click, "LeftButton"))
assert(ns.IsJourneyGuided() and waypoint and supertracked)
fireEvent("QUEST_TURNED_IN", 7)
assert(not ns.HasJourney())
restored()
]]
)

check(
	"native refresh, map change and reopen",
	"",
	[[
manual() start() pin(false)
waypointProvider:RefreshAllData() pin(false)
mapID = 1415
waypointProvider:OnMapChanged()
assert(not waypointProvider.pin, "a map with no projection has no pin")
mapID = 1414
waypointProvider:OnMapChanged() pin(false)
waypointProvider:OnHide()
waypointProvider:RefreshAllData(true)
waypointProvider:OnShow() pin(false)
ns.ToggleJourneyGuide() restored()
start()
waypointProvider:OnHide()
visible, WorldMapFrame.shown = false, false
local acquire = map.AcquirePin
map.AcquirePin = function() error("a closed map must not acquire pins") end
ns.ToggleJourneyGuide()
assert(waypoint and waypoint.position.x == 0.7 and supertracked and not ns.charDB.guideWaypoint)
map.AcquirePin = acquire
visible, WorldMapFrame.shown = true, true
waypointProvider:RefreshAllData(true)
waypointProvider:OnShow()
restored()
ns.ClearJourney()
]]
)

check(
	"player pin stays visible before any successful write",
	"",
	[[
manual()
C_Map.SetUserWaypoint = function() return false end
mapID, cursorX, cursorY = 1414, 0.5, 0.452
assert(clickHandlers[1](map, "LeftButton"))
waypointProvider:RefreshAllData()
pin(true)
ns.ToggleJourneyGuide()
pin(true)
assert(not ns.charDB.guideWaypoint)
]]
)

check(
	"manual replacement and removal",
	"",
	[[
manual() start()
local replacement = UiMapPoint.CreateFromCoordinates(1414, 0.2, 0.1)
C_Map.SetUserWaypoint(replacement)
assert(not ns.IsJourneyGuided() and waypoint == replacement and not ns.charDB.guideWaypoint)
pin(true)
ns.ClearJourney()
assert(waypoint == replacement)
start() C_Map.ClearUserWaypoint()
assert(not ns.IsJourneyGuided() and not ns.charDB.guideWaypoint)
ns.ClearJourney()
assert(not waypoint, "manual removal must not restore an earlier pin")
]]
)

check(
	"replacement before its deferred event",
	"",
	[[
start()
local replacement = UiMapPoint.CreateFromCoordinates(1414, 0.2, 0.1)
waypoint = replacement
posX, posY = 100, 100
arrowFrame.scripts.OnUpdate(arrowFrame, 0.1)
assert(waypoint == replacement, "a bend update must not overwrite a pending manual replacement")
fireEvent("USER_WAYPOINT_UPDATED")
assert(not ns.IsJourneyGuided() and not ns.charDB.guideWaypoint)
pin(true)
ns.ClearJourney()
assert(waypoint == replacement)
]]
)

check(
	"yield before its deferred event",
	"",
	[[
start()
trackedQuest, supertracked = 99, false
posX, posY = 100, 100
arrowFrame.scripts.OnUpdate(arrowFrame, 0.1)
assert(not waypoint and not supertracked and trackedQuest == 99, "a bend update must honor pending quest tracking")
fireEvent("SUPER_TRACKING_CHANGED")
assert(ns.IsJourneyGuided() and not ns.charDB.guideWaypoint)
ns.ClearJourney()
assert(not waypoint and trackedQuest == 99)
]]
)

check(
	"start never captures an orphan as the player's pin",
	"",
	[[
ns.charDB.guideWaypoint = {uiMapID=1414,x=0.4,y=0.3}
waypoint = UiMapPoint.CreateFromCoordinates(1414, 0.4, 0.3)
supertracked = true
start() record() ns.ClearJourney()
assert(not waypoint and not supertracked and not ns.charDB.guideWaypoint)
]]
)

check(
	"end cleans up before a reprojected event",
	reproject,
	[[
manual() start()
waypoint = UiMapPoint.CreateFromCoordinates(777, waypoint.position.x * 2, waypoint.position.y * 2)
ns.ClearJourney()
restored()
]]
)

check(
	"projection failure releases the persisted point",
	"",
	[[
manual() start() record()
playerUiMap = 778
arrowFrame.scripts.OnUpdate(arrowFrame, 0.1)
assert(not waypoint and not supertracked and not ns.charDB.guideWaypoint)
fireEvent("USER_WAYPOINT_UPDATED")
fireEvent("SUPER_TRACKING_CHANGED")
assert(ns.IsJourneyGuided(), "Guide must recognize its own deferred clear")
playerUiMap = nil
arrowFrame.scripts.OnUpdate(arrowFrame, 0.1)
record() pin(false)
ns.ClearJourney() restored()
]]
)

check(
	"failed restoration still removes Guide",
	"",
	[[
manual() start()
C_Map.SetUserWaypoint = function() return false end
ns.ClearJourney()
assert(not waypoint and not supertracked, "a rejected restoration must not leave Guide's bend behind")
assert(trackedQuest == 71 and not ns.charDB.guideWaypoint)
]]
)

assert(#failures == 0, table.concat(failures, "\n"))
