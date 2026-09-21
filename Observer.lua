local _, ns = ...

local Model = ns.Model
-- A ride ends once the player has been off every route this long (a continent crossing's loading screen
-- takes a few seconds, the other side of it is the same ride).
local RIDE_GAP = 30000
-- Samples older than any leg are dropped.
local KEEP = 600000

-- [route] = { samples = {...}, last = ms of the latest on-route sample, announced = bool }
local rides = {}
local lastDebug = 0

local function Record(routeID)
	local ride = rides[routeID]
	local epoch = Model.FitEpoch(ns.Routes[routeID], ride.samples)
	if not epoch then
		return
	end
	if ns.Sighted(routeID, { epoch = epoch, seen = GetServerTime() }, "you") and not ride.announced then
		ns.Print(string.format("synced the %s schedule from your ride.", ns.Routes[routeID].kind))
	end
	ride.announced = true
	ns.Share(routeID)
end

local function Sample()
	local now = ns.NowMs()
	local x, y, _, map = UnitPosition("player")
	local onTaxi = UnitOnTaxi("player")
	local matched = {}
	for routeID, route in pairs(ns.Routes) do
		local phases = x and not onTaxi and Model.Phases(route, map, x, y) or {}
		local ride = rides[routeID]
		if #phases > 0 then
			ride = ride or { samples = {} }
			rides[routeID] = ride
			ride.samples[#ride.samples + 1] = { now = now, phases = phases }
			ride.last = now
			while now - ride.samples[1].now > KEEP do
				table.remove(ride.samples, 1)
			end
			-- Sync as soon as the ride proves itself, then refine once it ends.
			if not ride.announced and #ride.samples >= Model.MIN_SAMPLES then
				Record(routeID)
			end
		elseif ride and now - ride.last > RIDE_GAP then
			Record(routeID)
			rides[routeID] = nil
		end
		if #phases > 0 then
			matched[#matched + 1] = string.format("%d (%.0f s into its loop)", routeID, phases[1] / 1000)
		end
	end
	-- `/ferry debug`: whether the position reads on a transport, and which routes it matches.
	if ns.debug and GetTime() - lastDebug >= 5 then
		lastDebug = GetTime()
		ns.Print(
			string.format(
				"map %s at %s, %s; routes: %s",
				tostring(map),
				tostring(x),
				tostring(y),
				table.concat(matched, ", ")
			)
		)
	end
end

ns.Init(function()
	C_Timer.NewTicker(1, Sample)
end)
