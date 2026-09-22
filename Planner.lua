local _, ns = ...

local Model = ns.Model
local Planner = {}
ns.Planner = Planner

local BOARDING = 3000

local function QuestPointValid(point)
	return point
		and type(point.uiMapID) == "number"
		and point.uiMapID > 0
		and type(point.x) == "number"
		and point.x >= 0
		and point.x <= 1
		and type(point.y) == "number"
		and point.y >= 0
		and point.y <= 1
end

-- Native POIs already describe the quest's current state. A completed quest prefers its
-- destination POI (turn-in) over a next waypoint that may still describe the last objective.
function Planner.QuestDestination(questID, title, complete, uiMapID, pois, waypoint)
	local destination
	for _, poi in ipairs(pois or {}) do
		if poi.questID == questID and not poi.isQuestStart then
			-- As in QuestDataProvider, x/y belong to the queried map, even for child-map POIs.
			local point = { uiMapID = uiMapID, x = poi.x, y = poi.y }
			if QuestPointValid(point) then
				destination = point
				break
			end
		end
	end
	if QuestPointValid(waypoint) and (not complete or not destination) then
		destination = { uiMapID = waypoint.uiMapID, x = waypoint.x, y = waypoint.y }
	end
	if destination and title and title ~= "" then
		destination.label = title .. (complete and " (turn in)" or "")
		return destination
	end
end

-- Preview geometry while a walking leg is still pending.
function Planner.WalkPoints(from, to)
	return { { map = from.map, x = from.x, y = from.y }, { map = to.map, x = to.x, y = to.y } }
end

-- World points in travel order; jump marks a teleport to the next point. Keep this free of map APIs.
function Planner.LegPoints(leg, routes)
	if leg.mode == "walk" then
		return leg.walkPoints or Planner.WalkPoints(leg.from, leg.to)
	end
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
		if route and route.frames and leg.aboard and alighting then
			-- Only the remaining geometry, including any continent jump ahead of the player.
			local remaining = leg.arrive - leg.depart
			local ordered = {}
			for index, frame in ipairs(route.frames) do
				local untilDock = (alighting.arrive - frame[1]) % route.period
				if untilDock > 0 and untilDock < remaining then
					ordered[#ordered + 1] = { frame = frame, remaining = untilDock, index = index }
				end
			end
			table.sort(ordered, function(a, b)
				return a.remaining > b.remaining or (a.remaining == b.remaining and a.index < b.index)
			end)
			for _, entry in ipairs(ordered) do
				local frame = entry.frame
				points[#points + 1] = { map = frame[3], x = frame[4], y = frame[5], jump = frame[6] }
			end
		elseif route and route.frames and boarding and alighting then
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
	-- Portal endpoints are drawn as separate marks.
	points[#points + 1] = { map = leg.to.map, x = leg.to.x, y = leg.to.y }
	return points
end

function Planner.Landmass(node, landmasses)
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

local function Gap(a, b)
	local dz = a.z and b.z and a.z - b.z or 0
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + dz ^ 2)
end

local function SamePoint(a, b)
	return a.map == b.map and a.x == b.x and a.y == b.y and a.z == b.z
end

-- Endpoint batches supply directed, exact running-yard costs (false for no path). Later entries override earlier
-- ones for Remaining(). Straight lines are only previews or the fallback on maps without walking data.
local function WalkCost(options, a, b)
	local walks = options.walks or {}
	for index = #walks, 1, -1 do
		local walk = walks[index]
		if SamePoint(walk.from, a) and SamePoint(walk.to, b) then
			return walk.cost, false
		end
	end
	if options.exactMaps and options.exactMaps[a.map] then
		return false, false
	end
	return Gap(a, b), true
end

-- A fixed place's key in the baked walk table (Data/Walks.lua); nil for where you stand and where you are going.
local function PlaceKey(node)
	if node.kind ~= "start" and node.kind ~= "goal" then
		return node.kind .. node.id
	end
end

-- options.baked holds walks searched ahead of time between fixed places, per map; options.waterWalking picks
-- which of their two costs applies.
local function BakedCost(options, a, b)
	local ka, kb = PlaceKey(a), PlaceKey(b)
	local baked = ka and kb and options.baked and options.baked[a.map]
	local pair = baked and baked[ka < kb and ka .. " " .. kb or kb .. " " .. ka]
	if pair then
		local mode = options.waterWalking and 2 or 1
		return true, pair[mode + (ka > kb and pair[3] ~= nil and 2 or 0)]
	end
	return false
end

-- The same fixed places feed the planner and endpoint batches. Keeping their identities here
-- prevents a new dock or portal from silently retaining an estimated start/goal edge.
function Planner.Places(options)
	local places = {}
	local function add(kind, id, point, label)
		places[#places + 1] = {
			kind = kind,
			id = id,
			map = point.map,
			x = point.x,
			y = point.y,
			z = point.z,
			label = label or point.label,
		}
	end
	for _, id in ipairs(Keys(options.docks or {})) do
		add("dock", id, options.docks[id])
	end
	for _, id in ipairs(Keys(options.taxiNodes or {})) do
		local node = options.taxiNodes[id]
		if Eligible(node, options) then
			add("taxi", id, node)
		end
	end
	for id, portal in ipairs(options.portals or {}) do
		if not portal.requires and Eligible(portal, options) then
			add("portal", id * 2 - 1, portal.from)
			add("portal", id * 2, portal.to, portal.name and portal.name:gsub("^%a+ to ", ""))
		end
	end
	return places
end

-- Changing arrival states must not turn a round trip into a shortcut around a measured continuous walk.
local function Revisits(previous, current, target, count)
	while current do
		if (current - 1) % count + 1 == target then
			return true
		end
		current = previous[current] and previous[current].index
	end
	return false
end

function Planner.Plan(options)
	local nodes, edges, masses = {}, {}, {}
	local docks, taxis, portals = {}, {}, {}
	local speed = options.walkSpeed or 7
	assert(speed > 0, "walkSpeed must be positive")

	local function Add(kind, id, point)
		local index = #nodes + 1
		nodes[index] =
			{ kind = kind, id = id, map = point.map, x = point.x, y = point.y, z = point.z, label = point.label }
		edges[index] = {}
		masses[index] = Planner.Landmass(point, options.landmasses or {})
		return index
	end

	local function Edge(from, to, edge)
		edge.to = to
		edges[from][#edges[from] + 1] = edge
	end

	local start, goal = Add("start", nil, options.from), Add("goal", nil, options.to)
	for _, place in ipairs(Planner.Places(options)) do
		local index = Add(place.kind, place.id, place)
		if place.kind == "dock" then
			docks[place.id] = index
		elseif place.kind == "taxi" then
			taxis[place.id] = index
			nodes[index].undiscovered = options.taxiKnown ~= nil and not options.taxiKnown[place.id]
		else
			portals[place.id] = index
		end
	end
	for id, portal in ipairs(options.portals or {}) do
		local from, to = portals[id * 2 - 1], portals[id * 2]
		if from and to then
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
							duration = Model.RideTime(route, stop, onward),
						})
					end
				end
			end
		end
	end
	local ride = options.ride
	if ride and docks[ride.dock] and (options.routes or {})[ride.route] then
		local route = options.routes[ride.route]
		for _, stop in ipairs(route.stops) do
			if stop.dock == ride.dock then
				Edge(start, docks[ride.dock], {
					mode = route.kind,
					route = ride.route,
					aboard = true,
					alighting = stop,
					duration = math.max(0, ride.arrive - options.now),
				})
				break
			end
		end
	end
	for from, a in ipairs(nodes) do
		for to = from + 1, #nodes do
			local b = nodes[to]
			if a.map == b.map and masses[from] == masses[to] and not (ride and from == start) then
				for direction = 1, 2 do
					local first, last = direction == 1 and from or to, direction == 1 and to or from
					local origin, destination = nodes[first], nodes[last]
					local baked, yards, estimated = BakedCost(options, origin, destination)
					if not baked then
						yards, estimated = WalkCost(options, origin, destination)
					end
					if yards then
						Edge(first, last, {
							mode = "walk",
							duration = yards / speed * 1000,
							yards = yards,
							estimated = estimated,
						})
					end
				end
			end
		end
	end

	-- Keep arrivals on foot separate from transit and flight. Splitting a continuous walk at arbitrary places
	-- invents fresh straight-line shortcuts around a measured detour (or a blocked walk), so it must be one search.
	-- Zero-length transfers still connect co-located places and break a flight for boarding costs.
	local count = #nodes
	local arrival, visited, previous = { [start] = options.now }, {}, {}
	local finishAt
	for _ = 1, count * 3 do
		local current, earliest
		for index = 1, count * 3 do
			if not visited[index] and arrival[index] and (not earliest or arrival[index] < earliest) then
				current, earliest = index, arrival[index]
			end
		end
		if not current then
			return nil
		end
		local node = (current - 1) % count + 1
		if node == goal then
			finishAt = current
			break
		end
		visited[current] = true
		local flying, walked = current > count and current <= count * 2, current > count * 2
		for _, edge in ipairs(edges[node]) do
			-- Unknown nodes may be learned on foot or crossed in flight, but never used to land.
			local canLeave = not flying or not nodes[node].undiscovered or edge.mode == "flight"
			if walked and edge.mode == "walk" and edge.yards > 0 then
				canLeave = false
			end
			local wait, estimated = 0, edge.estimated or false
			if edge.route and not edge.aboard then
				local route = options.routes[edge.route]
				local anchor = (options.anchors or {})[edge.route]
				if anchor then
					local _, _, departIn = Model.Visit(route, edge.stop, (earliest - anchor.epoch) % route.period)
					wait = departIn
				else
					wait, estimated = route.period / 2, true
				end
			elseif edge.mode == "flight" and not flying then
				wait = BOARDING
			end
			local depart = earliest + wait
			local finish = depart + edge.duration
			local target = edge.to + (edge.mode == "flight" and count or 0)
			if edge.mode == "walk" and (walked or edge.yards > 0) then
				target = edge.to + count * 2
			end
			if
				canLeave
				and not visited[target]
				and (not arrival[target] or finish < arrival[target])
				and not Revisits(previous, current, edge.to, count)
			then
				arrival[target] = finish
				previous[target] = {
					index = current,
					leg = {
						mode = edge.mode,
						from = nodes[node],
						to = nodes[edge.to],
						depart = depart,
						arrive = finish,
						wait = wait,
						estimated = estimated,
						route = edge.route,
						aboard = edge.aboard,
						boarding = edge.stop,
						alighting = edge.alighting,
						hops = edge.path and { edge.path } or nil,
						yards = edge.yards,
					},
				}
			end
		end
	end
	if not finishAt then
		return nil
	end
	local reversed, legs, current = {}, {}, finishAt
	while previous[current] do
		reversed[#reversed + 1] = previous[current].leg
		current = previous[current].index
	end
	for index = #reversed, 1, -1 do
		local leg, last = reversed[index], legs[#legs]
		local preceding = reversed[index + 1]
		if leg.mode == "flight" and last and preceding.mode == "flight" then
			last.to, last.arrive = leg.to, leg.arrive
			last.hops[#last.hops + 1] = leg.hops[1]
			-- Connecting hops stay in flight; only the initial departure pays boarding.
			last.estimated = last.estimated or leg.estimated
		elseif leg.mode ~= "walk" or leg.arrive > leg.depart or #reversed == 1 then
			legs[#legs + 1] = leg
		end
	end
	return { arrive = arrival[finishAt], legs = legs }
end
