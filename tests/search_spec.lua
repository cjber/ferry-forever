local function scenario(oldSeconds, newSeconds)
	local driver = assert(loadfile("tests/journey_driver.lua"))()
	local ns = driver.ns
	driver.load("Arrow.lua")
	local batches, jobs, draws = {}, {}, {}
	local choice, exact = "A", false
	local from, goal = { map = 1, x = 0, y = 0 }, { map = 1, x = 1000, y = 0 }
	local via = { A = { map = 1, x = 500, y = 100 }, B = { map = 1, x = 500, y = 200 } }
	ns.Path = {
		HasData = function()
			return true
		end,
		LowerBound = function()
			return 0
		end,
		FindMany = function(_, _, targets, callback)
			local job = { targets = targets, callback = callback }
			batches[#batches + 1] = job
			return job
		end,
		Find = function(_, a, b, callback)
			local job = { from = a, to = b, callback = callback }
			jobs[#jobs + 1] = job
			return job
		end,
		Cancel = function(job)
			job.cancelled = true
		end,
	}
	local draw = ns.SetJourneyRoute
	ns.SetJourneyRoute = function(g, r)
		draws[#draws + 1] = r or false
		draw(g, r)
	end
	ns.Planner.Plan = function(o)
		local seconds = choice == "A" and (exact and oldSeconds or 100) or newSeconds
		return {
			arrive = o.now + seconds * 1000,
			needsStart = not exact,
			needsGoal = not exact,
			legs = {
				{
					mode = "walk",
					from = o.from,
					to = via[choice],
					yards = seconds * 7,
					depart = o.now,
					arrive = o.now + seconds * 1000,
				},
				{
					mode = "passage",
					from = via[choice],
					to = o.to,
					depart = o.now + seconds * 1000,
					arrive = o.now + seconds * 1000,
				},
			},
		}
	end
	local function costs(nextChoice)
		choice, exact = nextChoice, true
		for _, batch in ipairs(batches) do
			if not batch.done and not batch.cancelled then
				batch.done = true
				batch.callback({}, nil, batch)
			end
		end
	end
	local function geometry(fail)
		for _, job in ipairs(jobs) do
			if not job.done and not job.cancelled then
				job.done = true
				local failed = fail == true or fail == "A" and job.to == via.A
				job.callback(
					not failed and { job.from, job.to } or nil,
					failed and "unreachable" or (job.to == via.A and oldSeconds or newSeconds) * 7,
					job
				)
			end
		end
	end
	driver.begin(from, goal)
	return driver,
		ns,
		draws,
		costs,
		geometry,
		function()
			return #jobs
		end,
		function()
			exact = false
			driver.update(60)
		end
end

-- Both cost and geometry callbacks must finish before the single visible commit.
do
	local driver, ns, draws, costs, geometry = scenario(300, 200)
	local title, rows, route, _, loading = ns.JourneyInfo()
	assert(title == "Journey to Test" and rows[1].text == "Finding the fastest way…" and rows[1].grey)
	assert(not route and loading and not driver.shown() and not driver.waypoint())
	local count = #draws
	driver.update(1)
	costs("B")
	assert(#draws == count and not driver.shown() and not driver.waypoint())
	geometry()
	assert(#draws == count + 1 and driver.shown() and not ns.JourneyStatus())
	driver.update(0.1)
	assert(driver.waypoint() and not select(5, ns.JourneyInfo()))
	ns.ClearJourney()
end

for _, case in ipairs({ { 300, 275, false }, { 600, 560, false }, { 200, 175, false }, { 300, 270, true } }) do
	local driver, ns, draws, costs, geometry = scenario(case[1], case[2])
	driver.update(2.9)
	assert(not driver.shown())
	driver.update(0.1)
	local committed = assert(driver.shown()).legs[1].to
	assert(select(5, ns.JourneyInfo()), "grace commit retains the spinner")
	for _, row in ipairs((select(2, ns.JourneyInfo()))) do
		assert(not row.text:find("finding walking", 1, true) and not row.text:find("   ", 1, true))
	end
	local count = #draws
	geometry()
	assert(#draws == count, "measuring a grace route cannot redraw it")
	costs("B")
	assert(#draws == count, "a different bounded plan cannot redraw the grace route")
	geometry()
	assert((driver.shown().legs[1].to ~= committed) == case[3], "both switch thresholds use settled old legs")
	assert(#draws == count + 1 and not select(5, ns.JourneyInfo()))
	geometry()
	assert(#draws == count + 1, "at most one settled swap per search")
	ns.ClearJourney()
end

-- Timed background work never publishes a loading state or intermediate plan.
do
	local driver, ns, draws, costs, geometry, _, refresh = scenario(300, 275)
	costs("A")
	geometry()
	local route, count = driver.shown(), #draws
	refresh()
	assert(not select(5, ns.JourneyInfo()) and driver.shown() == route)
	costs("B")
	geometry()
	assert(#draws == count and driver.shown() == route and not ns.JourneyStatus())
	ns.ClearJourney()
end

-- A geometry failure invalidates the grace route even if the replacement misses the margin.
do
	local driver, ns, _, costs, geometry = scenario(300, 295)
	driver.update(3)
	local old = driver.shown().legs[1].to
	costs("B")
	geometry("A")
	assert(driver.shown().legs[1].to ~= old and not ns.JourneyStatus())
	ns.ClearJourney()
end

do
	local driver, ns, draws, costs, geometry, _, refresh = scenario(300, 200)
	costs("A")
	geometry()
	local route, count = driver.shown(), #draws
	refresh()
	costs("B")
	assert(driver.shown() == route and #draws == count and not select(5, ns.JourneyInfo()))
	geometry()
	assert(driver.shown().legs[1].to ~= route.legs[1].to and #draws == count + 1)
	ns.ClearJourney()
end

-- Moving through many origins must evict old walks; clearing also discards a still-reusable recent walk.
do
	local driver, ns, _, costs, geometry, jobCount = scenario(300, 275)
	costs("A")
	geometry()
	for i = 1, 70 do
		driver.move({ map = 1, x = 0, y = -i * 50 })
		driver.update(60)
		costs("A")
		geometry()
	end
	local count = jobCount()
	driver.move({ map = 1, x = 0, y = 0 })
	driver.update(60)
	costs("A")
	geometry()
	assert(jobCount() == count + 1, "the oldest origin's geometry must have been evicted")
	ns.ClearJourney()
	driver.begin({ map = 1, x = 0, y = 0 }, { map = 1, x = 1000, y = 0 })
	costs("A")
	geometry()
	assert(jobCount() == count + 2, "clear must release even the most recent walk")
	ns.ClearJourney()
end

print(
	"search_spec: hidden previews, atomic commit, grace thresholds, one swap, invalid route and silent background: ok"
)
