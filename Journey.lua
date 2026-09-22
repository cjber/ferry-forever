local _, ns = ...

-- Shift-click the world map: the fastest way there from here, by foot, flight, boat, zeppelin, tram and portal,
-- with the boats' live waits. The tracker owns the list; closing the map leaves the journey running.
local REPLAN_EVERY = 5
local SCHEDULED = { boat = true, zeppelin = true, tram = true }
local VERB = {
	walk = "Walk to",
	flight = "Fly to",
	boat = "Boat to",
	zeppelin = "Zeppelin to",
	tram = "Tram to",
	portal = "Portal to",
	passage = "Go through to",
}

local goal, guide, result
local progress = { index = 1 }
local driver
local ARRIVAL = 15

local function NodeLabel(node)
	if node.kind == "start" then
		return "your position"
	elseif node.kind == "dock" then
		return ns.DockTitle(node.id)
	elseif node.kind == "taxi" then
		return ns.TaxiNodes[node.id].name
	elseif node.label then
		return node.label
	end
	local location = ns.Locate(node)
	return location and location.zone or UNKNOWN
end

local function LegTime(leg)
	local text = ns.FormatCountdown(leg.arrive - leg.depart)
	if leg.wait and leg.wait > 0 then
		text = "wait " .. ns.FormatCountdown(leg.wait) .. " · " .. text
	end
	return text
end

local function Near(node)
	local x, y, _, map = UnitPosition("player")
	return x and map == node.map and (x - node.x) ^ 2 + (y - node.y) ^ 2 <= ARRIVAL ^ 2
end

local function SameWaypoint(a, b)
	if not (a and b and a.uiMapID == b.uiMapID) then
		return false
	end
	local ax, ay = a.position:GetXY()
	local bx, by = b.position:GetXY()
	return math.abs(ax - bx) < 0.000001 and math.abs(ay - by) < 0.000001
end

local function StopGuide()
	if guide and SameWaypoint(C_Map.GetUserWaypoint(), guide.waypoint) then
		C_Map.ClearUserWaypoint()
		C_SuperTrack.SetSuperTrackedUserWaypoint(false)
	end
	guide = nil
end

local function OwnsWaypoint()
	if guide.waypoint and not SameWaypoint(C_Map.GetUserWaypoint(), guide.waypoint) then
		-- A manual replacement or removal ends guidance; never reclaim the player's waypoint.
		StopGuide()
		return false
	end
	return true
end

local function GuideTo(node)
	if not guide or guide.target == node then
		return
	end
	local point = node.kind == "dock" and ns.DockPoint(node.id) or node
	local location = ns.Locate(point)
	if not (location and C_Map.CanSetUserWaypointOnMap(location.uiMap)) then
		ns.Print("that stop cannot hold a map waypoint.")
		StopGuide()
		return
	end
	local waypoint = UiMapPoint.CreateFromCoordinates(location.uiMap, location.x, location.y)
	if not SameWaypoint(waypoint, guide.waypoint) then
		-- WaypointLocationDataProvider.lua:100; SuperTrackedFrame.lua:219,289 supplies native navigation.
		if not C_Map.SetUserWaypoint(waypoint) then
			StopGuide()
			return
		end
		guide.waypoint = C_Map.GetUserWaypoint()
		C_SuperTrack.SetSuperTrackedUserWaypoint(true)
	end
	guide.target = node
end

function ns.ClearJourney()
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
			GuideTo(leg.to)
			return
		end
		progress.index, progress.departed = progress.index + 1, false
	end
	ns.ClearJourney()
end

function ns.IsJourneyGuided()
	return guide ~= nil
end

function ns.ToggleJourneyGuide()
	if guide then
		StopGuide()
	elseif result then
		guide = {}
		UpdateProgress()
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
		title = title .. " · " .. ns.FormatCountdown(math.max(0, result.arrive - ns.NowMs()))
		for index = progress.index, #result.legs do
			local leg = result.legs[index]
			local text = string.format("%d. %s %s", index, VERB[leg.mode], NodeLabel(leg.to))
			if leg.mode == "walk" and leg.to.undiscovered then
				text = text .. " (new flight path)"
			end
			if leg.estimated and SCHEDULED[leg.mode] then
				text = text .. " (no sighting yet)"
			end
			rows[#rows + 1] = { key = index, text = text .. "   " .. LegTime(leg), current = index == progress.index }
		end
	else
		rows[1] = { key = "unreachable", text = "No way there from here." }
	end
	return title, rows
end

local function Refresh()
	local remaining
	if result then
		remaining = { now = result.now, arrive = result.arrive, legs = {} }
		for index = progress.index, #result.legs do
			remaining.legs[#remaining.legs + 1] = result.legs[index]
		end
	end
	ns.SetJourneyRoute(goal, remaining)
	ns.RefreshTracker()
end

local function Render(planned)
	if planned ~= result then
		progress.index, progress.departed = 1, false
	end
	result = planned
	if not result then
		StopGuide()
	end
	UpdateProgress()
	Refresh()
end

local function Plan()
	local x, y, _, map = UnitPosition("player")
	if not (x and goal) then
		return nil
	end
	local _, runSpeed = GetUnitSpeed("player")
	local now = ns.NowMs()
	-- Taxi paths cannot be interrupted; retain their chosen destination until landing.
	if result and UnitOnTaxi("player") then
		result.now = now
		return result
	end
	local ride, routeID = nil, ns.CurrentRide()
	if routeID then
		local dock, arriveIn = ns.NextStop(routeID)
		if dock then
			ride = { route = routeID, dock = dock, arrive = now + arriveIn }
		end
	end
	local planned = ns.Planner.Plan({
		from = { map = map, x = x, y = y },
		to = goal,
		now = now,
		ride = ride,
		walkSpeed = math.max(runSpeed, 7),
		faction = UnitFactionGroup("player"),
		taxiKnown = ns.KnownTaxiNodes(),
		anchors = ns.FreshAnchors(),
		docks = ns.Docks,
		routes = ns.Routes,
		taxiNodes = ns.TaxiNodes,
		taxiPaths = ns.TaxiPaths,
		portals = ns.Portals,
		landmasses = ns.Landmasses,
	})
	if planned then
		planned.now = now
	end
	return planned
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
		Render(Plan())
	elseif index ~= progress.index then
		Refresh()
	end
end

local function OnCanvasClick(map, button)
	if not ns.db.journey or button ~= "LeftButton" or not IsShiftKeyDown() then
		return false
	end
	local continent, world =
		C_Map.GetWorldPosFromMapPos(map:GetMapID(), CreateVector2D(map:GetNormalizedCursorPosition()))
	if not continent then
		ns.Print("no journey can be planned to that spot.")
		return true
	end
	local x, y = world:GetXY()
	if guide then
		StopGuide()
	end
	goal = { map = continent, x = x, y = y }
	result = nil
	progress.index, progress.departed = 1, false
	driver.elapsed, driver.progressElapsed = 0, 0
	driver:Show()
	Render(Plan())
	return true
end

ns.Init(function()
	driver = CreateFrame("Frame", "FerryForeverJourneyDriver", UIParent)
	driver:SetScript("OnUpdate", Update)
	driver:Hide()
	WorldMapFrame:AddCanvasClickHandler(OnCanvasClick)
end)
