local _, ns = ...

local Model = ns.Model
local PREFIX = "FerryFvr1"
local MAX_MESSAGE = 250
local SPACING = 1.5
-- Ask the dock at most this often, and only within this range of it.
local ASK_EVERY = 120
local ASK_RANGE = 150
local REPLY_EVERY = 30

local queue, sending = {}, false
local disabled, lastReply, lastAsk = {}, {}, 0

local function Flush()
	local item = table.remove(queue, 1)
	if not item then
		sending = false
		return
	end
	if not disabled[item.chatType] then
		local result = C_ChatInfo.SendAddonMessage(PREFIX, item.message, item.chatType)
		-- A distribution this client refuses (not merely throttled) stays off for the session.
		if
			result ~= Enum.SendAddonMessageResult.Success
			and result ~= Enum.SendAddonMessageResult.AddonMessageThrottle
			and result ~= Enum.SendAddonMessageResult.ChannelThrottle
		then
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

local function Ask(chatTypes)
	for _, chatType in ipairs(chatTypes) do
		Send("Q", chatType)
	end
end

-- Only this realm's boats: a cross-realm sender runs another server's schedule.
local function SameRealm(sender)
	local realm = sender:match("%-(.+)$")
	return realm == nil or realm == GetNormalizedRealmName()
end

local function OnMessage(prefix, message, chatType, sender)
	if prefix ~= PREFIX or not ns.db.share or not SameRealm(sender) then
		return
	end
	if Ambiguate(sender, "none") == UnitName("player") then
		return
	end
	if message == "Q" then
		local now = GetTime()
		local fresh = ns.FreshAnchors()
		if next(fresh) and now - (lastReply[chatType] or -math.huge) >= REPLY_EVERY then
			lastReply[chatType] = now
			-- Spread replies so everyone at a dock does not answer at once.
			C_Timer.After(1 + math.random() * 4, function()
				SendSightings(fresh, { chatType })
			end)
		end
	elseif message:sub(1, 1) == "S" then
		for routeID, anchor in pairs(Model.Decode(message:sub(2), ns.Routes, GetServerTime())) do
			ns.Sighted(routeID, anchor, "player")
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
	for _, departure in ipairs(ns.DockDepartures(dockID)) do
		if not departure.known then
			lastAsk = GetTime()
			Ask({ "YELL" })
			return
		end
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
			Ask(Distributions(false))
		end
	end)
	C_Timer.NewTicker(5, AskAtDock)
end)
