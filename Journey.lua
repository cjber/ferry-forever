local _, ns = ...

-- Shift-click the world map: the fastest way there from here, by foot, flight, boat, zeppelin, tram and portal,
-- with the boats' live waits. Replanned every few seconds from where you stand until closed.
local WIDTH = 320
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

local panel, goal

local function NodeLabel(node)
	if node.kind == "start" then
		return "your position"
	elseif node.kind == "dock" then
		return ns.DockTitle(node.id)
	elseif node.kind == "taxi" then
		return ns.TaxiNodes[node.id].name
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

-- Where to head first: the end of the opening walk, or the start of the first ride when already there.
local function FirstStop(result)
	local leg = result.legs[1]
	local node = leg.mode == "walk" and leg.to or leg.from
	return node.kind == "dock" and ns.DockPoint(node.id) or node
end

local function SetWaypoint(result)
	local location = ns.Locate(FirstStop(result))
	if not (location and C_Map.CanSetUserWaypointOnMap(location.uiMap)) then
		ns.Print("that spot cannot hold a map waypoint.")
		return
	end
	C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(location.uiMap, location.x, location.y))
	C_SuperTrack.SetSuperTrackedUserWaypoint(true)
end

local function Line(index)
	local line = panel.lines[index]
	if not line then
		line = {
			left = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall"),
			right = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall"),
		}
		line.left:SetJustifyH("LEFT")
		line.right:SetJustifyH("RIGHT")
		line.left:SetWidth(WIDTH - 110)
		line.left:SetWordWrap(true)
		panel.lines[index] = line
	end
	return line
end

local function Render(result)
	ns.SetJourneyRoute(goal, result)
	for _, line in ipairs(panel.lines) do
		line.left:Hide()
		line.right:Hide()
	end
	panel.result = result
	panel.Waypoint:SetEnabled(result ~= nil)
	if not result then
		panel.Title:SetText("Journey")
		local line = Line(1)
		line.left:SetText("No way there from here.")
		line.left:SetPoint("TOPLEFT", panel.Title, "BOTTOMLEFT", 0, -10)
		line.left:Show()
		panel:SetHeight(90)
		return
	end
	panel.Title:SetText("Journey · " .. ns.FormatCountdown(result.arrive - result.now))
	local previous, height = panel.Title, 0
	for index, leg in ipairs(result.legs) do
		local line = Line(index)
		local label = string.format("%d. %s %s", index, VERB[leg.mode], NodeLabel(leg.to))
		-- Walks and some flights are always estimates; only an untimed boat is worth calling out.
		local untimed = leg.estimated and SCHEDULED[leg.mode]
		if untimed then
			label = label .. " (no sighting yet)"
		end
		local color = untimed and GRAY_FONT_COLOR or HIGHLIGHT_FONT_COLOR
		line.left:SetText(color:WrapTextInColorCode(label))
		line.right:SetText(color:WrapTextInColorCode(LegTime(leg)))
		line.left:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, index == 1 and -10 or -4)
		line.right:SetPoint("TOPRIGHT", line.left, "TOPLEFT", WIDTH - 24, 0)
		line.left:Show()
		line.right:Show()
		previous = line.left
		height = height + line.left:GetStringHeight() + 4
	end
	panel:SetHeight(height + 80)
end

local function Plan()
	local x, y, _, map = UnitPosition("player")
	if not (x and goal) then
		return nil
	end
	local _, runSpeed = GetUnitSpeed("player")
	local now = ns.NowMs()
	local result = ns.Planner.Plan({
		from = { map = map, x = x, y = y },
		to = goal,
		now = now,
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
	if result then
		result.now = now
	end
	return result
end

local function CreatePanel()
	panel = CreateFrame("Frame", "FerryForeverJourney", WorldMapFrame:GetCanvasContainer(), "TooltipBackdropTemplate")
	panel:SetPoint("TOPLEFT", 12, -12)
	panel:SetWidth(WIDTH)
	panel:SetFrameStrata("HIGH")
	panel:EnableMouse(true)
	panel.lines = {}
	panel.Title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	panel.Title:SetPoint("TOPLEFT", 12, -12)
	local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)
	close:SetScript("OnClick", function()
		panel:Hide()
	end)
	panel:SetScript("OnHide", function()
		goal = nil
		ns.SetJourneyRoute(nil)
	end)
	panel:SetScript("OnShow", function(self)
		if not goal then
			self:Hide()
		end
	end)
	panel.Waypoint = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	panel.Waypoint:SetSize(140, 22)
	panel.Waypoint:SetPoint("BOTTOMLEFT", 10, 10)
	panel.Waypoint:SetText("Waypoint first stop")
	panel.Waypoint:SetScript("OnClick", function()
		if panel.result then
			SetWaypoint(panel.result)
		end
	end)
	panel.elapsed = 0
	panel:SetScript("OnUpdate", function(self, elapsed)
		if not ns.db.journey then
			self:Hide()
			return
		end
		self.elapsed = self.elapsed + elapsed
		if self.elapsed >= REPLAN_EVERY then
			self.elapsed = 0
			Render(Plan())
		end
	end)
end

local function OnCanvasClick(map, button)
	if not ns.db.journey or button ~= "LeftButton" or not IsShiftKeyDown() then
		return false
	end
	local continent, world =
		C_Map.GetWorldPosFromMapPos(map:GetMapID(), CreateVector2D(map:GetNormalizedCursorPosition()))
	if not continent then
		ns.Print("no journey can be planned to that spot.")
		return true
	end
	local x, y = world:GetXY()
	goal = { map = continent, x = x, y = y }
	if not panel then
		CreatePanel()
	end
	panel.elapsed = 0
	panel:Show()
	Render(Plan())
	return true
end

ns.Init(function()
	WorldMapFrame:AddCanvasClickHandler(OnCanvasClick)
end)
