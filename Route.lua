local _, ns = ...

local LINE_TEMPLATE = "FerryForeverRoutePinTemplate"
local TRANSPORT_TEMPLATE = "FerryForeverTransportPinTemplate"
local GOAL_TEMPLATE = "FerryForeverGoalPinTemplate"
-- A solid colour line with a slim dark border, so it reads on parchment and minimap alike; the taxi line
-- atlas is mostly transparent and turned into a thin core inside a heavy border. Walks are short breadcrumbs.
local THICKNESS, DASH, GAP = 3, 8, 6
local UNDER_THICKNESS, UNDER_ALPHA = THICKNESS + 2, 0.5
local COLORS = {
	walk = NORMAL_FONT_COLOR,
	flight = CreateColor(0.2, 1, 0.35),
	boat = CreateColor(0, 0.75, 1),
	zeppelin = CreateColor(1, 0.35, 0.1),
	tram = ORANGE_FONT_COLOR,
	portal = CreateColor(0.85, 0.35, 1),
	passage = CreateColor(0.85, 0.35, 1),
}
local provider, goal, result, paths, minimap
local transportProvider, transportPin, dockHover, highlightedRoutes

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
	local underline = owner.underlines[owner.used]
	if not line then
		underline = owner:CreateLine(nil, "ARTWORK", nil, -1)
		underline:SetColorTexture(0.04, 0.04, 0.04, 1)
		line = owner:CreateLine(nil, "ARTWORK")
		line:SetColorTexture(1, 1, 1, 1)
		owner.lines[owner.used] = line
		owner.underlines[owner.used] = underline
	end
	underline:SetAlpha((owner.strokeAlpha or 1) * UNDER_ALPHA)
	underline:SetThickness(UNDER_THICKNESS / scale)
	underline:SetStartPoint("TOPLEFT", owner, x1, y1)
	underline:SetEndPoint("TOPLEFT", owner, x2, y2)
	underline:Show()
	line:SetVertexColor(color:GetRGBA())
	line:SetAlpha(owner.strokeAlpha or 1)
	line:SetThickness(THICKNESS / scale)
	line:SetStartPoint("TOPLEFT", owner, x1, y1)
	line:SetEndPoint("TOPLEFT", owner, x2, y2)
	line:Show()
	if owner.hits then
		owner.hits[owner.used] = { route = owner.drawingRoute, fade = owner.strokeAlpha or 1 }
	end
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
		owner.underlines[index]:Hide()
	end
end

FerryForeverRoutePinMixin = CreateFromMixins(MapCanvasPinMixin)

function FerryForeverRoutePinMixin:OnLoad()
	self:UseFrameLevelType("PIN_FRAME_LEVEL_QUEST_BLOB")
	self:SetIgnoreGlobalPinScale(true)
	self:SetScaleStyle(AM_PIN_SCALE_STYLE_WITH_TERRAIN)
	self.lines, self.underlines = {}, {}
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
		self:GetEffectiveScale()
	)
end

function FerryForeverRoutePinMixin:Mark(x, y, color)
	if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
		local size = 4 / self:GetEffectiveScale()
		local dx, dy = size / self:GetWidth(), size / self:GetHeight()
		self:Line(x - dx, y, x + dx, y, color)
		self:Line(x, y - dy, x, y + dy, color)
	end
end

-- Smooth loading-screen bridges. The control follows the last sampled direction of travel.
local function Curve(pin, ax, ay, bx, by, cx, cy, color, fade)
	local px, py = ax, ay
	for step = 1, 12 do
		local t = step / 12
		local x = (1 - t) ^ 2 * ax + 2 * (1 - t) * t * cx + t ^ 2 * bx
		local y = (1 - t) ^ 2 * ay + 2 * (1 - t) * t * cy + t ^ 2 * by
		pin.strokeAlpha = fade and (1 - (step - 0.5) / 12) or 1
		pin:Line(px, py, x, y, color)
		px, py = x, y
	end
	pin.strokeAlpha = nil
end

local function EdgeCurve(pin, x, y, nx, ny, color)
	if not nx then
		return
	end
	local dx, dy = x - nx, y - ny
	local length = math.sqrt(dx * dx + dy * dy)
	if length < 0.000001 then
		return
	end
	dx, dy = dx / length, dy / length
	-- Bend gently out to sea while retaining the sampled tangent at the loading point.
	local ex, ey = dx - dy * 0.3, dy + dx * 0.3
	local distance = math.huge
	if ex ~= 0 then
		distance = math.min(distance, ((ex > 0 and 1 or 0) - x) / ex)
	end
	if ey ~= 0 then
		distance = math.min(distance, ((ey > 0 and 1 or 0) - y) / ey)
	end
	if distance > 0 and distance < math.huge then
		Curve(
			pin,
			x,
			y,
			x + ex * distance,
			y + ey * distance,
			x + dx * distance * 0.55,
			y + dy * distance * 0.55,
			color,
			true
		)
	end
end

local function Bridge(pin, points, index, ax, ay, bx, by, color)
	local mapID = pin:GetMap():GetMapID()
	local before, after = points[index - 2] or points[#points - 1], points[index + 1] or points[2]
	local px, py, nx, ny
	if before and before.map == points[index - 1].map then
		px, py = MapPosition(before, mapID)
	end
	if after and after.map == points[index].map then
		nx, ny = MapPosition(after, mapID)
	end
	if ax and bx then
		local dx, dy = bx - ax, by - ay
		local cx, cy = (ax + bx) / 2 - dy * 0.25, (ay + by) / 2 + dx * 0.25
		if px then
			local tx, ty = ax - px, ay - py
			local length = math.sqrt(tx * tx + ty * ty)
			if length > 0 then
				local reach = math.sqrt(dx * dx + dy * dy) * 0.6 / length
				cx, cy = ax + tx * reach, ay + ty * reach
			end
		end
		-- A tangent parallel to the chord would flatten the loading arc into a straight line.
		if math.abs((cx - ax) * dy - (cy - ay) * dx) < (dx * dx + dy * dy) * 0.1 then
			cx, cy = (ax + bx) / 2 - dy * 0.25, (ay + by) / 2 + dx * 0.25
		end
		Curve(pin, ax, ay, bx, by, cx, cy, color)
	elseif ax then
		EdgeCurve(pin, ax, ay, px, py, color)
	elseif bx then
		EdgeCurve(pin, bx, by, nx, ny, color)
	end
end

function FerryForeverRoutePinMixin:Draw()
	local map = self:GetMap()
	local canvas = map:GetCanvas()
	self:SetSize(canvas:GetWidth(), canvas:GetHeight())
	self:SetPosition(0.5, 0.5)
	self.used = 0
	if self.hits then
		self.hits = {}
	end
	for _, path in ipairs(self.paths) do
		local color = COLORS[path.mode]
		self.drawingRoute = path.route
		local previous, px, py
		for index, point in ipairs(path.points) do
			local x, y = MapPosition(point, map:GetMapID())
			if path.mode == "portal" or path.mode == "passage" then
				self:Mark(x, y, color)
			elseif previous then
				if previous.jump or previous.map ~= point.map then
					if path.mode == "boat" or path.mode == "zeppelin" then
						Bridge(self, path.points, index, px, py, x, y, color)
					else
						self:Mark(px, py, color)
						self:Mark(x, y, color)
					end
				elseif px and x then
					self:Line(px, py, x, y, color, path.mode == "walk")
				end
			end
			previous, px, py = point, x, y
		end
	end
	HideUnused(self)
	if self.hits then
		self:UpdateAlpha()
	end
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
	self:SetSize(28, 28)
	-- The Guide arrow's diamond (Blizzard_QuestNavigation/SuperTrackedFrame.xml), so map and arrow agree.
	self.Texture:SetAtlas("Navigation-Tracked-Icon")
	self:SetScript("OnHide", self.OnMouseLeave)
end

function FerryForeverGoalPinMixin:OnAcquired(x, y)
	self:SetPosition(x, y)
end

function FerryForeverGoalPinMixin:OnMouseEnter()
	local title, rows = ns.JourneyInfo()
	if not title then
		return
	end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip_SetTitle(GameTooltip, title)
	for _, row in ipairs(rows) do
		GameTooltip_AddColoredLine(GameTooltip, row.text, row.current and HIGHLIGHT_FONT_COLOR or NORMAL_FONT_COLOR)
	end
	GameTooltip_AddNormalLine(GameTooltip, "Right-click to clear")
	GameTooltip:Show()
end

function FerryForeverGoalPinMixin:OnMouseLeave()
	if GameTooltip:IsOwned(self) then
		GameTooltip:Hide()
	end
end

function FerryForeverGoalPinMixin.OnClick(_self, button)
	if button == "RightButton" then
		ns.ClearJourney()
	end
end

function FerryForeverGoalPinMixin:OnReleased()
	self:OnMouseLeave()
	MapCanvasPinMixin.OnReleased(self)
end

-- One mouse-transparent canvas pin holds every boat and zeppelin route, each hidden until its dock is hovered.
FerryForeverTransportPinMixin = CreateFromMixins(FerryForeverRoutePinMixin)

function FerryForeverTransportPinMixin:OnLoad()
	FerryForeverRoutePinMixin.OnLoad(self)
	self:UseFrameLevelType("PIN_FRAME_LEVEL_FOG_OF_WAR")
	self:EnableMouse(false)
	self.hits = {}
	self:SetScript("OnHide", self.OnReleased)
end

function FerryForeverTransportPinMixin:UpdateAlpha()
	for index, hit in ipairs(self.hits) do
		local alpha = highlightedRoutes and highlightedRoutes[hit.route] and 1 or 0
		self.lines[index]:SetAlpha(alpha * hit.fade)
		self.underlines[index]:SetAlpha(alpha * hit.fade * UNDER_ALPHA)
	end
end

function ns.HoverTransportRoutes(owner, routes)
	if not routes and dockHover ~= owner then
		return
	end
	dockHover, highlightedRoutes = routes and owner or nil, routes
	if transportPin then
		transportPin:UpdateAlpha()
	end
end

function FerryForeverTransportPinMixin:OnAcquired(_, geometry)
	self.paths = geometry
	transportPin = self
	self:Draw()
end

function FerryForeverTransportPinMixin:OnReleased()
	if not dockHover then
		highlightedRoutes = nil
	end
	if transportPin == self then
		transportPin = nil
	end
	MapCanvasPinMixin.OnReleased(self)
end

local TransportProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function TransportProviderMixin:RemoveAllData()
	self:GetMap():RemoveAllPinsByTemplate(TRANSPORT_TEMPLATE)
end

function TransportProviderMixin:RefreshAllData()
	self:RemoveAllData()
	local map = self:GetMap()
	if not (ns.db.mapRoutes and map:GetMapID() and map:IsVisible()) then
		return
	end
	local geometry = {}
	local ids = {}
	for id, route in pairs(ns.Routes) do
		if (route.kind == "boat" or route.kind == "zeppelin") and ns.RouteShown(route) then
			ids[#ids + 1] = id
		end
	end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local route, points = ns.Routes[id], {}
		for _, frame in ipairs(route.frames or {}) do
			points[#points + 1] = { map = frame[3], x = frame[4], y = frame[5], jump = frame[6] }
		end
		if #points > 1 then
			-- Close the loop with neighbours available on both sides of a wrapping loading gap.
			points[#points + 1] = points[1]
			geometry[#geometry + 1] = { mode = route.kind, route = id, points = points }
		end
	end
	map:AcquirePin(TRANSPORT_TEMPLATE, nil, geometry)
end

function ns.RefreshTransportRoutes()
	if transportProvider then
		transportProvider:RefreshAllData()
	end
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
	local scale = self:GetEffectiveScale()
	local border = UNDER_THICKNESS / scale
	if x and facing and radius and radius > 0 and width > border and height > border then
		local cosine, sine = math.cos(facing), math.sin(facing)
		-- GetMinimapShape is an optional addon convention (HBD-Pins:215), not a Blizzard global.
		local square = GetMinimapShape and GetMinimapShape() == "SQUARE"
		local inset = 1 - border / math.min(width, height)
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
							scale
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
	transportProvider = CreateFromMixins(TransportProviderMixin)
	WorldMapFrame:AddDataProvider(transportProvider)
	provider = CreateFromMixins(ProviderMixin)
	WorldMapFrame:AddDataProvider(provider)
	minimap = CreateFrame("Frame", "FerryForeverMinimapRoute", Minimap)
	minimap:SetAllPoints(Minimap)
	minimap:EnableMouse(false)
	minimap.lines, minimap.underlines, minimap.used = {}, {}, 0
	minimap:RegisterEvent("MINIMAP_UPDATE_ZOOM")
	minimap:SetScript("OnEvent", UpdateMinimapZoom)
	minimap:Hide()
end)
