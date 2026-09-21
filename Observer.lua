local _, ns = ...

local Model = ns.Model
-- A ride ends once the boat has not moved for this long: it docked (a minute), or the player got off. A
-- continent crossing's loading screen takes a few seconds; the far side is the same ride.
local RIDE_GAP = 30000
-- Only samples moving at least this fast count: boats cruise at 30 yd/s, a running player makes 7.
local MIN_SPEED = 12
-- Fitting is quadratic in samples, so it runs every few samples rather than every second.
local FIT_EVERY = 10

-- { samples = { [route] = {...} }, count, last = ms of the latest moving sample, announced = route }
local ride
local previous
local lastDebug = 0

local function Fits()
	local fits = {}
	for routeID, samples in pairs(ride.samples) do
		local epoch, support = Model.FitEpoch(ns.Routes[routeID], samples)
		if epoch then
			fits[routeID] = { epoch = epoch, support = support }
		end
	end
	return fits
end

-- Record the route the ride was on, once it is clear which one.
local function Record()
	local fits = Fits()
	local routeID = Model.RideRoute(fits)
	if not routeID then
		return
	end
	local sighting = { epoch = fits[routeID].epoch, seen = GetServerTime(), source = "you" }
	if ns.Sighted(routeID, sighting) and ride.announced ~= routeID then
		ns.Print(string.format("synced the %s schedule from your ride.", ns.Routes[routeID].kind))
	end
	ride.announced = routeID
	ns.Share(routeID)
end

local function Moving(now, x, y, map)
	local moving = previous
		and previous.map == map
		and math.sqrt((x - previous.x) ^ 2 + (y - previous.y) ^ 2) >= MIN_SPEED * (now - previous.now) / 1000
	previous = { now = now, x = x, y = y, map = map }
	return moving
end

local function Sample()
	local now = ns.NowMs()
	local x, y, _, map = UnitPosition("player")
	if x and not UnitOnTaxi("player") and Moving(now, x, y, map) then
		for routeID, route in pairs(ns.Routes) do
			local phases = Model.Phases(route, map, x, y)
			if #phases > 0 then
				ride = ride or { samples = {}, count = 0 }
				ride.samples[routeID] = ride.samples[routeID] or {}
				table.insert(ride.samples[routeID], { now = now, phases = phases })
				ride.last = now
			end
		end
		if ride and ride.last == now then
			ride.count = ride.count + 1
			-- Sync as soon as the ride proves itself; the ride's end refines it.
			if not ride.announced and ride.count % FIT_EVERY == 0 then
				Record()
			end
		end
	end
	if ride and now - ride.last > RIDE_GAP then
		Record()
		ride = nil
	end
	-- `/ferry debug`: whether the position reads on a transport, and what the ride has matched so far.
	if ns.debug and GetTime() - lastDebug >= 5 then
		lastDebug = GetTime()
		local matched = {}
		for routeID, samples in pairs(ride and ride.samples or {}) do
			matched[#matched + 1] = routeID .. " x" .. #samples
		end
		ns.Print(
			string.format(
				"map %s at %s, %s; ride: %s",
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
