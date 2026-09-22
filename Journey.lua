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

local panel, goal, guide
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
	panel.Guide:SetText("Guide")
end

local function OwnsWaypoint()
	if guide.waypoint and not SameWaypoint(C_Map.GetUserWaypoint(), guide.waypoint) then
		-- A manual replacement or removal ends guidance; never reclaim the player's waypoint.
		StopGuide()
		return false
	end
	return true
end

local function GuideTo(node)
	if guide.target == node then
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
	guide.target = node
end

local function UpdateGuide()
	if not guide or not OwnsWaypoint() then
		return
	end
	if Near(goal) then
		panel:Hide()
		return
	end
	local riding, flying = ns.CurrentRide(), UnitOnTaxi("player")
	while guide.index <= #guide.result.legs do
		local leg = guide.result.legs[guide.index]
		local nextLeg = guide.result.legs[guide.index + 1]
		if
			leg.mode == "walk"
			and nextLeg
			and ((nextLeg.route and riding == nextLeg.route) or (nextLeg.mode == "flight" and flying))
		then
			guide.index = guide.index + 1
			leg = nextLeg
		end
		local aboard = leg.aboard or (leg.route and riding == leg.route) or (leg.mode == "flight" and flying)
		if leg.mode ~= "walk" and not guide.departed then
			if aboard or Near(leg.from) then
				guide.departed = true
			else
				GuideTo(leg.from)
				return
			end
		end
		if not Near(leg.to) then
			GuideTo(leg.to)
			return
		end
		guide.index, guide.departed = guide.index + 1, false
	end
	panel:Hide()
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
	panel.Guide:SetEnabled(result ~= nil)
	if guide and OwnsWaypoint() then
		if result then
			if result ~= guide.result then
				guide.result, guide.index, guide.departed = result, 1, false
			end
			UpdateGuide()
		else
			StopGuide()
		end
	end
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
	-- Taxi paths cannot be interrupted; retain their chosen destination until landing.
	if guide and UnitOnTaxi("player") then
		guide.result.now = now
		return guide.result
	end
	local ride, routeID = nil, ns.CurrentRide()
	if routeID then
		local dock, arriveIn = ns.NextStop(routeID)
		if dock then
			ride = { route = routeID, dock = dock, arrive = now + arriveIn }
		end
	end
	local result = ns.Planner.Plan({
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
		StopGuide()
		goal = nil
		ns.SetJourneyRoute(nil)
	end)
	panel:SetScript("OnShow", function(self)
		if not goal then
			self:Hide()
		end
	end)
	panel.Guide = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	panel.Guide:SetSize(100, 22)
	panel.Guide:SetPoint("BOTTOMLEFT", 10, 10)
	panel.Guide:SetText("Guide")
	panel.Guide:SetScript("OnClick", function()
		if guide then
			StopGuide()
		elseif panel.result then
			guide = { result = panel.result, index = 1 }
			panel.Guide:SetText("Stop guiding")
			UpdateGuide()
		end
	end)
	panel.guideElapsed = 0
	panel.elapsed = 0
	panel:SetScript("OnUpdate", function(self, elapsed)
		if not ns.db.journey then
			self:Hide()
			return
		end
		self.elapsed = self.elapsed + elapsed
		self.guideElapsed = self.guideElapsed + elapsed
		if self.guideElapsed < 0.1 then
			return
		end
		self.guideElapsed = 0
		UpdateGuide()
		if not goal then
			return
		end
		local riding, flying = ns.CurrentRide(), UnitOnTaxi("player")
		local changedRide = riding ~= self.riding or flying ~= self.flying
		self.riding, self.flying = riding, flying
		if self.elapsed >= REPLAN_EVERY or changedRide then
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
	if guide then
		StopGuide()
	end
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
