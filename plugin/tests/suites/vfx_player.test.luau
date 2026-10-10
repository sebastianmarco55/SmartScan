-- Editor/VFX.luau, the player that runs in the game: it loads against stubbed services and exposes its public API.
-- (Playing an effect needs real CFrame rotations, Raycast, Heartbeat and tweens: that part is for Studio.)
local LC = ...
local t = LC.kit.new("vfx_player")
local check = t.check

local ENV = LC.run("tests/mocks/api_env.luau", nil, LC)
local function signal()
	return { Connect = function(_, f) return { Disconnect = function() end } end, Once = function() end }
end
ENV.__services.RunService = { IsStudio = function() return false end, IsClient = function() return true end,
	IsRunning = function() return true end, IsServer = function() return false end, Heartbeat = signal() }
ENV.__services.ContentProvider = { PreloadAsync = function() end }
ENV.__services.TweenService = { Create = function() return { Play = function() end, Completed = signal() } end }
local env = {}
for k, v in ENV do
	env[k] = v
end
env.UserSettings = function()
	return { GetService = function() return { SavedQualityLevel = ENV.Enum.Material.Plastic, GetPropertyChangedSignal = signal } end }
end
local folder = ENV.newInstance("Folder")
local vfxScript = ENV.newInstance("ModuleScript")
vfxScript.Name = "VFX"
vfxScript.Parent = folder
env.script = vfxScript

local VFX = LC.load("LostCube/Editor/VFX.luau", env)()
check(type(VFX) == "table", "the module returns a table")
for _, name in { "play", "bindMarkers", "preload" } do
	check(type(VFX[name]) == "function", "VFX." .. name .. " is a function")
end

t.section("an unknown effect name is a clear error", function()
	t.throws(function()
		VFX.play("Nu exista", nil)
	end, "no effect named Nu exista", "VFX.play of a missing effect")
end)

t.section("the Library folder is where named effects are looked up", function()
	local library = ENV.newInstance("Folder")
	VFX.Library = library
	t.throws(function()
		VFX.play("Boom", nil)
	end, "no effect named Boom", "empty library")
	VFX.Library = nil
end)

t.finish()
