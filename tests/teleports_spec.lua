local ns = {}
assert(loadfile("Data/Teleports.lua"))("ShortestPathForever", ns)

local bySpell = {}
for _, teleport in ipairs(ns.Teleports) do
	assert(not bySpell[teleport.spell], "one entry per spell")
	assert(teleport.cast > 0, "every teleport has a cast time")
	assert((teleport.bind == true) ~= (teleport.to ~= nil), "a teleport lands at the bind point or a sourced place")
	bySpell[teleport.spell] = teleport
end

-- UiMapAssignment 1450 (Moonglade) and 1453 (Stormwind City) bounds at build 1.60.1.69913.
local function within(point, map, minX, maxX, minY, maxY)
	return point.map == map and point.x >= minX and point.x <= maxX and point.y >= minY and point.y <= maxY
end
assert(within(bySpell[18960].to, 1, 6952.08, 8491.67, -3689.58, -1381.25), "Teleport: Moonglade lands in Moonglade")
assert(not bySpell[18960].reagents, "Teleport: Moonglade needs no reagent")
assert(within(bySpell[3561].to, 0, -9154.17, -7995.83, -14.58, 1722.92), "Teleport: Stormwind lands in Stormwind")
assert(bySpell[3561].reagents[17031] == 1, "mage teleports use a Rune of Teleportation")
assert(bySpell[8690].item == 6948 and bySpell[8690].bind, "the Hearthstone returns you to your bind point")
assert(bySpell[556].bind and not bySpell[556].item, "Astral Recall is a shaman spell to the bind point")
assert(not bySpell[1297659], "Teleport: Dalaran has no sourced destination")
assert(not bySpell[23442], "the Everlook ripper is not a personal teleport")

-- The planner: a teleport is an edge from where you stand, its remaining cooldown a wait.
assert(loadfile("Model.lua"))("ShortestPathForever", ns)
assert(loadfile("Planner.lua"))("ShortestPathForever", ns)
local Plan = ns.Planner.Plan

-- 7000 yards on foot is 1000 s; the hearth lands 70 yards short of the goal (10 s) after a 10 s cast.
local hearths = { { map = 1, x = 6930, y = 0, spell = 8690, item = 6948, cast = 10000, label = "Goldshire" } }
local function trip(ready, cache)
	return Plan({
		cache = cache,
		from = { map = 1, x = 0, y = 0 },
		to = { map = 1, x = 7000, y = 0 },
		now = 1000,
		walkSpeed = 7,
		teleports = hearths,
		teleportReady = ready and { ready } or nil,
	})
end

local hearthed = trip(1000)
assert(#hearthed.legs == 2 and hearthed.legs[1].mode == "teleport", "the hearth beats a long walk")
local cast = hearthed.legs[1]
assert(cast.teleport.item == 6948 and cast.wait == 0 and cast.arrive == 11000 and cast.ready == 1000)
assert(cast.to.kind == "teleport" and cast.to.label == "Goldshire")
assert(hearthed.legs[2].mode == "walk" and hearthed.legs[2].from == cast.to, "walk on from where it lands")
assert(ns.Planner.LegPoints(cast, {})[1].jump, "no line is drawn across the world")

local waited = trip(1000 + 300000)
assert(waited.legs[1].mode == "teleport" and waited.legs[1].wait == 300000, "a cooldown shorter than the walk waits")
assert(trip(1000 + 2000000).legs[1].mode == "walk", "a cooldown longer than the walk is ignored")
assert(trip(nil).legs[1].mode == "walk", "a teleport that cannot be cast is ignored")

-- The same topology serves a new cooldown: readiness is per plan, never a rebuild.
local cache = {}
assert(trip(1000, cache).legs[1].mode == "teleport")
local topology = cache.topology
assert(trip(1000 + 2000000, cache).legs[1].mode == "walk" and cache.topology == topology)
assert(trip(1000, cache).legs[1].mode == "teleport" and cache.topology == topology)
-- A new set of destinations (a new bind point) is a new topology.
hearths = { { map = 1, x = -700, y = 0, spell = 8690, item = 6948, cast = 10000 } }
assert(trip(1000, cache).legs[1].mode == "walk" and cache.topology ~= topology)

-- Another continent adds the loading screen.
local far = Plan({
	from = { map = 0, x = 0, y = 0 },
	to = { map = 1, x = 7000, y = 0 },
	now = 0,
	teleports = { { map = 1, x = 7000, y = 0, spell = 3566, cast = 10000 } },
	teleportReady = { 0 },
})
assert(#far.legs == 1 and far.legs[1].arrive == 15000)

-- What this character can cast, read from the client.
do
	local secret = {}
	local items, spells, cooldowns, itemCooldowns = {}, {}, {}, {}
	local bindName, position, onEvent = "Goldshire", { 10, 20, 30, 0 }, nil
	local runtime = { db = { teleports = true }, charDB = {}, Teleports = ns.Teleports }
	runtime.Init = function(fn)
		fn()
	end
	runtime.JourneyPosition = function()
		return unpack(position)
	end
	local env = setmetatable({
		C_Item = {
			GetItemCount = function(id)
				return items[id] or 0
			end,
			GetItemCooldown = function(id)
				return unpack(itemCooldowns[id] or { 0, 0, true })
			end,
		},
		C_SpellBook = {
			IsSpellKnown = function(id)
				return spells[id] or false
			end,
		},
		C_Spell = {
			GetSpellCooldown = function(id)
				return cooldowns[id] or { startTime = 0, duration = 0 }
			end,
		},
		GetBindLocation = function()
			return bindName
		end,
		GetTime = function()
			return 100
		end,
		canaccessvalue = function(value)
			return value ~= secret
		end,
		CreateFrame = function()
			return {
				RegisterEvent = function() end,
				SetScript = function(_, _, fn)
					onEvent = fn
				end,
			}
		end,
	}, { __index = _G })
	setfenv(assert(loadfile("Teleports.lua")), env)("ShortestPathForever", runtime)
	local Usable = runtime.UsableTeleports

	local places, ready = Usable(5000)
	assert(#places == 0 and next(ready) == nil, "nothing known, nothing usable")

	spells[3561] = true
	places, ready = Usable(5000)
	assert(#places == 1 and places[1].spell == 3561 and places[1].map == 0, "a known teleport is a place")
	assert(not ready[1], "without its rune it cannot be cast")
	items[17031] = 1
	local same
	same, ready = Usable(5000)
	assert(same == places and ready[1] == 5000, "the same places, now ready")
	cooldowns[3561] = { startTime = 90, duration = 60 }
	assert(select(2, Usable(5000))[1] == 55000, "the cooldown left delays it")
	cooldowns[3561] = { startTime = secret, duration = secret }
	assert(not select(2, Usable(5000))[1], "a secret cooldown is never guessed")
	cooldowns[3561], spells[3561] = nil, nil

	items[6948] = 1
	assert(#Usable(5000) == 0, "no hearth before a bind point is recorded")
	onEvent()
	local bind = runtime.charDB.bind
	assert(bind.name == "Goldshire" and bind.map == 0 and bind.x == 10 and bind.y == 20 and bind.z == 30)
	places, ready = Usable(5000)
	assert(#places == 1 and places[1].item == 6948 and places[1].x == 10 and places[1].label == "Goldshire")
	assert(ready[1] == 5000)
	runtime.db.teleports = false
	assert(#Usable(5000) == 0 and next((select(2, Usable(5000)))) == nil, "the setting off hides every teleport")
	runtime.db.teleports = true
	assert(Usable(5000) == places, "and on again, the same places")
	itemCooldowns[6948] = { 50, 3600, true }
	assert(select(2, Usable(5000))[1] == 5000 + 3550000, "the hearth's own cooldown")
	bindName = "Razor Hill"
	assert(#Usable(5000) == 0, "bound elsewhere since: no bind teleport")
	position = {}
	onEvent()
	assert(runtime.charDB.bind == nil, "no position, no bind point")
	items[6948] = 0
end

print("teleports_spec: ok")
