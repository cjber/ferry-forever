---@class SPFNamespace
local ns = select(2, ...)

-- A corpse run: while you are a ghost, the walk back to your body, dotted in the red-orange of the game's own
-- tombstone for your corpse (Interface\Minimap\POIIcons, its lit face 192, 76, 24). The journey you were on waits
-- (Journey.lua) and plans again once you are alive, however that happens.
local COLOR = CreateColor(192 / 255, 76 / 255, 24 / 255)
local TITLE, LABEL = "Return to your corpse", "your corpse"
local STEP_EVERY, SEARCH_EVERY = 0.5, 5
-- The client reports the corpse in map fractions, so reading it again can move it a hair.
local SAME = 1
local Guide = ns.JourneyGuide

---@class SPFCorpse
local Corpse = {}
ns.Corpse = Corpse

---@class SPFCorpseRun
---@field point SPFPoint
---@field leg SPFLeg the walk, from where it was last searched
---@field plan SPFPlan
---@field job? SPFPathJob
---@field searchedAt number
---@type SPFCorpseRun?
local run
---@type Frame
local frame

local function Here()
	local x, y, _, map = ns.JourneyPosition()
	return x and { map = map, x = x, y = y }
end

-- Where your corpse lies, read on the map you are on and then on its continent, where a corpse in the next zone
-- still shows. A corpse on another continent, or in a dungeon, gives no run.
---@return SPFPoint?
local function CorpsePoint()
	local uiMap = C_Map.GetBestMapForUnit("player")
	while uiMap do
		local position = C_DeathInfo.GetCorpseMapPosition(uiMap)
		if position then
			local point = ns.WorldPoint(uiMap, position:GetXY()) -- multi-value: x and y
			if point then
				point.label, point.corpse = LABEL, true
				return point
			end
		end
		local info = C_Map.GetMapInfo(uiMap)
		uiMap = info and info.mapType > Enum.UIMapType.Continent and info.parentMapID ~= 0 and info.parentMapID or nil
	end
end

-- A straight dotted line stands in until the walking path is found, and stays when there is none.
---@param current SPFCorpseRun
---@param here SPFPoint
local function Search(current, here)
	local leg = current.leg
	if current.job then
		ns.Path.Cancel(current.job)
		current.job = nil
	end
	current.searchedAt = GetTime()
	leg.from.map, leg.from.x, leg.from.y = here.map, here.x, here.y
	leg.measured, leg.walkError = false, nil
	leg.walkPoints = ns.Planner.WalkPoints(here, current.point)
	if here.map ~= current.point.map then
		leg.walkPoints, leg.walkError = {}, "outside"
	elseif not (ns.Path and ns.Path.HasData(here.map)) then
		leg.walkError = "nodata"
	else
		local job
		-- A ghost walks on water.
		job = ns.Path.Find(here.map, here, current.point, function(points, cost)
			if current.job ~= job then
				return
			end
			current.job = nil
			if points then
				leg.walkPoints, leg.measured = points, true
			else
				leg.walkError = cost --[[@as string]]
			end
			Corpse.Steer()
		end, true)
		current.job = job
	end
end

-- The walk on from where you stand, its time at your speed, the drawing and Guide.
function Corpse.Steer()
	local here = run and Here()
	if not (run and here) then
		return
	end
	local leg, point = run.leg, run.point
	local ahead, yards = { here, point }, nil
	if here.map ~= point.map then
		ahead = {}
	elseif leg.measured then
		local found, _, after = ns.OnWalk(leg.walkPoints, here)
		if found then
			ahead = { here }
			for index = found, #leg.walkPoints do
				ahead[#ahead + 1] = leg.walkPoints[index]
			end
			yards = after
		elseif GetTime() - run.searchedAt >= SEARCH_EVERY then
			-- Strayed off it: search again from here.
			Search(run, here)
		end
	end
	yards = yards or math.sqrt((point.x - here.x) ^ 2 + (point.y - here.y) ^ 2)
	local _, speed = GetUnitSpeed("player")
	speed = canaccessvalue(speed) and math.max(speed, 7) or 7
	leg.depart = ns.NowMs()
	leg.arrive = leg.depart + yards / speed * 1000
	run.plan.arrive = leg.arrive
	local drawn = setmetatable({ walkPoints = ahead }, { __index = leg })
	local shown = { legs = { drawn } }
	ns.SetJourneyRoute(point, shown)
	if Guide.Active() then
		Guide.To(point, leg.measured and leg.walkPoints or nil, point)
	end
	Guide.RefreshTracker()
end

---@return boolean
function Corpse.Active()
	return run ~= nil
end

---@return SPFPoint?
function Corpse.Point()
	return run and run.point
end

-- The tracker's block, in JourneyInfo's shape.
---@return string? title, SPFRow[]? rows, SPFPlan? plan, number? index, boolean? loading
function Corpse.Info()
	if not run then
		return nil
	end
	local leg = run.leg
	local text = string.format("1. %s %s", ns.LegVerb(leg), ns.LegLabel(leg))
	if leg.walkError then
		text = text .. " (no walking path)"
	end
	return TITLE, { { key = 1, text = text .. "   " .. ns.LegTime(leg), current = true } }, run.plan, 1, false
end

---@param point SPFPoint
local function Start(point)
	---@type SPFLeg
	local leg = {
		mode = "walk",
		from = { kind = "start", map = point.map, x = point.x, y = point.y },
		to = { kind = "goal", map = point.map, x = point.x, y = point.y, label = LABEL },
		depart = 0,
		arrive = 0,
		wait = 0,
		walkPoints = {},
		color = COLOR,
	}
	run = {
		point = point,
		leg = leg,
		plan = { arrive = 0, legs = { leg }, needsStart = false, needsGoal = false, pendingWalks = {} },
		searchedAt = 0,
	}
	ns.SuspendJourney()
	if not Guide.Active() then
		Guide.Start()
	end
	local here = Here()
	if here then
		Search(run, here)
	end
	frame:Show()
	Corpse.Steer()
end

local function Stop()
	if run and run.job then
		ns.Path.Cancel(run.job)
	end
	run = nil
	frame:Hide()
	ns.ResumeJourney()
end

-- Released, with a corpse to find: the run starts, follows the corpse, and ends when you live again.
function ns.RefreshCorpseRun()
	local point = ns.db.corpse and UnitIsGhost("player") and CorpsePoint() or nil
	if not point then
		if run then
			Stop()
		end
		return
	end
	if not run then
		Start(point)
		return
	end
	local current = run.point
	if point.map ~= current.map or (point.x - current.x) ^ 2 + (point.y - current.y) ^ 2 > SAME ^ 2 then
		run.point = point
		run.leg.to.map, run.leg.to.x, run.leg.to.y = point.map, point.x, point.y
		local here = Here()
		if here then
			Search(run, here)
		end
		Corpse.Steer()
	end
end

ns.Init(function()
	frame = CreateFrame("Frame")
	frame:Hide()
	local elapsed = 0
	frame:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + delta
		if elapsed >= STEP_EVERY then
			elapsed = 0
			Corpse.Steer()
		end
	end)
	local events = CreateFrame("Frame")
	for _, event in ipairs({
		"PLAYER_ENTERING_WORLD",
		"PLAYER_DEAD",
		"PLAYER_ALIVE",
		"PLAYER_UNGHOST",
		"ZONE_CHANGED_NEW_AREA",
	}) do
		events:RegisterEvent(event)
	end
	events:SetScript("OnEvent", function()
		ns.RefreshCorpseRun()
		-- Releasing moves you to a graveyard, and the map you are on may settle a moment later.
		C_Timer.After(1, ns.RefreshCorpseRun)
	end)
end)
