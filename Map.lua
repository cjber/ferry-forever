local _, ns = ...

local PIN_TEMPLATE = "FerryForeverDockPinTemplate"
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

function ns.SetWaypoint(dockID)
	local location = ns.DockLocation(dockID)
	if not location then
		ns.Print("Location unavailable for dock " .. dockID .. ".")
		return
	end
	local title = location.zone .. " dock"
	if TomTom then
		TomTom:AddWaypoint(location.uiMap, location.x, location.y, {
			title = title,
			from = "Ferry Forever",
			persistent = false,
		})
		return
	end
	if C_Map.CanSetUserWaypointOnMap(location.uiMap) then
		local point = UiMapPoint.CreateFromCoordinates(location.uiMap, location.x, location.y)
		if C_Map.SetUserWaypoint(point) then
			C_SuperTrack.SetSuperTrackedUserWaypoint(true)
			return
		end
	end
	ns.Print(string.format("%s: %.1f, %.1f", title, location.x * 100, location.y * 100))
end

FerryForeverDockPinMixin = CreateFromMixins(MapCanvasPinMixin)

function FerryForeverDockPinMixin:OnLoad()
	self:SetScalingLimits(1, 1, 1.2)
	self.Texture:SetAtlas("flightmasterferry", true)
	self.HighlightTexture:SetAtlas("flightmasterferry", true)
	self:SetSize(self.Texture:GetSize())
	self:SetScript("OnHide", self.OnMouseLeave)
end

function FerryForeverDockPinMixin:OnAcquired(dockID, x, y)
	self.dockID = dockID
	self:SetPosition(x, y)
end

function FerryForeverDockPinMixin:RefreshTooltip()
	GameTooltip_SetTitle(GameTooltip, ns.DockZone(self.dockID))
	local freshest
	for _, departure in ipairs(ns.DockDepartures(self.dockID)) do
		GameTooltip_AddColoredDoubleLine(
			GameTooltip,
			"to " .. ns.DepartureDestination(departure),
			ns.DepartureStatus(departure),
			NORMAL_FONT_COLOR,
			departure.known and HIGHLIGHT_FONT_COLOR or GRAY_FONT_COLOR
		)
		if departure.known and departure.seen and (not freshest or departure.seen < freshest.seen) then
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
	GameTooltip_AddInstructionLine(GameTooltip, "Click for a waypoint.")
	GameTooltip:Show()
end

function FerryForeverDockPinMixin:OnMouseEnter()
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
	self:SetScript("OnUpdate", nil)
	if GameTooltip:IsOwned(self) then
		GameTooltip:Hide()
	end
end

function FerryForeverDockPinMixin:OnReleased()
	self:OnMouseLeave()
	self.dockID = nil
	MapCanvasPinMixin.OnReleased(self)
end

function FerryForeverDockPinMixin:OnMouseClickAction(button)
	if button == "LeftButton" then
		ns.SetWaypoint(self.dockID)
	end
end

local ProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function ProviderMixin:RemoveAllData()
	self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE)
	self.pins = {}
end

local function IsDockMap(location, mapID)
	if location.uiMap == mapID then
		return true
	end
	local info = C_Map.GetMapInfo(location.uiMap)
	while info do
		if info.mapType == Enum.UIMapType.Continent then
			return info.mapID == mapID
		end
		if info.parentMapID == 0 then
			break
		end
		info = C_Map.GetMapInfo(info.parentMapID)
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
