local _, ns = ...

-- A heads-up for anyone waiting away from the keyboard: the stock raid-warning banner, its sound on the Master
-- channel (heard with the game in the background) and a flashing taskbar icon, once per boat.
-- Waiting at a dock: this long before a timed boat arrives (it then stays docked about a minute).
local AT_DOCK = 30000
-- Riding: this long before the boat reaches its next dock.
local ON_BOARD = 20000
local RADIUS = 120
local KIND = { boat = "Boat", zeppelin = "Zeppelin", tram = "Tram" }

-- [route .. ":" .. dock] = GetTime() of the alert, so each visit alerts once.
local alerted = {}

local function Alert(key, text)
	if GetTime() - (alerted[key] or -math.huge) < 120 then
		return
	end
	alerted[key] = GetTime()
	RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo.RAID_WARNING)
	if ns.db.alertSound then
		PlaySound(SOUNDKIT.RAID_WARNING, "Master")
	end
	FlashClientIcon()
end

local function Due(ms, lead)
	return ms <= lead and ms > lead - 5000
end

local function Check()
	if not ns.db.alerts then
		return
	end
	local riding = ns.CurrentRide()
	if riding then
		local dockID, arriveIn = ns.NextStop(riding)
		if dockID and Due(arriveIn, ON_BOARD) then
			Alert(
				riding .. ":" .. dockID,
				"Arriving at " .. ns.DockLabel(dockID) .. " in " .. ns.FormatCountdown(arriveIn)
			)
		end
		return
	end
	local dockID, yards = ns.NearestDock()
	if not dockID or yards > RADIUS then
		return
	end
	for _, departure in ipairs(ns.DockDepartures(dockID)) do
		-- Lifts come round every few seconds; an alert for each would only nag.
		local kind = KIND[departure.kind]
		if kind and departure.known and not departure.docked and Due(departure.arriveIn, AT_DOCK) then
			local text = string.format(
				"%s to %s arrives in %s",
				kind,
				ns.DepartureDestination(departure),
				ns.FormatCountdown(departure.arriveIn)
			)
			Alert(departure.route .. ":" .. dockID, text)
		end
	end
end

ns.Init(function()
	C_Timer.NewTicker(1, Check)
end)
