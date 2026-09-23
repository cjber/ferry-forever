-- Offline tools follow the shipped load order so split maps have the same contents as in game.
local map, root, env = ...
local directory = (root or ".") .. "/ShortestPathForever_Nav" .. map .. "/"
for line in io.lines(directory .. "ShortestPathForever_Nav" .. map .. ".toc") do
	local file = line:match("^%s*(.-)%s*$")
	if file:sub(1, 1) ~= "#" and file:match("%.lua$") then
		local chunk = assert(loadfile(directory .. file))
		if env then
			setfenv(chunk, env)
		end
		chunk()
	end
end
