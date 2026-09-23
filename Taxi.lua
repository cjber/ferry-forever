local _, ns = ...

-- The flight points this character knows, for the journey planner and the map's flight master pins. Only a
-- flight master's own map says which nodes a character can fly to: the world map's taxi query answers anywhere
-- but reports every node as discovered on this client (the other faction's included), so it is not a source.

-- Lists built from that query before it was dropped; they claim every node, so start again from empty.
local KNOWN_VERSION = 2

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
function ns.KnownTaxiNodes()
	return ns.charDB.taxi
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
	frame:SetScript("OnEvent", ScanFlightMaster)
end)
