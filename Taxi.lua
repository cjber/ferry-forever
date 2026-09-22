local _, ns = ...

-- The flight points this character knows, for the journey planner. The world map's taxi query answers anywhere
-- (not only at a flight master), so every zone holding a node is asked at login and whenever one is learned.

local function ZoneMaps()
	local maps, seen = {}, {}
	for _, node in pairs(ns.TaxiNodes) do
		local location = ns.Locate(node)
		if location and not seen[location.uiMap] then
			seen[location.uiMap] = true
			maps[#maps + 1] = location.uiMap
		end
	end
	return maps
end

local zoneMaps
local function Scan()
	zoneMaps = zoneMaps or ZoneMaps()
	local known, answered = ns.charDB.taxi, false
	for _, uiMap in ipairs(zoneMaps) do
		for _, node in ipairs(C_TaxiMap.GetTaxiNodesForMap(uiMap) or {}) do
			answered = true
			if not node.isUndiscovered and ns.TaxiNodes[node.nodeID] then
				known[node.nodeID] = true
			end
		end
	end
	ns.charDB.taxiScanned = ns.charDB.taxiScanned or answered
end

-- At a flight master, every node it can fly to is known (absence never unlearns one).
local function ScanFlightMaster()
	local uiMap = GetTaxiMapID and GetTaxiMapID()
	for _, node in ipairs(uiMap and C_TaxiMap.GetAllTaxiNodes(uiMap) or {}) do
		if node.state ~= Enum.FlightPathState.Unreachable and ns.TaxiNodes[node.nodeID] then
			ns.charDB.taxi[node.nodeID] = true
		end
	end
end

-- Known nodes, or nil when this client never answered the query (the planner then assumes every node of the
-- player's faction).
function ns.KnownTaxiNodes()
	return ns.charDB.taxiScanned and ns.charDB.taxi or nil
end

ns.Init(function()
	FerryForeverCharDB = FerryForeverCharDB or {}
	ns.charDB = FerryForeverCharDB
	ns.charDB.taxi = ns.charDB.taxi or {}
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("TAXI_NODE_STATUS_CHANGED")
	frame:RegisterEvent("TAXIMAP_OPENED")
	frame:SetScript("OnEvent", function(_, event)
		if event == "TAXIMAP_OPENED" then
			ScanFlightMaster()
		else
			Scan()
		end
	end)
	-- The map data is not ready the instant the addon loads.
	C_Timer.After(5, Scan)
end)
