local _, ns = ...

-- Shift-click the world map: the fastest way there from here, by foot, flight, boat, zeppelin, tram and portal,
-- with the boats' live waits. The tracker owns the list; closing the map leaves the journey running.
local REPLAN_EVERY = 5
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
local PATH_REUSE, PATH_REUSE_HEIGHT = 3, 10
local pathJobs, walkCache, pathVersion = {}, {}, 0
local pendingWalks, settleRound, replanning = 0, 0, false
-- Walks the pathfinder has measured on this journey, for the planner; the newest record of a walk replaces older
-- ones. A walk turning out this much longer than planned, or blocked, replans once the plan's searches are in.
local REPLAN_SLACK = 1.1
-- Walking along a measured path from where you stood, how far off it you may stray and still be on it.
local ON_PATH = 15
local SAME_WALK = 30
-- How far from where a walk was found blocked it is still taken as blocked.
local BLOCKED_REACH = 200
-- A timed replan replaces the route you are following only when it arrives this much sooner: at least SWITCH_GAIN
-- ms, or SWITCH_SHARE of the time left.
local SWITCH_GAIN, SWITCH_SHARE = 20000, 0.1
local measured = {}
local Replan
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

local function CancelPaths()
	pathVersion = pathVersion + 1
	for job in pairs(pathJobs) do
		ns.Path.Cancel(job)
	end
	pathJobs = {}
	pendingWalks = 0
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
	if not guide or not OwnsWaypoint() then
		return false
	end
	if not SameTracking(guide) then
		guide.yielded = true
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
	settleRound, replanning = 0, false
	walkCache, measured = {}, {}
	StopGuide()
	goal, result = nil, nil
	progress.index, progress.departed = 1, false
	driver:Hide()
	ns.SetJourneyRoute(nil)
	ns.RefreshTracker()
end

local function UpdateProgress()
	if guide then
		OwnsWaypoint()
	end
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
	return pendingWalks > 0 or replanning, settleRound, pendingWalks
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
	ns.RefreshTracker()
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
			local _, spell = WaterWalking()
			if spell and leg.wet and leg.wet >= WATER_HINT then
				text = text .. " (cast " .. C_Spell.GetSpellName(spell) .. ")"
			end
			rows[#rows + 1] = { key = index, text = text .. "   " .. LegTime(leg), current = index == progress.index }
		end
	else
		rows[1] = { key = "unreachable", text = "No way there from here." }
	end
	return title, rows
end

-- Where here falls on a walk: the segment ending at points[index], how far along it (t), and the yards still to walk
-- from there, or nil when here is more than reach (ON_PATH by default) off the walk.
local function OnWalk(points, here, reach)
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
		local leg, x, y, z, map = remaining.legs[1], UnitPosition("player")
		if leg and leg.mode == "walk" and leg.walkPoints and x then
			local here = { map = map, x = x, y = y, z = z }
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
	ns.RefreshTracker()
end

local function NearPathEndpoint(a, b)
	return a.map == b.map
		and (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 <= PATH_REUSE ^ 2
		and not (a.z and b.z and math.abs(a.z - b.z) > PATH_REUSE_HEIGHT)
end

local function Apart(a, b, reach)
	local dz = a.z and b.z and a.z - b.z or 0
	return a.map ~= b.map or (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + dz ^ 2 > (reach or SAME_WALK) ^ 2
end

-- Walks from your position change as you move, so only the newest to each destination is kept.
local function Measure(from, to, cost, points, exact)
	for index = #measured, 1, -1 do
		local walk = measured[index]
		local sameStart = from.kind == "start" and walk.from.kind == "start"
		if not Apart(walk.to, to) and (sameStart or not Apart(walk.from, from)) then
			table.remove(measured, index)
		end
	end
	measured[#measured + 1] = { from = from, to = to, cost = cost, points = points, exact = exact }
end

-- The rest of a measured walk from a point on it, in the walk's own yards (so swimming keeps its weight).
local function Remaining(walk, here)
	local found, _, after, total = OnWalk(walk.points, here)
	return found and total > 0 and walk.cost * after / total
end

-- Measurements for the planner, with the walks from where you stood carried along to where you are now.
local function Walks(here)
	local walks = {}
	for _, walk in ipairs(measured) do
		walks[#walks + 1] = walk
		local rest = walk.from.kind == "start" and walk.points and Remaining(walk, here)
		if rest then
			walks[#walks + 1] = { from = here, to = walk.to, cost = rest }
		elseif
			walk.from.kind == "start"
			and walk.cost == false
			and not walk.exact
			and not Apart(walk.from, here, BLOCKED_REACH)
		then
			-- Proving a place unreachable searches everything reachable, the dearest search there is; a few steps
			-- on foot will not change the answer.
			walks[#walks + 1] = { from = here, to = walk.to, cost = false }
		end
	end
	return walks
end

local function SamePlace(a, b)
	return a.map == b.map and a.x == b.x and a.y == b.y and a.z == b.z
end

local function PrepareWalks(planned)
	local cache, searches = {}, {}
	for _, leg in ipairs(planned and planned.legs or {}) do
		if leg.mode == "walk" then
			leg.measured, leg.walkError = false, nil
			leg.walkPoints = ns.Planner.WalkPoints(leg.from, leg.to)
			if ns.Path and leg.from.map == leg.to.map and ns.Path.HasData(leg.from.map) then
				local found
				for _, entry in ipairs(walkCache) do
					local matches = entry.exact and SamePlace or NearPathEndpoint
					if entry.done and matches(entry.from, leg.from) and matches(entry.to, leg.to) then
						found = entry
						break
					end
				end
				-- Compare with the original search endpoints, so small moves cannot drift the cache indefinitely.
				local entry = found or { from = leg.from, to = leg.to }
				cache[#cache + 1] = entry
				if found then
					leg.walkPoints, leg.measured = entry.points or leg.walkPoints, entry.points ~= nil
					leg.wet = entry.points and entry.points.wet
					leg.walkError = entry.reason
				else
					searches[#searches + 1] = { leg = leg, entry = entry }
					-- Until the search is in, keep drawing the walk it replaces rather than a straight line.
					for _, previous in ipairs(result and result.legs or {}) do
						if previous.mode == "walk" and previous.measured and SamePlace(previous.to, leg.to) then
							leg.walkPoints = previous.walkPoints
							break
						end
					end
				end
			else
				leg.walkError = "nodata"
			end
		end
	end
	walkCache = cache
	return searches
end

local function FindWalks(planned, searches)
	local version, pending, worse = pathVersion, #searches, false
	for _, search in ipairs(searches) do
		local leg, entry = search.leg, search.entry
		local from, to = leg.from, leg.to
		local job = ns.Path.Find(from.map, from, to, function(points, cost, finished)
			pathJobs[finished] = nil
			if result ~= planned or version ~= pathVersion then
				return
			end
			pending = pending - 1
			pendingWalks = pending
			entry.done, entry.points = true, points
			entry.reason = not points and cost or nil
			entry.exact = cost == "offmesh" or cost == "outside"
			leg.walkError = entry.reason
			-- A map click can fall outside the mesh even on a supported continent. That is a failed walk too;
			-- caching it without a blocked cost leaves the planner's straight-line estimate alive forever.
			if points or cost == "unreachable" or cost == "offmesh" or cost == "outside" then
				Measure(from, to, points and cost or false, points, entry.exact)
				-- The planner guessed a straight line; a walk that turns out blocked or longer may change the plan.
				worse = worse or not points or cost > leg.yards * REPLAN_SLACK
			end
			if points then
				leg.walkPoints, leg.measured, leg.wet = points, true, points.wet
				if guide and result.legs[progress.index] == leg then
					guide.target = nil
				end
			else
				leg.walkPoints = ns.Planner.WalkPoints(from, to)
			end
			-- A replan that keeps these legs only retimes them, so the points above still draw.
			if pending == 0 and worse then
				Replan()
			else
				UpdateProgress()
				Refresh()
			end
		end, waterMode)
		pathJobs[job] = true
	end
end

-- The same journey replanned from a few yards on: every leg goes the same way to the same place.
local function SameJourney(a, b)
	if not (a and b) or #a.legs ~= #b.legs then
		return false
	end
	for index, leg in ipairs(a.legs) do
		local other = b.legs[index]
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
	local walk, x, y, z, map = b.legs[progress.index], UnitPosition("player")
	return not (walk and walk.mode == "walk" and walk.measured)
		or OnWalk(walk.walkPoints, { map = map, x = x, y = y, z = z }) ~= nil
end

-- Only the timings move, so the drawn route, Guide and any walk still being searched carry on undisturbed.
local function Retime(planned)
	result.now, result.arrive = planned.now, planned.arrive
	for index, leg in ipairs(planned.legs) do
		local kept = result.legs[index]
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
	local x, y, z, map = UnitPosition("player")
	return not (leg.mode == "walk" and leg.measured)
		or OnWalk(leg.walkPoints, { map = map, x = x, y = y, z = z }) ~= nil
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
		replanning = false
		UpdateProgress()
		Refresh()
		return
	end
	if not forced and planned and result and StillValid(result, planned.now) and not Better(planned) then
		UpdateProgress()
		return
	end
	local searches
	if planned ~= result then
		CancelPaths()
		progress.index, progress.departed = 1, false
		searches = PrepareWalks(planned)
		pendingWalks = #searches
		if not replanning then
			settleRound = pendingWalks > 0 and 1 or 0
		end
		if guide then
			guide.target = nil
		end
	end
	result = planned
	replanning = false
	if not result then
		StopGuide()
	end
	UpdateProgress()
	Refresh()
	if result == planned and planned and searches then
		FindWalks(planned, searches)
	end
end

local function Plan()
	local x, y, z, map = UnitPosition("player")
	if not (x and goal) then
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
	-- Gaining or losing water walking changes every walk: search them all again.
	local waterWalking = WaterWalking()
	if waterWalking ~= waterMode then
		CancelPaths()
		waterMode, walkCache, measured, result = waterWalking, {}, {}, nil
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
	local planned = ns.Planner.Plan({
		from = { map = map, x = x, y = y, z = z },
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
		walks = Walks({ map = map, x = x, y = y, z = z }),
		baked = ns.Walks,
		waterWalking = waterMode,
	})
	if planned then
		planned.now = now
	end
	return planned
end

Replan = function()
	replanning = true
	settleRound = settleRound + 1
	Render(Plan(), true)
end

local function Update(self, elapsed)
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
		Render(Plan(), changedRide)
	elseif index ~= progress.index then
		Refresh()
	end
end

local function StartJourney(point)
	CancelPaths()
	settleRound, replanning = 0, false
	walkCache, measured = {}, {}
	if guide then
		StopGuide()
	end
	goal = point
	result = nil
	progress.index, progress.departed = 1, false
	driver.elapsed, driver.progressElapsed = 0, 0
	driver:Show()
	Render(Plan())
	-- Every journey starts guided; the tracker header turns it off.
	if result then
		StartGuide()
		ns.RefreshTracker()
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
	driver:RegisterEvent("QUEST_TURNED_IN")
	driver:RegisterEvent("QUEST_REMOVED")
	driver:RegisterEvent("SUPER_TRACKING_CHANGED")
	driver:RegisterEvent("USER_WAYPOINT_UPDATED")
	driver:SetScript("OnEvent", function(_, event, questID)
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
				ns.RefreshTracker()
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
