-- Exercise the real compass against allocation-free UI spies, including a stopped OnUpdate.
local source = arg[1] or "Compass.lua"
local calls = { text = 0, atlas = 0, info = 0, objects = 0, points = 0 }
local atlasSizes = {
	["Waypoint-MapPin-Tracked"] = { width = 30, height = 30 },
	["Navigation-Tracked-Icon"] = { width = 23, height = 35 },
	flightmasterferry = { width = 32, height = 32 },
	["poi-door-arrow-up"] = { width = 13, height = 14 },
	["poi-door-arrow-down"] = { width = 13, height = 14 },
	["map-icon-suramardoor.tga"] = { width = 32, height = 32 },
	taxinode_alliance = { width = 21, height = 21 },
	taxinode_horde = { width = 21, height = 21 },
	taxinode_neutral = { width = 21, height = 21 },
	taxinode_undiscovered = { width = 21, height = 21 },
}
local function noop() end
local methods = {
	EnableMouse = noop,
	SetFrameStrata = noop,
	SetColorTexture = noop,
	SetVertexColor = noop,
	SetBackdropColor = noop,
	SetBackdropBorderColor = noop,
	ClearAllPoints = noop,
}
local function object()
	calls.objects = calls.objects + 1
	return setmetatable({ scripts = {}, events = {} }, { __index = methods })
end
function methods:SetSize(width, height)
	self.width, self.height = width, height
end
function methods:SetAtlas(atlas)
	assert(atlasSizes[atlas], "unverified atlas: " .. atlas)
	calls.atlas = calls.atlas + 1
	self.atlas, self.texture = atlas, nil
end
function methods:SetTexture(texture)
	self.texture, self.atlas = texture, nil
end
function methods:SetPoint(point, owner, relativePoint, x, y)
	calls.points = calls.points + 1
	self.anchorPoint, self.owner, self.relativePoint, self.x, self.y = point, owner, relativePoint, x, y
end
function methods:SetText(text)
	calls.text = calls.text + 1
	self.text = text
end
function methods:SetFormattedText(format, value)
	self:SetText(string.format(format, value))
end
function methods:SetAlpha(alpha)
	self.alpha = alpha
end
function methods:SetShown(shown)
	if shown then
		self:Show()
	else
		self:Hide()
	end
end
function methods:Show()
	local hidden = self.hidden
	self.hidden = false
	if hidden and self.scripts.OnShow then
		self.scripts.OnShow(self)
	end
end
function methods:Hide()
	if self.hidden then
		return
	end
	self.hidden = true
	if self.scripts.OnHide then
		self.scripts.OnHide(self)
	end
end
function methods:SetBackdrop(backdrop)
	self.backdrop = backdrop
end
function methods:SetScript(name, fn)
	self.scripts[name] = fn
end
function methods:RegisterEvent(event)
	self.events[event] = true
end
function methods:UnregisterAllEvents()
	for event in pairs(self.events) do
		self.events[event] = nil
	end
end
function methods.CreateTexture()
	return object()
end
function methods.CreateFontString(_, _, _, font)
	local text = object()
	text.font = font
	return text
end
local x, y, map, facing = 0, 0, 1, 0
local guided, strip = true, nil
local bend = { map = 1, x = 100, y = 0 }
local nextBend = { map = 1, x = 100, y = 100 }
local stop = { map = 1, x = 0, y = -100, kind = "taxi", id = 26 }
local goal = { map = 1, x = -100, y = 0 }
local dock = { map = 1, x = 0, y = -100, z = 10 }
local dockKind = "boat"
local ns = {
	db = { compass = true, journey = true },
	TaxiNodes = { [26] = { faction = "Alliance" } },
	IsJourneyGuided = function()
		return guided
	end,
	GuideTargets = function()
		return bend, nextBend, stop, goal
	end,
	DockPoint = function()
		return dock
	end,
	DockKind = function()
		return dockKind
	end,
}
local env = setmetatable({
	UIParent = {},
	CreateFrame = function()
		strip = object()
		return strip
	end,
	UnitPosition = function()
		return x, y, 0, map
	end,
	GetPlayerFacing = function()
		return facing
	end,
	canaccessvalue = function()
		return true
	end,
	C_Texture = {
		GetAtlasInfo = function(atlas)
			calls.info = calls.info + 1
			return assert(atlasSizes[atlas])
		end,
	},
	C_Timer = {
		NewTicker = function(interval, fn)
			return {
				interval = interval,
				fn = fn,
				Cancel = function(self)
					self.cancelled = true
				end,
			}
		end,
	},
}, { __index = _G })
setfenv(assert(loadfile(source)), env)("ShortestPathForever", ns)
local function close(actual, expected, tolerance)
	assert(math.abs(actual - expected) < (tolerance or 1e-6), tostring(actual) .. " ~= " .. tostring(expected))
end
local function step(dt)
	if strip.scripts.OnUpdate then
		strip.scripts.OnUpdate(strip, dt or 1 / 60)
	elseif strip.ticker and not strip.ticker.cancelled then
		strip.ticker.fn()
	end
end
local function settle()
	for _ = 1, 180 do
		step()
	end
	assert(not strip.scripts.OnUpdate, "settled and still compass must detach OnUpdate")
end
local function wake(event)
	assert(strip.events[event], "missing wake event")
	strip.scripts.OnEvent(strip, event)
end
ns.RefreshCompass()
close(strip.Bend.x, 0)
close(strip.Next.x, -90)
close(strip.Stop.x, 180)
assert(strip.Goal.hidden, "clamped markers at the same edge must collapse")
assert(strip.Distance.text == "100 yd")
close(strip.Bend.width / strip.Bend.height, 23 / 35)
close(strip.Next.width / strip.Next.height, 23 / 35)
close(strip.Goal.width / strip.Goal.height, 1)
assert(strip.Distance.font == "GameFontHighlightSmall")
assert(strip.backdrop.bgFile == "Interface\\Tooltips\\UI-Tooltip-Background")

-- The old 10 Hz gate leaves this first 60 Hz frame stationary.
facing = math.pi / 4
step()
assert(strip.Bend.x > 0 and strip.Bend.x < 90, "first frame must glide, without waiting 0.1 seconds or snapping")
local first = strip.Bend.x
step()
assert(strip.Bend.x > first and strip.Bend.x < 90, "every moving frame must advance")
settle()
close(strip.Bend.x, 90)
local idlePoints, idleText, idleAtlas = calls.points, calls.text, calls.atlas
for _ = 1, 30 do
	strip.ticker.fn()
end
assert(calls.points == idlePoints and calls.text == idleText and calls.atlas == idleAtlas, "idle polls must not redraw")

-- Keyboard movement wakes immediately; the poll also catches turns and boat travel without events.
wake("PLAYER_STARTED_TURNING")
assert(strip.scripts.OnUpdate)
facing = math.pi / 3
step()
assert(strip.Bend.x > 90 and strip.Bend.x < 120)
settle()
facing = math.pi / 6
strip.ticker.fn()
assert(strip.scripts.OnUpdate)
step()
assert(strip.Bend.x < 120 and strip.Bend.x > 60)
settle()
x = 1
strip.ticker.fn()
assert(strip.scripts.OnUpdate and strip.Distance.text == "99 yd")
settle()

-- North is a seam, not a full turn, and elapsed time determines decay rather than frame count.
local function startHeading(angle)
	strip:Hide()
	facing = angle
	ns.RefreshCompass()
end
x = 0
startHeading(2 * math.pi - 0.03)
facing = 0.03
step()
assert(strip.Bend.x > -0.03 * 360 / math.pi and strip.Bend.x < 0, "north wrap must take the short arc")
settle()
close(strip.Bend.x, 0.03 * 360 / math.pi)
startHeading(0.03)
facing = 2 * math.pi - 0.03
step()
assert(strip.Bend.x > 0 and strip.Bend.x < 0.03 * 360 / math.pi)
settle()
local function sample(rate)
	startHeading(0)
	facing = math.pi / 3
	for _ = 1, rate / 10 do
		step(1 / rate)
	end
	return strip.Bend.x
end
close(sample(30), sample(60))
close(sample(60), sample(120))
step(2)
settle()
close(strip.Bend.x, 120)

-- Separately allocated endpoints still represent one destination; the yards move to its surviving icon.
goal = { map = 1, x = 100, y = 0 }
stop = { map = 1, x = 100, y = 0 }
nextBend = { map = 1, x = 100, y = 0 }
startHeading(0)
assert(not strip.Goal.hidden and strip.Stop.hidden and strip.Bend.hidden and strip.Next.hidden)
assert(strip.Distance.owner == strip.Goal and strip.Distance.text == "100 yd")
-- Close bearings collapse even when their distances differ.
stop = nil
bend = { map = 1, x = 40, y = 1 }
nextBend = { map = 1, x = 50, y = 1 }
ns.RefreshCompass()
assert(strip.Bend.hidden and strip.Next.hidden and strip.Distance.owner == strip.Goal)
assert(strip.Distance.text == "40 yd")
bend = { map = 1, x = 0, y = 50 }
nextBend = { map = 1, x = 100, y = 100 }
ns.RefreshCompass()
assert(not strip.Bend.hidden and not strip.Next.hidden and strip.Distance.owner == strip.Bend)
-- A dock uses its map pin's coordinates and retains its more specific transport art.
stop = { kind = "dock", id = 1 }
bend, nextBend, goal = dock, nil, { map = 1, x = dock.x, y = dock.y, z = dock.z }
ns.RefreshCompass()
assert(not strip.Stop.hidden and strip.Goal.hidden and strip.Bend.hidden)
assert(strip.Distance.owner == strip.Stop and strip.Distance.text == "100 yd")
for _, kind in ipairs({ "boat", "lift", "tram", "portal", "zeppelin", "boat" }) do
	dockKind = kind
	ns.RefreshCompass()
	local ratio = (kind == "lift" or kind == "tram") and 13 / 14 or 1
	close(strip.Stop.width / strip.Stop.height, ratio)
end
stop = { kind = "taxi", id = 26, map = 1, x = 0, y = -100 }
ns.RefreshCompass()
assert(strip.Stop.atlas == "taxinode_alliance")
stop.undiscovered = true
step()
assert(strip.Stop.atlas == "taxinode_undiscovered", "in-place discovery changes must refresh art")

-- Sampling moving bearings does not allocate, recreate regions, or repeatedly set unchanged art/text.
bend, nextBend, stop, goal = { map = 1, x = 100, y = 0 }, nil, nil, nil
startHeading(0)
step()
local objects, textCount, atlasCount, infos = calls.objects, calls.text, calls.atlas, calls.info
-- Exclude JIT trace compilation from the Lua allocation measurement.
jit.off()
jit.flush()
local function turn(count)
	for i = 1, count do
		facing = i * 0.0001
		strip.scripts.OnUpdate(strip, 1 / 60)
	end
end
turn(1000)
collectgarbage("collect")
collectgarbage("stop")
local before = collectgarbage("count")
turn(10000)
local allocated = collectgarbage("count") - before
collectgarbage("restart")
assert(allocated < 1, "per-frame allocation: " .. allocated .. " KB")
assert(calls.objects == objects and calls.text == textCount and calls.atlas == atlasCount and calls.info == infos)
print(string.format("compass: 10000 moving frames, %.3f KB allocated, no text/atlas writes or new regions", allocated))

map = 0
step()
assert(strip.Bend.hidden and strip.Distance.hidden, "cross-map points cannot have a bearing")
map, x = 1, nil
step()
assert(strip.alpha == 0 and not strip.scripts.OnUpdate)
x = 0
strip.ticker.fn()
assert(strip.alpha == 1 and not strip.Bend.hidden)
wake("PLAYER_ENTERING_WORLD")
assert(strip.scripts.OnUpdate)
local timer = strip.ticker
ns.db.compass = false
ns.RefreshCompass()
assert(strip.hidden and not strip.scripts.OnUpdate and timer.cancelled and not next(strip.events))
ns.db.compass = true
ns.RefreshCompass()
assert(not strip.hidden and strip.ticker ~= timer and not strip.ticker.cancelled)
ns.db.journey = false
step()
assert(strip.hidden and not strip.scripts.OnUpdate and not strip.ticker)
ns.db.journey = true
ns.RefreshCompass()
guided = false
step()
assert(strip.hidden and not strip.scripts.OnUpdate and not strip.ticker)
print("compass: smooth frames, wrap, frame rates, deduplication, atlas aspect, sleep/wake and visibility: ok")
