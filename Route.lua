local _, ns = ...

local LINE_TEMPLATE = "FerryForeverRoutePinTemplate"
local GOAL_TEMPLATE = "FerryForeverGoalPinTemplate"
-- Blizzard_FlightMap/FM_FlightPathDataProvider.xml:48, the native background flight line.
local LINE_ATLAS = "_UI-Taxi-Line-horizontal"
local THICKNESS, DASH, GAP = 6, 7, 7
local COLORS = {
	walk = HIGHLIGHT_FONT_COLOR,
	flight = NORMAL_FONT_COLOR,
	boat = LIGHTBLUE_FONT_COLOR,
	zeppelin = LIGHTBLUE_FONT_COLOR,
	tram = ORANGE_FONT_COLOR,
	portal = EPIC_PURPLE_COLOR,
	passage = EPIC_PURPLE_COLOR,
}
local provider, goal, result, paths, minimap

local function MapPosition(point, mapID)
	local uiMap, position = C_Map.GetMapPosFromWorldPos(point.map, CreateVector2D(point.x, point.y), mapID)
	if uiMap == mapID and position then
		return position:GetXY()
	end
end

-- Clip segments, not vertices: a line can cross a zone with both endpoints outside it.
local function ClipAxis(start, delta, low, high, minimum, maximum)
	if delta == 0 then
		if start < minimum or start > maximum then
			return nil
		end
	else
		local a, b = (minimum - start) / delta, (maximum - start) / delta
		low, high = math.max(low, math.min(a, b)), math.min(high, math.max(a, b))
	end
	if low < high then
		return low, high
	end
end

local function Stroke(owner, x1, y1, x2, y2, color, scale)
	owner.used = owner.used + 1
	local line = owner.lines[owner.used]
	if not line then
		line = owner:CreateLine(nil, "ARTWORK")
		line:SetAtlas(LINE_ATLAS)
		owner.lines[owner.used] = line
	end
	line:SetVertexColor(color:GetRGBA())
	line:SetThickness(THICKNESS / scale)
	line:SetStartPoint("TOPLEFT", owner, x1, y1)
	line:SetEndPoint("TOPLEFT", owner, x2, y2)
	line:Show()
end

-- Clip before subdividing: even continent-sized walks need only the visible breadcrumbs.
local function Segment(owner, x1, y1, x2, y2, low, high, color, dashed, scale)
	local dx, dy = x2 - x1, y2 - y1
	local length = math.sqrt(dx * dx + dy * dy) * scale
	if not low or length == 0 then
		return
	end
	if not dashed then
		Stroke(owner, x1 + low * dx, y1 + low * dy, x1 + high * dx, y1 + high * dy, color, scale)
		return
	end
	local first, last = low * length, high * length
	for distance = math.floor(first / (DASH + GAP)) * (DASH + GAP), last, DASH + GAP do
		local a, b = math.max(first, distance) / length, math.min(last, distance + DASH) / length
		if a < b then
			Stroke(owner, x1 + a * dx, y1 + a * dy, x1 + b * dx, y1 + b * dy, color, scale)
		end
	end
end

local function HideUnused(owner)
	for index = owner.used + 1, #owner.lines do
		owner.lines[index]:Hide()
	end
end

FerryForeverRoutePinMixin = CreateFromMixins(MapCanvasPinMixin)

function FerryForeverRoutePinMixin:OnLoad()
	self:UseFrameLevelType("PIN_FRAME_LEVEL_QUEST_BLOB")
	self:SetIgnoreGlobalPinScale(true)
	self:SetScaleStyle(AM_PIN_SCALE_STYLE_WITH_TERRAIN)
	self.lines = {}
end

function FerryForeverRoutePinMixin:Line(x1, y1, x2, y2, color, dashed)
	local low, high = ClipAxis(x1, x2 - x1, 0, 1, 0, 1)
	if low then
		low, high = ClipAxis(y1, y2 - y1, low, high, 0, 1)
	end
	Segment(
		self,
		x1 * self:GetWidth(),
		-y1 * self:GetHeight(),
		x2 * self:GetWidth(),
		-y2 * self:GetHeight(),
		low,
		high,
		color,
		dashed,
		self:GetMap():GetCanvasScale()
	)
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
	for _, path in ipairs(self.paths) do
		local color = COLORS[path.mode]
		local previous, px, py
		for _, point in ipairs(path.points) do
			local x, y = MapPosition(point, map:GetMapID())
			if path.mode == "portal" or path.mode == "passage" then
				self:Mark(x, y, color)
			elseif previous then
				if previous.jump or previous.map ~= point.map then
					self:Mark(px, py, color)
					self:Mark(x, y, color)
				elseif px and x then
					self:Line(px, py, x, y, color, path.mode == "walk")
				end
			end
			previous, px, py = point, x, y
		end
	end
	HideUnused(self)
end

function FerryForeverRoutePinMixin:OnAcquired(route, geometry)
	self.result, self.paths = route, geometry
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
	self:SetIgnoreGlobalPinScale(true)
	self:SetScalingLimits(1, 1, 1)
	self:SetSize(32, 32)
	-- Blizzard_POIButton/POIButton.lua:79. The quest ring, distinct from the user-waypoint diamond.
	self.Texture:SetAtlas("UI-QuestPoi-QuestNumber")
	self.Label:SetText("X")
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
	if not (mapID and map:IsVisible() and ns.db.journey and goal) then
		return
	end
	if result then
		map:AcquirePin(LINE_TEMPLATE, result, paths)
	end
	local x, y = MapPosition(goal, mapID)
	if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
		map:AcquirePin(GOAL_TEMPLATE, x, y)
	end
end

-- Diameters in yards, zoom 0..5; divide by two for radius. Preserve the upstream values.
-- https://github.com/Nevcairiel/HereBeDragons/blob/master/HereBeDragons-Pins-2.0.lua#L60-L77
local DIAMETERS = {
	indoor = { [0] = 300, 240, 180, 120, 80, 50 },
	outdoor = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 6, 200, 133 + 1 / 3 },
}
local indoors, probingZoom

local function UpdateMinimapZoom()
	if probingZoom or not result then
		return
	end
	-- The client reports the exact radius; the table is for clients without that API.
	if C_Minimap and C_Minimap.GetViewRadius then
		return
	end
	local zoom = Minimap:GetZoom()
	probingZoom = true
	-- HBD-Pins:309-317: disambiguate identical indoor/outdoor settings, then restore the zoom.
	if GetCVar("minimapZoom") == GetCVar("minimapInsideZoom") then
		Minimap:SetZoom(zoom < 2 and zoom + 1 or zoom - 1)
	end
	indoors = tonumber(GetCVar("minimapZoom")) == Minimap:GetZoom() and "outdoor" or "indoor"
	Minimap:SetZoom(zoom)
	probingZoom = false
end

local function ClipMinimap(x, y, dx, dy, inset, square)
	if square then
		local low, high = ClipAxis(x, dx, 0, 1, -inset, inset)
		if low then
			return ClipAxis(y, dy, low, high, -inset, inset)
		end
		return nil
	end
	local a, b, c = dx * dx + dy * dy, x * dx + y * dy, x * x + y * y - inset * inset
	local discriminant = b * b - a * c
	if a == 0 or discriminant <= 0 then
		return nil
	end
	local root = math.sqrt(discriminant)
	local low, high = math.max(0, (-b - root) / a), math.min(1, (-b + root) / a)
	if low < high then
		return low, high
	end
end

local function Project(point, x, y, radius, cosine, sine)
	-- UnitPosition's X is north, Y is west; minimap X is right, Y is up.
	local east, north = y - point.y, point.x - x
	return (east * cosine + north * sine) / radius, (north * cosine - east * sine) / radius
end

local function DrawMinimap(self)
	self.used = 0
	local x, y, _, map = UnitPosition("player")
	local facing = 0
	if GetCVar("rotateMinimap") == "1" then
		facing = GetPlayerFacing()
	end
	local diameter = DIAMETERS[indoors or "outdoor"][Minimap:GetZoom()]
	-- Blizzard_APIDocumentationGenerated/MinimapDocumentation.lua:127 (yards).
	local radius = C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius() or diameter and diameter / 2
	local width, height = self:GetWidth(), self:GetHeight()
	if x and facing and radius and radius > 0 and width > THICKNESS and height > THICKNESS then
		local cosine, sine = math.cos(facing), math.sin(facing)
		-- GetMinimapShape is an optional addon convention (HBD-Pins:215), not a Blizzard global.
		local square = GetMinimapShape and GetMinimapShape() == "SQUARE"
		local inset = 1 - THICKNESS / math.min(width, height)
		for _, path in ipairs(paths) do
			if path.mode ~= "portal" and path.mode ~= "passage" then
				for index = 2, #path.points do
					local a, b = path.points[index - 1], path.points[index]
					if a.map == map and b.map == map and not a.jump then
						local ax, ay = Project(a, x, y, radius, cosine, sine)
						local bx, by = Project(b, x, y, radius, cosine, sine)
						local low, high = ClipMinimap(ax, ay, bx - ax, by - ay, inset, square)
						Segment(
							self,
							(ax + 1) * width / 2,
							(ay - 1) * height / 2,
							(bx + 1) * width / 2,
							(by - 1) * height / 2,
							low,
							high,
							COLORS[path.mode],
							path.mode == "walk",
							1
						)
					end
				end
			end
		end
	end
	HideUnused(self)
end

local function UpdateMinimap(self, elapsed)
	if not (result and ns.db.journey) then
		self:Hide()
		return
	end
	self.elapsed = self.elapsed + elapsed
	if self.elapsed >= 0.1 then
		self.elapsed = 0
		DrawMinimap(self)
	end
end

function ns.SetJourneyRoute(destination, route)
	goal, result = destination, route
	paths = {}
	for _, leg in ipairs(route and route.legs or {}) do
		paths[#paths + 1] = { mode = leg.mode, points = ns.Planner.LegPoints(leg, ns.Routes) }
	end
	if provider then
		provider:RefreshAllData()
	end
	if minimap then
		if route then
			UpdateMinimapZoom()
			minimap.elapsed = 0
			minimap:SetScript("OnUpdate", UpdateMinimap)
			minimap:Show()
			DrawMinimap(minimap)
		else
			minimap:SetScript("OnUpdate", nil)
			minimap:Hide()
		end
	end
end

ns.Init(function()
	provider = CreateFromMixins(ProviderMixin)
	WorldMapFrame:AddDataProvider(provider)
	minimap = CreateFrame("Frame", "FerryForeverMinimapRoute", Minimap)
	minimap:SetAllPoints(Minimap)
	minimap:EnableMouse(false)
	minimap.lines, minimap.used = {}, 0
	minimap:RegisterEvent("MINIMAP_UPDATE_ZOOM")
	minimap:SetScript("OnEvent", UpdateMinimapZoom)
	minimap:Hide()
end)
