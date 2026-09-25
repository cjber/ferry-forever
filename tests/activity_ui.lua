-- Exercise real module lifecycles against the same offline UI fixture as runtime_bench.
local dir = arg[0]:match("^(.*)/") or "tests"
local source = ""
for _, part in ipairs({ "ui_client.lua", "ui_map.lua" }) do
	local file = assert(io.open(dir .. "/" .. part))
	source = source .. file:read("*a")
	file:close()
end
assert(loadstring(source .. [[
local callbacks = 0
local function advance(seconds)
 for _ = 1, math.floor(seconds * 60) do
  T = T + 1/60
  for _, t in ipairs(tickers) do
   if not t.cancelled and T >= t.next then t.next = T + t.every callbacks = callbacks + 1 t.fn() end
  end
  for i = #pending, 1, -1 do
   if T >= pending[i].at then local p = table.remove(pending, i) callbacks = callbacks + 1 p.fn() end
  end
  for _, f in ipairs(frames) do
   if f:IsShown() and f.scripts.OnUpdate then callbacks = callbacks + 1 f.scripts.OnUpdate(f, 1/60) end
  end
 end
end
local function activeTickers()
 local count = 0
 for _, t in ipairs(tickers) do if not t.cancelled then count = count + 1 end end
 return count
end
local tracker = ShortestPathForeverObjectiveTracker
local dirty, originalDirty = 0, tracker.MarkDirty
tracker.MarkDirty = function(self) dirty = dirty + 1 originalDirty(self) end
ns.db.debug = false
posX, posY, posMap = 0, 0, 1
fireEvent("PLAYER_ENTERING_WORLD")
advance(40)
assert(activeTickers() == 0 and #tracker.blocks == 0)
callbacks = 0
advance(60)
assert(callbacks == 0, "unrelated play must have no addon timer/frame callbacks")
local blocks = tracker.blocks
for _ = 1, 100 do
 fireEvent("TRADE_SKILL_SHOW") fireEvent("BAG_UPDATE", 0) fireEvent("UNIT_AURA", "party1")
 fireEvent("UNIT_EXITED_VEHICLE", "party1")
 tracker:LayoutContents()
 ns.RefreshTracker()
end
assert(activeTickers() == 0 and tracker.blocks == blocks, "empty tracker signature must reuse its model")

moving = true fireEvent("PLAYER_STARTED_MOVING")
advance(2)
assert(activeTickers() == 1)
moving = false fireEvent("PLAYER_STOPPED_MOVING")
advance(5)
assert(activeTickers() == 0)

local dock = ns.Docks[1]
posX, posY, posZ, posMap = dock.x, dock.y, dock.z or 0, dock.map
fireEvent("ZONE_CHANGED")
ns.Sighted(241, { epoch = ns.NowMs(), seen = GetServerTime(), source = "you" })
advance(2)
assert(activeTickers() == 1 and tracker.blocks[1].key == "dock1")
local block = tracker:GetExistingBlock("dock1")
local line = block:GetExistingLine(241)
local text, marks = line.Text:GetText(), dirty
advance(3)
assert(line == block:GetExistingLine(241) and line.Text:GetText() ~= text)
assert(dirty == marks, "countdown ticks must update text without layout")
line.Text.GetHeight = function() return 24 end
advance(2)
assert(dirty > marks, "changed wrapping must request a layout")

combat = true fireEvent("PLAYER_REGEN_DISABLED")
marks = dirty
blocks = tracker.blocks
posX, posY = 0, 0
fireEvent("ZONE_CHANGED")
advance(5)
assert(dirty == marks and tracker.blocks == blocks, "defer tracker work during combat")
combat = false fireEvent("PLAYER_REGEN_ENABLED")
advance(5)
assert(#tracker.blocks == 0 and activeTickers() == 0, "combat recovery must clear stale dock content")

-- No player movement events: a reload aboard a sailing boat still gets enough samples to recognize it.
local route = ns.Routes[241]
local first = route.frames[1][2]
local function sail(phase)
 for i = 1, #route.frames - 1 do
  local a, b = route.frames[i], route.frames[i + 1]
  if phase >= a[2] and phase <= b[1] and a[3] == b[3] then
   local t = (phase - a[2]) / (b[1] - a[2])
   posMap, posX, posY = a[3], a[4] + t * (b[4] - a[4]), a[5] + t * (b[5] - a[5])
   return
  end
 end
end
sail(first + 5000)
fireEvent("PLAYER_ENTERING_WORLD")
for i = 1, 50 do sail(first + 5000 + i * 1000) advance(1) end
assert(ns.CurrentRide() == 241 and activeTickers() == 1, "passive boat wake-up")
posX, posY, posMap = 0, 0, 1
advance(40)
assert(not ns.CurrentRide() and activeTickers() == 0, "alighting must retire observation")

-- A lift changes only height; its lower speed threshold and lack of movement events still matter.
route = ns.Routes[118981]
local function lift(phase)
 for i = 1, 12 do
  local a, b = route.frames[i], route.frames[i + 1]
  if phase >= a[1] and phase <= b[1] then
   local t = phase <= a[2] and 0 or (phase - a[2]) / (b[1] - a[2])
   posMap, posX, posY, posZ = a[3], a[4], a[5], a[7] + t * (b[7] - a[7])
   return
  end
 end
end
lift(0) fireEvent("ZONE_CHANGED")
for i = 1, 60 do lift(i * 1000 % route.period) advance(1) end
assert(ns.CurrentRide() == 118981, "height-only passive lift must still sync")
posX, posY, posZ, posMap = 0, 0, 0, 1
advance(40)

-- MapCanvas may release every pin before asking providers to refresh the same map.
visible, WorldMapFrame.shown = true, true
ns.RefreshMap()
local template = "ShortestPathForeverDockPinTemplate"
assert(#active[template] > 0)
map:RemoveAllPinsByTemplate(template)
ns.RefreshMap()
assert(#active[template] > 0 and active[template][1].cluster, "reacquire after external pin release")
local acquisitions, acquire = 0, map.AcquirePin
map.AcquirePin = function(self, ...) acquisitions = acquisitions + 1 return acquire(self, ...) end
ns.Sighted(241, { epoch = ns.NowMs(), seen = GetServerTime(), source = "you" })
assert(acquisitions == 0, "sightings must not rebuild unrelated map layers")
map.AcquirePin = acquire
visible, WorldMapFrame.shown = false, false

-- A queued walking search must sleep in combat and resume from the single regen event.
ns.Path = actualPath
local nextFrame
actualPath.after = function(fn) nextFrame = fn end
combat = true
local job = actualPath.Find(999999, {x=0,y=0}, {x=100,y=100}, noop)
local pump = assert(nextFrame) nextFrame = nil pump()
assert(job.frames == 0 and not nextFrame, "combat search must not reschedule frames")
combat = false fireEvent("PLAYER_REGEN_ENABLED")
local count = 0
while nextFrame do local fn = nextFrame nextFrame = nil fn() count = count + 1 assert(count < 100) end
assert(job.done, "search resumes after combat")

local messages, updates = {}, 0
ns.Print = function(message) messages[#messages + 1] = message end
_G.C_AddOnProfiler = nil
_G.UpdateAddOnMemoryUsage, _G.GetAddOnMemoryUsage = nil, nil
SlashCmdList.SHORTESTPATHFOREVER("perf")
assert(#messages == 2 and messages[1]:find("unavailable"))
messages = {}
Enum.AddOnProfilerMetric = {RecentAverageTime=1,SessionAverageTime=0,LastTime=3,PeakTime=4,CountTimeOver5Ms=6}
_G.C_AddOnProfiler = {
 IsEnabled=function() return true end,
 GetAddOnMetric=function(name, metric) assert(name == "ShortestPathForever") return metric == 6 and 2 or 0.123 end,
}
local collected, gc = false, collectgarbage
_G.collectgarbage = function(action)
 assert(action == "collect")
 collected = true
 return gc(action)
end
_G.UpdateAddOnMemoryUsage = function() assert(collected, "collect before addon accounting") updates = updates + 1 end
_G.GetAddOnMemoryUsage = function(name) return name == "ShortestPathForever" and 100 or 20 end
SlashCmdList.SHORTESTPATHFOREVER("perf")
assert(updates == 1 and #messages == 6 and messages[1]:find("0.123 ms", 1, true))
_G.collectgarbage = gc
assert(messages[6]:find("collected", 1, true))
assert(messages[6]:find("160.0 KB", 1, true), "include all loaded nav addons in memory")
assert(#errors == 0, table.concat(errors, "\n"))
print("activity_ui: idle sleep, tracker, combat, passive rides, pin pools and profiler ok")
]]))()
