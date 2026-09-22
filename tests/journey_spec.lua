local ns = { db = { journey = true } }
local now, here, target, shown, click = 0, { map = 1, x = 0, y = 0, z = 0 }
local function noop() end
local driver = {
	SetScript = function(self, name, fn)
		self[name] = fn
	end,
	RegisterEvent = noop,
	Show = noop,
	Hide = noop,
}
local env = setmetatable({
	CreateFrame = function()
		return driver
	end,
	UnitPosition = function()
		return here.x, here.y, here.z, here.map
	end,
	GetUnitSpeed = function()
		return 0, 7
	end,
	canaccessvalue = function()
		return true
	end,
	UnitOnTaxi = noop,
	UnitFactionGroup = function()
		return "Alliance"
	end,
	IsShiftKeyDown = function()
		return true
	end,
	C_UnitAuras = { GetPlayerAuraBySpellID = noop },
	IsPlayerSpell = noop,
	C_Map = {
		GetWorldPosFromMapPos = function(map, point)
			return map, point
		end,
		HasUserWaypoint = noop,
		GetUserWaypoint = noop,
	},
	CreateVector2D = function(x, y)
		return {
			GetXY = function()
				return x, y
			end,
		}
	end,
	C_SuperTrack = {
		GetSuperTrackedQuestID = noop,
		IsSuperTrackingUserWaypoint = noop,
		GetHighestPrioritySuperTrackingType = noop,
	},
	WorldMapFrame = {
		dataProviders = {},
		AddCanvasClickHandler = function(_, fn)
			click = fn
		end,
		AddGlobalPinMouseActionHandler = noop,
	},
	Minimap = { HookScript = noop },
	Menu = { ModifyMenu = noop },
}, { __index = _G })
local function load(file)
	setfenv(assert(loadfile(file)), env)("ShortestPathForever", ns)
end
ns.Init = function(fn)
	fn()
end
ns.NowMs = function()
	return now
end
ns.CurrentRide, ns.RefreshTracker, ns.PointGuideArrow = noop, noop, noop
ns.KnownTaxiNodes, ns.FreshAnchors = function()
	return {}
end, function()
	return {}
end
ns.Locate = function()
	return { zone = "Test" }
end
ns.FormatCountdown = tostring
ns.SetJourneyRoute = function(_, route)
	shown = route
end
load("Model.lua")
load("Planner.lua")
load("Journey.lua")

local jobs = {}
ns.Path = {
	HasData = function()
		return true
	end,
	Find = function(_, from, to, callback)
		local job = { from = from, to = to, callback = callback }
		jobs[#jobs + 1] = job
		return job
	end,
	Cancel = function(job)
		job.cancelled = true
	end,
}
local map = {
	GetMapID = function()
		return target.map
	end,
	GetNormalizedCursorPosition = function()
		return target.x, target.y
	end,
}
local function begin(to)
	target = to or { map = 1, x = 1200, y = 0 }
	assert(click(map, "LeftButton"))
end
local function update(seconds)
	now = now + seconds * 1000
	driver:OnUpdate(seconds)
end
local function finish(job, points, cost)
	job.callback(points, cost, job)
end

-- A search spanning timed replans still belongs to the retained plan and finishes exactly once.
begin()
local first = jobs[#jobs]
local count = #jobs
local _, waiting = ns.JourneyInfo()
assert(waiting[1].text:find("finding walking path", 1, true))
update(5)
update(5)
assert(#jobs == count and not first.cancelled)
local points = { first.from, { map = 1, x = 600, y = 300 }, first.to }
finish(first, points, 1400)
assert(shown.legs[1].measured and shown.legs[1].walkPoints[2] == points[2])
assert(not shown.legs[1].estimated, "the measured cost is replanned without discarding its geometry")

-- A cleared or replaced plan cannot be resurrected by an already queued callback.
begin()
local stale = jobs[#jobs]
begin({ map = 1, x = 1500, y = 0 })
local current = jobs[#jobs]
finish(stale, points, 1400)
assert(stale.cancelled and not shown.legs[1].measured)
ns.ClearJourney()
finish(current, points, 1400)
assert(not shown and not ns.JourneyInfo())

-- Hysteresis keeps the followed plan's pending callback, while a measured detour forces the new route to search.
begin()
first, count = jobs[#jobs], #jobs
local plan = ns.Planner.Plan
ns.Planner.Plan = function(options)
	local mid = { map = 1, x = 600, y = 100, kind = "portal", id = 1 }
	return {
		arrive = options.now + 165000,
		legs = {
			{
				mode = "walk",
				from = first.from,
				to = mid,
				depart = options.now,
				arrive = options.now + 85000,
				yards = 600,
				estimated = true,
			},
			{
				mode = "walk",
				from = mid,
				to = first.to,
				depart = options.now + 85000,
				arrive = options.now + 165000,
				yards = 600,
				estimated = true,
			},
		},
	}
end
update(5)
assert(#jobs == count and not first.cancelled, "a near-tie must keep the pending search")
finish(first, points, 2000)
assert(#jobs == count + 2, "the forced replacement must start all its estimated walks")
for index = count + 1, #jobs do
	local job = jobs[index]
	finish(job, { job.from, { map = 1, x = 600, y = 50 }, job.to }, 605)
end
for _, leg in ipairs(shown.legs) do
	assert(leg.measured)
end
ns.ClearJourney()
ns.Planner.Plan = plan

-- Every terminal search failure resolves the estimate, including an endpoint outside the walkable mesh.
for _, reason in ipairs({ "unreachable", "offmesh", "outside" }) do
	begin()
	finish(jobs[#jobs], nil, reason)
	assert(not shown, reason .. " must remove the impossible walk")
	local _, rows = ns.JourneyInfo()
	assert(rows[1].key == "unreachable")
	count = #jobs
	update(5)
	assert(#jobs == count, reason .. " must not be searched repeatedly")
	if reason == "offmesh" or reason == "outside" then
		here.x = here.x + 1
		update(5)
		assert(#jobs == count + 1, "moving onto the mesh must retry even within the cache radius")
	end
end

-- Missing data and execution errors are visible failures, not proof that the terrain is impassable.
for _, reason in ipairs({ "nodata", "error" }) do
	begin()
	finish(jobs[#jobs], nil, reason)
	local _, rows = ns.JourneyInfo()
	assert(shown.legs[1].walkError == reason and rows[1].text:find("walking", 1, true))
	count = #jobs
	update(5)
	assert(#jobs == count and shown.legs[1].walkError == reason)
end

print("journey_spec: ok")
