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
ns.Path = nil
ns.Docks, ns.Routes, ns.TaxiNodes, ns.TaxiPaths, ns.Portals, ns.Landmasses = {}, {}, {}, {}, {}, {}
local api = ShortestPathForever.API
local lineTemplate, goalTemplate = "ShortestPathForeverRoutePinTemplate", "ShortestPathForeverGoalPinTemplate"
local stops = {
 {map=1414,x=0.51,y=0.5,title="First"},
 {map=1414,x=0.52,y=0.49,title="Second"},
 {map=1414,x=0.53,y=0.5,title="Third"},
 {map=1414,x=0.54,y=0.51,title="Last"},
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
  assert(pin.Numeral.atlas == "services-number-"..(index+i-1), "remaining pins retain original stop numbers")
  assert(pin.Texture.atlas == "adventureguide-ring")
  assert(pin.alpha == (i == 1 and 1 or 0.55), "only the stop being guided to is at full strength")
  assert(pin.stopTitle == string.format("Stop %d of %d: %s", index+i-1, count, stops[index+i-1].title))
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
-- Pooled numbered pins must revert to the ordinary waypoint for a single destination.
assert(api.Navigate("Test", 1414, 0.51, 0.5, "Only"))
assert(#active[goalTemplate] == 1 and active[goalTemplate][1].Number.text == "")
assert(active[goalTemplate][1].stopTitle == nil and arrowFrame.Progress.text == "")
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
assert(#active[goalTemplate] == 64 and #line.paths[#line.paths].points == 64)
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
