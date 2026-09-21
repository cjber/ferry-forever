local _, ns = ...

local PIN_TEMPLATE = "FerryForeverDockPinTemplate"
local PIN_SIZE = 20
-- Half a pin, as a fraction of a zoomed-out map.
local EDGE = 0.015
-- Docks closer than this many pins apart merge into one.
local OVERLAP = 0.8
local provider

function ns.DepartureDestination(departure)
	local zones = {}
	for _, dockID in ipairs(departure.to) do
		zones[#zones + 1] = ns.DockZone(dockID)
	end
	return table.concat(zones, ", then ")
end

function ns.DepartureStatus(departure)
	if not departure.known then
		return "no sighting yet"
	end
	local leaves = "leaves " .. ns.FormatCountdown(departure.departIn)
	if departure.docked then
		return "docked · " .. leaves
	end
	return "arrives " .. ns.FormatCountdown(departure.arriveIn) .. " · " .. leaves
end

-- The stock ferry for boats. There is no zeppelin map icon in the game (only top-down vehicle sprites), so
-- zeppelins use our own, drawn to match the ferry (tools/draw_zeppelin.py).
local function SetIcon(texture, kind)
	if kind == "boat" then
		texture:SetAtlas("flightmasterferry")
	elseif kind == "zeppelin" then
		texture:SetTexture("Interface\\AddOns\\FerryForever\\Media\\zeppelin")
	else
		error("unknown route kind " .. tostring(kind))
	end
	texture:SetSize(PIN_SIZE, PIN_SIZE)
end

local KIND = { boat = "Boat", zeppelin = "Zeppelin" }
local KINDS = { boat = "Boats", zeppelin = "Zeppelins" }
local LANDING = { boat = "pier", zeppelin = "tower" }
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

FerryForeverDockPinMixin = CreateFromMixins(MapCanvasPinMixin)

function FerryForeverDockPinMixin:OnLoad()
	-- Above town, flight point and dungeon icons, so a dock beside one still takes the hover.
	self:UseFrameLevelType("PIN_FRAME_LEVEL_GOSSIP")
	self:SetScalingLimits(1, 1, 1.2)
	self:SetSize(PIN_SIZE, PIN_SIZE)
	self:SetScript("OnHide", self.OnMouseLeave)
end

-- cluster = { docks = { { id, x, y }... }, x, y, kind }: one dock, or several too close to tell apart.
function FerryForeverDockPinMixin:OnAcquired(cluster)
	self.cluster = cluster
	SetIcon(self.Texture, cluster.kind)
	SetIcon(self.HighlightTexture, cluster.kind)
	self:SetPosition(cluster.x, cluster.y)
end

-- Which of a cluster's docks this is: its zone where the zones differ, and which way it lies from the pin
-- where they do not.
local function LandingName(cluster, dock, kind)
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
		local departures = ns.DockDepartures(dock.id)
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
		GameTooltip_SetTitle(
			GameTooltip,
			cluster.mixed and KINDS.boat .. " & " .. KINDS.zeppelin or KINDS[cluster.kind]
		)
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

-- The docks on this map with any route still shown, as { id, x, y } in map fractions.
local function MapDocks(mapID)
	local docks = {}
	for dockID, dock in ipairs(ns.Docks) do
		local location = ns.DockLocation(dockID)
		if location and IsDockMap(location, mapID) and #ns.DockDepartures(dockID) > 0 then
			local uiMap, position = C_Map.GetMapPosFromWorldPos(dock.map, CreateVector2D(dock.x, dock.y), mapID)
			if uiMap == mapID and position then
				local x, y = position:GetXY()
				if x >= 0 and x <= 1 and y >= 0 and y <= 1 then
					-- Piers at the map's edge (Menethil) would be half cut off; keep the whole pin on the map.
					docks[#docks + 1] = { id = dockID, x = Clamp(x, EDGE, 1 - EDGE), y = Clamp(y, EDGE, 1 - EDGE) }
				end
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
			cluster.mixed = cluster.mixed or (cluster.kind and cluster.kind ~= kind)
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
	if not ns.db.pins or not mapID then
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

function ns.RefreshMap()
	if provider then
		provider:RefreshAllData()
	end
end

-- The world map's Map Filter ("Show:") menu gets the same switches as the settings panel.
local function AddFilters(_, rootDescription)
	rootDescription:CreateDivider()
	rootDescription:CreateCheckbox("Boats & Zeppelins", function()
		return ns.db.pins
	end, function()
		ns.SetOption("pins", not ns.db.pins)
	end)
	rootDescription:CreateCheckbox("Other Faction's Routes", function()
		return ns.db.otherFaction
	end, function()
		ns.SetOption("otherFaction", not ns.db.otherFaction)
	end)
end

ns.Init(function()
	provider = CreateFromMixins(ProviderMixin)
	WorldMapFrame:AddDataProvider(provider)
	Menu.ModifyMenu("MENU_WORLD_MAP_TRACKING", AddFilters)
	ns.OnChange(ns.RefreshMap)
	ns.RefreshMap()
end)
