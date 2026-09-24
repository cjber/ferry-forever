---@class SPFNamespace
local ns = select(2, ...)

-- This topology belongs exclusively to estimates: Planner.Plan mutates its cache between calls.
-- Never borrow the active journey's cache, path jobs, progress, waypoint or route drawing.
local plannerCache, knownSnapshot = {}, {}
local estimates, order, slot = {}, {}, 1
local anchorSnapshot, context = {}, {}
local CACHE_LIMIT, CACHE_MS = 256, 5000
-- Teleports are cast from where you stand, now: only an estimate that starts within this many yards of you counts
-- them. Anywhere else is a later leg of the caller's route, when their cooldowns are unknown.
local HERE = 15
local CONTEXT_KEYS = {
	"walkSpeed",
	"faction",
	"waterWalking",
	"docks",
	"routes",
	"taxiNodes",
	"taxiPaths",
	"portals",
	"teleports",
	"landmasses",
	"baked",
}

local function Number(value)
	return canaccessvalue(value) and type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function Point(map, x, y)
	if
		not Number(map)
		or map <= 0
		or map % 1 ~= 0
		or not Number(x)
		or not Number(y)
		or x < 0
		or x > 1
		or y < 0
		or y > 1
	then
		return nil
	end
	return ns.WorldPoint(map, x, y)
end

local function Ready()
	return ns.db and ns.charDB and not InCombatLockdown()
end

local function Owner(owner)
	return canaccessvalue(owner) and type(owner) == "string" and owner:find("%S") ~= nil
end

-- Only this module owns the caller's itinerary. Journey handles one destination at a time.
---@type {owner: string, points: SPFPoint[], index: integer}?
local route
local MAX_STOPS = 64

---@param point SPFPoint?
function ns.JourneyChanged(point)
	if not route then
		return
	end
	if point and point == route.points[route.index + 1] then
		route.index = route.index + 1
	elseif not point or point ~= route.points[route.index] then
		route = nil
	end
end

---@param point SPFPoint
---@return SPFPoint?
function ns.NextJourneyStop(point)
	return route and route.points[route.index] == point and route.points[route.index + 1] or nil
end

-- Internal read-only map view; the public API never exposes these private world points.
---@return SPFPoint[]? points, integer? index
function ns.JourneyStops()
	if route and #route.points > 1 then
		return route.points, route.index
	end
end

---@class SPFPublicAPI
local API = { version = 1 }

function API.Estimate(fromMap, fromX, fromY, toMap, toX, toY)
	if not Ready() then
		return nil
	end
	local from, to = Point(fromMap, fromX, fromY), Point(toMap, toX, toY)
	if not from or not to then
		return nil
	end
	local known = ns.KnownTaxiNodes()
	-- Discovery updates the same saved table in place; topology identity alone cannot detect it.
	local changed = false
	for id, value in pairs(known) do
		if knownSnapshot[id] ~= value then
			changed = true
			break
		end
	end
	if not changed then
		for id, value in pairs(knownSnapshot) do
			if known[id] ~= value then
				changed = true
				break
			end
		end
	end
	if changed then
		plannerCache, knownSnapshot = {}, {}
		for id, value in pairs(known) do
			knownSnapshot[id] = value
		end
	end
	local _, speed = GetUnitSpeed("player")
	local now = ns.NowMs()
	local anchors = ns.FreshAnchors()
	local teleports, ready = ns.UsableTeleports(now)
	local x, y, _, map = ns.JourneyPosition()
	if not (x and map == from.map and (x - from.x) ^ 2 + (y - from.y) ^ 2 <= HERE ^ 2) then
		ready = {}
	end
	for id, anchor in pairs(anchors) do
		if anchorSnapshot[id] ~= anchor.epoch then
			changed = true
		end
	end
	for id in pairs(anchorSnapshot) do
		if not anchors[id] then
			changed = true
		end
	end
	-- Same multimodal planner and baked walks as the arrow's initial plan. Endpoint terrain searches
	-- are asynchronous and deliberately omitted: this is an estimate, not a settled walking path.
	-- Uncached, LuaJIT -joff: Auberdine -> Eastern Plaguelands 2.45 ms cold / 0.51 ms warm;
	-- JIT compilation can make the first call ~4 ms. Forty estimates in an AGF rebuild cost ~12 ms,
	-- so cache 256 (origin rounded to 0.0001, exact destination) results for at most five seconds.
	-- Cached calls measured ~0.003 ms; a warm AGF Plan including 40 estimates measured 0.63 ms (-joff).
	local options = {
		cache = plannerCache,
		from = from,
		to = to,
		now = now,
		walkSpeed = Number(speed) and math.max(speed, 7) or 7,
		faction = UnitFactionGroup("player"),
		taxiKnown = known,
		anchors = anchors,
		docks = ns.Docks,
		routes = ns.Routes,
		taxiNodes = ns.TaxiNodes,
		taxiPaths = ns.TaxiPaths,
		portals = ns.Portals,
		teleports = teleports,
		teleportReady = ready,
		landmasses = ns.Landmasses,
		baked = ns.Walks,
		waterWalking = ns.JourneyWaterWalking(),
	}
	for _, key in ipairs(CONTEXT_KEYS) do
		if context[key] ~= options[key] then
			changed = true
		end
	end
	if changed then
		estimates, order, slot, anchorSnapshot = {}, {}, 1, {}
		for id, anchor in pairs(anchors) do
			anchorSnapshot[id] = anchor.epoch
		end
		context = options
	end
	local key = string.format("%d:%.4f:%.4f:%d:%.17g:%.17g", fromMap, fromX, fromY, toMap, toX, toY)
	local cached = estimates[key]
	if cached and now >= cached.at and now - cached.at < CACHE_MS then
		return cached.seconds or nil
	end
	local plan = ns.Planner.Plan(options)
	local seconds = plan and math.max(0, (plan.arrive - now) / 1000) or nil
	if not cached then
		if order[slot] then
			estimates[order[slot]] = nil
		end
		order[slot] = key
		slot = slot % CACHE_LIMIT + 1
	end
	estimates[key] = { at = now, seconds = seconds or false }
	return seconds
end

function API.NavigateRoute(owner, stops)
	if not Owner(owner) or not Ready() or not ns.db.journey or type(stops) ~= "table" then
		return false
	end
	local count = #stops
	if count < 1 or count > MAX_STOPS or not ns.JourneyPosition() then
		return false
	end
	for key in pairs(stops) do
		if not Number(key) or key % 1 ~= 0 or key < 1 or key > count then
			return false
		end
	end
	local points = {}
	for index = 1, count do
		local stop = stops[index]
		if
			type(stop) ~= "table"
			or (stop.title ~= nil and not (canaccessvalue(stop.title) and type(stop.title) == "string"))
		then
			return false
		end
		local point = Point(stop.map, stop.x, stop.y)
		if not point then
			return false
		end
		point.label = stop.title
		if count > 1 then
			local location = not point.label and ns.Locate(point)
			point.routeTitle =
				string.format("Stop %d of %d: %s", index, count, point.label or location and location.zone or UNKNOWN)
		end
		points[index] = point
	end
	-- Validate and copy every stop before replacing guidance. Caller mutations cannot redirect a journey.
	route = { owner = owner, points = points, index = 1 }
	return ns.StartJourney(points[1])
end

function API.Navigate(owner, map, x, y, title)
	return API.NavigateRoute(owner, { { map = map, x = x, y = y, title = title } })
end

function API.CurrentStop(owner)
	return Owner(owner) and route and route.owner == owner and route.index or nil
end

function API.Cancel(owner)
	if not API.CurrentStop(owner) then
		return false
	end
	ns.ClearJourney()
	return true
end

ShortestPathForever = ShortestPathForever or {}
ShortestPathForever.API = API
