local driver = assert(loadfile("tests/journey_driver.lua"))()
local ns = driver.ns
local here, target = { map = 1, x = 0, y = 0, z = 0 }, { map = 1, x = 1200, y = 0 }
local jobs, batches, plans, logs = {}, {}, {}, {}
ns.db.debug = true
ns.Print = function(message)
	logs[#logs + 1] = message
end
local plan = ns.Planner.Plan
ns.Planner.Plan = function(options)
	plans[#plans + 1] = options
	return plan(options)
end
ns.Path = {
	HasData = function()
		return true
	end,
	FindMany = function(map, from, targets, callback, water, reverse)
		local job = { map = map, from = from, targets = targets, callback = callback, water = water, reverse = reverse }
		batches[#batches + 1] = job
		return job
	end,
	Find = function(_, from, to, callback, water)
		local job = { from = from, to = to, callback = callback, water = water }
		jobs[#jobs + 1] = job
		return job
	end,
	Cancel = function(job)
		job.cancelled = true
	end,
}
local function begin()
	ns.ClearJourney()
	driver.begin(here, target)
end
local function costs(job, cost, reason)
	local values = {}
	for i = 1, #job.targets do
		values[i] = cost
	end
	job.callback(values, reason, job)
end
local function ready(cost)
	costs(batches[#batches], cost or 1400)
	costs(batches[#batches - 1], cost or 1400)
end
local function finish(job, points, cost)
	job.callback(points, cost or 1400, job)
end

-- Neither the timer nor the first batch completion can choose an exact plan before both batches finish.
begin()
local settling, round, pending = ns.JourneyStatus()
assert(settling and round == 0 and pending == 2 and driver.shown().settling)
assert(#jobs == 0 and #plans == 1 and #batches == 2)
assert(ns.JourneyInfo():find("finding the fastest way", 1, true))
for _ = 1, 3 do
	driver.update(5)
end
assert(#plans == 1 and #jobs == 0)
costs(batches[2], 1400)
assert(#plans == 1 and #jobs == 0)
costs(batches[1], 1400)
settling, round, pending = ns.JourneyStatus()
assert(settling and round == 1 and pending == 1 and #plans == 2 and #jobs == 1)
assert(not driver.shown().legs[1].estimated)
local first = jobs[1]
local points = { first.from, { map = 1, x = 600, y = 300 }, first.to }
-- Even a disagreement only logs; geometry cannot start another plan.
finish(first, points, 2100)
assert(#plans == 2 and #jobs == 1 and #logs == 1)
assert(driver.shown().legs[1].walkPoints[2] == points[2])
assert(not ns.JourneyStatus() and not driver.shown().settling)

-- Remaining() wins for the followed leg; other start costs are carried unchanged, never distance-shifted.
here = { map = 1, x = 600, y = 300 }
driver.move(here)
driver.update(5)
assert(#batches == 2 and #jobs == 1)
local walks = plans[#plans].walks
assert(walks[1].cost == 1400 and math.abs(walks[#walks].cost - 700) < 0.01)
driver.update(5)
walks = plans[#plans].walks
assert(math.abs(walks[#walks].cost - 700) < 0.01, "retiming must not repeatedly shrink the cost basis")
assert(driver.shown().legs[1].walkPoints[#driver.shown().legs[1].walkPoints] == first.to)
local batchCount = #batches
-- A minute refreshes only the start batch, in the background; geometry stays visible.
driver.update(60)
assert(#batches == batchCount + 1 and not batches[#batches].reverse and #jobs == 1)
assert(#driver.shown().legs[1].walkPoints >= 2)
costs(batches[#batches], 1300)
assert(#jobs == 1 and not ns.JourneyStatus())

-- Off-route refresh retains the old points both while costs and replacement geometry are pending.
here = { map = 1, x = 600, y = -100 }
driver.move(here)
driver.update(5)
assert(#batches == batchCount + 2 and not batches[#batches].reverse)
assert(#jobs == 1)
costs(batches[#batches], 1500)
local replacement = jobs[#jobs]
assert(#jobs == 2 and driver.shown().legs[1].walkPoints[2] == points[2])
local count = #plans
finish(replacement, nil, "unreachable")
assert(#plans == count and driver.shown().legs[1].walkPoints[2] == points[2], "failed refresh keeps drawn points")
assert(not ns.JourneyStatus())

-- Replacing/clearing a journey cancels both job types; late callbacks cannot settle or resurrect the new one.
begin()
local stale = batches[#batches]
begin()
local current = batches[#batches]
costs(stale, 1400)
assert(stale.cancelled and select(3, ns.JourneyStatus()) == 2)
ready()
local stalePoints = jobs[#jobs]
ns.ClearJourney()
costs(current, 1400)
finish(stalePoints, points)
assert(stalePoints.cancelled and not driver.shown() and not ns.JourneyInfo() and not ns.JourneyStatus())

-- A blocked endpoint is settled once, and a move retries the start without repeating the goal batch.
here = { map = 1, x = 0, y = 0 }
begin()
costs(batches[#batches], false)
costs(batches[#batches - 1], false)
assert(not driver.shown() and not ns.JourneyStatus())
count = #batches
driver.update(5)
assert(#batches == count)
here = { map = 1, x = 1, y = 0 }
driver.move(here)
driver.update(5)
assert(#batches == count + 1 and not batches[#batches].reverse)
costs(batches[#batches], 1400)
finish(jobs[#jobs], nil, "error")
assert(#driver.shown().legs[1].walkPoints == 0, "a terminal failure cannot keep a straight estimate")
count = #jobs
here = { map = 1, x = 2, y = 0 }
driver.move(here)
driver.update(5)
costs(batches[#batches], 1400)
assert(#jobs == count + 1, "moving after a failed point search must search the replacement geometry")
finish(jobs[#jobs], { jobs[#jobs].from, jobs[#jobs].to })

-- Changing the water mode invalidates both cost batches and points, keeping drawn points until replacement.
begin()
ready()
first = jobs[#jobs]
points = { first.from, { map = 1, x = 600, y = 300 }, first.to }
finish(first, points)
count = #batches
ns.water = true
driver.update(5)
assert(#batches == count + 2 and batches[#batches].water)
ready()
assert(jobs[#jobs].water and driver.shown().legs[1].walkPoints[2] == points[2])
finish(jobs[#jobs], points)
ns.ClearJourney()

-- Cancelling a pending replacement must keep the drawing it inherited from an earlier completed search.
ns.water = nil
here = { map = 1, x = 0, y = 0 }
begin()
ready()
first = jobs[#jobs]
points = { first.from, { map = 1, x = 600, y = 300 }, first.to }
finish(first, points)
here = { map = 1, x = 600, y = -100 }
driver.move(here)
driver.update(5)
costs(batches[#batches], 1500)
local cancelledReplacement = jobs[#jobs]
ns.water = true
driver.update(5)
assert(cancelledReplacement.cancelled)
ready()
assert(driver.shown().legs[1].walkPoints[2] == points[2], "a second replacement cannot reset drawn geometry")
finish(cancelledReplacement, nil, "error")
assert(ns.JourneyStatus(), "a cancelled callback cannot finish the current replacement")
finish(jobs[#jobs], points)
ns.ClearJourney()

-- Hysteresis can reject the newly computed route; it must still clear the background pulse.
ns.water = nil
here = { map = 1, x = 0, y = 0 }
begin()
ready()
first = jobs[#jobs]
finish(first, { first.from, { map = 1, x = 600, y = 300 }, first.to })
local trackedPlan, arrive = ns.Planner.Plan, driver.shown().arrive
count = #jobs
ns.Planner.Plan = function(options)
	local mid = { map = 1, x = 600, y = 100 }
	return {
		now = options.now,
		arrive = arrive - 1000,
		legs = {
			{
				mode = "walk",
				from = options.from,
				to = mid,
				yards = 700,
				depart = options.now,
				arrive = arrive - 10000,
			},
			{
				mode = "walk",
				from = mid,
				to = options.to,
				yards = 700,
				depart = arrive - 10000,
				arrive = arrive - 1000,
			},
		},
	}
end
driver.update(60)
assert(driver.shown().settling)
costs(batches[#batches], 1400)
assert(not driver.shown().settling and #jobs == count and driver.shown().legs[1].to == first.to)
ns.Planner.Plan = trackedPlan
ns.ClearJourney()

-- A searched two-point path is still genuine geometry, and survives a failed off-route replacement.
begin()
ready()
first = jobs[#jobs]
finish(first, { first.from, first.to })
here = { map = 1, x = 600, y = -100 }
driver.move(here)
driver.update(5)
costs(batches[#batches], 1500)
finish(jobs[#jobs], nil, "error")
assert(#driver.shown().legs[1].walkPoints == 2 and driver.shown().legs[1].walkPoints[2] == first.to)
ns.ClearJourney()

-- A recent ride remains observed after disembarking; a docked boat must not force a round trip.
ns.ClearJourney()
ns.Path = nil
driver.load("Data/Routes.lua")
local ratchet = ns.Routes[241]
local dock = ns.Docks[ratchet.stops[1].dock]
ns.DockTitle = function()
	return "Dock"
end
ns.DockLabel = ns.DockTitle
ns.DockPoint = function(id)
	return ns.Docks[id]
end
ns.CurrentRide = function()
	return 241
end
ns.FreshAnchors = function()
	return { [241] = { epoch = 0 } }
end
ns.NextStop = function()
	return ratchet.stops[2].dock, ratchet.stops[2].arrive - ns.NowMs()
end
here = { map = dock.map, x = dock.x, y = dock.y, z = dock.z }
ns.NowMs = function()
	return ratchet.stops[1].arrive + 1000
end
driver.begin(here, { map = here.map, x = here.x + 100, y = here.y })
assert(
	#driver.shown().legs == 1 and driver.shown().legs[1].mode == "walk",
	"a docked Ratchet ride must allow the 100-yard walk"
)
here.x = here.x + 35
driver.update(5)
assert(
	#driver.shown().legs == 1 and driver.shown().legs[1].mode == "walk",
	"walking away must not restore the stale ride"
)
ns.ClearJourney()
ns.NowMs = function()
	return ratchet.stops[1].depart + 55000
end
driver.begin(here, { map = dock.map, x = dock.x + 100, y = dock.y })
assert(
	driver.shown().legs[1].mode == "boat" and driver.shown().legs[1].aboard,
	"a ride in transit must still reach its next dock"
)
ns.ClearJourney()

-- The durable long-route regression uses real Journey, Path and all three nav maps.
assert(loadfile("tests/journey_bench.lua"))()
print("journey_spec: ok")
