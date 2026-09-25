-- Minimap transport pins: placement, rim, tooltips, the tracking menu, idle cost and a redraw bench.
local dir = arg[0]:match("^(.*)/") or "tests"
local source = ""
for _, part in ipairs({ "ui_client.lua", "ui_map.lua" }) do
	local file = assert(io.open(dir .. "/" .. part))
	source = source .. file:read("*a")
	file:close()
end
assert(loadstring(source .. [[
local layer = ShortestPathForeverMinimapPins
local function shown()
 local list = {}
 for _, pin in ipairs(layer.children or {}) do
  if pin:IsShown() then list[#list + 1] = pin end
 end
 return list
end
local function frame(seconds)
 for _ = 1, seconds * 60 do
  T = T + 1 / 60
  if layer.scripts.OnUpdate then layer.scripts.OnUpdate(layer, 1 / 60) end
 end
end

-- Beside Rut'theran Village's pier: its ferry shows, and nothing a continent away does.
local dock = ns.Docks[7]
posX, posY, posZ, posMap = dock.x + 60, dock.y, dock.z or 0, dock.map
ns.RefreshMinimapPins()
local pins = shown()
local ferry
for _, pin in ipairs(pins) do
 if pin.entry.cluster and pin.entry.cluster.docks[1].id == 7 then ferry = pin end
end
assert(ferry and ferry.Texture.atlas == "flightmasterferry", "the pier's ferry shows on the minimap")
-- 60 yards north of the player on a 200-yard radius, 200-pixel minimap: 30 pixels down.
local anchor = ferry.anchor
assert(math.abs(anchor[4]) < 0.01 and math.abs(anchor[5] + 30) < 0.01, "projected like the route")
for _, pin in ipairs(pins) do
 assert(pin.entry.map == posMap and math.abs(pin.entry.x - posX) < 200, "only places in view")
end

-- The world map's tooltip, refreshed each second while hovered.
ferry.scripts.OnEnter(ferry)
assert(GameTooltip:IsOwned(ferry) and tip[1]:find("Boat to", 1, true), "the dock's departures tooltip")
ferry.scripts.OnLeave(ferry)
assert(not GameTooltip:IsOwned(ferry))

-- The rim: a place just inside the view but under the frame's edge is hidden, never clamped.
posX = dock.x + 195
frame(0.2)
for _, pin in ipairs(shown()) do
 assert(pin.entry.cluster == nil or pin.entry.cluster.docks[1].id ~= 7, "a pier at the rim hides")
end
assert(layer.scripts.OnUpdate, "still near enough to keep redrawing")

-- Far from every place: pins hide and the frame script stops, so idle play costs nothing.
posX, posY = 0, 0
frame(0.2)
assert(#shown() == 0 and not layer.scripts.OnUpdate, "no pins and no frame script away from docks")

-- The tracking menu's Transport checkbox mirrors the setting.
local entries, initializer = {}, nil
local root = {CreateCheckbox = function(_, text, get, set)
 entries[text] = {get = get, set = set}
 return {AddInitializer = function(_, fn) initializer = fn end}
end}
menus.MENU_MINIMAP_TRACKING(nil, root)
local transport = assert(entries.Transport, "a Transport entry in minimap tracking")
local icon = {SetSize = noop, SetPoint = noop, SetAtlas = function(self, atlas) self.atlas = atlas end}
local width = initializer({AttachTexture = function() return icon end,
 fontString = {SetPoint = noop, GetUnboundedStringWidth = function() return 50 end}})
assert(icon.atlas == "flightmasterferry" and width == 110, "the tracking menu's icon style")
posX, posY = dock.x + 60, dock.y
assert(transport.get())
transport.set()
assert(not ns.db.minimapPins and #shown() == 0 or not layer:IsVisible(), "off hides the pins")
transport.set()
assert(ns.db.minimapPins and #shown() > 0, "on shows them again")

-- Bench: a minute running past the pier at 60 fps, redrawn every tenth of a second, after one warm-up run has
-- grown the pin pool. The harness's own SetPoint records its anchor in a new table, so it is replaced to count
-- only the addon's allocations.
local function run()
 for i = 1, 3600 do
  posX = dock.x + 60 + 7 * i / 60
  T = T + 1 / 60
  if layer.scripts.OnUpdate then layer.scripts.OnUpdate(layer, 1 / 60) end
 end
end
run()
for _, pin in ipairs(layer.children) do pin.SetPoint = noop end
-- The interpreter, as in the game: JIT traces allocate on their own schedule.
jit.off()
jit.flush()
collectgarbage("collect")
collectgarbage("stop")
local before, start = collectgarbage("count"), os.clock()
run()
local ms, kb = (os.clock() - start) * 1000, collectgarbage("count") - before
collectgarbage("restart")
print(string.format("minimap_ui: 60 s past a pier: %.2f ms, %.4f ms/redraw, %.2f KB allocated", ms, ms / 600, kb))
assert(ms / 600 < 0.2, "a redraw stays well under a fifth of a millisecond")
assert(kb < 1, "with the pool grown, redraws reuse pins and allocate next to nothing")
assert(#errors == 0, table.concat(errors, "\n"))
print("minimap_ui: placement, rim, tooltip, tracking menu and idle stop ok")
]]))()
