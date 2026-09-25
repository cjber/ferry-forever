-- Exercise the real route layers, tracker, Guide and compass against the offline client fixture.
local dir = arg[0]:match("^(.*)/") or "tests"
local source = ""
for _, part in ipairs({ "ui_client.lua", "ui_map.lua" }) do
	local file = assert(io.open(dir .. "/" .. part))
	source = source .. file:read("*a")
	file:close()
end
assert(loadstring(source .. [[
visible, WorldMapFrame.shown = true, true
posX, posY, posMap, facing = 0, 0, 1, 0
mapID, cursorX, cursorY, shiftDown = 1414, 0.5, 0.496, true
ns.db.tracker, ns.db.compass = false, true
-- Zoomed in on a zone-sized canvas, so the dots between here and a 100-yard goal clear the stop gaps (#51).
zoom, canvas.width, canvas.height = 1, 10000, 7000
local batches, jobs = {}, {}
local splitRoute = false
ns.Path = {
 HasData = function() return true end,
 FindMany = function(_, _, targets, callback)
  local job = {targets=targets, callback=callback}
  batches[#batches+1] = job
  return job
 end,
 Find = function(_, from, to, callback)
  local job = {from=from, to=to, callback=callback}
  jobs[#jobs+1] = job
  return job
 end,
 Cancel = function(job) job.cancelled=true end,
}
ns.Planner.Plan = function(o)
 if splitRoute then
  local mid = {map=1, x=50, y=40}
  return {now=o.now, arrive=o.now+100000, legs={
   {mode="walk", from=o.from, to=mid, yards=350, depart=o.now, arrive=o.now+50000},
   {mode="walk", from=mid, to=o.to, yards=350, depart=o.now+50000, arrive=o.now+100000},
  }}
 end
 return {now=o.now, arrive=o.now+200000, legs={{mode="walk", from=o.from, to=o.to,
  yards=1400, depart=o.now, arrive=o.now+200000}}}
end
assert(clickHandlers[1](map, "LeftButton"))
local tracker, mini = ShortestPathForeverObjectiveTracker, ShortestPathForeverMinimapRoute
local routeTemplate, goalTemplate = "ShortestPathForeverRoutePinTemplate", "ShortestPathForeverGoalPinTemplate"
local spinner = tracker.Spinner
assert(spinner.template == "SpinnerTemplate")
assert(spinner.Ring.atlas == "Spinner_Ring" and spinner.Sparks.atlas == "Spinner_Sparks")
assert(spinner.Sparks.blendMode == "ADD")
assert(spinner.Ring.allPoints == spinner and spinner.Sparks.allPoints == spinner)
assert(spinner.width == 16 and spinner.height == 16)
assert(spinner.anchor[1] == "LEFT" and spinner.anchor[2] == tracker.Header.Text)
assert(spinner.anchor[3] == "LEFT" and spinner.anchor[4] == tracker.Header.Text:GetStringWidth() + 6)
assert(spinner.anchor[5] == 0, "center vertically on the header text")
assert(spinner.Anim.looping == "REPEAT" and #spinner.Anim.animations == 2)
for i, rotation in ipairs(spinner.Anim.animations) do
 assert(rotation.kind == "Rotation" and rotation.Duration == 2 and rotation.Degrees == -360)
 assert(rotation.Order == 1 and rotation.Target == (i == 1 and spinner.Ring or spinner.Sparks))
end
local function pulse(owner, playing)
 local layer = assert(owner.strokeLayer)
 assert(layer.animation:IsPlaying() == playing)
 assert(not layer.scripts.OnUpdate, "pulsing must use native animation, never a frame script")
 if playing then
  assert(owner.used > 0)
  assert(layer.animation.owner == layer and layer.animation.looping == "BOUNCE")
  local alpha = layer.animation.animations[1]
  assert(#layer.animation.animations == 1 and alpha.kind == "Alpha")
  assert(alpha.FromAlpha == 0.8 and alpha.ToAlpha == 0.35 and alpha.Duration == 0.6)
  assert(alpha.Smoothing == "IN_OUT", "ease both ends of the 1.2-second pulse")
  for i=1,owner.used do
   assert(owner.lines[i].parent == layer and owner.underlines[i].parent == layer)
  end
 else
  assert(layer.alpha == 1, "settling restores full stroke opacity")
 end
end
local function drawn(loading)
 assert(#active[routeTemplate] == 1 and mini.used > 0)
 assert(select(5, ns.JourneyInfo()) == loading)
 assert(spinner.Anim:IsPlaying() == loading and spinner:IsShown() == loading)
 local pin = active[routeTemplate][1]
 pulse(pin, loading)
 pulse(mini, loading)
 assert(mini.Goal.parent == Minimap and active[goalTemplate][1] ~= pin)
 assert(waypoint and ns.GuideTargets())
 return pin
end
local function tick(seconds)
 T = T + seconds
 local driver = ShortestPathForeverJourneyDriver
 driver.scripts.OnUpdate(driver, seconds)
end
local function ready()
 for _, batch in ipairs(batches) do
  local costs = {}
  for i=1,#batch.targets do costs[i] = 1400 end
  batch.callback(costs, nil, batch)
 end
end
local function finish()
 for _, job in ipairs(jobs) do job.callback({job.from, job.to}, 1400, job) end
end
local function begin()
 ns.ClearJourney()
 batches, jobs, splitRoute = {}, {}, false
 assert(clickHandlers[1](map, "LeftButton"))
end
local function hiddenRoute()
 assert(#(active[routeTemplate] or {}) == 0 and mini.used == 0)
 assert(#active[goalTemplate] == 1 and not mini.Goal.hidden, "only the goal pins are drawn")
 assert(not waypoint and not ns.GuideTargets())
 assert(not ShortestPathForeverCompass or not ShortestPathForeverCompass:IsShown())
 local block = tracker:GetExistingBlock("journey")
 assert(block and block.HeaderText:GetText():find("Journey to ", 1, true) == 1)
 assert(#tracker.blocks[1].rows == 1 and tracker.blocks[1].rows[1].grey)
 assert(tracker.blocks[1].rows[1].text == "Finding the fastest way…")
 assert(tracker.Header.Text:GetText() == "Journey")
 assert(spinner.Anim:IsPlaying() and spinner:IsShown())
 pulse(mini, false)
end
hiddenRoute()
for _, batch in ipairs(batches) do
 local costs = {}
 for i=1,#batch.targets do costs[i] = 1400 end
 batch.callback(costs, nil, batch)
 hiddenRoute()
end
assert(#jobs == 1)
local job = jobs[1]
job.callback({job.from, job.to}, 1400, job)
drawn(false)
assert(tracker.blocks[1].rows[1].key == 1 and tracker.Header.Text:GetText():find("yd",1,true))
assert(not spinner.Anim:IsPlaying() and spinner.hidden)

-- A grace route pulses with the spinner, whether the settled candidate keeps or replaces it.
for _, replace in ipairs({false, true}) do
 begin()
 hiddenRoute()
 tick(3.1)
 local pin = drawn(true)
 local grace = select(3, ns.JourneyInfo())
 assert(tracker.Header.Text:GetText() == "Journey")
 -- Redrawing or polling unchanged geometry must not restart the native pulse.
 local mapPlays, miniPlays = pin.strokeLayer.animation.plays, mini.strokeLayer.animation.plays
 pin:Draw()
 mini.scripts.OnUpdate(mini, 0.1)
 assert(pin.strokeLayer.animation.plays == mapPlays and mini.strokeLayer.animation.plays == miniPlays)
 -- Both effects stop while hidden and resume only for the active visible search.
 spinner:Hide()
 assert(not spinner.Anim:IsPlaying())
 spinner:Show()
 assert(spinner.Anim:IsPlaying())
 pin:Hide()
 mini:Hide()
 pulse(pin, false)
 pulse(mini, false)
 pin:Show()
 mini:Show()
 drawn(true)
 splitRoute = replace
 ready()
 drawn(true)
 assert(#jobs > 0)
 finish()
 drawn(false)
 assert(not ns.JourneyStatus())
 assert((select(3, ns.JourneyInfo()) ~= grace) == replace)

 -- Background replans keep the existing route steady, including while replacement walks are pending.
 batches, jobs = {}, {}
 posY = 60
 tick(5)
 assert(ns.JourneyStatus() and #batches > 0)
 drawn(false)
 ready()
 assert(ns.JourneyStatus() and #jobs > 0)
 drawn(false)
 finish()
 assert(not ns.JourneyStatus())
 drawn(false)
 posY = 0
end

-- A repeated destination cancels an initial search but keeps its grace route without pulsing.
begin()
tick(3.1)
drawn(true)
assert(clickHandlers[1](map, "LeftButton"))
assert(ns.JourneyStatus())
drawn(false)

-- Clearing a pulsing journey releases hidden world-map pins and stops both animations.
begin()
tick(3.1)
local released = drawn(true)
visible, WorldMapFrame.shown = false, false
ns.ClearJourney()
assert(released.paths == nil, "clearing while the map is closed releases pooled journey geometry")
pulse(released, false)
pulse(mini, false)
assert(not spinner.Anim:IsPlaying() and not spinner:IsShown())
assert(mini.Goal.hidden and not ns.GuideTargets())
assert(not mini.scripts.OnUpdate)
assert(#errors == 0, table.concat(errors, "\n"))
print("search_ui: Group Finder spinner, both-map grace pulses, keep/swap settlement and silent replans: ok")
]]))()
