---@class SPFNamespace
local ns = select(2, ...)

-- Shift-click the world map: the fastest way there from here, by foot, flight, boat, zeppelin, tram and portal,
-- with the boats' live waits. Search candidates stay private until costs and geometry settle, with a grace
-- period for longer searches. The tracker owns the list; closing the map leaves the journey running.
local REPLAN_EVERY, REFRESH_EVERY = 5, 60
-- The frames around a timed replan, which Itinerary.lua leaves to it.
local REPLAN_MARGIN = 0.5
local DRAW_EVERY, SEARCH_GRACE = 0.5, 3
local PROBE_BUDGET = 60 -- ms before switching from candidate costs to shared endpoint searches
-- A teleport step, by the item's or spell's own name in the game's language.
local USE_ITEM, CAST_SPELL = "Use %s", "Cast %s"

local goal, guide, result
local nextPoint
local search, FinishSearch
local plannerCache = {}
local walkOrder, walkPending = {}, {}
local WALK_CACHE_LIMIT = 64
local progress = { index = 1 }
---@class SPFJourneyDriver : Frame
---@field elapsed number
---@field replannedAt? number GetTime of the last timed replan
---@field progressElapsed number
---@field riding? number
---@field flying? boolean
---@field drawAt? number
---@field drawX? number
---@field drawY? number
---@field drawMap? number
---@type SPFJourneyDriver
local driver
local ARRIVAL = 15
local lastRunSpeed = 7
local pathJobs, walkCache, pathVersion = {}, {}, 0
local pendingWalks, pendingCosts, settleRound = 0, 0, 0
local startBatch, goalBatch, startAt, refreshedAt
local startCosts, goalCosts = {}, {}
refreshedAt = 0
local costError, goalError
local costsWaiting
-- Walking along a measured path from where you stood, how far off it you may stray and still be on it.
local ON_PATH = 15
-- Timed replans replace the followed route only for a worthwhile gain; endpoint costs stay unchanged between
-- the infrequent batches, except for Remaining() along the walk you are following.
local SWITCH_GAIN, SWITCH_SHARE = 30000, 0.1
-- Water Walking, Levitate and the Elixir of Water Walking make water ground. A spell you know counts too: the step
-- asks you to cast it. waterMode is the mode this journey's walks were searched in.
local WATER_AURAS = { 546, 1706, 11319 }
local WATER_SPELLS = { 546, 1706 }
-- Yards over water worth casting for.
local WATER_HINT = 20
local waterMode
local WALK_FAILURE = {
	unreachable = "no walking path",
	offmesh = "no walking path",
	outside = "no walking path",
	nodata = "walking map unavailable",
	error = "walking search failed",
}

local function RefreshTracker()
	ns.journeyVersion = (ns.journeyVersion or 0) + 1
	ns.RefreshTracker()
end

---@return boolean
function ns.HasJourney()
	return goal ~= nil
end

local function CancelPaths()
	pathVersion = pathVersion + 1
	for job in pairs(pathJobs) do
		ns.Path.Cancel(job)
	end
	for _, batch in pairs({ start = startBatch, goal = goalBatch }) do
		if batch.job and batch.path.Pause then
			batch.path.Pause(batch.job)
		end
	end
	pathJobs, walkPending, pendingWalks, pendingCosts = {}, {}, 0, 0
end

-- Whether walks may cross water, and the spell to cast first when none is up.
local function WaterWalking()
	for _, id in ipairs(WATER_AURAS) do
		if C_UnitAuras.GetPlayerAuraBySpellID(id) then
			return true
		end
	end
	for _, id in ipairs(WATER_SPELLS) do
		-- Forever still exposes IsPlayerSpell; Ketho marks the retail compatibility wrapper deprecated.
		---@diagnostic disable-next-line: deprecated
		if IsPlayerSpell(id) then
			return true, id
		end
	end
	return false
end

-- Read-only capability query shared by the public estimator and the guided planner.
ns.JourneyWaterWalking = WaterWalking

-- A missing/secret sample is not evidence that the journey is unreachable. Planning, Guide and lines share this gate.
-- UnitPosition's third value is a placeholder, always 0, so the player's height is unknown: never a floor.
---@return number? x, number? y, nil z, number? map
function ns.JourneyPosition()
	local x, y, _, map = UnitPosition("player")
	if not (canaccessvalue(x) and canaccessvalue(y) and canaccessvalue(map)) or not (x and y and map) then
		return nil
	end
	return x, y, nil, map
end

local function Here()
	local x, y, _, map = ns.JourneyPosition()
	return x and { map = map, x = x, y = y }
end

local function Near(node, reach)
	local x, y, _, map = ns.JourneyPosition()
	return x and map == node.map and (x - node.x) ^ 2 + (y - node.y) ^ 2 <= (reach or ARRIVAL) ^ 2
end

local function SameWaypoint(a, b)
	if a == b then
		return true
	end
	if not (a and b) then
		return false
	end
	-- C_Map.GetUserWaypoint's position is a plain { x, y } table, not a Vector2D (WaypointLocationDataProvider.lua:183).
	if a.uiMapID == b.uiMapID and a.position.x == b.position.x and a.position.y == b.position.y then
		return true
	end
	local aMap, aWorld = C_Map.GetWorldPosFromMapPos(a.uiMapID, CreateVector2D(a.position.x, a.position.y))
	local bMap, bWorld = C_Map.GetWorldPosFromMapPos(b.uiMapID, CreateVector2D(b.position.x, b.position.y))
	-- Map changes can reproject or round the read-back. One yard absorbs that without claiming a different pin.
	return aWorld and bWorld and aMap == bMap and (aWorld.x - bWorld.x) ^ 2 + (aWorld.y - bWorld.y) ^ 2 <= 1
end

local waypointProviders = {}

-- Guide's waypoint only steers the native marker; our own pins already draw the route and destination.
local function HideGuideWaypointPin(provider)
	if provider.pin then
		local owned = guide and (guide.writingWaypoint or guide.waypoint)
		provider.pin:SetShown(not (owned and SameWaypoint(C_Map.GetUserWaypoint(), owned)))
	end
end

local function RefreshWaypointPins()
	-- Events may be deferred; a closed map is unsubscribed and may not have initialized its canvas yet.
	for _, provider in ipairs(waypointProviders) do
		if provider:GetMap():IsVisible() then
			provider:RefreshAllData()
		else
			provider:RemoveAllData()
		end
	end
end

local function ClearOrphanWaypoint()
	local saved = ns.charDB.guideWaypoint
	if guide or not saved then
		return
	end
	-- Journeys do not survive reloads, but the client saves user waypoints independently of this addon.
	ns.charDB.guideWaypoint = nil
	local point = UiMapPoint.CreateFromCoordinates(saved.uiMapID, saved.x, saved.y)
	if SameWaypoint(C_Map.GetUserWaypoint(), point) then
		C_Map.ClearUserWaypoint()
		C_SuperTrack.SetSuperTrackedUserWaypoint(false)
		RefreshWaypointPins()
	end
end

local function RememberTracking(state)
	state.expectedQuest = C_SuperTrack.GetSuperTrackedQuestID()
	state.expectedTrackedWaypoint = C_SuperTrack.IsSuperTrackingUserWaypoint()
	state.expectedTrackingType = C_SuperTrack.GetHighestPrioritySuperTrackingType()
end

local function SameTracking(state)
	return state.expectedQuest == C_SuperTrack.GetSuperTrackedQuestID()
		and state.expectedTrackedWaypoint == C_SuperTrack.IsSuperTrackingUserWaypoint()
		and state.expectedTrackingType == C_SuperTrack.GetHighestPrioritySuperTrackingType()
end

local function StopGuide()
	local previous = guide
	guide = nil
	ns.PointGuideArrow(nil)
	if previous then
		ns.charDB.guideWaypoint = nil
	end
	if
		not previous
		or not previous.hasDriven
		or not SameWaypoint(C_Map.GetUserWaypoint(), previous.expectedWaypoint)
	then
		RefreshWaypointPins()
		return
	end
	local ownsTracking = not previous.yielded and SameTracking(previous)
	local restored = previous.previousWaypoint and C_Map.SetUserWaypoint(previous.previousWaypoint)
	-- A rejected restoration must still remove our bend, rather than leave it behind without an ownership record.
	if not restored and previous.waypoint then
		C_Map.ClearUserWaypoint()
	end
	if ownsTracking then
		local tracked = restored and previous.previousTrackedWaypoint or false
		C_SuperTrack.SetSuperTrackedUserWaypoint(tracked)
		if not tracked then
			C_SuperTrack.SetSuperTrackedQuestID(previous.previousQuest or 0)
		end
	elseif not restored and C_SuperTrack.IsSuperTrackingUserWaypoint() then
		C_SuperTrack.SetSuperTrackedUserWaypoint(false)
	end
	RefreshWaypointPins()
end

local function OwnsWaypoint()
	if not SameWaypoint(C_Map.GetUserWaypoint(), guide.expectedWaypoint) then
		-- A manual replacement or removal ends guidance; never reclaim the player's waypoint.
		StopGuide()
		return false
	end
	return true
end

local function ClearGuideWaypoint()
	-- Synchronous clear events must see an internal write, and deferred events must see the empty expected point.
	guide.writing = true
	C_Map.ClearUserWaypoint()
	C_SuperTrack.SetSuperTrackedUserWaypoint(false)
	guide.waypoint, guide.expectedWaypoint = nil, nil
	ns.charDB.guideWaypoint = nil
	RememberTracking(guide)
	guide.writing = nil
	RefreshWaypointPins()
end

local function YieldGuide()
	-- A quest/map-pin click belongs to the player. Keep the route arrow, but never retake tracking.
	guide.yielded = true
	if guide.waypoint then
		ClearGuideWaypoint()
	end
end

local function GuideWaypoint(point, fading)
	if not guide then
		return false
	end
	-- The bend callback can run before deferred notifications of a player's waypoint or tracking change.
	if not OwnsWaypoint() then
		RefreshTracker()
		return false
	end
	if not guide.yielded and not SameTracking(guide) then
		YieldGuide()
	end
	if guide.yielded then
		return false
	end
	local uiMap = C_Map.GetBestMapForUnit("player")
	local bend = guide.bend
	if
		not bend
		or point.map ~= bend.map
		or point.x ~= bend.x
		or point.y ~= bend.y
		or uiMap ~= guide.uiMap
		or fading ~= guide.fading
	then
		guide.bend, guide.uiMap = { map = point.map, x = point.x, y = point.y }, uiMap
		guide.fading = fading
		local waypoint
		-- The native waypoint has no per-pin alpha; near the goal, use the fading fallback instead of stacking icons.
		if not fading and uiMap and C_Map.CanSetUserWaypointOnMap(uiMap) then
			local projectedMap, position =
				C_Map.GetMapPosFromWorldPos(point.map, CreateVector2D(point.x, point.y), uiMap)
			if projectedMap == uiMap and position then
				local x, y = position:GetXY()
				if x >= 0 and x <= 1 and y >= 0 and y <= 1 then
					waypoint = UiMapPoint.CreateFromVector2D(uiMap, position)
				end
			end
		end
		-- These APIs may dispatch events synchronously. Only our own writes bypass ownership checks.
		guide.writing = true
		guide.writingWaypoint = waypoint
		if waypoint and C_Map.SetUserWaypoint(waypoint) then
			guide.waypoint, guide.expectedWaypoint = waypoint, waypoint
			ns.charDB.guideWaypoint = { uiMapID = waypoint.uiMapID, x = waypoint.position.x, y = waypoint.position.y }
			guide.hasDriven = true
			C_SuperTrack.SetSuperTrackedUserWaypoint(true)
		elseif guide.waypoint then
			-- Never leave a stale native marker pointing at the preceding bend when projection fails.
			ClearGuideWaypoint()
		end
		-- Deferred events from our own writes must also agree with the expected tracking state.
		RememberTracking(guide)
		guide.writing, guide.writingWaypoint = nil, nil
		for _, provider in ipairs(waypointProviders) do
			HideGuideWaypointPin(provider)
		end
	end
	return guide.waypoint ~= nil and C_SuperTrack.IsSuperTrackingUserWaypoint()
end

local function GuideTo(node, points)
	if not guide or (guide.target == node and guide.points == points) then
		return
	end
	guide.points = points
	guide.target = node
	local point = node.kind == "dock" and ns.DockPoint(node.id) or node
	ns.PointGuideArrow(points or { point }, GuideWaypoint, node, goal)
end

-- A teleport is cast where you stand: nothing to walk toward until you land, so no arrow or marker.
local function GuideCast(leg)
	if not guide or guide.target == leg then
		return
	end
	guide.points, guide.target = nil, leg
	ns.PointGuideArrow(nil)
	if guide.waypoint then
		ClearGuideWaypoint()
	end
end

---@param reason "arrived"|"cleared"
local function EndJourney(reason)
	CancelPaths()
	costsWaiting = nil
	settleRound, costError, goalError = 0, nil, nil
	for _, batch in pairs({ start = startBatch, goal = goalBatch }) do
		if batch.job then
			batch.path.Cancel(batch.job)
		end
	end
	startBatch, goalBatch, search = nil, nil, nil
	walkCache, walkOrder, startCosts, goalCosts, startAt, plannerCache = {}, {}, {}, {}, nil, {}
	if ns.Path and ns.Path.ClearCaches then
		ns.Path.ClearCaches()
	end
	StopGuide()
	goal, result, nextPoint = nil, nil, nil
	if ns.JourneyChanged then
		ns.JourneyChanged(nil, reason)
	end
	progress.index, progress.departed = 1, false
	driver:Hide()
	ns.SetJourneyRoute(nil)
	RefreshTracker()
end

-- Menus and settings pass their own arguments to callbacks, so the player's clear takes none.
function ns.ClearJourney()
	EndJourney("cleared")
end

-- Completion may run inside a planner callback. Start at most one next stop on the driver's next step,
-- after that callback unwinds; coincident stops must never recurse through the whole route in one frame.
local function Arrive()
	nextPoint = ns.NextJourneyStop and ns.NextJourneyStop(goal)
	if not nextPoint then
		EndJourney("arrived")
	end
end

local function UpdateProgress()
	if not (goal and result) or nextPoint then
		return
	end
	if Near(goal) then
		Arrive()
		return
	end
	local riding, flying = ns.CurrentRide(), UnitOnTaxi("player")
	while progress.index <= #result.legs do
		local leg = result.legs[progress.index]
		local nextLeg = result.legs[progress.index + 1]
		if
			leg.mode == "walk"
			and nextLeg
			and ((nextLeg.route and riding == nextLeg.route) or (nextLeg.mode == "flight" and flying))
		then
			progress.index = progress.index + 1
			leg = nextLeg
		end
		-- A teleport is cast from wherever you are.
		local aboard = leg.aboard
			or leg.mode == "teleport"
			or (leg.route and riding == leg.route)
			or (leg.mode == "flight" and flying)
		if leg.mode ~= "walk" and not progress.departed then
			if aboard or Near(leg.from) then
				progress.departed = true
			else
				GuideTo(leg.from)
				return
			end
		end
		if leg.mode == "teleport" and not Near(leg.to) then
			GuideCast(leg)
			return
		end
		if not Near(leg.to) or (leg.mode == "flight" and flying) then
			GuideTo(leg.to, leg.walkPoints)
			return
		end
		progress.index, progress.departed = progress.index + 1, false
	end
	Arrive()
end

---@return boolean
function ns.IsJourneyGuided()
	return guide ~= nil
end

function ns.JourneyStatus()
	return pendingWalks + pendingCosts > 0, settleRound, pendingWalks + pendingCosts
end

local function StartGuide()
	ClearOrphanWaypoint()
	local previous = C_Map.HasUserWaypoint() and C_Map.GetUserWaypoint()
	local saved = previous
		and UiMapPoint.CreateFromCoordinates(previous.uiMapID, previous.position.x, previous.position.y, previous.z)
	guide = {
		previousQuest = C_SuperTrack.GetSuperTrackedQuestID(),
		previousWaypoint = saved,
		expectedWaypoint = previous or nil,
		previousTrackedWaypoint = saved ~= nil and C_SuperTrack.IsSuperTrackingUserWaypoint(),
	}
	RememberTracking(guide)
	UpdateProgress()
end

function ns.ToggleJourneyGuide()
	if guide then
		StopGuide()
	elseif goal then
		StartGuide()
	end
	RefreshTracker()
end

function ns.ShowJourneyMap()
	local location = goal and ns.Locate(goal)
	OpenWorldMap(location and location.uiMap)
end

-- Shared by the tracker and the goal pin, including on a fullscreen map.
---@return string? title, SPFRow[]? rows, SPFPlan? plan, number? index, boolean? loading
function ns.JourneyInfo()
	if not goal then
		return nil
	end
	local title = goal.routeTitle or ("Journey to " .. ns.PlaceLabel(goal))
	local rows = {}
	local loading = search and search.initial or false
	if not result and loading then
		rows[1] = { key = "searching", text = "Finding the fastest way…", grey = true }
	elseif result then
		local _, spell = WaterWalking()
		for index = progress.index, #result.legs do
			local leg = result.legs[index]
			local text
			local teleport = leg.teleport
			if teleport then
				local name = teleport.item and C_Item.GetItemNameByID(teleport.item)
					or C_Spell.GetSpellName(teleport.spell)
					or UNKNOWN
				text = string.format("%d. " .. (teleport.item and USE_ITEM or CAST_SPELL), index, name)
			else
				text = string.format("%d. %s %s", index, ns.LegVerb(leg), ns.LegLabel(leg))
			end
			if leg.mode == "walk" and leg.to.undiscovered then
				text = text .. " (new flight path)"
			end
			if leg.walkError then
				text = text .. " (" .. (WALK_FAILURE[leg.walkError] or "walking search failed") .. ")"
			end
			if spell and leg.wet and leg.wet >= WATER_HINT then
				text = text .. " (cast " .. C_Spell.GetSpellName(spell) .. ")"
			end
			rows[#rows + 1] = {
				key = index,
				text = loading and text or text .. "   " .. ns.LegTime(leg),
				current = index == progress.index,
			}
		end
	else
		rows[1] = { key = "unreachable", text = costError and WALK_FAILURE[costError] or "No way there from here." }
	end
	return title, rows, result, progress.index, loading
end

-- Where here falls on a walk: the segment ending at points[index], how far along it (t), and the yards still to walk
-- from there, or nil when here is more than reach (ON_PATH by default) off the walk.
local function OnWalk(points, here, reach)
	if not here then
		return nil
	end
	local lengths, total = {}, 0
	for index = 2, #points do
		local a, b = points[index - 1], points[index]
		lengths[index] = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
		total = total + lengths[index]
	end
	local walked, best, found, along, after = 0, nil, nil, nil, nil
	for index = 2, #points do
		local a, b = points[index - 1], points[index]
		local dx, dy, length = b.x - a.x, b.y - a.y, lengths[index]
		local t = length > 0 and math.max(0, math.min(1, ((here.x - a.x) * dx + (here.y - a.y) * dy) / length ^ 2)) or 0
		local off = math.sqrt((a.x + t * dx - here.x) ^ 2 + (a.y + t * dy - here.y) ^ 2)
		if here.map == a.map and off <= (reach or ON_PATH) and (not best or off < best) then
			best, found, along, after = off, index, t, total - walked - t * length
		end
		walked = walked + length
	end
	return found, along, after, total
end

local function Refresh()
	local remaining
	if result then
		remaining = { now = result.now, arrive = result.arrive, legs = {} }
		for index = progress.index, #result.legs do
			remaining.legs[#remaining.legs + 1] = result.legs[index]
		end
		-- Draw the walk you are on from where you stand, not from where it was planned.
		local leg, here = remaining.legs[1], Here()
		if here then
			driver.drawAt, driver.drawX, driver.drawY, driver.drawMap = GetTime(), here.x, here.y, here.map
		end
		if leg and leg.mode == "walk" and here then
			local points = leg.walkPoints or ns.Planner.WalkPoints(leg.from, leg.to)
			-- A walk still being searched may be the one it replaces, which you have strayed from: join it where it is
			-- nearest.
			local found = OnWalk(points, here, not leg.measured and math.huge or nil)
			if found then
				local ahead = { here }
				for index = found, #points do
					ahead[#ahead + 1] = points[index]
				end
				remaining.legs[1] = setmetatable({ walkPoints = ahead }, { __index = leg })
			end
		end
	end
	ns.SetJourneyRoute(goal, remaining)
	RefreshTracker()
end

-- The rest of the chosen walk in its own running yards, so water keeps its search weight.
local function Remaining(leg, here)
	local found, _, after, total = OnWalk(leg.walkPoints, here)
	return found and total > 0 and (leg.walkCost or leg.yards) * after / total
end

local function Walks(here)
	local walks = {}
	for _, walk in ipairs(goalCosts) do
		walks[#walks + 1] = walk
	end
	if startAt and startAt.map == here.map then
		for _, walk in ipairs(startCosts) do
			walks[#walks + 1] = { from = here, to = walk.to, cost = walk.cost, estimated = walk.estimated }
		end
	end
	local leg = result and result.legs[progress.index]
	local rest = leg and result.waterMode == waterMode and leg.mode == "walk" and leg.measured and Remaining(leg, here)
	if rest then
		walks[#walks + 1] = { from = here, to = leg.to, cost = rest }
	end
	return walks
end

local function SamePlace(a, b)
	return a.map == b.map and a.x == b.x and a.y == b.y and a.z == b.z
end

-- The bind point moves, so its walks on to the fixed places cannot be baked like a class teleport's: each is searched
-- once per bind point and water mode, alongside the journey's own endpoint searches.
local landings = {}
---@param place SPFTeleportPlace
---@return {targets: SPFPlace[], costs?: (number|false)[], waiting?: fun()[]}?
local function Landing(place)
	if not (ns.Path and place.bind and ns.Path.HasData(place.map)) then
		return nil
	end
	local key = string.format("%d:%.17g:%.17g:%s", place.map, place.x, place.y, tostring(waterMode))
	local entry = landings[key]
	if not entry then
		local mass, targets = ns.Planner.Landmass(place, ns.Landmasses or {}), {}
		local places = ns.Planner.Places({
			docks = ns.Docks,
			taxiNodes = ns.TaxiNodes,
			portals = ns.Portals,
			faction = UnitFactionGroup("player"),
		})
		for _, target in ipairs(places) do
			if target.map == place.map and ns.Planner.Landmass(target, ns.Landmasses or {}) == mass then
				targets[#targets + 1] = target
			end
		end
		entry = { targets = targets, waiting = {} }
		landings[key] = entry
		ns.Path.FindMany(place.map, place, targets, function(costs)
			local waiting = entry.waiting or {}
			entry.costs, entry.waiting = costs, nil
			for _, callback in ipairs(waiting) do
				callback()
			end
		end, waterMode)
	end
	return entry
end

-- Whether a bind point's walks are still being searched; callback, when given, runs once each search ends. With
-- ready, only a teleport castable before `before` counts: one ready later cannot beat a route arriving then.
---@param teleports SPFTeleportPlace[]?
---@param callback? fun()
---@param ready? table<number, number>
---@param before? number
local function LandingPending(teleports, callback, ready, before)
	local pending = false
	for index, place in ipairs(teleports or {}) do
		local entry = Landing(place)
		if entry and entry.waiting and (not ready or (ready[index] and ready[index] < before)) then
			pending = true
			if callback then
				entry.waiting[#entry.waiting + 1] = callback
			end
		end
	end
	return pending
end

---@param teleports SPFTeleportPlace[]?
---@return SPFWalkCost[]
local function LandingWalks(teleports)
	local walks = {}
	for _, place in ipairs(teleports or {}) do
		local entry = Landing(place)
		local costs = entry and entry.costs
		if entry and costs then
			for i, target in ipairs(entry.targets) do
				walks[#walks + 1] = { from = place, to = target, cost = costs[i] }
			end
		end
	end
	return walks
end

local function WalkKey(from, to)
	return table.concat({ from.map, from.x, from.y, from.z or "", to.x, to.y, to.z or "" }, ":")
end

local function CacheWalk(key, entry)
	if not walkCache[key] then
		walkOrder[#walkOrder + 1] = key
		if #walkOrder > WALK_CACHE_LIMIT then
			walkCache[table.remove(walkOrder, 1)] = nil
		end
	end
	walkCache[key] = entry
end

local function FindWalk(planned, leg, key)
	local version, previous = pathVersion, leg.walkPoints
	leg.walkDrawn = previous ~= nil
	leg.walkPoints = previous or ns.Planner.WalkPoints(leg.from, leg.to)
	local function apply(points, cost)
		leg.walkError = not points and cost or nil
		leg.walkPoints = points or previous or {}
		if points then
			leg.measured, leg.walkDrawn, leg.wet = true, true, points.wet
			if planned.preview then
				leg.walkCost, leg.yards = cost, cost
			end
		end
	end
	if walkPending[key] then
		walkPending[key][#walkPending[key] + 1] = apply
		return
	end
	local waiting = { apply }
	walkPending[key] = waiting
	pendingWalks = pendingWalks + 1
	local job = ns.Path.Find(leg.from.map, leg.from, leg.to, function(points, cost, finished)
		pathJobs[finished] = nil
		if version ~= pathVersion then
			return
		end
		pendingWalks = pendingWalks - 1
		walkPending[key] = nil
		for _, callback in ipairs(waiting) do
			callback(points, cost)
		end
		CacheWalk(key, { points = points or previous, reason = not points and cost or nil, cost = points and cost })
		if ns.db.debug and (not points or math.abs(cost - leg.yards) > math.max(1, leg.yards * 0.1)) then
			ns.Print(string.format("walking cost mismatch: planned %.1f, found %s", leg.yards, tostring(cost)))
		end
		-- Geometry is private until the entire search can be committed together.
		FinishSearch()
	end, waterMode)
	pathJobs[job] = true
end

local function PrepareWalks(planned)
	if not planned or planned.prepared then
		return
	end
	planned.prepared = true
	for _, leg in ipairs(planned.legs) do
		if leg.mode == "walk" then
			local key = WalkKey(leg.from, leg.to)
			local entry = walkCache[key]
			leg.measured, leg.walkError, leg.walkCost = false, nil, leg.yards
			if entry then
				leg.walkPoints, leg.measured = entry.points or {}, entry.reason == nil
				leg.walkDrawn = entry.points ~= nil
				leg.wet, leg.walkError = entry.points and entry.points.wet, entry.reason
				if planned.preview and entry.cost then
					leg.walkCost, leg.yards = entry.cost, entry.cost
				end
			elseif ns.Path and leg.from.map == leg.to.map and ns.Path.HasData(leg.from.map) then
				-- A replacement may itself still be pending while drawing an older result; preserve that too.
				for _, previous in ipairs(result and result.legs or {}) do
					if previous.mode == "walk" and SamePlace(previous.to, leg.to) and previous.walkDrawn then
						leg.walkPoints = previous.walkPoints
						break
					end
				end
				FindWalk(planned, leg, key)
			elseif ns.Path then
				leg.walkPoints, leg.walkError = {}, "nodata"
			else
				leg.walkPoints = ns.Planner.WalkPoints(leg.from, leg.to)
			end
		end
	end
end

-- The same journey replanned from a few yards on: every leg goes the same way to the same place.
local function SameJourney(a, b)
	if not (a and b) or a.waterMode ~= b.waterMode or #a.legs ~= #b.legs - progress.index + 1 then
		return false
	end
	for index, leg in ipairs(a.legs) do
		local other = b.legs[index + progress.index - 1]
		if
			leg.mode ~= other.mode
			or leg.route ~= other.route
			or not SamePlace(leg.to, other.to)
			or (index > 1 and not SamePlace(leg.from, other.from))
		then
			return false
		end
	end
	-- A walk you have strayed from is searched again from where you are.
	local walk = b.legs[progress.index]
	if walk and walk.walkError then
		local here = Here()
		return here and SamePlace(walk.from, here)
	end
	return not (walk and walk.mode == "walk" and walk.measured) or OnWalk(walk.walkPoints, Here()) ~= nil
end

-- Only the timings move, so the drawn route, Guide and any walk still being searched carry on undisturbed.
local function Retime(planned)
	result.now, result.arrive = planned.now, planned.arrive
	for index, leg in ipairs(planned.legs) do
		local kept = result.legs[index + progress.index - 1]
		kept.depart, kept.arrive, kept.wait, kept.estimated = leg.depart, leg.arrive, leg.wait, leg.estimated
		kept.aboard, kept.yards, kept.ready = leg.aboard, leg.yards, leg.ready
	end
end

-- Compare against this route's own measured legs, at the same departure time as the challenger.
-- Reusing the old optimistic arrival would make a grace-period route unfairly hard to replace.
local function EstimateKept(now)
	if not result then
		return nil
	end
	local here, anchors = Here(), ns.FreshAnchors()
	local estimate = { now = now, arrive = now, legs = {} }
	for index = progress.index, #result.legs do
		local leg = result.legs[index]
		if index == progress.index and leg.route and not progress.departed and leg.depart < now then
			return nil
		end
		local duration, wait = leg.arrive - leg.depart, leg.wait or 0
		local yards = leg.yards or duration / 1000 * math.max(lastRunSpeed, 7)
		if leg.walkError then
			return nil
		end
		if leg.mode == "walk" then
			local entry = walkCache[WalkKey(leg.from, leg.to)]
			if entry and entry.reason then
				return nil
			end
			local basis = entry and entry.cost or leg.walkCost or yards
			if index == progress.index and leg.measured then
				local rest = Remaining(leg, here)
				if not rest then
					return nil
				end
				yards = rest * basis / (leg.walkCost or leg.yards)
			else
				yards = basis
			end
			duration, wait = yards / math.max(lastRunSpeed, 7) * 1000, 0
		elseif leg.route and not leg.aboard then
			local route, anchor = ns.Routes[leg.route], anchors[leg.route]
			if anchor and leg.boarding then
				local _, _, departIn =
					ns.Model.Visit(route, leg.boarding, (estimate.arrive - anchor.epoch) % route.period)
				wait = departIn
			else
				wait = route.period / 2
			end
		elseif index == progress.index and leg.aboard then
			duration, wait = math.max(0, leg.arrive - now), 0
		elseif leg.ready then
			wait = math.max(0, leg.ready - estimate.arrive)
		end
		local depart = estimate.arrive + wait
		estimate.arrive = depart + duration
		estimate.legs[#estimate.legs + 1] = {
			depart = depart,
			arrive = estimate.arrive,
			wait = wait,
			yards = yards,
			estimated = leg.estimated,
			aboard = leg.aboard,
		}
	end
	return estimate
end

local function Commit(planned)
	result = planned
	progress.index, progress.departed = 1, false
	if guide then
		guide.target = nil
	end
	if not result then
		StopGuide()
	end
	UpdateProgress()
	Refresh()
end

FinishSearch = function()
	if not search or pendingCosts > 0 or pendingWalks > 0 then
		return
	end
	local planned, forced, refine = search.candidate, search.forced, search.initial or search.refine
	local estimate = EstimateKept(planned and planned.now or ns.NowMs())
	local same = SameJourney(planned, result)
	local gain = estimate and planned and estimate.arrive - planned.arrive
	local better = estimate
		and planned
		and gain
		and gain >= SWITCH_GAIN
		and gain >= (estimate.arrive - planned.now) * SWITCH_SHARE
	local valid = true
	for _, leg in ipairs(planned and planned.legs or {}) do
		if leg.walkError then
			valid = false
		end
	end
	local keep = result and planned and estimate and (not valid or (not forced and (same or not better)))
	if not keep and planned and not planned.prepared then
		PrepareWalks(planned)
		if pendingWalks > 0 then
			return
		end
	end
	search = nil
	-- Retain exact endpoint vectors and their lower bounds, never suspended search stacks.
	for _, batch in pairs({ start = startBatch, goal = goalBatch }) do
		if batch.job and batch.path.ReleaseMany then
			batch.path.ReleaseMany(batch.job)
		end
	end
	if keep then
		Retime(same and planned or estimate)
		local changedWater = result.waterMode ~= waterMode
		result.waterMode = waterMode
		if refine or changedWater then
			for _, leg in ipairs(result.legs) do
				if leg.mode == "walk" then
					local entry = walkCache[WalkKey(leg.from, leg.to)]
					if entry then
						if refine then
							leg.walkPoints = entry.points or {}
						end
						leg.walkError, leg.wet = entry.reason, entry.points and entry.points.wet
						leg.measured, leg.walkCost = entry.reason == nil, entry.cost or leg.walkCost
					end
				end
			end
			result.prepared = true
			if refine and guide then
				guide.target = nil
			end
		end
		UpdateProgress()
		if refine then
			Refresh()
		else
			RefreshTracker()
		end
	else
		Commit(planned)
	end
end

local function Render(planned, forced)
	search = search or { started = GetTime(), initial = not result }
	search.candidate, search.forced = planned, forced
	search.refine = result and not result.prepared
	-- Measure the grace route's own legs only after the proof finishes, so presentation never
	-- competes with the bounded search for its frame budget.
	if search.grace then
		PrepareWalks(search.grace)
	end
	if result and result.waterMode ~= waterMode then
		local kept = { legs = {}, preview = true }
		for index = progress.index, #result.legs do
			local copy = {}
			for key, value in pairs(result.legs[index]) do
				copy[key] = value
			end
			kept.legs[#kept.legs + 1] = copy
		end
		PrepareWalks(kept)
	end
	local estimate = not search.initial and not forced and EstimateKept(planned and planned.now or ns.NowMs())
	if estimate and planned and pendingWalks == 0 and not search.refine then
		local gain = estimate.arrive - planned.arrive
		if gain < SWITCH_GAIN or gain < (estimate.arrive - planned.now) * SWITCH_SHARE then
			FinishSearch()
			return
		end
	end
	-- Reusing the followed walk needs no new geometry and preserves Guide's passed bends.
	if search.refine or not SameJourney(planned, result) then
		PrepareWalks(planned)
	end
	FinishSearch()
end

local function Plan(preview)
	local here = Here()
	if not (here and goal) then
		return nil
	end
	local _, runSpeed = GetUnitSpeed("player")
	-- In combat the client returns unit speed as a secret value; keep the last one it let us read.
	if canaccessvalue(runSpeed) then
		lastRunSpeed = runSpeed
	end
	local now = ns.NowMs()
	-- Taxi paths cannot be interrupted; retain their chosen destination until landing.
	if result and UnitOnTaxi("player") then
		result.now = now
		return result
	end
	local anchors = ns.FreshAnchors()
	local teleports, ready = ns.UsableTeleports(now)
	local walks = preview and {} or Walks(here)
	for _, walk in ipairs(LandingWalks(teleports)) do
		walks[#walks + 1] = walk
	end
	local ride, routeID = nil, ns.CurrentRide()
	if routeID and anchors[routeID] then
		local route = ns.Routes[routeID]
		local phase = (now - anchors[routeID].epoch) % route.period
		for _, stop in ipairs(route.stops) do
			-- The observer retains a ride for 30 seconds after disembarking, enough to run 210 yards away.
			if ns.Model.Visit(route, stop, phase) and Near(ns.Docks[stop.dock], 250) then
				routeID = nil
				break
			end
		end
	end
	if routeID then
		local dock, arriveIn = ns.NextStop(routeID)
		if dock then
			ride = { route = routeID, dock = dock, arrive = now + arriveIn }
		end
	end
	local planned = ns.Planner.Plan({
		cache = plannerCache,
		from = here,
		to = goal,
		now = now,
		ride = ride,
		walkSpeed = math.max(lastRunSpeed, 7),
		faction = UnitFactionGroup("player"),
		taxiKnown = ns.KnownTaxiNodes(),
		anchors = anchors,
		docks = ns.Docks,
		routes = ns.Routes,
		taxiNodes = ns.TaxiNodes,
		taxiPaths = ns.TaxiPaths,
		portals = ns.Portals,
		teleports = teleports,
		teleportReady = ready,
		landmasses = ns.Landmasses,
		walks = walks,
		baked = ns.Walks,
		waterWalking = waterMode,
	})
	if planned then
		planned.now, planned.preview, planned.waterMode = now, preview, waterMode
	end
	return planned
end

-- Reuse only the last two endpoint searches, with starts confirmed by the pathfinder as the same snapped node.
-- sift: long-function - one search owns the callbacks' shared revision, preview and probe budget across resumes
local function RefreshCosts(includeGoal, forced)
	local here = Here()
	if not (here and goal) then
		return
	end
	if not ns.Path then
		Render(Plan(), forced)
		return
	end
	CancelPaths()
	search = { started = GetTime(), initial = not result, forced = forced }
	local version, faction = pathVersion, UnitFactionGroup("player")
	local teleports = ns.UsableTeleports(ns.NowMs())
	local places = ns.Planner.Places({
		docks = ns.Docks,
		taxiNodes = ns.TaxiNodes,
		portals = ns.Portals,
		teleports = teleports,
		faction = faction,
	})
	local function targets(point, withGoal)
		local list = {}
		local mass = ns.Planner.Landmass(point, ns.Landmasses or {})
		for _, place in ipairs(places) do
			if place.map == point.map and ns.Planner.Landmass(place, ns.Landmasses or {}) == mass then
				list[#list + 1] = place
			end
		end
		if withGoal and goal.map == point.map and ns.Planner.Landmass(goal, ns.Landmasses or {}) == mass then
			list[#list + 1] = goal
		end
		return list
	end
	local function reuse(batch, point, reverse)
		if
			not batch
			or batch.path ~= ns.Path
			or batch.water ~= waterMode
			or batch.faction ~= faction
			or batch.teleports ~= teleports
		then
			return false
		end
		if not reverse and not SamePlace(batch.goal, goal) then
			return false
		end
		return ns.Path.Resume
			and (
				SamePlace(batch.point, point)
				or (not reverse and ns.Path.ReuseMany and ns.Path.ReuseMany(batch.job, point))
			)
	end
	local function create(previous, point, reverse)
		if reuse(previous, point, reverse) then
			return previous
		end
		if previous and previous.job then
			previous.path.Cancel(previous.job)
		end
		return {
			point = point,
			goal = goal,
			targets = targets(point, not reverse),
			reverse = reverse,
			path = ns.Path,
			water = waterMode,
			faction = faction,
			teleports = teleports,
			costs = {},
		}
	end
	startBatch = create(startBatch, here, false)
	if includeGoal then
		goalBatch = create(goalBatch, goal, true)
	end
	startAt, refreshedAt = here, GetTime()
	pendingCosts, costError = 2, nil
	if search.initial then
		Refresh()
	end
	local slices, lastRevision, probeCPU = 0, -1, 0
	local function fixedPlace(batch)
		if batch.fixedChecked or not (batch.job and batch.job.valid and ns.Path.ReuseMany) then
			return
		end
		batch.fixedChecked = true
		for _, place in ipairs(places) do
			if
				place.map == batch.point.map
				and math.abs(place.x - batch.point.x) < 0.00001
				and math.abs(place.y - batch.point.y) < 0.00001
				and ns.Path.ReuseMany(batch.job, place)
			then
				batch.fixedKey = place.kind .. place.id
				return
			end
		end
	end
	local function bakedBound(batch, target)
		local first = batch.fixedKey
		local last = target.kind and target.kind .. target.id or target == goal and goalBatch.fixedKey
		local baked = first and last and ns.Walks and ns.Walks[batch.point.map]
		if not baked then
			return 0
		end
		if first == last then
			return 0
		end
		if batch.reverse then
			first, last = last, first
		end
		local pair = baked[first < last and first .. " " .. last or last .. " " .. first]
		local cost = pair and pair[(waterMode and 2 or 1) + (first > last and pair[3] ~= nil and 2 or 0)]
		-- Baked costs round to whole yards. They strengthen the bound but never stand in for exact endpoint costs.
		return cost and math.max(0, cost - 0.5) or 0
	end
	local function walks(batch)
		local list = {}
		if not ns.Path.HasData(batch.point.map) then
			return list
		end
		local radius = batch.job and batch.job.radius or 0
		for i, target in ipairs(batch.reason ~= "nodata" and batch.targets or {}) do
			local cost = batch.probes and batch.probes[i]
			if cost == nil then
				cost = batch.costs[i]
			end
			local estimated = cost == nil
			if estimated then
				local lower = ns.Path.LowerBound and ns.Path.LowerBound(batch.point.map, batch.point, target) or 0
				cost = math.max(lower, radius, bakedBound(batch, target))
			end
			list[#list + 1] = {
				from = batch.reverse and target or batch.point,
				to = batch.reverse and batch.point or target,
				cost = cost,
				estimated = estimated,
			}
		end
		return list
	end
	local function active(batch, needed)
		if ns.Path.Pause then
			if needed then
				ns.Path.Resume(batch.job)
			else
				ns.Path.Pause(batch.job)
			end
		end
	end
	local preview
	if not result and ns.Path.LowerBound then
		startCosts, goalCosts = walks(startBatch), walks(goalBatch)
		preview = Plan()
		if preview then
			preview.preview, search.candidate = true, preview
		end
	end
	local consider
	-- sift: long-function - bounded search callback; splitting adds calls and upvalues on every frontier update
	consider = function(final)
		if version ~= pathVersion or not goal then
			return
		end
		if not ns.JourneyPosition() then
			costsWaiting = true
			return
		end
		if
			(not startBatch.done and not (startBatch.job and startBatch.job.valid))
			or (not goalBatch.done and not (goalBatch.job and goalBatch.job.valid))
		then
			return
		end
		local hadFixed = startBatch.fixedKey or goalBatch.fixedKey
		fixedPlace(startBatch)
		fixedPlace(goalBatch)
		if not hadFixed and (startBatch.fixedKey or goalBatch.fixedKey) then
			preview = nil
		end
		slices = slices + 1
		local revision = (startBatch.job and startBatch.job.revision or 0)
			+ (goalBatch.job and goalBatch.job.revision or 0)
		if not final and revision == lastRevision and slices < 16 then
			return
		end
		slices, lastRevision = 0, revision
		startCosts, goalCosts = walks(startBatch), walks(goalBatch)
		goalError = goalBatch.reason
		costError = startBatch.reason == "error" and "error" or goalError == "error" and "error" or nil
		-- An invalid goal also rules out the direct start -> goal edge without searching toward it.
		if goalError and goalError ~= "nodata" then
			startCosts[#startCosts + 1] = { from = here, to = goal, cost = false }
		end
		-- Reuse the bounded preview once for probes; commit only after planning with current exact costs.
		local previewed = preview and not startBatch.reason and not goalBatch.reason
		local planned = previewed and preview or Plan()
		preview = nil
		-- Short A* cost probes let easy routes prove themselves before expanding a wide frontier. Bound
		-- their total work, then let shared Dijkstras settle harder alternatives. Finish an active probe:
		-- abandoning it near completion would make the batch repeat its work.
		if ns.Path.FindCost and probeCPU < PROBE_BUDGET then
			local probes = {}
			for _, leg in ipairs(planned and planned.pendingWalks or {}) do
				local batch = leg.from.kind == "start" and startBatch or goalBatch
				local target = batch.reverse and leg.from or leg.to
				for i, point in ipairs(batch.targets) do
					if
						SamePlace(point, target)
						and batch.costs[i] == nil
						and (not batch.probes or batch.probes[i] == nil)
					then
						probes[#probes + 1] = { batch = batch, index = i, leg = leg }
						break
					end
				end
			end
			if #probes > 0 then
				planned.preview, search.candidate = true, planned
				active(startBatch, false)
				active(goalBatch, false)
				local left = #probes
				for _, probe in ipairs(probes) do
					local leg, batch = probe.leg, probe.batch
					local job = ns.Path.FindCost(leg.from.map, leg.from, leg.to, function(cost, reason, finished)
						pathJobs[finished] = nil
						if version ~= pathVersion then
							return
						end
						if cost or reason == "unreachable" or reason == "offmesh" or reason == "outside" then
							batch.probes = batch.probes or {}
							batch.probes[probe.index] = cost or false
						end
						probeCPU = probeCPU + finished.cpu
						left = left - 1
						if left == 0 then
							consider(true)
						end
					end, waterMode)
					pathJobs[job] = true
				end
				return
			end
		end
		if previewed then
			planned = Plan()
		end
		local needStart = planned and planned.needsStart and ns.Path.HasData(here.map)
		local needGoal = planned and planned.needsGoal and ns.Path.HasData(goal.map)
		-- Missing-map estimates remain the existing terminal fallback, never an endless search.
		needStart = needStart and not startBatch.done
		needGoal = needGoal and not goalBatch.done
		active(startBatch, needStart)
		active(goalBatch, needGoal)
		-- A bind point's walks still being searched, for a teleport that could be faster: settle when they end.
		local landing = not needStart
			and not needGoal
			and LandingPending(
				teleports,
				nil,
				select(2, ns.UsableTeleports(ns.NowMs())),
				planned and planned.arrive or math.huge
			)
		if not needStart and not needGoal and not landing then
			pendingCosts, settleRound = 0, settleRound + 1
			Render(planned, forced)
		else
			if planned then
				planned.preview = true
			end
			search.candidate = planned
		end
	end
	local function attach(batch)
		local function update(costs, reason, job)
			if version ~= pathVersion or not goal then
				return
			end
			batch.costs, batch.reason, batch.job = costs or {}, reason, job
			if job.done or not ns.Path.Pause then
				batch.done = true
				for i = 1, #batch.targets do
					if batch.costs[i] == nil then
						batch.costs[i] = false
					end
				end
			end
			consider(batch.done)
		end
		if batch.job then
			batch.job.callback, batch.job.progress = update, update
		else
			batch.job =
				ns.Path.FindMany(batch.point.map, batch.point, batch.targets, update, waterMode, batch.reverse, update)
		end
	end
	attach(startBatch)
	attach(goalBatch)
	LandingPending(teleports, function()
		consider(true)
	end)
	-- Existing settled costs can prove a repeated journey without advancing either frontier.
	if ns.Path.Pause and (startBatch.job.valid or startBatch.done) and (goalBatch.job.valid or goalBatch.done) then
		consider(true)
	end
end
-- The timed replan in Update plans in the frame; Itinerary.lua keeps its own planning and drawing off that frame. A
-- frame's GetTime is fixed, and the margin covers the frame the replan will take whichever handler runs first.
---@return boolean
function ns.JourneyReplanning()
	return driver ~= nil and (driver.elapsed >= REPLAN_EVERY - REPLAN_MARGIN or driver.replannedAt == GetTime())
end

---@param self SPFJourneyDriver
---@param elapsed number
-- sift: long-function - one throttled frame step; keeping its gates together preserves the search/draw cadence
local function Update(self, elapsed)
	if InCombatLockdown() then
		return
	end
	if not ns.db.journey then
		ns.ClearJourney()
		return
	end
	self.elapsed = self.elapsed + elapsed
	self.progressElapsed = self.progressElapsed + elapsed
	if self.progressElapsed < 0.1 then
		return
	end
	self.progressElapsed = 0
	local x, y, _, map = ns.JourneyPosition()
	if not x then
		return
	end
	if not startAt or costsWaiting then
		costsWaiting = nil
		-- Search callbacks may finish while position is unavailable; resume from readable endpoints.
		if ns.Path then
			RefreshCosts(true, true)
		end
	end
	if
		search
		and search.initial
		and not result
		and search.candidate
		and #search.candidate.legs > 0
		and GetTime() - search.started >= SEARCH_GRACE
	then
		local candidate = search.candidate
		search.grace = candidate
		-- The visible snapshot never shares mutable leg records with ongoing geometry work.
		local snapshot = { now = candidate.now, arrive = candidate.arrive, waterMode = candidate.waterMode, legs = {} }
		for _, leg in ipairs(candidate.legs) do
			local copy = {}
			for key, value in pairs(leg) do
				copy[key] = value
			end
			if leg.mode == "walk" and not copy.walkPoints then
				local entry = walkCache[WalkKey(leg.from, leg.to)]
				copy.walkPoints = entry and entry.points or ns.Planner.WalkPoints(leg.from, leg.to)
				copy.measured = entry and entry.reason == nil
			end
			snapshot.legs[#snapshot.legs + 1] = copy
		end
		Commit(snapshot)
	end
	local index = progress.index
	UpdateProgress()
	if nextPoint then
		ns.StartJourney(nextPoint)
		return
	end
	if not goal then
		return
	end
	local riding, flying = ns.CurrentRide(), UnitOnTaxi("player")
	local changedRide = riding ~= self.riding or flying ~= self.flying
	self.riding, self.flying = riding, flying
	if self.elapsed >= REPLAN_EVERY or changedRide then
		self.elapsed, self.replannedAt = 0, GetTime()
		local mode = WaterWalking()
		if mode ~= waterMode then
			waterMode, walkCache, walkOrder, startCosts, goalCosts = mode, {}, {}, {}, {}
			RefreshCosts(true, false)
		elseif goalBatch and goalBatch.teleports ~= ns.UsableTeleports(ns.NowMs()) then
			-- A new bind point or teleport: measure the walks on from where it lands.
			RefreshCosts(true, false)
		elseif pendingCosts == 0 and pendingWalks == 0 then
			local here = Here()
			local leg = result and result.legs[progress.index]
			local off = here and leg and leg.mode == "walk" and leg.measured and not OnWalk(leg.walkPoints, here)
			local moved = here and startAt and not SamePlace(startAt, here)
			local retry = here
				and startAt
				and moved
				and (not result or (leg and leg.walkError) or here.map ~= startAt.map)
			if ns.Path and not flying and not riding and (off or retry or GetTime() - refreshedAt >= REFRESH_EVERY) then
				RefreshCosts(false, off or retry)
			else
				local planned = Plan()
				if
					planned
					and ns.Path
					and (
						(planned.needsStart and here and ns.Path.HasData(here.map))
						or (planned.needsGoal and ns.Path.HasData(goal.map))
					)
				then
					-- A timed replan can expose an alternative left bounded by the previous proof.
					-- Resume its costs before letting it replace the route with settled geometry.
					RefreshCosts(false, changedRide)
				else
					Render(planned, changedRide)
				end
			end
		end
	elseif index ~= progress.index then
		Refresh()
	end
	-- Trimming is presentation work, independent of the five-second planning/search cadence.
	if
		goal
		and result
		and GetTime() - (self.drawAt or 0) >= DRAW_EVERY
		and (x ~= self.drawX or y ~= self.drawY or map ~= self.drawMap)
	then
		Refresh()
	end
end

---@param point SPFPoint
---@return boolean
function ns.StartJourney(point)
	local mode = WaterWalking()
	local repeated = goal and SamePlace(goal, point) and mode == waterMode
	local previous = repeated and result
	local index, departed = progress.index, progress.departed
	CancelPaths()
	costsWaiting = nil
	settleRound, costError, goalError = 0, nil, nil
	walkCache, walkOrder, startCosts, goalCosts, startAt =
		repeated and walkCache or {}, repeated and walkOrder or {}, {}, {}, nil
	if guide then
		StopGuide()
	end
	goal, nextPoint = point, nil
	if ns.JourneyChanged then
		ns.JourneyChanged(point)
	end
	result, search = previous, nil
	progress.index, progress.departed = previous and index or 1, previous and departed or false
	driver.elapsed, driver.progressElapsed = 0, 0
	if not InCombatLockdown() then
		driver:Show()
	end
	ns.WakeTravel()
	waterMode = mode
	if ns.Path then
		RefreshCosts(true, false)
		if search and not search.candidate and not ns.Path.LowerBound then
			search.candidate = Plan(true)
		end
	else
		Render(Plan())
	end
	-- Every journey starts guided; the tracker header turns it off.
	if goal then
		StartGuide()
		RefreshTracker()
	end
	return true
end

ns.Init(function()
	local journeyDriver = CreateFrame("Frame", "ShortestPathForeverJourneyDriver", UIParent)
	---@cast journeyDriver SPFJourneyDriver
	driver = journeyDriver
	driver:SetScript("OnUpdate", Update)
	driver:RegisterEvent("PLAYER_REGEN_DISABLED")
	driver:RegisterEvent("PLAYER_REGEN_ENABLED")
	driver:RegisterEvent("QUEST_TURNED_IN")
	driver:RegisterEvent("QUEST_REMOVED")
	driver:RegisterEvent("SUPER_TRACKING_CHANGED")
	driver:RegisterEvent("USER_WAYPOINT_UPDATED")
	driver:RegisterEvent("PLAYER_LOGIN")
	driver:RegisterEvent("PLAYER_ENTERING_WORLD")
	driver:SetScript("OnEvent", function(self, event, questID)
		if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
			ClearOrphanWaypoint()
		elseif event == "PLAYER_REGEN_DISABLED" then
			self:Hide()
		elseif event == "PLAYER_REGEN_ENABLED" and goal then
			self:Show()
		end
		if (event == "QUEST_TURNED_IN" or event == "QUEST_REMOVED") and guide and guide.previousQuest == questID then
			guide.previousQuest = nil
		end
		if (event == "QUEST_TURNED_IN" or event == "QUEST_REMOVED") and goal and goal.questID == questID then
			ns.ClearJourney()
		elseif
			guide
			and not guide.writing
			and (event == "SUPER_TRACKING_CHANGED" or event == "USER_WAYPOINT_UPDATED")
		then
			if not OwnsWaypoint() then
				RefreshTracker()
			elseif event == "SUPER_TRACKING_CHANGED" and not SameTracking(guide) then
				YieldGuide()
			end
		end
	end)
	driver:Hide()
	for provider in pairs(WorldMapFrame.dataProviders) do
		if provider.RefreshAllData == WaypointLocationDataProviderMixin.RefreshAllData then
			waypointProviders[#waypointProviders + 1] = provider
			hooksecurefunc(provider, "RefreshAllData", HideGuideWaypointPin)
		end
	end
end)
