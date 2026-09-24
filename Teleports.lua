---@class SPFNamespace
local ns = select(2, ...)

-- The personal teleports this character can cast now, for the planner. The client names the bind point but has no
-- position for it, so it is where you stood when you bound (beside the innkeeper), kept with that name. Bound
-- anywhere else since (before this addon, or on another client), the names disagree: no bind teleport until you
-- bind again.

local places, placesKey, sources = {}, nil, {}

---@return SPFBindPoint?
local function Bind()
	local bind, name = ns.charDB.bind, GetBindLocation()
	if bind and canaccessvalue(name) and bind.name == name then
		return bind
	end
end

---@param teleport SPFTeleport
local function Known(teleport)
	if teleport.item then
		return C_Item.GetItemCount(teleport.item) > 0
	end
	return C_SpellBook.IsSpellKnown(teleport.spell)
end

---@param teleport SPFTeleport
local function Stocked(teleport)
	for item, count in pairs(teleport.reagents or {}) do
		if C_Item.GetItemCount(item) < count then
			return false
		end
	end
	return true
end

-- Seconds of cooldown left, or nil while the client keeps it secret.
---@param teleport SPFTeleport
---@return number?
local function Cooldown(teleport)
	local start, duration
	if teleport.item then
		start, duration = C_Item.GetItemCooldown(teleport.item)
	else
		local info = C_Spell.GetSpellCooldown(teleport.spell)
		if info then
			start, duration = info.startTime, info.duration
		end
	end
	if not (canaccessvalue(start) and canaccessvalue(duration)) then
		return nil
	end
	return start and duration and start > 0 and math.max(0, start + duration - GetTime()) or 0
end

-- The places keep their identity while the set is unchanged, so the planner keeps its topology; only readiness
-- ([index] = server ms when it can be cast) is read afresh.
---@param now number server ms
---@return SPFTeleportPlace[] places, table<number, number> ready
function ns.UsableTeleports(now)
	local bind, known, keys = Bind(), {}, {}
	for _, teleport in ipairs(ns.Teleports) do
		if (teleport.to or (teleport.bind and bind)) and Known(teleport) then
			known[#known + 1] = teleport
			keys[#keys + 1] = teleport.spell
		end
	end
	local key = table.concat(keys, ",") .. (bind and string.format(":%d:%.17g:%.17g", bind.map, bind.x, bind.y) or "")
	if key ~= placesKey then
		placesKey, places, sources = key, {}, known
		for index, teleport in ipairs(known) do
			local to = teleport.to or bind --[[@as SPFPoint]]
			places[index] = {
				map = to.map,
				x = to.x,
				y = to.y,
				z = to.z,
				label = not teleport.to and bind and bind.name or nil,
				spell = teleport.spell,
				item = teleport.item,
				cast = teleport.cast,
			}
		end
	end
	local ready = {}
	for index, teleport in ipairs(sources) do
		local wait = Stocked(teleport) and Cooldown(teleport)
		if wait then
			ready[index] = now + wait * 1000
		end
	end
	return places, ready
end

ns.Init(function()
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("HEARTHSTONE_BOUND")
	frame:SetScript("OnEvent", function()
		local x, y, z, map = ns.JourneyPosition()
		local name = GetBindLocation()
		if x and y and map and canaccessvalue(name) then
			ns.charDB.bind = { name = name, map = map, x = x, y = y, z = z }
		else
			ns.charDB.bind = nil
		end
	end)
end)
