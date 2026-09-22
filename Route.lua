local _, ns = ...

local LINE_TEMPLATE = "FerryForeverRoutePinTemplate"
local GOAL_TEMPLATE = "FerryForeverGoalPinTemplate"
local COLORS = {
	walk = HIGHLIGHT_FONT_COLOR,
	flight = NORMAL_FONT_COLOR,
	boat = LIGHTBLUE_FONT_COLOR,
	zeppelin = LIGHTBLUE_FONT_COLOR,
	tram = ORANGE_FONT_COLOR,
	portal = EPIC_PURPLE_COLOR,
	passage = EPIC_PURPLE_COLOR,
}
local provider, goal, result

local function MapPosition(point, mapID)
	local uiMap, position = C_Map.GetMapPosFromWorldPos(point.map, CreateVector2D(point.x, point.y), mapID)
	if uiMap == mapID and position then
		return position:GetXY()
	end
end

-- Clip segments, not vertices: a line can cross a zone with both endpoints outside it.
local function ClipAxis(start, delta, low, high)
	if delta == 0 then
		if start < 0 or start > 1 then
			return nil
		end
	else
		local a, b = -start / delta, (1 - start) / delta
		low, high = math.max(low, math.min(a, b)), math.min(high, math.max(a, b))
	end
	if low <= high then
		return low, high
	end
end

FerryForeverRoutePinMixin = CreateFromMixins(MapCanvasPinMixin)

function FerryForeverRoutePinMixin:OnLoad()
	self:UseFrameLevelType("PIN_FRAME_LEVEL_QUEST_BLOB")
	-- Icon scaling cancels canvas zoom; geometry must stay in the terrain's coordinate space.
	self:SetIgnoreGlobalPinScale(true)
	self:SetScaleStyle(AM_PIN_SCALE_STYLE_WITH_TERRAIN)
	self.lines = {}
end

function FerryForeverRoutePinMixin:Line(x1, y1, x2, y2, color)
	local dx, dy = x2 - x1, y2 - y1
	local low, high = ClipAxis(x1, dx, 0, 1)
	if low then
		low, high = ClipAxis(y1, dy, low, high)
	end
	if not low or low == high or (dx == 0 and dy == 0) then
		return
	end
	self.used = self.used + 1
	local line = self.lines[self.used]
	if not line then
		line = self:CreateLine(nil, "ARTWORK")
		self.lines[self.used] = line
	end
	line:SetColorTexture(color:GetRGBA())
	line:SetThickness(2 / self:GetMap():GetCanvasScale())
	line:SetStartPoint("TOPLEFT", self, (x1 + low * dx) * self:GetWidth(), -(y1 + low * dy) * self:GetHeight())
	line:SetEndPoint("TOPLEFT", self, (x1 + high * dx) * self:GetWidth(), -(y1 + high * dy) * self:GetHeight())
	line:Show()
end

function FerryForeverRoutePinMixin:Mark(x, y, color)
	if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
		local size = 4 / self:GetMap():GetCanvasScale()
		local dx, dy = size / self:GetWidth(), size / self:GetHeight()
		self:Line(x - dx, y, x + dx, y, color)
		self:Line(x, y - dy, x, y + dy, color)
	end
end

function FerryForeverRoutePinMixin:Draw()
	local map = self:GetMap()
	local canvas = map:GetCanvas()
	self:SetSize(canvas:GetWidth(), canvas:GetHeight())
	self:SetPosition(0.5, 0.5)
	self.used = 0
	for _, leg in ipairs(self.result.legs) do
		local color = COLORS[leg.mode]
		local previous, px, py
		for _, point in ipairs(ns.Planner.LegPoints(leg, ns.Routes)) do
			local x, y = MapPosition(point, map:GetMapID())
			if leg.mode == "portal" or leg.mode == "passage" then
				self:Mark(x, y, color)
			elseif previous then
				if previous.jump or previous.map ~= point.map then
					self:Mark(px, py, color)
					self:Mark(x, y, color)
				elseif px and x then
					self:Line(px, py, x, y, color)
				end
			end
			previous, px, py = point, x, y
		end
	end
	for index = self.used + 1, #self.lines do
		self.lines[index]:Hide()
	end
end

function FerryForeverRoutePinMixin:OnAcquired(route)
	self.result = route
	self:Draw()
end

function FerryForeverRoutePinMixin:OnCanvasScaleChanged()
	self:Draw()
end

function FerryForeverRoutePinMixin:OnCanvasSizeChanged()
	self:Draw()
end

FerryForeverGoalPinMixin = CreateFromMixins(MapCanvasPinMixin)

function FerryForeverGoalPinMixin:OnLoad()
	self:UseFrameLevelType("PIN_FRAME_LEVEL_SUPER_TRACKED_CONTENT")
	self:SetScalingLimits(1, 1, 1.2)
	self:SetSize(24, 24)
	-- Flag-1: Blizzard_Commentator/Mainline/Blizzard_CommentatorUnitFrame.xml; distinct from user waypoints.
	self.Texture:SetAtlas("Flag-1")
end

function FerryForeverGoalPinMixin:OnAcquired(x, y)
	self:SetPosition(x, y)
end

local ProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function ProviderMixin:RemoveAllData()
	self:GetMap():RemoveAllPinsByTemplate(LINE_TEMPLATE)
	self:GetMap():RemoveAllPinsByTemplate(GOAL_TEMPLATE)
end

function ProviderMixin:RefreshAllData()
	self:RemoveAllData()
	local map = self:GetMap()
	local mapID = map:GetMapID()
	-- Before the map's first show its zoom levels are unset.
	if not (mapID and map:IsVisible()) then
		return
	end
	if not (ns.db.journey and goal) then
		return
	end
	if result then
		map:AcquirePin(LINE_TEMPLATE, result)
	end
	local x, y = MapPosition(goal, mapID)
	if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
		map:AcquirePin(GOAL_TEMPLATE, x, y)
	end
end

function ns.SetJourneyRoute(destination, route)
	goal, result = destination, route
	if provider then
		provider:RefreshAllData()
	end
end

ns.Init(function()
	provider = CreateFromMixins(ProviderMixin)
	WorldMapFrame:AddDataProvider(provider)
end)
