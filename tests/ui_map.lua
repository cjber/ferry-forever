-- Continues tests/ui_client.lua: the world map, Blizzard's own map providers, and the addon loaded in TOC order.
local zoom, mapID, visible = 0, 1414, false
cursorX, cursorY = 0.5, 0.5
local pins, pools, active, providers = {}, {}, {}, {}
local canvas = { width = 1000, height = 700 }
function canvas:GetWidth()
	return self.width
end
function canvas:GetHeight()
	return self.height
end
local map = setmetatable({
	GetMapID = function()
		return mapID
	end,
	IsVisible = function()
		return visible
	end,
	GetCanvas = function()
		return canvas
	end,
	GetCanvasZoomPercent = function()
		assert(visible, "zoomLevels nil")
		return zoom
	end,
	GetGlobalPinScale = function()
		return 1.4
	end,
	GetCanvasScale = function()
		assert(visible, "zoomLevels nil")
		return 0.5 + zoom * 1.5
	end,
	GetNormalizedCursorPosition = function()
		return cursorX, cursorY
	end,
}, mt)
function map:RemoveAllPinsByTemplate(template)
	pools[template] = pools[template] or {}
	for _, pin in ipairs(active[template] or {}) do
		pin:Hide()
		pin.anchor = nil
		pin:OnReleased()
		pools[template][#pools[template] + 1] = pin
	end
	active[template] = {}
	if template:match("Dock") then
		pins = active[template]
	end
	if template:match("Portal") then
		portalPins = active[template]
	end
end
function map:AcquirePin(template, ...)
	pools[template], active[template] = pools[template] or {}, active[template] or {}
	local pin = table.remove(pools[template])
	if not pin then
		pin = stubframe()
		pin.Icon = pin:CreateTexture()
		pin.Label = setmetatable({}, fontmt)
		pin.Glow, pin.Texture, pin.HighlightTexture = setmetatable({}, mt), setmetatable({}, mt), setmetatable({}, mt)
		function pin.Texture:SetAtlas(atlas)
			self.atlas = atlas
		end
		pin.Disc, pin.Button, pin.Numeral = pin:CreateTexture(), pin:CreateTexture(), pin:CreateTexture()
		for k, v in pairs(_G[template:gsub("Template$", "Mixin")]) do
			pin[k] = v
		end
		pin:OnLoad()
	end
	active[template][#active[template] + 1] = pin
	if template:match("Dock") then
		pins = active[template]
	end
	if template:match("Portal") then
		portalPins = active[template]
	end
	pin:Show()
	pin:OnAcquired(...)
	if template:match("Transport") then
		assert(pin.anchor, "pooled transport geometry must restore its anchor")
	end
	return pin
end
portalPins = {}
_G.MapCanvasPinMixin = {
	OnReleased = noop,
	-- MapCanvas_DataProviderBase.lua:233/284: clicks reach OnMouseClickAction; right clicks pass through to zoom out.
	OnClick = function(self, button)
		if self:ShouldMouseButtonBePassthrough(button) then
			return
		end
		if self.OnMouseClickAction then
			self:OnMouseClickAction(button)
		end
	end,
	ShouldMouseButtonBePassthrough = function(_, button)
		return button == "RightButton"
	end,
	UseFrameLevelType = function(self, level)
		self.frameLevelType = level
	end,
	GetMap = function()
		return map
	end,
	GetEffectiveScale = function(self)
		return uiScale * map:GetCanvasScale() * (self.scale or 1)
	end,
	SetScalingLimits = function(self, factor, start, finish)
		self.scaleFactor, self.startScale, self.endScale = factor, start, finish
	end,
	SetIgnoreGlobalPinScale = function(self, v)
		self.ignoreGlobalPinScale = v
	end,
	SetScaleStyle = function(self, style)
		assert(style == 3)
		self.scale = self.ignoreGlobalPinScale and 1 or map:GetGlobalPinScale()
	end,
	SetPosition = function(self, x, y)
		self.x, self.y = x, y
		local scale = rawget(self, "scale") or 1
		self:SetPoint("CENTER", canvas, "TOPLEFT", canvas:GetWidth() * x / scale, -canvas:GetHeight() * y / scale)
	end,
}
_G.MapCanvasDataProviderMixin = {
	GetMap = function()
		return map
	end,
}
_G.BaseMapPoiPinMixin = {
	CreateSubPin = function(_, level)
		return CreateFromMixins(MapCanvasPinMixin, {
			OnLoad = function(self)
				self:UseFrameLevelType(level)
			end,
			SetTexture = function(self, info)
				self.Texture:SetAtlas((info.textureKit and info.textureKit .. "-" or "") .. info.atlasName)
			end,
		})
	end,
}
BaseMapPoiPinMixin.SetTexture = function(self, info)
	self.Texture:SetAtlas((info.textureKit and info.textureKit .. "-" or "") .. info.atlasName)
end
_G.SuperTrackablePoiPinMixin = {
	OnAcquired = function(self, info)
		self.poiInfo = info
		self:SetTexture(info)
		self:SetPosition(info.position:GetXY())
	end,
}
_G.MapPinTags = { FlightPoint = 1 }
assert(loadfile(BLIZZARD_UI .. "Blizzard_SharedMapDataProviders/FlightPointDataProvider.lua"))()
local clickHandlers, pinHandlers = {}, {}
_G.WorldMapFrame = setmetatable({
	dataProviders = {},
	shown = true,
	IsShown = function(self)
		return self.shown
	end,
	IsVisible = function()
		return visible
	end,
	EnumeratePinsByTemplate = function(_, template)
		local i, list = 0, active[template] or {}
		return function()
			i = i + 1
			return list[i]
		end
	end,
	AddDataProvider = function(self, provider)
		providers[#providers + 1] = provider
		self.dataProviders[provider] = true
		provider:RefreshAllData()
	end,
	RemoveDataProvider = function(self, provider)
		provider:RemoveAllData()
		self.dataProviders[provider] = nil
		for i = #providers, 1, -1 do
			if providers[i] == provider then
				table.remove(providers, i)
			end
		end
	end,
	AddCanvasClickHandler = function(_, fn)
		clickHandlers[#clickHandlers + 1] = fn
	end,
	AddGlobalPinMouseActionHandler = function(_, fn)
		pinHandlers[#pinHandlers + 1] = fn
	end,
	GetMapID = function()
		return mapID
	end,
	GetCanvasContainer = function()
		return {}
	end,
}, mt)
_G.ObjectiveTrackerManager = setmetatable({
	GetContainerForModule = function()
		return nil
	end,
}, mt)
_G.ObjectiveTrackerFrame = {}
_G.UIParent = {}
_G.WorldFrame = stubframe()
WorldFrame.width, WorldFrame.height = 1920, 1080
function WorldFrame:GetCenter()
	return 960, 540
end
_G.C_CVar = {
	GetCVar = function(name)
		return cvars[name]
	end,
}
cvars.cameraFov = "90"
_G.hooksecurefunc = function(t, name, f)
	if type(t) ~= "table" then
		return
	end
	local original = t[name]
	t[name] = function(...)
		local r = original(...)
		f(...)
		return r
	end
end
_G.GameTooltip = setmetatable({
	SetOwner = function(self, owner)
		self.owner = owner
	end,
	IsOwned = function(self, owner)
		return self.owner == owner
	end,
	IsShown = function(self)
		return self.shown
	end,
	Show = function(self)
		self.shown = true
	end,
	Hide = function(self)
		self.shown = false
		self.owner = nil
	end,
}, mt)
local mouseOverMap = true
map.ScrollContainer = {
	IsMouseOver = function()
		return mouseOverMap
	end,
}
local nativeProvider = CreateFromMixins(FlightPointDataProviderMixin)
WorldMapFrame:AddDataProvider(nativeProvider)
-- In combat GetUnitSpeed returns secret values; arithmetic on one raises, like this table does.
local SECRET = setmetatable({}, {
	__lt = function()
		error("secret number")
	end,
})
_G.canaccessvalue = function(v)
	return v ~= SECRET
end
-- Use Blizzard's acquisition and event paths so pin visibility tests also cover pooled frames.
_G.SlashCommandUtil = { CheckAddSlashCommand = noop }
_G.SLASH_COMMAND, _G.SLASH_COMMAND_CATEGORY = { MAPPIN = 1 }, { MAP = 1 }
_G.EventRegistry = { RegisterCallback = noop, UnregisterCallback = noop }
assert(loadfile(BLIZZARD_UI .. "Blizzard_SharedMapDataProviders/WaypointLocationDataProvider.lua"))()
local waypointProvider = CreateFromMixins(WaypointLocationDataProviderMixin)
do
	local events = stubframe()
	events:SetScript("OnEvent", function(_, event)
		waypointProvider:OnEvent(event)
	end)
	function waypointProvider:RegisterEvent(event)
		events:RegisterEvent(event)
	end
	function waypointProvider:UnregisterEvent(event)
		events:UnregisterEvent(event)
	end
	function waypointProvider:OnMapChanged()
		self:RefreshAllData()
	end
end
waypointProvider:OnShow()
Enum.SuperTrackingType = { Quest = "Quest", UserWaypoint = "UserWaypoint" }
-- SuperTrackedFrame.lua:228: the native icon per super-tracking type.
_G.SuperTrackedFrame = { Icon = {
	SetAtlas = function(icon, atlas)
		icon.atlas = atlas
	end,
} }
function SuperTrackedFrame:UpdateIconSize()
	self.sized = self.Icon.atlas
end
function SuperTrackedFrame:UpdateIcon()
	self.Icon:SetAtlas(
		C_SuperTrack.GetHighestPrioritySuperTrackingType() == "UserWaypoint" and "Waypoint-MapPin-Tracked"
			or "Navigation-Tracked-Icon"
	)
	self:UpdateIconSize()
end
WorldMapFrame:AddDataProvider(waypointProvider)
local ns = {}
for line in io.lines("ShortestPathForever.toc") do
	if line:match("%.lua$") then
		assert(loadfile((line:gsub("\\", "/"))))("ShortestPathForever", ns)
	end
end
local actualPath = ns.Path
ns.Path = nil -- Terrain scheduling is exercised with controlled callbacks below.
local pointArrow = ns.PointGuideArrow
ns.PointGuideArrow = function(points, placeBend, stop, goal)
	arrowPoints = points
	arrowCalls = arrowCalls + 1
	pointArrow(points, placeBend, stop, goal)
end
fireEvent("ADDON_LOADED", "ShortestPathForever")
fireEvent("PLAYER_ENTERING_WORLD")
assert(#errors == 0, table.concat(errors, "\n"))
