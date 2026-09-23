local _, ns = ...

local WIDTH, HEIGHT, UPDATE_EVERY = 360, 36, 0.1
local TURN = 2 * math.pi
local frame

-- Facing and bearings both increase westward; east belongs on the right of the strip.
local function Offset(angle, facing)
	return -((angle - facing + math.pi) % TURN - math.pi) * WIDTH / math.pi
end

local function Place(marker, point, x, y, map, facing)
	if point and point.kind == "dock" then
		point = ns.DockPoint(point.id)
	end
	-- Coordinates on opposite sides of a loading screen have no shared bearing.
	if not point or point.map ~= map then
		marker:Hide()
		return false
	end
	local offset = Offset(math.atan2(point.y - y, point.x - x), facing)
	marker:SetPoint("CENTER", frame, "CENTER", math.max(-WIDTH / 2, math.min(WIDTH / 2, offset)), -6)
	marker:Show()
	return true
end

local function Update()
	local bend, nextBend, stop, goal = ns.GuideTargets()
	local x, y, _, map = UnitPosition("player")
	local facing = GetPlayerFacing()
	if not (ns.db.compass and ns.db.journey and ns.IsJourneyGuided() and bend) then
		frame:Hide()
		return
	end
	if not (x and facing) then
		frame:SetAlpha(0)
		return
	end
	frame:SetAlpha(1)
	for _, tick in ipairs(frame.ticks) do
		local offset = Offset(tick.angle, facing)
		local visible = math.abs(offset) <= WIDTH / 2
		tick:SetShown(visible)
		if visible then
			tick:SetPoint("TOP", frame, "TOP", offset, -2)
		end
		if tick.label then
			tick.label:SetShown(visible)
		end
	end
	if stop ~= frame.stop then
		frame.stop = stop
		if stop and stop.kind == "dock" then
			ns.SetTransportIcon(frame.Stop, ns.DockKind(stop.id))
		elseif stop and stop.kind == "taxi" then
			local taxi = ns.TaxiNodes[stop.id]
			frame.Stop:SetAtlas(
				stop.undiscovered and "taxinode_undiscovered" or "taxinode_" .. (taxi.faction or "Neutral"):lower()
			)
		else
			frame.Stop:SetAtlas("Waypoint-MapPin-Tracked")
		end
		frame.Stop:SetSize(16, 16)
	end
	Place(frame.Goal, goal, x, y, map, facing)
	Place(frame.Stop, stop, x, y, map, facing)
	Place(frame.Next, nextBend, x, y, map, facing)
	if Place(frame.Bend, bend, x, y, map, facing) then
		local yards = math.floor(math.sqrt((bend.x - x) ^ 2 + (bend.y - y) ^ 2))
		if yards ~= frame.yards then
			frame.yards = yards
			frame.Distance:SetFormattedText("%d yd", yards)
		end
		frame.Distance:Show()
	else
		frame.Distance:Hide()
	end
end

local function Create()
	frame = CreateFrame("Frame", "ShortestPathForeverCompass", UIParent, "BackdropTemplate")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("TOP", 0, -42)
	frame:SetFrameStrata("LOW")
	frame:EnableMouse(false)
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	frame:SetBackdropColor(0.04, 0.04, 0.04, 0.75)
	frame:SetBackdropBorderColor(0.65, 0.5, 0.2, 0.8)
	frame.ticks = {}
	local directions = { "N", "W", "S", "E" }
	for index = 0, 23 do
		local tick = frame:CreateTexture(nil, "ARTWORK")
		tick.angle = index * TURN / 24
		tick:SetColorTexture(0.8, 0.7, 0.4, 0.6)
		tick:SetSize(1, index % 6 == 0 and 5 or 3)
		if index % 6 == 0 then
			tick.label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			tick.label:SetText(directions[index / 6 + 1])
			tick.label:SetPoint("TOP", tick, "BOTTOM", 0, -1)
		end
		frame.ticks[#frame.ticks + 1] = tick
	end
	for _, name in ipairs({ "Goal", "Stop", "Next", "Bend" }) do
		local marker = frame:CreateTexture(nil, "OVERLAY")
		marker:SetAtlas(name == "Goal" and "Waypoint-MapPin-Tracked" or "Navigation-Tracked-Icon")
		marker:SetSize(16, 16)
		frame[name] = marker
	end
	frame.Goal:SetAlpha(0.65)
	frame.Stop:SetAlpha(0.85)
	frame.Next:SetAlpha(0.4)
	frame.Next:SetSize(10, 10)
	frame.Bend:SetVertexColor(1, 0.85, 0.25)
	frame.Distance = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	frame.Distance:SetPoint("TOP", frame.Bend, "BOTTOM", 0, -2)
	frame.elapsed = 0
	frame:SetScript("OnUpdate", function(self, elapsed)
		self.elapsed = self.elapsed + elapsed
		if self.elapsed >= UPDATE_EVERY then
			self.elapsed = 0
			Update()
		end
	end)
end

function ns.RefreshCompass()
	if ns.db.compass and ns.db.journey and ns.IsJourneyGuided() and ns.GuideTargets() then
		if not frame then
			Create()
		end
		frame:Show()
		Update()
	elseif frame then
		frame:Hide()
	end
end
