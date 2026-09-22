local _, ns = ...

-- Guide's route drawn on the ground ahead of you. Addons get no world-to-screen projection, but the native
-- navigation marker is one: the game projects Guide's waypoint every frame, and where it lands pins down the
-- camera's yaw and pitch. GetCameraZoom gives its distance behind your head, so the path's next few dozen yards
-- project onto the screen as the marker's own arrows lying on the ground. The ground is taken as level with
-- your feet.

local AHEAD, SPACING, NEAR, FADE = 40, 3.5, 6, 4 -- yards drawn, between arrows, clear of you, fading in and out
local HEAD = 2 -- the camera orbits this far above your feet, in yards
local LENGTH, WIDTH = 1.1, 1.4 -- an arrow's footprint on the ground, in yards
local ALPHA, GLOW = 0.3, 0.35 -- resting alpha, and what the travelling glow adds
local WAVE, SPEED = 12, 9 -- the glow's spacing along the trail and its pace, in yards and yards a second
local ITERATIONS = 5
local STEP = 1e-4
local SETTLE = 3 -- frames the marker gets to follow a moved waypoint
local MEASURE = 150 -- pixels off centre the marker must be to measure the focal length

local frame, readout
local arrows = {}
-- focal is pixels per unit of view-space tangent; mouselook calibrates it, since yaw is then your facing.
local yaw, pitch, focal, focalDefault = 0, 0.3, nil, nil
local lastTarget, settle = nil, 0

local function Camera(px, py, pz, cameraYaw, cameraPitch)
	local cy, sy, cp, sp = math.cos(cameraYaw), math.sin(cameraYaw), math.cos(cameraPitch), math.sin(cameraPitch)
	local distance = GetCameraZoom()
	local d = { cp * cy, cp * sy, -sp }
	return {
		x = px - distance * d[1],
		y = py - distance * d[2],
		z = pz + HEAD - distance * d[3],
		d = d,
		r = { sy, -cy, 0 },
		u = { cy * sp, sy * sp, cp },
	}
end

-- Screen offset from the view's centre in pixels (y up), and depth along the view; nil behind the camera.
local function Project(camera, x, y, z, f)
	local vx, vy, vz = x - camera.x, y - camera.y, z - camera.z
	local d, r, u = camera.d, camera.r, camera.u
	local depth = vx * d[1] + vy * d[2] + vz * d[3]
	if depth < 0.5 then
		return nil
	end
	return f * (vx * r[1] + vy * r[2]) / depth, f * (vx * u[1] + vy * u[2] + vz * u[3]) / depth, depth
end

-- Newton's method on two unknowns, so the waypoint projects where the game drew it. Returns false if it
-- fails to converge; the caller then keeps the previous camera.
local function Solve(residual, a, b)
	for _ = 1, ITERATIONS do
		local ex, ey = residual(a, b)
		if not ex then
			return false
		end
		local ax, ay = residual(a + STEP, b)
		local bx, by = residual(a, b + STEP)
		if not (ax and bx) then
			return false
		end
		local j11, j21, j12, j22 = (ax - ex) / STEP, (ay - ey) / STEP, (bx - ex) / STEP, (by - ey) / STEP
		local det = j11 * j22 - j12 * j21
		if math.abs(det) < 1e-9 then
			return false
		end
		a, b = a - (j22 * ex - j12 * ey) / det, b - (j11 * ey - j21 * ex) / det
	end
	local ex, ey = residual(a, b)
	return ex and ex * ex + ey * ey < 25, a, b
end

local function Pixels(region)
	local x, y = region:GetCenter()
	local scale = region:GetEffectiveScale()
	return x * scale, y * scale
end

-- The camera from this frame's waypoint projection; false while the marker is off screen or just moved.
local function Calibrate(px, py, pz, target, facing)
	local nav = C_Navigation.GetFrame()
	if not (nav and C_Navigation.HasValidScreenPosition() and not C_Navigation.WasClampedToScreen()) then
		return false
	end
	-- The marker takes a frame or two to follow a moved waypoint; its old position would bend the camera.
	if target ~= lastTarget then
		lastTarget, settle = target, SETTLE
	end
	if settle > 0 then
		settle = settle - 1
		return false
	end
	local cx, cy = Pixels(WorldFrame)
	local nx, ny = Pixels(nav)
	local ox, oy = nx - cx, ny - cy
	local function Residual(cameraYaw, cameraPitch, f)
		local sx, sy = Project(Camera(px, py, pz, cameraYaw, cameraPitch), target.x, target.y, pz, f)
		return sx and sx - ox, sy and sy - oy
	end
	-- Mouselook turns you with the camera, so yaw is known and the focal length can be measured, but only
	-- from a marker well off centre: near the middle, a pixel of error swings the estimate wildly.
	if IsMouselooking() and math.abs(ox) > MEASURE then
		local ok, _, f = Solve(function(p, f)
			return Residual(facing, p, f)
		end, pitch, focal)
		if ok and f > focalDefault / 3 and f < focalDefault * 3 then
			focal = focal * 0.9 + f * 0.1
		end
	end
	-- Solved last, with the focal length in use, so the camera drawn is the one that fits the marker.
	local ok, a, b = Solve(function(y, p)
		return Residual(y, p, focal)
	end, yaw, pitch)
	if ok and math.abs(b) < 1.5 then
		yaw, pitch = a, b
		return true
	end
	return false
end

local function Arrow(i)
	local arrow = arrows[i]
	if not arrow then
		arrow = frame:CreateTexture(nil, "BACKGROUND")
		arrow:SetAtlas("Navigation-Tracked-Arrow")
		arrow:SetBlendMode("ADD")
		arrows[i] = arrow
	end
	return arrow
end

-- Points every SPACING yards along the walk still ahead, from you through the remaining bends, each with the
-- direction of its leg.
local function Samples(px, py, path, index)
	local samples, travelled, s = {}, 0, NEAR
	local ax, ay = px, py
	for i = index, #path do
		local bx, by = path[i].x, path[i].y
		local length = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
		while length > 0 and s <= travelled + length and s <= AHEAD do
			local t = (s - travelled) / length
			samples[#samples + 1] = {
				x = ax + (bx - ax) * t,
				y = ay + (by - ay) * t,
				dx = (bx - ax) / length,
				dy = (by - ay) / length,
				s = s,
			}
			s = s + SPACING
		end
		travelled, ax, ay = travelled + length, bx, by
		if s > AHEAD then
			break
		end
	end
	return samples, travelled
end

local function Draw(px, py, pz, path, index)
	local camera = Camera(px, py, pz, yaw, pitch)
	local scale = frame:GetEffectiveScale()
	local samples, walk = Samples(px, py, path, index)
	local finish = math.min(AHEAD, walk)
	local phase = GetTime() * SPEED
	local shown = 0
	for _, sample in ipairs(samples) do
		-- The arrow's footprint: its tip and tail along the leg, its sides across it, projected apiece so
		-- perspective shrinks it and the view's slant flattens it.
		local x, y, dx, dy = sample.x, sample.y, sample.dx, sample.dy
		local tx, ty = Project(camera, x + dx * LENGTH / 2, y + dy * LENGTH / 2, pz, focal)
		local bx, by = Project(camera, x - dx * LENGTH / 2, y - dy * LENGTH / 2, pz, focal)
		local lx, ly = Project(camera, x - dy * WIDTH / 2, y + dx * WIDTH / 2, pz, focal)
		local rx, ry = Project(camera, x + dy * WIDTH / 2, y - dx * WIDTH / 2, pz, focal)
		if tx and bx and lx and rx then
			shown = shown + 1
			local arrow = Arrow(shown)
			local height = math.sqrt((tx - bx) ^ 2 + (ty - by) ^ 2)
			local width = math.sqrt((rx - lx) ^ 2 + (ry - ly) ^ 2)
			arrow:SetSize(math.min(width, 64) / scale, math.min(math.max(height, 2), 64) / scale)
			-- The atlas points up the screen.
			arrow:SetRotation(math.atan2(ty - by, tx - bx) - math.pi / 2)
			arrow:SetPoint("CENTER", frame, "CENTER", (tx + bx) / 2 / scale, (ty + by) / 2 / scale)
			local fade = math.min(1, (sample.s - NEAR) / FADE + 0.25, (finish - sample.s) / FADE + 0.25)
			local glow = math.max(0, math.cos((sample.s - phase) / WAVE * 2 * math.pi)) ^ 6
			arrow:SetAlpha(fade * (ALPHA + GLOW * glow))
			arrow:Show()
		end
	end
	for i = shown + 1, #arrows do
		arrows[i]:Hide()
	end
end

local function Hide()
	for _, arrow in ipairs(arrows) do
		arrow:Hide()
	end
	if readout then
		readout:SetText("")
	end
end

local function Update()
	local path, index, native = ns.GuideProgress()
	local px, py, pz, map = UnitPosition("player")
	local facing = GetPlayerFacing()
	if
		not (ns.db.trail and path and native and px and facing and C_SuperTrack.IsSuperTrackingUserWaypoint())
		or not (canaccessvalue(px) and canaccessvalue(facing))
		or map ~= path[index].map
	then
		Hide()
		return
	end
	if not focal then
		-- Taken as horizontal until mouselook measures it.
		local width = WorldFrame:GetWidth() * WorldFrame:GetEffectiveScale()
		focalDefault = width / 2 / math.tan(math.rad(tonumber(C_CVar.GetCVar("cameraFov")) or 90) / 2)
		focal = focalDefault
	end
	local calibrated = Calibrate(px, py, pz, path[index], facing)
	if calibrated or IsMouselooking() then
		-- Without the marker, mouselook still fixes yaw to your facing; otherwise draw nothing rather than guess.
		if not calibrated then
			yaw = facing
		end
		Draw(px, py, pz, path, index)
	else
		Hide()
	end
	if not ns.db.debug then
		readout:SetText("")
	else
		readout:SetFormattedText(
			"trail %s  yaw-facing %.1f°  pitch %.1f°  fov %.1f°  zoom %.1f  z %.1f",
			calibrated and "locked" or "facing",
			math.deg((yaw - facing + math.pi) % (2 * math.pi) - math.pi),
			math.deg(pitch),
			math.deg(2 * math.atan(WorldFrame:GetWidth() * WorldFrame:GetEffectiveScale() / 2 / focal)),
			GetCameraZoom(),
			pz
		)
	end
end

ns.Init(function()
	frame = CreateFrame("Frame", nil, UIParent)
	frame:SetAllPoints(WorldFrame)
	frame:SetFrameStrata("BACKGROUND")
	readout = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	readout:SetPoint("TOP", 0, -60)
	frame:SetScript("OnUpdate", Update)
end)
