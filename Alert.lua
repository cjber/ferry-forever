---@class SPFNamespace
local ns = select(2, ...)
local L = ns.L

-- A heads-up for anyone waiting away from the keyboard: the stock raid-warning banner, the transport's own
-- in-world sound on the Master channel (heard with the game in the background) and a flashing taskbar icon,
-- once per boat. The sound is the one the game makes for that transport, never a raid alert (WFA-26).
-- Waiting at a dock: this long before a timed boat arrives (it then stays docked about a minute).
local AT_DOCK = 30000
-- Riding: this long before the boat reaches its next dock.
local ON_BOARD = 20000
local RADIUS = 120
-- Lifts come round every few seconds, so they never alert.
local ARRIVES = {
	boat = L["Boat to %s arrives in %s"],
	zeppelin = L["Zeppelin to %s arrives in %s"],
	tram = L["Tram to %s arrives in %s"],
}
-- What the game itself plays for each, as FileDataIDs in the Forever build (sound/doodad/): the bell a ship
-- rings as it docks (boatdockedwarning.ogg), the zeppelin's horn (zeppelinhorn.ogg), the tram pulling in
-- (subwaystop.ogg).
local SOUND = { boat = 566652, zeppelin = 566719, tram = 566056 }

-- [route .. ":" .. dock] = GetTime() of the alert, so each visit alerts once.
local alerted = {}

local function Alert(key, kind, text)
	if GetTime() - (alerted[key] or -math.huge) < 120 then
		return
	end
	alerted[key] = GetTime()
	RaidWarningUtil.AddMessage(text, ChatTypeInfo.RAID_WARNING)
	if ns.db.alertSound then
		PlaySoundFile(SOUND[kind], "Master")
	end
	FlashClientIcon()
end

local function Due(ms, lead)
	return ms <= lead and ms > lead - 5000
end

local function Check(dockID, yards)
	if not ns.db.alerts or InCombatLockdown() then
		return
	end
	local riding = ns.CurrentRide()
	if riding then
		local kind = ns.Routes[riding].kind
		local nextDock, arriveIn = ns.NextStop(riding)
		if ARRIVES[kind] and nextDock and arriveIn and Due(arriveIn, ON_BOARD) then
			Alert(
				riding .. ":" .. nextDock,
				kind,
				string.format(L["Arriving at %s in %s"], ns.DockLabel(nextDock), ns.FormatCountdown(arriveIn))
			)
		end
		return
	end
	if not dockID or yards > RADIUS then
		return
	end
	for _, departure in ipairs(ns.DockDepartures(dockID)) do
		local arrives = ARRIVES[departure.kind]
		if arrives and departure.known and not departure.docked and Due(departure.arriveIn, AT_DOCK) then
			local text =
				string.format(arrives, ns.DepartureDestination(departure), ns.FormatCountdown(departure.arriveIn))
			Alert(departure.route .. ":" .. dockID, departure.kind, text)
		end
	end
end

ns.Init(function()
	ns.OnTravelTick(Check)
end)
