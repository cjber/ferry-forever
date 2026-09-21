local _, ns = ...

local PIN_TEMPLATE = "FerryForeverDockPinTemplate"
local PIN_SIZE = 20
-- Half a pin, as a fraction of a zoomed-out map.
local EDGE = 0.015
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

-- Zeppelins are all Horde, so the Horde airship; boats the stock ferry.
local ICONS = { boat = "flightmasterferry", zeppelin = "vehicle-air-horde" }

local function StopsAt(route, dockID)
	for _, stop in ipairs(route.stops) do
		if stop.dock == dockID then
			return true
		end
	end
	return false
end

local function DockKind(dockID)
	for _, route in pairs(ns.Routes) do
		if StopsAt(route, dockID) then
			return route.kind
		end
	end
end

FerryForeverDockPinMixin = CreateFromMixins(MapCanvasPinMixin)

function FerryForeverDockPinMixin:OnLoad()
	self:SetScalingLimits(1, 1, 1.2)
	self:SetSize(PIN_SIZE, PIN_SIZE)
	self:SetScript("OnHide", self.OnMouseLeave)
end

function FerryForeverDockPinMixin:OnAcquired(dockID, x, y)
	self.dockID = dockID
	-- The atlases are 32 and 64 square; Blizzard's own flight point pins on these maps draw at about 20.
	local atlas = ICONS[DockKind(dockID)]
	for _, texture in ipairs({ self.Texture, self.HighlightTexture }) do
		texture:SetAtlas(atlas)
		texture:SetSize(PIN_SIZE, PIN_SIZE)
	end
	self:SetPosition(x, y)
end

local KIND = { boat = "Boat", zeppelin = "Zeppelin" }
local KINDS = { boat = "Boats", zeppelin = "Zeppelins" }

local function StatusColor(departure)
	return departure.known and HIGHLIGHT_FONT_COLOR or GRAY_FONT_COLOR
end

-- Titled by what the pin is, not where: the map already names the zone.
function FerryForeverDockPinMixin:RefreshTooltip()
	local departures = ns.DockDepartures(self.dockID)
	if #departures == 1 then
		local departure = departures[1]
		GameTooltip_SetTitle(GameTooltip, KIND[departure.kind] .. " to " .. ns.DepartureDestination(departure))
		local status = ns.DepartureStatus(departure):gsub("^%l", string.upper)
		GameTooltip_AddColoredLine(GameTooltip, status, StatusColor(departure))
	else
		GameTooltip_SetTitle(GameTooltip, KINDS[departures[1].kind])
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
	local freshest
	for _, departure in ipairs(departures) do
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
	provider:ShowDestinations(self.dockID)
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
	self.dockID = nil
	MapCanvasPinMixin.OnReleased(self)
end

local ProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function ProviderMixin:RemoveAllData()
	self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE)
	self.pins = {}
end

-- Where the hovered dock's boats go, glowing like the map legend's related pins.
function ProviderMixin:ShowDestinations(dockID)
	for _, departure in ipairs(ns.DockDepartures(dockID)) do
		for _, destination in ipairs(departure.to) do
			local pin = self.pins[destination]
			if pin then
				pin.Glow:Show()
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

function ProviderMixin:RefreshAllData()
	local map = self:GetMap()
	local mapID = map:GetMapID()
	if not ns.db.pins or mapID ~= self.mapID or not self.pins then
		self:RemoveAllData()
	end
	self.mapID = mapID
	if not ns.db.pins or not mapID then
		return
	end
	for dockID, dock in pairs(ns.Docks) do
		local location = ns.DockLocation(dockID)
		if location and IsDockMap(location, mapID) then
			local pin = self.pins[dockID]
			if not pin then
				local uiMap, position = C_Map.GetMapPosFromWorldPos(dock.map, CreateVector2D(dock.x, dock.y), mapID)
				if uiMap == mapID and position then
					local x, y = position:GetXY()
					if x >= 0 and x <= 1 and y >= 0 and y <= 1 then
						-- Piers at the map's edge (Menethil) would be half cut off; keep the whole pin on the map.
						x, y = Clamp(x, EDGE, 1 - EDGE), Clamp(y, EDGE, 1 - EDGE)
						self.pins[dockID] = map:AcquirePin(PIN_TEMPLATE, dockID, x, y)
					end
				end
			elseif GameTooltip:IsOwned(pin) and GameTooltip:IsShown() then
				pin:RefreshTooltip()
			end
		end
	end
end

function ns.RefreshMap()
	if provider then
		provider:RefreshAllData()
	end
end

ns.Init(function()
	provider = CreateFromMixins(ProviderMixin)
	WorldMapFrame:AddDataProvider(provider)
	ns.OnChange(ns.RefreshMap)
	ns.RefreshMap()
end)
