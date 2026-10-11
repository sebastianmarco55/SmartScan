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
	-- a green, sunny map (what the Game tab's analysis stores): "Potrivește cu harta" suggests colours against it
	Analyzer = { load = function()
		return { version = 1, style = { lighting = { clockTime = 14 }, atmosphere = { color = "C7D3E0" },
			colors = { { hex = "4B7A3A", share = 46 }, { hex = "8C8577", share = 22 }, { hex = "6E5A44", share = 14 },
				{ hex = "D9D4C7", share = 9 } } } }
	end },
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
	for _, key in { "MAGIC_CIRCLE", "RISING", "SHIELD_GLOW", "GLOW_LIGHT", "SOUND_SPARKLE", "SHAKE_LIGHT", "MAGIC_TRAIL" } do
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
-- states the CLI cannot click into (icon buttons, typed text), asked for with --open:
--   preview.playing   the preview runs, 0.6 s in (the player is mocked here: a handle with the player's clock)
--   preview.paste     a valid share code pasted in "Import și export" (preview.badcode: a damaged one)
--   preview.bare      a new effect without elements, selected
function scene.afterRender()
	local redraw = false
	for _, key in ARGS.open or {} do
		if key == "preview.bare" then
			panel.effect, panel.element = Editor.newEffect("Efect nou", { duration = 1 }), nil
			redraw = true
		elseif key == "preview.paste" or key == "preview.badcode" then
			local code = Editor.exportEffect(Editor.effect("Fulger"))
			panel.pasteCode = key == "preview.paste" and code or (string.sub(code, 1, 40) .. "x" .. string.sub(code, 42))
			redraw = true
		elseif key == "preview.playing" then
			mocks["Editor.VFX"].play = function()
				return { Done = false, start = os.clock() - 0.6, speed = 1, Destroy = function() end, Pause = function() end,
					Resume = function() end }
			end
			Editor.previewTarget = function()
				return ENV.CFrame.new()
			end
			panel:play()
		end
	end
	if redraw then
		scene.app:render()
	end
end
return scene
