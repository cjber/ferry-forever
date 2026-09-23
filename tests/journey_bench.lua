-- Real Journey + nav data, one pump per simulated 60 Hz frame. Optional arg: a baseline source directory.
local root = arg[1] or "."
for _, case in ipairs({
	{ "Auberdine -> Tanaris", 26, 39, "Alliance" },
	{ "Auberdine -> Eastern Plaguelands", 26, 67, "Alliance" },
	{ "Crossroads -> Thunder Bluff", 25, 22, "Horde" },
	{ "Ironforge -> Menethil", 6, 7, "Alliance" },
}) do
	local driver = assert(loadfile("tests/journey_driver.lua"))(root)
	local ns = driver.ns
	for _, file in ipairs({
		"Data/Routes.lua",
		"Data/Transports.lua",
		"Data/Taxi.lua",
		"Data/Portals.lua",
		"Data/Walks.lua",
		"Path.lua",
	}) do
		driver.load(file)
	end
	for _, map in ipairs({ 0, 1, 2991 }) do
		assert(loadfile("ShortestPathForever_Nav" .. map .. "/Nav" .. map .. ".lua"))()
	end
	local fromName, toName = case[1]:match("^(.-) %-> (.+)$")
	assert(ns.TaxiNodes[case[2]].name:find(fromName, 1, true), "wrong benchmark origin")
	assert(ns.TaxiNodes[case[3]].name:find(toName, 1, true), "wrong benchmark destination")
	ns.faction, ns.db.debug = case[4], true
	ns.Print = function(message)
		error(message)
	end
	local jobs, nextFrame, rounds, resets, plannerCPU = {}, nil, 0, 0, 0
	local drawn = {}
	local draw = ns.SetJourneyRoute
	ns.SetJourneyRoute = function(g, r)
		for _, leg in ipairs(r and r.legs or {}) do
			if leg.mode == "walk" then
				local key = table.concat({ leg.from.map, leg.from.x, leg.from.y, leg.to.x, leg.to.y }, ":")
				if drawn[key] and #ns.Planner.LegPoints(leg, ns.Routes) == 2 then
					resets = resets + 1
				end
				if leg.measured and #leg.walkPoints > 2 then
					drawn[key] = true
				end
			end
		end
		draw(g, r)
	end
	local plan = ns.Planner.Plan
	ns.Planner.Plan = function(options)
		rounds = rounds + 1
		local started = os.clock()
		local planned = plan(options)
		plannerCPU = plannerCPU + (os.clock() - started) * 1000
		return planned
	end
	for _, method in ipairs({ "Find", "FindMany" }) do
		local find = ns.Path[method]
		if find then
			ns.Path[method] = function(...)
				local job = find(...)
				job.method = method
				jobs[#jobs + 1] = job
				return job
			end
		end
	end
	ns.Path.after = function(fn)
		nextFrame = fn
	end
	driver.begin(ns.TaxiNodes[case[2]], ns.TaxiNodes[case[3]])
	local frames = 0
	while nextFrame do
		local fn = nextFrame
		nextFrame = nil
		fn()
		frames = frames + 1
		driver.update(1 / 60)
		assert(frames < 20000, "journey did not settle")
	end
	local cpu, many, probes = 0, 0, 0
	for _, job in ipairs(jobs) do
		cpu = cpu + job.cpu
		if job.costOnly then
			probes = probes + 1
		end
		if job.method == "FindMany" then
			many = many + 1
			print(string.format("  FindMany map %d: %.1f ms, %d slices", job.map, job.cpu, job.frames))
		end
	end
	local settling, round = ns.JourneyStatus()
	assert(not settling)
	assert(driver.shown(), "expected reachable journey")
	print(
		string.format(
			"%s: %d searches (%d many, %d probes), %d planner calls, %d settle rounds, %d frames, "
				.. "%.1f ms search, %.1f ms planner, %d straight resets",
			case[1],
			#jobs,
			many,
			probes,
			rounds,
			round,
			frames,
			cpu,
			plannerCPU,
			resets
		)
	)
	if ns.Path.FindMany then
		assert(many == 2 and round == 1 and rounds >= 2, "one committed route")
		assert(resets == 0, "drawn walks cannot revert to straight lines")
	end
	ns.ClearJourney()
end
