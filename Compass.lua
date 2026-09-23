---@class SPFNamespace
local ns = select(2, ...)

local WIDTH, HEIGHT, POLL_EVERY = 360, 60, 0.1
local TURN, EASE, SETTLED = 2 * math.pi, 18, 0.001
local OVERLAP = 6
---@class SPFCompassFrame : Frame, BackdropTemplate
---@field ticks SPFCompassTick[]
---@field markers SPFCompassMarker[]
---@field Goal SPFCompassMarker
---@field Stop SPFCompassMarker
---@field Next SPFCompassMarker
---@field Bend SPFCompassMarker
---@field Center Texture
---@field Distance FontString
---@field updating? boolean
---@field facing? number
---@field rawFacing? number
---@field x? number
---@field y? number
---@field map? number
---@field distance? number
---@field distanceOwner? SPFCompassMarker
---@field dirty? boolean
---@field idle number
---@field ticker? FunctionContainer
---@type SPFCompassFrame
local frame
local OnUpdate
---@type table<string, AtlasInfo|false>
local atlases = {
	["Waypoint-MapPin-Tracked"] = false,
	["Navigation-Tracked-Icon"] = false,
	flightmasterferry = false,
	["poi-door-arrow-up"] = false,
	["poi-door-arrow-down"] = false,
	["map-icon-suramardoor.tga"] = false,
	taxinode_alliance = false,
	taxinode_horde = false,
	taxinode_neutral = false,
	taxinode_undiscovered = false,
}
local transportIcons = {
	boat = "flightmasterferry",
	zeppelin = "Interface\\AddOns\\ShortestPathForever\\media\\zeppelin",
	lift = "poi-door-arrow-up",
	tram = "poi-door-arrow-down",
	portal = "map-icon-suramardoor.tga",
}
local taxiIcons = { Alliance = "taxinode_alliance", Horde = "taxinode_horde", Neutral = "taxinode_neutral" }

local function Difference(angle, facing)
	return (angle - facing + math.pi) % TURN - math.pi
end

-- Facing and bearings both increase westward; east belongs on the right of the strip.
local function Offset(angle, facing)
	return -Difference(angle, facing) * WIDTH / math.pi
end

local function SetIcon(marker, icon)
	if marker.icon == icon then
		return false
	end
	marker.icon = icon
	if icon == transportIcons.zeppelin then
		marker:SetTexture(icon)
		-- Our zeppelin texture is a square, unlike several of the stock marker atlases.
		marker:SetSize(marker.size, marker.size)
	else
		marker:SetAtlas(icon, true)
		local info = atlases[icon]
		if info then
			local scale = marker.size / math.max(info.width, info.height)
			marker:SetSize(info.width * scale, info.height * scale)
		end
	end
	return true
end

local function StopIcon(stop)
	if stop and stop.kind == "dock" then
		return transportIcons[ns.DockKind(stop.id)] or "Waypoint-MapPin-Tracked", true
	elseif stop and stop.kind == "taxi" then
		local taxi = ns.TaxiNodes[stop.id]
		return stop.undiscovered and "taxinode_undiscovered" or taxiIcons[taxi and taxi.faction] or taxiIcons.Neutral,
			true
	end
	return "Waypoint-MapPin-Tracked", false
end

local function SamePlace(a, b)
	return a == b
		or (a.map == b.map and (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 <= 1 and not (a.z and b.z and math.abs(a.z - b.z) > 1))
end

local function Place(marker, x, y, map, facing, index)
	local point = marker.target
	if point and point.kind == "dock" then
		point = ns.DockPoint(point.id)
	end
	marker.point, marker.visible, marker.replacement = point, false, nil
	-- Coordinates on opposite sides of a loading screen have no shared bearing.
	if not point or point.map ~= map then
		marker:Hide()
		return
	end
	local offset = Offset(math.atan2(point.y - y, point.x - x), facing)
	marker.offset = math.max(-WIDTH / 2, math.min(WIDTH / 2, offset))
	for i = 1, index - 1 do
		local other = frame.markers[i]
		if other.visible and (SamePlace(point, other.point) or math.abs(marker.offset - other.offset) <= OVERLAP) then
			marker.replacement = other
			marker:Hide()
			return
		end
	end
	marker:SetPoint("CENTER", frame, "CENTER", marker.offset, -6)
	marker:Show()
	marker.visible = true
end

local function Render(x, y, map)
	for _, tick in ipairs(frame.ticks) do
		local offset = Offset(tick.angle, frame.facing)
		local visible = math.abs(offset) <= WIDTH / 2
		local alpha = math.max(0, math.min(1, (WIDTH / 2 - math.abs(offset)) / 18))
		tick:SetShown(visible)
		if visible then
			tick:SetPoint("TOP", frame, "TOP", offset, -6)
			tick:SetAlpha(alpha)
		end
		if tick.label then
			tick.label:SetShown(visible)
			tick.label:SetAlpha(alpha)
		end
	end
	for i, marker in ipairs(frame.markers) do
		Place(marker, x, y, map, frame.facing, i)
	end
	local bend = frame.Bend
	local owner = bend.visible and bend or bend.replacement
	local point = bend.point
	if owner and point then
		local distance = math.floor(math.sqrt((point.x - x) ^ 2 + (point.y - y) ^ 2))
		if distance ~= frame.distance then
			frame.distance = distance
			frame.Distance:SetFormattedText("%d yd", distance)
		end
		-- A merged bend keeps its distance under the surviving destination or transport icon.
		if owner ~= frame.distanceOwner then
			frame.distanceOwner = owner
			frame.Distance:ClearAllPoints()
			frame.Distance:SetPoint("TOP", owner, "BOTTOM", 0, -2)
		end
		frame.Distance:Show()
	else
		frame.Distance:Hide()
	end
end

local function SetUpdating(running)
	if frame.updating ~= running then
		frame.updating = running
		frame:SetScript("OnUpdate", running and OnUpdate or nil)
	end
end

local function Update(elapsed)
	local bend, nextBend, stop, goal = ns.GuideTargets()
	if not (ns.db.compass and ns.db.journey and ns.IsJourneyGuided() and bend) then
		frame:Hide()
		return
	end
	local x, y, _, map = UnitPosition("player")
	local facing = GetPlayerFacing()
	if not (x and y and map and canaccessvalue(facing) and facing) then
		frame:SetAlpha(0)
		frame.facing = nil
		SetUpdating(false)
		return
	end
	frame:SetAlpha(1)
	local moved = x ~= frame.x or y ~= frame.y or map ~= frame.map or facing ~= frame.rawFacing
	local changed = frame.dirty
		or not frame.facing
		or bend ~= frame.Bend.target
		or nextBend ~= frame.Next.target
		or stop ~= frame.Stop.target
		or goal ~= frame.Goal.target
	local icon, specific = StopIcon(stop)
	changed = SetIcon(frame.Stop, icon) or changed
	frame.Goal.target, frame.Stop.target, frame.Bend.target, frame.Next.target = goal, stop, bend, nextBend
	-- A named transport is more useful than a generic pin; the final destination outranks walking bends.
	frame.markers[1], frame.markers[2] = specific and frame.Stop or frame.Goal, specific and frame.Goal or frame.Stop
	frame.x, frame.y, frame.map, frame.rawFacing = x, y, map, facing
	frame.facing = frame.facing or facing
	local delta = Difference(facing, frame.facing)
	local easing = math.abs(delta) > SETTLED
	if easing then
		-- Exponential decay is frame-rate independent and crosses north by the shortest arc.
		frame.facing = (frame.facing + delta * (1 - math.exp(-EASE * elapsed))) % TURN
	else
		frame.facing = facing
	end
	if moved or changed or delta ~= 0 then
		Render(x, y, map)
	end
	frame.dirty = false
	frame.idle = moved and 0 or frame.idle + elapsed
	SetUpdating(easing or frame.idle < 0.15)
end

OnUpdate = function(_, elapsed)
	Update(elapsed)
end

local function Poll()
	-- Mouse turns and moving transports need not send a player movement event.
	if not frame.updating then
		Update(0)
	end
end

local function Wake()
	frame.idle = 0
	SetUpdating(true)
end

local function OnShow()
	frame.ticker = C_Timer.NewTicker(POLL_EVERY, Poll)
	frame:RegisterEvent("PLAYER_STARTED_MOVING")
	frame:RegisterEvent("PLAYER_STARTED_TURNING")
	frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	Wake()
end

local function OnHide()
	SetUpdating(false)
	if frame.ticker then
		frame.ticker:Cancel()
		frame.ticker = nil
	end
	frame:UnregisterAllEvents()
	frame.facing = nil
end

local function Create()
	-- Read atlas dimensions once: GetAtlasInfo returns a fresh table.
	for atlas in pairs(atlases) do
		atlases[atlas] = C_Texture.GetAtlasInfo(atlas) or false
	end
	local compass = CreateFrame("Frame", "ShortestPathForeverCompass", UIParent, "BackdropTemplate")
	---@cast compass SPFCompassFrame
	frame = compass
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("TOP", 0, -42)
	frame:SetFrameStrata("LOW")
	frame:EnableMouse(false)
	-- The stock tooltip art keeps the edge soft and legible over bright terrain.
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	frame:SetBackdropColor(0.06, 0.06, 0.06, 0.7)
	frame:SetBackdropBorderColor(0.55, 0.52, 0.46, 0.65)
	frame.ticks = {}
	local directions = { "N", "W", "S", "E" }
	for index = 0, 23 do
		---@class SPFCompassTick : Texture
		---@field angle number
		---@field label? FontString
		local tick = frame:CreateTexture(nil, "ARTWORK")
		tick.angle = index * TURN / 24
		tick:SetColorTexture(0.72, 0.67, 0.55, 0.7)
		tick:SetSize(1, index % 6 == 0 and 5 or 3)
		if index % 6 == 0 then
			tick.label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			tick.label:SetText(directions[index / 6 + 1])
			tick.label:SetPoint("TOP", tick, "BOTTOM", 0, -1)
		end
		frame.ticks[#frame.ticks + 1] = tick
	end
	frame.Center = frame:CreateTexture(nil, "OVERLAY")
	frame.Center:SetColorTexture(1, 0.82, 0, 0.85)
	frame.Center:SetSize(1, 6)
	frame.Center:SetPoint("TOP", frame, "TOP", 0, -3)
	for _, name in ipairs({ "Goal", "Stop", "Next", "Bend" }) do
		---@class SPFCompassMarker : Texture
		---@field size number
		---@field icon? string
		---@field target? SPFPoint|SPFPlace
		---@field point? SPFPoint
		---@field visible boolean
		---@field replacement? SPFCompassMarker
		---@field offset number
		local marker = frame:CreateTexture(nil, "OVERLAY")
		marker.size = name == "Next" and 12 or 18
		SetIcon(marker, name == "Goal" and "Waypoint-MapPin-Tracked" or "Navigation-Tracked-Icon")
		frame[name] = marker
	end
	frame.Goal:SetAlpha(0.85)
	frame.Stop:SetAlpha(0.9)
	frame.Next:SetAlpha(0.45)
	frame.markers = { frame.Goal, frame.Stop, frame.Bend, frame.Next }
	frame.Distance = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.idle = 0
	frame:SetScript("OnShow", OnShow)
	frame:SetScript("OnHide", OnHide)
	frame:SetScript("OnEvent", Wake)
	frame:Hide()
end

function ns.RefreshCompass()
	if ns.db.compass and ns.db.journey and ns.IsJourneyGuided() and ns.GuideTargets() then
		if not frame then
			Create()
		end
		frame.dirty = true
		frame:Show()
		Update(0)
	elseif frame then
		frame:Hide()
	end
end
