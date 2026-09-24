---@class SPFNamespace
local ns = select(2, ...)

-- Boat and zeppelin routes on the world map, drawn with Route.lua's strokes and shown while their dock is hovered.
local TRANSPORT_TEMPLATE = "ShortestPathForeverTransportPinTemplate"
local UNDER_ALPHA = ns.RouteUnderAlpha
local transportProvider, dockHover, highlightedRoutes

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

ns.Init(function()
	transportProvider = CreateFromMixins(TransportProviderMixin)
	WorldMapFrame:AddDataProvider(transportProvider)
end)
