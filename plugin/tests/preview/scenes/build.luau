-- Build tab (Modelare): the real Modeling engine on the typed Roblox mock of its tests (tests/mocks/modeling_env.luau)
-- with a small demo place (a baseplate, posts, a generated house, a tree to scatter), the real BuildPanel + UI + App.
-- Demo variants (they ride on --open, the keys are harmless section keys):
--   --open build.demo.parts   three posts, the tree and loose pebbles selected (operations have something to work on)
--   --open build.demo.model   the generated house selected (the form loads its parameters: Actualizează)
--   --state empty             nothing in the place, no generator chosen
-- e.g. render.py --tab Build --click Operații --open build.demo.parts,build.op.fill
local LC, P, ARGS, common = ...
local ENV = LC.run("tests/mocks/modeling_env.luau", nil, LC)
local services = ENV.__services

local function has(key)
	for _, k in ARGS.open or {} do
		if k == key then
			return true
		end
	end
	return false
end

-- services the GUI kit, App and the panel touch (the typed mock only has the modeling ones)
local signalOf = P.newSignal
local function stub(name, extra)
	services[name] = services[name] or extra or P.stub(name)
	return services[name]
end
stub("UserInputService", { IsKeyDown = function() return false end, InputBegan = signalOf() })
stub("RunService", { Heartbeat = signalOf(), IsEdit = function() return true end, IsRunning = function() return false end })
stub("StudioService", P.StudioService)
services.ChangeHistoryService.OnUndo = signalOf()
services.ChangeHistoryService.OnRedo = signalOf()
services.Selection.SelectionChanged = signalOf()

-- the typed mock has no signals: every instance gets the ones App / the panel connect to (they never fire here)
local EVENT_NAMES = { ChildAdded = true, ChildRemoved = true, DescendantAdded = true, DescendantRemoving = true, Destroying = true,
	Changed = true, AttributeChanged = true, AncestryChanged = true }
local signals = setmetatable({}, { __mode = "k" })
local function signalFor(inst, key)
	local per = signals[inst]
	if not per then
		per = {}
		signals[inst] = per
	end
	per[key] = per[key] or signalOf()
	return per[key]
end
local function addSignals(inst)
	local meta = getmetatable(inst)
	if type(meta) ~= "table" or meta.__lcSignals then
		return inst
	end
	meta.__lcSignals = true
	local old = meta.__index
	meta.__index = function(self, k)
		if EVENT_NAMES[k] then
			return signalFor(self, k)
		elseif k == "GetAttributeChangedSignal" then
			return function(o, name) return signalFor(o, "Attr:" .. tostring(name)) end
		elseif k == "GetPropertyChangedSignal" then
			return function(o, name) return signalFor(o, "Prop:" .. tostring(name)) end
		end
		return old(self, k)
	end
	return inst
end
for _, name in { "ReplicatedStorage", "ServerStorage" } do
	addSignals(services[name])
end
addSignals(ENV.workspace)

-- game:GetService through the preview's helpers (TweenService, TextService, stubs for the rest)
local baseGame = ENV.game
ENV.game = setmetatable({}, { __index = function(_, k)
	if k == "GetService" then
		return function(_, name)
			return P.getService(function(n) return services[n] or baseGame:GetService(n) end, name)
		end
	end
	return baseGame[k]
end })

local baseNew = ENV.Instance.new
ENV.Instance = { new = function(class, parent)
	local inst = baseNew(class, parent)
	if not P.isGuiClass(class) then
		addSignals(inst)
	end
	return inst
end }

P.install(ENV, { mergeEnum = true })

local mocks = {
	Installer = { status = function() return { version = "2.1.0", editor = "2.1.0", vfx = "2.1.0", ok = true } end, install = function() end },
	Analyzer = { load = function() return { version = 1 } end },
}
local tree = LC.modtree.new{ env = ENV, mocks = mocks }
local Modeling = tree.load("Modeling")
local Vector3, CFrame, Color3, Enum, Instance = ENV.Vector3, ENV.CFrame, ENV.Color3, ENV.Enum, ENV.Instance
local workspace = ENV.workspace

-- demo place ----------------------------------------------------------------------------------------------------------
local demo = {}
if ARGS.state ~= "empty" then
	local base = ENV.part("Part", Vector3.new(256, 1, 256), CFrame.new(0, -0.5, 0))
	base.Name = "Baseplate"
	base.Color = Color3.fromRGB(91, 154, 76)
	base.Material = Enum.Material.Grass
	demo.posts = {}
	for i, x in { -12, 0, 12 } do
		local post = ENV.part("Part", Vector3.new(1, 6, 1), CFrame.new(x, 3, -30 + i * 2))
		post.Name = "Stâlp" .. i
		post.Color = Color3.fromRGB(120, 86, 56)
		post.Material = Enum.Material.Wood
		table.insert(demo.posts, post)
	end
	demo.house = Modeling.generate("building", { width = 24, depth = 20, floors = 2, roof = "gable" }, nil, CFrame.new(40, 0, 0))
	demo.house.Name = "Casa"
	demo.tree = Modeling.generate("tree", { kind = "pine", height = 14, seed = 3 }, nil, CFrame.new(-40, 0, 20))
	demo.tree.Name = "Brad"
	-- loose decor (unanchored pebbles): something for the optimizer to report
	demo.pebbles = Instance.new("Model")
	demo.pebbles.Name = "Pietre"
	for i = 1, 6 do
		local p = ENV.part("Part", Vector3.new(0.6, 0.4, 0.5), CFrame.new(-30 + i, 0.2, 10), demo.pebbles)
		p.Anchored = false
		p.Color = Color3.fromRGB(125, 122, 117)
	end
	demo.pebbles.Parent = workspace
	ENV.__history.log = {}
end

local Editor = common.fakeEditor()
local scene = { tree = tree, Editor = Editor, Modeling = Modeling }
common.mount(scene)
local panel = scene.app:panel("Build")
if ARGS.state ~= "empty" then
	panel.kind = "building"
	if has("build.demo.parts") then
		local list = table.clone(demo.posts)
		table.insert(list, demo.tree)
		table.insert(list, demo.pebbles)
		services.Selection:Set(list)
	elseif has("build.demo.model") then
		services.Selection:Set({ demo.house })
	end
	panel:onSelection()
end
scene.demo = demo
return scene
