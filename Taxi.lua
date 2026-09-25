---@class SPFNamespace
local ns = select(2, ...)

-- The flight points this character knows, for the journey planner and the map's flight master pins. Only a
-- flight master's own map says which nodes a character can fly to: the world map's taxi query answers anywhere
-- but reports every node as discovered on this client (the other faction's included), so it is not a source.

-- Lists built from that query before it was dropped; they claim every node, so start again from empty.
local KNOWN_VERSION = 2

---@type SPFLeg[]?
local journeyLegs
---@type TaxiNodeInfo[]
local mapNodes = {}
---@type Texture[]
local lines = {}
---@type Button?
local highlighted, hovered
local ownsMap = false
local hookedFrame
local hookedButtons = {}

-- The displayed legs already start at the journey's progress. Only the flight being taken, or the one
-- immediately after its approach walk, belongs on this flight master's map.
---@param legs SPFLeg[]?
---@param origin number
---@return number?
function ns.TaxiDestination(legs, origin)
	if not legs then
		return nil
	end
	local leg = legs[1]
	if leg and leg.mode == "walk" then
		leg = legs[2]
	end
	if not leg or leg.mode ~= "flight" or leg.to.id == origin then
		return nil
	end
	if leg.from.id == origin then
		return leg.to.id
	end
	for _, hop in ipairs(leg.hops or {}) do
		if hop.from == origin then
			return leg.to.id
		end
	end
	return nil
end

local function HideLines()
	for _, line in ipairs(lines) do
		line:Hide()
	end
end

local function ClearRoute(restore)
	HideLines()
	if highlighted then
		highlighted:UnlockHighlight()
		highlighted = nil
	end
	if ownsMap and not hovered then
		ownsMap = false
		if restore and TaxiFrame:IsShown() then
			DrawOneHopLines()
		end
	end
end

local function DestinationSlot()
	local origin
	for _, node in ipairs(mapNodes) do
		if node.state == Enum.FlightPathState.Current then
			if origin or not node.slotIndex or TaxiNodeGetType(node.slotIndex) ~= "CURRENT" then
				return nil
			end
			origin = node.nodeID
		end
	end
	local destination = origin and ns.TaxiDestination(journeyLegs, origin)
	for _, node in ipairs(mapNodes) do
		if node.nodeID == destination and node.state == Enum.FlightPathState.Reachable then
			-- World-map positions and TaxiNodePosition have no verified shared coordinate provenance here.
			-- Without the current flight master's slotIndex, neither names nor proximity identify a button.
			local slot = node.slotIndex
			if
				slot
				and slot >= 1
				and slot <= NumTaxiNodes()
				and slot % 1 == 0
				and TaxiNodeGetType(slot) == "REACHABLE"
			then
				return slot
			end
		end
	end
	return nil
end

---@param slot number
---@return Button?, number?, number?
local function ButtonPosition(slot)
	if not slot or slot < 1 or slot > NumTaxiNodes() or TaxiNodeGetType(slot) == "NONE" then
		return nil
	end
	local button = _G["TaxiButton" .. slot]
	if not button then
		return nil
	end
	-- TaxiFrame_OnShow displaces overlapping nodes, then anchors their centres here. Its private
	-- taxiNodePositions table is inaccessible; these anchors keep lines on the displayed buttons.
	local point, _, relativePoint, x, y = button:GetPoint(1)
	if point == "CENTER" and relativePoint == "BOTTOMLEFT" then
		return button, x, y
	end
	return nil
end

function ns.RefreshTaxiRoute()
	if not TaxiFrame or not TaxiFrame:IsShown() then
		return
	end
	local slot = ns.db.taxiRoute and DestinationSlot()
	if not slot then
		ClearRoute(true)
		return
	end
	local button = _G["TaxiButton" .. slot]
	if not button or not button:IsShown() or GetNumRoutes(slot) == 0 then
		ClearRoute(true)
		return
	end
	-- TaxiNodeOnButtonEnter also opens GameTooltip. Use its hop query, DrawLine and line art alone,
	-- in our own texture pool so the stock route globals and click handler remain untouched.
	local segments = {}
	local previous
	for hop = 1, GetNumRoutes(slot) do
		local from, to = TaxiGetNodeSlot(slot, hop, true), TaxiGetNodeSlot(slot, hop, false)
		local source, sx, sy = ButtonPosition(from)
		local target, dx, dy = ButtonPosition(to)
		if
			not source
			or not target
			or (previous and from ~= previous)
			or (not previous and TaxiNodeGetType(from) ~= "CURRENT")
		then
			ClearRoute(true)
			return
		end
		segments[#segments + 1] = { sx = sx, sy = sy, dx = dx, dy = dy, slot = to, button = target }
		previous = to
	end
	if previous ~= slot then
		ClearRoute(true)
		return
	end
	if highlighted ~= button then
		ClearRoute(true)
		highlighted = button
		button:LockHighlight()
	end
	if hovered then
		return
	end
	HideLines()
	DrawOneHopLines()
	for index = 1, NUM_TAXI_ROUTES do
		_G["TaxiRoute" .. index]:Hide()
	end
	for index, segment in ipairs(segments) do
		local line = lines[index]
		if not line then
			line = TaxiRouteMap:CreateTexture(nil, "BACKGROUND")
			line:SetTexture("Interface\\TaxiFrame\\UI-Taxi-Line")
			lines[index] = line
		end
		DrawLine(line, "TaxiRouteMap", segment.sx, segment.sy, segment.dx, segment.dy, 32, TAXIROUTE_LINEFACTOR)
		line:Show()
		if TaxiNodeGetType(segment.slot) == "DISTANT" then
			segment.button:Show()
		end
	end
	ownsMap = true
end

-- `/path debug`: what the game's taxi queries return, to check how this client reports known flight points.
local function Log(key, uiMap, nodes)
	if not ns.db.debug then
		return
	end
	local rows = {}
	for _, node in ipairs(nodes) do
		rows[#rows + 1] = string.format(
			"%d %s undiscovered=%s state=%s",
			node.nodeID,
			node.name,
			tostring(node.isUndiscovered),
			tostring(node.state)
		)
	end
	ns.db.taxiLog = ns.db.taxiLog or {}
	ns.db.taxiLog[key .. uiMap] = {
		seen = GetServerTime(),
		showsNodes = C_TaxiMap.ShouldMapShowTaxiNodes(uiMap),
		nodes = rows,
	}
end

-- At a flight master, every node it can fly to is known (absence never unlearns one).
local function ScanFlightMaster()
	local uiMap = GetTaxiMapID and GetTaxiMapID()
	local nodes = uiMap and C_TaxiMap.GetAllTaxiNodes(uiMap) or {}
	mapNodes = nodes
	if uiMap then
		Log("master", uiMap, nodes)
	end
	for _, node in ipairs(nodes) do
		if node.state ~= Enum.FlightPathState.Unreachable and ns.TaxiNodes[node.nodeID] then
			ns.charDB.taxi[node.nodeID] = true
		end
	end
end

-- Empty until the character opens a flight master: the planner then walks rather than guessing at flights.
---@return table<number, boolean>
function ns.KnownTaxiNodes()
	return ns.charDB.taxi
end

local function Closed()
	hovered, mapNodes = nil, {}
	ClearRoute(false)
end

local function Shown()
	ScanFlightMaster()
	for slot = 1, NumTaxiNodes() do
		local button = _G["TaxiButton" .. slot]
		if button and not hookedButtons[button] then
			hookedButtons[button] = true
			button:HookScript("OnEnter", function(self)
				hovered = self
				-- Stock hover leaves the previous route in place for a distant, non-clickable node.
				if TaxiNodeGetType(self:GetID()) ~= "DISTANT" then
					HideLines()
					ownsMap = false
				end
			end)
			button:HookScript("OnLeave", function(self)
				if hovered == self then
					hovered = nil
				end
				ns.RefreshTaxiRoute()
			end)
		end
	end
	ns.RefreshTaxiRoute()
end

local function HookTaxiFrame()
	if TaxiFrame and hookedFrame ~= TaxiFrame then
		hookedFrame = TaxiFrame
		TaxiFrame:HookScript("OnShow", Shown)
		TaxiFrame:HookScript("OnHide", Closed)
	end
end

ns.Init(function()
	ShortestPathForeverCharDB = ShortestPathForeverCharDB or {}
	ns.charDB = ShortestPathForeverCharDB
	if ns.charDB.taxiVersion ~= KNOWN_VERSION then
		ns.charDB.taxi, ns.charDB.taxiScanned, ns.charDB.taxiVersion = {}, nil, KNOWN_VERSION
	end
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("TAXIMAP_OPENED")
	-- Learning a node fires this while the flight master's map is open.
	frame:RegisterEvent("TAXI_NODE_STATUS_CHANGED")
	frame:RegisterEvent("TAXIMAP_CLOSED")
	frame:SetScript("OnEvent", function(_, event)
		if event == "TAXIMAP_CLOSED" then
			Closed()
		else
			HookTaxiFrame()
			if TaxiFrame and TaxiFrame:IsShown() then
				Shown()
			else
				ScanFlightMaster()
			end
		end
	end)
	HookTaxiFrame()
	hooksecurefunc(ns, "SetJourneyRoute", function(destination, route)
		journeyLegs = destination and not destination.corpse and route and not route.preview and route.legs or nil
		ns.RefreshTaxiRoute()
	end)
	hooksecurefunc(ns, "JourneyChanged", function()
		journeyLegs = nil
		ClearRoute(true)
	end)
end)
