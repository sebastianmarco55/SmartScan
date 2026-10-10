-- The plugin's ModuleScript tree (LostCube/*.luau, LostCube/Editor/*.luau) as light fake instances, plus a loader that
-- runs the REAL source of a module with `script` and `require` of its own. Used by the suites that do not need
-- real-looking Instances for the scripts themselves.
--
--   local tree = LC.modtree.new{
--       env = LC.env{ game = ..., Color3 = ... },     -- globals the sources see (default: the plain Luau globals)
--       mocks = { UI = fakeUI, Editor = LC.modtree.MISSING }, -- require(<that module>) returns this instead of the
--                                                              -- source (MISSING: the require raises an error)
--       patch = { Editor = function(text) return text end }, -- rewrite a source before it is compiled
--   }
--   local AI = tree.load("AI")             -- module names: "AI", "Editor", "Editor.VFX" ...
--   tree.node("Editor.VFX")                -- the fake ModuleScript (script / script.Parent / require(argument))
local LC = ...

local Tree = {}
Tree.MISSING = setmetatable({}, { __tostring = function() return "<missing module>" end })

local NodeMethods = {}
local NodeMT = {}
NodeMT.__index = function(node, key)
	local method = NodeMethods[key]
	if method then
		return method
	end
	local child = rawget(node, "_byName")[key]
	if child then
		return child
	end
	error(string.format("%s is not a valid member of %s \"%s\"", tostring(key), rawget(node, "ClassName"), rawget(node, "Name")), 2)
end
NodeMT.__newindex = function(_, key)
	error("fake script node: cannot set " .. tostring(key), 2)
end
NodeMT.__tostring = function(node)
	return rawget(node, "Name")
end

function NodeMethods.FindFirstChild(node, name)
	return rawget(node, "_byName")[name]
end
function NodeMethods.WaitForChild(node, name)
	local child = rawget(node, "_byName")[name]
	if not child then
		error("fake WaitForChild would wait forever for " .. tostring(name), 2)
	end
	return child
end
function NodeMethods.GetChildren(node)
	return table.clone(rawget(node, "_children"))
end
function NodeMethods.IsA(node, class)
	return class == rawget(node, "ClassName") or class == "LuaSourceContainer" or class == "Instance"
end
function NodeMethods.GetFullName(node)
	local names, n = {}, node
	while n do
		table.insert(names, 1, rawget(n, "Name"))
		n = rawget(n, "Parent")
	end
	return table.concat(names, ".")
end

local function newNode(name, class, path, modname)
	return setmetatable({ Name = name, ClassName = class, Parent = nil, path = path, modname = modname,
		_children = {}, _byName = {} }, NodeMT)
end

local function attach(parent, child)
	rawset(child, "Parent", parent)
	table.insert(rawget(parent, "_children"), child)
	rawget(parent, "_byName")[rawget(child, "Name")] = child
end

function Tree.new(opts)
	opts = opts or {}
	local baseEnv = opts.env or LC.env()
	local mocks = opts.mocks or {}
	local patches = opts.patch or {}

	local self = { nodes = {}, loaded = {}, loading = {} }

	-- build the tree from the source files
	local root = newNode("LostCube", "Script", "LostCube/init.server.luau", "")
	self.root = root
	local folders = { [""] = root }
	local prefix = "LostCube/"
	local paths = {}
	for path in LC.files do
		if string.sub(path, 1, #prefix) == prefix then
			table.insert(paths, path)
		end
	end
	table.sort(paths)
	-- folders with an init file first (the folder IS that module), then the plain files
	for _, path in paths do
		local rel = string.sub(path, #prefix + 1)
		local dir = string.match(rel, "^(.*)/init%.luau$")
		if dir then
			local node = newNode(dir, "ModuleScript", path, (string.gsub(dir, "/", ".")))
			attach(root, node)
			folders[dir] = node
			self.nodes[dir] = node
		end
	end
	for _, path in paths do
		local rel = string.sub(path, #prefix + 1)
		local dir, file = string.match(rel, "^(.*)/([^/]+)%.luau$")
		if dir and file ~= "init" then
			local parent = folders[dir]
			local node = newNode(file, "ModuleScript", path, dir .. "." .. file)
			attach(parent, node)
			self.nodes[dir .. "." .. file] = node
		elseif not dir then
			local file2 = string.match(rel, "^([^/]+)%.luau$")
			if file2 and not string.find(file2, "^init") then
				local node = newNode(file2, "ModuleScript", path, file2)
				attach(root, node)
				self.nodes[file2] = node
			end
		end
	end

	function self.node(modname)
		return self.nodes[modname] or error("no such module in the tree: " .. tostring(modname), 2)
	end

	function self.env(modname)
		local env = {}
		for k, v in baseEnv do
			env[k] = v
		end
		env.script = self.node(modname)
		env.require = self.require
		local meta = getmetatable(baseEnv) -- an env with a fallback (__index) keeps it
		if meta then
			setmetatable(env, meta)
		end
		return env
	end

	function self.load(modname)
		if mocks[modname] == Tree.MISSING then
			error("module " .. modname .. " is not available in this test", 2)
		elseif mocks[modname] ~= nil then
			return mocks[modname]
		end
		if self.loaded[modname] ~= nil then
			return self.loaded[modname]
		end
		if self.loading[modname] then
			error("circular require of " .. modname, 2)
		end
		self.loading[modname] = true
		local node = self.node(modname)
		local fn = LC.load(rawget(node, "path"), self.env(modname), patches[modname])
		local result = fn()
		self.loading[modname] = nil
		self.loaded[modname] = result
		return result
	end

	function self.require(target)
		if type(target) == "table" and rawget(target, "modname") then
			return self.load(rawget(target, "modname"))
		end
		if opts.require then
			return opts.require(target)
		end
		error("fake require: not a module of the plugin: " .. tostring(target), 2)
	end

	return self
end

return Tree
