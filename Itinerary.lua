---@class SPFNamespace
local ns = select(2, ...)

-- Journey searches only the way to the current stop. Each later hop between stops is planned here with the
-- estimate's planner (no endpoint searches, about 2 ms cold), then its walking legs are searched on the walking
-- maps like the current leg's. One piece of work runs at a time, and only on frames the journey's own searches
-- leave free: a walking search in flight is paused while the journey settles. Until a hop is ready, its stops are
-- joined by a straight dotted placeholder, and a walking leg keeps its straight line until its search lands.

---@class SPFHop
---@field from SPFPoint
---@field to SPFPoint
---@field paths? SPFDrawPath[]|false false when the planner found no way
---@field walks {path: SPFDrawPath, leg: SPFLeg}[] walking legs still to search, nearest first

-- Hops are keyed by both stops' coordinates, so an unchanged hop survives a replan of the current leg and a caller
-- sending the same stops again. Only the current route's hops are kept, at most one per stop (64).
---@type table<string, SPFHop>
local hops = {}
local scheduled, wait, dirty
-- Redrawing the map's route line redraws every hop, so ready hops are drawn together at most once a second, in a
-- frame of their own, and once more when nothing is left to do.
local DRAW_EVERY, drawnAt = 1, -math.huge
---@type SPFPathJob?, SPFHop?
local job, searching
local Step

local function Key(from, to)
	return string.format("%d:%.17g:%.17g:%d:%.17g:%.17g", from.map, from.x, from.y, to.map, to.x, to.y)
end

local function Schedule()
	if not scheduled then
		scheduled = true
		ns.Path.after(Step)
	end
end

local function DrawDue()
	return dirty and GetTime() - drawnAt >= DRAW_EVERY
end

-- The journey's own searches (the current leg) always come first.
local function Settling()
	return ns.JourneyStatus and ns.JourneyStatus() == true
end

---@param hop SPFHop
local function PlanHop(hop)
	local legs = ns.EstimateLegs(hop.from, hop.to)
	hop.paths = legs and {} or false
	for index, leg in ipairs(legs or {}) do
		local walk = leg.mode == "walk"
		local path = { mode = leg.mode, points = ns.Planner.LegPoints(leg, ns.Routes), preview = walk or nil }
		hop.paths[index] = path
		if walk and leg.from.map == leg.to.map and ns.Path.HasData(leg.from.map) then
			hop.walks[#hop.walks + 1] = { path = path, leg = leg }
		end
	end
end

-- The next piece of work, and whether it is a plan. Every hop is planned before any walk is searched, so the walks
-- run back to back, and one hop's last walk and the next hop's first, which meet at a stop, share decoded grids.
---@return SPFHop?, boolean?
local function Next()
	local points, index = ns.JourneyStops()
	if not (points and index) then
		return nil
	end
	local walk
	for stop = index, #points - 1 do
		local hop = hops[Key(points[stop], points[stop + 1])]
		if hop and hop.paths == nil then
			return hop, true
		end
		walk = walk or hop and hop.walks[1] and hop
	end
	return walk, false
end

local SearchWalk

-- The search loads the continent's walking map on demand, like the current leg's.
---@param hop SPFHop
SearchWalk = function(hop)
	local walk = hop.walks[1]
	searching = hop
	job = ns.Path.Find(walk.leg.from.map, walk.leg.from, walk.leg.to, function(points, _, finished)
		if job ~= finished then
			return
		end
		job, searching = nil, nil
		table.remove(hop.walks, 1)
		-- An unreachable walk keeps its straight placeholder rather than vanishing.
		if points and #points > 1 then
			walk.path.points, walk.path.preview = points, nil
			dirty = true
		end
		-- Queued from this callback, the next walk keeps the search queue from draining, which frees the grids. A
		-- due redraw waits for a free frame instead, so it never adds to a search slice.
		local following, plan = Next()
		if following and not plan and not Settling() and not DrawDue() then
			SearchWalk(following)
		end
		Schedule()
	end, (ns.JourneyWaterWalking()))
end

Step = function()
	scheduled = false
	local points, index = ns.JourneyStops()
	if not (points and index and ns.db and ns.charDB) then
		return
	end
	if InCombatLockdown() then
		if not wait then
			wait = CreateFrame("Frame")
			wait:SetScript("OnEvent", function(self)
				self:UnregisterEvent("PLAYER_REGEN_ENABLED")
				Schedule()
			end)
		end
		wait:RegisterEvent("PLAYER_REGEN_ENABLED")
		return
	end
	if job then
		-- A finished job's callback is already queued; pausing it then would drop the callback.
		if not job.done then
			if Settling() then
				ns.Path.Pause(job)
			else
				ns.Path.Resume(job)
			end
		end
		Schedule()
		return
	end
	if ns.Path.Busy() or Settling() then
		Schedule()
		return
	end
	local hop, plan = Next()
	if dirty and (DrawDue() or not hop) then
		dirty, drawnAt = false, GetTime()
		if ns.RefreshJourneyPreview then
			ns.RefreshJourneyPreview()
		end
		Schedule()
	elseif plan then
		---@cast hop -?
		PlanHop(hop)
		dirty = true
		Schedule()
	elseif hop then
		SearchWalk(hop)
		Schedule()
	end
end

-- The route was replaced, advanced or cancelled: keep only the hops still ahead, dropping a search for any other.
function ns.ItineraryChanged()
	local points, index = ns.JourneyStops()
	local kept = {}
	if points and index then
		for stop = index, #points - 1 do
			local key = Key(points[stop], points[stop + 1])
			kept[key] = hops[key] or { from = points[stop], to = points[stop + 1], walks = {} }
		end
	end
	local owner = searching
	if job and not (owner and kept[Key(owner.from, owner.to)] == owner) then
		ns.Path.Cancel(job)
		job, searching = nil, nil
		-- A cleared journey skipped this while the walk was queued; release its decoded grids now.
		if not points then
			ns.Path.ClearCaches()
		end
	end
	hops = kept
	-- Specs of the public API alone run without the walking search.
	if points and ns.Path then
		Schedule()
	end
end

-- The drawn itinerary after the current stop. A planned hop draws its legs; consecutive unplanned hops are one
-- straight placeholder, which the map shows as end marks where it changes continent.
---@return SPFDrawPath[]
function ns.JourneyPreview()
	local drawn = {}
	local points, index = ns.JourneyStops()
	if not (points and index) then
		return drawn
	end
	local chain = { points[index] }
	for stop = index, #points - 1 do
		local hop, to = hops[Key(points[stop], points[stop + 1])], points[stop + 1]
		if hop and hop.paths then
			if #chain > 1 then
				drawn[#drawn + 1] = { mode = "walk", points = chain, preview = true }
			end
			for _, path in ipairs(hop.paths) do
				drawn[#drawn + 1] = path
			end
			chain = { to }
		else
			chain[#chain + 1] = to
		end
	end
	if #chain > 1 then
		drawn[#drawn + 1] = { mode = "walk", points = chain, preview = true }
	end
	return drawn
end
