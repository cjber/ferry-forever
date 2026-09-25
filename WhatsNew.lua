local addonName = ...
---@class SPFNamespace
local ns = select(2, ...)

-- One sentence on what the latest release changed, printed once after an update. Each release refreshes it from
-- its CHANGELOG entry.
ns.WHATS_NEW = "The flight map shows which flight to take, and route stops look like the map's own quest buttons."

-- Once per new version, after an update: never on a first install, nor in a checkout, whose TOC still holds the
-- packager's version keyword (matched by its "@", as the packager would rewrite the whole keyword here too).
function ns.CheckWhatsNew()
	local db = ns.db
	local version = C_AddOns.GetAddOnMetadata(addonName, "Version")
	if not db or not version or version:find("^@") then
		return
	end
	local seen = db.seenVersion
	db.seenVersion = version
	if seen and seen ~= version and db.whatsNew then
		ns.Print(string.format("updated to %s. %s", version, ns.WHATS_NEW))
	end
end

ns.Init(function()
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("PLAYER_LOGIN")
	frame:SetScript("OnEvent", function(self)
		self:UnregisterEvent("PLAYER_LOGIN")
		ns.CheckWhatsNew()
	end)
end)
