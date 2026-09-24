-- Reuse the client UI fixture without its integration scenarios.
local harness = os.getenv("SPF_HARNESS") or os.getenv("HOME") .. "/drive/proj/wow-handoff/scratch/harness2.lua"
local file = assert(io.open(harness))
local source = file:read("*a")
file:close()
source = source:sub(1, assert(source:find("visible = true\nlocal function advance", 1, true)) - 1)
assert(loadstring(source .. [[
local tracker = ShortestPathForeverObjectiveTracker
local dirty, headers, geometry = 0, 0, 0
local markDirty, legPoints = tracker.MarkDirty, ns.Planner.LegPoints
tracker.MarkDirty = function(self) dirty = dirty + 1 markDirty(self) end
tracker.SetHeader = function(self, text) headers = headers + 1 self.Header.text = text end
ns.Planner.LegPoints = function(...) geometry = geometry + 1 return legPoints(...) end
ns.db.tracker = false
local route, index, settling
ns.HasJourney = function() return route ~= nil end
ns.CurrentRide = function() return onTaxi and 123 end
ns.JourneyInfo = function()
 if not route then return end
 local title = "Journey to Silithus"
 local rows = {}
 for i = index, #route.legs do rows[#rows + 1] = {key=i, text="Step " .. i, current=i==index} end
 return title, rows, route, index, settling
end
local function point(x, y, map, z) return {x=x, y=y or 0, map=map or 1, z=z} end
-- The header adds up each step's arrive - depart (ns.JourneyTime); a lone step takes the whole 44:47.
local function leg(mode, points, seconds)
 return {mode=mode, from=points[1], to=points[#points], walkPoints=points, measured=true,
  depart=0, arrive=(seconds or 2687) * 1000}
end
local function refresh(changed)
 if changed then ns.journeyVersion = (ns.journeyVersion or 0) + 1 end
 ns.RefreshTracker()
 return tracker.Header.text
end
local function tick()
 T = T + 1
 return refresh()
end
local function start(legs)
 index, settling = 1, false
 route = {legs=legs}
 return refresh(true)
end

posX, posY, posMap = 0, 0, 1
local walk = leg("walk", {point(0), point(0, 300), point(400, 300)}, 47)
-- Running cost includes terrain weights and must never substitute for geometric yards.
walk.yards, walk.walkCost = 99999, 99999
local flight = leg("flight", {point(400, 300), point(8900, 300)}, 2640)
local header = start({walk, flight})
assert(header == "Journey  44:47 · 9.2k yd", "missing journey totals: " .. tostring(header))
assert(tracker:GetExistingBlock("journey").HeaderText:GetText() == "Journey to Silithus")
local block, line = tracker:GetExistingBlock("journey"), tracker:GetExistingBlock("journey"):GetExistingLine(1)
local marks, texts, points, blocks = dirty, headers, geometry, tracker.blocks
for _ = 1, 100 do refresh() end
assert(dirty == marks and headers == texts and geometry == points and tracker.blocks == blocks,
 "unchanged signature reuses the model")
-- The header adds up the steps rather than counting down, so a tick standing still changes nothing.
assert(tick() == header and headers == texts and geometry == points and dirty == marks,
 "a tick standing still holds the header, geometry and layout")
assert(block == tracker:GetExistingBlock("journey") and line == block:GetExistingLine(1))
refresh(true)
assert(headers == texts and dirty == marks, "version changes with identical text must not set the header")
posY = 150
assert(tick() == "Journey  44:47 · 9.1k yd", "mid-walk progress updates between replans")
posX, posY = 200, 300
assert(tick() == "Journey  44:47 · 8.7k yd", "passed bends are removed from the total")
assert(dirty == marks)
index, onTaxi = 2, true
assert(refresh(true) == "Journey  44:00 · 8.5k yd")
assert(dirty == marks + 1 and not block:GetExistingLine(1), "leg changes still relayout rows")
posX = 4600
assert(tick() == "Journey  44:00 · 4.3k yd", "flight progresses along its drawn path")

onTaxi, posX, posY = false, 0, 0
assert(start({leg("walk", {point(0), point(850)}, 60)}) == "Journey  1:00 · 850 yd")
assert(start({leg("walk", {point(0), point(999.6)}, 60)}) == "Journey  1:00 · 1.0k yd")
assert(start({leg("walk", {point(0), point(0)}, 0)}) == "Journey  0:00 · 0 yd")
posX = nil
assert(tick() == "Journey  0:00 · 0 yd", "missing positions are safe")
posX = 0

local boat = leg("boat", {point(0), point(0, 600)})
boat.route, boat.depart, boat.arrive = 123, 0, 3000
boat.boarding, boat.alighting = {depart=0}, {arrive=3000}
ns.Routes[123] = {period=6000, frames={{0,0,1,0,0},{1000,1000,1,400,0},{2000,2000,1,400,600},{3000,3000,1,0,600}}}
assert(start({boat}) == "Journey  0:03 · 1.4k yd", "transport must use bends, not dock separation")
onTaxi, posX, posY = true, 400, 300
assert(tick() == "Journey  0:03 · 700 yd", "riding drops already sailed distance")
onTaxi, posX, posY = false, 0, 0

flight = leg("flight", {point(0), point(400, 600)})
flight.hops = {{points={1,0,0, 1,400,0, 1,400,600}}}
assert(start({flight}) == "Journey  44:47 · 1.0k yd", "flight hops use their drawn path")
local cross = leg("walk", {point(0), point(100), point(100000, 0, 0), point(100200, 0, 0)})
assert(start({cross}) == "Journey  44:47 · 300 yd", "continent coordinates cannot be subtracted")
posX, posMap = 100050, 0
assert(tick() == "Journey  44:47 · 150 yd", "crossings retain only geometry on and after the player's continent")
posX, posMap = 0, 1
cross = leg("walk", {point(0), point(100), point(900), point(1000)})
cross.walkPoints[2].jump = true
assert(start({cross}) == "Journey  44:47 · 200 yd", "same-continent teleports are not yards")
assert(start({leg("portal", {point(0), point(10000)})}) == "Journey  44:47 · 0 yd")

walk = leg("walk", {point(0), point(300)})
assert(start({walk}) == "Journey  44:47 · 300 yd")
walk.walkPoints = {point(0), point(0, 400), point(300, 400), point(300)}
assert(refresh(true) == "Journey  44:47 · 1.1k yd", "measured geometry invalidates cached distance")
settling = true
refresh(true)
assert(block.HeaderText:GetText() == "Journey to Silithus" and tracker.Spinner.Anim:IsPlaying())
assert(tracker.Header.text == "Journey", "loading suppresses totals")
combat = true
marks, texts = dirty, headers
posY = 200
tick()
assert(dirty == marks and headers == texts, "combat defers the new header too")
combat = false
settling = false
assert(refresh() == "Journey  44:47 · 900 yd")
route = nil
refresh(true)
assert(tracker.Header.text == "Boats" and #tracker.blocks == 0 and not tracker.distance)
assert(#errors == 0, table.concat(errors, "\n"))
print("tracker_ui: remaining walking/transport yards, step times, geometry cache and no header layout churn ok")
]]))()
