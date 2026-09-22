local _, ns = ...

local PIN_TEMPLATE = "FerryForeverDockPinTemplate"
local FLIGHT_TEMPLATE = "FerryForeverFlightPinTemplate"
local PORTAL_TEMPLATE = "FerryForeverPortalPinTemplate"
local PIN_SIZE = 20
local ARROW_SIZE = 15
-- Half a pin, as a fraction of a zoomed-out map.
local EDGE = 0.015
-- Docks closer than this many pins apart merge into one.
local OVERLAP = 0.8
local provider

function ns.DepartureDestination(departure)
	local zones = {}
	for _, dockID in ipairs(departure.to) do
		zones[#zones + 1] = ns.DockLabel(dockID)
	end
	return table.concat(zones, ", then ")
end

local HERE = { boat = "docked", zeppelin = "docked", lift = "here", tram = "boarding" }

function ns.DepartureStatus(departure)
	if not departure.known then
		return "no sighting yet"
	end
	local leaves = "leaves " .. ns.FormatCountdown(departure.departIn)
	if departure.thenIn then
		leaves = leaves .. ", then " .. ns.FormatCountdown(departure.thenIn)
	end
	if departure.docked then
		return HERE[departure.kind] .. " · " .. leaves
	end
	return "arrives " .. ns.FormatCountdown(departure.arriveIn) .. " · " .. leaves
end

-- The stock ferry for boats. There is no zeppelin map icon in the game (only top-down vehicle sprites), so
-- zeppelins use our own, drawn to match the ferry (tools/draw_zeppelin.py). Lifts and the tram take the stock
-- map's floor-change arrows; portals its arcane door.
local function SetIcon(texture, kind)
	if kind == "boat" then
		texture:SetAtlas("flightmasterferry")
	elseif kind == "zeppelin" then
		texture:SetTexture("Interface\\AddOns\\FerryForever\\Media\\zeppelin")
	elseif kind == "lift" then
		texture:SetAtlas("poi-door-arrow-up")
	elseif kind == "tram" then
		texture:SetAtlas("poi-door-arrow-down")
	elseif kind == "portal" then
		texture:SetAtlas("map-icon-suramardoor.tga")
	else
		error("unknown route kind " .. tostring(kind))
	end
	-- The floor arrows fill their square where the ferry has a margin, so they draw smaller to match.
	local size = (kind == "lift" or kind == "tram") and ARROW_SIZE or PIN_SIZE
	texture:SetSize(size, size)
end

local KIND = { boat = "Boat", zeppelin = "Zeppelin", lift = "Lift", tram = "Tram" }
local KINDS = { boat = "Boats", zeppelin = "Zeppelins", lift = "Lifts", tram = "Deeprun Tram" }
local ORDER = { "boat", "zeppelin", "lift", "tram" }
local LANDING = { boat = "pier", zeppelin = "tower", lift = "landing", tram = "station" }
local COMPASS = { "east", "northeast", "north", "northwest", "west", "southwest", "south", "southeast" }

local function StatusColor(departure)
	return departure.known and HIGHLIGHT_FONT_COLOR or GRAY_FONT_COLOR
end

local function AddDepartureLines(departures)
	for _, departure in ipairs(departures) do
		GameTooltip_AddColoredDoubleLine(
			GameTooltip,
			"to " .. ns.DepartureDestination(departure),
			ns.DepartureStatus(departure),
			NORMAL_FONT_COLOR,
			StatusColor(departure)
		)
	end
end

-- Use the same departure rows on a route hover as on its docks.
function ns.TransportTooltip(routeID)
	local route, departures = ns.Routes[routeID], {}
	for _, stop in ipairs(route.stops) do
		for _, departure in ipairs(ns.DockDepartures(stop.dock)) do
			if departure.route == routeID then
				departures[#departures + 1] = departure
			end
		end
	end
	GameTooltip_SetTitle(GameTooltip, KIND[route.kind])
	AddDepartureLines(departures)
	GameTooltip:Show()
end

FerryForeverDockPinMixin = CreateFromMixins(MapCanvasPinMixin)

function FerryForeverDockPinMixin:OnLoad()
	-- Above town, flight point and dungeon icons, so a dock beside one still takes the hover.
	self:UseFrameLevelType("PIN_FRAME_LEVEL_GOSSIP")
	self:SetScalingLimits(1, 1, 1.2)
	self:SetSize(PIN_SIZE, PIN_SIZE)
	self:SetScript("OnHide", self.OnMouseLeave)
end

-- cluster = { docks = { { id, x, y }... }, x, y, kind, kinds = { [kind] = true } }: one dock, or several too
-- close to tell apart.
function FerryForeverDockPinMixin:OnAcquired(cluster)
	self.cluster = cluster
	SetIcon(self.Texture, cluster.kind)
	SetIcon(self.HighlightTexture, cluster.kind)
	self:SetPosition(cluster.x, cluster.y)
end

-- Which of a cluster's docks this is: a lift's landing or tram station by name (with its site where sites
-- differ), otherwise its zone where the zones differ, and which way it lies from the pin where they do not.
local function LandingName(cluster, dock, kind)
	local site = ns.Docks[dock.id].site
	if site then
		for _, other in ipairs(cluster.docks) do
			if ns.Docks[other.id].site ~= site then
				return ns.DockTitle(dock.id)
			end
		end
		return ns.DockLabel(dock.id)
	end
	local zone, sharedZone = ns.DockZone(dock.id), false
	for _, other in ipairs(cluster.docks) do
		sharedZone = sharedZone or (other ~= dock and ns.DockZone(other.id) == zone)
	end
	if not sharedZone then
		return zone
	end
	local angle = math.atan2(cluster.y - dock.y, dock.x - cluster.x)
	local direction = COMPASS[math.floor(angle / (2 * math.pi) * 8 + 0.5) % 8 + 1]
	local name = direction .. " " .. LANDING[kind]
	return #cluster.docks > 2 and zone .. ", " .. name or (name:gsub("^%l", string.upper))
end

-- Titled by what the pin is, not where: the map already names the zone.
function FerryForeverDockPinMixin:RefreshTooltip()
	local cluster, all = self.cluster, {}
	local groups = {}
	for _, dock in ipairs(cluster.docks) do
		local departures = ns.ByDestination(ns.DockDepartures(dock.id))
		groups[#groups + 1] = { dock = dock, departures = departures }
		for _, departure in ipairs(departures) do
			all[#all + 1] = departure
		end
	end
	if #all == 1 then
		local departure = all[1]
		GameTooltip_SetTitle(GameTooltip, KIND[departure.kind] .. " to " .. ns.DepartureDestination(departure))
		local status = ns.DepartureStatus(departure):gsub("^%l", string.upper)
		GameTooltip_AddColoredLine(GameTooltip, status, StatusColor(departure))
	else
		local titles = {}
		for _, kind in ipairs(ORDER) do
			if cluster.kinds[kind] then
				titles[#titles + 1] = KINDS[kind]
			end
		end
		GameTooltip_SetTitle(GameTooltip, table.concat(titles, " & "))
		for _, group in ipairs(groups) do
			if #groups > 1 then
				local kind = group.departures[1].kind
				GameTooltip_AddColoredLine(GameTooltip, LandingName(cluster, group.dock, kind), HIGHLIGHT_FONT_COLOR)
			end
			AddDepartureLines(group.departures)
		end
	end
	local freshest
	for _, departure in ipairs(all) do
		if departure.known and (not freshest or departure.seen < freshest.seen) then
			freshest = departure
		end
	end
	if freshest then
		local text = string.format(
			"Last seen %d min ago by %s",
			math.floor(freshest.seen / 60),
			freshest.source == "you" and "you" or "another player"
		)
		GameTooltip_AddNormalLine(GameTooltip, GRAY_FONT_COLOR:WrapTextInColorCode(text))
	end
	GameTooltip:Show()
end

function FerryForeverDockPinMixin:OnMouseEnter()
	local routes = {}
	for _, dock in ipairs(self.cluster.docks) do
		for _, departure in ipairs(ns.DockDepartures(dock.id)) do
			routes[departure.route] = true
		end
	end
	ns.HoverTransportRoutes(self, routes)
	provider:ShowDestinations(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	self:RefreshTooltip()
	self.tooltipElapsed = 0
	self:SetScript("OnUpdate", function(pin, elapsed)
		if not (GameTooltip:IsOwned(pin) and GameTooltip:IsShown()) then
			pin:SetScript("OnUpdate", nil)
			return
		end
		pin.tooltipElapsed = pin.tooltipElapsed + elapsed
		if pin.tooltipElapsed >= 1 then
			pin.tooltipElapsed = pin.tooltipElapsed % 1
			pin:RefreshTooltip()
		end
	end)
end

function FerryForeverDockPinMixin:OnMouseLeave()
	ns.HoverTransportRoutes(self, nil)
	provider:HideDestinations()
	self:SetScript("OnUpdate", nil)
	if GameTooltip:IsOwned(self) then
		GameTooltip:Hide()
	end
end

function FerryForeverDockPinMixin:OnReleased()
	self:OnMouseLeave()
	self.Glow:Hide()
	self.cluster = nil
	MapCanvasPinMixin.OnReleased(self)
end

local ProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function ProviderMixin:RemoveAllData()
	self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE)
	-- [dockID] = the pin showing it; [key of the cluster's docks] = that pin.
	self.pinOf, self.pins = {}, {}
end

-- Where the hovered pin's boats go, glowing like the map legend's related pins.
function ProviderMixin:ShowDestinations(pin)
	for _, dock in ipairs(pin.cluster.docks) do
		for _, departure in ipairs(ns.DockDepartures(dock.id)) do
			for _, destination in ipairs(departure.to) do
				local target = self.pinOf[destination]
				if target and target ~= pin then
					target.Glow:Show()
				end
			end
		end
	end
end

function ProviderMixin:HideDestinations()
	for _, pin in pairs(self.pins or {}) do
		pin.Glow:Hide()
	end
end

-- A dock shows on its zone and every map above it (continent, Azeroth), where both ends of a crossing fit.
local function IsDockMap(location, mapID)
	local info = C_Map.GetMapInfo(location.uiMap)
	while info do
		if info.mapID == mapID then
			return true
		end
		info = info.parentMapID ~= 0 and C_Map.GetMapInfo(info.parentMapID) or nil
	end
	return false
end

-- Whether a dock has any route the filters still show.
local function DockShown(dockID)
	local departures = ns.DockDepartures(dockID)
	return #departures > 0 and ns.KindShown(departures[1].kind)
end

-- A world point's position on this map, in map fractions, or nil when it is off the map.
local function MapPosition(point, mapID)
	local uiMap, position = C_Map.GetMapPosFromWorldPos(point.map, CreateVector2D(point.x, point.y), mapID)
	if uiMap ~= mapID or not position then
		return nil
	end
	local x, y = position:GetXY()
	if x >= 0 and x <= 1 and y >= 0 and y <= 1 then
		-- Piers at the map's edge (Menethil) would be half cut off; keep the whole pin on the map.
		return Clamp(x, EDGE, 1 - EDGE), Clamp(y, EDGE, 1 - EDGE)
	end
end

-- The docks on this map with any route still shown, as { id, x, y } in map fractions. A lift or tram
-- landing also shows on any neighbouring zone it falls inside: the Great Lift joins the Barrens to Thousand
-- Needles, so it belongs on both.
local function MapDocks(mapID)
	local ids, docks = {}, {}
	for dockID in pairs(ns.Docks) do
		ids[#ids + 1] = dockID
	end
	table.sort(ids)
	for _, dockID in ipairs(ids) do
		local location = ns.DockLocation(dockID)
		if location and (ns.Docks[dockID].site or IsDockMap(location, mapID)) and DockShown(dockID) then
			local x, y = MapPosition(ns.DockPoint(dockID), mapID)
			if x then
				docks[#docks + 1] = { id = dockID, x = x, y = y }
			end
		end
	end
	return docks
end

-- Docks whose pins would overlap at this zoom share one pin, at their middle.
local function Clusters(map, docks)
	local canvas = map:GetCanvas()
	local zoom = Saturate(map:GetCanvasZoomPercent())
	local size = PIN_SIZE * OVERLAP * map:GetGlobalPinScale() * Lerp(1, 1.2, zoom) / map:GetCanvasScale()
	local reachX, reachY = size / canvas:GetWidth(), size / canvas:GetHeight()
	local root = {}
	local function Find(i)
		while root[i] ~= i do
			i = root[i]
		end
		return i
	end
	for i in ipairs(docks) do
		root[i] = i
	end
	for i = 1, #docks do
		for j = i + 1, #docks do
			if math.abs(docks[i].x - docks[j].x) < reachX and math.abs(docks[i].y - docks[j].y) < reachY then
				root[Find(j)] = Find(i)
			end
		end
	end
	local byRoot, clusters = {}, {}
	for i, dock in ipairs(docks) do
		local r = Find(i)
		if not byRoot[r] then
			byRoot[r] = { docks = {} }
			clusters[#clusters + 1] = byRoot[r]
		end
		table.insert(byRoot[r].docks, dock)
	end
	for _, cluster in ipairs(clusters) do
		local x, y, ids = 0, 0, {}
		for _, dock in ipairs(cluster.docks) do
			x, y = x + dock.x, y + dock.y
			ids[#ids + 1] = dock.id
			local kind = ns.DockDepartures(dock.id)[1].kind
			cluster.kinds = cluster.kinds or {}
			cluster.kinds[kind] = true
			cluster.kind = cluster.kind or kind
		end
		cluster.x, cluster.y = x / #cluster.docks, y / #cluster.docks
		cluster.key = table.concat(ids, ",")
	end
	return clusters
end

function ProviderMixin:RefreshAllData()
	local map = self:GetMap()
	local mapID = map:GetMapID()
	-- A map never opened has no zoom levels yet; opening it refreshes every provider anyway.
	if not (mapID and map:IsVisible()) then
		self:RemoveAllData()
		return
	end
	local clusters = Clusters(map, MapDocks(mapID))
	local wanted = {}
	for _, cluster in ipairs(clusters) do
		wanted[cluster.key] = cluster
	end
	-- Rebuild only when the set of pins changed (a new map, a zoom that merged or split docks, a filter), so a
	-- hovered pin keeps its tooltip through the once-a-second refresh.
	local same = self.pins ~= nil and mapID == self.mapID
	for key in pairs(self.pins or {}) do
		same = same and wanted[key] ~= nil
	end
	for key in pairs(wanted) do
		same = same and self.pins[key] ~= nil
	end
	self.mapID = mapID
	if same then
		for _, pin in pairs(self.pins) do
			if GameTooltip:IsOwned(pin) and GameTooltip:IsShown() then
				pin:RefreshTooltip()
			end
		end
		return
	end
	self:RemoveAllData()
	for _, cluster in ipairs(clusters) do
		local pin = map:AcquirePin(PIN_TEMPLATE, cluster)
		self.pins[cluster.key] = pin
		for _, dock in ipairs(cluster.docks) do
			self.pinOf[dock.id] = pin
		end
	end
end

function ProviderMixin:OnCanvasScaleChanged()
	self:RefreshAllData()
end

FerryForeverPortalPinMixin = CreateFromMixins(MapCanvasPinMixin)

function FerryForeverPortalPinMixin:OnLoad()
	self:UseFrameLevelType("PIN_FRAME_LEVEL_GOSSIP")
	self:SetScalingLimits(1, 1, 1.2)
	self:SetSize(PIN_SIZE, PIN_SIZE)
end

function FerryForeverPortalPinMixin:OnAcquired(portal, x, y)
	self.portal = portal
	SetIcon(self.Texture, "portal")
	SetIcon(self.HighlightTexture, "portal")
	self:SetPosition(x, y)
end

function FerryForeverPortalPinMixin:OnMouseEnter()
	local portal = self.portal
	local destination = ns.Locate(portal.to)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip_SetTitle(GameTooltip, portal.name)
	GameTooltip_AddNormalLine(GameTooltip, "to " .. (destination and destination.zone or UNKNOWN))
	GameTooltip:Show()
end

function FerryForeverPortalPinMixin:OnMouseLeave()
	if GameTooltip:IsOwned(self) then
		GameTooltip:Hide()
	end
end

-- Portals are faction-locked, unlike boats; the tram's entrances already show as tram pins.
local function PortalShown(portal)
	return portal.kind == "portal" and (not portal.faction or portal.faction == UnitFactionGroup("player"))
end

local PortalProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function PortalProviderMixin:RemoveAllData()
	self:GetMap():RemoveAllPinsByTemplate(PORTAL_TEMPLATE)
end

function PortalProviderMixin:RefreshAllData()
	self:RemoveAllData()
	local mapID = self:GetMap():GetMapID()
	if not (mapID and ns.db.portals and self:GetMap():IsVisible()) then
		return
	end
	for _, portal in ipairs(ns.Portals) do
		local location = PortalShown(portal) and ns.Locate(portal.from)
		if location and IsDockMap(location, mapID) then
			local x, y = MapPosition(portal.from, mapID)
			if x then
				self:GetMap():AcquirePin(PORTAL_TEMPLATE, portal, x, y)
			end
		end
	end
end

-- Reuse the native flight-point template and acquisition (atlas size, nudging and supertracking).
FerryForeverFlightPinMixin = CreateFromMixins(FlightPointPinMixin)

function FerryForeverFlightPinMixin:OnMouseEnter()
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip_SetTitle(GameTooltip, self.poiInfo.name)
	if self.poiInfo.isUndiscovered then
		GameTooltip_AddNormalLine(GameTooltip, "Not discovered")
	end
	GameTooltip:Show()
end

function FerryForeverFlightPinMixin:OnMouseLeave()
	if GameTooltip:IsOwned(self) then
		GameTooltip:Hide()
	end
end

function FerryForeverFlightPinMixin:OnReleased()
	self:OnMouseLeave()
	MapCanvasPinMixin.OnReleased(self)
end

local FlightProviderMixin = CreateFromMixins(FlightPointDataProviderMixin)

function FlightProviderMixin:RemoveAllData()
	self:GetMap():RemoveAllPinsByTemplate(FLIGHT_TEMPLATE)
end

function FlightProviderMixin:RefreshAllData()
	self:RemoveAllData()
	local map = self:GetMap()
	local mapID = map:GetMapID()
	if not (ns.db.mapFlightMasters and mapID and map:IsVisible()) then
		return
	end
	local known, faction = ns.KnownTaxiNodes(), UnitFactionGroup("player")
	local queried, reported = {}, {}
	local function Query(id)
		if id and not queried[id] then
			queried[id] = true
			for _, info in ipairs(C_TaxiMap.GetTaxiNodesForMap(id) or {}) do
				reported[info.nodeID] = info
			end
		end
	end
	Query(mapID)
	for id, node in pairs(ns.TaxiNodes) do
		local location = ns.Locate(node)
		local x, y = MapPosition(node, mapID)
		if x and location and IsDockMap(location, mapID) then
			Query(location.uiMap)
			local unknown = known ~= nil and not known[id]
			local native = reported[id]
			-- The API's nodeID is the TaxiNodes DB2 key, also used by Taxi.lua; no name/position guessing.
			local info = {
				nodeID = id,
				name = node.name,
				position = CreateVector2D(x, y),
				isUndiscovered = unknown,
				faction = Enum.FlightPathFaction[node.faction or "Neutral"],
				-- Native fallback atlases from UiTextureAtlasMember, build 1.60.1.69913.
				atlasName = unknown and "taxinode_undiscovered" or "taxinode_" .. (node.faction or "Neutral"):lower(),
			}
			if native and native.isUndiscovered == unknown and native.atlasName ~= "" then
				info.atlasName = native.atlasName
				info.textureKit = native.textureKit ~= "" and native.textureKit or nil
			end
			if self:ShouldShowTaxiNode(faction, info) then
				map:AcquirePin(FLIGHT_TEMPLATE, info)
			end
		end
	end
end

local portalProvider, flightProvider

function ns.RefreshMap()
	if provider then
		provider:RefreshAllData()
		portalProvider:RefreshAllData()
		flightProvider:RefreshAllData()
		ns.RefreshTransportRoutes()
	end
end

-- Works before the matching Settings.lua checkboxes are registered as well as afterwards.
local function ToggleMapOption(key)
	local value = not ns.db[key]
	local setting = Settings.GetSetting("FerryForever_" .. key)
	if setting then
		setting:SetValue(value)
	else
		ns.db[key] = value
	end
	ns.RefreshMap()
end

-- The world map's Map Filter ("Show:") menu gets the same switches as the settings panel.
local function AddFilters(_, rootDescription)
	rootDescription:CreateDivider()
	rootDescription:CreateCheckbox("Flight Masters", function()
		return ns.db.mapFlightMasters
	end, function()
		ToggleMapOption("mapFlightMasters")
	end)
	rootDescription:CreateCheckbox("Boat and Zeppelin Routes", function()
		return ns.db.mapRoutes
	end, function()
		ToggleMapOption("mapRoutes")
	end)
	rootDescription:CreateCheckbox("Boats & Zeppelins", function()
		return ns.db.pins
	end, function()
		ns.SetOption("pins", not ns.db.pins)
	end)
	rootDescription:CreateCheckbox("Lifts & Tram", function()
		return ns.db.transit
	end, function()
		ns.SetOption("transit", not ns.db.transit)
	end)
	rootDescription:CreateCheckbox("Portals", function()
		return ns.db.portals
	end, function()
		ns.SetOption("portals", not ns.db.portals)
	end)
	rootDescription:CreateCheckbox("Other Faction's Routes", function()
		return ns.db.otherFaction
	end, function()
		ns.SetOption("otherFaction", not ns.db.otherFaction)
	end)
end

ns.Init(function()
	for _, key in ipairs({ "mapFlightMasters", "mapRoutes" }) do
		if ns.db[key] == nil then
			ns.db[key] = true
		end
	end
	-- Replace only this map's stock provider, avoiding duplicates if the native gate starts returning true.
	for existing in pairs(WorldMapFrame.dataProviders) do
		if existing.RefreshAllData == FlightPointDataProviderMixin.RefreshAllData then
			WorldMapFrame:RemoveDataProvider(existing)
		end
	end
	flightProvider = CreateFromMixins(FlightProviderMixin)
	WorldMapFrame:AddDataProvider(flightProvider)
	local taxiEvents = CreateFrame("Frame")
	taxiEvents:RegisterEvent("TAXI_NODE_STATUS_CHANGED")
	taxiEvents:RegisterEvent("TAXIMAP_OPENED")
	taxiEvents:SetScript("OnEvent", function()
		-- Let Taxi.lua finish updating the known-set before recolouring the pins.
		C_Timer.After(0, function()
			flightProvider:RefreshAllData()
		end)
	end)
	provider = CreateFromMixins(ProviderMixin)
	portalProvider = CreateFromMixins(PortalProviderMixin)
	WorldMapFrame:AddDataProvider(provider)
	WorldMapFrame:AddDataProvider(portalProvider)
	Menu.ModifyMenu("MENU_WORLD_MAP_TRACKING", AddFilters)
	ns.OnChange(ns.RefreshMap)
	ns.RefreshMap()
end)
