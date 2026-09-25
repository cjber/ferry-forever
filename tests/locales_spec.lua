-- Every phrase a player reads goes through L, so it can be translated, and Locales/phrases.txt (what the
-- maintainer pastes into CurseForge) lists exactly the phrases the code uses.

local function read(path)
	local file = assert(io.open(path, "rb"))
	local text = file:read("*a")
	file:close()
	return text
end

-- A literal handed straight to one of the places the player reads it. `%s*` spans line breaks, so a call split
-- over lines by StyLua still counts.
local SINKS = {
	':SetText%(%s*"([^"]*)"',
	':SetFormattedText%(%s*"([^"]*)"',
	':SetHeader%(%s*"([^"]*)"',
	':CreateButton%(%s*"([^"]*)"',
	':CreateCheckbox%(%s*"([^"]*)"',
	':CreateTitle%(%s*"([^"]*)"',
	':AddLine%(%s*"([^"]*)"',
	':AddDoubleLine%(%s*"([^"]*)"',
	'AddMessage%(%s*"([^"]*)"',
	'GameTooltip_SetTitle%(%s*[%w_]+,%s*"([^"]*)"',
	'GameTooltip_Add%a*Line%(%s*[%w_]+,%s*"([^"]*)"',
	'Print%(%s*"([^"]*)"',
	'Print%(%s*string%.format%(%s*"([^"]*)"',
	-- Settings.lua's rows and Map.lua's filter menu: a saved-variable key, then the label.
	'Checkbox%(%s*"[%w_]+",%s*"([^"]*)"',
	'AddFilter%(%s*"[%w_]+",%s*"([^"]*)"',
}

-- Shown as they are on purpose: the addon's name, and `/path perf` and `/path debug` output.
local ALLOWED = {
	["Shortest Path Forever"] = true,
	["CPU profiling is unavailable on this client."] = true,
	["Memory accounting is unavailable on this client."] = true,
	["Ticks over 5 ms: %d"] = true,
	["CPU %s: %.3f ms"] = true,
	["Memory (collected): %.1f KB addon + %.1f KB walking maps = %.1f KB"] = true,
	["debug "] = true,
	["walking cost mismatch: planned %.1f, found %s"] = true,
	["map %s at %s, %s; ride: %s"] = true,
}

local shipped = {}
for line in io.lines("ShortestPathForever.toc") do
	local file = line:match("^([^#]%S*%.lua)%s*$")
	if file then
		shipped[#shipped + 1] = (file:gsub("\\", "/"))
	end
end
assert(#shipped > 20, "the TOC lists the addon's files")
assert(shipped[1] == "Locales/enUS.lua" and shipped[2] == "Locales/Translations.lua", "locales load first")

local found = {}
for _, file in ipairs(shipped) do
	if not file:match("^Locales/") and not file:match("^Data/") then
		local text = read(file):gsub("%-%-[^\n]*", "")
		for _, sink in ipairs(SINKS) do
			for literal in text:gmatch(sink) do
				if literal:match("%a") and not ALLOWED[literal] then
					found[#found + 1] = string.format('%s: "%s" (wrap it in L[])', file, literal)
				end
			end
		end
	end
end
assert(#found == 0, "\n" .. table.concat(found, "\n"))

-- The guard itself still sees a bare literal.
local probe = 'GameTooltip_AddInstructionLine(GameTooltip, "Click to go")'
assert(probe:match(SINKS[11]) == "Click to go")

-- Locales/phrases.txt is what tools/phrases.py prints.
local pipe = assert(io.popen("python3 tools/phrases.py"))
local printed = pipe:read("*a")
assert(pipe:close(), "tools/phrases.py failed")
assert(printed ~= "" and printed == read("Locales/phrases.txt"), "run: python3 tools/phrases.py > Locales/phrases.txt")

-- A missing phrase reads as English; a translation the packager writes into a locale's block replaces it.
local ns = {}
assert(loadfile("Locales/enUS.lua"))("ShortestPathForever", ns)
assert(ns.L["Journey"] == "Journey")
local translations = read("Locales/Translations.lua")
local released, count = translations:gsub('%-%-@localization%(locale="deDE"[^\n]*', 'L["Journey"] = "Reise"')
assert(count == 1, "one deDE block")
local env = setmetatable({
	GetLocale = function()
		return "deDE"
	end,
}, { __index = _G })
setfenv(assert(loadstring(released)), env)("ShortestPathForever", ns)
assert(ns.L["Journey"] == "Reise" and ns.L["Boats"] == "Boats")
for _, locale in ipairs({ "deDE", "esES", "esMX", "frFR", "itIT", "koKR", "ptBR", "ruRU", "zhCN", "zhTW" }) do
	assert(translations:find('@localization(locale="' .. locale .. '"', 1, true), locale)
end

print("locales_spec: ok")
