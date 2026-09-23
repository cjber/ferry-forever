-- Exercise the real route layers, tracker, Guide and compass against the offline client fixture.
local harness = os.getenv("SPF_HARNESS") or os.getenv("HOME") .. "/drive/proj/wow-handoff/scratch/harness2.lua"
local file = assert(io.open(harness))
local source = file:read("*a")
file:close()
source = source:sub(1, assert(source:find("visible = true\nlocal function advance", 1, true)) - 1)
assert(loadstring(source .. [[
visible, WorldMapFrame.shown = true, true
posX, posY, posMap, facing = 0, 0, 1, 0
mapID, cursorX, cursorY, shiftDown = 1414, 0.5, 0.496, true
ns.db.tracker, ns.db.compass = false, true
local batches, jobs = {}, {}
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
 return {arrive=o.now+200000, legs={{mode="walk", from=o.from, to=o.to,
  yards=1400, depart=o.now, arrive=o.now+200000}}}
end
assert(clickHandlers[1](map, "LeftButton"))
local tracker, mini = ShortestPathForeverObjectiveTracker, ShortestPathForeverMinimapRoute
local routeTemplate, goalTemplate = "ShortestPathForeverRoutePinTemplate", "ShortestPathForeverGoalPinTemplate"
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
 assert(tracker.Spinner.atlas == "common-loadingspinnercircle" and tracker.Spinner.animation:IsPlaying())
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
assert(#active[routeTemplate] == 1 and mini.used > 0)
assert(waypoint and ns.GuideTargets())
assert(tracker.blocks[1].rows[1].key == 1 and tracker.Header.Text:GetText():find("yd",1,true))
assert(not tracker.Spinner.animation:IsPlaying() and tracker.Spinner.hidden)
local released = active[routeTemplate][1]
visible, WorldMapFrame.shown = false, false
ns.ClearJourney()
assert(released.paths == nil, "clearing while the map is closed releases pooled journey geometry")
assert(mini.Goal.hidden and not ns.GuideTargets())
assert(#errors == 0, table.concat(errors, "\n"))
print("search_ui: goal-only maps, grey loading row, animated stock spinner, idle Guide/compass and atomic commit: ok")
]]))()
