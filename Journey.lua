---@class SPFNamespace
local ns = select(2, ...)

-- Shift-click the world map: the fastest way there from here, by foot, flight, boat, zeppelin, tram and portal,
-- with the boats' live waits. Search candidates stay private until costs and geometry settle, with a grace
-- period for longer searches. The tracker owns the list; closing the map leaves the journey running.
local REPLAN_EVERY, REFRESH_EVERY = 5, 60
-- The frames around a timed replan, which Itinerary.lua leaves to it.
local REPLAN_MARGIN = 0.5
local DRAW_EVERY, SEARCH_GRACE = 0.5, 3
-- A teleport step, by the item's or spell's own name in the game's language, after its own icon at the font's
-- height: the one step you act on from your bags or spellbook stands out from the travel around it.
local USE_ITEM, CAST_SPELL = "Use %s", "Cast %s"
local ICON = "|T%d:0|t "

local goal, result
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
local pendingWalks = 0
local Costs, Guide = ns.JourneyCosts, ns.JourneyGuide
local RefreshTracker, StopGuide = Guide.RefreshTracker, Guide.Stop
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

-- While you are a ghost, Corpse.lua's run borrows the route drawing, the tracker and Guide; the journey waits.
local function CorpseRun()
	return ns.Corpse ~= nil and ns.Corpse.Active()
end

---@return boolean
function ns.HasJourney()
	return goal ~= nil or CorpseRun()
end

local function CancelPaths()
	pathVersion = pathVersion + 1
	for job in pairs(pathJobs) do
		ns.Path.Cancel(job)
	end
	Costs.Pause()
	pathJobs, walkPending, pendingWalks = {}, {}, 0
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

---@param reason "arrived"|"cleared"
local function EndJourney(reason)
	CancelPaths()
	Costs.Reset()
	search = nil
	walkCache, walkOrder, plannerCache = {}, {}, {}
	if ns.Path and ns.Path.ClearCaches then
		ns.Path.ClearCaches()
	end
	goal, result, nextPoint = nil, nil, nil
	if ns.JourneyChanged then
		ns.JourneyChanged(nil, reason)
	end
	progress.index, progress.departed = 1, false
	driver:Hide()
	if not CorpseRun() then
		StopGuide()
		ns.SetJourneyRoute(nil)
	end
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
	if not (goal and result) or nextPoint or CorpseRun() then
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
				Guide.To(leg.from, nil, goal)
				return
			end
		end
		if leg.mode == "teleport" and not Near(leg.to) then
			Guide.Cast(leg)
			return
		end
		if not Near(leg.to) or (leg.mode == "flight" and flying) then
			Guide.To(leg.to, leg.walkPoints, goal)
			return
		end
		progress.index, progress.departed = progress.index + 1, false
	end
	Arrive()
end

---@return boolean
function ns.IsJourneyGuided()
	return Guide.Active()
end

function ns.JourneyStatus()
	local pendingCosts, settleRound = Costs.Status()
	return pendingWalks + pendingCosts > 0, settleRound, pendingWalks + pendingCosts
end

local function StartGuide()
	Guide.Start()
	UpdateProgress()
end

function ns.ToggleJourneyGuide()
	if Guide.Active() then
		StopGuide()
	elseif CorpseRun() then
		Guide.Start()
		ns.Corpse.Steer()
	elseif goal then
		StartGuide()
	end
	RefreshTracker()
end

function ns.ShowJourneyMap()
	local place = CorpseRun() and ns.Corpse.Point() or goal
	local location = place and ns.Locate(place)
	OpenWorldMap(location and location.uiMap)
end

-- Shared by the tracker and the goal pin, including on a fullscreen map.
---@return string? title, SPFRow[]? rows, SPFPlan? plan, number? index, boolean? loading
function ns.JourneyInfo()
	if CorpseRun() then
		return ns.Corpse.Info()
	end
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
				local icon = teleport.item and C_Item.GetItemIconByID(teleport.item)
					or (C_Spell.GetSpellTexture(teleport.spell))
				text = string.format(
					"%d. %s" .. (teleport.item and USE_ITEM or CAST_SPELL),
					index,
					icon and ICON:format(icon) or "",
					name
				)
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
		local _, _, costError = Costs.Status()
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

ns.OnWalk = OnWalk -- Corpse.lua trims its walk the same way.
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
	if not CorpseRun() then
		ns.SetJourneyRoute(goal, remaining)
	end
	RefreshTracker()
end

-- The rest of the chosen walk in its own running yards, so water keeps its search weight.
local function Remaining(leg, here)
	local found, _, after, total = OnWalk(leg.walkPoints, here)
	return found and total > 0 and (leg.walkCost or leg.yards) * after / total
end

local function Walks(here)
	local walks = Costs.Walks(here)
	local leg = result and result.legs[progress.index]
	local rest = leg and result.waterMode == waterMode and leg.mode == "walk" and leg.measured and Remaining(leg, here)
	if rest then
		walks[#walks + 1] = { from = here, to = leg.to, cost = rest }
	end
	return walks
end

local SamePlace = Costs.SamePlace

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
		if ns.db.debug and ns.Planner.WalkContradicts(leg, points and cost) then
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
	Guide.Retarget()
	if not result then
		StopGuide()
	end
	UpdateProgress()
	Refresh()
end

FinishSearch = function()
	if not search or Costs.Status() > 0 or pendingWalks > 0 then
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
	Costs.Release()
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
			if refine then
				Guide.Retarget()
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
	for _, walk in ipairs(Costs.LandingWalks(teleports)) do
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

-- The timed replan in Update plans in the frame; Itinerary.lua keeps its own planning and drawing off that frame. A
-- frame's GetTime is fixed, and the margin covers the frame the replan will take whichever handler runs first.
---@return boolean
function ns.JourneyReplanning()
	return driver ~= nil and (driver.elapsed >= REPLAN_EVERY - REPLAN_MARGIN or driver.replannedAt == GetTime())
end

---@param self SPFJourneyDriver
---@param elapsed number
-- One throttled frame step; keeping its gates together preserves the search/draw cadence
local function Update(self, elapsed)
	if InCombatLockdown() or CorpseRun() then
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
	if Costs.Stale() then
		-- Search callbacks may finish while position is unavailable; resume from readable endpoints.
		if ns.Path then
			Costs.Refresh(true, true)
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
			waterMode, walkCache, walkOrder = mode, {}, {}
			Costs.Forget()
			Costs.Refresh(true, false)
		elseif Costs.TeleportsChanged() then
			-- A new bind point or teleport: measure the walks on from where it lands.
			Costs.Refresh(true, false)
		elseif Costs.Status() == 0 and pendingWalks == 0 then
			local here, startAt, refreshedAt = Here(), Costs.Started()
			local leg = result and result.legs[progress.index]
			local off = here and leg and leg.mode == "walk" and leg.measured and not OnWalk(leg.walkPoints, here)
			local moved = here and startAt and not SamePlace(startAt, here)
			local retry = here
				and startAt
				and moved
				and (not result or (leg and leg.walkError) or here.map ~= startAt.map)
			if ns.Path and not flying and not riding and (off or retry or GetTime() - refreshedAt >= REFRESH_EVERY) then
				Costs.Refresh(false, off or retry)
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
					Costs.Refresh(false, changedRide)
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

-- Whether the journey waiting out a corpse run was guided; one asked for while you are a ghost starts guided.
local waitingGuided = false
-- The run is starting: searches stop, and the journey keeps its goal, route and progress for later.
function ns.SuspendJourney()
	waitingGuided = goal ~= nil and Guide.Active()
	CancelPaths()
	search = nil
end

-- You are alive again: the journey plans afresh from wherever that is, guided as it was.
function ns.ResumeJourney()
	if goal then
		ns.StartJourney(goal)
		-- The route you were on shows again at once, until the new plan replaces it.
		if result then
			Refresh()
		end
		if not waitingGuided then
			StopGuide()
		end
	else
		StopGuide()
		ns.SetJourneyRoute(nil)
	end
	RefreshTracker()
end

---@param point SPFPoint
---@return boolean
function ns.StartJourney(point)
	if CorpseRun() then
		-- Queued behind the corpse run, which ResumeJourney plans from where you come back to life.
		if not (goal and SamePlace(goal, point)) then
			result, search, walkCache, walkOrder = nil, nil, {}, {}
			progress.index, progress.departed = 1, false
		end
		goal, nextPoint, waitingGuided = point, nil, true
		if ns.JourneyChanged then
			ns.JourneyChanged(point)
		end
		RefreshTracker()
		return true
	end
	local mode = WaterWalking()
	local repeated = goal and SamePlace(goal, point) and mode == waterMode
	local previous = repeated and result
	local index, departed = progress.index, progress.departed
	CancelPaths()
	Costs.Clear()
	walkCache, walkOrder = repeated and walkCache or {}, repeated and walkOrder or {}
	if Guide.Active() then
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
		Costs.Refresh(true, false)
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

Costs.Bind({
	Here = Here,
	Plan = Plan,
	Render = Render,
	Refresh = Refresh,
	CancelPaths = CancelPaths,
	Goal = function()
		return goal
	end,
	Result = function()
		return result
	end,
	Search = function()
		return search
	end,
	SetSearch = function(value)
		search = value
	end,
	WaterMode = function()
		return waterMode
	end,
	Version = function()
		return pathVersion
	end,
	Jobs = function()
		return pathJobs
	end,
})

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
			Guide.ClearOrphan()
		elseif event == "PLAYER_REGEN_DISABLED" then
			self:Hide()
		elseif event == "PLAYER_REGEN_ENABLED" and goal then
			self:Show()
		end
		local questGone = event == "QUEST_TURNED_IN" or event == "QUEST_REMOVED"
		if questGone then
			Guide.QuestGone(questID)
		end
		if questGone and goal and goal.questID == questID then
			ns.ClearJourney()
		elseif event == "SUPER_TRACKING_CHANGED" or event == "USER_WAYPOINT_UPDATED" then
			Guide.TrackingChanged(event)
		end
	end)
	driver:Hide()
end)
