---@class SPFNamespace
local ns = select(2, ...)
local L = ns.L

---@param uiMapID integer
---@param x number
---@param y number
---@return SPFPoint?
function ns.WorldPoint(uiMapID, x, y)
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
	-- Forever takes questID and ignoreWaypoint; Ketho's Wiki stub incorrectly has zero parameters.
	---@diagnostic disable-next-line: redundant-parameter
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
	local point = location and ns.WorldPoint(location.uiMapID, location.x, location.y)
	if not point then
		-- Questie.API exposes icons and update notifications, but no public coordinate lookup.
		ns.Print(L["No location for that quest yet."])
		return
	end
	point.label, point.questID = location.label, questID
	ns.StartJourney(point)
end

local function OnCanvasClick(map, button)
	if not ns.db.journey or button ~= "LeftButton" or not IsShiftKeyDown() then
		return false
	end
	local point = ns.WorldPoint(map:GetMapID(), map:GetNormalizedCursorPosition())
	if point then
		ns.StartJourney(point)
	else
		ns.Print(L["no journey can be planned to that spot."])
	end
	return true
end

local function OnMinimapClick(_, button)
	if not ns.db.journey or button ~= "LeftButton" or not IsShiftKeyDown() then
		return
	end
	local point = ns.MinimapPoint()
	if point then
		ns.StartJourney(point)
	end
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
	for _, focus in ipairs(GetMouseFoci()) do
		local pin = focus
		---@cast pin SPFQuestPin
		if pin.pinTemplate == "QuestPinTemplate" and pin:GetMap() == map and pin:GetQuestID() then
			PlanQuest(pin:GetQuestID(), map:GetMapID(), pin:GetStyle() == POIButtonUtil.Style.Waypoint)
			return true
		end
	end
	return false
end

local function AddQuestMenuEntry(root, questID)
	if ns.db.journey and questID then
		root:CreateButton(L["Plan journey"], function()
			PlanQuest(questID)
		end)
	end
end

ns.Init(function()
	WorldMapFrame:AddCanvasClickHandler(OnCanvasClick)
	WorldMapFrame:AddGlobalPinMouseActionHandler(OnPinClick)
	-- The stock handler still pings the spot, which marks where the journey goes for your group too.
	Minimap:HookScript("OnMouseUp", OnMinimapClick)
	Menu.ModifyMenu("MENU_QUEST_OBJECTIVE_TRACKER", function(owner, root)
		-- The native menu owner is the tracker container, with no quest ID/context data.
		-- Resolve the right-clicked HeaderButton's block; never reuse a previous hover's quest.
		for _, header in ipairs(GetMouseFoci()) do
			local block = header:GetParent()
			---@cast block SPFTrackerBlock
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
		---@cast owner SPFQuestMenuOwner
		-- Waypoint menus share this tag, but have no questID.
		AddQuestMenuEntry(root, owner.questID)
	end)
end)
