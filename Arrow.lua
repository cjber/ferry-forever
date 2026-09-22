local _, ns = ...

-- Guide's direction arrow, for clients where the game's own navigation marker never appears (WoW Forever drops
-- the "In-game navigation" option: Blizzard_SettingsDefinitions_Frame/Camelot/InterfaceOverrides.lua). It uses
-- the same art as that marker (Blizzard_QuestNavigation/SuperTrackedFrame.xml), turned toward the stop by the
-- player's facing. There is no way to place it in the world, so it sits near the top of the screen instead.
-- Given a walking path it leads bend by bend, so following it walks the path drawn on the map.

local UPDATE_EVERY = 0.05
-- The native marker's arrow sits this far from its icon.
local RADIUS = 36
-- A bend this close counts as passed, and the arrow turns to the next one.
local PASSED = 10

local frame, path, index, target

-- Counter-clockwise from north, like GetPlayerFacing: UnitPosition's first value grows north, its second west.
local function Bearing(x, y)
	return math.atan2(target.y - y, target.x - x)
end

local function Update()
	local x, y, _, map = UnitPosition("player")
	local facing = GetPlayerFacing()
	-- The game's own marker, where it works, already shows the way.
	while index < #path and map == target.map and (target.x - x) ^ 2 + (target.y - y) ^ 2 < PASSED ^ 2 do
		index = index + 1
		target = path[index]
	end
	if not (x and facing and map == target.map) or C_Navigation.GetFrame() then
		frame:SetAlpha(0)
		return
	end
	frame:SetAlpha(1)
	local angle = Bearing(x, y) - facing
	frame.Arrow:SetRotation(angle)
	frame.Arrow:SetPoint("CENTER", frame.Icon, "CENTER", -math.sin(angle) * RADIUS, math.cos(angle) * RADIUS)
	-- The distance still to walk: to this bend, then along the rest of the path.
	local distance = math.sqrt((target.x - x) ^ 2 + (target.y - y) ^ 2)
	for i = index + 1, #path do
		distance = distance + math.sqrt((path[i].x - path[i - 1].x) ^ 2 + (path[i].y - path[i - 1].y) ^ 2)
	end
	frame.Distance:SetFormattedText("%d yd", distance)
end

local function Create()
	frame = CreateFrame("Frame", nil, UIParent)
	frame:SetSize(100, 100)
	frame:SetPoint("TOP", 0, -120)
	frame:SetFrameStrata("BACKGROUND")
	frame.Icon = frame:CreateTexture(nil, "BACKGROUND")
	frame.Icon:SetAtlas("Navigation-Tracked-Icon", true)
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

-- Lead along `points` ({ x, y, map } in UnitPosition's frame, ending at the stop), or hide the arrow with nil.
function ns.PointGuideArrow(points)
	path, index, target = points, 1, points and points[1]
	if not points then
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
