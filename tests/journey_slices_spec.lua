-- A slow frame cuts the search into ten times as many slices, so it outlasts the grace period and shows a candidate
-- whose walks are still lower bounds. Measuring them must not read as a mismatch, and the proof still commits.
local driver = assert(loadfile("tests/journey_driver.lua"))()
local ns = driver.ns
for _, file in ipairs({
	"Data/Routes.lua",
	"Data/Transports.lua",
	"Data/Taxi.lua",
	"Data/Portals.lua",
	"Data/Walks.lua",
	"Path.lua",
}) do
	driver.load(file)
end
assert(loadfile("tools/load_nav.lua"))(1)
ns.faction, ns.db.debug = "Horde", true
ns.Print = function(message)
	error(message)
end
-- Every clock read costs a tenth of the 3 ms budget: about one read per 64 expansions, whatever the machine.
local now = 0
ns.Path.clock = function()
	now = now + ns.Path.budget / 10
	return now
end
local nextFrame
ns.Path.after = function(fn)
	nextFrame = fn
end
local graced
local commit = ns.SetJourneyRoute
ns.SetJourneyRoute = function(g, route)
	graced = graced or (route ~= nil and ns.JourneyStatus())
	commit(g, route)
end
driver.begin(ns.TaxiNodes[25], ns.TaxiNodes[22])
local frames = 0
while nextFrame do
	local fn = nextFrame
	nextFrame = nil
	fn()
	frames = frames + 1
	driver.update(1 / 60)
	assert(frames < 20000, "journey did not settle")
end
assert(graced, "the search should outlast the grace period")
assert(not ns.JourneyStatus())
local route = assert(driver.shown(), "expected a reachable journey")
for _, leg in ipairs(route.legs) do
	assert(leg.mode ~= "walk" or leg.measured and not leg.walkError, "the committed route's walks are proven")
end
print("journey_slices_spec: ok")
