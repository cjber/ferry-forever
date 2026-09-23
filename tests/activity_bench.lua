-- Offline travel/event cost, including the harness dispatcher at 60 Hz; run with luajit -joff.
local harness = os.getenv("SPF_HARNESS") or os.getenv("HOME") .. "/drive/proj/wow-handoff/scratch/harness2.lua"
local file = assert(io.open(harness))
local source = file:read("*a")
file:close()
source = source:sub(1, assert(source:find("visible = true\nlocal function advance", 1, true)) - 1)
source = source:gsub(
	"local ns = {}",
	[[
local costs = { positions = 0, dirty = 0, layouts = 0, texts = 0, callbacks = 0, cpu = 0 }
local position = UnitPosition
_G.UnitPosition = function(...) costs.positions = costs.positions + 1 return position(...) end
local create = CreateFrame
_G.CreateFrame = function(...)
 local f = create(...)
 if select(4, ...) == "ObjectiveTrackerModuleTemplate" then
  local dirty = f.MarkDirty
  f.MarkDirty = function(self) costs.dirty = costs.dirty + 1 return dirty(self) end
 end
 return f
end
collectgarbage("collect")
local loadBase = collectgarbage("count")
local loadKB, loadStart = loadBase, os.clock()
collectgarbage("stop")
local ns = {}
]]
)
source = source:gsub(
	"local actualPath=ns.Path",
	[[
local loadMs = (os.clock() - loadStart) * 1000
loadKB = collectgarbage("count") - loadKB
local initKB, initStart = collectgarbage("count"), os.clock()
local actualPath=ns.Path
]]
)
local driver = assert(loadstring(source .. [[
local initMs = (os.clock() - initStart) * 1000
initKB = collectgarbage("count") - initKB
collectgarbage("restart")
collectgarbage("collect")
local loginRetained = collectgarbage("count") - loadBase
local module = ShortestPathForeverObjectiveTracker
local layout = module.LayoutContents
module.LayoutContents = function(self) costs.layouts = costs.layouts + 1 return layout(self) end
ns.db.debug = false
WorldMapFrame.shown = false
return {
 ns = ns, costs = costs, loginRetained = loginRetained,
 loadMs = loadMs, loadKB = loadKB, initMs = initMs, initKB = initKB,
 move = function(x, y, map) posX, posY, posMap = x, y, map end,
 event = fireEvent,
 moving = function(value) moving = value fireEvent(value and "PLAYER_STARTED_MOVING" or "PLAYER_STOPPED_MOVING") end,
 combat = function(value) combat = value fireEvent(value and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED") end,
 frame = function(churn)
  T = T + 1/60
  if churn then
   fireEvent("TRADE_SKILL_SHOW") fireEvent("BAG_UPDATE", 0) fireEvent("UNIT_AURA", "party1")
   local t = os.clock() module:LayoutContents() costs.cpu = costs.cpu + os.clock() - t
  end
  for _, f in ipairs(frames) do
   if f:IsShown() and f.scripts.OnUpdate then
    costs.callbacks = costs.callbacks + 1
    local t = os.clock()
    f.scripts.OnUpdate(f, 1/60)
    costs.cpu = costs.cpu + os.clock() - t
   end
  end
  for _, t in ipairs(tickers) do
   if not t.cancelled and T >= t.next then
    costs.callbacks = costs.callbacks + 1
    t.next = T + t.every
    local start = os.clock()
    t.fn()
    costs.cpu = costs.cpu + os.clock() - start
   end
  end
  for i = #pending, 1, -1 do
   if T >= pending[i].at then
    costs.callbacks = costs.callbacks + 1
    local p = table.remove(pending, i)
    local start = os.clock()
    p.fn()
    costs.cpu = costs.cpu + os.clock() - start
   end
  end
 end,
 check = function() assert(#errors == 0, table.concat(errors, "\n")) end,
}
]]))()
local ns, scenario = driver.ns, arg[1] or "idle"
print(string.format("login retained: %.1f KB", driver.loginRetained))
print(
	string.format(
		"login: load %.3f ms / %.1f KB; init %.3f ms / %.1f KB",
		driver.loadMs,
		driver.loadKB,
		driver.initMs,
		driver.initKB
	)
)
if scenario == "dock" or scenario == "ride" then
	local dock = ns.Docks[1]
	driver.move(dock.x, dock.y, dock.map)
	ns.db.anchors.Test[241] = { epoch = ns.NowMs(), seen = GetServerTime(), source = "you" }
else
	driver.move(0, 0, 1)
end
driver.event("PLAYER_ENTERING_WORLD")
for _ = 1, 2400 do
	driver.frame()
end
if scenario == "walking" then
	driver.moving(true)
end
if scenario == "combat" then
	driver.combat(true)
end
for key in pairs(driver.costs) do
	driver.costs[key] = 0
end
collectgarbage("collect")
local resident = collectgarbage("count")
collectgarbage("stop")
local before, started = collectgarbage("count"), os.clock()
for i = 1, 3600 do
	if scenario == "walking" then
		driver.move(i * 7 / 60, 0, 1)
	end
	if scenario == "ride" then
		local route = ns.Routes[241]
		local phase = (route.frames[1][2] + i / 60 * 1000) % route.period
		for j = 1, #route.frames - 1 do
			local a, b = route.frames[j], route.frames[j + 1]
			if phase >= a[2] and phase <= b[1] and a[3] == b[3] then
				local t = (phase - a[2]) / (b[1] - a[2])
				driver.move(a[4] + t * (b[4] - a[4]), a[5] + t * (b[5] - a[5]), a[3])
				break
			end
		end
	end
	driver.frame(scenario == "panel" and i % 3 == 0)
end
local ms, kb = (os.clock() - started) * 1000 / 60, (collectgarbage("count") - before) / 60
if scenario == "ride" then
	assert(ns.CurrentRide() == 241, "passive ride must be recognized")
end
driver.check()
collectgarbage("restart")
collectgarbage("collect")
print(
	string.format(
		"%s: %.4f ms/s dispatch, %.4f ms/s addon, %.3f KB/s, %.1f resident KB; "
			.. "callbacks %d, positions %d, dirty %d, layouts %d",
		scenario,
		ms,
		driver.costs.cpu * 1000 / 60,
		kb,
		resident,
		driver.costs.callbacks,
		driver.costs.positions,
		driver.costs.dirty,
		driver.costs.layouts
	)
)
