-- Run this script by absolute path from either source snapshot; all measurements use offline UI stubs.
local script = arg[0]:match("^(.*)/") or "tests"
local file = assert(io.open(script .. "/runtime_bench.lua"))
local source = file:read("*a")
file:close()
source = source:sub(1, assert(source:find("local scenario = arg[1]", 1, true)) - 1)
local driver = assert(loadstring(source .. "return driver"))()
local ns = driver.ns
local function collected()
	collectgarbage("collect")
	return collectgarbage("count")
end
local base = collected()
for _, map in ipairs({ 0, 1, 2991 }) do
	assert(loadfile("tools/load_nav.lua"))(map)
end
local packed = collected() - base
local cases = { tanaris = { 26, 39 }, cross = { 26, 67 }, thunder = { 25, 22 }, menethil = { 6, 7 } }
local case = cases[arg[1] or "cross"]
assert(case or arg[1] == "felwood")
_G.UnitFactionGroup = function()
	return arg[1] == "thunder" and "Horde" or "Alliance"
end
local topologyCache
local plan = ns.Planner.Plan
ns.Planner.Plan = function(o)
	topologyCache = o.cache
	return plan(o)
end
driver.move(case and ns.TaxiNodes[case[1]] or { map = 1, x = 6341.38, y = 557.68 })
driver.wake()
if arg[2] == "stop" then
	collectgarbage("stop")
end
if arg[2] == "open" then
	driver.open(true)
	driver.refresh()
end
driver.begin(case and ns.TaxiNodes[case[2]] or { map = 1, x = 5000, y = -2000 })
local frames = 0
while driver.pending() do
	driver.frame()
	frames = frames + 1
	assert(frames < 20000)
end
local before = collectgarbage("count")
local retained = collected()
print(
	string.format(
		"%s: %d frames; %.1f KB before GC, %.1f retained, %.1f garbage; %.1f packed, %.1f base, %.1f route/caches",
		arg[1] or "cross",
		frames,
		before,
		retained,
		before - retained,
		packed,
		base,
		retained - packed - base
	)
)

if arg[2] == "clear" then
	topologyCache = nil -- luacheck: ignore 311 (release the benchmark reference before measuring clear)
	ns.ClearJourney()
	print(string.format("  clear retained: %.1f KB excluding packed maps and base", collected() - packed - base))
	driver.check()
	return
end

local function upvalue(fn, wanted, seen)
	seen = seen or {}
	if seen[fn] then
		return
	end
	seen[fn] = true
	for i = 1, 100 do
		local name, value = debug.getupvalue(fn, i)
		if not name then
			break
		end
		if name == wanted then
			return value
		end
		if type(value) == "function" then
			local found = upvalue(value, wanted, seen)
			if found then
				return found
			end
		end
	end
end
local function wipe(t)
	for k in pairs(t or {}) do
		t[k] = nil
	end
end
local function release(label, fn)
	local prior = collected()
	fn()
	print(string.format("  %s: %.1f KB released", label, prior - collected()))
end
-- Destructive attribution runs only after the scenario, in this disposable LuaJIT process.
release("FindMany frontiers", function()
	for _, key in ipairs({ "startBatch", "goalBatch" }) do
		local batch = upvalue(ns.ClearJourney, key)
		if batch and batch.job then
			ns.Path.Cancel(batch.job)
		end
	end
end)
release("endpoint costs/results", function()
	wipe(upvalue(ns.ClearJourney, "startCosts"))
	wipe(upvalue(ns.ClearJourney, "goalCosts"))
	for _, key in ipairs({ "startBatch", "goalBatch" }) do
		wipe(upvalue(ns.ClearJourney, key))
	end
end)
release("walkCache (shared drawing excluded)", function()
	wipe(upvalue(ns.ClearJourney, "walkCache"))
end)
release("planner topology", function()
	wipe(topologyCache)
end)
release("Path endpoint trees/connections/abstract paths", function()
	for _, st in pairs(upvalue(ns.Path.FindSync, "states")) do
		st.ends, st.endTrees, st.paths = {}, nil, nil
	end
end)
release("remaining Path graphs/grids/scratch", function()
	wipe(upvalue(ns.Path.FindSync, "states"))
end)
release("journey display/Guide on clear (client regions remain pooled)", ns.ClearJourney)
release("transport geometry (open-map scenario)", function()
	local providers = upvalue(driver.refresh, "providers")
	for _, provider in pairs(providers or {}) do
		wipe(upvalue(provider.RefreshAllData, "transportGeometry"))
	end
	local active = upvalue(WorldMapFrame.EnumeratePinsByTemplate, "active")
	for _, pins in pairs(active or {}) do
		for _, pin in pairs(pins) do
			pin.paths = nil
		end
	end
end)
release("pooled stroke Lua bookkeeping (UI region storage is client-owned)", function()
	local map = MapCanvasDataProviderMixin:GetMap()
	local pools = upvalue(map.RemoveAllPinsByTemplate, "pools")
	local active = upvalue(map.RemoveAllPinsByTemplate, "active")
	local function strokes(owner)
		owner.lines, owner.underlines, owner.hits = nil, nil, nil
	end
	for _, list in ipairs({ pools, active }) do
		for _, pins in pairs(list) do
			for _, pin in ipairs(pins) do
				strokes(pin)
			end
		end
	end
	strokes(_G.ShortestPathForeverMinimapRoute)
end)
print(
	string.format("  remaining fixture/metadata: %.1f KB excluding packed maps and base", collected() - packed - base)
)
collectgarbage("restart")
driver.check()
