local _, ns = ...

-- Shift-click the world map: the fastest way there from here, by foot, flight, boat, zeppelin, tram and portal,
-- with the boats' live waits. The tracker owns the list; closing the map leaves the journey running.
local REPLAN_EVERY = 5
local SCHEDULED = { boat = true, zeppelin = true, tram = true }
local VERB = {
	walk = "Walk to",
	flight = "Fly to",
	boat = "Boat to",
	zeppelin = "Zeppelin to",
	tram = "Tram to",
	portal = "Portal to",
	passage = "Go through to",
}

local goal, guide, result
local progress = { index = 1 }
local driver
local ARRIVAL = 15

local function NodeLabel(node)
	if node.kind == "start" then
		return "your position"
	elseif node.kind == "dock" then
		return ns.DockTitle(node.id)
	elseif node.kind == "taxi" then
		return ns.TaxiNodes[node.id].name
	elseif node.label then
		return node.label
	end
	local location = ns.Locate(node)
	return location and location.zone or UNKNOWN
end

local function LegTime(leg)
	local text = ns.FormatCountdown(leg.arrive - leg.depart)
	if leg.wait and leg.wait > 0 then
		text = "wait " .. ns.FormatCountdown(leg.wait) .. " · " .. text
	end
	return text
end

local function Near(node)
	local x, y, _, map = UnitPosition("player")
	return x and map == node.map and (x - node.x) ^ 2 + (y - node.y) ^ 2 <= ARRIVAL ^ 2
end

local function SameWaypoint(a, b)
	if not (a and b and a.uiMapID == b.uiMapID) then
		return false
	end
	local ax, ay = a.position:GetXY()
	local bx, by = b.position:GetXY()
	return math.abs(ax - bx) < 0.000001 and math.abs(ay - by) < 0.000001
end

local function StopGuide()
	if guide and SameWaypoint(C_Map.GetUserWaypoint(), guide.waypoint) then
		C_Map.ClearUserWaypoint()
		C_SuperTrack.SetSuperTrackedUserWaypoint(false)
	end
	guide = nil
	ns.PointGuideArrow(nil)
end

local function OwnsWaypoint()
	if guide.waypoint and not SameWaypoint(C_Map.GetUserWaypoint(), guide.waypoint) then
		-- A manual replacement or removal ends guidance; never reclaim the player's waypoint.
		StopGuide()
		return false
	end
	return true
end

local function GuideTo(node, points)
	if not guide or guide.target == node then
		return
	end
	local point = node.kind == "dock" and ns.DockPoint(node.id) or node
	local location = ns.Locate(point)
	if not (location and C_Map.CanSetUserWaypointOnMap(location.uiMap)) then
		ns.Print("that stop cannot hold a map waypoint.")
		StopGuide()
		return
	end
	local waypoint = UiMapPoint.CreateFromCoordinates(location.uiMap, location.x, location.y)
	if not SameWaypoint(waypoint, guide.waypoint) then
		-- WaypointLocationDataProvider.lua:100; SuperTrackedFrame.lua:219,289 supplies native navigation.
		if not C_Map.SetUserWaypoint(waypoint) then
			StopGuide()
			return
		end
		guide.waypoint = C_Map.GetUserWaypoint()
		C_SuperTrack.SetSuperTrackedUserWaypoint(true)
	end
	ns.PointGuideArrow(points or { point })
	guide.target = node
end

function ns.ClearJourney()
	StopGuide()
	goal, result = nil, nil
	progress.index, progress.departed = 1, false
	driver:Hide()
	ns.SetJourneyRoute(nil)
	ns.RefreshTracker()
end

local function UpdateProgress()
	if guide then
		OwnsWaypoint()
	end
	if not (goal and result) then
		return
	end
	if Near(goal) then
		ns.ClearJourney()
		return
	end
	local riding, flying = ns.CurrentRide(), UnitOnTaxi("player")
	while progress.index <= #result.legs do
		local leg = result.legs[progress.index]
		local nextLeg = result.legs[progress.index + 1]
		if
			leg.mode == "walk"
			and nextLeg
			and ((nextLeg.route and riding == nextLeg.route) or (nextLeg.mode == "flight" and flying))
		then
			progress.index = progress.index + 1
			leg = nextLeg
		end
		local aboard = leg.aboard or (leg.route and riding == leg.route) or (leg.mode == "flight" and flying)
		if leg.mode ~= "walk" and not progress.departed then
			if aboard or Near(leg.from) then
				progress.departed = true
			else
				GuideTo(leg.from)
				return
			end
		end
		if not Near(leg.to) or (leg.mode == "flight" and flying) then
			GuideTo(leg.to, leg.walkPoints)
			return
		end
		progress.index, progress.departed = progress.index + 1, false
	end
	ns.ClearJourney()
end

function ns.IsJourneyGuided()
	return guide ~= nil
end

function ns.ToggleJourneyGuide()
	if guide then
		StopGuide()
	elseif result then
		guide = {}
		UpdateProgress()
	end
	ns.RefreshTracker()
end

function ns.ShowJourneyMap()
	local location = goal and ns.Locate(goal)
	OpenWorldMap(location and location.uiMap)
end

-- Shared by the tracker and the goal pin, including on a fullscreen map.
function ns.JourneyInfo()
	if not goal then
		return nil
	end
	local title = "Journey to " .. NodeLabel(goal)
	local rows = {}
	if result then
		title = title .. " · " .. ns.FormatCountdown(math.max(0, result.arrive - ns.NowMs()))
		for index = progress.index, #result.legs do
			local leg = result.legs[index]
			local text = string.format("%d. %s %s", index, VERB[leg.mode], NodeLabel(leg.to))
			if leg.mode == "walk" and leg.to.undiscovered then
				text = text .. " (new flight path)"
			end
			if leg.estimated and SCHEDULED[leg.mode] then
				text = text .. " (no sighting yet)"
			end
			rows[#rows + 1] = { key = index, text = text .. "   " .. LegTime(leg), current = index == progress.index }
		end
	else
		rows[1] = { key = "unreachable", text = "No way there from here." }
	end
	return title, rows
end

local function Refresh()
	local remaining
	if result then
		remaining = { now = result.now, arrive = result.arrive, legs = {} }
		for index = progress.index, #result.legs do
			remaining.legs[#remaining.legs + 1] = result.legs[index]
		end
	end
	ns.SetJourneyRoute(goal, remaining)
	ns.RefreshTracker()
end

local function Render(planned)
	if planned ~= result then
		progress.index, progress.departed = 1, false
		-- Resolve a walking path once per plan, shared by both maps and the bend-by-bend arrow.
		for _, leg in ipairs(planned and planned.legs or {}) do
			if leg.mode == "walk" then
				leg.walkPoints = ns.Planner.WalkPoints(leg.from, leg.to)
			end
		end
		if guide then
			guide.target = nil
		end
	end
	result = planned
	if not result then
		StopGuide()
	end
	UpdateProgress()
	Refresh()
end

local function Plan()
	local x, y, _, map = UnitPosition("player")
	if not (x and goal) then
		return nil
	end
	local _, runSpeed = GetUnitSpeed("player")
	local now = ns.NowMs()
	-- Taxi paths cannot be interrupted; retain their chosen destination until landing.
	if result and UnitOnTaxi("player") then
		result.now = now
		return result
	end
	local ride, routeID = nil, ns.CurrentRide()
	if routeID then
		local dock, arriveIn = ns.NextStop(routeID)
		if dock then
			ride = { route = routeID, dock = dock, arrive = now + arriveIn }
		end
	end
	local planned = ns.Planner.Plan({
		from = { map = map, x = x, y = y },
		to = goal,
		now = now,
		ride = ride,
		walkSpeed = math.max(runSpeed, 7),
		faction = UnitFactionGroup("player"),
		taxiKnown = ns.KnownTaxiNodes(),
		anchors = ns.FreshAnchors(),
		docks = ns.Docks,
		routes = ns.Routes,
		taxiNodes = ns.TaxiNodes,
		taxiPaths = ns.TaxiPaths,
		portals = ns.Portals,
		landmasses = ns.Landmasses,
	})
	if planned then
		planned.now = now
	end
	return planned
end

local function Update(self, elapsed)
	if not ns.db.journey then
		ns.ClearJourney()
		return
	end
	self.elapsed = self.elapsed + elapsed
	self.progressElapsed = self.progressElapsed + elapsed
	if self.progressElapsed < 0.1 then
		return
	end
	self.progressElapsed = 0
	local index = progress.index
	UpdateProgress()
	if not goal then
		return
	end
	local riding, flying = ns.CurrentRide(), UnitOnTaxi("player")
	local changedRide = riding ~= self.riding or flying ~= self.flying
	self.riding, self.flying = riding, flying
	if self.elapsed >= REPLAN_EVERY or changedRide then
		self.elapsed = 0
		Render(Plan())
	elseif index ~= progress.index then
		Refresh()
	end
end

local function StartJourney(point)
	if guide then
		StopGuide()
	end
	goal = point
	result = nil
	progress.index, progress.departed = 1, false
	driver.elapsed, driver.progressElapsed = 0, 0
	driver:Show()
	Render(Plan())
	return true
end

local function WorldPoint(uiMapID, x, y)
	local continent, world = C_Map.GetWorldPosFromMapPos(uiMapID, CreateVector2D(x, y))
	if continent and world then
		local worldX, worldY = world:GetXY()
		return { map = continent, x = worldX, y = worldY }
	end
end

local function PlanQuest(questID, clickedMap, isWaypoint)
	if not ns.db.journey then
		return
	end
	local uiMapID = clickedMap or GetQuestUiMapID(questID, true)
	local waypoint
	if not clickedMap or isWaypoint then
		local mapID, x, y
		if clickedMap then
			mapID = clickedMap
			x, y = C_QuestLog.GetNextWaypointForMap(questID, mapID)
		else
			mapID, x, y = C_QuestLog.GetNextWaypoint(questID)
		end
		waypoint = { uiMapID = mapID, x = x, y = y }
	end
	local pois = not isWaypoint and uiMapID and uiMapID > 0 and C_QuestLog.GetQuestsOnMap(uiMapID) or nil
	local location = ns.Planner.QuestDestination(
		questID,
		C_QuestLog.GetTitleForQuestID(questID),
		C_QuestLog.IsComplete(questID),
		uiMapID,
		pois,
		waypoint
	)
	local point = location and WorldPoint(location.uiMapID, location.x, location.y)
	if not point then
		-- Questie.API exposes icons and update notifications, but no public coordinate lookup.
		ns.Print("No location for that quest yet.")
		return
	end
	point.label, point.questID = location.label, questID
	StartJourney(point)
end

local function OnCanvasClick(map, button)
	if not ns.db.journey or button ~= "LeftButton" or not IsShiftKeyDown() then
		return false
	end
	local point = WorldPoint(map:GetMapID(), map:GetNormalizedCursorPosition())
	if point then
		StartJourney(point)
	else
		ns.Print("no journey can be planned to that spot.")
	end
	return true
end

local function OnPinClick(map, action, button)
	if
		not ns.db.journey
		or action ~= MapCanvasMixin.MouseAction.Click
		or button ~= "LeftButton"
		or not IsShiftKeyDown()
	then
		return false
	end
	-- MapCanvas calls these handlers before POIButton.OnClick. Canvas click handlers do not run over pins.
	for _, pin in ipairs(GetMouseFoci()) do
		if pin.pinTemplate == "QuestPinTemplate" and pin:GetMap() == map and pin:GetQuestID() then
			PlanQuest(pin:GetQuestID(), map:GetMapID(), pin:GetStyle() == POIButtonUtil.Style.Waypoint)
			return true
		end
	end
	return false
end

local function AddQuestMenuEntry(root, questID)
	if ns.db.journey and questID then
		root:CreateButton("Plan journey", function()
			PlanQuest(questID)
		end)
	end
end

ns.Init(function()
	driver = CreateFrame("Frame", "FerryForeverJourneyDriver", UIParent)
	driver:SetScript("OnUpdate", Update)
	driver:RegisterEvent("QUEST_TURNED_IN")
	driver:RegisterEvent("QUEST_REMOVED")
	driver:SetScript("OnEvent", function(_, event, questID)
		if (event == "QUEST_TURNED_IN" or event == "QUEST_REMOVED") and goal and goal.questID == questID then
			ns.ClearJourney()
		end
	end)
	driver:Hide()
	WorldMapFrame:AddCanvasClickHandler(OnCanvasClick)
	WorldMapFrame:AddGlobalPinMouseActionHandler(OnPinClick)
	Menu.ModifyMenu("MENU_QUEST_OBJECTIVE_TRACKER", function(owner, root)
		-- The native menu owner is the tracker container, with no quest ID/context data.
		-- Resolve the right-clicked HeaderButton's block; never reuse a previous hover's quest.
		for _, header in ipairs(GetMouseFoci()) do
			local block = header:GetParent()
			if
				block
				and block.HeaderButton == header
				and block.parentModule
				and block.parentModule:GetContextMenuParent() == owner
			then
				AddQuestMenuEntry(root, block.id)
				return
			end
		end
	end)
	Menu.ModifyMenu("MENU_QUEST_MAP_LOG_TITLE", function(owner, root)
		-- Waypoint menus share this tag, but have no questID.
		AddQuestMenuEntry(root, owner.questID)
	end)
end)
