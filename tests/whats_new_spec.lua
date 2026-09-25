-- After an update the addon says once what changed; a first install, the same version, a checkout and the
-- setting turned off stay quiet, and a missing saved table never errors.
local version, printed, frame, handler = "1.4.0", {}, nil, nil
local env = setmetatable({
	C_AddOns = {
		GetAddOnMetadata = function(name, field)
			assert(name == "ShortestPathForever" and field == "Version")
			return version
		end,
	},
	CreateFrame = function()
		frame = {
			RegisterEvent = function(_, event)
				assert(event == "PLAYER_LOGIN")
			end,
			UnregisterEvent = function() end,
			SetScript = function(_, script, fn)
				assert(script == "OnEvent")
				handler = fn
			end,
		}
		return frame
	end,
}, { __index = _G })
local ns = {
	Init = function(fn)
		fn()
	end,
	Print = function(message)
		printed[#printed + 1] = message
	end,
}
setfenv(assert(loadfile("WhatsNew.lua")), env)("ShortestPathForever", ns)
assert(type(ns.WHATS_NEW) == "string" and ns.WHATS_NEW:find("%.$"), "one sentence")

local function login(db)
	ns.db = db
	handler(frame, "PLAYER_LOGIN")
	return db
end

-- Saved variables that never loaded: nothing to compare, nothing to break.
login(nil)
assert(#printed == 0)

-- First install: remember the version, say nothing.
local db = login({ whatsNew = true })
assert(#printed == 0 and db.seenVersion == "1.4.0")

-- Same version again: nothing.
login(db)
assert(#printed == 0)

-- A new version: one line, then quiet on the next login.
version = "1.5.0"
login(db)
assert(#printed == 1 and printed[1] == "updated to 1.5.0. " .. ns.WHATS_NEW, printed[1])
assert(db.seenVersion == "1.5.0")
login(db)
assert(#printed == 1)

-- The setting off: quiet, and the version still moves on.
version, db.whatsNew = "1.6.0", false
login(db)
assert(#printed == 1 and db.seenVersion == "1.6.0")

-- A checkout reads the packager's keyword, not a version: quiet, and nothing stored.
version = "@" .. "project-version@"
login(db)
assert(#printed == 1 and db.seenVersion == "1.6.0")

print("whats_new_spec: ok")
