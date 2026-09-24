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

print("teleports_spec: ok")
