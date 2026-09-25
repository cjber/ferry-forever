-- Every phrase a player reads goes through L, so it can be translated, and Locales/phrases.txt (the file a
-- translator copies) lists exactly the phrases the code uses.

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
assert(shipped[1] == "Locales/enUS.lua", "L exists before any file uses it")

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

-- A missing phrase reads as English. The template is a working translation file: in its own language it
-- replaces the English, in any other it changes nothing.
local ns = {}
assert(loadfile("Locales/enUS.lua"))("ShortestPathForever", ns)
assert(ns.L["Journey"] == "Journey")
local template, count = read("Locales/phrases.txt"):gsub('\nL%["Journey"%] = "Journey"\n', '\nL["Journey"] = "Reise"\n')
assert(count == 1, "the template lists Journey")
for _, case in ipairs({ { "frFR", "Journey" }, { "deDE", "Reise" } }) do
	local env = setmetatable({
		GetLocale = function()
			return case[1]
		end,
	}, { __index = _G })
	setfenv(assert(loadstring(template)), env)("ShortestPathForever", ns)
	assert(ns.L["Journey"] == case[2] and ns.L["Boats"] == "Boats", case[1])
end

-- The packager's CurseForge localization keyword would fail the release: CurseForge no longer serves translations.
local keyword = "@" .. "localization"
local grep = assert(io.popen("git grep -l -F '" .. keyword .. "'"))
local hits = grep:read("*a")
grep:close()
assert(hits == "", "remove the packager localization keyword from:\n" .. hits)

print("locales_spec: ok")
