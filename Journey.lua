local _, ns = ...

-- Shift-click the world map: the fastest way there from here, by foot, flight, boat, zeppelin, tram and portal,
-- with the boats' live waits. Endpoint lower bounds prove the winning route before committing; chosen walks
-- then get geometry without replanning. The tracker owns the list; closing the map leaves the journey running.
local REPLAN_EVERY, REFRESH_EVERY = 5, 60
local PROBE_BUDGET = 60 -- ms before switching from candidate costs to shared endpoint searches
local SCHEDULED = { boat = true, zeppelin = true, lift = true, tram = true }
local VERB = {
	walk = "Walk to",
	flight = "Fly to",
	boat = "Boat to",
	zeppelin = "Zeppelin to",
	lift = "Lift to",
	tram = "Tram to",
	portal = "Portal to",
	passage = "Go through to",
}

local goal, guide, result
local progress = { index = 1 }
local driver
local ARRIVAL = 15
-- A lift's landings share a spot on the map; height tells the top from the bottom.
local ARRIVAL_HEIGHT = 30
local lastRunSpeed = 7
local pathJobs, walkCache, pathVersion = {}, {}, 0
local pendingWalks, pendingCosts, settleRound = 0, 0, 0
local startBatch, goalBatch, startAt, refreshedAt
local startCosts, goalCosts = {}, {}
refreshedAt = 0
local costError, goalError
-- Walking along a measured path from where you stood, how far off it you may stray and still be on it.
local ON_PATH = 15
-- Timed replans replace the followed route only for a worthwhile gain; endpoint costs stay unchanged between
-- the infrequent batches, except for Remaining() along the walk you are following.
local SWITCH_GAIN, SWITCH_SHARE = 20000, 0.1
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
	pathJobs, pendingWalks, pendingCosts = {}, 0, 0
end

local function NodeLabel(node, mode)
	if node.kind == "start" then
		return "your position"
	elseif node.kind == "dock" then
		return (mode == "boat" or mode == "zeppelin") and ns.DockLabel(node.id) or ns.DockTitle(node.id)
	elseif node.kind == "taxi" then
		return ns.TaxiNodes[node.id].name
	elseif node.label then
		return node.label
	end
	local location = ns.Locate(node)
	return location and location.zone or UNKNOWN
end

-- Whether walks may cross water, and the spell to cast first when none is up.
local function WaterWalking()
	for _, id in ipairs(WATER_AURAS) do
		if C_UnitAuras.GetPlayerAuraBySpellID(id) then
			return true
		end
	end
	for _, id in ipairs(WATER_SPELLS) do
		if IsPlayerSpell(id) then
			return true, id
		end
	end
	return false
end

local function LegTime(leg)
	local text = ns.FormatCountdown(leg.arrive - leg.depart)
	if leg.wait and leg.wait > 0 then
		text = "wait " .. ns.FormatCountdown(leg.wait) .. " · " .. text
	end
	return text
end

local function Here()
	local x, y, z, map = UnitPosition("player")
	return x and { map = map, x = x, y = y, z = z }
end

local function Near(node, reach)
	local x, y, z, map = UnitPosition("player")
	return x
		and map == node.map
		and (x - node.x) ^ 2 + (y - node.y) ^ 2 <= (reach or ARRIVAL) ^ 2
		and not (z and node.z and math.abs(z - node.z) > ARRIVAL_HEIGHT)
end

local function SameWaypoint(a, b)
	if a == b then
		return true
	end
	if not (a and b and a.uiMapID == b.uiMapID) then
		return false
	end
	-- C_Map.GetUserWaypoint's position is a plain { x, y } table, not a Vector2D (WaypointLocationDataProvider.lua:183).
	return math.abs(a.position.x - b.position.x) < 0.000001 and math.abs(a.position.y - b.position.y) < 0.000001
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
	if
		not previous
		or not previous.hasDriven
		or not SameWaypoint(C_Map.GetUserWaypoint(), previous.expectedWaypoint)
	then
		return
	end
	local ownsTracking = not previous.yielded and SameTracking(previous)
	if previous.previousWaypoint then
		C_Map.SetUserWaypoint(previous.previousWaypoint)
	elseif previous.waypoint then
		C_Map.ClearUserWaypoint()
	end
	if ownsTracking then
		C_SuperTrack.SetSuperTrackedUserWaypoint(previous.previousTrackedWaypoint)
		if not previous.previousTrackedWaypoint then
			C_SuperTrack.SetSuperTrackedQuestID(previous.previousQuest or 0)
		end
	end
end

local function OwnsWaypoint()
	if not SameWaypoint(C_Map.GetUserWaypoint(), guide.expectedWaypoint) then
		-- A manual replacement or removal ends guidance; never reclaim the player's waypoint.
		StopGuide()
		return false
	end
	return true
end

local function GuideWaypoint(point)
	if not guide then
		return false
	end
	if guide.yielded then
		return false
	end
	local uiMap = C_Map.GetBestMapForUnit("player")
	local bend = guide.bend
	if not bend or point.map ~= bend.map or point.x ~= bend.x or point.y ~= bend.y or uiMap ~= guide.uiMap then
		guide.bend, guide.uiMap = { map = point.map, x = point.x, y = point.y }, uiMap
		local waypoint
		if uiMap and C_Map.CanSetUserWaypointOnMap(uiMap) then
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
		-- The native map pin marks the next bend; our destination pin still marks the final goal.
		if waypoint and C_Map.SetUserWaypoint(waypoint) then
			guide.waypoint = C_Map.GetUserWaypoint()
			guide.expectedWaypoint = guide.waypoint
			guide.hasDriven = true
			C_SuperTrack.SetSuperTrackedUserWaypoint(true)
		elseif guide.waypoint then
			-- Never leave a stale native marker pointing at the preceding bend when projection fails.
			C_Map.ClearUserWaypoint()
			C_SuperTrack.SetSuperTrackedUserWaypoint(false)
			guide.waypoint, guide.expectedWaypoint = nil, nil
		end
		-- Deferred events from our own writes must also agree with the expected tracking state.
		RememberTracking(guide)
		guide.writing = nil
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

function ns.ClearJourney()
	CancelPaths()
	settleRound, costError, goalError = 0, nil, nil
	walkCache, startCosts, goalCosts, startAt = {}, {}, {}, nil
	StopGuide()
	goal, result = nil, nil
	progress.index, progress.departed = 1, false
	driver:Hide()
	ns.SetJourneyRoute(nil)
	RefreshTracker()
end

local function UpdateProgress()
	if not (goal and result) then
		return
	end
	if Near(goal) then
		ns.ClearJourney()
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
		local aboard = leg.aboard or (leg.route and riding == leg.route) or (leg.mode == "flight" and flying)
		if leg.mode ~= "walk" and not progress.departed then
			if aboard or Near(leg.from) then
				progress.departed = true
			else
				GuideTo(leg.from)
				return
			end
		end
		if not Near(leg.to) or (leg.mode == "flight" and flying) then
			GuideTo(leg.to, leg.walkPoints)
			return
		end
		progress.index, progress.departed = progress.index + 1, false
	end
	ns.ClearJourney()
end

-- Guide's waypoint only steers the native marker; our own pins already draw the route and destination.
local function HideGuideWaypointPin(provider)
	if provider.pin and guide and (guide.writing or SameWaypoint(C_Map.GetUserWaypoint(), guide.expectedWaypoint)) then
		provider.pin:Hide()
	end
end

function ns.IsJourneyGuided()
	return guide ~= nil
end

function ns.JourneyStatus()
	return pendingWalks + pendingCosts > 0, settleRound, pendingWalks + pendingCosts
end

local function StartGuide()
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
	elseif result then
		StartGuide()
	end
	RefreshTracker()
end

function ns.ShowJourneyMap()
	local location = goal and ns.Locate(goal)
	OpenWorldMap(location and location.uiMap)
end

-- Shared by the tracker and the goal pin, including on a fullscreen map.
function ns.JourneyInfo()
	if not goal then
		return nil
	end
	local title = "Journey to " .. NodeLabel(goal)
	local rows = {}
	if result then
		if ns.JourneyStatus() then
			title = title .. " · finding the fastest way" .. string.rep(".", math.floor(GetTime()) % 3 + 1)
		else
			title = title .. " · " .. ns.FormatCountdown(math.max(0, result.arrive - ns.NowMs()))
		end
		local _, spell = WaterWalking()
		for index = progress.index, #result.legs do
			local leg = result.legs[index]
			local text = string.format("%d. %s %s", index, VERB[leg.mode], NodeLabel(leg.to, leg.mode))
			if leg.mode == "walk" and leg.to.undiscovered then
				text = text .. " (new flight path)"
			end
			if leg.estimated and SCHEDULED[leg.mode] then
				text = text .. " (no sighting yet)"
			end
			if leg.walkError then
				text = text .. " (" .. (WALK_FAILURE[leg.walkError] or "walking search failed") .. ")"
			elseif leg.mode == "walk" and ns.Path and not leg.measured then
				text = text .. " (finding walking path)"
			end
			if spell and leg.wet and leg.wet >= WATER_HINT then
				text = text .. " (cast " .. C_Spell.GetSpellName(spell) .. ")"
			end
			rows[#rows + 1] = { key = index, text = text .. "   " .. LegTime(leg), current = index == progress.index }
		end
	else
		rows[1] = { key = "unreachable", text = costError and WALK_FAILURE[costError] or "No way there from here." }
	end
	return title, rows, result, progress.index
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
		local z = a.z and b.z and a.z + t * (b.z - a.z)
		local level = not (z and here.z and math.abs(z - here.z) > ARRIVAL_HEIGHT)
		if here.map == a.map and off <= (reach or ON_PATH) and level and (not best or off < best) then
			best, found, along, after = off, index, t, total - walked - t * length
		end
		walked = walked + length
	end
	return found, along, after, total
end

local function Refresh()
	local remaining
	if result then
		remaining = { now = result.now, arrive = result.arrive, legs = {}, settling = ns.JourneyStatus() }
		for index = progress.index, #result.legs do
			remaining.legs[#remaining.legs + 1] = result.legs[index]
		end
		-- Draw the walk you are on from where you stand, not from where it was planned.
		local leg, here = remaining.legs[1], Here()
		if leg and leg.mode == "walk" and leg.walkPoints and here then
			-- A walk still being searched may be the one it replaces, which you have strayed from: join it where it is
			-- nearest.
			local found = OnWalk(leg.walkPoints, here, not leg.measured and math.huge or nil)
			if found then
				local ahead = { here }
				for index = found, #leg.walkPoints do
					ahead[#ahead + 1] = leg.walkPoints[index]
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
	local rest = leg
		and not result.preview
		and result.waterMode == waterMode
		and leg.mode == "walk"
		and leg.measured
		and Remaining(leg, here)
	if rest then
		walks[#walks + 1] = { from = here, to = leg.to, cost = rest }
	end
	return walks
end

local function SamePlace(a, b)
	return a.map == b.map and a.x == b.x and a.y == b.y and a.z == b.z
end

local function WalkKey(from, to)
	return table.concat({ from.map, from.x, from.y, from.z or "", to.x, to.y, to.z or "" }, ":")
end

local function FindWalk(planned, leg, key)
	local version, previous = pathVersion, leg.walkPoints
	leg.walkDrawn = previous ~= nil
	leg.walkPoints = previous or ns.Planner.WalkPoints(leg.from, leg.to)
	pendingWalks = pendingWalks + 1
	local job = ns.Path.Find(leg.from.map, leg.from, leg.to, function(points, cost, finished)
		pathJobs[finished] = nil
		if result ~= planned or version ~= pathVersion then
			return
		end
		pendingWalks = pendingWalks - 1
		leg.walkError = not points and cost or nil
		leg.walkPoints = points or previous or {}
		if points then
			leg.measured, leg.walkDrawn, leg.wet = true, true, points.wet
			if guide and result.legs[progress.index] == leg then
				guide.target = nil
			end
		end
		walkCache[key] = { points = points or previous, reason = leg.walkError }
		if ns.db.debug and (not points or math.abs(cost - leg.yards) > math.max(1, leg.yards * 0.1)) then
			ns.Print(string.format("walking cost mismatch: planned %.1f, found %s", leg.yards, tostring(cost)))
		end
		-- Costs were settled before choosing the plan. Geometry must never start another planning round.
		UpdateProgress()
		Refresh()
	end, waterMode)
	pathJobs[job] = true
end

local function PrepareWalks(planned)
	for _, leg in ipairs(planned and planned.legs or {}) do
		if leg.mode == "walk" then
			local key = WalkKey(leg.from, leg.to)
			local entry = walkCache[key]
			leg.measured, leg.walkError, leg.walkCost = false, nil, leg.yards
			if entry then
				leg.walkPoints, leg.measured = entry.points or {}, entry.reason == nil
				leg.walkDrawn = entry.points ~= nil
				leg.wet, leg.walkError = entry.points and entry.points.wet, entry.reason
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
	if not (a and b) or b.preview or a.waterMode ~= b.waterMode or #a.legs ~= #b.legs - progress.index + 1 then
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
		kept.aboard, kept.yards = leg.aboard, leg.yards
	end
end

-- Whether the plan you are following still works: you are on its walk, and have not missed a timed departure.
local function StillValid(plan, now)
	local leg = plan.legs[progress.index]
	if not leg or plan.arrive < now then
		return false
	end
	if leg.route and not progress.departed and leg.depart and leg.depart < now then
		return false
	end
	return not (leg.mode == "walk" and leg.measured) or OnWalk(leg.walkPoints, Here()) ~= nil
end

-- A route only gives way to one clearly faster, as satnavs do, so near-ties cannot flip the route back and forth
-- and restart its searches every few seconds.
local function Better(planned)
	local gain = math.max(SWITCH_GAIN, (result.arrive - planned.now) * SWITCH_SHARE)
	return planned.arrive < result.arrive - gain
end

local function Render(planned, forced)
	if SameJourney(planned, result) then
		Retime(planned)
		UpdateProgress()
		Refresh()
		return
	end
	if
		not forced
		and planned
		and result
		and not result.preview
		and StillValid(result, planned.now)
		and not Better(planned)
	then
		UpdateProgress()
		Refresh()
		return
	end
	if planned ~= result then
		CancelPaths()
		progress.index, progress.departed = 1, false
		PrepareWalks(planned)
		if guide then
			guide.target = nil
		end
	end
	result = planned
	if not result then
		StopGuide()
	end
	UpdateProgress()
	Refresh()
end

local plannerCache = {}

local function Plan(preview, bounded)
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
	local exactMaps = {}
	if not preview and not bounded and ns.Path then
		for _, continent in ipairs({ here.map, goal.map }) do
			if ns.Path.HasData(continent) then
				exactMaps[continent] = true
			end
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
		landmasses = ns.Landmasses,
		walks = preview and {} or Walks(here),
		exactMaps = exactMaps,
		baked = ns.Walks,
		waterWalking = waterMode,
	})
	if planned then
		planned.now, planned.preview, planned.waterMode = now, preview, waterMode
	end
	return planned
end

-- Only the two most recent endpoint searches are retained. Goal costs survive a repeated destination;
-- a start can be reused within three yards only if the pathfinder confirms the same snapped grid node.
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
	local version, faction = pathVersion, UnitFactionGroup("player")
	local places = ns.Planner.Places({
		docks = ns.Docks,
		taxiNodes = ns.TaxiNodes,
		portals = ns.Portals,
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
		if not batch or batch.path ~= ns.Path or batch.water ~= waterMode or batch.faction ~= faction then
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
			costs = {},
		}
	end
	startBatch = create(startBatch, here, false)
	if includeGoal then
		goalBatch = create(goalBatch, goal, true)
	end
	startAt, refreshedAt = here, GetTime()
	pendingCosts, costError = 2, nil
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
		preview = Plan(false, true)
		if preview then
			preview.preview, result = true, preview
		end
	end
	local consider
	consider = function(final)
		if version ~= pathVersion or not goal then
			return
		end
		if
			(not startBatch.done and not (startBatch.job and startBatch.job.valid))
			or (not goalBatch.done and not (goalBatch.job and goalBatch.job.valid))
		then
			Refresh()
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
		-- The initial bounded preview can choose probes while endpoint validation runs. Reuse that
		-- choice once, but always plan with current exact costs before committing a route.
		local previewed = preview and not startBatch.reason and not goalBatch.reason
		local planned = previewed and preview or Plan(false, true)
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
				if not result or result.preview then
					planned.preview, result = true, planned
					progress.index, progress.departed = 1, false
				end
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
				Refresh()
				return
			end
		end
		if previewed then
			planned = Plan(false, true)
		end
		local needStart = planned and planned.needsStart and ns.Path.HasData(here.map)
		local needGoal = planned and planned.needsGoal and ns.Path.HasData(goal.map)
		-- Missing-map estimates remain the existing terminal fallback, never an endless search.
		needStart = needStart and not startBatch.done
		needGoal = needGoal and not goalBatch.done
		active(startBatch, needStart)
		active(goalBatch, needGoal)
		if not needStart and not needGoal then
			pendingCosts, settleRound = 0, settleRound + 1
			Render(planned, forced)
		else
			-- Interim routes are previews; only a proven route starts geometry and becomes committed.
			if not result or result.preview then
				if planned then
					planned.preview = true
				end
				result = planned
				progress.index, progress.departed = 1, false
			end
			Refresh()
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
	-- Existing settled costs can prove a repeated journey without advancing either frontier.
	if ns.Path.Pause and (startBatch.job.valid or startBatch.done) and (goalBatch.job.valid or goalBatch.done) then
		consider(true)
	else
		Refresh()
	end
end

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
	local index = progress.index
	UpdateProgress()
	if not goal then
		return
	end
	local riding, flying = ns.CurrentRide(), UnitOnTaxi("player")
	local changedRide = riding ~= self.riding or flying ~= self.flying
	self.riding, self.flying = riding, flying
	if self.elapsed >= REPLAN_EVERY or changedRide then
		self.elapsed = 0
		local mode = WaterWalking()
		if mode ~= waterMode then
			waterMode, walkCache, startCosts, goalCosts = mode, {}, {}, {}
			RefreshCosts(true, true)
		elseif pendingCosts == 0 and pendingWalks == 0 then
			local here = Here()
			local leg = result and result.legs[progress.index]
			local off = here and leg and leg.mode == "walk" and leg.measured and not OnWalk(leg.walkPoints, here)
			local moved = here and startAt and not SamePlace(startAt, here)
			local retry = moved and (not result or (leg and leg.walkError) or here.map ~= startAt.map)
			if ns.Path and not flying and not riding and (off or retry or GetTime() - refreshedAt >= REFRESH_EVERY) then
				RefreshCosts(false, off or retry)
			else
				local planned = Plan(false, true)
				if
					planned
					and ns.Path
					and (
						(planned.needsStart and ns.Path.HasData(here.map))
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
end

local function StartJourney(point)
	local mode = WaterWalking()
	local repeated = goal and SamePlace(goal, point) and mode == waterMode
	local previous = repeated and result
	local index, departed = progress.index, progress.departed
	CancelPaths()
	settleRound, costError, goalError = 0, nil, nil
	walkCache, startCosts, goalCosts, startAt = repeated and walkCache or {}, {}, {}, nil
	if guide then
		StopGuide()
	end
	goal = point
	result = previous
	progress.index, progress.departed = previous and index or 1, previous and departed or false
	driver.elapsed, driver.progressElapsed = 0, 0
	if not InCombatLockdown() then
		driver:Show()
	end
	ns.WakeTravel()
	waterMode = mode
	if ns.Path then
		if not ns.Path.LowerBound then
			result = result or Plan(true)
		end
		RefreshCosts(true, true)
	else
		Render(Plan())
	end
	-- Every journey starts guided; the tracker header turns it off.
	if result then
		StartGuide()
		RefreshTracker()
	end
	return true
end

local function WorldPoint(uiMapID, x, y)
	local continent, world = C_Map.GetWorldPosFromMapPos(uiMapID, CreateVector2D(x, y))
	if continent and world then
		local worldX, worldY = world:GetXY()
		return { map = continent, x = worldX, y = worldY }
	end
end

local function PlanQuest(questID, clickedMap, isWaypoint)
	if not ns.db.journey then
		return
	end
	local uiMapID = clickedMap or GetQuestUiMapID(questID, true)
	local waypoint
	if not clickedMap or isWaypoint then
		local mapID, x, y
		if clickedMap then
			mapID = clickedMap
			x, y = C_QuestLog.GetNextWaypointForMap(questID, mapID)
		else
			mapID, x, y = C_QuestLog.GetNextWaypoint(questID)
		end
		waypoint = { uiMapID = mapID, x = x, y = y }
	end
	local pois = not isWaypoint and uiMapID and uiMapID > 0 and C_QuestLog.GetQuestsOnMap(uiMapID) or nil
	local location = ns.Planner.QuestDestination(
		questID,
		C_QuestLog.GetTitleForQuestID(questID),
		C_QuestLog.IsComplete(questID),
		uiMapID,
		pois,
		waypoint
	)
	local point = location and WorldPoint(location.uiMapID, location.x, location.y)
	if not point then
		-- Questie.API exposes icons and update notifications, but no public coordinate lookup.
		ns.Print("No location for that quest yet.")
		return
	end
	point.label, point.questID = location.label, questID
	StartJourney(point)
end

local function OnCanvasClick(map, button)
	if not ns.db.journey or button ~= "LeftButton" or not IsShiftKeyDown() then
		return false
	end
	local point = WorldPoint(map:GetMapID(), map:GetNormalizedCursorPosition())
	if point then
		StartJourney(point)
	else
		ns.Print("no journey can be planned to that spot.")
	end
	return true
end

local function OnMinimapClick(_, button)
	if not ns.db.journey or button ~= "LeftButton" or not IsShiftKeyDown() then
		return
	end
	local point = ns.MinimapPoint()
	if point then
		StartJourney(point)
	end
end

local function OnPinClick(map, action, button)
	if
		not ns.db.journey
		or action ~= MapCanvasMixin.MouseAction.Click
		or button ~= "LeftButton"
		or not IsShiftKeyDown()
	then
		return false
	end
	-- MapCanvas calls these handlers before POIButton.OnClick. Canvas click handlers do not run over pins.
	for _, pin in ipairs(GetMouseFoci()) do
		if pin.pinTemplate == "QuestPinTemplate" and pin:GetMap() == map and pin:GetQuestID() then
			PlanQuest(pin:GetQuestID(), map:GetMapID(), pin:GetStyle() == POIButtonUtil.Style.Waypoint)
			return true
		end
	end
	return false
end

local function AddQuestMenuEntry(root, questID)
	if ns.db.journey and questID then
		root:CreateButton("Plan journey", function()
			PlanQuest(questID)
		end)
	end
end

ns.Init(function()
	driver = CreateFrame("Frame", "ShortestPathForeverJourneyDriver", UIParent)
	driver:SetScript("OnUpdate", Update)
	driver:RegisterEvent("PLAYER_REGEN_DISABLED")
	driver:RegisterEvent("PLAYER_REGEN_ENABLED")
	driver:RegisterEvent("QUEST_TURNED_IN")
	driver:RegisterEvent("QUEST_REMOVED")
	driver:RegisterEvent("SUPER_TRACKING_CHANGED")
	driver:RegisterEvent("USER_WAYPOINT_UPDATED")
	driver:SetScript("OnEvent", function(self, event, questID)
		if event == "PLAYER_REGEN_DISABLED" then
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
				-- A quest/map-pin click belongs to the player. Keep the route arrow, but never retake tracking.
				guide.yielded = true
			end
		end
	end)
	driver:Hide()
	WorldMapFrame:AddCanvasClickHandler(OnCanvasClick)
	for provider in pairs(WorldMapFrame.dataProviders) do
		if provider.RefreshAllData == WaypointLocationDataProviderMixin.RefreshAllData then
			hooksecurefunc(provider, "RefreshAllData", HideGuideWaypointPin)
		end
	end
	WorldMapFrame:AddGlobalPinMouseActionHandler(OnPinClick)
	-- The stock handler still pings the spot, which marks where the journey goes for your group too.
	Minimap:HookScript("OnMouseUp", OnMinimapClick)
	Menu.ModifyMenu("MENU_QUEST_OBJECTIVE_TRACKER", function(owner, root)
		-- The native menu owner is the tracker container, with no quest ID/context data.
		-- Resolve the right-clicked HeaderButton's block; never reuse a previous hover's quest.
		for _, header in ipairs(GetMouseFoci()) do
			local block = header:GetParent()
			if
				block
				and block.HeaderButton == header
				and block.parentModule
				and block.parentModule:GetContextMenuParent() == owner
			then
				AddQuestMenuEntry(root, block.id)
				return
			end
		end
	end)
	Menu.ModifyMenu("MENU_QUEST_MAP_LOG_TITLE", function(owner, root)
		-- Waypoint menus share this tag, but have no questID.
		AddQuestMenuEntry(root, owner.questID)
	end)
end)
