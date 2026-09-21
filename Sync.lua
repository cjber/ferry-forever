local _, ns = ...

local Model = ns.Model
local PREFIX = "FerryFvr1"
local MAX_MESSAGE = 250
local SPACING = 1.5
-- Ask the dock at most this often, and only within this range of it.
local ASK_EVERY = 120
local ASK_RANGE = 150
local REPLY_EVERY = 30
-- Sightings are only taken from these; a whisper is anyone's.
local ACCEPTED = { GUILD = true, PARTY = true, RAID = true, INSTANCE_CHAT = true, YELL = true }
local UNSUPPORTED = {
	[Enum.SendAddonMessageResult.InvalidPrefix] = true,
	[Enum.SendAddonMessageResult.InvalidChatType] = true,
	[Enum.SendAddonMessageResult.InvalidChannel] = true,
}

local queue, sending = {}, false
local disabled, lastAsk = {}, 0
-- [chatType][route] = GetTime() a sighting of it last went out or arrived there, so a route answered on that
-- distribution recently (by us or by someone else) is not answered again.
local answered = {}

local function Answered(chatType, routeID)
	return (answered[chatType] or {})[routeID] or -math.huge
end

local function MarkAnswered(chatType, routeID)
	answered[chatType] = answered[chatType] or {}
	answered[chatType][routeID] = GetTime()
end

local function Flush()
	local item = table.remove(queue, 1)
	if not item then
		sending = false
		return
	end
	if ns.db.share and not disabled[item.chatType] then
		local result = C_ChatInfo.SendAddonMessage(PREFIX, item.message, item.chatType)
		-- A distribution this client does not support stays off for the session; anything else (throttled, not
		-- in a group any more, lockdown) only loses this message.
		if UNSUPPORTED[result] then
			disabled[item.chatType] = true
		end
	end
	C_Timer.After(SPACING, Flush)
end

local function Send(message, chatType)
	queue[#queue + 1] = { message = message, chatType = chatType }
	if not sending then
		sending = true
		Flush()
	end
end

-- Guild and group, plus yell (everyone around, outside instances) when asked.
local function Distributions(yell)
	local chatTypes = {}
	if IsInGuild() then
		chatTypes[#chatTypes + 1] = "GUILD"
	end
	if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
		chatTypes[#chatTypes + 1] = "INSTANCE_CHAT"
	elseif IsInRaid() then
		chatTypes[#chatTypes + 1] = "RAID"
	elseif IsInGroup() then
		chatTypes[#chatTypes + 1] = "PARTY"
	end
	if yell and not IsInInstance() then
		chatTypes[#chatTypes + 1] = "YELL"
	end
	return chatTypes
end

-- Sightings packed into as few messages as fit, sent to each distribution given.
local function SendSightings(anchors, chatTypes)
	local messages = {}
	for _, entry in ipairs(Model.Encode(anchors, ns.Routes)) do
		local last = messages[#messages]
		if last and #last + 1 + #entry <= MAX_MESSAGE then
			messages[#messages] = last .. ";" .. entry
		else
			messages[#messages + 1] = "S" .. entry
		end
	end
	for _, chatType in ipairs(chatTypes) do
		for _, message in ipairs(messages) do
			Send(message, chatType)
		end
	end
end

function ns.Share(routeID)
	local anchor = ns.FreshAnchors()[routeID]
	if ns.db.share and anchor then
		SendSightings({ [routeID] = anchor }, Distributions(true))
	end
end

-- Ask for the given routes (a list of IDs), naming them so only holders of those answer.
local function Ask(routeIDs, chatTypes)
	if #routeIDs == 0 then
		return
	end
	table.sort(routeIDs)
	local message = "Q" .. table.concat(routeIDs, ",")
	for _, chatType in ipairs(chatTypes) do
		Send(message, chatType)
	end
end

local function Untimed()
	local fresh, routeIDs = ns.FreshAnchors(), {}
	for routeID in pairs(ns.Routes) do
		if not fresh[routeID] then
			routeIDs[#routeIDs + 1] = routeID
		end
	end
	return routeIDs
end

-- Only this realm's boats: a cross-realm sender runs another server's schedule.
local function SameRealm(sender)
	local realm = sender:match("%-(.+)$")
	return realm == nil or realm == GetNormalizedRealmName()
end

local function OnMessage(prefix, message, chatType, sender)
	if prefix ~= PREFIX or not ns.db.share or not ACCEPTED[chatType] or not SameRealm(sender) then
		return
	end
	if Ambiguate(sender, "none") == UnitName("player") then
		return
	end
	if message:sub(1, 1) == "Q" then
		local wanted = {}
		for routeID in message:gmatch("%d+") do
			wanted[tonumber(routeID)] = true
		end
		-- Spread replies so everyone at a dock does not answer at once, and skip routes answered on this
		-- distribution (by anyone) within the last REPLY_EVERY seconds.
		C_Timer.After(1 + math.random() * 4, function()
			local reply = {}
			for routeID, anchor in pairs(ns.FreshAnchors()) do
				if wanted[routeID] and GetTime() - Answered(chatType, routeID) >= REPLY_EVERY then
					reply[routeID] = anchor
					MarkAnswered(chatType, routeID)
				end
			end
			SendSightings(reply, { chatType })
		end)
	elseif message:sub(1, 1) == "S" then
		for routeID, anchor in pairs(Model.Decode(message:sub(2), ns.Routes, GetServerTime())) do
			MarkAnswered(chatType, routeID)
			anchor.source = "player"
			ns.Sighted(routeID, anchor)
		end
	end
end

-- Near a dock with a boat nobody has timed yet, ask whoever is around.
local function AskAtDock()
	if not ns.db.share or IsInInstance() or GetTime() - lastAsk < ASK_EVERY then
		return
	end
	local dockID, yards = ns.NearestDock()
	if not dockID or yards > ASK_RANGE then
		return
	end
	local routeIDs = {}
	for _, departure in ipairs(ns.DockDepartures(dockID)) do
		if not departure.known then
			routeIDs[#routeIDs + 1] = departure.route
		end
	end
	if #routeIDs > 0 then
		lastAsk = GetTime()
		Ask(routeIDs, { "YELL" })
	end
end

ns.Init(function()
	C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("CHAT_MSG_ADDON")
	frame:SetScript("OnEvent", function(_, _, ...)
		OnMessage(...)
	end)
	C_Timer.After(15, function()
		if ns.db.share then
			Ask(Untimed(), Distributions(false))
		end
	end)
	C_Timer.NewTicker(5, AskAtDock)
end)
