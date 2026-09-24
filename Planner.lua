---@class SPFNamespace
local ns = select(2, ...)

local Model = ns.Model
---@class SPFPlanner
local Planner = {}
ns.Planner = Planner

local BOARDING = 3000
-- A teleport to another continent shows a loading screen: the same allowance as a portal's.
local LOADING = 5000

local function checkpoint()
	if ns.Path and ns.Path.Checkpoint then
		ns.Path.Checkpoint()
	end
end

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
---@param questID number
---@param title string?
---@param complete boolean
---@param uiMapID number?
---@param pois QuestPOIMapInfo[]?
---@param waypoint {uiMapID: number?, x: number?, y: number?}?
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
	if waypoint and QuestPointValid(waypoint) and (not complete or not destination) then
		destination = { uiMapID = waypoint.uiMapID, x = waypoint.x, y = waypoint.y }
	end
	if destination and title and title ~= "" then
		destination.label = title .. (complete and " (turn in)" or "")
		return destination
	end
end

-- Preview geometry while a walking leg is still pending.
---@param from SPFPoint
---@param to SPFPoint
---@return SPFWalkPoints
function Planner.WalkPoints(from, to)
	return { { map = from.map, x = from.x, y = from.y }, { map = to.map, x = to.x, y = to.y } }
end

-- World points in travel order; jump marks a teleport to the next point. Keep this free of map APIs.
---@param leg SPFLeg
---@param routes table<number, SPFRoute>
---@return SPFWalkPoints
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
	elseif leg.mode == "teleport" then
		-- Nothing to draw between the ends: a jump, marked at both.
		points[1].jump = 1
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

---@param node SPFPoint
---@param landmasses SPFLandmass[]
---@return number?
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

local function PointKey(point)
	return string.format(
		"%d:%.17g:%.17g:%s",
		point.map,
		point.x,
		point.y,
		point.z and string.format("%.17g", point.z) or ""
	)
end

-- Endpoint batches supply exact costs or lower bounds in running yards. Index once per plan: repeatedly
-- scanning every measurement for every edge made frequent bounded plans more expensive than their searches.
local function WalkCost(options, a, b, index)
	local from = index[a.pointKey]
	local walk = from and from[b.pointKey]
	if walk then
		return walk.cost, walk.estimated or false
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
---@param options SPFPlaceOptions
---@return SPFPlace[]
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
			-- Named from the portal itself: an end inside an instance such as the Deeprun Tram has no zone to fall
			-- back on.
			add("portal", id * 2 - 1, portal.from, assert(portal.name, "every portal needs a name"))
			add("portal", id * 2, portal.to, Planner.PortalDestination(portal))
		end
	end
	for id, teleport in ipairs(options.teleports or {}) do
		add("teleport", id, teleport)
	end
	return places
end

-- "Passage to Stormwind" leads to Stormwind.
function Planner.PortalDestination(portal)
	return (portal.name:gsub("^%a+ to ", ""))
end

-- A cheaper arrival only dominates another if it leaves at least the same onward choices. The no-revisit
-- rule depends on the path taken, so keeping just one arrival per travel mode can discard the fastest route.
local function Revisits(labels, current, target)
	while current do
		if labels.node[current] == target then
			return true
		end
		current = labels.parent[current]
	end
	return false
end

local function Subset(labels, first, second, target)
	while first do
		local node = labels.node[first]
		if node ~= target and not Revisits(labels, second, node) then
			return false
		end
		first = labels.parent[first]
	end
	return true
end

-- Only callers with immutable data tables opt in; replacing data or advancing revision rebuilds topology.
-- Taxi discovery is read each plan because the client mutates its known-node set in place.
local CACHE_KEYS = {
	"docks",
	"routes",
	"taxiNodes",
	"taxiPaths",
	"portals",
	"teleports",
	"landmasses",
	"baked",
	"faction",
	"waterWalking",
	"walkSpeed",
	"revision",
}

---@param options SPFPlanOptions
---@return SPFPlan?
-- sift: long-function - bounded label search shares topology and heap locals; splitting adds hot-path upvalues
function Planner.Plan(options)
	local cache = options.cache
	local topology = cache and cache.topology
	if topology then
		for _, key in ipairs(CACHE_KEYS) do
			if topology.options[key] ~= options[key] then
				topology = nil
				break
			end
		end
	end
	local nodes, edges, masses = {}, {}, {}
	local docks, taxis, portals, teleports = {}, {}, {}, {}
	if topology then
		nodes, edges, masses = topology.nodes, topology.edges, topology.masses
		docks, taxis, teleports = topology.docks, topology.taxis, topology.teleports
		for index, adjacent in ipairs(edges) do
			for i = #adjacent, topology.counts[index] + 1, -1 do
				adjacent[i] = nil
			end
		end
	end
	local walkIndex = {}
	for _, walk in ipairs(options.walks or {}) do
		local from, to = PointKey(walk.from), PointKey(walk.to)
		walkIndex[from] = walkIndex[from] or {}
		local previous = walkIndex[from][to]
		-- An unresolved alias must not replace an exact measurement of the same physical endpoint.
		if not previous or previous.estimated or not walk.estimated then
			walkIndex[from][to] = walk
		end
	end
	local speed = options.walkSpeed or 7
	assert(speed > 0, "walkSpeed must be positive")

	local function Add(kind, id, point)
		local index = #nodes + 1
		nodes[index] =
			{ kind = kind, id = id, map = point.map, x = point.x, y = point.y, z = point.z, label = point.label }
		nodes[index].pointKey = PointKey(point)
		edges[index] = {}
		masses[index] = Planner.Landmass(point, options.landmasses or {})
		return index
	end

	local function Edge(from, to, edge)
		edge.to = to
		edges[from][#edges[from] + 1] = edge
	end

	local start, goal = 1, 2
	if not topology then
		Add("start", nil, options.from)
		Add("goal", nil, options.to)
		for _, place in ipairs(Planner.Places(options)) do
			local index = Add(place.kind, place.id, place)
			if place.kind == "dock" then
				docks[place.id] = index
			elseif place.kind == "taxi" then
				taxis[place.id] = index
				nodes[index].undiscovered = options.taxiKnown ~= nil and not options.taxiKnown[place.id]
			elseif place.kind == "teleport" then
				teleports[place.id] = index
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
		-- Fixed baked edges and the remaining dynamic pairs share one topology build.
		local pairs = {}
		for from = 1, #nodes do
			checkpoint()
			for to = from + 1, #nodes do
				if from <= 2 then
					pairs[#pairs + 1], pairs[#pairs + 2] = from, to
				elseif nodes[from].map == nodes[to].map and masses[from] == masses[to] then
					local baked, yards = BakedCost(options, nodes[from], nodes[to])
					if not baked then
						pairs[#pairs + 1], pairs[#pairs + 2] = from, to
					else
						if yards then
							Edge(from, to, { mode = "walk", duration = yards / speed * 1000, yards = yards })
						end
						local _, reverse = BakedCost(options, nodes[to], nodes[from])
						if reverse then
							Edge(to, from, { mode = "walk", duration = reverse / speed * 1000, yards = reverse })
						end
					end
				end
			end
		end
		local counts, saved = {}, {}
		for i, adjacent in ipairs(edges) do
			counts[i] = #adjacent
		end
		for _, key in ipairs(CACHE_KEYS) do
			saved[key] = options[key]
		end
		topology = {
			nodes = nodes,
			edges = edges,
			masses = masses,
			docks = docks,
			taxis = taxis,
			teleports = teleports,
			counts = counts,
			options = saved,
			pairs = pairs,
		}
		if cache then
			cache.topology = topology
		end
	else
		-- Returned legs retain their endpoint objects; never move a previously drawn route in place.
		for i = 1, 2 do
			local point = i == 1 and options.from or options.to
			nodes[i] = {
				kind = i == 1 and "start" or "goal",
				map = point.map,
				x = point.x,
				y = point.y,
				z = point.z,
				label = point.label,
				pointKey = PointKey(point),
			}
			masses[i] = Planner.Landmass(point, options.landmasses or {})
		end
	end
	for id, index in pairs(taxis) do
		nodes[index].undiscovered = options.taxiKnown ~= nil and not options.taxiKnown[id]
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
	-- Teleports leave from where you stand, once each is ready: its cooldown is a wait, like a boat's.
	local ready = options.teleportReady or {}
	for id, teleport in ipairs(options.teleports or {}) do
		if ready[id] and teleports[id] then
			Edge(start, teleports[id], {
				mode = "teleport",
				teleport = teleport,
				ready = ready[id],
				duration = teleport.cast + (teleport.map ~= options.from.map and LOADING or 0),
			})
		end
	end
	for pair = 1, #topology.pairs, 2 do
		local from, to = topology.pairs[pair], topology.pairs[pair + 1]
		local a, b = nodes[from], nodes[to]
		if a.map == b.map and masses[from] == masses[to] and not (ride and from == start) then
			for direction = 1, 2 do
				local first, last = direction == 1 and from or to, direction == 1 and to or from
				local origin, destination = nodes[first], nodes[last]
				local yards, estimated = WalkCost(options, origin, destination, walkIndex)
				if yards and first ~= goal and last ~= start then
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
	-- Keep arrivals on foot separate from transit and flight. Splitting a continuous walk at arbitrary places
	-- invents fresh straight-line shortcuts around a measured detour (or a blocked walk), so it must be one search.
	-- Zero-length transfers still connect co-located places and break a flight for boarding costs.
	local count = #nodes
	-- Ignoring arrival modes and revisits gives an admissible remaining-time bound. It keeps the extra
	-- labels needed for correctness from exploring unrelated routes before reaching the destination.
	local backward, lower, done = {}, { [goal] = 0 }, {}
	for from, adjacent in ipairs(edges) do
		for _, edge in ipairs(adjacent) do
			local duration = edge.duration
			if edge.route and not edge.aboard and not (options.anchors or {})[edge.route] then
				duration = duration + options.routes[edge.route].period / 2
			end
			backward[edge.to] = backward[edge.to] or {}
			local list = backward[edge.to]
			list[#list + 1], list[#list + 2] = from, duration
		end
	end
	for _ = 1, count do
		checkpoint()
		local current, best
		for node, cost in pairs(lower) do
			if not done[node] and (not best or cost < best) then
				current, best = node, cost
			end
		end
		if not current then
			break
		end
		done[current] = true
		local adjacent = backward[current] or {}
		for i = 1, #adjacent, 2 do
			local node, cost = adjacent[i], best + adjacent[i + 1]
			if not lower[node] or cost < lower[node] then
				lower[node] = cost
			end
		end
	end
	local labels = topology.labels
		or {
			node = {},
			state = {},
			time = {},
			key = {},
			parent = {},
			edge = {},
			depart = {},
			wait = {},
			estimated = {},
			discarded = {},
		}
	for i = 1, labels.count or 0 do
		labels.discarded[i], labels.edge[i] = nil, nil
	end
	labels.node[1], labels.state[1], labels.time[1] = start, start, options.now
	labels.key[1], labels.parent[1] = options.now + (lower[start] or math.huge), nil
	topology.labels = labels
	local labelCount = 1
	labels.count = 1
	local states, heap = { [start] = { 1 } }, { 1 }
	local function push(id)
		local at = #heap + 1
		while at > 1 do
			local parent = math.floor(at / 2)
			if labels.key[heap[parent]] <= labels.key[id] then
				break
			end
			heap[at], at = heap[parent], parent
		end
		heap[at] = id
	end
	local function pop()
		local first, last = heap[1], table.remove(heap)
		if #heap > 0 then
			local at = 1
			while at * 2 <= #heap do
				local child = at * 2
				if child < #heap and labels.key[heap[child + 1]] < labels.key[heap[child]] then
					child = child + 1
				end
				if labels.key[last] <= labels.key[heap[child]] then
					break
				end
				heap[at], at = heap[child], child
			end
			heap[at] = last
		end
		return first
	end
	local finishAt
	while #heap > 0 do
		checkpoint()
		local current = pop()
		if not labels.discarded[current] then
			local node, earliest = labels.node[current], labels.time[current]
			local state = labels.state[current]
			if node == goal then
				finishAt = current
				break
			end
			local flying, walked = state > count and state <= count * 2, state > count * 2
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
				elseif edge.ready then
					wait = math.max(0, edge.ready - earliest)
				end
				local depart = earliest + wait
				local finish = depart + edge.duration
				local target = edge.to + (edge.mode == "flight" and count or 0)
				if edge.mode == "walk" and (walked or edge.yards > 0) then
					target = edge.to + count * 2
				end
				if canLeave and lower[edge.to] and not Revisits(labels, current, edge.to) then
					local peers = states[target] or {}
					local dominated = false
					for _, peer in ipairs(peers) do
						if
							not labels.discarded[peer]
							and labels.time[peer] <= finish
							and Subset(labels, peer, current, edge.to)
						then
							dominated = true
							break
						end
					end
					if not dominated then
						labelCount = labelCount + 1
						labels.count = labelCount
						local id = labelCount
						labels.node[id], labels.state[id], labels.time[id] = edge.to, target, finish
						labels.key[id], labels.parent[id], labels.edge[id] = finish + lower[edge.to], current, edge
						labels.depart[id], labels.wait[id], labels.estimated[id] = depart, wait, estimated
						for _, peer in ipairs(peers) do
							if
								not labels.discarded[peer]
								and finish <= labels.time[peer]
								and Subset(labels, id, peer)
							then
								labels.discarded[peer] = true
							end
						end
						states[target] = peers
						peers[#peers + 1] = id
						push(id)
					end
				end
			end
		end
	end
	labels.count = labelCount
	if not finishAt then
		return nil
	end
	local reversed, legs, current = {}, {}, finishAt
	local needsStart, needsGoal, pendingWalks = false, false, {}
	while labels.parent[current] do
		local edge = labels.edge[current]
		local leg = {
			mode = edge.mode,
			from = nodes[labels.node[labels.parent[current]]],
			to = nodes[labels.node[current]],
			depart = labels.depart[current],
			arrive = labels.time[current],
			wait = labels.wait[current],
			estimated = labels.estimated[current],
			route = edge.route,
			aboard = edge.aboard,
			boarding = edge.stop,
			alighting = edge.alighting,
			hops = edge.path and { edge.path } or nil,
			yards = edge.yards,
			teleport = edge.teleport,
			ready = edge.ready,
		}
		-- Zero-cost lower bounds may disappear from the displayed steps, but still need proof.
		if leg.mode == "walk" and leg.estimated then
			if leg.from.kind == "start" or leg.to.kind == "goal" then
				pendingWalks[#pendingWalks + 1] = leg
			end
			needsStart = needsStart or leg.from.kind == "start"
			needsGoal = needsGoal or (leg.to.kind == "goal" and leg.from.kind ~= "start")
		end
		reversed[#reversed + 1] = leg
		current = labels.parent[current]
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
	return {
		arrive = labels.time[finishAt],
		legs = legs,
		needsStart = needsStart,
		needsGoal = needsGoal,
		pendingWalks = pendingWalks,
	}
end
