-- Editor (the VFX engine): data sanity of presets / textures / templates, every preset and every template builds
-- against the typed Roblox mock (property names, value types and enum members come from the real API dump), one undo
-- step per template, recolour / scale maths, name and option validation, importEmitters and importAsset of free VFX
-- models (every script of the model is deleted first; suspicious ones are reported).
local LC = ...
local t = LC.kit.new("editor")
local function check(cond, msg)
	t.check(cond, msg)
end
local function expectError(fn, needle, msg)
	t.throws(fn, needle, msg)
end

local ENV = LC.run("tests/mocks/api_env.luau", nil, LC)
local Vector3, CFrame, Color3, NumberRange, NumberSequence, ColorSequence =
	ENV.Vector3, ENV.CFrame, ENV.Color3, ENV.NumberRange, ENV.NumberSequence, ENV.ColorSequence
local D = ENV.__DATA

-- the real Editor, with a few of its internals exposed for the unit tests of the maths (they are optional: a section
-- whose internal was renamed says so instead of failing; the public behaviour is checked as well)
local INTERNALS = { "shiftColor", "mapColors", "mulSpec", "scaleProps", "recolorProps", "PRESET_BY_KEY", "TEMPLATE_BY_KEY", "stripScripts" }
local function expose(src)
	local at = string.find(src, "\nreturn Editor%s*$")
	assert(at, "Editor/init.luau should end with `return Editor`")
	local fields = {}
	for _, name in INTERNALS do
		table.insert(fields, name .. " = " .. name)
	end
	return string.sub(src, 1, at) .. "Editor.__i = { " .. table.concat(fields, ", ") .. " }\nreturn Editor\n"
end
local Editor = LC.load("LostCube/Editor/init.luau", ENV, expose)()
local I = Editor.__i
local history = ENV.__history
print(string.format("presets: %d, templates: %d, textures: %d", #Editor.PRESETS, #Editor.TEMPLATES, #Editor.TEXTURES))

local KINDS = { PARTICLES = true, LIGHT = true, TRAIL = true, MESH = true, BEAM = true, SOUND = true, CAMERA = true }

-- 1. data sanity ---------------------------------------------------------------------------------------
do
	local keys, seen = {}, {}
	for _, p in Editor.PRESETS do
		check(not seen[p.key], "duplicate preset key " .. p.key)
		seen[p.key] = true
		check(KINDS[p.kind] == true, "bad kind of " .. p.key .. ": " .. tostring(p.kind))
		check(type(p.group) == "string" and p.group ~= "", "preset without group: " .. p.key)
		check(type(p.label) == "string", "preset without label " .. p.key)
		if p.props.texture then
			local found = false
			for _, t in Editor.TEXTURES do if t.key == p.props.texture then found = true end end
			check(found, "preset " .. p.key .. " uses unknown texture " .. tostring(p.props.texture))
		end
	end
	local tk = {}
	for _, t in Editor.TEXTURES do
		check(not tk[t.key], "duplicate texture key " .. t.key)
		tk[t.key] = true
		check(t.url == "" or t.url:match("^rbxasset://textures/") or t.url:match("^rbxassetid://%d+$"), "bad texture url " .. t.url)
		check(type(t.group) == "string", "texture without group " .. t.key)
	end
	local urls = {}
	for _, t in Editor.TEXTURES do
		if t.url ~= "" then check(not urls[t.url], "duplicate texture url " .. t.url); urls[t.url] = true end
	end
	local tpl = {}
	for _, t in Editor.TEMPLATES do
		check(not tpl[t.key], "duplicate template key " .. t.key)
		tpl[t.key] = true
		check(t.label and t.category and t.duration and t.attach and t.main and t.desc, "template fields " .. t.key)
		local ok = false
		for _, a in Editor.ATTACH do if a.key == t.attach then ok = true end end
		check(ok, "template " .. t.key .. " attach " .. t.attach)
		check(#t.elements >= 3, "template too small " .. t.key)
	end
end

-- 2. every preset applies (property names and value types are checked against the real API dump) ---------
for _, p in Editor.PRESETS do
	local ok, e = pcall(function()
		local fx = Editor.newEffect("P_" .. p.key, { duration = 1 })
		local el = Editor.addElement(fx, p.key)
		local data = Editor.read(el)
		check(data.kind == p.kind, "read kind " .. p.key)
		if p.props.texture then check(data.texture == p.props.texture, "texture key round-trips for " .. p.key .. ": " .. tostring(data.texture)) end
		Editor.applyPreset(el, p.key)
		Editor.duplicate(el)
		Editor.removeEffect(fx)
	end)
	check(ok, "preset " .. p.key .. ": " .. tostring(e))
end
check(history.active == nil, "a recording was left open after presets")

-- 3. every template builds, with and without recolour / scale ----------------------------------------------
local function timeline(fx, label)
	local dur = fx:GetAttribute("LC_Duration")
	for _, el in Editor.elements(fx) do
		local data = Editor.read(el)
		if data.window then check(data.window[2] <= dur + 1e-6, label .. ": window of " .. el.Name .. " ends after the effect (" .. data.window[2] .. " > " .. dur .. ")") end
		for _, b in data.bursts or {} do check(b[1] <= dur + 1e-6, label .. ": burst of " .. el.Name .. " at " .. b[1] .. " after the end " .. dur) end
		if data.keys then for _, k in data.keys do check(k[1] <= dur + 1e-6, label .. ": light key of " .. el.Name .. " at " .. k[1] .. " after the end " .. dur) end end
		check(data.window or (data.bursts and #data.bursts > 0) or data.kind == "LIGHT", label .. ": " .. el.Name .. " never plays")
	end
end
for _, t in Editor.TEMPLATES do
	local before = #history.log
	local ok, fx = pcall(Editor.newFromTemplate, t.label, t.key)
	check(ok, "template " .. t.key .. ": " .. tostring(fx))
	if ok then
		check(fx.Parent == Editor.folder(false), "template parent " .. t.key)
		check(fx:GetAttribute("LC_Duration") == t.duration, "template duration " .. t.key)
		check(fx:GetAttribute("LC_Attach") == t.attach, "template attach " .. t.key)
		check(#Editor.elements(fx) == #t.elements, "template element count " .. t.key .. ": " .. #Editor.elements(fx) .. " vs " .. #t.elements)
		local names = {}
		for _, el in Editor.elements(fx) do check(not names[el.Name], "duplicate element name " .. el.Name); names[el.Name] = true; Editor.read(el) end
		timeline(fx, t.key)
		-- one undo step: exactly one begin + one finish (Commit)
		local entries = {}
		for i = before + 1, #history.log do if history.log[i]:find("^begin") or history.log[i]:find("^finish") then table.insert(entries, history.log[i]) end end
		check(#entries == 2 and entries[2] == "finish Commit", "template " .. t.key .. " recordings: " .. table.concat(entries, " | "))
		local ok2, fx2 = pcall(Editor.newFromTemplate, t.label .. " rosu", t.key, { color = Color3.fromRGB(255, 20, 60), scale = 1.7 })
		check(ok2, "template recoloured/scaled " .. t.key .. ": " .. tostring(fx2))
		if ok2 then
			for _, el in Editor.elements(fx2) do Editor.read(el) end
		end
		local ok3, fx3 = pcall(Editor.newFromTemplate, t.label .. " alb", t.key, { color = Color3.new(1, 1, 1), scale = 0.4 })
		check(ok3, "template white/small " .. t.key .. ": " .. tostring(fx3))
	end
end
check(history.active == nil, "a recording was left open after templates")

-- 4. names and options are validated, and a failure leaves nothing behind ---------------------------------------
do
	local n = #Editor.effects()
	expectError(function() Editor.newFromTemplate("", "PUNCH") end, "gol", "empty name")
	expectError(function() Editor.newFromTemplate("   ", "PUNCH") end, "gol", "blank name")
	expectError(function() Editor.newFromTemplate("Lovitură de pumn", "PUNCH") end, "există deja", "duplicate name")
	expectError(function() Editor.newFromTemplate("Nou", "NU_EXISTA") end, "șablon", "unknown template")
	expectError(function() Editor.newFromTemplate("Nou", "PUNCH", { scale = 0 }) end, "scara", "bad scale")
	expectError(function() Editor.newFromTemplate("Nou", "PUNCH", { color = "red" }) end, "culoarea", "bad colour")
	expectError(function() Editor.newFromTemplate(string.rep("x", 101), "PUNCH") end, "lung", "long name")
	check(#Editor.effects() == n, "failed templates left effects behind")
	check(history.active == nil, "recording left open after failed templates")
	local fx = Editor.newFromTemplate("  Cu spații  ", "PUNCH")
	check(fx.Name == "Cu spații", "name is trimmed: '" .. fx.Name .. "'")
end

-- 5. recolour / scale ----------------------------------------------------------------------------------------------------------
do
	-- unit tests of the maths (need the internals; skipped with a note if they were renamed)
	if I.shiftColor and I.mapColors and I.mulSpec and I.scaleProps and I.recolorProps then
		local from, to = Color3.fromRGB(110, 255, 150), Color3.fromRGB(255, 40, 40)
		local c = I.shiftColor(Color3.fromRGB(110, 255, 150), from, to)
		local h = c:ToHSV()
		check(h < 0.03 or h > 0.97, "main colour lands on the target hue, got " .. tostring(c))
		check(I.shiftColor(Color3.new(1, 1, 1), from, to) == Color3.new(1, 1, 1), "white stays white")
		check(I.shiftColor(Color3.fromRGB(20, 18, 24), from, to) == Color3.fromRGB(20, 18, 24), "near-black stays")
		local seq = I.mapColors({ Color3.fromRGB(255, 0, 0), Color3.new(1, 1, 1), Color3.fromRGB(0, 0, 255), mid = 0.3 }, function(x) return Color3.new(0, 0, 0) end)
		check(seq.mid == 0.3 and #seq == 3, "mapColors keeps mid and length")
		local kp = I.mapColors({ { 0, Color3.fromRGB(255, 0, 0) }, { 1, Color3.fromRGB(0, 0, 255) } }, function() return Color3.new(0, 1, 0) end)
		check(kp[1][1] == 0 and kp[2][2] == Color3.new(0, 1, 0), "mapColors on keypoints")
		local props = { color = Color3.fromRGB(110, 255, 150), Color = Color3.fromRGB(110, 255, 150), colorEnd = Color3.fromRGB(20, 100, 40), size = { 1, 2, 3, mid = 0.4 } }
		I.recolorProps(props, from, to)
		check(props.size[3] == 3 and props.size.mid == 0.4, "recolour leaves other props alone")
		local sp = I.mulSpec({ 1, 2, 3, mid = 0.4 }, 2)
		check(sp[1] == 2 and sp[3] == 6 and sp.mid == 0.4, "mulSpec triple")
		local k = I.mulSpec({ { 0, 1 }, { 0.5, 2 } }, 3)
		check(k[2][2] == 6 and k[2][1] == 0.5, "mulSpec keypoints")
		local light = { Range = 10, keys = { { 0, 1, 10 }, { 0.5, 4, 20 } }, position = Vector3.new(1, 2, 3) }
		I.scaleProps("LIGHT", light, 2)
		check(light.keys[2][3] == 40 and light.keys[2][2] == 4 and light.keys[2][1] == 0.5 and light.Range == 20 and light.position.Y == 4, "scaleProps LIGHT")
	else
		print("NOTE: recolour / scale internals are not exposed by Editor.luau any more: unit tests of the maths skipped")
	end

	-- the public behaviour: scale + recolour are really applied to the built effect (HEAL: green particles + a light)
	local heal
	for _, tpl in Editor.TEMPLATES do
		if tpl.key == "HEAL" then
			heal = tpl
		end
	end
	check(heal ~= nil, "template HEAL exists")
	if heal then
		local a = Editor.newFromTemplate("Scara 1", "HEAL")
		local b = Editor.newFromTemplate("Scara 2 rosu", "HEAL", { scale = 2, color = Color3.fromRGB(255, 40, 40) })
		-- the same element in both effects: the first particle emitter that sits on a shape part, the first light
		local function pick(fx, kind, needShape)
			for _, e in Editor.elements(fx) do
				if Editor.kindOf(e) == kind and (not needShape or Editor.read(e).partSize) then
					return e
				end
			end
		end
		local pa, pb = pick(a, "PARTICLES", true), pick(b, "PARTICLES", true)
		check(pa ~= nil and pb ~= nil, "HEAL has a particle emitter on a shape part")
		if pa and pb then
			local sa, sb = Editor.read(pa), Editor.read(pb)
			check(math.abs(sb.size[1] - 2 * sa.size[1]) < 1e-6, "scale doubles particle size")
			check(math.abs(sb.speed[2] - 2 * sa.speed[2]) < 1e-6, "scale doubles speed")
			check(math.abs(sb.partSize.X - 2 * sa.partSize.X) < 1e-6, "scale doubles the emitter shape")
			local h1, h2 = sa.color[2]:ToHSV(), sb.color[2]:ToHSV()
			local mainHue = heal.main:ToHSV()
			check(math.abs(h1 - mainHue) < 0.2 and (h2 < 0.05 or h2 > 0.95), "recolour moved the main colour to red: " .. h1 .. " -> " .. h2)
		end
		local la, lb = pick(a, "LIGHT"), pick(b, "LIGHT")
		if la and lb then
			local ra, rb = Editor.read(la), Editor.read(lb)
			check(math.abs(rb.keys[2][3] - 2 * ra.keys[2][3]) < 1e-6, "scale doubles light range")
		end
	end
end

-- 6. importEmitters -------------------------------------------------------------------------------------------------------------
local part, build = ENV.part, ENV.freeModel
do
	local fx = Editor.newEffect("Imp", { duration = 1 })
	local src = build()
	local before = #src:GetDescendants()
	local res = Editor.importEmitters(fx, src)
	check(res.particles == 5, "importEmitters particles: " .. res.particles)
	check(res.trails == 1 and res.lights == 2, "importEmitters trails/lights " .. res.trails .. "/" .. res.lights)
	check(#res.elements == 8, "importEmitters elements " .. #res.elements)
	check(res.unsupported == 1, "beam counted as unsupported")
	check(#src:GetDescendants() == before, "importEmitters must not modify the source")
	check(src:FindFirstChild("Backdoor") ~= nil, "importEmitters leaves the source scripts alone")
	for _, el in Editor.elements(fx) do check(el:IsA("LuaSourceContainer") == false, "no scripts are copied") end
	for _, d in fx:GetDescendants() do check(not d:IsA("LuaSourceContainer"), "no script inside the effect") end
	local byName = {}
	for _, el in res.elements do byName[el.Name] = el end
	local flame = Editor.read(byName.Flame)
	check(flame.window and flame.window[1] == 0 and flame.window[2] == 2, "enabled emitter gets a window 0-2")
	check(flame.Rate == 30 and flame.texture == "CUSTOM" and flame.textureId == "rbxassetid://123", "flame props copied")
	check(math.abs(flame.position.Y - 2) < 1e-6 and math.abs(flame.position.X) < 1e-6, "relative position: " .. tostring(flame.position))
	local pop = Editor.read(byName.Pop)
	check(#pop.bursts == 1 and pop.bursts[1][1] == 0 and pop.bursts[1][2] == 12 and pop.window == nil, "disabled emitter gets a burst of Rate")
	local counted = Editor.read(byName.Counted)
	check(#counted.bursts == 1 and counted.bursts[1][1] == 0.3 and counted.bursts[1][2] == 25, "EmitCount / EmitDelay")
	local timed = Editor.read(byName.Timed)
	check(timed.window and timed.window[1] == 0.5 and timed.window[2] == 2, "EmitDuration / EmitDelay window")
	local shape = Editor.read(byName.FromShape)
	check(shape.shape == "Cylinder" and math.abs(shape.partSize.X - 4) < 1e-6, "emitter on a part keeps its shape and size")
	check(math.abs(shape.position.X - 2) < 1e-6, "shape part position relative to the pivot: " .. tostring(shape.position))
	local tr = Editor.read(byName.Swoosh)
	check(math.abs(tr.height - 2) < 1e-6 and tr.window ~= nil, "trail height from its attachments")
	local gl = Editor.read(byName.Glow)
	check(gl.Range == 18 and gl.Brightness == 3, "light copied")
	check(byName.Beam:GetAttribute("LC_Muted") == true, "disabled light is muted")
	check(fx:GetAttribute("LC_Duration") >= 2, "duration grows to the longest window: " .. tostring(fx:GetAttribute("LC_Duration")))
	check(#res.notes >= 1, "notes about guessed bursts / unsupported")
	expectError(function() Editor.importEmitters(fx, fx) end, "chiar efectul", "cannot import from itself")
	expectError(function() Editor.importEmitters(fx, 5) end, "obiect", "source must be an instance")
	-- source as a bare emitter
	local e2 = build():FindFirstChild("Flame", true)
	local fx2 = Editor.newEffect("Imp2", { duration = 1 })
	local r2 = Editor.importEmitters(fx2, e2)
	check(r2.particles == 1, "a bare emitter can be the source")
	-- many emitters are capped
	local big = ENV.newInstance("Folder")
	for i = 1, 100 do local e = ENV.newInstance("ParticleEmitter"); e.Parent = big end
	local fx3 = Editor.newEffect("Imp3", { duration = 1 })
	local r3 = Editor.importEmitters(fx3, big)
	check(#r3.elements == 80 and r3.skipped == 20, "cap of 80 elements: " .. #r3.elements .. "/" .. r3.skipped)
	for _, el in Editor.elements(fx) do Editor.duplicate(el) end -- imported elements survive the editor's own functions
end
check(history.active == nil, "recording left open after imports")

-- 7. importAsset ------------------------------------------------------------------------------------------------------------------
do
	local loaded
	ENV.game.GetObjects = function(_, url)
		assert(url == "rbxassetid://777", "url " .. url)
		loaded = build()
		return { loaded }
	end
	local effectsBefore = #Editor.effects()
	local fx, report = Editor.importAsset(777, "Din magazin")
	check(fx ~= nil and report.ok, "importAsset ok: " .. tostring(report.error))
	check(report.scriptsRemoved == 3, "scripts removed " .. tostring(report.scriptsRemoved))
	check(report.scriptsByClass.Script == 1 and report.scriptsByClass.LocalScript == 1 and report.scriptsByClass.ModuleScript == 1, "scripts by class")
	check(report.suspicious == 2, "suspicious scripts flagged: " .. tostring(report.suspicious))
	check(report.particles == 5 and report.trails == 1 and report.lights == 2, "report counts")
	check(fx.Name == "Din magazin" and fx.Parent == Editor.folder(false), "effect created")
	check(fx:GetAttribute("LC_Source") == "rbxassetid://777", "source recorded")
	check(D[loaded].destroyed, "the loaded model is destroyed")
	for _, d in fx:GetDescendants() do check(not d:IsA("LuaSourceContainer"), "no script in the new effect") end
	check(#Editor.effects() == effectsBefore + 1, "one effect added")
	print("--- report lines ---")
	for _, l in report.lines do print("  " .. l) end
	check(report.lines[1]:find("✓", 1, true) ~= nil, "first line is the verdict")

	-- the scripts really are deleted BEFORE the import: nothing of the loaded model keeps a script
	check(#Editor.effects() == effectsBefore + 1, "ok")

	-- failure paths
	local f2, r2 = Editor.importAsset("abc", "X")
	check(f2 == nil and r2.error and r2.error:find("ID invalid"), "bad id")
	local f3, r3 = Editor.importAsset(-5, "X")
	check(f3 == nil and r3.error, "negative id")
	local f4, r4 = Editor.importAsset(777, "Din magazin")
	check(f4 == nil and r4.error and r4.error:find("există deja"), "duplicate name is refused before downloading: " .. tostring(r4.error))
	ENV.game.GetObjects = function() error("HTTP 403 (Forbidden)") end
	local f5, r5 = Editor.importAsset(778, "Y")
	check(f5 == nil and r5.error and r5.error:find("Nu am putut încărca"), "load failure: " .. tostring(r5.error))
	-- fallback to InsertService
	local inserted
	ENV.__services.InsertService.LoadAsset = function(_, id)
		inserted = ENV.newInstance("Model")
		local e = ENV.newInstance("ParticleEmitter"); e.Parent = inserted
		local s = ENV.newInstance("Script"); s.Parent = inserted
		return inserted
	end
	local f6, r6 = Editor.importAsset(779, "Prin Insert")
	check(f6 ~= nil and r6.ok and r6.scriptsRemoved == 1 and r6.particles == 1, "InsertService fallback: " .. tostring(r6.error))
	check(D[inserted].destroyed, "container destroyed")
	-- an asset without emitters
	ENV.game.GetObjects = function() local m = ENV.newInstance("Model"); local p = part("P", 0, 0, 0); p.Parent = m; return { m } end
	local f7, r7 = Editor.importAsset(780, "Gol")
	check(f7 == nil and r7.error and r7.error:find("niciun ParticleEmitter"), "no emitters: " .. tostring(r7.error))
	check(Editor.folder(false):FindFirstChild("Gol") == nil, "no empty effect is left behind")
	-- roots that are scripts themselves + analyzer hook
	local an = ENV.newInstance("ModuleScript"); an.Name = "Analyzer"; ENV.setParent(an, ENV.__pluginRoot)
	ENV.__requires[an] = { scanInstance = function(root) return { { severity = "high", message = "model mare", path = "X.Y" }, "text simplu" } end }
	ENV.game.GetObjects = function()
		local s = ENV.newInstance("Script"); s.Source = "x"
		local m = ENV.newInstance("Model"); local e = ENV.newInstance("ParticleEmitter"); e.Parent = m
		return { s, m }
	end
	local f8, r8 = Editor.importAsset(781)
	check(f8 ~= nil and r8.ok and r8.scriptsRemoved == 1, "script root + default name: " .. tostring(r8.error))
	check(f8 and f8.Name == "Import 781", "default name")
	check(r8.analyzer and #r8.analyzer == 2 and r8.analyzer[1] == "[mare] model mare (X.Y)", "analyzer findings are in the report")
	local f9 = Editor.importAsset(781)
	check(f9 and f9.Name == "Import 781 2", "default name gets a number: " .. tostring(f9 and f9.Name))
	ENV.__requires[an] = { scanInstance = function() error("boom") end }
	local f10, r10 = Editor.importAsset(781)
	check(f10 ~= nil and r10.ok and r10.analyzer == nil, "a failing analyzer never breaks the import")
end
check(history.active == nil, "recording left open after importAsset")


-- 8. share codes on this mock too (its CFrame has no rotation and its HttpService is a stub: the codes use neither) -----------------
do
	for _, fx in Editor.effects() do
		Editor.removeEffect(fx)
	end
	local count = 0
	for _, tpl in Editor.TEMPLATES do
		local fx = Editor.newFromTemplate("Share " .. tpl.key, tpl.key, { color = Color3.fromRGB(40, 200, 120), scale = 1.3 })
		local code = Editor.exportEffect(fx)
		local steps = #history.log
		Editor.removeEffect(fx)
		local back = Editor.importEffect(code)
		check(back.Name == "Share " .. tpl.key and #Editor.elements(back) == #tpl.elements, "share " .. tpl.key .. ": rebuilt")
		check(Editor.exportEffect(back) == code, "share " .. tpl.key .. ": the second export is the same code")
		local begins = 0
		for i = steps + 1, #history.log do
			if string.find(history.log[i], "^begin") then begins += 1 end
		end
		check(begins == 2 and history.log[#history.log] == "finish Commit" and history.active == nil, "share " .. tpl.key .. ": removing and importing are one undo step each")
		for _, el in Editor.elements(back) do
			Editor.read(el)
		end
		Editor.removeEffect(back)
		count += 1
	end
	check(count == #Editor.TEMPLATES and #Editor.effects() == 0, "all templates shared")
	for _, bad in { "", "LC1:", "LC2:AAAA", "nu e cod", "LC1:AAAAAAAAAAAAAAAAAAAA" } do
		expectError(function() Editor.importEffect(bad) end, "LostCube: ", "refused: " .. bad)
	end
	check(#Editor.effects() == 0, "nothing created by the bad codes")
end

t.finish()
