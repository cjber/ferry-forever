local addonName = ...
---@class SPFNamespace
local ns = select(2, ...)

local Model = ns.Model
-- The settings panel registers these same defaults, so a checkbox's reset matches a fresh install.
local DEFAULTS = {
	pins = true,
	transit = true,
	portals = true,
	minimapPins = true,
	mapFlightMasters = true,
	mapRoutes = true,
	otherFaction = true,
	tracker = true,
	alerts = true,
	alertSound = true,
	journey = true,
	teleports = true,
	share = true,
	guideStops = false,
	compass = false,
}
ns.Defaults = DEFAULTS

---@param message string
function ns.Print(message)
	print(NORMAL_FONT_COLOR:WrapTextInColorCode("Shortest Path Forever:") .. " " .. message)
end

-- Each module starts on its own, so one that fails (reported as usual) does not stop the rest.
local function Start(fn)
	xpcall(fn, geterrorhandler())
end

local pending, ready = {}, false
---@param fn fun()
function ns.Init(fn)
	if ready then
		Start(fn)
	else
		pending[#pending + 1] = fn
	end
end

local listeners = {}
---@param fn fun()
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
---@return number
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

-- Record a sighting ({ epoch = server ms at phase 0, seen = server s, source = "you"|"player" }) unless the
-- one held should stand.
---@param routeID number
---@param anchor SPFAnchor
---@return boolean
function ns.Sighted(routeID, anchor)
	local anchors = Anchors()
	if not Model.Newer(anchor, anchors[routeID], GetServerTime()) then
		return false
	end
	anchors[routeID] = { epoch = anchor.epoch, seen = anchor.seen, source = anchor.source }
	ns.sightingVersion = (ns.sightingVersion or 0) + 1
	Changed()
	return true
end

---@param routeID number
---@return SPFAnchor?
function ns.FreshAnchor(routeID)
	local anchor = Anchors()[routeID]
	return anchor and GetServerTime() - anchor.seen <= Model.MAX_AGE and anchor or nil
end

-- Sightings still fresh enough to count down from (and to share).
---@return table<number, SPFAnchor>
function ns.FreshAnchors()
	local fresh, now = {}, GetServerTime()
	for routeID, anchor in pairs(Anchors()) do
		if now - anchor.seen <= Model.MAX_AGE then
			fresh[routeID] = anchor
		end
	end
	return fresh
end

-- The zone map a world point ({ map, x, y }) sits on. GetMapPosFromWorldPos may answer with the continent, so
-- descend to the zone under the point when it does.
local function Resolve(point)
	local world = CreateVector2D(point.x, point.y)
	local uiMap, position = C_Map.GetMapPosFromWorldPos(point.map, world)
	if not uiMap then
		return nil
	end
	local info = C_Map.GetMapInfo(uiMap)
	if info and info.mapType ~= Enum.UIMapType.Zone then
		local zone = C_Map.GetMapInfoAtPosition(uiMap, position:GetXY())
		if zone and zone.mapType == Enum.UIMapType.Zone then
			local zoneMap, zonePosition = C_Map.GetMapPosFromWorldPos(point.map, world, zone.mapID)
			if zoneMap then
				uiMap, position, info = zoneMap, zonePosition, zone
			end
		end
	end
	local x, y = position:GetXY()
	return { uiMap = uiMap, x = x, y = y, zone = info and info.name or UNKNOWN }
end

local locations = setmetatable({}, { __mode = "k" })
---@param point SPFPoint
---@return SPFLocation?
function ns.Locate(point)
	if locations[point] == nil then
		locations[point] = Resolve(point) or false
	end
	return locations[point] or nil
end

-- Where a dock is drawn: the tram's stations are on a map with no world map, so they show at the city entrance.
---@param dockID number
---@return SPFPoint
function ns.DockPoint(dockID)
	local dock = ns.Docks[dockID]
	return dock.pin or dock
end

---@param dockID number
---@return SPFLocation?
function ns.DockLocation(dockID)
	return ns.Locate(ns.DockPoint(dockID))
end

---@param dockID number
---@return string
function ns.DockZone(dockID)
	local location = ns.DockLocation(dockID)
	return location and location.zone or UNKNOWN
end

-- A dock as a destination: a lift's landing or a tram station by name, a pier by its zone.
---@param dockID number
---@return string
function ns.DockLabel(dockID)
	return ns.Docks[dockID].name or ns.DockZone(dockID)
end

-- A specific stop for walking directions and tracker headings; boat destinations still use DockLabel.
---@param dockID number
---@return string
function ns.DockTitle(dockID)
	local dock = ns.Docks[dockID]
	return dock.site and dock.site .. ", " .. dock.name or ns.DockPierName(dockID)
end

local dockX, dockY, dockZ, dockMap, nearestDock, nearestYards
---@return number? dockID, number? yards
function ns.NearestDock()
	local x, y, z, map = UnitPosition("player")
	if not x then
		return nil
	end
	if x == dockX and y == dockY and z == dockZ and map == dockMap then
		return nearestDock, nearestYards
	end
	-- Height counts where it is known, so a lift's top and bottom landings stay apart.
	local nearest, yards
	for dockID, dock in pairs(ns.Docks) do
		if dock.map == map then
			local distance = math.sqrt((dock.x - x) ^ 2 + (dock.y - y) ^ 2 + (dock.z and z and (dock.z - z) ^ 2 or 0))
			if not yards or distance < yards then
				nearest, yards = dockID, distance
			end
		end
	end
	dockX, dockY, dockZ, dockMap = x, y, z, map
	nearestDock, nearestYards = nearest, yards
	return nearest, yards
end

local function SoonestFirst(a, b)
	if a.known ~= b.known then
		return a.known
	end
	return (a.departIn or 0) < (b.departIn or 0) or (a.departIn == b.departIn and a.route < b.route)
end

-- Anyone can ride either faction's boats, so the other faction's show unless turned off.
---@param route SPFRoute
---@return boolean
function ns.RouteShown(route)
	return ns.db.otherFaction or not route.faction or route.faction == UnitFactionGroup("player")
end

-- Which map filter each kind of route answers to.
local FILTER = { boat = "pins", zeppelin = "pins", lift = "transit", tram = "transit" }
---@param kind SPFMode
---@return boolean?
function ns.KindShown(kind)
	return ns.db[FILTER[kind] or error("unknown route kind " .. tostring(kind))]
end

-- Timetable topology never changes with sightings; build it only when a dock first needs it.
local dockVisits = {}
---@param dockID number
function ns.DockVisits(dockID)
	if not dockVisits[dockID] then
		local visits = {}
		for routeID, route in pairs(ns.Routes) do
			for index, stop in ipairs(route.stops) do
				if stop.dock == dockID then
					visits[#visits + 1] = { route = routeID, stop = stop, to = Model.Onward(route, index) }
				end
			end
		end
		dockVisits[dockID] = visits
	end
	return dockVisits[dockID]
end

---@param dockID number
---@return SPFDeparture[]
function ns.DockDepartures(dockID)
	local departures, now = {}, ns.NowMs()
	for _, visit in ipairs(ns.DockVisits(dockID)) do
		local routeID = visit.route
		local route = ns.Routes[routeID]
		if ns.RouteShown(route) then
			local anchor = ns.FreshAnchor(routeID)
			local departure = { route = routeID, kind = route.kind, to = visit.to, known = false }
			if anchor then
				local phase = (now - anchor.epoch) % route.period
				departure.known = true
				departure.docked, departure.arriveIn, departure.departIn = Model.Visit(route, visit.stop, phase)
				departure.seen = GetServerTime() - anchor.seen
				departure.source = anchor.source
			end
			departures[#departures + 1] = departure
		end
	end
	table.sort(departures, SoonestFirst)
	return departures
end

-- Boats sharing a lane (Auberdine's two Menethil boats, a lift's two cars) read as one line: the soonest,
-- with when the one after it leaves once both are timed. Departures arrive soonest first.
---@param departures SPFDeparture[]
---@return SPFDeparture[]
function ns.ByDestination(departures)
	local merged, first = {}, {}
	for _, departure in ipairs(departures) do
		local labels = {}
		for _, dockID in ipairs(departure.to) do
			labels[#labels + 1] = ns.DockLabel(dockID)
		end
		local key = table.concat(labels, ",")
		local lead = first[key]
		if not lead then
			first[key] = departure
			merged[#merged + 1] = departure
		elseif lead.known and departure.known and not lead.thenIn then
			lead.thenIn = departure.departIn
		end
	end
	return merged
end

-- Where the route being ridden calls next, and in how many ms, when its schedule is known.
---@param routeID number
---@return number? dockID, number? arriveIn
function ns.NextStop(routeID)
	local anchor = ns.FreshAnchor(routeID)
	if not anchor then
		return nil
	end
	local route = ns.Routes[routeID]
	local phase = (ns.NowMs() - anchor.epoch) % route.period
	local dockID, soonest
	for _, stop in ipairs(route.stops) do
		local docked, arriveIn = Model.Visit(route, stop, phase)
		if not docked and (not soonest or arriveIn < soonest) then
			dockID, soonest = stop.dock, arriveIn
		end
	end
	return dockID, soonest
end

ns.FormatCountdown = Model.FormatCountdown

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, _, name)
	if name ~= addonName then
		return
	end
	self:UnregisterEvent("ADDON_LOADED")
	ShortestPathForeverDB = ShortestPathForeverDB or {}
	ns.db = ShortestPathForeverDB
	for key, value in pairs(DEFAULTS) do
		if ns.db[key] == nil then
			ns.db[key] = value
		end
	end
	ns.db.anchors = ns.db.anchors or {}
	ns.db.anchors[GetRealmName()] = ns.db.anchors[GetRealmName()] or {}
	for routeID, anchor in pairs(ns.db.anchors[GetRealmName()]) do
		if GetServerTime() - anchor.seen > Model.MAX_AGE then
			ns.db.anchors[GetRealmName()][routeID] = nil
		end
	end
	ready = true
	for _, fn in ipairs(pending) do
		Start(fn)
	end
	pending = nil
end)

-- Passive boat/lift motion need not fire player movement events. Keep sampling near a landing and
-- through a ride; elsewhere movement/world events wake one shared clock instead of four idle tickers.
local travelListeners, travelTicker = {}, nil
local moving, probes = false, 0
---@param fn fun(dockID: number?, yards: number?)
function ns.OnTravelTick(fn)
	travelListeners[#travelListeners + 1] = fn
end

local function TravelTick()
	local dockID, yards = ns.NearestDock()
	for _, fn in ipairs(travelListeners) do
		fn(dockID, yards)
	end
	local near = yards and yards <= 200
	local observing = ns.IsObservingRide and ns.IsObservingRide()
	local journey = ns.HasJourney and ns.HasJourney()
	probes = math.max(0, probes - 1)
	local active = near or observing or journey or ns.db.debug or moving or probes > 0
	if not active and travelTicker then
		travelTicker:Cancel()
		travelTicker = nil
	end
end

function ns.WakeTravel()
	-- Two position samples also detect a reload/zone change in the middle of a crossing.
	probes = 2
	if not travelTicker then
		travelTicker = C_Timer.NewTicker(1, TravelTick)
	end
end

ns.Init(function()
	local travel = CreateFrame("Frame")
	for _, event in ipairs({
		"PLAYER_ENTERING_WORLD",
		"PLAYER_CONTROL_GAINED",
		"ZONE_CHANGED",
		"ZONE_CHANGED_INDOORS",
		"ZONE_CHANGED_NEW_AREA",
		"PLAYER_STARTED_MOVING",
		"PLAYER_STOPPED_MOVING",
		"PLAYER_REGEN_ENABLED",
	}) do
		travel:RegisterEvent(event)
	end
	travel:RegisterUnitEvent("UNIT_EXITED_VEHICLE", "player")
	travel:SetScript("OnEvent", function(_, event)
		if event == "PLAYER_STARTED_MOVING" then
			moving = true
		elseif event == "PLAYER_STOPPED_MOVING" then
			moving = false
		elseif event == "PLAYER_ENTERING_WORLD" then
			moving = IsPlayerMoving()
		end
		ns.WakeTravel()
	end)
end)
