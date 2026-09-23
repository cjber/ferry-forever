local _, ns = ...

-- Guide follows the map's walking path bend by bend. Journey places Blizzard's native navigation marker at
-- this target; our screen arrow is the fallback when that marker is unavailable or the player owns tracking.
-- Camelot omits the navigation setting, but its native super-tracked marker does work.

local UPDATE_EVERY = 0.05
-- The native marker's arrow sits this far from its icon.
local RADIUS = 36
-- A bend this close counts as passed, and the arrow turns to the next one.
local PASSED = 25
local frame, source, path, index, target, placeTarget, native
local stepEnd, destination

-- Counter-clockwise from north, like GetPlayerFacing: UnitPosition's first value grows north, its second west.
local function Bearing(x, y)
	return math.atan2(target.y - y, target.x - x)
end

local function Update()
	local x, y, _, map = ns.JourneyPosition()
	local facing = GetPlayerFacing()
	if not x or not canaccessvalue(facing) then
		frame:SetAlpha(0)
		return
	end
	while x and index < #path and map == target.map and (target.x - x) ^ 2 + (target.y - y) ^ 2 <= PASSED ^ 2 do
		index = index + 1
		target = path[index]
	end
	local alpha = 1
	if
		destination
		and map == destination.map
		and target.map == destination.map
		and target.x == destination.x
		and target.y == destination.y
	then
		alpha = math.max(0, math.min(1, (math.sqrt((target.x - x) ^ 2 + (target.y - y) ^ 2) - 15) / 25))
	end
	native = placeTarget and placeTarget(target, alpha < 1)
	-- A manual waypoint replacement can stop Guide inside placeTarget.
	if not path then
		return
	end
	if not (x and facing and map == target.map) or (native and C_Navigation.GetFrame()) then
		frame:SetAlpha(0)
		return
	end
	frame:SetAlpha(alpha)
	local angle = Bearing(x, y) - facing
	frame.Arrow:SetRotation(angle)
	frame.Arrow:SetPoint("CENTER", frame.Icon, "CENTER", -math.sin(angle) * RADIUS, math.cos(angle) * RADIUS)
	-- The distance still to walk: to this bend, then along the rest of the path.
	local distance = math.sqrt((target.x - x) ^ 2 + (target.y - y) ^ 2)
	for i = index + 1, #path do
		distance = distance + math.sqrt((path[i].x - path[i - 1].x) ^ 2 + (path[i].y - path[i - 1].y) ^ 2)
	end
	local yards = math.floor(distance)
	if yards ~= frame.yards then
		frame.yards = yards
		frame.Distance:SetFormattedText("%d yd", yards)
	end
end

local function Create()
	frame = CreateFrame("Frame", nil, UIParent)
	frame:SetSize(100, 100)
	frame:SetPoint("TOP", 0, -120)
	frame:SetFrameStrata("BACKGROUND")
	frame.Icon = frame:CreateTexture(nil, "BACKGROUND")
	frame.Icon:SetAtlas("Waypoint-MapPin-Tracked", true)
	frame.Icon:SetPoint("CENTER")
	frame.Arrow = frame:CreateTexture(nil, "BACKGROUND")
	frame.Arrow:SetAtlas("Navigation-Tracked-Arrow", true)
	frame.Distance = frame:CreateFontString(nil, "BACKGROUND", "GameFontNormal")
	frame.Distance:SetPoint("TOP", frame.Icon, "BOTTOM", 0, -8)
	local elapsed = 0
	frame:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + delta
		if elapsed >= UPDATE_EVERY then
			elapsed = 0
			Update()
		end
	end)
end

-- Guide leads bend by bend, or straight to the walk's end when set to mark only where each step ends.
function ns.RefreshGuideStops()
	path = source and (ns.db.guideStops and { source[#source] } or source)
	index = 1
	local x, y, z, map = ns.JourneyPosition()
	local nearest
	-- Guide may be restarted halfway along a walk, including one that crosses itself on another floor.
	for i = 2, #(path or {}) do
		local a, b = path[i - 1], path[i]
		local dx, dy = b.x - a.x, b.y - a.y
		local length = dx * dx + dy * dy
		if x and map == a.map and map == b.map then
			local t = length > 0 and math.max(0, math.min(1, ((x - a.x) * dx + (y - a.y) * dy) / length)) or 0
			local height = a.z and b.z and a.z + t * (b.z - a.z)
			local off = (a.x + t * dx - x) ^ 2 + (a.y + t * dy - y) ^ 2
			if not (height and z and math.abs(height - z) > 30) and (not nearest or off < nearest) then
				index, nearest = i, off
			end
		end
	end
	target = path and path[index]
end

-- placeBend owns waypoint placement and returns whether native tracking is ours. Progress lives only here.
function ns.PointGuideArrow(points, placeBend, stop, goal)
	if points and #points == 0 then
		points = nil
	end
	if points ~= source then
		source = points
		ns.RefreshGuideStops()
	end
	placeTarget = placeBend
	stepEnd, destination = stop, goal
	if ns.RefreshCompass then
		ns.RefreshCompass()
	end
	if not points then
		native = nil
		if frame then
			frame:Hide()
		end
		return
	end
	if not frame then
		Create()
	end
	frame:Show()
	Update()
end

-- Read-only targets share Guide's passed bends, including its step-end-only setting.
function ns.GuideTargets()
	if path then
		return target, path[index + 1], stepEnd, destination
	end
end
