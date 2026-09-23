local ns = { db = { share = true } }
for _, file in ipairs({ "Data/Routes.lua", "Data/Transports.lua", "Model.lua" }) do
	assert(loadfile(file))("ShortestPathForever", ns)
end
local now, timers, sent, handler = 0, {}, {}
local function noop() end
local env = setmetatable({
	GetTime = function()
		return now
	end,
	GetServerTime = function()
		return 1790000000 + math.floor(now)
	end,
	GetNormalizedRealmName = function()
		return "Test"
	end,
	UnitName = function()
		return "Me"
	end,
	Ambiguate = function(sender)
		return sender:match("^[^-]+")
	end,
	IsInGuild = function()
		return true
	end,
	IsInGroup = function()
		return true
	end,
	IsInRaid = function()
		return false
	end,
	IsInInstance = function()
		return false
	end,
	LE_PARTY_CATEGORY_INSTANCE = 1,
	Enum = { SendAddonMessageResult = { InvalidPrefix = 1, InvalidChatType = 2, InvalidChannel = 3 } },
	C_ChatInfo = {
		RegisterAddonMessagePrefix = noop,
		SendAddonMessage = function(_, message, distribution)
			assert(#message <= 250, "sync message exceeds the wire limit")
			assert(not sent[#sent] or now - sent[#sent].at >= 1.5 - 0.000001, "sync sent faster than its rate limit")
			sent[#sent + 1] = { at = now, message = message, distribution = distribution }
			return 0
		end,
	},
	C_Timer = {
		After = function(delay, fn)
			timers[#timers + 1] = { at = now + delay, fn = fn }
		end,
		NewTicker = noop,
	},
	CreateFrame = function()
		return {
			RegisterEvent = noop,
			SetScript = function(_, _, fn)
				handler = fn
			end,
		}
	end,
}, { __index = _G })
ns.OnTravelTick = noop
ns.Init = function(fn)
	fn()
end
ns.FreshAnchors = function()
	local anchors = {}
	for id in pairs(ns.Routes) do
		anchors[id] = { epoch = 1790000000000, seen = env.GetServerTime() }
	end
	return anchors
end
ns.Sighted = noop
setfenv(assert(loadfile("Sync.lua")), env)("ShortestPathForever", ns)
local function advance(seconds)
	local untilTime = now + seconds
	while true do
		local first
		for i, timer in ipairs(timers) do
			if timer.at <= untilTime and (not first or timer.at < timers[first].at) then
				first = i
			end
		end
		if not first then
			break
		end
		local timer = table.remove(timers, first)
		now = timer.at
		timer.fn()
	end
	now = untilTime
end
local function request(message, distribution)
	handler(nil, "CHAT_MSG_ADDON", "ShortPath1", message, distribution, "Peer-Test")
end
local function upvalue(fn, wanted)
	for i = 1, math.huge do
		local name, value = debug.getupvalue(fn, i)
		assert(name, "missing upvalue " .. wanted)
		if name == wanted then
			return value
		end
	end
end
local queue = upvalue(upvalue(upvalue(ns.Share, "SendSightings"), "Send"), "queue")
advance(20)
request("Q241", "YELL")
advance(6)
local count = #sent
assert(sent[count].distribution == "YELL" and sent[count].message:sub(1, 1) == "S")
request("Q241", "YELL")
advance(6)
assert(#sent == count, "repeat replies must wait 30 seconds")
request("Q241", "GUILD")
advance(6)
assert(#sent == count + 1, "reply suppression must be per distribution")

-- Enough requests and fresh sightings to outpace the sender; pending work must depend only on routes/channels.
local distributions = { "GUILD", "PARTY", "RAID", "INSTANCE_CHAT", "YELL" }
local routes = 0
for _ in pairs(ns.Routes) do
	routes = routes + 1
end
for _ = 1, 10 do
	for id in pairs(ns.Routes) do
		for _, distribution in ipairs(distributions) do
			request("Q" .. id, distribution)
		end
		ns.Share(id)
	end
	assert(#timers <= 6, "requests must share one reply timer per distribution")
	advance(5)
	assert(#queue <= 10, "sync queue must stay bounded by two batches per distribution")
	local pending = 0
	for _, batch in ipairs(queue) do
		for _ in pairs(batch.entries) do
			pending = pending + 1
		end
	end
	assert(pending <= #distributions * 2 * routes, "queued routes must be deduplicated")
	advance(26)
end
advance(120)
assert(#queue == 0 and #timers == 0, "bounded sync work must drain")
print("sync_spec: ok")
