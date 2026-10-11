-- Share codes (Editor.exportEffect / importEffect / exportAll / importMany / describeCode), the palette tools (recolorEffect,
-- suggestColors, matchPalette, paletteOf), scaleEffect and makeVariants of Editor/init.luau, against the real VFX player on the
-- typed Roblox mock: every preset and template survives export -> import -> export byte for byte, and the rebuilt effect has the
-- same instances, properties, attributes and compiled timeline; malformed / hostile / oversized codes are refused without
-- creating anything; recolouring keeps whites and greys; suggestions stay away from the colours of the map.
local LC = ...
local t = LC.kit.new("share")
local ENV = LC.run("tests/mocks/vfx_env.luau", nil, LC)
local M = ENV.__M
local API = LC.run("tests/data/api_subset.luau")
local Vector3, CFrame, Color3, NumberRange, NumberSequence, ColorSequence, Instance, typeof =
	ENV.Vector3, ENV.CFrame, ENV.Color3, ENV.NumberRange, ENV.NumberSequence, ENV.ColorSequence, ENV.Instance, ENV.typeof
local NumberSequenceKeypoint, ColorSequenceKeypoint = ENV.NumberSequenceKeypoint, ENV.ColorSequenceKeypoint
local function check(cond, msg)
	return t.check(cond, msg)
end

-- loading: the real player (its compiler exposed) and the real Editor ---------------------------------------------------------
local REQ = {}
ENV.require = function(m)
	local r = REQ[m]
	assert(r ~= nil, "require: unknown module " .. tostring(m))
	return r
end
M.flags.studio, M.flags.running, M.flags.client = true, false, true
local pluginRoot = Instance.new("Folder")
local function inst(class, name, parent)
	local o = Instance.new(class)
	o.Name = name
	if parent then
		o.Parent = parent
	end
	return o
end
local editorScript = inst("ModuleScript", "Editor", pluginRoot)
local vfxScript = inst("ModuleScript", "VFX", editorScript)
local vfxSource = LC.files["LostCube/Editor/VFX.luau"]
local atEnd = string.find(vfxSource, "\nreturn VFX%s*$")
assert(atEnd, "Editor/VFX.luau should end with `return VFX`")
local VFX = M.load(string.sub(vfxSource, 1, atEnd) .. "VFX.__compile = compile\nreturn VFX\n", "VFX", vfxScript)
REQ[vfxScript] = VFX

-- The mock's CFrame has no ToOrientation / fromOrientation (Euler angles, Y-X-Z order): the test supplies them, so the path
-- that writes and reads the orientation of an Attachment is exercised too. Both are the textbook formulas.
local Angles = CFrame.Angles
CFrame.fromOrientation = function(rx, ry, rz)
	return Angles(0, ry, 0) * Angles(rx, 0, 0) * Angles(0, 0, rz)
end
ENV.TEST_TO_ORIENTATION = function(cf)
	local look, right, up = cf.LookVector, cf.RightVector, cf.UpVector
	return math.asin(math.clamp(look.Y, -1, 1)), math.atan2(-look.X, -look.Z), math.atan2(right.Y, up.Y)
end
local editorSource = LC.files["LostCube/Editor/init.luau"]
local patched, replaced = string.gsub(editorSource, "return cf:ToOrientation%(%)", "return TEST_TO_ORIENTATION(cf)")
local orientationTested = replaced == 1
if not orientationTested then
	print("NOTE: Editor.luau no longer calls cf:ToOrientation(): the orientation tests are skipped")
	patched = editorSource
end
local Editor = M.load(patched, "Editor", editorScript)
REQ[editorScript] = Editor
local history = M.history
print(string.format("presets: %d, templates: %d", #Editor.PRESETS, #Editor.TEMPLATES))

-- helpers --------------------------------------------------------------------------------------------------------------------------
local fmt
local function fmtTable(v)
	local keys = {}
	for k in v do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local out = {}
	for _, k in keys do
		table.insert(out, tostring(k) .. "=" .. fmt(v[k]))
	end
	return "{" .. table.concat(out, ",") .. "}"
end
fmt = function(v)
	local kind = typeof(v)
	if kind == "number" then
		return string.format("%.5g", v)
	elseif kind == "string" or kind == "boolean" or kind == "nil" then
		return tostring(v)
	elseif kind == "Vector3" then
		return string.format("V(%.4g,%.4g,%.4g)", v.X, v.Y, v.Z)
	elseif kind == "Vector2" then
		return string.format("V2(%.4g,%.4g)", v.X, v.Y)
	elseif kind == "Color3" then
		return string.format("C(%.3f,%.3f,%.3f)", v.R, v.G, v.B)
	elseif kind == "NumberRange" then
		return string.format("R(%.5g,%.5g)", v.Min, v.Max)
	elseif kind == "NumberSequence" then
		local out = {}
		for _, kp in v.Keypoints do
			table.insert(out, string.format("%.4g:%.5g:%.4g", kp.Time, kp.Value, kp.Envelope))
		end
		return "NS[" .. table.concat(out, " ") .. "]"
	elseif kind == "ColorSequence" then
		local out = {}
		for _, kp in v.Keypoints do
			table.insert(out, string.format("%.4g:%s", kp.Time, fmt(kp.Value)))
		end
		return "CS[" .. table.concat(out, " ") .. "]"
	elseif kind == "EnumItem" then
		return v.Name
	elseif kind == "CFrame" then
		local look, up = v.LookVector, v.UpVector -- (the turn survives to ~1e-5)
		return string.format("CF(%s L(%.3f,%.3f,%.3f) U(%.3f,%.3f,%.3f))", fmt(v.Position), look.X, look.Y, look.Z, up.X, up.Y, up.Z)
	elseif kind == "Instance" then
		return "<" .. v.Name .. ">"
	elseif kind == "table" then
		return fmtTable(v)
	end
	return kind
end

-- every writable property the API dump lists for the class, and the attributes, of one instance
local IGNORE = { Parent = true, UniqueId = true, SourceAssetId = true, Capabilities = true, DataCost = true, Archivable = true,
	Name = true, RobloxLocked = true, Sandboxed = true }
local function dumpInstance(o)
	local out = { o.ClassName .. " " .. o.Name }
	local names = {}
	for name, ty in API.classes[o.ClassName].props do
		if not IGNORE[name] and not string.find(ty, ":ro$") and string.find(name, "^%u") then
			table.insert(names, name)
		end
	end
	table.sort(names)
	for _, name in names do
		local ok, v = pcall(function()
			return o[name]
		end)
		if ok then
			table.insert(out, "  " .. name .. " = " .. fmt(v))
		end
	end
	local attrs = o:GetAttributes()
	local attrNames = {}
	for name in attrs do
		table.insert(attrNames, name)
	end
	table.sort(attrNames)
	for _, name in attrNames do
		table.insert(out, "  @" .. name .. " = " .. fmt(attrs[name]))
	end
	return table.concat(out, "\n")
end

local function dumpEffect(fx)
	local out = { dumpInstance(fx) }
	for _, d in fx:GetDescendants() do
		table.insert(out, dumpInstance(d))
	end
	return table.concat(out, "\n")
end

-- the compiled timeline of an effect, independent of the order of its instances
local function planOf(fx)
	local plan = VFX.__compile(fx)
	local events = {}
	for _, ev in plan.events do
		local slot = plan.slots[ev.s]
		local copy = {}
		for k, v in slot do
			if k ~= "i" then
				copy[k] = v
			end
		end
		table.insert(events, string.format("%.4f|%d|%s|%s", ev.t, ev.op, tostring(ev.n), fmt(copy)))
	end
	table.sort(events)
	local function listOf(items)
		local out = {}
		for _, item in items do
			local copy = {}
			for k, v in item do
				if k ~= "i" then
					copy[k] = v
				end
			end
			table.insert(out, fmt(copy))
		end
		table.sort(out)
		return table.concat(out, ";")
	end
	return table.concat(events, "\n") .. "\n" .. string.format("%s|%s|%.4f|%.4f|%d|%d", fmt(plan.duration), tostring(plan.attach), plan.tail,
		plan.trailLife, plan.count, #plan.slots) .. "\n" .. listOf(plan.emitters) .. "\n" .. listOf(plan.trails)
end

local function readAll(fx)
	local out = {}
	for _, el in Editor.elements(fx) do
		table.insert(out, fmt(Editor.read(el)))
	end
	return table.concat(out, "\n")
end

local function clearEffects()
	for _, fx in Editor.effects() do
		Editor.removeEffect(fx)
	end
end

local function shorten(text)
	return #text > 60 and (string.sub(text, 1, 60) .. "...") or text
end

local function cleanError(err)
	return (string.gsub(tostring(err), "^[%w%._/]+:%d+: ", ""))
end

-- export -> remove -> import under the same name -> export: the code, the instances, the read-outs and the timeline must match
local function roundTrip(fx, label)
	local name = fx.Name
	local before, beforeRead, beforePlan = dumpEffect(fx), readAll(fx), planOf(fx)
	local lengthBefore = Editor.length(fx)
	local code = Editor.exportEffect(fx)
	Editor.removeEffect(fx)
	local ok, back = pcall(Editor.importEffect, code)
	if not check(ok and typeof(back) == "Instance", label .. ": import failed: " .. tostring(back)) then
		return nil
	end
	check(back.Name == name and back.Parent == Editor.folder(false), label .. ": name / parent")
	local code2 = Editor.exportEffect(back)
	if code ~= code2 then
		check(false, label .. ": the second export differs from the first")
	end
	local after = dumpEffect(back)
	if before ~= after then
		local a, b = string.split(before, "\n"), string.split(after, "\n")
		for i = 1, math.max(#a, #b) do
			if a[i] ~= b[i] then
				check(false, label .. ": instance dump differs at line " .. i .. "\n  was: " .. tostring(a[i]) .. "\n  now: " .. tostring(b[i]))
				break
			end
		end
	else
		check(true, "dump")
	end
	check(readAll(back) == beforeRead, label .. ": Editor.read of the elements differs")
	check(planOf(back) == beforePlan, label .. ": the compiled timeline differs")
	check(math.abs(Editor.length(back) - lengthBefore) < 1e-9, label .. ": length")
	return back, code
end

-- 1. the shape of a code -----------------------------------------------------------------------------------------------------------
t.section("code format", function()
	clearEffects()
	local fx = Editor.newFromTemplate("Format", "FIRE_EXPLOSION")
	local code, stats = Editor.exportEffect(fx)
	check(string.sub(code, 1, 4) == "LC1:" and Editor.CODE_PREFIX == "LC1:" and Editor.CODE_VERSION == 1, "prefix / version")
	check(string.match(string.sub(code, 5), "^[A-Za-z0-9+/]+$") ~= nil, "base64 body without padding or spaces")
	check(Editor.exportEffect(fx) == code and Editor.exportEffect("Format") == code, "export is deterministic and takes a name")
	check(stats.elements == 10 and stats.chars == #code and stats.json > #code / 2, "stats")
	check(stats.compressed == true and #code < 3200, "compressed, a whole template is a short code (" .. #code .. " chars)")
	print(string.format("FIRE_EXPLOSION: %d elements, %d characters (%d bytes of JSON)", stats.elements, #code, stats.json))
	local payload = Editor.unpackCode(code)
	check(type(payload.fx) == "table" and payload.fx.n == "Format" and #payload.fx.e == 10 and payload.g == Editor.VERSION,
		"the payload is a plain table")
	check(Editor.packCode(payload) == code, "unpackCode / packCode round trip")
	-- no instance, no script: the code holds data only
	check(string.find(code, "Script", 1, true) == nil, "no script text in the code")
	local info = Editor.describeCode(code)
	check(info and info.kind == "effect" and #info.effects == 1 and info.effects[1].name == "Format" and info.effects[1].elements == 10
		and info.effects[1].duration == 1.3 and info.effects[1].attach == "GROUND" and info.effects[1].kinds.PARTICLES ~= nil
		and info.effects[1].kinds.SOUND == 1 and info.effects[1].kinds.CAMERA == 1 and info.chars == #code - 4, "describeCode")
	-- tolerated when pasted: line breaks, a message around it, code fences, invisible characters
	local wrapped = string.gsub(code, "(" .. string.rep(".", 60) .. ")", "%1\n")
	Editor.removeEffect(fx)
	local back = Editor.importEffect("  \n" .. wrapped .. "\n  ")
	check(back.Name == "Format", "a code with line breaks imports")
	Editor.removeEffect(back)
	back = Editor.importEffect("Uite codul meu: " .. code .. " sper să-ți placă!")
	check(back.Name == "Format", "a code inside a message imports")
	Editor.removeEffect(back)
	back = Editor.importEffect("```\n" .. code .. "\n```")
	check(back.Name == "Format", "a code between fences imports")
	Editor.removeEffect(back)
	back = Editor.importEffect(string.lower(string.sub(code, 1, 4)) .. string.sub(code, 5) .. "\226\128\139\239\187\191")
	check(back.Name == "Format", "lower case prefix and invisible characters")
	check(select(1, Editor.describeCode(code .. "==")) ~= nil, "padding is accepted")
	clearEffects()
end)

-- what is not an element is not in the code, and the export says how much that was
t.section("objects that are not elements", function()
	clearEffects()
	local fx = Editor.newFromTemplate("Cu de toate", "PUNCH")
	local _, clean = Editor.exportEffect(fx)
	check(clean.ignored == 0, "a plain effect ignores nothing")
	inst("Script", "Backdoor", fx)
	inst("Folder", "Altceva", fx)
	inst("Attachment", "Orfană", fx.Root)
	local code, stats = Editor.exportEffect(fx)
	check(stats.ignored == 3 and stats.elements == clean.elements, "a script, a folder and a lonely Attachment are ignored: " .. tostring(stats.ignored))
	check(string.find(code, "Backdoor", 1, true) == nil and string.find(Editor.unpackCode(code).fx.e[1].n, "Backdoor", 1, true) == nil, "...and not in the code")
	local _, lib = Editor.exportAll()
	check(lib.ignored == 3 and lib.effects == 1, "exportAll adds them up")
	Editor.removeEffect(fx)
	local back = Editor.importEffect(code)
	check(select(2, Editor.exportEffect(back)).ignored == 0 and back:FindFirstChild("Backdoor", true) == nil, "the copy has none of them")
	clearEffects()
end)

-- 2. lossless round trip: every preset, every template ------------------------------------------------------------------------------
t.section("presets", function()
	clearEffects()
	local n = 0
	for _, preset in Editor.PRESETS do
		local fx = Editor.newEffect("P " .. preset.key, { duration = 1.5, attach = "TORSO" })
		Editor.addElement(fx, preset.key)
		local back = roundTrip(fx, "preset " .. preset.key)
		if back then
			n += 1
			check(#Editor.elements(back) == 1, "preset " .. preset.key .. " keeps its one element")
			Editor.removeEffect(back)
		end
	end
	check(n == #Editor.PRESETS, "all presets round-tripped: " .. n)
	check(history.active == nil, "no recording left open")
end)

t.section("templates", function()
	clearEffects()
	local n, biggest = 0, 0
	for _, tpl in Editor.TEMPLATES do
		local fx = Editor.newFromTemplate("T " .. tpl.key, tpl.key)
		local back, code = roundTrip(fx, "template " .. tpl.key)
		if back then
			n += 1
			biggest = math.max(biggest, #code)
			check(back:GetAttribute("LC_Template") == tpl.key and #Editor.elements(back) == #tpl.elements, "template " .. tpl.key .. " keeps its template and elements")
			Editor.removeEffect(back)
		end
		-- recoloured (colours that are not 8-bit) and scaled
		local fx2 = Editor.newFromTemplate("T2 " .. tpl.key, tpl.key, { color = Color3.fromHSV(0.83, 0.77, 0.91), scale = 1.37 })
		local back2 = roundTrip(fx2, "template " .. tpl.key .. " recoloured")
		if back2 then
			Editor.removeEffect(back2)
		end
	end
	check(n == #Editor.TEMPLATES, "all templates round-tripped: " .. n)
	print(string.format("%d templates, the biggest code has %d characters", n, biggest))
end)

-- an effect with a bit of everything the editor can do
local function kitchenSink()
	local fx = Editor.newEffect("Kitchen", { duration = 2.5, attach = "RIGHT_HAND" })
	fx:SetAttribute("LC_Template", "PUNCH")
	fx:SetAttribute("LC_Source", "rbxassetid://123456789")
	local a = Editor.addElement(fx, "SPARKLES", { name = "Chipuri ș î", position = Vector3.new(1, 2, 3), texture = "rbxassetid://987654321",
		color = { { 0, Color3.new(1, 1, 1) }, { 0.2, Color3.fromHSV(0.1, 0.8, 0.9) }, { 0.7, Color3.fromRGB(10, 200, 30) }, { 1, Color3.fromRGB(0, 0, 0) } },
		size = { { 0, 1 }, { 0.3, 5 }, { 1, 0 } }, Rate = 33.5, Drag = 2.25, Orientation = "VelocityParallel", Acceleration = Vector3.new(0, -9.8, 1.5),
		muted = true, LockedToPart = true, window = { 0.25, 1.75 }, bursts = { { 0.5, 7 }, { 0, 3 } } })
	a.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1, 0.5), NumberSequenceKeypoint.new(0.5, 3, 0), NumberSequenceKeypoint.new(1, 0, 0.25) }) -- an envelope
	a.FlipbookLayout = ENV.Enum.ParticleFlipbookLayout.Grid4x4
	a.FlipbookFramerate = NumberRange.new(8, 24)
	local shaped = Editor.addElement(fx, "RISING", { name = "Pe disc", shape = "Cylinder", partSize = Vector3.new(6.5, 0.4, 6.5),
		position = Vector3.new(-2, 0.5, 4) })
	shaped.Parent.CFrame = CFrame.Angles(0.2, 0.3, 0.1) * CFrame.new(Vector3.new(-2, 0.5, 4))
	local trail = Editor.addElement(fx, "MAGIC_TRAIL", { name = "Dâră", height = 4.5, position = Vector3.new(0, 1, 2), ground = true })
	trail.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.3, 0.4), NumberSequenceKeypoint.new(1, 0.1) })
	Editor.addElement(fx, "GROUND_RIBBON", { name = "Panglică" })
	local beam = Editor.addElement(fx, "BEAM", { name = "Rază", start = Vector3.new(0, 1, 0), finish = Vector3.new(4, 6, -8), width = { 0.4, 1.2 }, jitter = 0.7,
		curve = { 1, -1 }, flashTime = 0.2, window = { 0.1, 1 }, bursts = { { 1.5, 1 } } })
	beam.Segments = 24
	Editor.addElement(fx, "SOUND", { name = "Sunet", soundId = 12345678, pitch = { 0.8, 1.3 }, fade = 0.3, bursts = { { 0.2, 2 } }, position = Vector3.new(0, 1, 1) })
	Editor.addElement(fx, "CAMERA", { name = "Cameră", shake = 1.4, frequency = 22, fov = -6, flash = Color3.fromRGB(255, 190, 120), flashAlpha = 0.3,
		radius = 90, studio = false, bursts = { { 0.3, 1 } } })
	Editor.addElement(fx, "FLASH_LIGHT", { name = "Lumină", Color = Color3.fromRGB(255, 160, 70), position = Vector3.new(0, 3, 1) })
	local light = Editor.addElement(fx, "LIGHT", { name = "Lumină 2", Range = 19, Brightness = 2.5, Shadows = true })
	light.Parent.CFrame = CFrame.new(Vector3.new(1, 1, 1)) * CFrame.Angles(0, 0.7, 0)
	Editor.addElement(fx, "RING3D", { name = "Inel", colorEnd = Color3.fromRGB(150, 60, 20), count = 12, radius = { 1, 7 } })
	Editor.addElement(fx, "DEBRIS3D", { name = "Pietre" })
	return fx
end

t.section("kitchen sink", function()
	clearEffects()
	local fx = kitchenSink()
	local back, code = roundTrip(fx, "kitchen sink")
	if back then
		-- the things a code must carry, checked on the rebuilt effect itself
		check(back:GetAttribute("LC_Source") == "rbxassetid://123456789" and back:GetAttribute("LC_Template") == "PUNCH"
			and back:GetAttribute("LC_Duration") == 2.5 and back:GetAttribute("LC_Attach") == "RIGHT_HAND", "model attributes")
		local byName = {}
		for _, el in Editor.elements(back) do
			byName[el.Name] = el
		end
		local a = byName["Chipuri ș î"]
		check(a and a.Texture == "rbxassetid://987654321" and a.Size.Keypoints[1].Envelope == 0.5 and #a.Color.Keypoints == 4
			and a.FlipbookLayout.Name == "Grid4x4" and a.FlipbookFramerate.Max == 24 and a:GetAttribute("LC_Muted") == true
			and a:GetAttribute("LC_Bursts") == "0:3;0.5:7", "emitter: texture, envelope, 4 colour keys, flipbook, muted, bursts")
		local shaped = byName["Pe disc"]
		check(shaped and shaped.Parent:IsA("BasePart") and shaped.Parent.Size.X == 6.5 and shaped.Shape.Name == "Cylinder", "emitter on a Part keeps shape and size")
		check(shaped and shaped.Parent.CFrame.UpVector.Y < 0.99, "the Part keeps its turn (orientation)")
		check(byName["Rază"] and byName["Rază"].Segments == 24 and byName["Rază"].Attachment1.Position.X == 4, "beam ends")
		check(byName["Sunet"] and byName["Sunet"].SoundId == "rbxassetid://12345678" and byName["Sunet"]:GetAttribute("LC_Pitch") == "0.8,1.3", "sound")
		check(byName["Cameră"] and byName["Cameră"]:GetAttribute("LC_Flash") == Color3.fromRGB(255, 190, 120)
			and byName["Cameră"]:GetAttribute("LC_Studio") == false and byName["Cameră"]:GetAttribute("LC_Kind") == "CAMERA", "camera")
		check(byName["Lumină 2"] and byName["Lumină 2"].Shadows == true and byName["Lumină 2"].Range == 19, "light")
		check(byName["Inel"] and byName["Inel"]:GetAttribute("LC_ColorEnd") == Color3.fromRGB(150, 60, 20), "mesh end colour")
		check(Editor.kindOf(byName["Inel"]) == "MESH" and Editor.kindOf(byName["Panglică"]) == "TRAIL", "kinds")
		for _, d in back:GetDescendants() do
			check(not d:IsA("LuaSourceContainer"), "no script")
		end
	end
	-- the rotation of an Attachment is part of the code too
	if orientationTested and back then
		local rotated
		for _, el in Editor.elements(back) do
			if el.Name == "Lumină 2" then
				rotated = el
			end
		end
		local look = rotated.Parent.CFrame.LookVector
		check(look.X ~= 0 and math.abs(look.X) > 0.5, "the light's Attachment is turned: " .. fmt(look))
		check(string.find(Editor.exportEffect(back), "", 1, true) ~= nil, "export again")
		local payload = Editor.unpackCode(code)
		local found
		for _, el in payload.fx.e do
			if el.n == "Lumină 2" then
				found = el
			end
		end
		check(found and #found.f == 6 and math.abs(found.f[5] - 40.107) < 0.01, "orientation is written in degrees (YXZ): " .. fmt(found and found.f))
	end
end)

-- attributes and properties that are ABSENT must stay absent: create() gives new elements defaults that a code must undo
t.section("absent values", function()
	clearEffects()
	local fx = Editor.newEffect("Absente", { duration = 1 })
	local cam = Editor.addElement(fx, "CAMERA", { name = "Doar zoom", shake = 0, fov = 6, bursts = { { 0, 1 } } })
	cam:SetAttribute("LC_Radius", nil)
	cam:SetAttribute("LC_Freq", nil)
	local sound = Editor.addElement(fx, "SOUND", { name = "Fără ton", soundId = "HIT" })
	sound:SetAttribute("LC_Pitch", nil)
	local mesh = Editor.addElement(fx, "RING3D", { name = "Fără viață" })
	mesh:SetAttribute("LC_Life", nil)
	mesh:SetAttribute("LC_Grow", nil)
	local light = Editor.addElement(fx, "GLOW_LIGHT", { name = "Fără taste" })
	light.Enabled = false
	local trail = Editor.addElement(fx, "MAGIC_TRAIL", { name = "Fără fereastră" })
	trail:SetAttribute("LC_On", nil)
	trail.FaceCamera = false
	trail.Enabled = true
	local emitter = Editor.addElement(fx, "SPARKLES", { name = "Fără timp" })
	emitter:SetAttribute("LC_Bursts", nil)
	emitter.Enabled = true
	emitter.Rate = 0
	emitter.Drag = 0
	emitter.LightEmission = 0
	emitter.Squash = NumberSequence.new(0)
	local back = roundTrip(fx, "absent values")
	if back then
		local byName = {}
		for _, el in Editor.elements(back) do
			byName[el.Name] = el
		end
		check(byName["Doar zoom"]:GetAttribute("LC_Shake") == nil and byName["Doar zoom"]:GetAttribute("LC_Radius") == nil
			and byName["Doar zoom"]:GetAttribute("LC_Freq") == nil and byName["Doar zoom"]:GetAttribute("LC_FOV") == 6, "camera: no default shake / radius / frequency")
		check(byName["Fără ton"]:GetAttribute("LC_Pitch") == nil, "sound: no default pitch")
		check(byName["Fără viață"]:GetAttribute("LC_Life") == nil and byName["Fără viață"]:GetAttribute("LC_Grow") == nil, "mesh: no default life")
		check(byName["Fără taste"].Enabled == false and byName["Fără fereastră"].FaceCamera == false and byName["Fără fereastră"].Enabled == true
			and byName["Fără timp"].Enabled == true and byName["Fără timp"].Rate == 0 and byName["Fără timp"].LightEmission == 0, "properties at their defaults stay there")
		Editor.removeEffect(back)
	end
end)

-- 3. libraries -----------------------------------------------------------------------------------------------------------------------
-- the code of an effect without its name: two effects that differ only by name compare equal
local function codeWithoutName(fx)
	local payload = Editor.unpackCode(Editor.exportEffect(fx))
	payload.fx.n = "-"
	return Editor.packCode(payload)
end

t.section("library", function()
	clearEffects()
	for _, key in { "PUNCH", "GROUND_SLAM", "HEAL", "LIGHTNING" } do
		Editor.newFromTemplate("Lib " .. key, key)
	end
	kitchenSink()
	local code, stats = Editor.exportAll()
	check(string.sub(code, 1, 4) == "LC1:" and stats.effects == 5, "exportAll")
	local info = Editor.describeCode(code)
	check(info and info.kind == "library" and #info.effects == 5, "describeCode of a library")
	check(Editor.exportAll(Editor.effects()) == code and Editor.exportAll({ "Lib PUNCH" }) ~= code, "exportAll takes a list")
	-- a library is not a single effect
	local okSingle, errSingle = pcall(Editor.importEffect, code)
	check(not okSingle and string.find(tostring(errSingle), "bibliotecă", 1, true), "importEffect refuses a library: " .. tostring(errSingle))
	-- importing it over itself: the names are taken, so they get a number; everything else is identical
	local steps = #history.log
	local made, info2 = Editor.importMany(code)
	check(#made == 5 and info2.count == 5 and #info2.renamed == 5, "importMany with taken names: " .. #made)
	check(#history.log == steps + 1 and history.log[#history.log] == "Commit", "importMany is one undo step")
	check(#Editor.effects() == 10, "ten effects now")
	for _, fx in made do
		local original = Editor.effect((string.gsub(fx.Name, " 2$", "")))
		check(fx.Name == original.Name .. " 2", "numbered name " .. fx.Name)
		check(codeWithoutName(fx) == codeWithoutName(original), "same effect as " .. original.Name)
		check(planOf(fx) == planOf(original), "same timeline: " .. fx.Name)
	end
	-- replace = true overwrites instead
	local again = Editor.importMany(code, { replace = true })
	check(#again == 5 and #Editor.effects() == 10, "replace keeps the count")
	check(Editor.exportAll({ again[1], again[2], again[3], again[4], again[5] }) == code, "the replaced library exports the same")
	clearEffects()
	-- a single-effect code works with importMany
	local single = Editor.exportEffect(Editor.newFromTemplate("Solo", "DASH"))
	local one = Editor.importMany(single)
	check(#one == 1 and one[1].Name == "Solo 2", "importMany takes a single-effect code")
	clearEffects()
	t.throws(function()
		Editor.exportAll()
	end, "nu există efecte", "empty library")
end)

-- 4. names, options, undo ---------------------------------------------------------------------------------------------------------
t.section("import options", function()
	clearEffects()
	local fx = Editor.newFromTemplate("Opțiuni", "SHIELD")
	local code = Editor.exportEffect(fx)
	local effectsBefore, steps = #Editor.effects(), #history.log
	-- the name is taken
	t.throws(function()
		Editor.importEffect(code)
	end, "există deja un efect numit Opțiuni", "taken name")
	check(#Editor.effects() == effectsBefore and #history.log == steps, "a refused import leaves nothing behind (no undo step)")
	-- another name
	local b = Editor.importEffect(code, "  Alt nume  ")
	check(b.Name == "Alt nume" and #Editor.effects() == 2, "name given (and trimmed)")
	check(#history.log == steps + 1 and history.log[#history.log] == "Commit", "one undo step")
	-- unique / replace
	local u, info = Editor.importEffect(code, nil, { unique = true })
	check(u.Name == "Opțiuni 2" and info.renamed == true and info.elements == #Editor.elements(fx), "unique: " .. u.Name)
	local u2 = Editor.importEffect(code, nil, { unique = true })
	check(u2.Name == "Opțiuni 3", "unique again: " .. u2.Name)
	local old = Editor.effect("Opțiuni")
	local r = Editor.importEffect(code, nil, { replace = true })
	check(r.Name == "Opțiuni" and r ~= old and old.Parent == nil, "replace builds a new effect and removes the old one")
	check(Editor.effect("Opțiuni") == r and #Editor.effects() == 4, "replace removed the old one: " .. #Editor.effects())
	t.throws(function()
		Editor.importEffect(code, "")
	end, "nu poate fi gol", "empty name")
	t.throws(function()
		Editor.importEffect(code, string.rep("x", 101))
	end, "prea lung", "long name")
	-- an effect made from a code is a normal effect: edit it, play it, export it
	local el = Editor.elements(r)[1]
	Editor.setProps(el, { color = Color3.fromRGB(10, 20, 30) })
	check(Editor.length(r) > 0 and Editor.read(el).kind ~= nil, "editable")
	check(VFX.play ~= nil and select(1, pcall(Editor.preview, r, { target = CFrame.new() })), "playable in the preview")
	-- a template effect keeps working after a library import
	t.throws(function()
		Editor.exportEffect("Nu exista")
	end, "nu există efectul", "unknown effect")
	t.throws(function()
		Editor.exportEffect(Instance.new("Folder"))
	end, "un efect e un Model", "not a model")
	check(history.active == nil, "no recording left open")
	clearEffects()
end)

-- 5. refused codes ------------------------------------------------------------------------------------------------------------------
local baseCode
local function craft(mutate)
	local payload = Editor.unpackCode(baseCode)
	mutate(payload)
	return Editor.packCode(payload)
end

-- the code is refused with `needle` in a Romanian message, and nothing is created
local function refuses(code, needle, label, validOnly)
	local effectsBefore, steps = #Editor.effects(), #history.log
	local ok, err = pcall(Editor.importEffect, code)
	check(not ok, label .. ": must be refused")
	if not ok then
		check(string.find(tostring(err), needle, 1, true) ~= nil, label .. ": message lacks \"" .. needle .. "\": " .. tostring(err))
		check(string.sub(tostring(err), 1, 10) == "LostCube: ", label .. ": message begins with LostCube: " .. tostring(err))
		check(#tostring(err) < 400, label .. ": message stays short")
		if not validOnly then
			local info, msg = Editor.describeCode(code)
			check(info == nil and msg == tostring(err), label .. ": describeCode says the same: " .. tostring(msg))
		end
	end
	check(#Editor.effects() == effectsBefore and #history.log == steps and history.active == nil, label .. ": nothing created, no undo step")
	check(not pcall(Editor.importMany, code), label .. ": importMany refuses it too")
	check(#Editor.effects() == effectsBefore, label .. ": importMany created nothing")
end

t.section("malformed codes", function()
	clearEffects()
	local fx = Editor.newFromTemplate("Baza", "LIGHTNING")
	baseCode = Editor.exportEffect(fx)
	Editor.removeEffect(fx)
	-- not codes at all
	refuses("", "gol", "empty")
	refuses("   \n ", "gol", "blank")
	refuses("salut", "nu arată ca un cod", "text")
	refuses("LC", "nu arată ca un cod", "LC only")
	refuses("LC1:", "stricat", "no body")
	refuses("LC1:!!!!", "stricat", "bad characters")
	refuses("LC1:A", "stricat", "one character")
	refuses("LC1:AAAAAAAAAAAA", "stricat", "all zeros")
	local ok, err = pcall(Editor.importEffect, 42)
	check(not ok and string.find(tostring(err), "trebuie să fie text", 1, true), "a number is not a code: " .. tostring(err))
	ok, err = pcall(Editor.importEffect, nil)
	check(not ok and string.find(tostring(err), "trebuie să fie text", 1, true), "nil is not a code")
	ok, err = pcall(Editor.importEffect, {})
	check(not ok, "a table is not a code")
	check(select(2, Editor.describeCode(nil)) ~= nil and Editor.describeCode(12) == nil, "describeCode never throws")
	-- versions
	local body = string.sub(baseCode, 5)
	refuses("LC2:" .. body, "LC2", "newer version")
	refuses("LC2:" .. body, "Actualizează", "newer version asks for an update")
	refuses("LC99:" .. body, "mai nou", "much newer version")
	refuses("LC0:" .. body, "LC0", "older version")
	-- cut / mangled in transit
	refuses(string.sub(baseCode, 1, #baseCode // 2), "incomplet", "cut in half")
	refuses(string.sub(baseCode, 1, #baseCode - 1), "stricat", "last character missing")
	local flipped = string.sub(baseCode, 1, 200) .. (string.sub(baseCode, 201, 201) == "A" and "B" or "A") .. string.sub(baseCode, 202)
	refuses(flipped, "stricat", "one character changed")
	refuses(string.sub(baseCode, 1, 100) .. string.sub(baseCode, 103), "stricat", "two characters missing")
	refuses(string.sub(baseCode, 1, 50) .. "!" .. string.sub(baseCode, 51), "stricat", "a foreign character")
	-- a valid frame around nonsense
	refuses(Editor.packCode({}), "niciun efect", "empty payload")
	refuses(Editor.packCode({ fx = {} }), "numele efectului", "effect without a name")
	refuses(Editor.packCode({ fx = { n = 5 } }), "numele efectului", "name that is not text")
	refuses(Editor.packCode({ fx = { n = "x", e = { { k = "Z", n = "a" } } } }), "tip de element necunoscut", "unknown kind")
	refuses(Editor.packCode({ fx = { n = "x", e = 7 } }), "elemente", "elements that are not a list")
	refuses(Editor.packCode({ fx = { n = "x", e = { 5 } } }), "element invalid", "an element that is not a table")
	refuses(Editor.packCode({ fx = { n = "x", e = { { k = "P" } } } }), "numele elementului", "element without a name")
	refuses(Editor.packCode({ lib = {} }), "între 1 și", "empty library")
	do
		local badLibrary = Editor.packCode({ lib = { { n = "a" }, 5 } })
		local okMany, errMany = pcall(Editor.importMany, badLibrary)
		check(not okMany and string.find(tostring(errMany), "efect invalid", 1, true) and #Editor.effects() == 0, "a bad effect in a library: " .. tostring(errMany))
		check(select(2, Editor.describeCode(badLibrary)) == tostring(errMany), "describeCode says the same")
	end
	refuses(Editor.packCode({ fx = { n = "x\n\0y" } }), "caractere nepermise", "control characters in the name")
	refuses(Editor.packCode({ fx = { n = string.rep("x", 101) } }), "prea lung", "long name")
	refuses(Editor.packCode({ fx = { n = "x\255\254" } }), "caractere nepermise", "invalid UTF-8")
	refuses(Editor.packCode(7), "nu poate fi citit", "a number as payload")
	refuses(Editor.packCode("text"), "nu poate fi citit", "a string as payload")
	check(history.active == nil, "no recording left open")
	-- fields it does not know are ignored (codes of a later 1.x may add some)
	local extra = craft(function(payload)
		payload.future = { 1, 2, 3 }
		payload.fx.zz = "ceva"
		payload.fx.e[1].qq = true
		payload.fx.e[1].p.zzz = 5
	end)
	local imported = Editor.importEffect(extra)
	check(imported.Name == "Baza" and #Editor.elements(imported) == #Editor.unpackCode(baseCode).fx.e, "unknown fields are ignored")
	Editor.removeEffect(imported)
end)

t.section("hostile codes", function()
	clearEffects()
	local el1 -- the first particle element of the base code
	local function first(payload)
		for _, el in payload.fx.e do
			if el.k == "P" then
				return el
			end
		end
	end
	local function props(payload)
		el1 = first(payload)
		el1.p = el1.p or {}
		return el1.p
	end
	-- resources: only Roblox assets
	for _, url in { "http://evil.example/x.png", "https://example.com/a.png", "file:///etc/passwd", "rbxassetid://abc", "rbxasset://../../x.png",
		"data:text/html,<script>", "rbxassetid://12 34", "\\\\server\\share\\a.png", string.rep("a", 300) } do
		refuses(craft(function(payload)
			props(payload).tx = url
		end), "adresa", "texture " .. string.sub(url, 1, 24), true)
	end
	for _, url in { "rbxassetid://123", "#456", "~p/sparkles_main.dds", "rbxasset://textures/particles/x.png", "~t/foo.png",
		"https://www.roblox.com/asset/?id=77", "" } do
		local code = craft(function(payload)
			props(payload).tx = url
		end)
		local fx = Editor.importEffect(code)
		check(fx ~= nil, "texture " .. url .. " is fine")
		Editor.removeEffect(fx)
	end
	-- wrong types and shapes
	local bad = {
		{ "sz", "abc", "secvență de numere" }, { "sz", { 1 }, "secvență de numere" }, { "sz", { 0, 1, 0.7, 2, 0.5, 3, 1, 0 }, "timpii" }, { "sz", { 0, 1, 1.5, 2 }, "timpii" },
		{ "sz", { 0.5, 1, 1, 2 }, "să înceapă la 0" }, { "co", { "ZZZZZZ" }, "culoare invalidă" }, { "co", 5, "secvență de culori" },
		{ "co", { 0, "FFFFFF", 0.5 }, "secvență de culori" }, { "lf", { 1, 2, 3 }, "interval" }, { "lf", "x", "interval" },
		{ "sa", { 1, 2, 3 }, "vector" }, { "ac", { 1 }, "vector" }, { "or", "NuExista", "nu e o valoare cunoscută pentru ParticleOrientation" },
		{ "or", 5, "valoare de enum" }, { "lp", "da", "da / nu" }, { "rt", "mult", "număr invalid" }, { "rt", true, "număr invalid" },
		{ "tr", { "e", 0, 0, 0, 1, 0 }, "secvență" },
	}
	for _, case in bad do
		refuses(craft(function(payload)
			props(payload)[case[1]] = case[2]
		end), case[3], "property " .. case[1] .. " = " .. fmt(case[2]), true)
	end
	-- too many keypoints
	local many = {}
	for i = 0, 30 do
		many[#many + 1] = i / 30
		many[#many + 1] = 1
	end
	refuses(craft(function(payload)
		props(payload).sz = many
	end), "secvență de numere", "31 keypoints", true)
	-- positions, frames
	for _, frame in { { 1, 2 }, { 1, 2, 3, 4 }, "x", { 1, 2, 3, 4, 5, 6, 7 } } do
		refuses(craft(function(payload)
			first(payload).f = frame
		end), "poziție", "frame " .. fmt(frame), true)
	end
	refuses(craft(function(payload)
		first(payload).f = { "a", 2, 3 }
	end), "număr invalid", "frame with text", true)
	refuses(craft(function(payload)
		first(payload).hs = { 1, 2 }
	end), "vector", "bad part size", true)
	refuses(craft(function(payload)
		for _, el in payload.fx.e do
			if el.k == "L" then
				el.hs = { 1, 1, 1 }
			end
		end
	end), "doar particulele", "part size on a light", true)
	refuses(craft(function(payload)
		for _, el in payload.fx.e do
			if el.k == "L" then
				el.c = "X"
			end
		end
	end), "tip de lumină", "light kind", true)
	-- attributes
	local attrCases = {
		{ { Bursts = "0:abc" }, "LC_Bursts" }, { { Bursts = "0:5;0:5;" .. string.rep("1:1;", 400) }, "prea multe" }, { { Bursts = "0:99999" }, "în afara limitelor" },
		{ { On = "0,1,2,3" }, "LC_On" }, { { On = "5" .. string.rep("9", 3000) }, "în afara limitelor" }, { { Keys = "0,1" }, "LC_Keys" },
		{ { Life = "-1,2" }, "în afara limitelor" }, { { Alpha = "0,2" }, "în afara limitelor" }, { { Mode = "Rm -rf" }, "nu e permisă" },
		{ { Attach = "LUNA" }, "punct de atașare" }, { { Bursts = { 1 } }, "valoare neașteptată" }, { { ["x y"] = 1 }, "nume de atribut" },
		{ { Preset = "x" .. string.rep("y", 500) }, "prea lung" }, { { Preset = "a\nb" }, "caractere nepermise" },
		{ { Rate = "mult" }, "alt tip" }, { { Muted = "da" }, "alt tip" },
		{ { Kind = "SCRIPT" }, "nu e permisă" },
	}
	for n, case in attrCases do
		refuses(craft(function(payload)
			local el = first(payload)
			if case[1].Attach then
				payload.fx.a = payload.fx.a or {}
				payload.fx.a.Attach = case[1].Attach
			else
				el.a = el.a or {}
				for k, v in case[1] do
					el.a[k] = v
				end
			end
		end), case[2], "attribute case " .. n .. " (" .. shorten(fmt(case[1])) .. ")", true)
	end
	local tooMany = {}
	for i = 1, 60 do
		tooMany["Atr" .. i] = i
	end
	refuses(craft(function(payload)
		first(payload).a = tooMany
	end), "prea multe atribute", "60 attributes", true)
	-- the model itself
	refuses(craft(function(payload)
		payload.fx.a = payload.fx.a or {}
		payload.fx.a.Duration = "lung"
	end), "LC_Duration", "duration that is text", true)
	-- a mesh without its mode would not be a mesh any more
	local meshCode = Editor.exportEffect(Editor.newFromTemplate("Cu mesh", "GROUND_SLAM"))
	Editor.removeEffect("Cu mesh")
	local m = Editor.unpackCode(meshCode)
	for _, el in m.fx.e do
		if el.k == "M" then
			el.a.Mode = nil
		end
	end
	refuses(Editor.packCode(m), "LC_Mode", "mesh without a mode", true)
	-- numbers outside the limits are brought inside (and said)
	local wild = craft(function(payload)
		local p = props(payload)
		p.rt = 1e9
		p.lf = { -5, 9999 }
		p.sz = 1e9
		p.ac = { 1e9, -1e9, 0 }
		first(payload).f = { 1e9, -1e9, 0 }
	end)
	local imported, info = Editor.importEffect(wild)
	check(info.clamped >= 6 and #info.notes >= 1 and string.find(info.notes[1], "limite", 1, true), "clamped values are reported: " .. fmt(info))
	local emitter
	for _, el in Editor.elements(imported) do
		if Editor.kindOf(el) == "PARTICLES" and el.Rate == 2000 then
			emitter = el
		end
	end
	check(emitter and emitter.Lifetime.Min == 0 and emitter.Lifetime.Max == 60 and emitter.Size.Keypoints[1].Value == 2000
		and emitter.Acceleration.X == 2000 and math.abs(emitter.Parent.CFrame.Position.X) == 5000, "values were clamped into the limits")
	Editor.removeEffect(imported)
	check(Editor.describeCode(wild).clamped >= 6, "describeCode counts the clamped values")
end)

t.section("size caps", function()
	clearEffects()
	local limits = Editor.SHARE_LIMITS
	check(limits.elements == 150 and limits.effects == 100 and limits.codeChars >= 100000 and limits.jsonBytes >= 1000000, "documented limits")
	local fx = Editor.newFromTemplate("Mic", "PUNCH")
	baseCode = Editor.exportEffect(fx)
	Editor.removeEffect(fx)
	-- 151 elements
	local lots = Editor.unpackCode(baseCode)
	local one = lots.fx.e[1]
	lots.fx.e = {}
	for i = 1, 151 do
		lots.fx.e[i] = { k = one.k, n = "E" .. i, f = one.f, p = one.p, a = one.a }
	end
	refuses(Editor.packCode(lots), "151 elemente; maximul e 150", "151 elements", true)
	lots.fx.e[151] = nil
	local fine = Editor.importEffect(Editor.packCode(lots))
	check(#Editor.elements(fine) == 150, "150 elements are fine")
	Editor.removeEffect(fine)
	-- the same through the exporter: an effect that big cannot be exported
	local big = Editor.newEffect("Mare", { duration = 1 })
	for i = 1, 151 do
		Editor.addElement(big, "PARTICLES", { name = "E" .. i })
	end
	t.throws(function()
		Editor.exportEffect(big)
	end, "151 elemente", "export of 151 elements")
	Editor.removeEffect(big)
	-- 101 effects in a library
	local lib = { lib = {} }
	for i = 1, 101 do
		lib.lib[i] = { n = "F" .. i }
	end
	refuses(Editor.packCode(lib), "între 1 și 100", "101 effects", true)
	-- more characters than a code may have (text that does not compress)
	math.randomseed(11)
	local noise = {}
	for i = 1, 240000 do
		noise[i] = string.char(math.random(33, 126))
	end
	local huge = Editor.packCode({ fx = { n = "x", junk = string.gsub(table.concat(noise), '[\\"]', "") } })
	check(#huge > limits.codeChars, "the noisy code is longer than a code may be: " .. #huge)
	refuses(huge, "prea mare", "code over the cap", true)
	check(Editor.describeCode(huge) == nil, "describeCode refuses it too")
	-- more than a library may have: refused before anything is decoded
	refuses("LC1:" .. string.rep("A", limits.libraryChars + 1), "prea mare", "text over the library cap", true)
	-- a "zip bomb": tiny text that grows past the limit when unpacked
	local small = Editor.packCode({ fx = { n = "x", junk = string.rep("a", 15000) } })
	local bomb = Editor.packCode({ fx = { n = "x", junk = string.rep("a", 60000) } })
	check(#bomb < 12000, "the bomb is small: " .. #bomb)
	local old = limits.jsonBytes
	limits.jsonBytes = 20000
	check(Editor.describeCode(small) ~= nil, "15 KB of JSON passes a 20 KB limit")
	refuses(bomb, "stricat", "decompression past the limit", true)
	t.throws(function()
		Editor.packCode({ fx = { n = "x", junk = string.rep("a", 21000) } })
	end, "prea mare", "a code cannot be made out of more JSON than can be read back")
	limits.jsonBytes = old
	check(Editor.describeCode(bomb) ~= nil, "...and the same text is fine under the normal limit")
	-- the name of a library entry and an element
	refuses(craft(function(payload)
		payload.fx.e[1].n = string.rep("n", 101)
	end), "numele elementului", "long element name", true)
end)

-- no script, no matter what the code says
t.section("never scripts", function()
	clearEffects()
	local fx = Editor.newFromTemplate("Fără scripturi", "PUNCH")
	local payload = Editor.unpackCode(Editor.exportEffect(fx))
	Editor.removeEffect(fx)
	payload.fx.e[1].p.Source = "print('x')"
	payload.fx.e[1].p.RunContext = "Server"
	payload.fx.Source = "require(1)"
	payload.fx.scripts = { { n = "Backdoor", c = "Script", s = "require(123)" } }
	payload.fx.e[#payload.fx.e + 1] = { k = "Script", n = "Backdoor", s = "require(123)" }
	refuses(Editor.packCode(payload), "tip de element necunoscut", "a Script element", true)
	payload.fx.e[#payload.fx.e] = nil
	local back = Editor.importEffect(Editor.packCode(payload))
	local scripts = 0
	for _, d in back:GetDescendants() do
		if d:IsA("LuaSourceContainer") or d.Name == "Backdoor" then
			scripts += 1
		end
	end
	check(scripts == 0 and not back:IsA("LuaSourceContainer"), "extra fields never become scripts")
	-- the editor never writes a script into a code either
	local code = Editor.exportEffect(back)
	check(string.find(code, "Backdoor", 1, true) == nil, "nothing of it in the code")
	Editor.removeEffect(back)
end)

-- random damage to a valid payload: whatever happens, the answer is an import or a Romanian "LostCube: ..." message, never a Lua
-- error, and nothing is left behind
t.section("fuzz", function()
	clearEffects()
	local sink = kitchenSink()
	local original = Editor.unpackCode(Editor.exportEffect(sink))
	Editor.removeEffect(sink)
	math.randomseed(20240607)
	local function random(n)
		return math.random(1, n)
	end
	local function paths(node, path, out)
		out = out or {}
		if type(node) == "table" then
			for key, value in node do
				local here = table.clone(path)
				table.insert(here, key)
				table.insert(out, here)
				paths(value, here, out)
			end
		end
		return out
	end
	local function copy(node)
		if type(node) ~= "table" then
			return node
		end
		local out = {}
		for k, v in node do
			out[k] = copy(v)
		end
		return out
	end
	local replacements = { function() return 0 end, function() return -1 end, function() return 1e308 end, function() return -1e308 end,
		function() return 0.5 end, function() return "x" end, function() return "" end, function() return true end, function() return false end,
		function() return {} end, function() return { 1, 2, 3 } end, function() return { "a" } end, function() return { { 1 } } end,
		function() return string.rep("y", 700) end, function() return 12345678901234 end, function() return { "e", 0, 1 } end,
		function() return { "c", "FFFFFF" } end, function() return { x = 1 } end, function() return "rbxassetid://5" end,
		function() return nil end }
	local survived, refused, bare = 0, 0, 0
	local effectsBefore = #Editor.effects()
	for round = 1, 350 do
		local payload = copy(original)
		for _ = 1, random(3) do
			local all = paths(payload, {})
			local target = all[random(#all)]
			local node = payload
			for i = 1, #target - 1 do
				node = node[target[i]]
			end
			node[target[#target]] = replacements[random(#replacements)]()
		end
		local okPack, code = pcall(Editor.packCode, payload)
		if okPack then
			local okDescribe, info, why = pcall(Editor.describeCode, code)
			check(okDescribe, "describeCode must not throw (round " .. round .. ")")
			local ok, err = pcall(Editor.importEffect, code, "Fuzz " .. round)
			if ok then
				survived += 1
				check(info ~= nil, "describeCode agrees with importEffect on round " .. round .. ": " .. tostring(why))
				local good = pcall(Editor.exportEffect, err)
				check(good, "an imported effect can be exported again (round " .. round .. ")")
				Editor.removeEffect(err)
			else
				refused += 1
				if string.sub(tostring(err), 1, 10) ~= "LostCube: " then
					bare += 1
					check(false, "round " .. round .. ": a raw error instead of a message: " .. tostring(err))
				end
				check(info == nil, "describeCode agrees with importEffect on round " .. round .. " (refused: " .. tostring(err) .. ")")
				check(#Editor.effects() == effectsBefore and history.active == nil, "round " .. round .. ": nothing left behind")
			end
		end
	end
	print(string.format("fuzz: %d imported, %d refused, %d raw errors", survived, refused, bare))
	check(survived > 20 and refused > 50, "both outcomes happen: " .. survived .. " / " .. refused)
	-- bytes of the text itself
	local base = Editor.exportEffect(Editor.newFromTemplate("Octeți", "TELEPORT"))
	Editor.removeEffect("Octeți")
	for round = 1, 150 do
		local chars = {}
		for i = 1, #base do
			chars[i] = string.sub(base, i, i)
		end
		for _ = 1, random(4) do
			local at = random(#chars)
			local kind = random(3)
			if kind == 1 then
				chars[at] = string.char(random(256) - 1)
			elseif kind == 2 then
				chars[at] = ""
			else
				chars[at] = chars[at] .. string.char(random(256) - 1)
			end
		end
		local mangled = table.concat(chars)
		local ok, err = pcall(Editor.importEffect, mangled, "Octeți " .. round)
		if ok then
			Editor.removeEffect(err) -- (a change that the checksum cannot see, such as a space)
		else
			check(string.sub(tostring(err), 1, 10) == "LostCube: ", "text round " .. round .. ": " .. tostring(err))
		end
	end
	check(#Editor.effects() == effectsBefore and history.active == nil, "nothing left behind")
end)

-- a failure while building leaves nothing and cancels the undo step
t.section("failed build", function()
	clearEffects()
	local code = Editor.exportEffect(Editor.newFromTemplate("Cade", "PUNCH"))
	Editor.removeEffect("Cade")
	local real = ENV.Instance
	ENV.Instance = { new = function(class)
		if class == "Sound" then
			error("boom")
		end
		return real.new(class)
	end }
	local steps = #history.log
	local ok, err = pcall(Editor.importEffect, code)
	ENV.Instance = real
	check(not ok and string.find(tostring(err), "boom", 1, true), "the engine error comes up: " .. tostring(err))
	check(#Editor.effects() == 0 and #history.log == steps + 1 and history.log[#history.log] == "Cancel" and history.active == nil,
		"nothing left, the undo step is cancelled")
	local library = Editor.exportAll({ Editor.newFromTemplate("A1", "DASH"), Editor.newFromTemplate("A2", "PUNCH") })
	ENV.Instance = { new = function(class)
		if class == "Sound" then
			error("boom")
		end
		return real.new(class)
	end }
	local okMany = pcall(Editor.importMany, library, { replace = true })
	ENV.Instance = real
	check(not okMany and #Editor.effects() == 2 and history.log[#history.log] == "Cancel" and history.active == nil,
		"importMany: the effects built before the failure are removed again")
	clearEffects()
end)

local function oklabL(c)
	local function lin(x)
		return x <= 0.04045 and x / 12.92 or ((x + 0.055) / 1.055) ^ 2.4
	end
	local r, g, b = lin(c.R), lin(c.G), lin(c.B)
	local l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ^ (1 / 3)
	local m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ^ (1 / 3)
	local s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ^ (1 / 3)
	return 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s
end

-- 6. palette ------------------------------------------------------------------------------------------------------------------------
local function hsv(c)
	local h, s, v = c:ToHSV()
	return h * 360, s, v
end
local function hueGap(a, b)
	local d = math.abs(a - b) % 360
	return d > 180 and 360 - d or d
end

local PALETTES = {
	forest = { { hex = "3C6E3A", share = 40 }, { hex = "2A4F2A", share = 25 }, { hex = "6B4F2E", share = 15 }, { hex = "9A9A9A", share = 10 },
		{ hex = "1E3320", share = 10 } },
	desert = { { hex = "D9B26F", share = 50 }, { hex = "B5651D", share = 25 }, { hex = "F0E0B0", share = 15 }, { hex = "7A5230", share = 10 } },
	night = { { hex = "10131F", share = 60 }, { hex = "1B2A4A", share = 25 }, { hex = "3A3F55", share = 10 }, { hex = "FFD27A", share = 5 } },
	ocean = { { hex = "1F6FB5", share = 50 }, { hex = "0E3E6B", share = 30 }, { hex = "7FC4E8", share = 20 } },
	snow = { { hex = "F2F6FA", share = 60 }, { hex = "C9D6E3", share = 25 }, { hex = "8FA6BF", share = 10 } },
	grey = { { hex = "808080", share = 50 }, { hex = "9A9A9A", share = 30 }, { hex = "505050", share = 20 } },
}

t.section("colour distance and names", function()
	local red, green = Color3.fromRGB(255, 0, 0), Color3.fromRGB(0, 200, 0)
	check(Editor.colorDistance(red, red) == 0 and math.abs(Editor.colorDistance(red, green) - Editor.colorDistance(green, red)) < 1e-12, "identity and symmetry")
	check(Editor.colorDistance(red, green) > 0.4 and Editor.colorDistance(Color3.fromRGB(100, 100, 100), Color3.fromRGB(102, 100, 100)) < 0.02,
		"distant colours are far, close ones close")
	check(Editor.colorDistance(Color3.new(0, 0, 0), Color3.new(1, 1, 1)) > 0.9, "black and white are the farthest")
	local names = { [Color3.fromRGB(255, 0, 0)] = "roșu", [Color3.fromRGB(0, 160, 0)] = "verde", [Color3.fromRGB(0, 0, 255)] = "albastru",
		[Color3.fromRGB(255, 255, 0)] = "galben", [Color3.fromRGB(255, 140, 0)] = "portocaliu", [Color3.fromRGB(128, 0, 255)] = "violet",
		[Color3.fromRGB(255, 80, 200)] = "roz", [Color3.fromRGB(0, 230, 230)] = "turcoaz", [Color3.fromRGB(10, 10, 10)] = "negru",
		[Color3.fromRGB(250, 250, 250)] = "alb", [Color3.fromRGB(128, 128, 128)] = "gri", [Color3.fromRGB(110, 70, 30)] = "maro" }
	for color, name in names do
		check(Editor.colorName(color) == name, "colorName " .. fmt(color) .. " = " .. Editor.colorName(color) .. ", wanted " .. name)
	end
end)

t.section("suggestColors", function()
	for name, palette in PALETTES do
		local list = Editor.suggestColors(palette)
		local dominant = {}
		for _, entry in palette do
			if entry.share >= 8 then
				table.insert(dominant, Color3.fromHex(entry.hex))
			end
		end
		check(#list == 4, name .. ": four suggestions by default (" .. #list .. ")")
		for i, s in list do
			check(typeof(s.color) == "Color3" and string.match(s.hex, "^#%x%x%x%x%x%x$") and s.hex == "#" .. string.upper(s.color:ToHex()), name .. ": colour and hex")
			check(type(s.reason) == "string" and #s.reason > 25 and string.find(s.reason, "%.$") ~= nil, name .. ": a sentence as reason: " .. tostring(s.reason))
			for _, d in dominant do
				check(Editor.colorDistance(s.color, d) >= 0.14, string.format("%s: suggestion %d %s is too close to the map colour %s (%.3f)", name, i, s.hex,
					fmt(d), Editor.colorDistance(s.color, d)))
			end
			local h, sat, v = hsv(s.color)
			check(sat >= 0.5 and v >= 0.75, name .. ": vivid colours only: " .. s.hex)
			for j = i + 1, #list do
				check(hueGap(h, (hsv(list[j].color))) >= 40, name .. ": different hues " .. s.hex .. " / " .. list[j].hex)
			end
		end
		local reasons = {}
		for _, s in list do
			reasons[s.reason] = true
		end
		check(next(reasons) ~= nil, name .. ": reasons")
		print(string.format("%-7s -> %s", name, table.concat((function()
			local out = {}
			for _, s in list do
				table.insert(out, s.hex)
			end
			return out
		end)(), " ")) .. "   " .. list[1].reason)
	end
	-- the classic relations
	local forest = Editor.suggestColors(PALETTES.forest)
	check(hueGap((hsv(forest[1].color)), (hsv(Color3.fromHex("3C6E3A")))) >= 100, "forest: the first suggestion is far from the green " .. forest[1].hex)
	check(string.find(forest[1].reason, "verde", 1, true) ~= nil, "forest: the reason names the green: " .. forest[1].reason)
	local desert = Editor.suggestColors(PALETTES.desert)
	local dh = hsv(desert[1].color)
	check(dh > 170 and dh < 290, "desert (sand, orange): a bluish first suggestion, got " .. desert[1].hex .. " at " .. dh)
	local ocean = Editor.suggestColors(PALETTES.ocean)
	local oh = hsv(ocean[1].color)
	check(oh < 75 or oh > 330, "ocean (blue): a warm first suggestion, got " .. ocean[1].hex)
	local night = Editor.suggestColors(PALETTES.night)
	check(select(1, oklabL(night[1].color)) > 0.6, "night: bright colours glow")
	check(string.find(night[1].reason, "întunecat", 1, true) ~= nil or string.find(night[1].reason, "Complementar", 1, true) ~= nil, "night: " .. night[1].reason)
	local grey = Editor.suggestColors(PALETTES.grey)
	check(string.find(grey[1].reason, "fără culoare", 1, true) ~= nil, "grey map: " .. grey[1].reason)
	-- the number of suggestions
	check(#Editor.suggestColors(PALETTES.forest, { count = 1 }) == 3 and #Editor.suggestColors(PALETTES.forest, { count = 9 }) == 5
		and #Editor.suggestColors(PALETTES.forest, { count = 3 }) == 3, "3..5 suggestions")
	-- the same palette always gives the same answer; the first of 3 is the first of 5
	local again = Editor.suggestColors(PALETTES.forest)
	for i, s in Editor.suggestColors(PALETTES.forest) do
		check(s.hex == again[i].hex and s.reason == again[i].reason, "deterministic")
	end
	check(Editor.suggestColors(PALETTES.forest, { count = 5 })[1].hex == forest[1].hex, "the best one does not depend on the count")
	-- other ways to write a palette
	local mixed = Editor.suggestColors({ Color3.fromRGB(60, 110, 58), "2A4F2A", "#6B4F2E", { color = Color3.fromRGB(154, 154, 154), share = 10 },
		{ hex = "1E3320", share = 10 } })
	check(#mixed == 4, "Color3, hex, #hex, { color, share }, { hex, share }")
	check(#Editor.suggestColors({ Color3.fromRGB(10, 200, 10) }) == 4, "a palette of one colour")
	-- bad palettes
	t.throws(function()
		Editor.suggestColors({})
	end, "paleta hărții e goală", "empty palette")
	t.throws(function()
		Editor.suggestColors(nil)
	end, "paleta hărții e goală", "nil palette")
	t.throws(function()
		Editor.suggestColors({ "nu e culoare", 5 })
	end, "nicio culoare validă", "no valid colour")
	-- darkness can be told
	local dark = Editor.suggestColors(PALETTES.ocean, { night = true })
	check(#dark == 4, "night option")
end)

t.section("paletteOf", function()
	local report = { style = { colors = { { hex = "3C6E3A", share = 40.5 }, { hex = "6B4F2E", share = 20 }, { hex = "zzz", share = 5 } },
		atmosphere = { color = "A0B0C0", density = 0.3 }, lighting = { clockTime = 22 } } }
	local palette, mood = Editor.paletteOf(report)
	check(#palette == 3 and palette[1].color == Color3.fromRGB(60, 110, 58) and palette[1].share == 40.5 and palette[3].share == 8, "colours and atmosphere")
	check(mood.night == true and mood.clockTime == 22, "night")
	local _, day = Editor.paletteOf({ style = { colors = { { hex = "FFFFFF", share = 1 } }, lighting = { clockTime = 14 } } })
	check(day.night == false, "day")
	local _, unknown = Editor.paletteOf({ style = { colors = { { hex = "FFFFFF", share = 1 } } } })
	check(unknown.night == nil and unknown.clockTime == nil, "unknown time of day")
	check(#Editor.suggestColors(palette, { night = mood.night }) == 4, "the palette of a report feeds suggestColors")
	t.throws(function()
		Editor.paletteOf({})
	end, "stil vizual", "no style")
	t.throws(function()
		Editor.paletteOf({ style = { colors = {} } })
	end, "culorile hărții", "no colours")
	t.throws(function()
		Editor.paletteOf(nil)
	end, "stil vizual", "nil report")
end)

-- 7. recolour, match, scale, variants ----------------------------------------------------------------------------------------------
-- every colour of an effect, in a fixed order: { value, kind } with kind "particles" / "light" / "mesh" / "meshEnd" / "flash"
local function allColors(fx)
	local out = {}
	local function add(c, tag)
		table.insert(out, { c, tag })
	end
	for _, el in Editor.elements(fx) do
		local kind = Editor.kindOf(el)
		if kind == "PARTICLES" or kind == "TRAIL" or kind == "BEAM" then
			for _, kp in el.Color.Keypoints do
				add(kp.Value, kind)
			end
		elseif kind == "LIGHT" or kind == "MESH" then
			add(el.Color, kind)
			if typeof(el:GetAttribute("LC_ColorEnd")) == "Color3" then
				add(el:GetAttribute("LC_ColorEnd"), "meshEnd")
			end
		elseif kind == "CAMERA" and typeof(el:GetAttribute("LC_Flash")) == "Color3" then
			add(el:GetAttribute("LC_Flash"), "flash")
		end
	end
	return out
end

local function isNeutral(c)
	local _, s, v = hsv(c)
	return s < 0.12 or v < 0.16
end

-- the circular mean hue (degrees) of the chromatic colours, weighted like the Editor does (saturation x value)
local function meanHue(fx)
	local x, y = 0, 0
	for _, entry in allColors(fx) do
		local h, s, v = hsv(entry[1])
		if not isNeutral(entry[1]) then
			x += math.cos(math.rad(h)) * s * v
			y += math.sin(math.rad(h)) * s * v
		end
	end
	return math.deg(math.atan2(y, x)) % 360
end

t.section("recolorEffect", function()
	clearEffects()
	local red = Color3.fromRGB(255, 40, 40)
	local totalNeutral = 0
	for _, key in { "HEAL", "FIRE_EXPLOSION", "FREEZE", "LEVEL_UP", "POISON", "GROUND_SLAM", "TELEPORT", "SHIELD" } do
		local fx = Editor.newFromTemplate("Rec " .. key, key)
		local before = allColors(fx)
		local steps = #history.log
		local same, info = Editor.recolorEffect(fx, red)
		check(same == fx and info.changed > 0 and not info.neutral and info.slots >= info.changed, key .. ": returns the effect and what changed")
		check(#history.log == steps + 1 and history.log[#history.log] == "Commit", key .. ": one undo step")
		local after = allColors(fx)
		check(#before == #after, key .. ": same number of colours")
		local neutralKept = 0
		for i, entry in before do
			local now = after[i][1]
			if isNeutral(entry[1]) then
				check(now == entry[1], key .. ": a white / grey / near-black stays (" .. fmt(entry[1]) .. " -> " .. fmt(now) .. ")")
				neutralKept += 1
			end
		end
		totalNeutral += neutralKept
		local h = meanHue(fx)
		check(h < 30 or h > 330, string.format("%s: the effect is red now (mean hue %.0f)", key, h))
		-- the saturated colours stay saturated and keep their brightness roughly
		for i, entry in before do
			if not isNeutral(entry[1]) then
				local _, s0, v0 = hsv(entry[1])
				local _, s1, v1 = hsv(after[i][1])
				check(math.abs(v1 - v0) < 0.45 and s1 > 0.1, string.format("%s: colour %d keeps its character (%s -> %s)", key, i, fmt(entry[1]), fmt(after[i][1])))
			end
		end
		Editor.removeEffect(fx)
	end
	check(totalNeutral >= 10, "the templates hold many whites / greys / blacks, all untouched: " .. totalNeutral)
	-- the same result as asking the template for that colour (opts.from = the template's main colour)
	for _, key in { "HEAL", "FIRE_EXPLOSION", "POWER_AURA", "FREEZE" } do
		local tpl
		for _, candidate in Editor.TEMPLATES do
			if candidate.key == key then
				tpl = candidate
			end
		end
		local viaTemplate = Editor.newFromTemplate("Via " .. key, key, { color = red })
		local viaRecolor = Editor.newFromTemplate("Rec " .. key, key)
		Editor.recolorEffect(viaRecolor, red, { from = tpl.main })
		local a, b = allColors(viaTemplate), allColors(viaRecolor)
		local worst = 0
		for i = 1, #a do
			worst = math.max(worst, Editor.colorDistance(a[i][1], b[i][1]))
		end
		check(#a == #b and worst < 0.006, string.format("%s: recolouring an effect = building the template in that colour (worst distance %.4f)", key, worst))
		Editor.removeEffect(viaTemplate)
		Editor.removeEffect(viaRecolor)
	end
	-- attributes: the end colour of 3D pieces and the flash of the camera
	local slam = Editor.newFromTemplate("Atribute", "FIRE_EXPLOSION")
	local flashBefore
	for _, el in Editor.elements(slam) do
		if Editor.kindOf(el) == "CAMERA" then
			flashBefore = el:GetAttribute("LC_Flash")
		end
	end
	Editor.recolorEffect(slam, Color3.fromRGB(40, 90, 255))
	for _, el in Editor.elements(slam) do
		if Editor.kindOf(el) == "CAMERA" then
			local h = hsv(el:GetAttribute("LC_Flash"))
			check(flashBefore ~= el:GetAttribute("LC_Flash") and h > 200 and h < 250, "the camera flash turned blue: " .. fmt(el:GetAttribute("LC_Flash")))
		elseif Editor.kindOf(el) == "MESH" and typeof(el:GetAttribute("LC_ColorEnd")) == "Color3" then
			local h = hsv(el:GetAttribute("LC_ColorEnd"))
			check(h > 190 and h < 260, "the end colour of " .. el.Name .. " turned blue: " .. fmt(el:GetAttribute("LC_ColorEnd")))
		end
	end
	check(planOf(slam) ~= nil and Editor.length(slam) > 0, "still plays")
	-- hex input and several targets
	local fx = Editor.newFromTemplate("Hex", "HEAL")
	local _, info = Editor.recolorEffect(fx, "#0000FF")
	check(info.changed > 0 and info.to[1] == Color3.fromRGB(0, 0, 255), "hex string")
	local h = meanHue(fx)
	check(h > 220 and h < 260, "blue from hex: " .. h)
	-- an effect that is only white / grey / black has nothing to recolour
	local grey = Editor.newEffect("Gri", { duration = 1 })
	Editor.addElement(grey, "SPARKLES", { color = { Color3.new(1, 1, 1), Color3.fromRGB(128, 128, 128) } })
	Editor.addElement(grey, "SMOKE", { color = { Color3.fromRGB(20, 18, 24), Color3.fromRGB(60, 60, 60) } })
	local greyBefore = allColors(grey)
	local _, greyInfo = Editor.recolorEffect(grey, red)
	check(greyInfo.neutral == true and greyInfo.changed == 0, "greys are left alone")
	local gcolors = allColors(grey)
	check(#gcolors == #greyBefore and #gcolors >= 4, "four grey colours")
	for i, entry in greyBefore do
		check(gcolors[i][1] == entry[1], "...exactly: " .. fmt(entry[1]))
	end
	check(history.active == nil, "recording closed")
	-- two targets: the heavier hue group goes to the first, the other to the second
	local duo = Editor.newEffect("Duo", { duration = 1 })
	Editor.addElement(duo, "SPARKLES", { name = "Portocaliu 1", color = Color3.fromRGB(255, 140, 0) })
	Editor.addElement(duo, "SPARKLES", { name = "Portocaliu 2", color = Color3.fromRGB(255, 150, 20) })
	Editor.addElement(duo, "SPARKLES", { name = "Albastru", color = Color3.fromRGB(0, 120, 255) })
	local _, duoInfo = Editor.recolorEffect(duo, { Color3.fromRGB(0, 220, 0), Color3.fromRGB(255, 0, 200) })
	local byName = {}
	for _, el in Editor.elements(duo) do
		byName[el.Name] = el.Color.Keypoints[1].Value
	end
	local g, m = hsv(byName["Portocaliu 1"]), hsv(byName["Albastru"])
	check(duoInfo.changed == 3 and #duoInfo.from == 2, "two groups found")
	check(g > 100 and g < 140 and m > 290 and m < 330, string.format("orange -> green (%.0f), blue -> magenta (%.0f)", g, m))
	check(hueGap(hsv(byName["Portocaliu 1"]), hsv(byName["Portocaliu 2"])) < 12, "the oranges stay together")
	-- one target: everything turns by the same angle
	local trio = Editor.newEffect("Trio", { duration = 1 })
	Editor.addElement(trio, "SPARKLES", { name = "A", color = Color3.fromRGB(255, 0, 0) })
	Editor.addElement(trio, "SPARKLES", { name = "B", color = Color3.fromRGB(255, 255, 0) })
	Editor.addElement(trio, "SPARKLES", { name = "C", color = Color3.fromRGB(255, 0, 0) })
	Editor.recolorEffect(trio, Color3.fromRGB(0, 0, 255))
	local aHue = hsv(Editor.elements(trio)[1].Color.Keypoints[1].Value)
	local bHue = hsv(Editor.elements(trio)[2].Color.Keypoints[1].Value)
	check(aHue > 230 and aHue < 250 and hueGap(bHue, aHue) > 40 and hueGap(bHue, aHue) < 80, string.format("the yellow keeps its distance from the red: %.0f / %.0f", aHue, bHue))
	-- bad input
	t.throws(function()
		Editor.recolorEffect(fx, "rosu")
	end, "culoare", "a name is not a colour")
	t.throws(function()
		Editor.recolorEffect(fx, {})
	end, "culoare", "empty list")
	t.throws(function()
		Editor.recolorEffect(fx, 5)
	end, "culoare", "a number")
	t.throws(function()
		Editor.recolorEffect("Nu exista", red)
	end, "nu există efectul", "unknown effect")
	check(history.active == nil, "no recording left open")
	clearEffects()
end)

t.section("matchPalette", function()
	clearEffects()
	for _, name in { "forest", "desert", "ocean", "night" } do
		local palette = PALETTES[name]
		local fx = Editor.newFromTemplate("Pe " .. name, "FIRE_EXPLOSION")
		local steps = #history.log
		local color, reason, info = Editor.matchPalette(fx, palette)
		local best = Editor.suggestColors(palette, { count = 5 })[1]
		check(color == best.color and reason == best.reason and typeof(color) == "Color3" and #reason > 25, name .. ": the first suggestion")
		check(info.changed > 0 and #history.log == steps + 1 and history.log[#history.log] == "Commit", name .. ": recoloured in one undo step")
		local h = meanHue(fx)
		check(hueGap(h, (hsv(color))) < 35, string.format("%s: the effect now has the chosen hue (%.0f vs %.0f)", name, h, (hsv(color))))
		for _, entry in palette do
			if entry.share >= 8 then
				check(Editor.colorDistance(color, Color3.fromHex(entry.hex)) >= 0.14, name .. ": the chosen colour is not a colour of the map")
			end
		end
		Editor.removeEffect(fx)
	end
	local fx = Editor.newFromTemplate("Alt", "LIGHTNING")
	local second = Editor.suggestColors(PALETTES.forest, { count = 5 })[2]
	local color = Editor.matchPalette(fx, PALETTES.forest, { pick = 2 })
	check(color == second.color, "pick = 2 takes the second suggestion")
	check(Editor.matchPalette(fx, PALETTES.forest, { pick = 99 }) == Editor.suggestColors(PALETTES.forest, { count = 5 })[5].color, "pick is limited to 5")
	t.throws(function()
		Editor.matchPalette(fx, {})
	end, "paleta hărții e goală", "empty palette")
	clearEffects()
end)

t.section("scaleEffect", function()
	clearEffects()
	local fx = Editor.newFromTemplate("Scara", "GROUND_SLAM")
	local ref = Editor.newFromTemplate("Scara cu 2", "GROUND_SLAM", { scale = 2 })
	local steps = #history.log
	check(Editor.scaleEffect(fx, 2) == fx, "returns the effect")
	check(#history.log == steps + 1 and history.log[#history.log] == "Commit", "one undo step")
	-- the same as baking the scale into the template (sizes, distances, speeds, light range and keys)
	local mine, theirs = {}, {}
	for _, el in Editor.elements(fx) do
		mine[el.Name] = Editor.read(el)
	end
	for _, el in Editor.elements(ref) do
		theirs[el.Name] = Editor.read(el)
	end
	local compared = 0
	for name, a in mine do
		local b = theirs[name]
		check(b ~= nil and a.kind == b.kind, "element " .. name)
		if b then
			for _, key in { "position", "size", "speed", "partSize", "acceleration", "radius", "Range", "rise" } do
				-- (a template leaves its default sound / camera position where it is; scaleEffect moves it with the rest)
				if a[key] ~= nil and not (key == "position" and (a.kind == "SOUND" or a.kind == "CAMERA")) then
					compared += 1
					local fa, fb = fmt(a[key]), fmt(b[key])
					check(fa == fb, string.format("%s.%s: scaled %s, baked %s", name, key, fa, fb))
				end
			end
			if a.keys then
				for i, key in a.keys do
					check(math.abs(key[3] - b.keys[i][3]) < 1e-3 and math.abs(key[2] - b.keys[i][2]) < 1e-6, name .. ": light keys")
				end
			end
		end
	end
	check(compared > 20, "many values compared: " .. compared)
	-- smaller, then back
	local sized = Editor.newFromTemplate("Rotund", "DASH")
	local code = Editor.exportEffect(sized)
	Editor.scaleEffect(sized, 0.5)
	check(Editor.exportEffect(sized) ~= code, "scaling changed it")
	Editor.scaleEffect(sized, 2)
	local back = Editor.unpackCode(Editor.exportEffect(sized))
	local orig = Editor.unpackCode(code)
	check(#back.fx.e == #orig.fx.e, "halved and doubled: same elements")
	for _, bad in { 0, -1, 0.01, 21, "2" } do
		t.throws(function()
			Editor.scaleEffect(fx, bad)
		end, "scara", "scale " .. tostring(bad))
	end
	clearEffects()
end)

t.section("makeVariants", function()
	clearEffects()
	local fx = Editor.newFromTemplate("Foc", "FIRE_EXPLOSION")
	local steps, count = #history.log, #Editor.effects()
	local list = Editor.makeVariants(fx, { count = 3 })
	check(#list == 3 and #Editor.effects() == count + 3, "three variants")
	check(#history.log == steps + 1 and history.log[#history.log] == "Commit", "one undo step")
	local names, hues = { [fx.Name] = true }, {}
	for i, v in list do
		check(typeof(v) == "Instance" and v.Parent == fx.Parent and v ~= fx, "variant " .. i .. " is a new effect in the same folder")
		check(not names[v.Name] and string.sub(v.Name, 1, 4) == "Foc ", "unique name " .. v.Name)
		names[v.Name] = true
		hues[i] = meanHue(v)
		check(#Editor.elements(v) == #Editor.elements(fx) and v:GetAttribute("LC_Duration") == fx:GetAttribute("LC_Duration"), "same elements")
	end
	local base = meanHue(fx)
	check(math.abs(hueGap(hues[1], base) - 90) < 25 and math.abs(hueGap(hues[2], base) - 180) < 25, string.format("hues %.0f %.0f %.0f from %.0f", hues[1], hues[2], hues[3], base))
	check(hueGap(hues[1], hues[2]) > 60 and hueGap(hues[2], hues[3]) > 60, "different colours")
	check(meanHue(fx) == base and Editor.exportEffect(fx) == Editor.exportEffect("Foc"), "the original is untouched")
	-- the names come from the colours; a second round gets numbers
	local again = Editor.makeVariants(fx, { count = 3 })
	for i, v in again do
		check(not names[v.Name], "second round, still unique: " .. v.Name)
		names[v.Name] = true
	end
	-- explicit colours and names, growing size
	local custom = Editor.makeVariants(fx, { colors = { Color3.fromRGB(0, 200, 0), "#4060FF" }, names = { "Comun", "Rar" }, scale = 1.5 })
	check(#custom == 2 and custom[1].Name == "Comun" and custom[2].Name == "Rar", "given names")
	local h1, h2 = meanHue(custom[1]), meanHue(custom[2])
	check(h1 > 90 and h1 < 150 and h2 > 215 and h2 < 250, string.format("given colours: %.0f / %.0f", h1, h2))
	local function particleSize(effect)
		for _, el in Editor.elements(effect) do
			if Editor.kindOf(el) == "PARTICLES" then
				return Editor.read(el).size[2], el.Name
			end
		end
	end
	local s0 = particleSize(fx)
	check(math.abs(particleSize(custom[1]) / s0 - 1.5) < 1e-3 and math.abs(particleSize(custom[2]) / s0 - 2.25) < 1e-3, "each variant is 1.5x bigger than the one before")
	local steps2 = #history.log
	local taken = Editor.makeVariants(fx, { colors = { Color3.fromRGB(0, 200, 0) }, names = { "Comun" } })
	check(taken[1].Name == "Comun 2" and #history.log == steps2 + 1, "a taken name gets a number")
	-- an element of a variant can be edited without touching the original
	for _, el in Editor.elements(list[1]) do
		if Editor.kindOf(el) == "PARTICLES" then
			Editor.setProps(el, { Rate = 123 })
		end
	end
	check(Editor.exportEffect(fx) == Editor.exportEffect("Foc"), "independent copies")
	-- variants survive a round trip
	roundTrip(list[2], "variant")
	-- bad input
	t.throws(function()
		Editor.makeVariants(fx, { count = 0 })
	end, "între 1 și 12", "0 variants")
	t.throws(function()
		Editor.makeVariants(fx, { count = 13 })
	end, "între 1 și 12", "13 variants")
	t.throws(function()
		Editor.makeVariants(fx, { count = 3, scale = 5 })
	end, "scara variantelor", "scale that grows past the limit")
	t.throws(function()
		Editor.makeVariants(fx, { colors = { "nu" } })
	end, "culoare", "bad colour")
	local grey = Editor.newEffect("Alb", { duration = 1 })
	Editor.addElement(grey, "SPARKLES", { color = Color3.new(1, 1, 1) })
	local effectsBefore = #Editor.effects()
	t.throws(function()
		Editor.makeVariants(grey, { count = 2 })
	end, "nu are culori de schimbat", "a white effect has no colours to vary")
	check(#Editor.effects() == effectsBefore and history.active == nil, "nothing created")
	clearEffects()
end)

t.finish()
