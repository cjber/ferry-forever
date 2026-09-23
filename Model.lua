local _, ns = ...

-- Pure timetable arithmetic, free of game APIs. Times are server milliseconds; a route's `epoch` is the
-- server time at which its loop was at 0 ms, so its phase is (now - epoch) % period.
local Model = {}
ns.Model = Model

-- Samples of one ride whose phase offsets agree this closely are one boat.
local AGREE = 8000
-- A position this far from every leg of a route is not on that route.
local NEAR = 40
Model.MIN_SAMPLES = 10
Model.MIN_SPAN = 30000
local CLEAR_LEAD = 1.25
-- How far ahead of this client's clock a sighting may be dated (both read the server's time).
local CLOCK_SLACK = 5
-- A sighting of your own this recent is not replaced by another player's.
local OWN_TRUST = 3600
-- Sightings older than this are too stale to share or to count down from.
Model.MAX_AGE = 6 * 3600

function Model.FormatCountdown(ms)
	local seconds = math.max(0, math.ceil(ms / 1000))
	return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- The next visit of `stop` at `phase`: docked now (departIn), or arriveIn and that visit's departIn.
function Model.Visit(route, stop, phase)
	local period = route.period
	local stay = (stop.depart - stop.arrive) % period
	local since = (phase - stop.arrive) % period
	if since < stay then
		return true, nil, stay - since
	end
	local arriveIn = (stop.arrive - phase) % period
	return false, arriveIn, arriveIn + stay
end

-- The docks visited after stop `index`, in order, until the route returns to it.
function Model.Onward(route, index)
	local stops, onward, seen = route.stops, {}, { [route.stops[index].dock] = true }
	for offset = 1, #stops - 1 do
		local dock = stops[(index + offset - 1) % #stops + 1].dock
		if not seen[dock] then
			onward[#onward + 1] = dock
			seen[dock] = true
		end
	end
	return onward
end

-- Ride time excludes the boarding stop's dwell and includes intermediate stops, across phase zero.
function Model.RideTime(route, from, to)
	return (to.arrive - from.depart) % route.period
end

-- Every phase at which the route passes within NEAR yards of (map, x, y) while moving. A docked boat is
-- still for a minute, so a stop's own point yields no phase.
function Model.Phases(route, map, x, y, z, scratch)
	local frames, phases = route.frames, scratch
	if phases then
		for i = #phases, 1, -1 do
			phases[i] = nil
		end
	end
	-- Adjacent lift shafts can run different periods; a boat-sized radius confuses their cars.
	local near = route.kind == "lift" and 10 or NEAR
	for i = 1, #frames - 1 do
		local a, b = frames[i], frames[i + 1]
		if a[3] == map and not a[6] then
			local dx, dy = b[4] - a[4], b[5] - a[5]
			local dz, oz = 0, 0
			if z and a[7] and b[7] then
				dz, oz = b[7] - a[7], z - a[7]
			end
			local length = dx * dx + dy * dy + dz * dz
			local t = length > 0 and math.min(1, math.max(0, ((x - a[4]) * dx + (y - a[5]) * dy + oz * dz) / length))
				or 0
			local px, py = a[4] + t * dx - x, a[5] + t * dy - y
			local pz = t * dz - oz
			if px * px + py * py + pz * pz <= near * near and t > 0 and t < 1 then
				phases = phases or {}
				phases[#phases + 1] = a[2] + t * (b[1] - a[2])
			end
		end
	end
	return phases or {}
end

-- The epoch most samples of one ride agree on, and how many agree (nil, support when too few do). Each
-- sample is { now = ms, phases = {...} } from Model.Phases. The agreeing samples must span MIN_SPAN: offsets
-- of someone standing near a leg drift one second per second, so they agree only briefly, while a rider's
-- hold for the whole leg.
function Model.FitEpoch(route, samples)
	local period, offsets = route.period, {}
	local fit = route.fit or {}
	-- A UC ride lasts only 3.5 s; the boat window also fits its opposite-direction phases.
	local agree = route.kind == "lift" and 2000 or AGREE
	for _, sample in ipairs(samples) do
		for _, phase in ipairs(sample.phases) do
			offsets[#offsets + 1] = { offset = (sample.now - phase) % period, now = sample.now }
		end
	end
	local best, support = nil, 0
	for _, center in ipairs(offsets) do
		local members, sum, first, last = 0, 0, math.huge, -math.huge
		for _, other in ipairs(offsets) do
			local delta = (other.offset - center.offset + period / 2) % period - period / 2
			if math.abs(delta) <= agree / 2 then
				members, sum = members + 1, sum + delta
				first, last = math.min(first, other.now), math.max(last, other.now)
			end
		end
		if members > support and last - first >= (fit.span or Model.MIN_SPAN) then
			best, support = (center.offset + sum / members) % period, members
		end
	end
	if support < (fit.samples or Model.MIN_SAMPLES) then
		return nil, support
	end
	return best, support
end

-- The route a ride was on. Routes sharing a lane (Menethil's two Auberdine boats) both fit the shared part,
-- so only a clear winner counts: the most supported fit, well ahead of every other.
function Model.RideRoute(fits)
	local best, runnerUp
	for routeID, fit in pairs(fits) do
		if not best or fit.support > fits[best].support then
			best, runnerUp = routeID, best and fits[best].support or runnerUp
		elseif not runnerUp or fit.support > runnerUp then
			runnerUp = fit.support
		end
	end
	if best and (not runnerUp or fits[best].support >= CLEAR_LEAD * runnerUp) then
		return best
	end
end

-- Wire format: "<route>:<seen s>:<phase ms at seen>" entries joined by ";". Phase-at-seen keeps every number
-- short and independent of the sender's clock beyond the sighting's own timestamp.
function Model.Encode(anchors, routes)
	local entries = {}
	for routeID, anchor in pairs(anchors) do
		local route = routes[routeID]
		if route then
			local phase = (anchor.seen * 1000 - anchor.epoch) % route.period
			entries[#entries + 1] = string.format("%d:%d:%d", routeID, anchor.seen, math.floor(phase))
		end
	end
	table.sort(entries)
	return entries
end

-- Validated anchors from one message; anything malformed, unknown, future-dated or stale is dropped.
function Model.Decode(message, routes, now)
	local anchors = {}
	for routeID, seen, phase in message:gmatch("(%d+):(%d+):(%d+)") do
		routeID, seen, phase = tonumber(routeID), tonumber(seen), tonumber(phase)
		local route = routes[routeID]
		if route and phase < route.period and seen <= now + CLOCK_SLACK and now - seen <= Model.MAX_AGE then
			anchors[routeID] = { epoch = seen * 1000 - phase, seen = seen }
		end
	end
	return anchors
end

-- Whether an incoming sighting replaces the one held: only a newer one, and another player's never
-- replaces a recent ride of your own.
function Model.Newer(incoming, held, now)
	if held == nil then
		return true
	end
	if held.source == "you" and incoming.source ~= "you" and now - held.seen < OWN_TRUST then
		return false
	end
	return incoming.seen > held.seen
end
