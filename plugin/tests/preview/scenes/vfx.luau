-- VFX tab: the real Editor on the typed Roblox mock (tests/mocks/api_env.luau) with a few effects made by the Editor itself
-- (templates and presets of every element kind), the real VFXPanel + UI + App.
local LC, P, ARGS, common = ...
local ENV = LC.run("tests/mocks/api_env.luau", nil, LC)

-- services the GUI kit and the panels touch
local services = ENV.__services
local function stub(name, extra)
	local s = extra or {}
	services[name] = services[name] or s
	return services[name]
end
local signalOf = P.newSignal
stub("UserInputService", { IsKeyDown = function() return false end })
stub("RunService", { Heartbeat = signalOf(), IsEdit = function() return true end, IsRunning = function() return false end })
stub("SoundService", { PlayLocalSound = function() end })
stub("StudioService", P.StudioService)
local origGetService = ENV.game.GetService
ENV.game.GetService = function(self, name)
	return P.getService(function(n) return origGetService(self, n) end, name)
end
stub("Players", { LocalPlayer = nil })
stub("ScriptEditorService", {})
stub("Lighting", {})
ENV.workspace = ENV.workspace or ENV.newInstance("Workspace")
services.ChangeHistoryService.OnUndo = signalOf()
services.ChangeHistoryService.OnRedo = signalOf()
services.Selection.Set = function() end
-- the typed mock has no signals: every instance gets the ones the panels connect to (they never fire here)
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
P.wrapBase = addSignals
for _, name in { "ReplicatedStorage", "ServerStorage" } do
	addSignals(services[name])
end
local baseNew = ENV.Instance.new
ENV.Instance = { new = function(class)
	local inst = baseNew(class)
	if not P.isGuiClass(class) then
		addSignals(inst)
	end
	return inst
end }

P.install(ENV, { mergeEnum = true })

local mocks = {
	["Editor.VFX"] = { play = function() end },
	Installer = { status = function() return { version = "2.1.0", editor = "2.1.0", vfx = "2.1.0", ok = true } end, install = function() end },
	Analyzer = { load = function() return { version = 1 } end },
}
local tree = LC.modtree.new{ env = ENV, mocks = mocks }
local Editor = tree.load("Editor")

-- demo state ----------------------------------------------------------------------------------------------------------
if ARGS.state ~= "empty" then
	local boom = Editor.newFromTemplate("Explozie de foc", "FIRE_EXPLOSION", { scale = 1 })
	Editor.newFromTemplate("Vindecare", "HEAL", { color = ENV.Color3.fromRGB(90, 230, 160) })
	Editor.newFromTemplate("Fulger", "LIGHTNING")
	Editor.newFromTemplate("Aterizare", "LANDING")
	local magic = Editor.newEffect("Aură magică", { duration = 2, attach = "ROOT" })
	for _, key in { "MAGIC_CIRCLE", "RISING", "SHIELD_GLOW", "GLOW_LIGHT", "SOUND_SPARKLE", "SHAKE_LIGHT" } do
		pcall(Editor.addElement, magic, key)
	end
	local chosen = Editor.effects()[1]
	for _, fx in Editor.effects() do
		if fx.Name == "Explozie de foc" then
			chosen = fx
		end
	end
	scene = { chosen = chosen }
end

local scene = { tree = tree, Editor = Editor }
common.mount(scene)
local panel = scene.app:panel("VFX")
if ARGS.state ~= "empty" then
	for _, fx in Editor.effects() do
		if fx.Name == "Explozie de foc" then
			panel.effect = fx
			local els = Editor.elements(fx)
			panel.element = els[1]
		end
	end
end
function scene.afterRender() end
return scene
