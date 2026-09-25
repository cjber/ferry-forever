-- The journey's breadcrumbs stop a little short of each stop's mark, on the world map at any zoom and on the minimap,
-- and a place the route visits twice shows one ring: the first visit's number with a +N corner count.
local checks = 0
local function check(value, label)
	checks = checks + 1
	assert(value, label)
end

local UI_SCALE, CANVAS, MINIMAP, DOT, RIM, GAP, SPACING = 1, 1000, 140, 4, 1, 2, 9
local canvasScale = 2

-- Regions record what the route sets on them; any other method is a no-op returning another stub.
local region = {}
local function stub(fields)
	return setmetatable(fields or {}, region)
end
region.__index = function(_, key)
	if region[key] then
		return region[key]
	end
	if key:match("^%u") then
		return function()
			return stub()
		end
	end
end
function region:SetText(text)
	self.text = text
end
function region:SetAtlas(atlas)
	self.atlas = atlas
end
function region:SetSize(width, height)
	self.width, self.height = width, height
end
function region:GetWidth()
	return self.width
end
function region:GetHeight()
	return self.height
end
function region:SetAllPoints(other)
	self.width, self.height = other.width, other.height
end
function region:GetEffectiveScale()
	return self.scale or UI_SCALE
end
function region:SetStartPoint(_, _, x, y)
	self.start = { x, y }
end
function region:SetEndPoint(_, _, x, y)
	self.finish = { x, y }
end
function region:Show()
	self.shown = true
end
function region:Hide()
	self.shown = false
end
function region:SetShown(shown)
	self.shown = shown
end
function region:IsShown()
	return self.shown
end
function region.CreateLine()
	return stub()
end
function region.CreateFontString()
	return stub()
end
function region.CreateTexture()
	return stub()
end

local ns = { db = { journey = true }, Planner = {} }
local stops, preview, player = nil, {}, nil
function ns.Init(fn)
	ns.init = fn
end
function ns.JourneyStops()
	return stops, 1
end
function ns.JourneyPreview()
	return preview
end
function ns.JourneyPosition()
	return player.x, player.y, 0, player.map
end
function ns.Planner.LegPoints(leg)
	return leg.points
end
-- Map.lua's grouping, reduced to what this route needs: marks at one place share a ring.
function ns.OverlapGroups(_, marks)
	local groups, at = {}, {}
	for _, mark in ipairs(marks) do
		local key = mark.x .. "," .. mark.y
		if not at[key] then
			at[key] = {}
			groups[#groups + 1] = at[key]
		end
		table.insert(at[key], mark)
	end
	return groups
end

local active, provider, named = {}, nil, {}
local map = stub()
function map.GetMapID()
	return 1432
end
function map.IsVisible()
	return true
end
function map.GetCanvas()
	return stub({ width = CANVAS, height = CANVAS })
end
function map.GetCanvasScale()
	return canvasScale
end
function map.RemoveAllPinsByTemplate(_, template)
	active[template] = {}
end
function map.AcquirePin(_, template, ...)
	local pin = stub({ Texture = stub(), Icon = stub(), Disc = stub(), Numeral = stub(), Glow = stub() })
	for key, value in pairs(_G[template:gsub("Template$", "Mixin")]) do
		pin[key] = value
	end
	function pin.GetMap()
		return map
	end
	function pin.GetEffectiveScale()
		-- MapCanvasPinMixin scales a pin with scaling limits by 1 / canvas scale; the route's strokes zoom with the map.
		return template:match("Route") and UI_SCALE * canvasScale or UI_SCALE
	end
	active[template] = active[template] or {}
	table.insert(active[template], pin)
	pin:OnLoad()
	pin:OnAcquired(...)
	return pin
end

local env = setmetatable({
	CreateColor = function(r, g, b)
		return {
			GetRGBA = function()
				return r, g, b, 1
			end,
		}
	end,
	CreateFromMixins = function(...)
		local mixed = {}
		for _, mixin in ipairs({ ... }) do
			for key, value in pairs(mixin) do
				mixed[key] = value
			end
		end
		return mixed
	end,
	CreateVector2D = function(x, y)
		return {
			GetXY = function()
				return x, y
			end,
		}
	end,
	CreateFrame = function(_, name, parent)
		local frame = stub({ width = parent and parent.width, height = parent and parent.height })
		if name then
			named[name] = frame
		end
		return frame
	end,
	MapCanvasPinMixin = { OnReleased = function() end },
	MapCanvasDataProviderMixin = {
		GetMap = function()
			return map
		end,
	},
	WorldMapFrame = {
		AddDataProvider = function(_, added)
			provider = added
		end,
		IsShown = function()
			return true
		end,
		EnumeratePinsByTemplate = function(_, template)
			local i = 0
			return function()
				i = i + 1
				return (active[template] or {})[i]
			end
		end,
	},
	Minimap = stub({ width = MINIMAP, height = MINIMAP }),
	-- Map fractions stand in for world yards, so one set of points serves both maps.
	C_Map = {
		GetMapPosFromWorldPos = function(_, point, mapID)
			return mapID, point
		end,
		GetMapInfo = function()
			return { mapType = 3 }
		end,
	},
	C_Minimap = {
		GetViewRadius = function()
			return 0.5
		end,
	},
	C_Texture = {
		GetAtlasInfo = function()
			return { width = 32, height = 32 }
		end,
	},
	Enum = { UIMapType = { Continent = 2 } },
	GetCVar = function()
		return "0"
	end,
	canaccessvalue = function()
		return true
	end,
}, { __index = _G })
env.NORMAL_FONT_COLOR, env.ORANGE_FONT_COLOR = env.CreateColor(1, 0.82, 0), env.CreateColor(1, 0.5, 0.25)
for _, file in ipairs({ "StopPin.lua", "Route.lua" }) do
	setfenv(assert(loadfile(file)), env)("ShortestPathForever", ns)
end
for key, value in pairs(env) do
	if type(key) == "string" and key:match("^ShortestPathForever") then
		_G[key] = value
	end
end
ns.init()

-- Stop 3 goes back to stop 1's place: the route walks there, on to stop 2, and back.
local first, second = { map = 0, x = 0.3, y = 0.5 }, { map = 0, x = 0.5, y = 0.5 }
player = { map = 0, x = 0.1, y = 0.5 }
stops = {
	{ map = 0, x = 0.3, y = 0.5, routeTitle = "Stop 1 of 3: Quest giver" },
	{ map = 0, x = 0.5, y = 0.5, routeTitle = "Stop 2 of 3: Camp" },
	{ map = 0, x = 0.3, y = 0.5, routeTitle = "Stop 3 of 3: Quest giver" },
}
preview = { { mode = "walk", points = { first, second, first } } }
ns.SetJourneyRoute(stops[1], { legs = { { mode = "walk", points = { player, first } } } })

local rings = active.ShortestPathForeverGoalPinTemplate
check(#rings == 2, "the place visited twice shares one ring")
check(rings[1].Numeral.atlas == "services-number-1" and rings[1].Count.text == "+1", "first visit's number, +1")
check(rings[1].stopTitles[1] == stops[1].routeTitle and rings[1].stopTitles[2] == stops[3].routeTitle)
check(rings[2].Numeral.atlas == "services-number-2" and rings[2].Count.text == "", "a single visit has no count")

-- Dot centres, in the owner's units.
local function dots(owner)
	local centres = {}
	for i = 1, owner.used do
		local line = owner.lines[i]
		if owner.dots[i] and line.shown then
			centres[#centres + 1] = { (line.start[1] + line.finish[1]) / 2, (line.start[2] + line.finish[2]) / 2 }
		end
	end
	return centres
end
-- Every dot's rim stays GAP clear of the mark, and the nearest dot is within one spacing of that.
local function clears(owner, cx, cy, radius, scale, label)
	local reach, nearest = radius + (GAP + DOT / 2 + RIM) / scale, math.huge
	for _, dot in ipairs(dots(owner)) do
		nearest = math.min(nearest, math.sqrt((dot[1] - cx) ^ 2 + (dot[2] - cy) ^ 2))
	end
	check(nearest >= reach, label .. ": a dot runs under the mark")
	check(nearest < reach + SPACING / scale, label .. ": the dots stop well short of the mark")
end

local line = active.ShortestPathForeverRoutePinTemplate[1]
for _, zoom in ipairs({ 2, 0.5 }) do
	canvasScale = zoom
	provider:OnCanvasScaleChanged()
	line:OnCanvasScaleChanged()
	local scale = UI_SCALE * zoom
	for _, place in ipairs({ first, second }) do
		clears(line, place.x * CANVAS, -place.y * CANVAS, 13 / zoom, scale, "world map at " .. zoom)
	end
end

-- On the minimap, the dots stop short of the ring around the stop's own icon.
local minimap = named.ShortestPathForeverMinimapRoute
check(minimap.Goal.shown, "the stop shows on the minimap")
-- The stop is 0.2 north of the player in a 0.5 view radius: 0.4 of the way from centre to rim.
clears(minimap, MINIMAP / 2, -MINIMAP / 2 + 0.4 * MINIMAP / 2, 16 / 2, UI_SCALE, "minimap")

print(string.format("route_spec: %d checks ok", checks))
