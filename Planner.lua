local _, ns = ...

local Model = ns.Model
local Planner = {}
ns.Planner = Planner

local BOARDING = 3000

-- World points in travel order; jump marks a teleport to the next point. Keep this free of map APIs.
function Planner.LegPoints(leg, routes)
	local points = { { map = leg.from.map, x = leg.from.x, y = leg.from.y } }
	if leg.mode == "flight" then
		for _, hop in ipairs(leg.hops or {}) do
			for i = 1, #(hop.points or {}), 3 do
				points[#points + 1] = { map = hop.points[i], x = hop.points[i + 1], y = hop.points[i + 2] }
			end
		end
	elseif leg.route then
		local route = routes[leg.route]
		local boarding, alighting = leg.boarding, leg.alighting
		if route and route.frames and boarding and alighting then
			local duration = Model.RideTime(route, boarding, alighting)
			for index, frame in ipairs(route.frames) do
				if frame[2] % route.period == boarding.depart % route.period then
					points[1].jump = frame[6]
					for offset = 1, #route.frames - 1 do
						local nextFrame = route.frames[(index + offset - 1) % #route.frames + 1]
						local elapsed = (nextFrame[1] - boarding.depart) % route.period
						if elapsed >= duration then
							break
						end
						points[#points + 1] = {
							map = nextFrame[3],
							x = nextFrame[4],
							y = nextFrame[5],
							jump = nextFrame[6],
						}
					end
					break
				end
			end
		end
	end
	-- Walks are straight: we have no collision map. Portal endpoints are drawn as separate marks.
	points[#points + 1] = { map = leg.to.map, x = leg.to.x, y = leg.to.y }
	return points
end

local function Landmass(node, landmasses)
	for index, land in ipairs(landmasses) do
		if
			node.map == land.map
			and node.x >= land.minX
			and node.x <= land.maxX
			and node.y >= land.minY
			and node.y <= land.maxY
		then
			return index
		end
	end
end

local function Eligible(node, options)
	return not node.faction or node.faction == options.faction
end

local function Keys(values)
	local keys = {}
	for key in pairs(values) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

function Planner.Plan(options)
	local nodes, edges, masses = {}, {}, {}
	local docks, taxis = {}, {}
	local speed = options.walkSpeed or 7
	assert(speed > 0, "walkSpeed must be positive")

	local function Add(kind, id, point)
		local index = #nodes + 1
		nodes[index] = { kind = kind, id = id, map = point.map, x = point.x, y = point.y, z = point.z }
		edges[index] = {}
		masses[index] = Landmass(point, options.landmasses or {})
		return index
	end

	local function Edge(from, to, edge)
		edge.to = to
		edges[from][#edges[from] + 1] = edge
	end

	local start, goal = Add("start", nil, options.from), Add("goal", nil, options.to)
	for _, id in ipairs(Keys(options.docks or {})) do
		docks[id] = Add("dock", id, options.docks[id])
	end
	for _, id in ipairs(Keys(options.taxiNodes or {})) do
		local node = options.taxiNodes[id]
		if Eligible(node, options) and (not options.taxiKnown or options.taxiKnown[id]) then
			taxis[id] = Add("taxi", id, node)
		end
	end
	for id, portal in ipairs(options.portals or {}) do
		if not portal.requires and Eligible(portal, options) then
			local from, to = Add("portal", id * 2 - 1, portal.from), Add("portal", id * 2, portal.to)
			Edge(from, to, { mode = portal.kind, duration = portal.seconds * 1000 })
		end
	end
	for _, path in ipairs(options.taxiPaths or {}) do
		if taxis[path.from] and taxis[path.to] then
			Edge(taxis[path.from], taxis[path.to], {
				mode = "flight",
				path = path,
				duration = path.seconds * 1000,
				estimated = path.estimated,
			})
		end
	end
	for _, id in ipairs(Keys(options.routes or {})) do
		local route = options.routes[id]
		if route.kind ~= "lift" then
			for index, stop in ipairs(route.stops) do
				if docks[stop.dock] then
					for offset = 1, #route.stops - 1 do
						local onward = route.stops[(index + offset - 1) % #route.stops + 1]
						if docks[onward.dock] and onward.dock ~= stop.dock then
							Edge(docks[stop.dock], docks[onward.dock], {
								mode = route.kind,
								route = id,
								stop = stop,
								alighting = onward,
								stops = offset,
								duration = Model.RideTime(route, stop, onward),
							})
						end
					end
				end
			end
		end
	end
	for from, a in ipairs(nodes) do
		for to = from + 1, #nodes do
			local b = nodes[to]
			if a.map == b.map and masses[from] == masses[to] then
				local duration = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) / speed * 1000
				Edge(from, to, { mode = "walk", duration = duration, estimated = true })
				Edge(to, from, { mode = "walk", duration = duration, estimated = true })
			end
		end
	end

	local arrival, visited, previous = { [start] = options.now }, {}, {}
	for _ = 1, #nodes do
		local current, earliest
		for index in ipairs(nodes) do
			if not visited[index] and arrival[index] and (not earliest or arrival[index] < earliest) then
				current, earliest = index, arrival[index]
			end
		end
		if not current then
			return nil
		end
		if current == goal then
			break
		end
		visited[current] = true
		for _, edge in ipairs(edges[current]) do
			local wait, estimated = 0, edge.estimated or false
			if edge.route then
				local route = options.routes[edge.route]
				local anchor = (options.anchors or {})[edge.route]
				if anchor then
					local _, _, departIn = Model.Visit(route, edge.stop, (earliest - anchor.epoch) % route.period)
					wait = departIn
				else
					wait, estimated = route.period / 2, true
				end
			elseif edge.mode == "flight" then
				wait = BOARDING
			end
			local depart = earliest + wait
			local finish = depart + edge.duration
			if not visited[edge.to] and (not arrival[edge.to] or finish < arrival[edge.to]) then
				arrival[edge.to] = finish
				previous[edge.to] = {
					index = current,
					leg = {
						mode = edge.mode,
						from = nodes[current],
						to = nodes[edge.to],
						depart = depart,
						arrive = finish,
						wait = wait,
						estimated = estimated,
						route = edge.route,
						stops = edge.stops,
						boarding = edge.stop,
						alighting = edge.alighting,
						hops = edge.path and { edge.path } or nil,
					},
				}
			end
		end
	end
	if not arrival[goal] then
		return nil
	end
	local reversed, legs, current = {}, {}, goal
	while previous[current] do
		reversed[#reversed + 1] = previous[current].leg
		current = previous[current].index
	end
	for index = #reversed, 1, -1 do
		local leg, last = reversed[index], legs[#legs]
		if leg.mode == "flight" and last and last.mode == "flight" then
			last.to, last.arrive = leg.to, leg.arrive
			last.hops[#last.hops + 1] = leg.hops[1]
			-- Intermediate boarding is inside the leg; wait describes only its initial departure.
			last.estimated = last.estimated or leg.estimated
		elseif leg.mode ~= "walk" or leg.arrive > leg.depart or #reversed == 1 then
			legs[#legs + 1] = leg
		end
	end
	return { arrive = arrival[goal], legs = legs }
end
