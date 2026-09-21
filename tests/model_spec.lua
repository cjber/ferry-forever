local ns = {}
assert(loadfile("Data/Routes.lua"))("FerryForever", ns)
assert(loadfile("Model.lua"))("FerryForever", ns)
local Model, Routes = ns.Model, ns.Routes

local function near(actual, expected, tolerance, label)
	assert(math.abs(actual - expected) <= tolerance, ("%s: %s, expected %s"):format(label, actual, expected))
end

-- The generated data: every stop names a dock, and every route's frames run forward through one loop.
for routeID, route in pairs(Routes) do
	assert(route.kind == "boat" or route.kind == "zeppelin", routeID)
	assert(#route.stops >= 2, routeID)
	for _, stop in ipairs(route.stops) do
		assert(ns.Docks[stop.dock], routeID)
	end
	for i = 2, #route.frames do
		assert(route.frames[i][1] >= route.frames[i - 1][2], routeID)
	end
	assert(route.frames[#route.frames][2] <= route.period, routeID)
end

assert(Model.FormatCountdown(61000) == "1:01")
assert(Model.FormatCountdown(500) == "0:01")
assert(Model.FormatCountdown(-3) == "0:00")

-- Countdowns before, during and after a visit, and across the loop's start (route 303 idles at its first
-- dock over the wrap).
local ratchet = Routes[241]
local stop = ratchet.stops[1]
local stay = stop.depart - stop.arrive
local docked, arriveIn, departIn = Model.Visit(ratchet, stop, stop.arrive - 5000)
assert(not docked and arriveIn == 5000 and departIn == 5000 + stay)
docked, arriveIn, departIn = Model.Visit(ratchet, stop, stop.arrive + 1000)
assert(docked and arriveIn == nil and departIn == stay - 1000)
docked, arriveIn = Model.Visit(ratchet, stop, stop.depart + 1000)
assert(not docked and arriveIn == ratchet.period - stay - 1000)
local wrap = Routes[303].stops[1]
assert(wrap.depart < wrap.arrive)
assert((Model.Visit(Routes[303], wrap, 10)))
assert((Model.Visit(Routes[303], wrap, Routes[303].period - 10)))

-- Menethil -> Southshore -> Auberdine: from Menethil the boat goes on to both.
local southshore = Routes[11167]
local onward = Model.Onward(southshore, 1)
assert(#onward == 2 and onward[1] == southshore.stops[2].dock and onward[2] == southshore.stops[3].dock)

-- Where a boat is at a phase, by the same frames the observer matches against.
local function position(route, phase)
	local frames = route.frames
	for i = 1, #frames - 1 do
		local a, b = frames[i], frames[i + 1]
		if phase >= a[2] and phase <= b[1] and not a[6] then
			local t = (phase - a[2]) / (b[1] - a[2])
			return a[3], a[4] + t * (b[4] - a[4]), a[5] + t * (b[5] - a[5])
		end
	end
end

-- A rider sampled once a second across a leg yields the boat's epoch, and the ride is told apart from every
-- other route it passes over (boats share lanes out of Menethil and Auberdine).
for routeID, route in pairs(Routes) do
	local epoch = 1790000000000 + routeID * 7919
	local samples = {}
	local from, to = route.stops[1].depart, route.stops[1].depart + 150000
	for phase = from, to, 1000 do
		local map, x, y = position(route, phase % route.period)
		if map then
			for candidateID, candidate in pairs(Routes) do
				local phases = Model.Phases(candidate, map, x + 5, y - 5)
				if #phases > 0 then
					samples[candidateID] = samples[candidateID] or {}
					table.insert(samples[candidateID], { now = epoch + phase, phases = phases })
				end
			end
		end
	end
	local fits = {}
	for candidateID, candidateSamples in pairs(samples) do
		local fitted, support = Model.FitEpoch(Routes[candidateID], candidateSamples)
		if fitted then
			fits[candidateID] = { epoch = fitted, support = support }
		end
	end
	assert(Model.RideRoute(fits) == routeID, "ride on " .. routeID .. " read as " .. tostring(Model.RideRoute(fits)))
	local error = (fits[routeID].epoch - epoch + route.period / 2) % route.period - route.period / 2
	near(error, 0, 1500, "route " .. routeID .. " epoch")
end

-- Someone standing by a leg for minutes is not a rider.
local map, x, y = position(ratchet, ratchet.stops[1].depart + 40000)
local standing = {}
for second = 1, 300 do
	standing[#standing + 1] = { now = second * 1000, phases = Model.Phases(ratchet, map, x, y) }
end
assert(Model.FitEpoch(ratchet, standing) == nil)

-- Sightings round-trip through the wire format; anything unknown, stale or from the future is dropped.
local now = 1790000000
local sent = { [241] = { epoch = 1789999876543, seen = now - 30 }, [11616] = { epoch = 1789000000000, seen = now } }
local message = table.concat(Model.Encode(sent, Routes), ";")
local received = Model.Decode(message, Routes, now)
for routeID, anchor in pairs(sent) do
	local period = Routes[routeID].period
	assert(received[routeID].seen == anchor.seen)
	near((received[routeID].epoch - anchor.epoch) % period, 0, 1, "route " .. routeID .. " round trip")
end
local rejected = Model.Decode(
	("9:%d:1;241:%d:1;241:%d:1;285:%d:999999999"):format(now, now + 600, now - Model.MAX_AGE - 1, now),
	Routes,
	now
)
assert(next(rejected) == nil)

assert(Model.Newer({ seen = 2 }, { seen = 1 }, 2) and not Model.Newer({ seen = 1 }, { seen = 1 }, 2))
assert(Model.Newer({ seen = 1 }, nil, 1))
-- Your own ride outranks a newer report from someone else for an hour.
local own = { seen = now, source = "you" }
assert(not Model.Newer({ seen = now + 60, source = "player" }, own, now + 60))
assert(Model.Newer({ seen = now + 3700, source = "player" }, own, now + 3700))
assert(Model.Newer({ seen = now + 60, source = "you" }, own, now + 60))

print("model_spec: ok")
