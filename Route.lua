---@class SPFNamespace
local ns = select(2, ...)

local LINE_TEMPLATE = "ShortestPathForeverRoutePinTemplate"
local TRANSPORT_TEMPLATE = "ShortestPathForeverTransportPinTemplate"
local GOAL_TEMPLATE = "ShortestPathForeverGoalPinTemplate"
-- A solid colour line with a slim dark border, so it reads on parchment and minimap alike; the taxi line
-- atlas is mostly transparent and turned into a thin core inside a heavy border. Walks are round breadcrumbs, each
-- a dot-textured line one diameter long over a slightly larger dark dot, spaced evenly across the walk's bends.
local THICKNESS, DOT, RIM, SPACING = 2, 4, 1, 9
-- Continent and world maps show a whole journey at a fraction of a zone's scale, so their dots are smaller.
local SMALL_DOT, SMALL_SPACING = 3, 7
local DOT_TEXTURE = "Interface\\AddOns\\ShortestPathForever\\media\\Dot"
local UNDER_THICKNESS, UNDER_ALPHA = THICKNESS + 2, 0.5
local GOAL_ATLAS, GOAL_SCALE = "Waypoint-MapPin-Tracked", 0.8
local STOP_ATLAS, STOP_SIZE, MAX_NUMERAL = "adventureguide-ring", 26, 9
-- Everything past the stop being guided to recedes, so the way ahead reads first. Later lines keep their colour
-- but drop well back against parchment; later stop rings stay a little stronger so their numbers remain legible.
local LATER_ALPHA, LATER_STOP_ALPHA = 0.4, 0.55
local COLORS = {
	walk = NORMAL_FONT_COLOR,
	flight = CreateColor(0.2, 1, 0.35),
	boat = CreateColor(0, 0.75, 1),
	zeppelin = CreateColor(1, 0.35, 0.1),
	lift = ORANGE_FONT_COLOR,
	tram = ORANGE_FONT_COLOR,
	portal = CreateColor(0.85, 0.35, 1),
	passage = CreateColor(0.85, 0.35, 1),
	teleport = CreateColor(0.85, 0.35, 1),
}
local provider, goal, paths, worldPaths, stops, stopIndex
---@class SPFMinimapRoute : Frame
---@field lines Line[]
---@field underlines Line[]
---@field dots boolean[]
---@field walked number
---@field dot number
---@field spacing number
---@field used number
---@field Goal Texture
---@field strokeLayer SPFStrokeLayer
---@field elapsed number
---@field lastX? number
---@field lastY? number
---@field lastMap? number
---@field lastRadius? number
---@field lastFacing? number
---@field lastWidth? number
---@field lastHeight? number
---@field lastScale? number
---@field lastSquare? boolean
---@field revision? number
---@field fadeX? number
---@field fadeY? number
---@field fadeScaleX? number
---@field fadeScaleY? number
---@type SPFMinimapRoute
local minimap
local transportProvider, dockHover, highlightedRoutes
local geometryRevision = 0
local loading = false

-- Each map's world corners: { continent, x and y at the top left, x and y at the bottom right }.
local corners = {}

local function Corners(mapID)
	if corners[mapID] == nil then
		local continent, topLeft = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
		local other, bottomRight = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(1, 1))
		corners[mapID] = false
		if continent and continent == other and topLeft and bottomRight then
			local x0, y0 = topLeft:GetXY()
			local x1, y1 = bottomRight:GetXY()
			if x0 ~= x1 and y0 ~= y1 then
				corners[mapID] = { continent, x0, y0, x1, y1 }
			end
		end
	end
	return corners[mapID]
end

-- A world point on this map, in map fractions. Lines are clipped to the map, so a point past its edge still counts:
-- the client projects only points it places on the map, and the rest follow from the map's corners.
local function MapPosition(point, mapID)
	local uiMap, position = C_Map.GetMapPosFromWorldPos(point.map, CreateVector2D(point.x, point.y), mapID)
	if uiMap == mapID and position then
		return position:GetXY()
	end
	local map = Corners(mapID)
	if map and map[1] == point.map then
		-- World x runs north and y west, so the map's x follows world y and its y follows world x.
		return (point.y - map[3]) / (map[5] - map[3]), (point.x - map[2]) / (map[4] - map[2])
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

-- Pooled lines swap between a flat colour and the dot texture only when their use changes.
local function Paint(owner, index, dot)
	if owner.dots[index] == dot then
		return
	end
	owner.dots[index] = dot
	local line, underline = owner.lines[index], owner.underlines[index]
	if dot then
		line:SetTexture(DOT_TEXTURE)
		underline:SetTexture(DOT_TEXTURE)
		underline:SetVertexColor(0.04, 0.04, 0.04)
	else
		line:SetColorTexture(1, 1, 1, 1)
		underline:SetColorTexture(0.04, 0.04, 0.04, 1)
		underline:SetVertexColor(1, 1, 1)
	end
end

local function Stroke(owner, x1, y1, x2, y2, color, scale, dot)
	-- Client regions cannot be destroyed. Bound each reusable pool even after extreme map zooms.
	if owner.used >= 4096 then
		return
	end
	owner.used = owner.used + 1
	local line = owner.lines[owner.used]
	local underline = owner.underlines[owner.used]
	if not line then
		local layer = owner.strokeLayer or owner
		underline = layer:CreateLine(nil, "ARTWORK", nil, -1)
		underline:SetColorTexture(0.04, 0.04, 0.04, 1)
		line = layer:CreateLine(nil, "ARTWORK")
		owner.lines[owner.used] = line
		owner.underlines[owner.used] = underline
	end
	Paint(owner, owner.used, dot or false)
	local alpha = (owner.strokeAlpha or 1) * (owner.pathAlpha or 1)
	if owner.fadeX then
		local dx = ((x1 + x2) / 2 - owner.fadeX) * owner.fadeScaleX
		local dy = ((y1 + y2) / 2 - owner.fadeY) * owner.fadeScaleY
		alpha = alpha * math.min(1, math.sqrt(dx * dx + dy * dy) / 30)
	end
	-- A dot's rim reaches RIM past it on every side, so its underline is longer as well as thicker.
	local ux, uy = 0, 0
	if dot then
		local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
		ux, uy = (x2 - x1) / length * RIM / scale, (y2 - y1) / length * RIM / scale
	end
	underline:SetAlpha(alpha * UNDER_ALPHA)
	underline:SetThickness((dot and owner.dot + RIM * 2 or UNDER_THICKNESS) / scale)
	underline:SetStartPoint("TOPLEFT", owner, x1 - ux, y1 - uy)
	underline:SetEndPoint("TOPLEFT", owner, x2 + ux, y2 + uy)
	underline:Show()
	line:SetVertexColor(color:GetRGBA())
	line:SetAlpha(alpha)
	line:SetThickness((dot and owner.dot or THICKNESS) / scale)
	line:SetStartPoint("TOPLEFT", owner, x1, y1)
	line:SetEndPoint("TOPLEFT", owner, x2, y2)
	line:Show()
	if owner.hits then
		owner.hits[owner.used] = { route = owner.drawingRoute, fade = owner.strokeAlpha or 1 }
	end
end

-- Clip before subdividing: even continent-sized walks need only the visible breadcrumbs. Dots sit at every SPACING
-- along the whole walk, owner.walked carrying the distance across segment joins so bends never bunch them.
local function Segment(owner, x1, y1, x2, y2, low, high, color, dashed, scale)
	local dx, dy = x2 - x1, y2 - y1
	local length = math.sqrt(dx * dx + dy * dy) * scale
	if length == 0 then
		return
	end
	if not dashed then
		owner.walked = 0
		if low then
			Stroke(owner, x1 + low * dx, y1 + low * dy, x1 + high * dx, y1 + high * dy, color, scale)
		end
		return
	end
	local start = owner.walked
	owner.walked = start + length
	if not low then
		return
	end
	-- The caller clipped a walk a dot's reach inside its frame, so every rim fits and joints need no trim, which
	-- would drop the dots at each bend. A dot on a joint belongs to the later segment: both ends share a tolerance,
	-- so rounding in the running total cannot push it out of both.
	local half, spacing = owner.dot / 2 / length, owner.spacing
	local first = math.ceil((start + low * length - 0.001) / spacing) * spacing - start
	for distance = first, high * length - 0.001, spacing do
		local t = distance / length
		Stroke(
			owner,
			x1 + (t - half) * dx,
			y1 + (t - half) * dy,
			x1 + (t + half) * dx,
			y1 + (t + half) * dy,
			color,
			scale,
			true
		)
	end
end

local function HideUnused(owner)
	for index = owner.used + 1, #owner.lines do
		owner.lines[index]:Hide()
		owner.underlines[index]:Hide()
	end
end

local function StopPulse(layer)
	layer.animation:Stop()
	layer:SetAlpha(1)
end

local function Pulse(owner)
	local layer = owner.strokeLayer
	if not layer then
		return
	end
	if loading and owner.used > 0 and owner:IsVisible() then
		if not layer.animation:IsPlaying() then
			layer.animation:Play()
		end
	else
		StopPulse(layer)
	end
end

-- One alpha animation covers all strokes and outlines, beneath the minimap's separate arrival fade.
local function StrokeLayer(owner)
	---@class SPFStrokeLayer : Frame
	local layer = CreateFrame("Frame", nil, owner)
	owner.strokeLayer = layer
	layer:SetAllPoints(owner)
	layer:EnableMouse(false)
	local animation = layer:CreateAnimationGroup()
	animation:SetLooping("BOUNCE")
	local alpha = animation:CreateAnimation("Alpha")
	alpha:SetFromAlpha(0.8)
	alpha:SetToAlpha(0.35)
	alpha:SetDuration(0.6)
	alpha:SetSmoothing("IN_OUT")
	layer.animation = animation
	layer:SetScript("OnShow", function()
		Pulse(owner)
	end)
	layer:SetScript("OnHide", StopPulse)
end

-- JourneyInfo's loading flag drives both the header spinner and the route, even when geometry is kept.
---@param shown boolean
function ns.RefreshJourneyPulse(shown)
	if loading == shown then
		return
	end
	loading = shown
	for pin in WorldMapFrame:EnumeratePinsByTemplate(LINE_TEMPLATE) do
		Pulse(pin)
	end
	if minimap then
		Pulse(minimap)
	end
end

---@class SPFRoutePin : SPFMapPin
---@field dots boolean[]
---@field walked number
---@field dot number
---@field spacing number
---@field strokeLayer? SPFStrokeLayer
---@field pathAlpha? number
---@field UpdateAlpha? fun(self: SPFRoutePin)
ShortestPathForeverRoutePinMixin = CreateFromMixins(MapCanvasPinMixin)

function ShortestPathForeverRoutePinMixin:OnLoad()
	self:UseFrameLevelType("PIN_FRAME_LEVEL_QUEST_BLOB")
	self:SetIgnoreGlobalPinScale(true)
	self:SetScaleStyle(AM_PIN_SCALE_STYLE_WITH_TERRAIN)
	self.lines, self.underlines, self.dots, self.walked = {}, {}, {}, 0
	self.dot, self.spacing = DOT, SPACING
end

function ShortestPathForeverRoutePinMixin:Line(x1, y1, x2, y2, color, dashed)
	local scale = self:GetEffectiveScale()
	local reach = self.dot / 2 + RIM
	local mx = dashed and reach / scale / self:GetWidth() or 0
	local my = dashed and reach / scale / self:GetHeight() or 0
	local low, high = ClipAxis(x1, x2 - x1, 0, 1, mx, 1 - mx)
	if low then
		low, high = ClipAxis(y1, y2 - y1, low, high, my, 1 - my)
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
		scale
	)
end

function ShortestPathForeverRoutePinMixin:Mark(x, y, color)
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

local function CrossingCurve(pin, ax, ay, bx, by, color, px, py)
	local dx, dy = bx - ax, by - ay
	local cx, cy = (ax + bx) / 2 - dy * 0.25, (ay + by) / 2 + dx * 0.25
	if px then
		local tx, ty = ax - px, ay - py
		local length = math.sqrt(tx * tx + ty * ty)
		if length > 0 then
			local reach = math.sqrt(dx * dx + dy * dy) * 0.6 / length
			cx, cy = ax + tx * reach, ay + ty * reach
		end
	else
		-- Overview crossings arc toward open sea to the north, identically in either travel direction.
		local side = dx < 0 and -1 or 1
		cx, cy = (ax + bx) / 2 + dy * side * 0.6, (ay + by) / 2 - dx * side * 0.6
	end
	if math.abs((cx - ax) * dy - (cy - ay) * dx) < (dx * dx + dy * dy) * 0.1 then
		cx, cy = (ax + bx) / 2 - dy * 0.25, (ay + by) / 2 + dx * 0.25
	end
	Curve(pin, ax, ay, bx, by, cx, cy, color)
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
		CrossingCurve(pin, ax, ay, bx, by, color, px, py)
	elseif ax then
		EdgeCurve(pin, ax, ay, px, py, color)
	elseif bx then
		EdgeCurve(pin, bx, by, nx, ny, color)
	end
end

local function OverviewCrossing(pin, path, color)
	if path.mode ~= "boat" and path.mode ~= "zeppelin" then
		return false
	end
	local first, last = path.points[1], path.points[#path.points]
	if not first or first.map == last.map then
		return false
	end
	local mapID = pin:GetMap():GetMapID()
	local ax, ay = MapPosition(first, mapID)
	local bx, by = MapPosition(last, mapID)
	if ax and bx then
		CrossingCurve(pin, ax, ay, bx, by, color)
		return true
	end
	return false
end

function ShortestPathForeverRoutePinMixin:Draw()
	local map = self:GetMap()
	local canvas = map:GetCanvas()
	self.drawMap, self.drawWidth, self.drawHeight, self.drawScale =
		map:GetMapID(), canvas:GetWidth(), canvas:GetHeight(), self:GetEffectiveScale()
	self:SetSize(canvas:GetWidth(), canvas:GetHeight())
	self:SetPosition(0.5, 0.5)
	local info = C_Map.GetMapInfo(map:GetMapID())
	local small = info and info.mapType <= Enum.UIMapType.Continent
	self.dot, self.spacing = small and SMALL_DOT or DOT, small and SMALL_SPACING or SPACING
	self.used = 0
	if self.hits then
		self.hits = {}
	end
	-- The journey's own paths come first; the later hops Itinerary.lua adds after them recede.
	local current = self.paths == worldPaths and #paths or math.huge
	for pathIndex, path in ipairs(self.paths) do
		local color = COLORS[path.mode]
		self.drawingRoute = path.route
		self.pathAlpha = pathIndex > current and LATER_ALPHA or nil
		self.walked = 0
		local previous, px, py
		local crossing = OverviewCrossing(self, path, color)
		for index = 1, crossing and 0 or #path.points do
			local point = path.points[index]
			local x, y = MapPosition(point, map:GetMapID())
			if path.mode == "portal" or path.mode == "passage" then
				self:Mark(x, y, color)
			elseif previous then
				if path.preview then
					-- A hop still planning has no geometry to draw; a straight line would cross the sea.
					if previous.map ~= point.map then
						self:Mark(px, py, color)
						self:Mark(x, y, color)
					elseif px and x then
						self:Line(px, py, x, y, color, true)
					end
				elseif previous.jump or previous.map ~= point.map then
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
	self.pathAlpha = nil
	HideUnused(self)
	Pulse(self)
	if self.hits then
		self:UpdateAlpha()
	end
end

function ShortestPathForeverRoutePinMixin:OnReleased()
	if self.strokeLayer then
		StopPulse(self.strokeLayer)
	end
	-- Released journey pins must not keep the last route alive through the client's pin pool.
	self.paths = nil
	MapCanvasPinMixin.OnReleased(self)
end

function ShortestPathForeverRoutePinMixin:OnAcquired(geometry)
	if not self.hits and not self.strokeLayer then
		StrokeLayer(self)
	end
	local same = self.hits and self.paths and #self.paths == #geometry
	if same then
		for i, path in ipairs(geometry) do
			if self.paths[i] ~= path then
				same = false
				break
			end
		end
	end
	self.paths = geometry
	local map, canvas = self:GetMap(), self:GetMap():GetCanvas()
	local width, height, scale = canvas:GetWidth(), canvas:GetHeight(), self:GetEffectiveScale()
	if
		same
		and self.drawMap == map:GetMapID()
		and self.drawWidth == width
		and self.drawHeight == height
		and self.drawScale == scale
	then
		-- MapCanvas's pool clears anchors on release, even when the strokes remain reusable.
		self:SetPosition(0.5, 0.5)
		self:UpdateAlpha()
		return
	end
	self:Draw()
end

function ShortestPathForeverRoutePinMixin:OnCanvasScaleChanged()
	self:Draw()
end

function ShortestPathForeverRoutePinMixin:OnCanvasSizeChanged()
	self:Draw()
end

---@class SPFGoalPin : SPFMapPin
---@field Texture Texture
---@field Disc Texture
---@field Glow Texture
---@field Numeral Texture
---@field Number FontString
---@field stopTitle? string
ShortestPathForeverGoalPinMixin = CreateFromMixins(MapCanvasPinMixin)

function ShortestPathForeverGoalPinMixin:OnLoad()
	self:UseFrameLevelType("PIN_FRAME_LEVEL_SUPER_TRACKED_CONTENT")
	self:SetIgnoreGlobalPinScale(true)
	self:SetScalingLimits(1, 1, 1)
	-- The native waypoint pin (SuperTrackedFrame.lua:219) that Guide's marker wears, so map and marker agree.
	self.Number = self:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	self.Number:SetPoint("CENTER")
	self:SetScript("OnHide", self.OnMouseLeave)
end

-- A lone destination wears the waypoint pin; a numbered stop wears the ring the Adventure Guide draws for the same
-- step. Blizzard's numerals (centred in their atlas boxes, unlike font digits) stop at 9; later stops use the font.
function ShortestPathForeverGoalPinMixin:OnAcquired(x, y, number, title, later)
	self:SetPosition(x, y)
	self:SetAlpha(later and LATER_STOP_ALPHA or 1)
	self.stopTitle = title
	local numeral = number and number <= MAX_NUMERAL
	self.Disc:SetShown(number ~= nil)
	self.Numeral:SetShown(numeral == true)
	self.Number:SetText(number and not numeral and tostring(number) or "")
	if number then
		self:SetSize(STOP_SIZE, STOP_SIZE)
		self.Texture:SetAtlas(STOP_ATLAS)
		if numeral then
			self.Numeral:SetAtlas("services-number-" .. number)
		end
	else
		local atlas = C_Texture.GetAtlasInfo(GOAL_ATLAS)
		self:SetSize(atlas.width * GOAL_SCALE, atlas.height * GOAL_SCALE)
		self.Texture:SetAtlas(GOAL_ATLAS)
	end
end

function ShortestPathForeverGoalPinMixin:OnMouseEnter()
	local title, rows = ns.JourneyInfo()
	if not title or not rows then
		return
	end
	self.Glow:SetShown(self.Disc:IsShown())
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip_SetTitle(GameTooltip, self.stopTitle or title)
	for _, row in ipairs(not self.stopTitle and rows or {}) do
		GameTooltip_AddColoredLine(GameTooltip, row.text, row.current and HIGHLIGHT_FONT_COLOR or NORMAL_FONT_COLOR)
	end
	GameTooltip_AddNormalLine(GameTooltip, "Right-click to clear")
	GameTooltip:Show()
end

function ShortestPathForeverGoalPinMixin:OnMouseLeave()
	self.Glow:Hide()
	if GameTooltip:IsOwned(self) then
		GameTooltip:Hide()
	end
end

-- Pins pass right clicks to the canvas to zoom out (Blizzard_MapCanvas.lua:328); this one clears instead.
function ShortestPathForeverGoalPinMixin.ShouldMouseButtonBePassthrough()
	return false
end

function ShortestPathForeverGoalPinMixin.OnMouseClickAction(_, button)
	if button == "RightButton" then
		ns.ClearJourney()
	end
end

function ShortestPathForeverGoalPinMixin:OnReleased()
	self:OnMouseLeave()
	self.stopTitle = nil
	MapCanvasPinMixin.OnReleased(self)
end

-- One mouse-transparent canvas pin holds every boat and zeppelin route, each hidden until its dock is hovered.
---@class SPFTransportPin : SPFRoutePin
ShortestPathForeverTransportPinMixin = CreateFromMixins(ShortestPathForeverRoutePinMixin)

function ShortestPathForeverTransportPinMixin:OnLoad()
	ShortestPathForeverRoutePinMixin.OnLoad(self)
	self:UseFrameLevelType("PIN_FRAME_LEVEL_FOG_OF_WAR")
	self:EnableMouse(false)
	self.hits = {}
end

function ShortestPathForeverTransportPinMixin:UpdateAlpha()
	for index, hit in ipairs(self.hits) do
		local alpha = highlightedRoutes and highlightedRoutes[hit.route] and 1 or 0
		self.lines[index]:SetAlpha(alpha * hit.fade)
		self.underlines[index]:SetAlpha(alpha * hit.fade * UNDER_ALPHA)
	end
end

---@param owner SPFMapPin
---@param routes table<number, boolean>?
function ns.HoverTransportRoutes(owner, routes)
	if not routes and dockHover ~= owner then
		return
	end
	dockHover, highlightedRoutes = routes and owner or nil, routes
	-- Looked up rather than cached: a pin hidden with the map stays active and is not always re-acquired.
	for pin in WorldMapFrame:EnumeratePinsByTemplate(TRANSPORT_TEMPLATE) do
		---@cast pin SPFTransportPin
		pin:UpdateAlpha()
	end
end

function ShortestPathForeverTransportPinMixin:OnReleased()
	if not dockHover then
		highlightedRoutes = nil
	end
	MapCanvasPinMixin.OnReleased(self)
end

---@class SPFTransportProvider : SPFMapProvider
local TransportProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)
local transportGeometry = {}
local geometryRoutes, geometryDocks

function TransportProviderMixin:RemoveAllData()
	self:GetMap():RemoveAllPinsByTemplate(TRANSPORT_TEMPLATE)
end

function TransportProviderMixin:RefreshAllData()
	self:RemoveAllData()
	local map = self:GetMap()
	if not (ns.db.mapRoutes and map:GetMapID() and map:IsVisible()) then
		return
	end
	if geometryRoutes ~= ns.Routes or geometryDocks ~= ns.Docks then
		transportGeometry, geometryRoutes, geometryDocks = {}, ns.Routes, ns.Docks
	end
	for id in pairs(transportGeometry) do
		if not ns.Routes[id] then
			transportGeometry[id] = nil
		end
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
		local route = ns.Routes[id]
		local cached = transportGeometry[id]
		if not cached or cached.route ~= route or cached.docks ~= ns.Docks then
			cached = { route = route, docks = ns.Docks, paths = {} }
			transportGeometry[id] = cached
			-- Dock-to-dock legs preserve intermediate calls and give overview maps the actual crossing endpoints.
			for index, stop in ipairs(route.stops) do
				local onward = route.stops[index % #route.stops + 1]
				local leg = {
					mode = route.kind,
					route = id,
					from = ns.Docks[stop.dock],
					to = ns.Docks[onward.dock],
					boarding = stop,
					alighting = onward,
				}
				cached.paths[#cached.paths + 1] =
					{ mode = route.kind, route = id, points = ns.Planner.LegPoints(leg, ns.Routes) }
			end
		end
		for _, path in ipairs(cached.paths) do
			geometry[#geometry + 1] = path
		end
	end
	map:AcquirePin(TRANSPORT_TEMPLATE, geometry)
end

function ns.RefreshTransportRoutes()
	if transportProvider then
		transportProvider:RefreshAllData()
	end
end

---@class SPFRouteProvider : SPFMapProvider
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
	if #worldPaths > 0 then
		map:AcquirePin(LINE_TEMPLATE, worldPaths)
	end
	for index = stopIndex or 1, stops and #stops or 1 do
		local point = stops and stops[index] or goal
		local x, y = MapPosition(point, mapID)
		if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
			map:AcquirePin(GOAL_TEMPLATE, x, y, stops and index, point.routeTitle, stops and index > (stopIndex or 1))
		end
	end
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

-- The minimap's view radius in yards, and how far it is turned from north-up.
local function MinimapView()
	-- Blizzard_APIDocumentationGenerated/MinimapDocumentation.lua:127 (yards).
	local radius = C_Minimap.GetViewRadius()
	if GetCVar("rotateMinimap") == "1" then
		return radius, GetPlayerFacing()
	end
	return radius, 0
end

-- The minimap's transport pins share the route's projection.
ns.MinimapView, ns.MinimapProject = MinimapView, Project

-- The world point under the cursor on the minimap, undoing Project; nil off its face.
function ns.MinimapPoint()
	local x, y, _, map = ns.JourneyPosition()
	---@type number?, number?
	local radius, facing = MinimapView()
	local scale = Minimap:GetEffectiveScale()
	local cx, cy = Minimap:GetCenter()
	local mx, my = GetCursorPosition()
	local u, v = (mx / scale - cx) / (Minimap:GetWidth() / 2), (my / scale - cy) / (Minimap:GetHeight() / 2)
	if not (x and canaccessvalue(radius) and canaccessvalue(facing) and radius and facing) or u * u + v * v > 1 then
		return nil
	end
	local cosine, sine = math.cos(facing), math.sin(facing)
	local east, north = radius * (u * cosine - v * sine), radius * (u * sine + v * cosine)
	return { map = map, x = x + north, y = y - east }
end

---@param self SPFMinimapRoute
local function DrawMinimap(self)
	local x, y, _, map = ns.JourneyPosition()
	---@type number?, number?
	local radius, facing = MinimapView()
	if not (canaccessvalue(radius) and canaccessvalue(facing)) then
		radius, facing = nil, nil
	end
	local width, height = self:GetWidth(), self:GetHeight()
	local scale = self:GetEffectiveScale()
	local square = GetMinimapShape and GetMinimapShape() == "SQUARE"
	if
		self.lastX == x
		and self.lastY == y
		and self.lastMap == map
		and self.lastRadius == radius
		and self.lastFacing == facing
		and self.lastWidth == width
		and self.lastHeight == height
		and self.lastScale == scale
		and self.lastSquare == square
		and self.revision == geometryRevision
	then
		return
	end
	self.lastX, self.lastY, self.lastMap, self.lastRadius, self.lastFacing = x, y, map, radius, facing
	self.lastWidth, self.lastHeight, self.lastScale, self.lastSquare = width, height, scale, square
	self.revision = geometryRevision
	self.used = 0
	self.fadeX = nil
	self:SetAlpha(1)
	self.Goal:Hide()
	local border = UNDER_THICKNESS / scale
	if x and facing and radius and radius > 0 and width > border and height > border then
		local cosine, sine = math.cos(facing), math.sin(facing)
		if goal and goal.map == map then
			local gx, gy = Project(goal, x, y, radius, cosine, sine)
			if math.abs(gx) <= 1 and math.abs(gy) <= 1 and (square or gx * gx + gy * gy <= 1) then
				self.Goal:SetPoint("CENTER", self, "CENTER", gx * width / 2, gy * height / 2)
				self.Goal:Show()
			end
			self.fadeX, self.fadeY = (gx + 1) * width / 2, (gy - 1) * height / 2
			self.fadeScaleX, self.fadeScaleY = 2 * radius / width, 2 * radius / height
			local distance = math.sqrt((goal.x - x) ^ 2 + (goal.y - y) ^ 2)
			-- Fade the line near arrival so it does not obscure the goal.
			self:SetAlpha(math.max(0, math.min(1, (distance - 15) / 25)))
		end
		-- GetMinimapShape is an optional addon convention (HBD-Pins:215), not a Blizzard global.
		local inset = 1 - border / math.min(width, height)
		for _, path in ipairs(paths) do
			self.walked = 0
			if path.mode ~= "portal" and path.mode ~= "passage" then
				for index = 2, #path.points do
					local a, b = path.points[index - 1], path.points[index]
					if a.map == map and b.map == map and not a.jump then
						local ax, ay = Project(a, x, y, radius, cosine, sine)
						local bx, by = Project(b, x, y, radius, cosine, sine)
						local walk = path.mode == "walk"
						local within = walk and inset - (self.dot + RIM * 2) / scale / math.min(width, height) or inset
						local low, high = ClipMinimap(ax, ay, bx - ax, by - ay, within, square)
						Segment(
							self,
							(ax + 1) * width / 2,
							(ay - 1) * height / 2,
							(bx + 1) * width / 2,
							(by - 1) * height / 2,
							low,
							high,
							COLORS[path.mode],
							walk,
							scale
						)
					end
				end
			end
		end
	end
	HideUnused(self)
	Pulse(self)
end

---@param self SPFMinimapRoute
---@param elapsed number
local function UpdateMinimap(self, elapsed)
	if not (goal and ns.db.journey) then
		self.Goal:Hide()
		self:Hide()
		return
	end
	self.elapsed = self.elapsed + elapsed
	if self.elapsed >= 0.1 then
		self.elapsed = 0
		DrawMinimap(self)
	end
end

-- The world map adds the later hops as Itinerary.lua plans them; the minimap guides along the current leg only.
local function WorldPaths()
	worldPaths = paths
	if stops then
		worldPaths = {}
		for _, path in ipairs(paths) do
			worldPaths[#worldPaths + 1] = path
		end
		for _, path in ipairs(ns.JourneyPreview()) do
			worldPaths[#worldPaths + 1] = path
		end
	end
end

-- A later hop, or one of its walks, finished planning; only the world map draws the itinerary.
function ns.RefreshJourneyPreview()
	if not stops then
		return
	end
	WorldPaths()
	if provider and WorldMapFrame:IsShown() then
		provider:RefreshAllData()
	end
end

---@param destination SPFPoint?
---@param route SPFPlan?
function ns.SetJourneyRoute(destination, route)
	goal = destination
	geometryRevision = geometryRevision + 1
	paths = {}
	for _, leg in ipairs(route and route.legs or {}) do
		paths[#paths + 1] = {
			mode = leg.mode,
			points = ns.Planner.LegPoints(leg, ns.Routes),
		}
	end
	stops, stopIndex = nil, nil
	if destination and ns.JourneyStops then
		stops, stopIndex = ns.JourneyStops()
	end
	WorldPaths()
	-- The map refreshes every provider when it opens, so a closed one is left until then.
	if provider and (WorldMapFrame:IsShown() or not destination) then
		provider:RefreshAllData()
	end
	if minimap then
		if destination then
			minimap.elapsed = 0
			minimap:SetScript("OnUpdate", UpdateMinimap)
			minimap:Show()
			DrawMinimap(minimap)
		else
			minimap.Goal:Hide()
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
	local minimapRoute = CreateFrame("Frame", "ShortestPathForeverMinimapRoute", Minimap)
	---@cast minimapRoute SPFMinimapRoute
	minimap = minimapRoute
	minimap:SetAllPoints(Minimap)
	minimap:EnableMouse(false)
	minimap.lines, minimap.underlines, minimap.dots, minimap.walked, minimap.used = {}, {}, {}, 0, 0
	minimap.dot, minimap.spacing = DOT, SPACING
	StrokeLayer(minimap)
	minimap.Goal = Minimap:CreateTexture(nil, "OVERLAY")
	minimap.Goal:SetAtlas(GOAL_ATLAS)
	minimap.Goal:SetSize(16, 16)
	minimap.Goal:Hide()
	minimap:Hide()
end)
