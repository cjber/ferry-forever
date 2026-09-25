-- Run from the source tree being measured; the harness only supplies offline UI stubs.
-- luajit -joff /path/to/tests/runtime_bench.lua <scenario> [gc]
local dir = arg[0]:match("^(.*)/") or "tests"
local source = ""
for _, part in ipairs({ "ui_client.lua", "ui_map.lua" }) do
	local file = assert(io.open(dir .. "/" .. part))
	source = source .. file:read("*a")
	file:close()
end
local driver = assert(loadstring(source .. [[
ns.Path = actualPath
ns.db.debug = false
WorldMapFrame.shown = false
-- A character with a hearthstone and no recorded bind point: no teleport edges, as after a fresh install.
GetBindLocation = GetBindLocation or function() return "Auberdine" end
C_SpellBook = C_SpellBook or { IsSpellKnown = function() return false end }
C_Item = C_Item or {
 GetItemCount = function(id) return id == 6948 and 1 or 0 end,
 GetItemCooldown = function() return 0, 0, 1 end,
}
local nextFrame, displayed
local plannerStats = { calls = 0, cpu = 0, worst = 0, kb = 0 }
local plan = ns.Planner.Plan
ns.Planner.Plan = function(options)
 local before, started = collectgarbage("count"), os.clock()
 local result = plan(options)
 local elapsed = (os.clock() - started) * 1000
 plannerStats.calls = plannerStats.calls + 1
 plannerStats.cpu, plannerStats.worst = plannerStats.cpu + elapsed, math.max(plannerStats.worst, elapsed)
 plannerStats.kb = plannerStats.kb + collectgarbage("count") - before
 return result
end
if arg[1] == "cold" then _G.C_AddOns = {
 DoesAddOnExist = function(name) return name:match("Nav[01]$") ~= nil end,
 LoadAddOn = function(name)
  local map = assert(name:match("Nav(%d+)$"))
  assert(loadfile("tools/load_nav.lua"))(map)
 end,
} end
local miniEnabled = true
actualPath.after = function(fn) nextFrame = fn end
local draw = ns.SetJourneyRoute
ns.SetJourneyRoute = function(g, r) displayed = r draw(g, r) end
return {
 ns = ns,
 stats = plannerStats,
 move = function(point) posX, posY, posMap = point.x, point.y, point.map end,
 wake = function() fireEvent("PLAYER_ENTERING_WORLD") end,
 moving = function() moving = true fireEvent("PLAYER_STARTED_MOVING") end,
 begin = function(point)
  mapID = point.map == 0 and 1415 or 1414
  cursorX, cursorY = 0.5 - point.y / 25000, 0.5 - point.x / 25000
  shiftDown = true
  for _, fn in ipairs(clickHandlers) do fn(map, "LeftButton") end
  shiftDown = false
 end,
 frame = function()
  T = T + 1/60
  local fn = nextFrame nextFrame = nil if fn then fn() end
  for _, f in ipairs(frames) do
   if f:IsShown() and f.scripts.OnUpdate
    and (miniEnabled or f ~= ShortestPathForeverMinimapRoute) then f.scripts.OnUpdate(f, 1/60) end
  end
  for _, t in ipairs(tickers) do if not t.cancelled and T >= t.next then t.next = T + t.every t.fn() end end
 end,
 pending = function() return nextFrame end,
 shown = function() return displayed end,
 refresh = function() for _, provider in ipairs(providers) do provider:RefreshAllData() end end,
 open = function(value) visible = value WorldMapFrame.shown = value end,
 minimap = function(value) miniEnabled = value end,
 sail = function(id, phase)
  ns.CurrentRide = function() return id end
  ns.db.anchors[GetRealmName()][id] = { epoch = ns.NowMs() - phase, seen = GetServerTime(), source = "you" }
 end,
 check = function() assert(#errors == 0, table.concat(errors, "\n")) end,
}
]]))()
local scenario = arg[1] or "idle"
local ns = driver.ns
collectgarbage("collect")
local base = collectgarbage("count")
if
	scenario ~= "idle"
	and scenario ~= "observer"
	and scenario ~= "refresh"
	and scenario ~= "boat"
	and scenario ~= "cold"
then
	assert(loadfile("tools/load_nav.lua"))(1)
	if scenario == "cross" or scenario == "aboard" then
		assert(loadfile("tools/load_nav.lua"))(0)
	end
end
collectgarbage("collect")
local packed = math.max(0, collectgarbage("count") - base)
local cpu, worst, frames, allocated = 0, 0, 0, 0
local function measure(fn)
	local memory, started = collectgarbage("count"), os.clock()
	fn()
	local elapsed = (os.clock() - started) * 1000
	cpu, worst, frames = cpu + elapsed, math.max(worst, elapsed), frames + 1
	allocated = allocated + collectgarbage("count") - memory
end
local function drain()
	local count = 0
	while driver.pending() do
		driver.frame()
		count = count + 1
		assert(count < 20000)
	end
end
local from, to = ns.TaxiNodes[26], ns.TaxiNodes[scenario == "cross" and 67 or 39]
driver.move(from)
driver.wake()
if scenario == "aboard" then
	driver.move(ns.Docks[1])
	driver.begin(ns.Docks[2])
	drain()
	driver.sail(241, 155000)
	for key in pairs(driver.stats) do
		driver.stats[key] = 0
	end
end
if scenario == "tanaris" or scenario == "cross" or scenario == "cold" then
	if arg[2] ~= "gc" then
		collectgarbage("stop")
	end
	local started = os.clock()
	driver.begin(to)
	local click = (os.clock() - started) * 1000
	while driver.pending() do
		measure(driver.frame)
		assert(frames < 20000)
	end
	print(string.format("click %.3f ms", click))
elseif scenario == "closed" or scenario == "open" or scenario == "minimap" or scenario == "stationary" then
	if scenario ~= "stationary" then
		driver.move({ map = 1, x = 6341.38, y = 557.68 })
		to = { map = 1, x = 5068.4, y = -337.22 }
	end
	driver.begin(to)
	drain()
	driver.minimap(scenario ~= "closed")
	for key in pairs(driver.stats) do
		driver.stats[key] = 0
	end
	if scenario == "open" then
		driver.open(true)
		driver.refresh()
	end
	local walk
	for _, leg in ipairs(assert(driver.shown()).legs) do
		if leg.mode == "walk" and leg.walkPoints and #leg.walkPoints > 2 then
			walk = leg.walkPoints
			break
		end
	end
	assert(walk)
	local segment, offset = 2, 0
	local a, b = walk[1], walk[2]
	local length = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
	local point = { map = a.map, x = a.x, y = a.y }
	if scenario ~= "stationary" then
		driver.moving()
	end
	if arg[2] ~= "gc" then
		collectgarbage("stop")
	end
	for _ = 1, 1800 do
		if scenario ~= "stationary" then
			offset = offset + 7 / 60
			while offset > length and segment < #walk do
				offset, segment = offset - length, segment + 1
				a, b = walk[segment - 1], walk[segment]
				length = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
			end
			assert(offset < length, "walking benchmark reached the destination")
			point.x, point.y = a.x + (b.x - a.x) * offset / length, a.y + (b.y - a.y) * offset / length
			driver.move(point)
		end
		measure(driver.frame)
	end
elseif scenario == "refresh" then
	driver.open(true)
	driver.refresh()
	collectgarbage("stop")
	for _ = 1, 100 do
		measure(driver.refresh)
	end
else
	if arg[2] ~= "gc" then
		collectgarbage("stop")
	end
	local point = { map = 1, x = from.x, y = from.y }
	local route = ns.Routes[241]
	if scenario == "observer" then
		driver.moving()
	end
	for i = 1, 1800 do
		if scenario == "observer" then
			point.x = point.x + 7 / 60
			driver.move(point)
		elseif scenario == "boat" or scenario == "aboard" then
			local phase = (i / 60 * 1000 + (scenario == "aboard" and 155000 or route.frames[1][2])) % route.period
			for j = 1, #route.frames - 1 do
				local a, b = route.frames[j], route.frames[j + 1]
				if phase >= a[2] and phase <= b[1] and a[3] == b[3] then
					local t = (phase - a[2]) / (b[1] - a[2])
					point.map, point.x, point.y = a[3], a[4] + t * (b[4] - a[4]), a[5] + t * (b[5] - a[5])
					driver.move(point)
					break
				end
			end
		end
		measure(driver.frame)
	end
end
if ns.Path.decodes then
	print("decoded grids", ns.Path.decodes)
end
if scenario == "aboard" then
	local leg = assert(driver.shown()).legs[1]
	assert(leg.route == 241 and leg.aboard, "aboard benchmark must retain its boat journey")
end
if scenario == "stationary" or scenario == "aboard" then
	local stats = driver.stats
	print(
		string.format(
			"settled Planner.Plan: %d calls, %.3f mean / %.3f worst ms, %.1f KB/call",
			stats.calls,
			stats.cpu / stats.calls,
			stats.worst,
			stats.kb / stats.calls
		)
	)
end
driver.check()
collectgarbage("restart")
collectgarbage("collect")
local resident = math.max(0, collectgarbage("count") - base)
print(
	string.format(
		"%s: %d frames, %.4f mean / %.4f worst ms, %.3f KB/frame, %.1f resident KB (%.1f packed; %.1f harness/addon base)",
		scenario,
		frames,
		cpu / frames,
		worst,
		allocated / frames,
		resident,
		packed,
		base
	)
)
