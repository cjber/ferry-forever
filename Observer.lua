local _, ns = ...

local Model = ns.Model
-- A ride ends once the boat has not moved for this long: it docked (a minute), or the player got off. A
-- continent crossing's loading screen takes a few seconds; the far side is the same ride.
local RIDE_GAP = 30000
-- Only samples moving at least this fast count: boats cruise at 30 yd/s, a running player makes 7. Lifts set
-- their own (route.fit.speed), since they climb slower than a boat sails.
local MIN_SPEED = 12
-- Fitting is quadratic in samples, so it runs every few samples rather than every second.
local FIT_EVERY = 10
-- A ride's newest samples per route, enough for any crossing: fitting is quadratic, and a lift or tram ride
-- never pauses long enough to end.
local MAX_SAMPLES = 300
-- Your own sighting this recent makes a repeat ride routine: no chat line, nothing new worth sharing.
local QUIET = 600
-- About 25 minutes of debug samples.
local TRACE_LIMIT = 1500

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
	local now = GetServerTime()
	local held = ns.FreshAnchors()[routeID]
	local routine = held and held.source == "you" and now - held.seen < QUIET
	ride.announced = routeID
	if ns.Sighted(routeID, { epoch = fits[routeID].epoch, seen = now, source = "you" }) and not routine then
		local route = ns.Routes[routeID]
		ns.Print(string.format("synced the %s schedule from your ride.", route.site or route.kind))
		ns.Share(routeID)
	end
end

-- Speed since the last sample in yd/s, height included (0 across a map change).
local function Speed(now, x, y, z, map)
	local speed = 0
	if previous and previous.map == map and now > previous.now then
		local distance = math.sqrt((x - previous.x) ^ 2 + (y - previous.y) ^ 2 + (z - previous.z) ^ 2)
		speed = distance * 1000 / (now - previous.now)
	end
	previous = { now = now, x = x, y = y, z = z, map = map }
	return speed
end

-- The route the player is riding, once the ride has shown which.
function ns.CurrentRide()
	return ride and ride.announced
end

local function Sample()
	local now = ns.NowMs()
	local x, y, z, map = UnitPosition("player")
	local speed = x and not UnitOnTaxi("player") and Speed(now, x, y, z or 0, map) or 0
	if speed > 0 then
		for routeID, route in pairs(ns.Routes) do
			local phases = speed >= (route.fit and route.fit.speed or MIN_SPEED) and Model.Phases(route, map, x, y, z)
				or {}
			if #phases > 0 then
				ride = ride or { samples = {}, count = 0 }
				ride.samples[routeID] = ride.samples[routeID] or {}
				table.insert(ride.samples[routeID], { now = now, phases = phases })
				if #ride.samples[routeID] > MAX_SAMPLES then
					table.remove(ride.samples[routeID], 1)
				end
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
	-- `/ferry debug` also keeps the raw samples in the saved variables, to diagnose a ride that did not sync.
	if ns.db.debug then
		-- Fitting is the costly part, so the trace refits on the same cadence as syncing.
		if ride and (not ride.traceFits or ride.count % FIT_EVERY == 0) then
			local fits = {}
			for routeID, samples in pairs(ride.samples) do
				local epoch, support = Model.FitEpoch(ns.Routes[routeID], samples)
				fits[#fits + 1] = string.format("%d:%d/%d%s", routeID, support, #samples, epoch and "*" or "")
			end
			ride.traceFits = table.concat(fits, " ")
		end
		table.insert(ns.db.trace, {
			GetServerTime(),
			map or -1,
			x or 0,
			y or 0,
			z or 0,
			math.floor(speed * 10) / 10,
			ride and ride.traceFits or "",
		})
		if #ns.db.trace > TRACE_LIMIT then
			table.remove(ns.db.trace, 1)
		end
	end
	-- `/ferry debug`: whether the position reads on a transport, and what the ride has matched so far.
	if ns.db.debug and GetTime() - lastDebug >= 5 then
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
	if ns.db.debug then
		ns.db.trace = ns.db.trace or {}
	end
	C_Timer.NewTicker(1, Sample)
	-- A /reload or logout on board would otherwise drop the ride so far (it lives only in memory).
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("PLAYER_LEAVING_WORLD")
	frame:SetScript("OnEvent", function()
		if ride then
			Record()
		end
	end)
end)
