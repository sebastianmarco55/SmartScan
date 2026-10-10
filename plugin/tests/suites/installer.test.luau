-- Installer: puts Editor + VFX into ReplicatedStorage.LostCube (status, install, update on a version change, nothing
-- duplicated, the Effects folder is kept, a failed install is cancelled in the undo history). The real Installer runs
-- on the typed Roblox mock; the plugin's own Editor / VFX modules are fake ModuleScript instances.
local LC = ...
local t = LC.kit.new("installer")
local eq, check = t.eq, t.check

local ENV = LC.run("tests/mocks/api_env.luau", nil, LC)
local new, D, history = ENV.newInstance, ENV.__DATA, ENV.__history
local RS = ENV.__services.ReplicatedStorage

local function named(class, name, parent)
	local inst = new(class)
	inst.Name = name
	inst.Parent = parent
	return inst
end

-- the plugin as it is in Studio: LostCube/{Installer, Editor/{VFX}}
local pluginRoot = named("Folder", "LostCube")
local editorMod = named("ModuleScript", "Editor", pluginRoot)
local vfxMod = named("ModuleScript", "VFX", editorMod)
named("ModuleScript", "Inner", vfxMod)
named("ModuleScript", "Helper", editorMod)
local installerMod = named("ModuleScript", "Installer", pluginRoot)

local version = "2.0.0"
local env = {}
for k, v in ENV do
	env[k] = v
end
env.script = installerMod
env.require = function(module)
	assert(module == editorMod, "the Installer should only require the Editor")
	return { VERSION = version }
end
-- Installer reads the plugin's version once (status() runs on every redraw): a new plugin session = a fresh module
local function loadInstaller()
	return LC.load("LostCube/Installer.luau", env)()
end
local Installer = loadInstaller()

local function lastRecording()
	local entries = {}
	for _, line in history.log do
		if string.find(line, "^begin") or string.find(line, "^finish") then
			table.insert(entries, line)
		end
	end
	return entries
end

t.section("status before the install", function()
	local s = Installer.status()
	eq("version of the plugin", s.version, version)
	eq("no Editor in the game", s.editor, nil)
	eq("no VFX in the game", s.vfx, nil)
	eq("not ok", s.ok, false)
end)

t.section("install", function()
	local s = Installer.install()
	eq("ok after install", s.ok, true)
	eq("editor version", s.editor, version)
	eq("vfx version", s.vfx, version)
	local root = RS:FindFirstChild("LostCube")
	check(root ~= nil, "ReplicatedStorage.LostCube exists")
	check(root and root:FindFirstChild("Effects") ~= nil and root.Effects.ClassName == "Folder", "Effects folder")
	local editor, vfx = root:FindFirstChild("Editor"), root:FindFirstChild("VFX")
	check(editor and editor.ClassName == "ModuleScript" and vfx and vfx.ClassName == "ModuleScript", "both modules are copied")
	eq("the Editor copy has no children (it uses the VFX next to it)", #editor:GetChildren(), 0)
	eq("the VFX copy has no children", #vfx:GetChildren(), 0)
	check(editor ~= editorMod and vfx ~= vfxMod, "copies, not the plugin's own scripts")
	check(editorMod:FindFirstChild("VFX") == vfxMod, "the plugin's own tree is untouched")
	eq("version attribute on the Editor", editor:GetAttribute("LC_Version"), version)
	eq("version attribute on the VFX", vfx:GetAttribute("LC_Version"), version)
	local entries = lastRecording()
	eq("one undo step: begin", entries[#entries - 1], "begin LostCube: instalare module")
	eq("one undo step: committed", entries[#entries], "finish Commit")
	check(history.active == nil, "no recording left open")
end)

t.section("install again: nothing duplicated, the effects are kept", function()
	local root = RS:FindFirstChild("LostCube")
	named("Model", "MyEffect", root.Effects)
	Installer.install()
	local count = { Editor = 0, VFX = 0, Effects = 0 }
	for _, child in RS:FindFirstChild("LostCube"):GetChildren() do
		if count[child.Name] then
			count[child.Name] += 1
		end
	end
	eq("one Editor", count.Editor, 1)
	eq("one VFX", count.VFX, 1)
	eq("one Effects folder", count.Effects, 1)
	check(root.Effects:FindFirstChild("MyEffect") ~= nil, "the user's effect survived the update")
	eq("only one LostCube folder", #RS:GetChildren(), 1)
end)

t.section("a new plugin version makes the game's modules outdated until the next install", function()
	version = "2.1.0"
	Installer = loadInstaller() -- Studio restarted with the new plugin
	local s = Installer.status()
	eq("outdated", s.ok, false)
	eq("shows the installed version", s.editor, "2.0.0")
	eq("shows the plugin version", s.version, "2.1.0")
	s = Installer.install()
	eq("updated", s.ok, true)
	eq("new version in the game", s.vfx, "2.1.0")
end)

t.section("a module without a version attribute counts as outdated", function()
	RS.LostCube.VFX:SetAttribute("LC_Version", nil)
	local s = Installer.status()
	eq("not ok", s.ok, false)
	eq("question mark for the unknown version", s.vfx, "?")
	Installer.install()
end)

t.section("a failed install is cancelled and the error is raised", function()
	local broken = {
		Clone = function() error("clone failed") end,
		GetChildren = function() return {} end,
	}
	local fakeEditor = { VFX = broken, Clone = broken.Clone }
	local failing = {}
	for k, v in env do
		failing[k] = v
	end
	failing.require = function() return { VERSION = version } end
	failing.script = { Parent = { Editor = fakeEditor } }
	local Failing = LC.load("LostCube/Installer.luau", failing)()
	local before = #lastRecording()
	local ok, err = pcall(Failing.install)
	check(not ok and string.find(tostring(err), "clone failed", 1, true) ~= nil, "the error is raised: " .. tostring(err))
	local entries = lastRecording()
	eq("one more recording", #entries, before + 2)
	eq("it was cancelled", entries[#entries], "finish Cancel")
	check(history.active == nil, "no recording left open")
end)

t.finish()
