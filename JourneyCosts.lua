---@class SPFNamespace
local ns = select(2, ...)

-- A journey's endpoint costs: one bounded FindMany from where you stand and one back from the goal, short A* probes
-- for the candidate's own walks, and the plan they settle. Journey.lua binds its state and steps as J.
local PROBE_BUDGET = 60 -- ms before switching from candidate costs to shared endpoint searches

---@class SPFJourneyCosts
local Costs = {}
ns.JourneyCosts = Costs
local J
local startBatch, goalBatch, startAt, refreshedAt
local startCosts, goalCosts = {}, {}
refreshedAt = 0
local pendingCosts, settleRound = 0, 0
local costError, goalError
local costsWaiting

local function SamePlace(a, b)
	return a.map == b.map and a.x == b.x and a.y == b.y and a.z == b.z
end
Costs.SamePlace = SamePlace

-- Reuse only the last two endpoint searches, with starts confirmed by the pathfinder as the same snapped node.
-- One search owns the callbacks' shared revision, preview and probe budget across resumes
local function RefreshCosts(includeGoal, forced)
	local here = J.Here()
	if not (here and J.Goal()) then
		return
	end
	if not ns.Path then
		J.Render(J.Plan(), forced)
		return
	end
	J.CancelPaths()
	J.SetSearch({ started = GetTime(), initial = not J.Result(), forced = forced })
	local version, faction = J.Version(), UnitFactionGroup("player")
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
		if withGoal and J.Goal().map == point.map and ns.Planner.Landmass(J.Goal(), ns.Landmasses or {}) == mass then
			list[#list + 1] = J.Goal()
		end
		return list
	end
	local function reuse(batch, point, reverse)
		if not batch or batch.path ~= ns.Path or batch.water ~= J.WaterMode() or batch.faction ~= faction then
			return false
		end
		if not reverse and not SamePlace(batch.goal, J.Goal()) then
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
			goal = J.Goal(),
			targets = targets(point, not reverse),
			reverse = reverse,
			path = ns.Path,
			water = J.WaterMode(),
			faction = faction,
			costs = {},
		}
	end
	startBatch = create(startBatch, here, false)
	if includeGoal then
		goalBatch = create(goalBatch, J.Goal(), true)
	end
	startAt, refreshedAt = here, GetTime()
	pendingCosts, costError = 2, nil
	if J.Search().initial then
		J.Refresh()
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
		local last = target.kind and target.kind .. target.id or target == J.Goal() and goalBatch.fixedKey
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
		local cost = pair and pair[(J.WaterMode() and 2 or 1) + (first > last and pair[3] ~= nil and 2 or 0)]
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
	if not J.Result() and ns.Path.LowerBound then
		startCosts, goalCosts = walks(startBatch), walks(goalBatch)
		preview = J.Plan()
		if preview then
			preview.preview, J.Search().candidate = true, preview
		end
	end
	local consider
	-- Bounded search callback; splitting adds calls and upvalues on every frontier update
	consider = function(final)
		if version ~= J.Version() or not J.Goal() then
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
			startCosts[#startCosts + 1] = { from = here, to = J.Goal(), cost = false }
		end
		-- Reuse the bounded preview once for probes; commit only after planning with current exact costs.
		local previewed = preview and not startBatch.reason and not goalBatch.reason
		local planned = previewed and preview or J.Plan()
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
				planned.preview, J.Search().candidate = true, planned
				active(startBatch, false)
				active(goalBatch, false)
				local left = #probes
				for _, probe in ipairs(probes) do
					local leg, batch = probe.leg, probe.batch
					local job = ns.Path.FindCost(leg.from.map, leg.from, leg.to, function(cost, reason, finished)
						J.Jobs()[finished] = nil
						if version ~= J.Version() then
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
					end, J.WaterMode())
					J.Jobs()[job] = true
				end
				return
			end
		end
		if previewed then
			planned = J.Plan()
		end
		local needStart = planned and planned.needsStart and ns.Path.HasData(here.map)
		local needGoal = planned and planned.needsGoal and ns.Path.HasData(J.Goal().map)
		-- Missing-map estimates remain the existing terminal fallback, never an endless search.
		needStart = needStart and not startBatch.done
		needGoal = needGoal and not goalBatch.done
		active(startBatch, needStart)
		active(goalBatch, needGoal)
		if not needStart and not needGoal then
			pendingCosts, settleRound = 0, settleRound + 1
			J.Render(planned, forced)
		else
			if planned then
				planned.preview = true
			end
			J.Search().candidate = planned
		end
	end
	local function attach(batch)
		local function update(costs, reason, job)
			if version ~= J.Version() or not J.Goal() then
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
			batch.job = ns.Path.FindMany(
				batch.point.map,
				batch.point,
				batch.targets,
				update,
				J.WaterMode(),
				batch.reverse,
				update
			)
		end
	end
	attach(startBatch)
	attach(goalBatch)
	-- Existing settled costs can prove a repeated journey without advancing either frontier.
	if ns.Path.Pause and (startBatch.job.valid or startBatch.done) and (goalBatch.job.valid or goalBatch.done) then
		consider(true)
	end
end

Costs.Refresh = RefreshCosts

-- Journey.lua's state and steps, read through accessors so its locals stay its own.
---@class SPFJourneyBinding
---@field Here fun(): SPFPoint?
---@field Plan fun(preview?: boolean): table?
---@field Render fun(planned: table?, forced?: boolean)
---@field Refresh fun()
---@field CancelPaths fun()
---@field Goal fun(): SPFPoint?
---@field Result fun(): table?
---@field Search fun(): table?
---@field SetSearch fun(value: table?)
---@field WaterMode fun(): boolean?
---@field Version fun(): number
---@field Jobs fun(): table

---@param journey SPFJourneyBinding
function Costs.Bind(journey)
	J = journey
end

-- The measured walks from where the batch started, moved to here, and back from the goal.
---@param here SPFPoint
---@return SPFWalkCost[]
function Costs.Walks(here)
	local walks = {}
	for _, walk in ipairs(goalCosts) do
		walks[#walks + 1] = walk
	end
	if startAt and startAt.map == here.map then
		for _, walk in ipairs(startCosts) do
			walks[#walks + 1] = { from = here, to = walk.to, cost = walk.cost, estimated = walk.estimated }
		end
	end
	return walks
end

-- Cancelled searches leave both batches paused with their settled costs.
function Costs.Pause()
	for _, batch in pairs({ start = startBatch, goal = goalBatch }) do
		if batch.job and batch.path.Pause then
			batch.path.Pause(batch.job)
		end
	end
	pendingCosts = 0
end

-- A proved journey keeps exact endpoint vectors and their lower bounds, never suspended search stacks.
function Costs.Release()
	for _, batch in pairs({ start = startBatch, goal = goalBatch }) do
		if batch.job and batch.path.ReleaseMany then
			batch.path.ReleaseMany(batch.job)
		end
	end
end

-- A new goal starts from no measured walks, keeping the batches a repeated journey may reuse.
function Costs.Clear()
	costsWaiting = nil
	settleRound, costError, goalError = 0, nil, nil
	startCosts, goalCosts, startAt = {}, {}, nil
end

function Costs.Reset()
	Costs.Clear()
	for _, batch in pairs({ start = startBatch, goal = goalBatch }) do
		if batch.job then
			batch.path.Cancel(batch.job)
		end
	end
	startBatch, goalBatch = nil, nil
end

-- Walks searched in another water mode no longer apply.
function Costs.Forget()
	startCosts, goalCosts = {}, {}
end

-- Whether no batch has started or a callback waited for a readable position; a true answer is consumed.
---@return boolean
function Costs.Stale()
	local stale = not startAt or costsWaiting
	costsWaiting = nil
	return stale and true or false
end

---@return SPFPoint? startAt, number refreshedAt
function Costs.Started()
	return startAt, refreshedAt
end

---@return number pending, number round, string? error
function Costs.Status()
	return pendingCosts, settleRound, costError
end
