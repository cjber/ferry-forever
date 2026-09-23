---@class SPFNamespace
local ns = select(2, ...)

-- Docks, lifts, tram stations and portals on the minimap, with the world map's icons and tooltips. The
-- minimap's own tracking icons (flight masters, mailboxes) vanish at the rim rather than cling to it, and so do
-- these.

local SIZE = 16
-- Redraws at most this often (seconds), and only when the view moved: a running player crosses under a pixel.
local INTERVAL = 0.1
-- Yards beyond the minimap's rim that keep the redraws running: more than a second's flight, since the shared
-- travel clock (Core.lua) wakes them only once a second.
local MARGIN = 100
-- Docks this close (yards) are one place: a lift's landings share a spot and differ only in height.
local SAME_PLACE = 20

local frame, entries
local pins, used = {}, 0
local lastX, lastY, lastMap, lastRadius, lastFacing, lastWidth, lastSquare, lastNear

-- entries = { { map, x, y, kind, cluster | portal }... }, rebuilt only when a filter changes. A cluster
-- matches the world map's (Map.lua Clusters) with x right and y down, so its tooltip names each pier alike.
local function Entries()
	local list, ids = {}, {}
	for dockID in pairs(ns.Docks) do
		ids[#ids + 1] = dockID
	end
	table.sort(ids)
	local function Place(dockID, point)
		for _, entry in ipairs(list) do
			local cluster = entry.cluster
			if
				cluster
				and entry.map == point.map
				and (entry.x - point.x) ^ 2 + (entry.y - point.y) ^ 2 < SAME_PLACE ^ 2
			then
				cluster.docks[#cluster.docks + 1] = { id = dockID, x = -point.y, y = -point.x }
				cluster.kinds[ns.DockKind(dockID)] = true
				return
			end
		end
		local kind = ns.DockKind(dockID)
		local cluster = {
			docks = { { id = dockID, x = -point.y, y = -point.x } },
			x = -point.y,
			y = -point.x,
			kind = kind,
			kinds = { [kind] = true },
		}
		list[#list + 1] = { map = point.map, x = point.x, y = point.y, kind = kind, cluster = cluster }
	end
	for _, dockID in ipairs(ids) do
		if ns.DockKind(dockID) and ns.DockShown(dockID) then
			local dock = ns.Docks[dockID]
			Place(dockID, dock)
			-- A tram station also shows at its city entrance, as it does on the world map.
			if dock.pin then
				Place(dockID, dock.pin)
			end
		end
	end
	if ns.db.portals then
		for _, portal in ipairs(ns.Portals) do
			if ns.PortalShown(portal) then
				local from = portal.from
				list[#list + 1] = { map = from.map, x = from.x, y = from.y, kind = "portal", portal = portal }
			end
		end
	end
	return list
end

local function Tooltip(pin)
	local entry = pin.entry
	if entry.portal then
		ns.AddPortalTooltip(entry.portal)
	else
		ns.AddDockTooltip(entry.cluster)
	end
	GameTooltip:Show()
end

local function OnUpdate(pin, elapsed)
	if not (GameTooltip:IsOwned(pin) and GameTooltip:IsShown()) then
		pin:SetScript("OnUpdate", nil)
		return
	end
	pin.elapsed = pin.elapsed + elapsed
	if pin.elapsed >= 1 then
		pin.elapsed = pin.elapsed % 1
		Tooltip(pin)
	end
end

local function OnEnter(pin)
	GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
	Tooltip(pin)
	pin.elapsed = 0
	pin:SetScript("OnUpdate", OnUpdate)
end

local function OnLeave(pin)
	pin:SetScript("OnUpdate", nil)
	if GameTooltip:IsOwned(pin) then
		GameTooltip:Hide()
	end
end

local function Acquire(entry)
	used = used + 1
	local pin = pins[used]
	if not pin then
		pin = CreateFrame("Frame", nil, frame)
		pin:SetSize(SIZE, SIZE)
		pin:EnableMouse(true)
		-- Shift-click through a pin still plans a journey there (Journey.lua's minimap handler).
		pin:SetPropagateMouseClicks(true)
		pin.Texture = pin:CreateTexture(nil, "ARTWORK")
		pin.Texture:SetPoint("CENTER")
		pin:SetScript("OnEnter", OnEnter)
		pin:SetScript("OnLeave", OnLeave)
		pin:SetScript("OnHide", OnLeave)
		pins[used] = pin
	end
	if pin.entry ~= entry then
		if GameTooltip:IsOwned(pin) then
			OnLeave(pin)
		end
		pin.entry = entry
		ns.SetTransportIcon(pin.Texture, entry.kind, SIZE)
	end
	pin:Show()
	return pin
end

local function Draw()
	local x, y, _, map = ns.JourneyPosition()
	---@type number?, number?
	local radius, facing = ns.MinimapView()
	-- Facing is nil while unavailable and secret while restricted; either way nothing below may read it.
	if not (x and canaccessvalue(radius) and canaccessvalue(facing) and radius and facing and radius > 0) then
		x, radius, facing = nil, nil, nil
	end
	local width = frame:GetWidth()
	local square = GetMinimapShape and GetMinimapShape() == "SQUARE"
	if
		x == lastX
		and y == lastY
		and map == lastMap
		and radius == lastRadius
		and facing == lastFacing
		and width == lastWidth
		and square == lastSquare
	then
		return lastNear
	end
	lastX, lastY, lastMap, lastRadius, lastFacing, lastWidth, lastSquare = x, y, map, radius, facing, width, square
	entries = entries or Entries()
	used = 0
	local near = false
	if x and radius and facing and width > SIZE then
		local cosine, sine = math.cos(facing), math.sin(facing)
		-- The whole icon stays inside the rim.
		local reach = 1 - SIZE / width
		for _, entry in ipairs(entries) do
			-- Most places are a continent away; skip them before any projection.
			local dx, dy = math.abs(entry.x - x), math.abs(entry.y - y)
			near = near or entry.map == map and dx < radius + MARGIN and dy < radius + MARGIN
			if entry.map == map and dx < radius and dy < radius then
				local px, py = ns.MinimapProject(entry, x, y, radius, cosine, sine)
				local inside
				if square then
					inside = math.abs(px) <= reach and math.abs(py) <= reach
				else
					inside = px * px + py * py <= reach * reach
				end
				if inside then
					local pin = Acquire(entry)
					pin:SetPoint("CENTER", frame, "CENTER", px * width / 2, py * width / 2)
				end
			end
		end
	end
	for index = used + 1, #pins do
		local pin = pins[index]
		if pin:IsShown() then
			pin:Hide()
			pin.entry = nil
		end
	end
	lastNear = near
	return near
end

-- Redraws run only while a place is on or just off the minimap; away from every dock and portal the addon
-- keeps no frame script of its own.
local function Update(self, elapsed)
	self.elapsed = self.elapsed + elapsed
	if self.elapsed >= INTERVAL then
		self.elapsed = 0
		if not Draw() then
			self:SetScript("OnUpdate", nil)
		end
	end
end

local function Wake()
	if ns.db.minimapPins and Draw() and not frame:GetScript("OnUpdate") then
		frame.elapsed = 0
		frame:SetScript("OnUpdate", Update)
	end
end

-- Filters and the minimap switch: rebuild the place list and redraw now.
function ns.RefreshMinimapPins()
	if not frame then
		return
	end
	entries, lastX, lastRadius = nil, nil, nil
	frame:SetScript("OnUpdate", nil)
	frame:SetShown(ns.db.minimapPins)
	Wake()
end

-- Minimap tracking (Blizzard_Minimap Mainline/Minimap.lua MiniMapTrackingButtonMixin:OnLoad) tags its menu
-- MENU_MINIMAP_TRACKING; this adds one checkbox in the style of its CreateCheckboxWithIcon.
local function AddTracking(_, rootDescription)
	local checkbox = rootDescription:CreateCheckbox("Transport", function()
		return ns.db.minimapPins
	end, function()
		ns.SetOption("minimapPins", not ns.db.minimapPins)
	end)
	checkbox:AddInitializer(function(button)
		local icon = button:AttachTexture()
		icon:SetSize(20, 20)
		icon:SetPoint("RIGHT")
		icon:SetAtlas("flightmasterferry")
		button.fontString:SetPoint("RIGHT", icon, "LEFT")
		return button.fontString:GetUnboundedStringWidth() + 60, 20
	end)
end

ns.Init(function()
	frame = CreateFrame("Frame", "ShortestPathForeverMinimapPins", Minimap)
	frame:SetAllPoints(Minimap)
	frame:EnableMouse(false)
	-- Zooming changes the view without moving; the travel clock covers movement and arrival.
	frame:RegisterEvent("MINIMAP_UPDATE_ZOOM")
	frame:SetScript("OnEvent", Wake)
	ns.OnTravelTick(Wake)
	Menu.ModifyMenu("MENU_MINIMAP_TRACKING", AddTracking)
	ns.RefreshMinimapPins()
end)
