-- Tools.luau executors against a mock DataModel, a mock Editor / AnimGen, the real Analyzer.resolve and AnimLibrary
local RS, SS, SSS, WS = game:GetService("ReplicatedStorage"), game:GetService("ServerStorage"),
	game:GetService("ServerScriptService"), game:GetService("Workspace")

-- the place
local door = Instance.new("Part", { Name = "Door", Parent = WS, Position = Vector3.new(1, 2.5, -3), Size = Vector3.new(4, 7, 1),
	Anchored = true, Color = Color3.fromRGB(255, 0, 0), Material = Enum.Material.Wood, Transparency = 0 })
door:SetAttribute("Locked", true)
door.__data.tags = { "Doors" }
local handle = Instance.new("Part", { Name = "Sword.Handle", Parent = WS }) -- a dot in the name
local dummy = Instance.new("Model", { Name = "Dummy", Parent = WS, PivotPosition = Vector3.new(0, 3, 0) })
Instance.new("Humanoid", { Name = "Humanoid", Parent = dummy, RigType = Enum.HumanoidRigType.R15, Health = 100, WalkSpeed = 16 })
Instance.new("Part", { Name = "HumanoidRootPart", Parent = dummy })
Instance.new("Part", { Name = "UpperTorso", Parent = dummy })
local lines = {}
for i = 1, 500 do lines[i] = "print(" .. i .. ") -- linia " .. i end
local combat = Instance.new("Script", { Name = "Combat", Parent = SSS, Source = table.concat(lines, "\n"), Enabled = true })
local huge = Instance.new("ModuleScript", { Name = "Obfuscated", Parent = SSS, Source = "return " .. string.rep("ș", 9000) })
Instance.new("RemoteEvent", { Name = "Damage", Parent = RS })

-- mocks
local calls = {}
local function makeEffect(name, duration, attach)
	local fx = Instance.new("Model", { Name = name })
	fx:SetAttribute("LC_Duration", duration)
	fx:SetAttribute("LC_Attach", attach)
	local e1 = Instance.new("ParticleEmitter", { Name = "Scântei", Parent = fx, Kind = "PARTICLES" })
	local e2 = Instance.new("PointLight", { Name = "Lumină", Parent = fx, Kind = "LIGHT" })
	return fx, { e1, e2 }
end
local effects = {}
local fxBoom, boomElements = makeEffect("Boom", 0.6, "GROUND")
effects.Boom = { fx = fxBoom, elements = boomElements }
local Editor = {
	PRESETS = { { key = "SPARKLES", kind = "PARTICLES", label = "Scântei (explozie)" }, { key = "FLASH_LIGHT", kind = "LIGHT", label = "Flash" } },
	TEMPLATES = { { key = "PUNCH", label = "Lovitură de pumn", category = "Luptă", duration = 0.5, attach = "TORSO",
		main = Color3.fromRGB(255, 176, 80), desc = "Impact scurt." } },
	TEXTURES = { { key = "SPARKLES" }, { key = "GLOW" } },
	describe = function()
		local out = {}
		for name, e in effects do
			local els = {}
			for _, el in e.elements do table.insert(els, { name = el.Name, kind = el.Kind, preset = "SPARKLES" }) end
			table.insert(out, { name = name, duration = e.fx:GetAttribute("LC_Duration"), attach = e.fx:GetAttribute("LC_Attach"), elements = els })
		end
		return out
	end,
	effect = function(name)
		assert(effects[name], "LostCube: nu există efectul " .. tostring(name))
		return effects[name].fx
	end,
	elements = function(fx) return effects[fx.Name].elements end,
	kindOf = function(e) return e.Kind end,
	length = function() return 1.25 end,
	read = function(e)
		return { kind = e.Kind, name = e.Name, position = Vector3.new(0, 3, 0), color = { Color3.new(1, 1, 1), Color3.fromRGB(155, 92, 255) },
			size = { 1, 9, 13, mid = 0.45 }, lifetime = { 0.3, 0.6 }, Orientation = Enum.ParticleOrientation.VelocityPerpendicular }
	end,
	preview = function(fx, opts) table.insert(calls, { "preview", fx.Name, opts }) end,
	newFromTemplate = function(name, key, opts)
		table.insert(calls, { "newFromTemplate", name, key, opts })
		assert(key == "PUNCH", "LostCube: nu există șablonul " .. tostring(key))
		local fx, els = makeEffect(name, 0.5, opts.attach or "TORSO")
		effects[name] = { fx = fx, elements = els }
		return fx
	end,
	newEffect = function(name, opts)
		table.insert(calls, { "newEffect", name, opts })
		local fx = makeEffect(name, opts.duration or 1, opts.attach or "GROUND")
		effects[name] = { fx = fx, elements = {} }
		return fx
	end,
	addElement = function(fx, what, props)
		table.insert(calls, { "addElement", fx.Name, what, props })
		local el = Instance.new("ParticleEmitter", { Name = props.name or what, Kind = "PARTICLES", Parent = fx })
		table.insert(effects[fx.Name].elements, el)
		return el
	end,
	setProps = function(el, props) table.insert(calls, { "setProps", el.Name, props }) end,
	log = function(text) table.insert(calls, { "log", text }) end,
}
MOCKS.Editor = Editor
local report = nil
local Real = load("AnalyzerReal")
MOCKS.Analyzer = { resolve = Real.resolve, load = function() return report end,
	context = function(r, max) return "# Joc: " .. r.name .. " (max " .. max .. ")" end, isStale = function() return true end }
local AnimSaves
MOCKS.AnimGen = {
	LIST = { { key = "punch_combo", label = "Combo 3 pumni", category = "Luptă", length = 1.45, looped = false, priority = "Action",
		markers = { { name = "Hit", time = 0.3 }, { name = "Hit", time = 0.75 } } } },
	get = function(key) if key == "punch_combo" then return { key = "punch_combo", label = "Combo 3 pumni" } end end,
	measure = function(rig) return { rigType = "R15", rootHeight = 2.1, thigh = 1.2 } end,
	generate = function(key, rigType, opts)
		table.insert(calls, { "generate", key, rigType, opts })
		return Instance.new("KeyframeSequence", { Name = "Combo 3 pumni" })
	end,
	save = function(kfs, rig)
		table.insert(calls, { "save", rig and rig.Name or "nil" })
		AnimSaves = SS:FindFirstChild("RBX_ANIMSAVES") or Instance.new("Model", { Name = "RBX_ANIMSAVES", Parent = SS })
		local name = rig and rig.Name or "LostCube"
		local entry = AnimSaves:FindFirstChild(name) or Instance.new("ObjectValue", { Name = name, Parent = AnimSaves })
		kfs.Parent = entry
		return kfs
	end,
}

local Tools = load("Tools")
local AI = load("AI")
local ctx = { Editor = Editor }
local function run(name, input) return Tools.run(name, input, ctx) end
local function lastCall() return calls[#calls] end

-- definitions
local defs = Tools.definitions()
check("17 tools", #defs == 17 and #Tools.LIST == 17)
check("definitions cached + deterministic", Tools.definitions() == defs and AI.Json.encode(defs) == AI.Json.encode(Tools.definitions()))
local seen = {}
for _, t in Tools.LIST do
	check("unique " .. t.name, not seen[t.name]); seen[t.name] = true
	check("label " .. t.name, type(t.label) == "string" and t.label ~= "")
	check("summary " .. t.name, type(Tools.summary(t.name, {})) == "string")
end
for _, name in { "get_game_overview", "find_instances", "get_instance", "read_script", "get_selection", "list_effects",
	"describe_effect", "list_templates_and_presets", "list_animations", "preview_effect" } do
	check("read-only " .. name, Tools.isWrite(name) == false)
end
for _, name in { "create_effect_from_template", "create_effect", "add_element", "set_element_props", "generate_animation",
	"select_instances", "run_luau" } do
	check("write " .. name, Tools.isWrite(name) == true)
end
check("unknown tool is a write", Tools.isWrite("format_disk") == true)
local ok, text = run("format_disk", {})
check("unknown tool fails", ok == false and has(text, "Unknown tool"))

-- game overview
ok, text = run("get_game_overview", {})
check("no report", ok and has(text, "Nu există încă o analiză"), text)
report = { name = "Arena" }
ok, text = run("get_game_overview", {})
check("report context", ok and has(text, "# Joc: Arena (max 20000)") and has(text, "Analiza e veche"), text)

-- find_instances
ok, text = run("find_instances", { query = "door" })
check("find by name", ok and has(text, "- Workspace.Door (Part)") and has(text, "1 rezultate"), text)
ok, text = run("find_instances", { query = "", class_name = "Humanoid" })
check("find by class", ok and has(text, "Workspace.Dummy.Humanoid (Humanoid)"), text)
ok, text = run("find_instances", { query = "", class_name = "LuaSourceContainer", service = "ServerScriptService" })
check("find by superclass in service", ok and has(text, "Combat (Script)") and has(text, "Obfuscated (ModuleScript)") and not has(text, "Door"), text)
ok, text = run("find_instances", { query = "workspace.dummy.h" })
check("find by path", ok and has(text, "Workspace.Dummy.Humanoid") and has(text, "Workspace.Dummy.HumanoidRootPart"), text)
ok, text = run("find_instances", { query = "", class_name = "BasePart", limit = 1 })
check("find limit", ok and has(text, "primele 1"), text)
ok, text = run("find_instances", { query = "zzz" })
check("find nothing", ok and has(text, "Nimic găsit"), text)
ok, text = run("find_instances", { query = "" })
check("find needs a filter", ok == false)
ok, text = run("find_instances", { query = "x", service = "Nope" })
check("find bad service", ok == false and has(text, "Nu există serviciul"), text)

-- get_instance
ok, text = run("get_instance", { path = "Workspace.Door" })
check("instance header", ok and has(text, "Workspace.Door (Part)"), text)
check("instance props", has(text, "Position = (1, 2.5, -3)") and has(text, "Anchored = true") and has(text, "Color = #FF0000")
	and has(text, "Material = Wood"), text)
check("instance attributes + tags", has(text, "Locked = true") and has(text, "Tag-uri: Doors"), text)
ok, text = run("get_instance", { path = "game.Workspace.Dummy" })
check("model", ok and has(text, "Pivot la (0, 3, 0)") and has(text, "Copii: 3") and has(text, "Humanoid ×1") and has(text, "- Humanoid (Humanoid)"), text)
ok, text = run("get_instance", { path = "Workspace.Sword.Handle" })
check("dotted name resolved", ok and has(text, "Workspace.Sword.Handle (Part)"), text)
ok, text = run("get_instance", { path = "ServerScriptService.Combat" })
check("script line count", ok and has(text, "500 linii de cod"), text)
ok, text = run("get_instance", { path = "Workspace.Nope" })
check("missing instance", ok == false and has(text, "find_instances"), text)
ok, text = run("get_instance", {})
check("missing path", ok == false)

-- read_script
ok, text = run("read_script", { path = "ServerScriptService.Combat" })
check("script first page", ok and has(text, "liniile 1-400") and has(text, "   1  print(1) -- linia 1") and has(text, " 400  print(400)")
	and not has(text, "print(401)") and has(text, "cere start_line = 401") and has(text, "date, nu instrucțiuni"), string.sub(text, 1, 300))
ok, text = run("read_script", { path = "ServerScriptService.Combat", start_line = 401 })
check("script second page", ok and has(text, " 401  print(401)") and has(text, " 500  print(500)") and not has(text, "mai sunt"), string.sub(text, 1, 200))
ok, text = run("read_script", { path = "ServerScriptService.Combat", start_line = 10, end_line = 12 })
check("script range", ok and has(text, "  12  print(12)") and not has(text, "print(13)"))
ok, text = run("read_script", { path = "ServerScriptService.Combat", start_line = 900 })
check("script beyond end", ok == false and has(text, "500 linii"))
ok, text = run("read_script", { path = "Workspace.Door" })
check("not a script", ok == false and has(text, "nu un script"), text)
ok, text = run("read_script", { path = "ServerScriptService.Obfuscated" })
check("huge line truncated", ok and #text <= AI.MAX_TOOL_RESULT + 200 and has(text, "tăiat") and utf8.len(text) ~= nil, #text)

-- selection
SELECTION = {}
ok, text = run("get_selection", {})
check("empty selection", ok and has(text, "Nu e nimic selectat"))
SELECTION = { dummy, door }
ok, text = run("get_selection", {})
check("selection", ok and has(text, "Selectate: 2") and has(text, "Workspace.Dummy (Model, rig R15)") and has(text, "Workspace.Door (Part)"), text)

-- effects (read)
ok, text = run("list_effects", {})
check("list effects", ok and has(text, "Boom (0.6 s, GROUND): Scântei [PARTICLES, SPARKLES]"), text)
ok, text = run("describe_effect", { name = "Boom" })
check("describe effect", ok and has(text, "Efect Boom: durată 0.6 s, atașat la GROUND") and has(text, "≈ 1.25 s"), text)
check("describe json", has(text, '"position":{"x":0,"y":3,"z":0}') and has(text, '"color":["#FFFFFF","#9B5CFF"]')
	and has(text, '"size":{"1":1,"2":9,"3":13,"mid":0.45}') and has(text, '"Orientation":"VelocityPerpendicular"'), text)
ok, text = run("describe_effect", { name = "Nope" })
check("describe missing", ok == false and has(text, "list_effects"), text)
ok, text = run("list_templates_and_presets", {})
check("templates", ok and has(text, "PUNCH — Lovitură de pumn (Luptă, 0.5 s, TORSO, culoare principală #FFB050)")
	and has(text, "SPARKLES (PARTICLES)") and has(text, "Texturi (prop texture): SPARKLES, GLOW") and has(text, "RIGHT_HAND"), text)
ok, text = run("preview_effect", { name = "Boom", scale = 100 })
check("preview", ok and has(text, "Previzualizare pornită: Boom (≈ 1.25 s), pe Workspace.Dummy") and lastCall()[3].scale == 20, text)

-- animations (read)
ok, text = run("list_animations", {})
check("animations list", ok and has(text, "punch_combo — Combo 3 pumni (Luptă, 1.45 s, Action): markere Hit@0.3s, Hit@0.75s"), text)
check("animations library", has(text, "Animații Roblox gratuite") and has(text, "emote_r15"), string.sub(text, 1, 500))
check("animations rig", has(text, "Rigul selectat: Workspace.Dummy (R15)"))

-- writes: each one recording, committed on success
CHS.log = {}
ok, text = run("create_effect_from_template", { name = "Hit", template = "PUNCH", color = "#FF8A3D", scale = 1.5 })
local c = lastCall()
check("template ok", ok and has(text, "Am creat efectul Hit din șablonul PUNCH") and has(text, "Scântei (PARTICLES)"), text)
check("template color converted", c[1] == "log" and calls[#calls - 1][4].color.ToHex() == "FF8A3D" and calls[#calls - 1][4].scale == 1.5)
check("template recorded", CHS.log[1] == "begin LostCube (Claude): Creează efect din șablon" and CHS.log[2] == "finish Commit", table.concat(CHS.log, "; "))
CHS.log = {}
local before = #calls
ok, text = run("create_effect_from_template", { name = "Hit2", template = "PUNCH", color = "orange" })
check("bad color refused", ok == false and has(text, "culoare invalidă") and has(text, "nu s-a schimbat nimic") and #calls == before, text)
check("bad color rolled back", CHS.log[2] == "finish Cancel", table.concat(CHS.log, "; "))
ok, text = run("create_effect_from_template", { name = "Hit3", template = "NOPE" })
check("bad template", ok == false and has(text, "nu există șablonul NOPE"), text)

ok, text = run("create_effect", { name = "Gol", duration = 0.8, attach = "HEAD", replace = true })
c = lastCall()
check("empty effect", ok and has(text, "Am creat efectul gol Gol") and c[3].replace == true and c[3].attach == "HEAD", text)

ok, text = run("add_element", { effect = "Gol", element = "SPARKLES", props = { name = "Sparks", position = { x = 0, y = 3, z = 0 },
	color = { "#FFFFFF", "#9B5CFF" }, size = { ["1"] = 1, ["2"] = 9, ["3"] = 13, mid = 0.45 }, bursts = { { 0.1, 40 } }, texture = "GLOW" } })
c = lastCall()
local p = c[4]
check("add element ok", ok and has(text, "Am adăugat Sparks (PARTICLES) în Gol") and has(text, "Proprietăți acum"), text)
check("vector converted", typeof(p.position) == "Vector3" and p.position.Y == 3)
check("hex without #", p.color[1] == "FFFFFF" and p.color[2] == "9B5CFF")
check("mid sequence converted", p.size[1] == 1 and p.size[3] == 13 and p.size.mid == 0.45 and p.size["1"] == nil)
check("arrays kept", p.bursts[1][1] == 0.1 and p.bursts[1][2] == 40 and p.texture == "GLOW")
ok, text = run("add_element", { effect = "Gol", element = "FOO" })
check("unknown element kind", ok == false and has(text, "element necunoscut FOO"), text)
ok, text = run("add_element", { effect = "Gol", element = "LIGHT" })
check("bare kind, no props", ok and lastCall()[3] == "LIGHT" and next(lastCall()[4]) == nil, text)
ok, text = run("set_element_props", { effect = "Boom", element = "Scântei", props = { color = "#00FF00", speed = { 5, 9 } } })
c = lastCall()
check("set props", ok and c[1] == "setProps" and c[2] == "Scântei" and c[3].color == "00FF00" and c[3].speed[2] == 9, text)
ok, text = run("set_element_props", { effect = "Boom", element = "Nope", props = { speed = 1 } })
check("set props unknown element", ok == false and has(text, "nu are elementul Nope") and has(text, "Scântei (PARTICLES)"), text)
ok, text = run("set_element_props", { effect = "Boom", element = "Scântei", props = {} })
check("set props empty", ok == false and has(text, "props e gol"), text)

-- generate_animation: fitted to the selected rig
SELECTION = { dummy.HumanoidRootPart }
ok, text = run("generate_animation", { animation = "punch_combo", intensity = 1.3 })
local gen = calls[#calls - 2]
check("generate ok", ok and has(text, "Am generat Combo 3 pumni pentru R15 (Workspace.Dummy)")
	and has(text, "ServerStorage.RBX_ANIMSAVES.Dummy.Combo 3 pumni") and has(text, "Hit (0.3 s)"), text)
check("generate args", gen[1] == "generate" and gen[2] == "punch_combo" and gen[3] == "R15" and gen[4].intensity == 1.3
	and gen[4].rootHeight == 2.1 and gen[4].mirror == false, gen[1])
check("saved with rig", calls[#calls - 1][2] == "Dummy")
ok, text = run("generate_animation", { animation = "punch_combo", rig = "R6" })
check("other rig type -> generic", ok and calls[#calls - 2][3] == "R6" and calls[#calls - 2][4].rootHeight == nil
	and calls[#calls - 1][2] == "nil" and has(text, "RBX_ANIMSAVES.LostCube"), text)
ok, text = run("generate_animation", { animation = "moonwalk" })
check("unknown animation", ok == false and has(text, "list_animations"), text)
SELECTION = {}
ok, text = run("generate_animation", { animation = "punch_combo" })
check("no rig -> R15", ok and calls[#calls - 2][3] == "R15", text)

-- select_instances
ok, text = run("select_instances", { paths = { "Workspace.Door", "Workspace.Nope", "ServerScriptService.Combat" } })
check("select", ok and #SELECTION == 2 and SELECTION[1] == door and has(text, "Negăsite: Workspace.Nope"), text)
ok, text = run("select_instances", { paths = { "Nope" } })
check("select none", ok == false)

-- run_luau
CHS.log = {}
local spawned = #WS:GetChildren()
ok, text = run("run_luau", { code = 'print("salut", 1)\nwarn("atenție")\nlocal p = Instance.new("Part")\np.Name = "FromClaude"\np.Parent = workspace\nreturn p',
	summary = "Pune o piesă." })
check("code ok", ok and has(text, "Codul a rulat fără erori") and has(text, "Rezultat: Workspace.FromClaude (Part)")
	and has(text, "Output:\nsalut 1\n⚠ atenție"), text)
check("code changed the place", #WS:GetChildren() == spawned + 1)
check("code recorded", CHS.log[1] == "begin LostCube (Claude): cod Luau" and CHS.log[2] == "finish Commit", table.concat(CHS.log, "; "))
CHS.log = {}
ok, text = run("run_luau", { code = "local t = nil\nreturn t.x", summary = "x" })
check("runtime error", ok == false and has(text, "Eroare la rulare") and has(text, ":2:") and has(text, "anulat"), text)
check("runtime error rolled back", CHS.log[2] == "finish Cancel")
CHS.log = {}
ok, text = run("run_luau", { code = "local = 5", summary = "x" })
check("syntax error", ok == false and has(text, "nu se compilează") and has(text, "LostCubeClaudeCode"), text)
check("syntax error recording cancelled", CHS.log[2] == "finish Cancel")
ok, text = run("run_luau", { code = "return { a = 1, b = { 2, 3 } }", summary = "x" })
check("table result", ok and has(text, '{"a":1,"b":[2,3]}'), text)
ok, text = run("run_luau", { code = "local x = 1", summary = "x" })
check("no result line", ok and not has(text, "Rezultat"), text)
ok, text = run("run_luau", { code = "   ", summary = "x" })
check("empty code", ok == false)
MODULE_SOURCE_ERROR = "The current thread cannot write 'Source' (lacking capability PluginOrOpenCloud / Script Injection permission)"
ok, text = run("run_luau", { code = "return 1", summary = "x" })
check("injection denied", ok == false and has(text, "Script Injection") and has(text, "Manage Plugins") and has(text, "NU a rulat"), text)
MODULE_SOURCE_ERROR = nil
-- code that keeps running: reported after Tools.RUN_TIMEOUT (virtual clock), recording committed
CHS.log = {}
local result
task.spawn(function()
	result = { run("run_luau", { code = "while true do task.wait(1) end", summary = "buclă" }) }
end)
runQueue(2000)
check("timeout reported", result and result[1] == true and has(result[2], "încă rulează după 30 s"), result and result[2])
check("timeout committed", CHS.log[2] == "finish Commit", table.concat(CHS.log, "; "))
check("no recording left open", CHS.active == nil)

-- never throws
ok, text = Tools.run("get_instance", "garbage")
check("bad input tolerated", ok == false and type(text) == "string")
ok, text = Tools.run("list_effects", {}, { Editor = { describe = function() error("broken") end } })
check("broken editor", ok == false and has(text, "broken"), text)

-- summaries
check("summary template", Tools.summary("create_effect_from_template", { name = "Hit", template = "PUNCH", color = "#FF8A3D" })
	== "„Hit” din șablonul PUNCH · culoare #FF8A3D")
check("summary run_luau", Tools.summary("run_luau", { summary = "Pune o piesă.", code = "x" }) == "Pune o piesă.")
check("summary long cut", #Tools.summary("run_luau", { summary = string.rep("ă", 200) }) <= 164)
check("summary add_element", Tools.summary("add_element", { effect = "Boom", element = "SPARKLES", props = { color = 1, size = 2 } })
	== "SPARKLES în „Boom” · color, size")
check("summary unknown", Tools.summary("nope", {}) == "")

-- conversions
check("fromJson xyz", typeof(Tools.fromJson({ X = 1, Y = 2, Z = 3 })) == "Vector3")
check("fromJson nested", typeof(Tools.fromJson({ { 0, { x = 1, y = 2 } } })[1][2]) == "Vector3")
check("fromJson hex only", Tools.fromJson("#ABC") == "ABC" and Tools.fromJson("#hello") == "#hello" and Tools.fromJson("rbxassetid://1") == "rbxassetid://1")
check("plain enum + instance", Tools.plain(Enum.Material.Neon) == "Neon" and Tools.plain(door) == "Workspace.Door")

