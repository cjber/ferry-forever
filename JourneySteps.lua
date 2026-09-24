---@class SPFNamespace
local ns = select(2, ...)

-- How a journey step reads. The tracker and the public API's EstimateDetail share these words, so a step names
-- the same place in SPF's list and in another addon's travel line.
local SCHEDULED = { boat = true, zeppelin = true, lift = true, tram = true }
local VERB = {
	walk = "Walk to",
	flight = "Fly to",
	boat = "Boat to",
	zeppelin = "Zeppelin to",
	lift = "Lift to",
	tram = "Tram to",
	portal = "Portal to",
	passage = "Go through to",
	teleport = "Teleport to",
}

-- A place with no kind is the destination point as clicked or picked from a quest.
---@param node SPFPoint|SPFPlace
---@param mode? SPFMode
---@return string
function ns.PlaceLabel(node, mode)
	if node.kind == "start" then
		return "your position"
	elseif node.kind == "dock" then
		return (mode == "boat" or mode == "zeppelin") and ns.DockLabel(node.id) or ns.DockTitle(node.id)
	elseif node.kind == "taxi" then
		return ns.TaxiNodes[node.id].name
	elseif node.kind == "portal" then
		return node.label
	elseif node.kind == "teleport" or node.kind == "goal" or node.kind == nil then
		local location = not node.label and ns.Locate(node)
		return node.label or location and location.zone or UNKNOWN
	end
	error("unknown journey node kind " .. tostring(node.kind))
end

-- The place a leg ends.
---@param leg SPFLeg
---@return string
function ns.LegLabel(leg)
	return ns.PlaceLabel(leg.to, leg.mode)
end

---@param leg SPFLeg
---@return string
function ns.LegVerb(leg)
	return VERB[leg.mode]
end

-- Whole seconds as a countdown shows them, so totals add up to the times on screen.
local function Seconds(ms)
	return math.max(0, math.ceil(ms / 1000))
end

-- Only a timed transport's departure and a teleport's cooldown make a step wait; a flight leaves at once. A
-- transport nobody has timed yet waits half its round trip on average; "about" marks that guess.
---@param leg SPFLeg
---@return string
function ns.LegTime(leg)
	local text = ns.FormatCountdown(leg.arrive - leg.depart)
	if leg.wait and leg.wait > 0 then
		local guess = leg.estimated and SCHEDULED[leg.mode] and "about " or ""
		local lead = leg.mode == "teleport" and "ready in " or "leaves in "
		text = lead .. guess .. ns.FormatCountdown(leg.wait) .. " · " .. text
	end
	return text
end

-- The steps from index on, waits included, in the milliseconds of the whole seconds each step shows. The header
-- adds up the steps rather than counting down to the planned arrival, which would run on while you stand still
-- until the next retime put it back.
---@param legs SPFLeg[]
---@param index integer
---@return integer
function ns.JourneyTime(legs, index)
	local seconds = 0
	for legIndex = index, #legs do
		local leg = legs[legIndex]
		seconds = seconds + Seconds(leg.arrive - leg.depart) + Seconds(leg.wait or 0)
	end
	return seconds * 1000
end
