-- Real map pins, route strokes and arrow text against the local offline client fixture.
local harness = os.getenv("SPF_HARNESS") or os.getenv("HOME") .. "/drive/proj/wow-handoff/scratch/harness2.lua"
local file = assert(io.open(harness))
local source = file:read("*a")
file:close()
source = source:sub(1, assert(source:find("visible = true\nlocal function advance", 1, true)) - 1)
assert(loadstring(source .. [[
visible, WorldMapFrame.shown = true, true
posX, posY, posMap, facing = 0, 0, 1, 0
mapID = 1414
-- Zoomed in, so the stops' rings stand apart; the overlap checks below zoom out.
zoom = 1
ns.Path = nil
-- A character with a hearthstone and no recorded bind point: no teleport edges, as after a fresh install.
GetBindLocation = GetBindLocation or function() return "Auberdine" end
C_SpellBook = C_SpellBook or { IsSpellKnown = function() return false end }
C_Item = C_Item or {
 GetItemCount = function(id) return id == 6948 and 1 or 0 end,
 GetItemCooldown = function() return 0, 0, 1 end,
}
ns.Docks, ns.Routes, ns.TaxiNodes, ns.TaxiPaths, ns.Portals, ns.Landmasses = {}, {}, {}, {}, {}, {}
local api = ShortestPathForever.API
local lineTemplate, goalTemplate = "ShortestPathForeverRoutePinTemplate", "ShortestPathForeverGoalPinTemplate"
local stops = {
 {map=1414,x=0.51,y=0.5,title="First"},
 {map=1414,x=0.53,y=0.49,title="Second"},
 {map=1414,x=0.55,y=0.5,title="Third"},
 {map=1414,x=0.57,y=0.51,title="Last"},
}
local function tick()
 T = T + 0.1
 local driver = ShortestPathForeverJourneyDriver
 driver.scripts.OnUpdate(driver, 0.1)
end
local function check(index, count)
 assert(api.CurrentStop("Test") == index)
 local pins = active[goalTemplate]
 assert(#pins == count-index+1)
 for i, pin in ipairs(pins) do
  -- Stops up to 9 wear Blizzard's numeral atlas on the Adventure Guide ring; later stops use the font.
  assert(pin.Numeral.atlas == "services-number-" .. (index+i-1), "remaining pins retain original stop numbers")
  assert(pin.Number.text == "")
  assert(pin.Texture.atlas == "adventureguide-ring")
  assert(pin.alpha == (i == 1 and 1 or 0.55), "only the stop being guided to is at full strength")
  assert(pin.stopTitles[1] == string.format("Stop %d of %d: %s", index+i-1, count, stops[index+i-1].title))
 end
 local line = active[lineTemplate][1]
 assert(line.used > 0 and line.used <= 4096)
 local preview = line.paths[#line.paths]
 assert(index == count or preview.preview and #preview.points == count-index+1)
 -- The leg being walked draws at full strength and every stroke of the later hops recedes.
 local current, later = 0, 0
 for i = 1, line.used do
  local alpha = line.lines[i].alpha
  assert(alpha == 1 or alpha == 0.4, "strokes are either current or later")
  if alpha == 1 then current = current + 1 else later = later + 1 end
 end
 assert(current > 0)
 assert(index == count and later == 0 or later > 0 and line.lines[line.used].alpha == 0.4)
 assert(line.lines[1].alpha == 1, "the current leg is drawn first, at full strength")
 assert(arrowFrame.Progress.text == string.format("Stop %d of %d: %s", index, count, stops[index].title))
 assert(ns.JourneyInfo() == arrowFrame.Progress.text)
 return line
end
assert(api.NavigateRoute("Test", stops))
local first = check(1, 4)
-- Map closure/reopening and canvas resizes keep the full itinerary, without reallocating pins.
local created = lineCreations
first:OnCanvasScaleChanged()
first:OnCanvasSizeChanged()
assert(lineCreations == created)
visible, WorldMapFrame.shown = false, false
visible, WorldMapFrame.shown = true, true
for _, provider in ipairs(providers) do provider:RefreshAllData() end
check(1, 4)
for i, stop in ipairs(stops) do
 local point = ns.WorldPoint(stop.map, stop.x, stop.y)
 posX, posY = point.x, point.y
 tick()
 if i < #stops then check(i+1, 4) end
end
assert(api.CurrentStop("Test") == nil and not ns.HasJourney())
assert(#active[goalTemplate] == 0 and #active[lineTemplate] == 0)
assert(not ShortestPathForeverMinimapRoute.scripts.OnUpdate)
assert(not ShortestPathForeverJourneyDriver:IsShown() and not arrowFrame:IsShown())
-- Stops whose rings would overlap at this zoom share one ring, labelled with their numbers and naming each stop in
-- order; the stop being guided to always keeps its own ring at full strength.
local routeProvider
for _, candidate in ipairs(providers) do
 if candidate.RefreshStops then routeProvider = candidate end
end
local close = {
 {map=1414,x=0.5,y=0.5,title="A"},
 {map=1414,x=0.512,y=0.5,title="B"},
 {map=1414,x=0.524,y=0.5,title="C"},
 {map=1414,x=0.536,y=0.5,title="D"},
 {map=1414,x=0.3,y=0.3,title="E"},
 {map=1414,x=0.7,y=0.7,title="F"},
 {map=1414,x=0.31,y=0.3,title="G"},
}
local function rings(expected)
 local pins = active[goalTemplate]
 assert(#pins == #expected, "one ring per group: " .. #pins)
 for i, want in ipairs(expected) do
  local pin = pins[i]
  assert(pin.alpha == (i == 1 and 1 or 0.55), "only the current stop's ring is at full strength")
  assert(#pin.stopTitles == #want.stops)
  for j, n in ipairs(want.stops) do
   local expected = string.format("Stop %d of 7: %s", n, close[n].title)
   assert(pin.stopTitles[j] == expected, "the tooltip names each stop in order")
  end
  if #want.stops == 1 then
   assert(pin.Numeral.atlas == "services-number-" .. want.stops[1] and pin.Number.text == "")
  else
   assert(pin.Number.text == want.label, tostring(pin.Number.text))
   local x = 0
   for _, n in ipairs(want.stops) do x = x + close[n].x end
   assert(math.abs(pin.x - x / #want.stops) < 1e-9, "a shared ring sits at its stops' middle")
  end
 end
 return pins
end
posX, posY = 0, 0
assert(api.NavigateRoute("Test", close))
zoom = 0
routeProvider:OnCanvasScaleChanged()
local zoomedOut = rings({ {stops={1}}, {stops={2,3,4}, label="2-4"}, {stops={5,7}, label="5, 7"}, {stops={6}} })
zoomedOut[2]:OnMouseEnter()
assert(tip[1] == "# Stop 2 of 7: B" and tip[2] == "  Stop 3 of 7: C" and tip[3] == "  Stop 4 of 7: D")
zoomedOut[2]:OnMouseLeave()
-- A canvas refresh that keeps the grouping keeps the rings, hover and all.
local acquisitions, acquire = 0, map.AcquirePin
map.AcquirePin = function(self, ...) acquisitions = acquisitions + 1 return acquire(self, ...) end
routeProvider:OnCanvasScaleChanged()
assert(acquisitions == 0 and active[goalTemplate][2] == zoomedOut[2])
-- Zooming in splits the rings that no longer overlap, from the pool.
zoom = 1
routeProvider:OnCanvasScaleChanged()
map.AcquirePin = acquire
assert(acquisitions == 6 and #pools[goalTemplate] == 0, "the split reuses pooled rings, plus two more")
rings({ {stops={1}}, {stops={2}}, {stops={3}}, {stops={4}}, {stops={5,7}, label="5, 7"}, {stops={6}} })
-- Arriving at a stop draws it on its own, never inside the later ring it shared.
zoom = 0
routeProvider:OnCanvasScaleChanged()
local arrive = ns.WorldPoint(close[1].map, close[1].x, close[1].y)
posX, posY = arrive.x, arrive.y
tick()
assert(api.CurrentStop("Test") == 2)
local pins = active[goalTemplate]
assert(#pins == 4 and pins[1].Numeral.atlas == "services-number-2" and pins[1].alpha == 1)
assert(pins[2].Number.text == "3-4" and pins[2].alpha == 0.55 and #pins[2].stopTitles == 2)
api.Cancel("Test")
zoom = 1
posX, posY = 0, 0

-- Pooled numbered pins must revert to the ordinary waypoint for a single destination.
assert(api.Navigate("Test", 1414, 0.51, 0.5, "Only"))
assert(#active[goalTemplate] == 1 and active[goalTemplate][1].Number.text == "")
assert(active[goalTemplate][1].Texture.atlas == "Waypoint-MapPin-Tracked")
assert(active[goalTemplate][1].stopTitles == nil and arrowFrame.Progress.text == "")
assert(api.Cancel("Test"))
posX, posY = 0, 0
assert(api.NavigateRoute("Test", stops))
assert(not api.Cancel("Other") and #active[goalTemplate] == 4)
active[goalTemplate][3]:OnMouseClickAction("RightButton")
assert(not api.CurrentStop("Test") and #active[goalTemplate] == 0)

-- Previews can cross continents on an overview map when both endpoints project there.
assert(api.NavigateRoute("Test", {stops[1], {map=1415,x=0.52,y=0.5,title="Across the sea"}}))
local overview = active[lineTemplate][1]
local project = C_Map.GetMapPosFromWorldPos
C_Map.GetMapPosFromWorldPos = function(_, point, targetMap)
 return targetMap, CreateVector2D(0.5-point.y/25000, 0.5-point.x/25000)
end
overview.paths = {overview.paths[#overview.paths]}
overview:Draw()
assert(overview.used > 0, "cross-continent preview draws a dashed connection")
C_Map.GetMapPosFromWorldPos = project
api.Cancel("Test")

zoom = 0
local many = {}
for i=1,64 do
 many[i] = {map=1414,x=0.2+i/1000,y=i%2 == 0 and 0.3 or 0.7,title=tostring(i)}
end
local plan, calls = ns.Planner.Plan, 0
ns.Planner.Plan = function(options) calls=calls+1 return plan(options) end
local started = os.clock()
assert(api.NavigateRoute("Test", many))
local startMS = (os.clock()-started)*1000
assert(calls == 1, "only the current stop is planned")
local line = active[lineTemplate][1]
-- The rest share two rings, one per row, too many apart to list on the ring.
assert(#active[goalTemplate] == 3 and #line.paths[#line.paths].points == 64)
assert(active[goalTemplate][2].Number.text == "2+" and #active[goalTemplate][3].stopTitles == 31)
local drawCPU, drawWorst = 0, 0
for _=1,30 do
 started = os.clock()
 line:Draw()
 local ms = (os.clock()-started)*1000
 drawCPU, drawWorst = drawCPU+ms, math.max(drawWorst, ms)
end
assert(line.used <= 4096)
api.Cancel("Test")
assert(#errors == 0, table.concat(errors, "\n"))
print(string.format("api_ui: numbered pins, preview lines, progress, pooling, completion/cancel: ok; "..
 "64 stops start %.3f ms / redraw %.3f mean %.3f worst ms", startMS, drawCPU/30, drawWorst))
]]))()
