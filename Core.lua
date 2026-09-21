local addonName, ns = ...

local Model = ns.Model
local DEFAULTS = { pins = true, tracker = true, share = true }

function ns.Print(message)
	print(NORMAL_FONT_COLOR:WrapTextInColorCode("Ferry Forever:") .. " " .. message)
end

local pending, ready = {}, false
function ns.Init(fn)
	if ready then
		fn()
	else
		pending[#pending + 1] = fn
	end
end

local listeners = {}
function ns.OnChange(fn)
	listeners[#listeners + 1] = fn
end

local function Changed()
	for _, fn in ipairs(listeners) do
		fn()
	end
end

-- Server time in ms. GetServerTime has whole seconds; it floors the true time, so its largest lead over
-- GetTime is the offset between the two clocks (reset if the clocks jump).
local offset
function ns.NowMs()
	local lead = GetServerTime() - GetTime()
	if not offset or lead > offset or offset - lead > 2 then
		offset = lead
	end
	return (GetTime() + offset) * 1000
end

local function Anchors()
	return ns.db.anchors[GetRealmName()]
end

-- Record a sighting ({ epoch = server ms at phase 0, seen = server s }) unless a newer one is held.
function ns.Sighted(routeID, anchor, source)
	local anchors = Anchors()
	if not Model.Newer(anchor, anchors[routeID]) then
		return false
	end
	anchors[routeID] = { epoch = anchor.epoch, seen = anchor.seen, source = source }
	Changed()
	return true
end

-- Sightings still fresh enough to count down from (and to share).
function ns.FreshAnchors()
	local fresh, now = {}, GetServerTime()
	for routeID, anchor in pairs(Anchors()) do
		if now - anchor.seen <= Model.MAX_AGE then
			fresh[routeID] = anchor
		end
	end
	return fresh
end

-- The zone map a dock sits on. GetMapPosFromWorldPos may answer with the continent, so descend to the zone
-- under the point when it does.
local locations = {}
local function Resolve(dock)
	local world = CreateVector2D(dock.x, dock.y)
	local uiMap, position = C_Map.GetMapPosFromWorldPos(dock.map, world)
	if not uiMap then
		return nil
	end
	local info = C_Map.GetMapInfo(uiMap)
	if info and info.mapType ~= Enum.UIMapType.Zone then
		local zone = C_Map.GetMapInfoAtPosition(uiMap, position:GetXY())
		if zone and zone.mapType == Enum.UIMapType.Zone then
			uiMap, position = C_Map.GetMapPosFromWorldPos(dock.map, world, zone.mapID)
			info = zone
		end
	end
	local x, y = position:GetXY()
	return { uiMap = uiMap, x = x, y = y, zone = info and info.name or UNKNOWN }
end

function ns.DockLocation(dockID)
	if locations[dockID] == nil then
		locations[dockID] = Resolve(ns.Docks[dockID]) or false
	end
	return locations[dockID] or nil
end

function ns.DockZone(dockID)
	local location = ns.DockLocation(dockID)
	return location and location.zone or UNKNOWN
end

function ns.NearestDock()
	local x, y, _, map = UnitPosition("player")
	if not x then
		return nil
	end
	local nearest, yards
	for dockID, dock in ipairs(ns.Docks) do
		if dock.map == map then
			local distance = math.sqrt((dock.x - x) ^ 2 + (dock.y - y) ^ 2)
			if not yards or distance < yards then
				nearest, yards = dockID, distance
			end
		end
	end
	return nearest, yards
end

local function SoonestFirst(a, b)
	if a.known ~= b.known then
		return a.known
	end
	return (a.departIn or 0) < (b.departIn or 0) or (a.departIn == b.departIn and a.route < b.route)
end

function ns.DockDepartures(dockID)
	local departures, fresh, now = {}, ns.FreshAnchors(), ns.NowMs()
	for routeID, route in pairs(ns.Routes) do
		for index, stop in ipairs(route.stops) do
			if stop.dock == dockID then
				local anchor = fresh[routeID]
				local departure = { route = routeID, kind = route.kind, to = Model.Onward(route, index), known = false }
				if anchor then
					local phase = (now - anchor.epoch) % route.period
					departure.known = true
					departure.docked, departure.arriveIn, departure.departIn = Model.Visit(route, stop, phase)
					departure.seen = GetServerTime() - anchor.seen
					departure.source = anchor.source
				end
				departures[#departures + 1] = departure
			end
		end
	end
	table.sort(departures, SoonestFirst)
	return departures
end

ns.FormatCountdown = Model.FormatCountdown

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, _, name)
	if name ~= addonName then
		return
	end
	self:UnregisterEvent("ADDON_LOADED")
	FerryForeverDB = FerryForeverDB or {}
	ns.db = FerryForeverDB
	for key, value in pairs(DEFAULTS) do
		if ns.db[key] == nil then
			ns.db[key] = value
		end
	end
	ns.db.anchors = ns.db.anchors or {}
	ns.db.anchors[GetRealmName()] = ns.db.anchors[GetRealmName()] or {}
	ready = true
	for _, fn in ipairs(pending) do
		fn()
	end
	pending = nil
end)
