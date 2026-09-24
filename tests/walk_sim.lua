-- Follow real Journey geometry at seven yards/second, including its timed start-cost refreshes.
-- Transport steps advance to their arrival; no client APIs or SavedVariables are used.
for _, case in ipairs({
	{ "Auberdine -> Tanaris", 26, 39, "Alliance" },
	{ "Auberdine -> Eastern Plaguelands", 26, 67, "Alliance" },
	{ "Crossroads -> Thunder Bluff", 25, 22, "Horde" },
	{ "Ironforge -> Menethil", 6, 7, "Alliance" },
}) do
	local driver = assert(loadfile("tests/journey_driver.lua"))()
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
		assert(loadfile("tools/load_nav.lua"))(map)
	end
	local fromName, toName = case[1]:match("^(.-) %-> (.+)$")
	assert(ns.TaxiNodes[case[2]].name:find(fromName, 1, true), "wrong benchmark origin")
	assert(ns.TaxiNodes[case[3]].name:find(toName, 1, true), "wrong benchmark destination")
	ns.faction = case[4]
	local frame, batches, flips, steps, transfers = nil, 0, 0, 0, 0
	ns.Path.after = function(fn)
		frame = fn
	end
	local many = ns.Path.FindMany
	ns.Path.FindMany = function(...)
		batches = batches + 1
		return many(...)
	end
	local function drain()
		while frame do
			local fn = frame
			frame = nil
			fn()
			driver.update(1 / 60)
		end
	end
	local here = ns.TaxiNodes[case[2]]
	driver.begin(here, ns.TaxiNodes[case[3]])
	drain()
	local current, points, segment, offset
	while driver.shown() do
		local leg = driver.shown().legs[1]
		assert(leg, "empty journey")
		-- A replan restarts the same goal from the player, so its endpoint can move by rounding alone.
		local to, was = leg.to, current and current.to
		if was and (to.map ~= was.map or (to.x - was.x) ^ 2 + (to.y - was.y) ^ 2 >= 1) then
			local gap = here.map == current.to.map
				and math.sqrt((here.x - current.to.x) ^ 2 + (here.y - current.to.y) ^ 2)
			if not gap or gap > 15 then
				flips = flips + 1
			end
			current = nil
		end
		-- The tram interior (369) has no shipped nav map. Simulate its station transfers by endpoints,
		-- as with the ride itself; every walking leg on the three nav maps must have real geometry.
		if leg.mode == "walk" and not (leg.from.map == 369 and leg.walkError == "nodata") then
			assert(
				leg.measured and #leg.walkPoints >= 2,
				"walk must have settled geometry: "
					.. case[1]
					.. ", map "
					.. leg.from.map
					.. ", "
					.. tostring(leg.walkError)
			)
			if not current then
				current, points, segment, offset = leg, leg.walkPoints, 2, 0
			end
			local travel = 35
			while travel > 0 and segment <= #points do
				local a, b = points[segment - 1], points[segment]
				local length = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
				local step = math.min(travel, length - offset)
				offset, travel = offset + step, travel - step
				local t = length > 0 and offset / length or 1
				here = {
					map = a.map,
					x = a.x + (b.x - a.x) * t,
					y = a.y + (b.y - a.y) * t,
					z = a.z and b.z and a.z + (b.z - a.z) * t,
				}
				if offset >= length then
					segment, offset = segment + 1, 0
				end
			end
			driver.move(here)
			driver.update(5)
		else
			if leg.mode == "walk" then
				transfers = transfers + 1
			end
			current = nil
			here = leg.to
			driver.move(here)
			driver.update(math.max(0.1, (leg.arrive - ns.NowMs()) / 1000))
		end
		drain()
		steps = steps + 1
		assert(steps < 10000, "walking simulation did not arrive")
	end
	print(
		string.format(
			"%s: %d steps, %d batches, %d route flips, %d tram transfers",
			case[1],
			steps,
			batches,
			flips,
			transfers
		)
	)
	assert(flips == 0, "following the drawn route must not flip it")
	ns.ClearJourney()
end
