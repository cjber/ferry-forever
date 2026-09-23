-- Compare every shipped cluster with a source snapshot, including the previous floor-link representation.
local function upvalue(fn, wanted, seen)
	seen = seen or {}
	if seen[fn] then
		return
	end
	seen[fn] = true
	for i = 1, 100 do
		local name, value = debug.getupvalue(fn, i)
		if not name then
			break
		end
		if name == wanted then
			return value
		end
		if type(value) == "function" then
			local found = upvalue(value, wanted, seen)
			if found then
				return found
			end
		end
	end
end
local function loader(root)
	local env = setmetatable({}, { __index = _G })
	local ns = {}
	setfenv(assert(loadfile(root .. "/Path.lua")), env)("ShortestPathForever", ns)
	for _, map in ipairs({ 0, 1, 2991 }) do
		setfenv(assert(loadfile(root .. "/ShortestPathForever_Nav" .. map .. "/Nav" .. map .. ".lua")), env)()
	end
	return assert(upvalue(ns.Path.FindSync, "State")), assert(upvalue(ns.Path.FindSync, "decodeGrid"))
end
local oldState, oldDecode = loader(assert(arg[1], "usage: luajit tests/nav_compare.lua <baseline-source-tree>"))
local newState, newDecode = loader(".")
local function equal(a, b)
	for key, v in pairs(a) do
		assert(v == b[key], tostring(key) .. " differs")
	end
	for key, v in pairs(b) do
		assert(v == a[key], tostring(key) .. " differs")
	end
end
local count = 0
for _, map in ipairs({ 0, 1, 2991 }) do
	local old, new = oldState(map), newState(map)
	for index in pairs(old.D.grid) do
		local k = index - 1
		local val = oldDecode(old, k)
		local nval, m, z, at, links = newDecode(new, k)
		equal(val, nval)
		equal(old.moves[k], m)
		equal(old.z[k], z)
		equal(old.at[k], at)
		for node, l in pairs(old.links[k]) do
			local a, b = {}, {}
			for i = 1, #l, 2 do
				a[l[i] + 8 * (l[i + 1] + 1)] = true
			end
			for _, v in ipairs(links[node] or {}) do
				b[v] = true
			end
			equal(a, b)
		end
		for node in pairs(links) do
			assert(old.links[k][node])
		end
		old.val[k], old.moves[k], old.z[k], old.at[k], old.links[k] = nil, nil, nil, nil, nil
		count = count + 1
	end
end
print("Decoded grids equivalent:", count, "surfaces, moves, heights, floors, directed link sets")
