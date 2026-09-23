---@class SPFNamespace
local ns = select(2, ...)

-- This topology belongs exclusively to estimates: Planner.Plan mutates its cache between calls.
-- Never borrow the active journey's cache, path jobs, progress, waypoint or route drawing.
local plannerCache, knownSnapshot = {}, {}
local estimates, order, slot = {}, {}, 1
local anchorSnapshot, context = {}, {}
local CACHE_LIMIT, CACHE_MS = 256, 5000
local CONTEXT_KEYS = {
	"walkSpeed",
	"faction",
	"waterWalking",
	"docks",
	"routes",
	"taxiNodes",
	"taxiPaths",
	"portals",
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
	return type(owner) == "string" and owner:find("%S") ~= nil
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

function API.Navigate(owner, map, x, y, title)
	if not Owner(owner) or not Ready() or not ns.db.journey or (title ~= nil and type(title) ~= "string") then
		return false
	end
	local point = Point(map, x, y)
	if not point or not ns.JourneyPosition() then
		return false
	end
	point.label = title
	return ns.StartJourney(point, owner)
end

function API.Cancel(owner)
	return Owner(owner) and ns.CancelOwnedJourney(owner) or false
end

ShortestPathForever = ShortestPathForever or {}
ShortestPathForever.API = API
