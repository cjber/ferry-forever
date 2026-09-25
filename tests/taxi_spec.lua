local ns = {}
function ns.Init(fn)
	ns.init = fn
end

local current, reachable, unreachable = 0, 1, 2
local mapNodes = {
	{ nodeID = 103, slotIndex = 1, state = reachable },
	{ nodeID = 101, slotIndex = 3, state = current },
	{ nodeID = 102, slotIndex = 4, state = reachable },
}
local nodeTypes = { "REACHABLE", "DISTANT", "CURRENT", "REACHABLE" }
-- The client's chosen route deliberately differs from the planner's intermediate hop.
local routes = { [1] = { { 3, 2 }, { 2, 1 } }, [4] = { { 3, 4 } } }
local textures, eventFrame = {}, nil
local tooltip, stockDraws, routeQueries = false, 0, 0
local region = {}
region.__index = region
local function widget(fields)
	local value = fields or {}
	value.scripts, value.hooks = {}, {}
	return setmetatable(value, region)
end
function region:SetScript(event, fn)
	assert(event ~= "OnUpdate", "taxi guidance must not poll")
	self.scripts[event] = fn
end
function region:HookScript(event, fn)
	assert(not self.hooks[event], "hook each button only once")
	self.hooks[event] = fn
end
function region:Run(event, ...)
	if self.scripts[event] then
		self.scripts[event](self, ...)
	end
	if self.hooks[event] then
		self.hooks[event](self, ...)
	end
end
function region:RegisterEvent(event)
	self.events = self.events or {}
	self.events[event] = true
end
function region:IsShown()
	return self.shown
end
function region:Show()
	if not self.shown then
		self.shown = true
		self:Run("OnShow")
	end
end
function region:Hide()
	if self.shown then
		self.shown = false
		self:Run("OnHide")
	end
end
function region:GetID()
	return self.id
end
function region:GetPoint()
	return "CENTER", "TaxiMap", "BOTTOMLEFT", self.x, self.y
end
function region:LockHighlight()
	self.locked = true
end
function region:UnlockHighlight()
	self.locked = false
end
function region:SetTexture(path)
	self.path = path
end
function region.CreateTexture(_, name, layer)
	assert(name == nil and layer == "BACKGROUND", "addon lines do not replace stock named textures")
	local texture = widget()
	textures[#textures + 1] = texture
	return texture
end

local env = setmetatable({
	Enum = { FlightPathState = { Current = current, Reachable = reachable, Unreachable = unreachable } },
	C_TaxiMap = {
		GetAllTaxiNodes = function(map)
			assert(map == 99, "only query the current flight master's map")
			return mapNodes
		end,
	},
	GetTaxiMapID = function()
		return 99
	end,
	NumTaxiNodes = function()
		return #nodeTypes
	end,
	TaxiNodeGetType = function(slot)
		return nodeTypes[slot]
	end,
	GetNumRoutes = function(slot)
		routeQueries = routeQueries + 1
		return #(routes[slot] or {})
	end,
	TaxiGetNodeSlot = function(slot, hop, source)
		return routes[slot][hop][source and 1 or 2]
	end,
	TaxiNodeName = function()
		error("never match by name")
	end,
	TaxiNodePosition = function()
		error("never guess a slot from unverified coordinates")
	end,
	TakeTaxiNode = function()
		error("never fly automatically")
	end,
	TaxiFrame = widget(),
	TaxiRouteMap = widget(),
	NUM_TAXI_ROUTES = 1,
	TAXIROUTE_LINEFACTOR = 32 / 30,
	TaxiRoute1 = widget(),
	CreateFrame = function()
		eventFrame = widget()
		return eventFrame
	end,
	DrawLine = function(line, canvas, sx, sy, dx, dy, width, factor)
		assert(canvas == "TaxiRouteMap" and width == 32 and factor == 32 / 30, "stock line drawing parameters")
		line.points = { sx, sy, dx, dy }
	end,
	hooksecurefunc = function(target, key, fn)
		assert(
			target == ns and (key == "SetJourneyRoute" or key == "JourneyChanged"),
			"only hook journey notifications"
		)
		local original = assert(target[key])
		target[key] = function(...)
			original(...)
			fn(...)
		end
	end,
}, { __index = _G })
env._G = env
function env.DrawOneHopLines()
	stockDraws = stockDraws + 1
	env.TaxiRoute1:Show()
	for slot, kind in ipairs(nodeTypes) do
		if kind == "DISTANT" then
			env["TaxiButton" .. slot]:Hide()
		end
	end
end
for slot = 1, #nodeTypes do
	local button = widget({ id = slot, x = slot * 20, y = slot * 30 })
	env["TaxiButton" .. slot] = button
	button:SetScript("OnEnter", function()
		tooltip = true
		if nodeTypes[slot] ~= "DISTANT" then
			env.DrawOneHopLines()
		end
	end)
	button:SetScript("OnLeave", function()
		tooltip = false
		env.TaxiRoute1:Hide()
	end)
end
env.TaxiFrame:SetScript("OnShow", function()
	for slot, kind in ipairs(nodeTypes) do
		local button = env["TaxiButton" .. slot]
		if kind ~= "DISTANT" and kind ~= "NONE" then
			button:Show()
		end
	end
	env.DrawOneHopLines()
end)

setfenv(assert(loadfile("Taxi.lua")), env)("ShortestPathForever", ns)
local flight = {
	mode = "flight",
	from = { id = 101 },
	to = { id = 103 },
	hops = { { from = 101, to = 102 }, { from = 102, to = 103 } },
}
local walk = { mode = "walk" }
assert(ns.TaxiDestination({ flight }, 101) == 103, "origin on route selects the merged leg's final node")
assert(ns.TaxiDestination({ flight }, 102) == 103, "origin midway through merged hops selects the final node")
assert(ns.TaxiDestination({ flight }, 999) == nil, "origin off the route selects nothing")
assert(ns.TaxiDestination({ flight }, 103) == nil, "already at the final node")
assert(ns.TaxiDestination({ walk, flight }, 101) == 103, "the approach walk can still be current")
assert(ns.TaxiDestination({ walk, walk, flight }, 101) == nil, "a later flight is not the next step")
assert(ns.TaxiDestination({ { mode = "boat" }, flight }, 101) == nil, "do not skip a transport to offer a flight")
assert(ns.TaxiDestination(nil, 101) == nil and ns.TaxiDestination({}, 101) == nil)

ns.db = { taxiRoute = true }
ns.TaxiNodes = { [101] = {}, [102] = {}, [103] = {} }
ns.SetJourneyRoute = function() end
ns.JourneyChanged = function() end
ns.init()
local function event(name)
	assert(eventFrame.events[name])
	eventFrame:Run("OnEvent", name)
end
local function publish(legs, destination)
	ns.SetJourneyRoute(destination or {}, { legs = legs or { walk, flight } })
end
local function visibleLines()
	local count = 0
	for _, texture in ipairs(textures) do
		if texture:IsShown() then
			count = count + 1
		end
	end
	return count
end
local target = env.TaxiButton1
publish()
assert(routeQueries == 0, "a closed map does no route work")
event("TAXIMAP_OPENED")
env.TaxiFrame:Show()
assert(
	visibleLines() == 2 and target.locked and not tooltip,
	"opening draws all hops and lights the destination without a tooltip"
)
assert(
	not env.TaxiRoute1:IsShown() and env.TaxiButton2:IsShown(),
	"replace stock one-hop lines and reveal a distant connection"
)
assert(ns.KnownTaxiNodes()[103], "flight discovery still runs")
assert(textures[1].path == "Interface\\TaxiFrame\\UI-Taxi-Line")
assert(table.concat(textures[1].points, ",") == "60,90,40,60", "first client hop uses displayed button anchors")
assert(
	table.concat(textures[2].points, ",") == "40,60,20,30",
	"second client hop reaches the mapped slot, not the first planner hop"
)

local other = env.TaxiButton4
other:Run("OnEnter")
assert(tooltip and visibleLines() == 0 and env.TaxiRoute1:IsShown(), "stock hover owns the lines and tooltip")
local before = stockDraws
publish()
assert(stockDraws == before and visibleLines() == 0 and tooltip, "a journey refresh does not fight hover")
other:Run("OnLeave")
assert(not tooltip and visibleLines() == 2 and target.locked, "restore after the stock leave handler clears lines")
assert(#textures == 2, "reuse the line pool")

env.TaxiButton2:Run("OnEnter")
assert(visibleLines() == 2, "stock distant-node hover retains the existing route")
ns.JourneyChanged({})
assert(visibleLines() == 0 and not target.locked, "a replacement clears even during distant-node hover")
env.TaxiButton2:Run("OnLeave")
assert(env.TaxiRoute1:IsShown() and not env.TaxiButton2:IsShown(), "restore stock nodes after a cleared hovered route")
publish()
ns.db.taxiRoute = false
ns.RefreshTaxiRoute()
assert(visibleLines() == 0 and not target.locked and env.TaxiRoute1:IsShown(), "setting off restores the stock map")
ns.db.taxiRoute = true
ns.RefreshTaxiRoute()
assert(visibleLines() == 2 and target.locked)

publish({ { mode = "flight", from = { id = 101 }, to = { id = 102 } } })
assert(visibleLines() == 1 and not target.locked and other.locked, "a changed leg clears the old glow and surplus hop")
ns.SetJourneyRoute(nil)
assert(visibleLines() == 0 and not other.locked, "ending the journey clears everything")
publish(nil, { corpse = true })
assert(visibleLines() == 0, "a corpse route does not revive a waiting flight")
ns.SetJourneyRoute({}, { legs = { flight }, preview = true })
assert(visibleLines() == 0, "a preview is not a committed flight")
publish()

mapNodes[1].slotIndex = nil
mapNodes[1].name, mapNodes[1].x, mapNodes[1].y = "Same name", 0.2, 0.3
event("TAXI_NODE_STATUS_CHANGED")
assert(visibleLines() == 0 and not target.locked, "missing slot never falls back to a name or unrelated coordinates")
mapNodes[1].slotIndex = 1
mapNodes[1].state = unreachable
event("TAXI_NODE_STATUS_CHANGED")
assert(visibleLines() == 0, "an unreachable destination is not offered")
mapNodes[1].state = reachable
nodeTypes[1] = "UNREACHABLE"
event("TAXI_NODE_STATUS_CHANGED")
assert(visibleLines() == 0, "both client views must say reachable")
nodeTypes[1] = "REACHABLE"
mapNodes[2].nodeID = 999
event("TAXI_NODE_STATUS_CHANGED")
assert(visibleLines() == 0, "an unrelated flight master draws nothing")
mapNodes[2].nodeID = 101
routes[1] = {}
event("TAXI_NODE_STATUS_CHANGED")
assert(visibleLines() == 0 and not target.locked, "no client route means no highlight")
routes[1] = { { 3, 2 }, { 0, 1 } }
ns.RefreshTaxiRoute()
assert(visibleLines() == 0 and not target.locked, "an incomplete client route is never partially drawn")
routes[1] = { { 3, 2 }, { 2, 1 } }
ns.RefreshTaxiRoute()
assert(visibleLines() == 2)

event("TAXIMAP_CLOSED")
assert(visibleLines() == 0 and not target.locked, "closed event clears before the frame hides")
env.TaxiFrame:Hide()
env.TaxiFrame:Show()
event("TAXIMAP_OPENED")
assert(visibleLines() == 2 and target.locked, "also support open events after the stock OnShow")
env.TaxiFrame:Hide()
assert(visibleLines() == 0 and not target.locked, "hiding the frame clears without waiting for the event")

print("taxi_spec: ok")
