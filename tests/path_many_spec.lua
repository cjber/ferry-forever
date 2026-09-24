local ns = {}
for _, file in ipairs({ "PathGrid.lua", "Path.lua", "PathJobs.lua" }) do
	assert(loadfile(file))("ShortestPathForever", ns)
end
assert(loadfile("Data/Taxi.lua"))("ShortestPathForever", ns)
for _, map in ipairs({ 0, 1, 2991 }) do
	assert(loadfile("tools/load_nav.lua"))(map)
end
local Path = ns.Path

-- Verify the shipped graph, not just the generator: every reverse edge exists with both identical costs.
local alphabet, digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", {}
for i = 1, #alphabet do
	digits[alphabet:byte(i)] = i - 1
end
local function number(s, at, width)
	local n = 0
	for i = at, at + width - 1 do
		n = n * 64 + digits[s:byte(i)]
	end
	return n
end
for _, map in ipairs({ 0, 1, 2991 }) do
	local data, edges, count = ShortestPathForeverPathData[map], {}, 0
	for cluster, chunks in pairs(data.graph) do
		local s, k = chunks, cluster - 1
		local n = number(s, 1, 2)
		local at = 3 + n * 7
		for i = 0, n - 1 do
			local id = k * 4096 + i
			edges[id] = {}
			for _ = 1, number(s, 3 + i * 7 + 6, 1) do
				local offset = number(s, at, 1)
				local other = k + (math.floor(offset / 3) - 1) * data.ny + offset % 3 - 1
				local target = other * 4096 + number(s, at + 1, 2)
				edges[id][target] = s:sub(at + 3, at + 6)
				at, count = at + 7, count + 1
			end
		end
	end
	for from, adjacent in pairs(edges) do
		for to, costs in pairs(adjacent) do
			assert(edges[to] and edges[to][from] == costs, "asymmetric graph edge")
		end
	end
	print(string.format("map %d: %d symmetric directed edges", map, count))
end

local comparisons = 0
local function compare(map, from, targets, water)
	local costs = Path.FindManySync(map, from, targets, water)
	local reverse = Path.FindManySync(map, from, targets, water, true)
	for i, to in ipairs(targets) do
		local points, cost = Path.FindSync(map, from, to, water)
		assert(
			points and math.abs(costs[i] - cost) < 1e-6 or not points and costs[i] == false,
			string.format("forward %d/%d: %s vs %s", map, i, tostring(costs[i]), tostring(cost))
		)
		if points then
			assert(Path.LowerBound(map, from, to) <= cost + 1e-6, "geometric bound exceeded a forward cost")
		end
		points, cost = Path.FindSync(map, to, from, water)
		assert(
			points and math.abs(reverse[i] - cost) < 1e-6 or not points and reverse[i] == false,
			string.format("reverse %d/%d: %s vs %s", map, i, tostring(reverse[i]), tostring(cost))
		)
		if points then
			assert(Path.LowerBound(map, to, from) <= cost + 1e-6, "geometric bound exceeded a reverse cost")
		end
		comparisons = comparisons + 2
	end
end
for _, id in ipairs({ 26, 6, 25 }) do
	local from, targets = ns.TaxiNodes[id], {}
	for _, target in pairs(ns.TaxiNodes) do
		if target.map == from.map then
			targets[#targets + 1] = target
		end
	end
	targets[#targets + 1] = { x = 0, y = 100000 }
	targets[#targets + 1] = { x = 5500, y = -1500 }
	for _, water in ipairs({ false, true }) do
		compare(from.map, from, targets, water)
	end
end
-- Same-cluster, zero distance, rooftop fallback, layered landings and directed local water costs.
for _, water in ipairs({ false, true }) do
	compare(0, { x = -5293, y = -3157 }, {
		{ x = -5293, y = -3157 },
		{ x = -5300, y = -3200 },
		{ x = -5293, y = -3220 },
		{ x = -9010, y = 870 },
		{ x = 1596.15, y = 291.8, z = -40.784 },
		{ x = 1596.15, y = 291.8, z = 55.718 },
	}, water)
end
local off = Path.FindManySync(1, { x = 5500, y = -1500 }, { ns.TaxiNodes[27] })
assert(off[1] == false)
local missing, reason = Path.FindManySync(999, { x = 0, y = 0 }, { { x = 1, y = 1 } })
assert(missing[1] == false and reason == "nodata")

local frame, called, done
Path.after = function(fn)
	frame = fn
end
Path.budget = -1
local cancelled = Path.FindMany(1, ns.TaxiNodes[27], { ns.TaxiNodes[32] }, function()
	called = true
end)
frame()
assert(cancelled.frames == 1 and coroutine.status(cancelled.co) == "suspended")
Path.Cancel(cancelled)
local job = Path.FindMany(1, ns.TaxiNodes[27], { ns.TaxiNodes[32] }, function(costs, err, finished)
	assert(costs[1] and not err)
	done = finished
end)
Path.budget = 3
while frame do
	local fn = frame
	frame = nil
	fn()
end
assert(not called and done == job and job.frames > 1)
-- An invalid job reports one terminal error and leaves a geometry job behind it runnable.
local previousHandler, reported, failures = rawget(_G, "geterrorhandler"), nil, 0
rawset(_G, "geterrorhandler", function()
	return function(message)
		reported = message
	end
end)
Path.FindMany(0, { x = "invalid", y = 0 }, { { x = 0, y = 0 } }, function(costs, err)
	assert(costs == nil and err == "error")
	failures = failures + 1
end)
local recovered
Path.Find(0, { x = -9459, y = 43 }, { x = -8914, y = -135 }, function(points)
	recovered = points
end)
while frame do
	local fn = frame
	frame = nil
	fn()
end
rawset(_G, "geterrorhandler", previousHandler)
assert(reported and failures == 1 and recovered)
print(string.format("path_many_spec: %d exact forward/reverse comparisons, queue and cancellation ok", comparisons))

-- Every published frontier bounds every still-unsettled target, even while another map's local grid
-- search owns the scratch heap. Pausing one batch must leave its peer and a geometry search runnable.
local isolated = {}
for _, file in ipairs({ "PathGrid.lua", "Path.lua", "PathJobs.lua" }) do
	assert(loadfile(file))("ShortestPathForever", isolated)
end
Path = isolated.Path
Path.clusters = 4
Path.after = function(fn)
	frame = fn
end
local sources = { ns.TaxiNodes[26], ns.TaxiNodes[6] }
local targetLists = {
	{ ns.TaxiNodes[27], ns.TaxiNodes[39], ns.TaxiNodes[26], { x = 5500, y = -1500 } },
	{ ns.TaxiNodes[7], ns.TaxiNodes[6], ns.TaxiNodes[67] },
}
local expected, incremental, complete = {}, {}, {}
for i, from in ipairs(sources) do
	expected[i] = Path.FindManySync(from.map, from, targetLists[i], i == 2, i == 2)
end
local realClock, fakeTime, pauses = Path.clock, 0, 0
Path.clock = function()
	fakeTime = fakeTime + 0.01
	return fakeTime
end
Path.budget = 0.05
local function check(i, costs, current)
	for target, cost in ipairs(expected[i]) do
		if costs[target] ~= nil then
			assert(costs[target] == cost, "an incremental cost must already be exact")
		elseif cost then
			assert(current.radius <= cost + 1e-6, "frontier exceeded an unsettled target's cost")
		end
	end
end
for i, from in ipairs(sources) do
	incremental[i] = Path.FindMany(
		from.map,
		from,
		targetLists[i],
		function(costs, err, current)
			assert(not err)
			check(i, costs, current)
			complete[i] = true
		end,
		i == 2,
		i == 2,
		function(costs, _, current)
			check(i, costs, current)
			if i == 1 and pauses == 0 and current.radius > 0 then
				Path.Pause(current)
				pauses = pauses + 1
			end
		end
	)
end
local geometry
Path.Find(1, ns.TaxiNodes[26], ns.TaxiNodes[39], function(points)
	geometry = points
end)
while frame do
	local fn = frame
	frame = nil
	fn()
end
assert(pauses == 1 and not complete[1] and complete[2] and geometry)
local released = incremental[1]
local callback, progressCallback, savedCosts = released.callback, released.progress, released.costs
Path.ReleaseMany(released)
assert(not released.co and not released.scratch and not released.callback and not released.progress)
assert(released.costs == savedCosts and Path.ReuseMany(released, sources[1]))
released.callback, released.progress = callback, progressCallback
Path.Resume(released)
while frame do
	local fn = frame
	frame = nil
	fn()
end
assert(complete[1])
Path.clock, Path.budget = realClock, 3
print("incremental frontier bounds, cross-map interleaving, pause/release/resume and geometry: ok")
