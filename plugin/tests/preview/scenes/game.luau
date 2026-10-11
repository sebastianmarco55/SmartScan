-- Game tab (and the base of the Anim / Library / Claude scenes): a small mock place on tests/mocks/datamodel.luau that the
-- REAL Analyzer reads; the real AnalysisPanel analyzes it by itself on the first render, like in Studio.
local LC, P, ARGS, common = ...
local S = {}

-- the DataModel mock + the GUI layer of the preview: returns env, M (datamodel mock)
function S.world()
	local M = LC.run("tests/mocks/datamodel.luau")
	M.enableGui()
	local env = LC.env(M.globals())
	P.install(env)
	env.Vector3 = env.Vector3 or { new = M.V3 }
	env.NumberRange = env.NumberRange or P.datatypes.NumberRange
	M.methods.IsEdit = function() return true end
	M.methods.GetClassIcon = nil
	local base = M.methods.GetService
	M.methods.GetService = function(o, name)
		if o ~= M.game then
			return base(o, name)
		end
		return P.getService(function(n) return base(o, n) end, name)
	end
	for _, name in { "UserInputService", "Selection", "RunService", "ScriptEditorService", "Players", "KeyframeSequenceProvider",
		"ChangeHistoryService", "MarketplaceService", "SoundService", "Lighting", "ReplicatedStorage", "ServerStorage",
		"ServerScriptService", "StarterGui", "StarterPlayer", "StarterPack", "TextService", "Teams", "SoundService" } do
		if not M.services[name] then
			M.service(name)
		end
	end
	for _, name in { "RunService", "UserInputService", "Players", "Selection", "ChangeHistoryService", "ReplicatedStorage", "ServerStorage" } do
		rawget(M.services[name], "_data").lenient = true -- unknown members are signals (Heartbeat, OnUndo, ...)
	end
	return env, M
end

-- a game with some character: parts, models, scripts with typical problems, remotes, a GUI
function S.populate(env, M)
	local new, service, Enum = M.new, M.service, env.Enum
	local Color3 = env.Color3
	local V3 = M.V3
	local workspace = M.workspace
	local function part(name, props, parent)
		local base = { Anchored = true, Size = V3(4, 1, 2), Position = V3(0, 0, 0), Color = Color3.fromRGB(163, 162, 165),
			Material = Enum.Material.Plastic, Transparency = 0, CanCollide = true }
		for k, v in props or {} do
			base[k] = v
		end
		local p = new("Part", name, base)
		p.Parent = parent or workspace
		return p
	end
	local SS = M.services.ServerStorage
	local SSS = M.services.ServerScriptService
	local RS = M.services.ReplicatedStorage
	rawget(SSS, "_data").LoadStringEnabled = false
	rawget(M.services.StarterPlayer, "_data").CharacterWalkSpeed = 16
	local lighting = M.services.Lighting
	rawget(lighting, "_data").Technology = Enum.Technology.Future
	rawget(lighting, "_data").ClockTime = 14
	-- the map: a floor, walls in a dark / violet palette, neon accents, a spawn
	local palette = { { 40, 38, 58 }, { 61, 52, 96 }, { 98, 74, 150 }, { 31, 33, 44 }, { 120, 90, 180 } }
	part("Floor", { Size = V3(256, 2, 256), Color = Color3.fromRGB(30, 30, 42), Material = Enum.Material.Slate }, workspace)
	for i = 1, 24 do
		local c = palette[(i % #palette) + 1]
		part("Wall" .. i, { Size = V3(10, 12, 2), Position = V3(i * 11, 6, 0), Color = Color3.fromRGB(c[1], c[2], c[3]),
			Material = i % 3 == 0 and Enum.Material.Concrete or Enum.Material.Metal }, workspace)
	end
	for i = 1, 6 do
		part("Neon" .. i, { Size = V3(1, 8, 1), Position = V3(i * 20, 4, 8), Color = Color3.fromRGB(155, 92, 255),
			Material = Enum.Material.Neon }, workspace)
	end
	for i = 1, 40 do
		part("Crate" .. i, { Size = V3(3, 3, 3), Position = V3(i * 5, 2, 20), Anchored = false, CanCollide = true,
			Color = Color3.fromRGB(150, 110, 70) }, workspace)
	end
	new("SpawnLocation", "Spawn", { Anchored = true, Size = V3(8, 1, 8), Position = V3(0, 1, 0), Color = Color3.fromRGB(76, 195, 138),
		Material = Enum.Material.Plastic, Transparency = 0, CanCollide = true, Duration = 0 }).Parent = workspace
	-- an enemy
	local enemy = new("Model", "Enemy", {}, {
		new("Humanoid", "Humanoid", { RigType = Enum.HumanoidRigType.R15, Health = 100 }),
		new("Part", "HumanoidRootPart", { Anchored = false, Size = V3(2, 2, 1), Position = V3(30, 3, 30), Color = Color3.fromRGB(200, 60, 60),
			Material = Enum.Material.Plastic, Transparency = 1, CanCollide = true }),
	})
	enemy.Parent = workspace
	-- scripts
	new("Script", "Vaccine", { Source = "local x = require(4567891234)\n\nlocal y = getfenv(0)\nprint(x, y)" }).Parent = workspace
	new("Script", "Combat", { Source = "local remote = game.ReplicatedStorage.Hit\nremote.OnServerEvent:Connect(function(p, dmg)\n\t"
		.. "p.leaderstats.Cash.Value += dmg\nend)\nwhile true do\n\twait(1)\nend\n" }).Parent = SSS
	new("Script", "Shop", { Source = "local buy = game.ReplicatedStorage.Buy\nbuy.OnServerEvent:Connect(function(plr, item, price)\n\t"
		.. "plr.leaderstats.Coins.Value -= price\nend)\n" }).Parent = SSS
	new("LocalScript", "Hud", { Source = "game:GetService('RunService').RenderStepped:Connect(function()\n\tfor _, p in workspace:GetChildren() do\n\t\t"
		.. "p.Name = p.Name\n\tend\nend)\n" }).Parent = M.services.StarterGui
	new("ModuleScript", "Utils", { Source = "local U = {}\nfunction U.clamp(v, a, b)\n\treturn math.max(a, math.min(b, v))\nend\nreturn U\n" }).Parent = RS
	new("RemoteEvent", "Hit").Parent = RS
	new("RemoteEvent", "Buy").Parent = RS
	-- UI
	local gui = new("ScreenGui", "Hud", {})
	gui.Parent = M.services.StarterGui
	new("Frame", "Health", { Size = env.UDim2.new(0, 200, 0, 20) }).Parent = gui
	new("TextLabel", "Coins", { Text = "0", Size = env.UDim2.new(0, 100, 0, 20) }).Parent = gui
	new("Sound", "Music", { SoundId = "rbxassetid://1837879082" }).Parent = M.workspace
end

-- mounts the real App on the world; `tweak(scene)` runs before the first render
function S.scene(opts)
	opts = opts or {}
	local env, M = S.world()
	if ARGS.state ~= "empty" then
		S.populate(env, M)
	end
	local mocks = opts.mocks or {}
	if ARGS.tab ~= "Game" and not mocks.Analyzer then
		-- App.mount asks the Analyzer for a stored report (none: it opens the Game tab, which analyzes): not wanted on other tabs
		mocks.Analyzer = { load = function() return { version = 1 } end, context = function() return "## Joc" end }
	end
	local editor = opts.editor or common.fakeEditor()
	mocks.Editor = mocks.Editor or editor
	local tree = LC.modtree.new{ env = env, mocks = mocks }
	local scene = { env = env, M = M, tree = tree, mocks = mocks, settings = opts.settings, Editor = editor }
	if opts.before then
		opts.before(scene)
	end
	common.mount(scene)
	return scene
end

-- preview-only states, asked for with pseudo section keys:  --open preview.scanning (an analysis in progress; with
-- --state empty: the first one), --open preview.airunning (Claude's analysis on its way), --open preview.noreport (not
-- analysed, nothing running), --open preview.noai (no Claude analysis yet)
local function wants(key)
	return table.find(ARGS.open or {}, key) ~= nil
end

if ARGS.tab == "Game" then
	local scene = S.scene{
		mocks = {
			-- the answer of Claude (AnalysisPanel.askClaude) is canned; Markdown / UI / Analyzer are the real ones
			AI = {
				getKey = function() return "sk-ant-api03-demo" end,
				getModel = function() return "claude-opus-5-5" end,
				modelInfo = function(id) return id and string.find(id, "opus", 1, true) and { short = "Opus 5.5" } or nil end,
				describeInfo = function() return "Opus 5.5 · 12 480 tokeni intrare · 1 906 ieșire · 41 s" end,
				analyzeGame = function(plugin, context, opts)
					opts.onStatus("aștept răspunsul")
					return true, "## Pe scurt\nUn joc de acțiune cu hartă în tonuri de violet și multe piese ancorate. "
						.. "Bucla de bază e clară, dar lipsesc feedback-ul loviturilor și protecția remote-urilor.\n\n"
						.. "## Securitate\n1. **Backdoor confirmat**: `Workspace.Vaccine` încarcă un modul de pe site (`require(4567891234)`).\n"
						.. "2. **Remote-uri**: `Hit` și `Buy` au încredere în client. Validează `dmg` și `price` pe server.\n\n"
						.. "| Problemă | Unde | Efort |\n|---|---|---|\n| Backdoor | Workspace.Vaccine | mic |\n| Remote fără validare | Combat, Shop | mediu |\n\n"
						.. "## Acțiuni în LostCube\n- Creează un efect de lovitură din șablonul `PUNCH`, în violetul hărții\n"
						.. "- Leagă-l de markerul `Hit` al animației de atac\n\n```lua\nlocal Editor = require(game.ReplicatedStorage.LostCube.Editor)\n"
						.. "Editor.newFromTemplate(\"Lovitură\", \"PUNCH\", { color = Color3.fromRGB(155, 92, 255) })\n```",
						{ model = "claude-opus-5-5", inputTokens = 12480, outputTokens = 1906 }
				end,
			},
		},
	}
	local panel = scene.app:panel("Game")
	-- the first render of the panel started the analysis by itself (task.defer); let it finish
	P.drain(30)
	if ARGS.state ~= "empty" and ARGS.noai ~= true and not wants("preview.noai") then
		panel:askClaude()
		P.drain(30)
	end
	if wants("preview.scanning") then
		if ARGS.state == "empty" then
			panel.report = nil
		end
		panel.running, panel.fraction, panel.label = true, 0.62, "Citesc scripturile: 18 / 29"
	end
	if wants("preview.noreport") then -- not analysed and nothing running (e.g. opened during a play test)
		panel.report, panel.running = nil, false
	end
	if wants("preview.airunning") then
		panel.aiRunning, panel.aiStarted, panel.aiStatus = true, scene.env.os.clock() - 18, "aștept răspunsul" -- the panel's clock
	end
	return scene
end
return S
