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
local PATH_REUSE = 3
local pathJobs, walkCache, pathVersion = {}, {}, 0

local function CancelPaths()
	pathVersion = pathVersion + 1
	for job in pairs(pathJobs) do
		ns.Path.Cancel(job)
	end
	pathJobs = {}
end

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
	if a == b then
		return true
	end
	if not (a and b and a.uiMapID == b.uiMapID) then
		return false
	end
	-- C_Map.GetUserWaypoint's position is a plain { x, y } table, not a Vector2D (WaypointLocationDataProvider.lua:183).
	return math.abs(a.position.x - b.position.x) < 0.000001 and math.abs(a.position.y - b.position.y) < 0.000001
end

local function RememberTracking(state)
	state.expectedQuest = C_SuperTrack.GetSuperTrackedQuestID()
	state.expectedTrackedWaypoint = C_SuperTrack.IsSuperTrackingUserWaypoint()
	state.expectedTrackingType = C_SuperTrack.GetHighestPrioritySuperTrackingType()
end

local function SameTracking(state)
	return state.expectedQuest == C_SuperTrack.GetSuperTrackedQuestID()
		and state.expectedTrackedWaypoint == C_SuperTrack.IsSuperTrackingUserWaypoint()
		and state.expectedTrackingType == C_SuperTrack.GetHighestPrioritySuperTrackingType()
end

local function StopGuide()
	local previous = guide
	guide = nil
	ns.PointGuideArrow(nil)
	if
		not previous
		or not previous.hasDriven
		or not SameWaypoint(C_Map.GetUserWaypoint(), previous.expectedWaypoint)
	then
		return
	end
	local ownsTracking = not previous.yielded and SameTracking(previous)
	if previous.previousWaypoint then
		C_Map.SetUserWaypoint(previous.previousWaypoint)
	elseif previous.waypoint then
		C_Map.ClearUserWaypoint()
	end
	if ownsTracking then
		C_SuperTrack.SetSuperTrackedUserWaypoint(previous.previousTrackedWaypoint)
		if not previous.previousTrackedWaypoint then
			C_SuperTrack.SetSuperTrackedQuestID(previous.previousQuest or 0)
		end
	end
end

local function OwnsWaypoint()
	if not SameWaypoint(C_Map.GetUserWaypoint(), guide.expectedWaypoint) then
		-- A manual replacement or removal ends guidance; never reclaim the player's waypoint.
		StopGuide()
		return false
	end
	return true
end

local function GuideWaypoint(point)
	if not guide or not OwnsWaypoint() then
		return false
	end
	if not SameTracking(guide) then
		guide.yielded = true
	end
	if guide.yielded then
		return false
	end
	local uiMap = C_Map.GetBestMapForUnit("player")
	local bend = guide.bend
	if not bend or point.map ~= bend.map or point.x ~= bend.x or point.y ~= bend.y or uiMap ~= guide.uiMap then
		guide.bend, guide.uiMap = { map = point.map, x = point.x, y = point.y }, uiMap
		local waypoint
		if uiMap and C_Map.CanSetUserWaypointOnMap(uiMap) then
			local projectedMap, position =
				C_Map.GetMapPosFromWorldPos(point.map, CreateVector2D(point.x, point.y), uiMap)
			if projectedMap == uiMap and position then
				local x, y = position:GetXY()
				if x >= 0 and x <= 1 and y >= 0 and y <= 1 then
					waypoint = UiMapPoint.CreateFromVector2D(uiMap, position)
				end
			end
		end
		-- These APIs may dispatch events synchronously. Only our own writes bypass ownership checks.
		guide.writing = true
		-- The native map pin marks the next bend; Ferry's destination diamond still marks the final goal.
		if waypoint and C_Map.SetUserWaypoint(waypoint) then
			guide.waypoint = C_Map.GetUserWaypoint()
			guide.expectedWaypoint = guide.waypoint
			guide.hasDriven = true
			C_SuperTrack.SetSuperTrackedUserWaypoint(true)
		elseif guide.waypoint then
			-- Never leave a stale native marker pointing at the preceding bend when projection fails.
			C_Map.ClearUserWaypoint()
			C_SuperTrack.SetSuperTrackedUserWaypoint(false)
			guide.waypoint, guide.expectedWaypoint = nil, nil
		end
		-- Deferred events from our own writes must also agree with the expected tracking state.
		RememberTracking(guide)
		guide.writing = nil
	end
	return guide.waypoint ~= nil and C_SuperTrack.IsSuperTrackingUserWaypoint()
end

local function GuideTo(node, points)
	if not guide or (guide.target == node and guide.points == points) then
		return
	end
	guide.points = points
	guide.target = node
	local point = node.kind == "dock" and ns.DockPoint(node.id) or node
	ns.PointGuideArrow(points or { point }, GuideWaypoint)
end

function ns.ClearJourney()
	CancelPaths()
	walkCache = {}
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

local function StartGuide()
	local previous = C_Map.HasUserWaypoint() and C_Map.GetUserWaypoint()
	local saved = previous
		and UiMapPoint.CreateFromCoordinates(previous.uiMapID, previous.position.x, previous.position.y, previous.z)
	guide = {
		previousQuest = C_SuperTrack.GetSuperTrackedQuestID(),
		previousWaypoint = saved,
		expectedWaypoint = previous or nil,
		previousTrackedWaypoint = saved ~= nil and C_SuperTrack.IsSuperTrackingUserWaypoint(),
	}
	RememberTracking(guide)
	UpdateProgress()
end

function ns.ToggleJourneyGuide()
	if guide then
		StopGuide()
	elseif result then
		StartGuide()
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

local function NearPathEndpoint(a, b)
	return a.map == b.map and (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 <= PATH_REUSE ^ 2
end

local function PrepareWalks(planned)
	local cache, searches = {}, {}
	for _, leg in ipairs(planned and planned.legs or {}) do
		if leg.mode == "walk" then
			leg.walkPoints = ns.Planner.WalkPoints(leg.from, leg.to)
			if ns.Path and leg.from.map == leg.to.map and ns.Path.HasData(leg.from.map) then
				local found
				for _, entry in ipairs(walkCache) do
					if entry.done and NearPathEndpoint(entry.from, leg.from) and NearPathEndpoint(entry.to, leg.to) then
						found = entry
						break
					end
				end
				-- Compare with the original search endpoints, so small moves cannot drift the cache indefinitely.
				local entry = found or { from = leg.from, to = leg.to }
				cache[#cache + 1] = entry
				if found then
					leg.walkPoints = entry.points or leg.walkPoints
				else
					searches[#searches + 1] = { leg = leg, entry = entry }
				end
			end
		end
	end
	walkCache = cache
	return searches
end

local function FindWalks(planned, searches)
	local version = pathVersion
	for _, search in ipairs(searches) do
		local leg, entry = search.leg, search.entry
		local from, to = leg.from, leg.to
		local job = ns.Path.Find(from.map, from.x, from.y, to.x, to.y, function(points, _, finished)
			pathJobs[finished] = nil
			if result ~= planned or version ~= pathVersion then
				return
			end
			entry.done, entry.points = true, points
			if points then
				-- Geometry improves asynchronously; arrival times still use the planner's straight-line estimate.
				leg.walkPoints = points
				if guide and result.legs[progress.index] == leg then
					guide.target = nil
					UpdateProgress()
				end
				Refresh()
			end
		end)
		pathJobs[job] = true
	end
end

local function Render(planned)
	local searches
	if planned ~= result then
		CancelPaths()
		progress.index, progress.departed = 1, false
		searches = PrepareWalks(planned)
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
	if result == planned and planned and searches then
		FindWalks(planned, searches)
	end
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
	CancelPaths()
	walkCache = {}
	if guide then
		StopGuide()
	end
	goal = point
	result = nil
	progress.index, progress.departed = 1, false
	driver.elapsed, driver.progressElapsed = 0, 0
	driver:Show()
	Render(Plan())
	-- Every journey starts guided; the tracker header turns it off.
	if result then
		StartGuide()
		ns.RefreshTracker()
	end
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
	driver:RegisterEvent("SUPER_TRACKING_CHANGED")
	driver:RegisterEvent("USER_WAYPOINT_UPDATED")
	driver:SetScript("OnEvent", function(_, event, questID)
		if (event == "QUEST_TURNED_IN" or event == "QUEST_REMOVED") and guide and guide.previousQuest == questID then
			guide.previousQuest = nil
		end
		if (event == "QUEST_TURNED_IN" or event == "QUEST_REMOVED") and goal and goal.questID == questID then
			ns.ClearJourney()
		elseif
			guide
			and not guide.writing
			and (event == "SUPER_TRACKING_CHANGED" or event == "USER_WAYPOINT_UPDATED")
		then
			if not OwnsWaypoint() then
				ns.RefreshTracker()
			elseif event == "SUPER_TRACKING_CHANGED" and not SameTracking(guide) then
				-- A quest/map-pin click belongs to the player. Keep the route arrow, but never retake tracking.
				guide.yielded = true
			end
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
