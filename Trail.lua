local _, ns = ...

-- Guide's route drawn on the ground ahead of you as faint dots. Addons get no world-to-screen projection, but the
-- native navigation marker is one: the game projects Guide's waypoint every frame, and where it lands pins down the
-- camera's yaw and pitch. GetCameraZoom gives its distance behind your head, so the walk's next few dozen yards
-- project onto the screen. Heights come from the walking map, so the dots lie on slopes and the waypoint is
-- calibrated at its own ground rather than at your feet.

local AHEAD, SPACING, NEAR, FADE = 40, 4, 6, 4 -- yards drawn, between dots, clear of you, fading in and out
local HEAD = 2 -- the camera orbits this far above your feet, in yards
local DOT = 0.5 -- a dot's diameter on the ground, in yards
local ALPHA = 0.45
local COLOR = { 1, 0.82, 0 } -- the route's walking gold
local ITERATIONS = 5
local STEP = 1e-4
local SETTLE = 3 -- frames the marker gets to follow a moved waypoint
local MEASURE = 150 -- pixels off centre the marker must be to measure the focal length

local frame, readout
local dots = {}
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
local function Calibrate(px, py, pz, target, tz, facing)
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
		local sx, sy = Project(Camera(px, py, pz, cameraYaw, cameraPitch), target.x, target.y, tz, f)
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

local function Dot(i)
	local dot = dots[i]
	if not dot then
		dot = frame:CreateTexture(nil, "BACKGROUND")
		dot:SetColorTexture(COLOR[1], COLOR[2], COLOR[3])
		local mask = frame:CreateMaskTexture()
		mask:SetAtlas("CircleMaskScalable")
		mask:SetAllPoints(dot)
		dot:AddMaskTexture(mask)
		dots[i] = dot
	end
	return dot
end

-- Where you are on the walk: the nearest point of its nearest segment, and the index of that segment's end.
local function Nearest(px, py, path)
	local best, bx, by, after = nil, px, py, 2
	for i = 2, #path do
		local a, b = path[i - 1], path[i]
		local dx, dy = b.x - a.x, b.y - a.y
		local length = dx * dx + dy * dy
		local t = length > 0 and math.max(0, math.min(1, ((px - a.x) * dx + (py - a.y) * dy) / length)) or 0
		local x, y = a.x + t * dx, a.y + t * dy
		local off = (x - px) ^ 2 + (y - py) ^ 2
		if not best or off < best then
			best, bx, by, after = off, x, y, i
		end
	end
	return bx, by, after
end

-- Points every SPACING yards along the walk still ahead, from where you are on it through the remaining bends.
local function Samples(px, py, path)
	local ax, ay, index = Nearest(px, py, path)
	local samples, travelled, s = {}, 0, NEAR
	for i = index, #path do
		local bx, by = path[i].x, path[i].y
		local length = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
		while length > 0 and s <= travelled + length and s <= AHEAD do
			local t = (s - travelled) / length
			samples[#samples + 1] = { x = ax + (bx - ax) * t, y = ay + (by - ay) * t, s = s }
			s = s + SPACING
		end
		travelled, ax, ay = travelled + length, bx, by
		if s > AHEAD then
			break
		end
	end
	return samples, travelled
end

local function Draw(px, py, pz, map, path)
	local camera = Camera(px, py, pz, yaw, pitch)
	local scale = frame:GetEffectiveScale()
	local samples, walk = Samples(px, py, path)
	local finish = math.min(AHEAD, walk)
	local shown, z = 0, pz
	local fx, fy = math.cos(yaw), math.sin(yaw)
	for _, sample in ipairs(samples) do
		-- Each height is taken nearest the last, so the dots follow the level you walk on.
		z = ns.Path.Ground(map, sample.x, sample.y, z) or z
		local x, y = sample.x, sample.y
		-- A disc on the ground: its extent across the view and along it, projected apiece so perspective shrinks it
		-- and the view's slant flattens it.
		local cx, cy = Project(camera, x, y, z, focal)
		local lx = Project(camera, x - fy * DOT / 2, y + fx * DOT / 2, z, focal)
		local rx = Project(camera, x + fy * DOT / 2, y - fx * DOT / 2, z, focal)
		local _, ny = Project(camera, x - fx * DOT / 2, y - fy * DOT / 2, z, focal)
		local _, far = Project(camera, x + fx * DOT / 2, y + fy * DOT / 2, z, focal)
		if cx and lx and rx and ny and far then
			shown = shown + 1
			local dot = Dot(shown)
			dot:SetSize(math.min(math.abs(rx - lx), 48) / scale, math.min(math.max(math.abs(far - ny), 1), 48) / scale)
			dot:SetPoint("CENTER", frame, "CENTER", cx / scale, cy / scale)
			dot:SetAlpha(ALPHA * math.min(1, (sample.s - NEAR) / FADE + 0.25, (finish - sample.s) / FADE + 0.25))
			dot:Show()
		end
	end
	for i = shown + 1, #dots do
		dots[i]:Hide()
	end
end

local function Hide()
	for _, dot in ipairs(dots) do
		dot:Hide()
	end
	if readout then
		readout:SetText("")
	end
end

local function Update()
	local path, target, native = ns.GuideProgress()
	local px, py, pz, map = UnitPosition("player")
	local facing = GetPlayerFacing()
	if
		not (ns.db.trail and path and native and px and facing and C_SuperTrack.IsSuperTrackingUserWaypoint())
		or not (canaccessvalue(px) and canaccessvalue(facing))
		or map ~= target.map
		or not (ns.Path and ns.Path.HasData(map))
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
	local tz = ns.Path.Ground(map, target.x, target.y, target.z or pz) or pz
	local calibrated = Calibrate(px, py, pz, target, tz, facing)
	if calibrated or IsMouselooking() then
		-- Without the marker, mouselook still fixes yaw to your facing; otherwise draw nothing rather than guess.
		if not calibrated then
			yaw = facing
		end
		Draw(px, py, pz, map, path)
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
