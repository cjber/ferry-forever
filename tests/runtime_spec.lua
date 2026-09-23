-- Cache reuse must agree with a fresh topology after every dynamic input change.
local ns = {}
for _, file in ipairs({
	"Model.lua",
	"Planner.lua",
	"Data/Routes.lua",
	"Data/Transports.lua",
	"Data/Taxi.lua",
	"Data/Portals.lua",
	"Data/Walks.lua",
}) do
	assert(loadfile(file))("ShortestPathForever", ns)
end
local cache = {}
local options = {
	cache = cache,
	from = ns.TaxiNodes[26],
	to = ns.TaxiNodes[39],
	now = 123456,
	docks = ns.Docks,
	routes = ns.Routes,
	taxiNodes = ns.TaxiNodes,
	taxiPaths = ns.TaxiPaths,
	portals = ns.Portals,
	landmasses = ns.Landmasses,
	baked = ns.Walks,
	faction = "Alliance",
	walkSpeed = 7,
	taxiKnown = {},
	anchors = {},
}
local function compare()
	options.cache = cache
	local cached = ns.Planner.Plan(options)
	options.cache = nil
	local fresh = ns.Planner.Plan(options)
	assert((cached ~= nil) == (fresh ~= nil))
	if cached then
		assert(math.abs(cached.arrive - fresh.arrive) < 1e-6)
	end
	return cached
end
local original = compare()
local origin = original.legs[1].from
local originX = origin.x
local topology = cache.topology
options.now = options.now + 7000
compare()
assert(cache.topology == topology, "timing changes reuse fixed topology")
options.from = { map = origin.map, x = origin.x + 100, y = origin.y }
compare()
assert(original.legs[1].from.x == originX, "cached plans must not move previously returned endpoints")
for id in pairs(ns.TaxiNodes) do
	options.taxiKnown[id] = true
end
compare()
options.faction = "Horde"
compare()
options.waterWalking, options.walkSpeed = true, 14
compare()
options.baked = {}
compare()
options.revision = 1
compare()
print("planner topology: timings, endpoints, taxi discovery, faction, water, speed, data revision: ok")

-- Cold loading cannot happen in HasData/LowerBound or be poisoned by cancelling a pending load.
local loaded, nextFrame, fakeTime = 0, nil, 0
local env = setmetatable({
	C_AddOns = {
		DoesAddOnExist = function(name)
			return name == "ShortestPathForever_Nav0"
		end,
	},
}, { __index = _G })
-- Lua 5.1 locals enter scope after their initializer.
env.C_AddOns.LoadAddOn = function()
	loaded = loaded + 1
	setfenv(assert(loadfile("ShortestPathForever_Nav0/Nav0.lua")), env)()
end
setfenv(assert(loadfile("Path.lua")), env)("ShortestPathForever", ns)
local path = ns.Path
path.after = function(fn)
	nextFrame = fn
end
path.clock = function()
	fakeTime = fakeTime + 0.02
	return fakeTime
end
path.budget, path.cacheKB, path.graphKB = 0.01, 512, 64
local from, to = { x = -9459, y = 43 }, { x = -8914, y = -135 }
assert(path.HasData(0) and not path.HasData(1))
assert(path.LowerBound(0, from, to) == 0 and loaded == 0)
local cancelled = path.Find(0, from, to, function()
	error("cancelled callback")
end)
nextFrame()
assert(loaded == 0)
path.Cancel(cancelled)
assert(cancelled.co == nil and cancelled.scratch == nil)
local checkpoints, callbacks = 0, 0
local job = path.Find(0, from, to, function(points)
	assert(points)
	for _ = 1, 10 do
		checkpoints = checkpoints + 1
		path.Checkpoint()
	end
	callbacks = callbacks + 1
end)
local frames = 0
while nextFrame do
	local fn = nextFrame
	nextFrame = nil
	fn()
	frames = frames + 1
	assert(frames < 20000)
end
assert(loaded == 1 and frames > 20 and checkpoints == 10 and callbacks == 1)
assert(job.co == nil and job.scratch == nil, "finished handles must release coroutine locals")
-- Cancelling a callback while it is suspended must prevent its remaining work.
local began, ended = false, false
job = path.Find(0, from, to, function()
	began = true
	path.Checkpoint()
	ended = true
end)
while nextFrame and not began do
	local fn = nextFrame
	nextFrame = nil
	fn()
end
assert(began and not ended)
path.Cancel(job)
while nextFrame do
	local fn = nextFrame
	nextFrame = nil
	fn()
end
assert(not ended)
print("resumable decoding/callbacks, cold-load cancellation and released coroutine state: ok")
