-- VFX runtime (Editor/VFX.luau, the player) and the Editor's newer element kinds, on the typed Roblox mock with a fake
-- clock: templates build with sound / camera / beam elements, the shared Heartbeat scheduler, cached plans and pools,
-- quality / speed / distance / cap, sounds, beams, the camera shake / FOV / flash, pause / resume / stop, the Editor API for
-- the new kinds and the VFX panel (every kind renders, its controls apply).
local LC = ...
local t = LC.kit.new("vfx_runtime")
local ENV = LC.run("tests/mocks/vfx_env.luau", nil, LC)
local M = ENV.__M
local SRC = {
	NEW_VFX = LC.files["LostCube/Editor/VFX.luau"], EDITOR = LC.files["LostCube/Editor/init.luau"],
	PANEL = LC.files["LostCube/VFXPanel.luau"],
}
local Vector3, CFrame, Color3, NumberRange, NumberSequence, ColorSequence, Enum, Instance, typeof =
	ENV.Vector3, ENV.CFrame, ENV.Color3, ENV.NumberRange, ENV.NumberSequence, ENV.ColorSequence, ENV.Enum, ENV.Instance, ENV.typeof
-- LostCube VFX / Editor tests in the mock (built by tools/build.py)
local DATA = M.DATA
local failures, passes = 0, 0
local function check(cond, msg)
	if cond then
		passes += 1
	else
		failures += 1
		print("FAIL: " .. msg)
	end
end
local function expectError(fn, needle, msg)
	local ok, err = pcall(fn)
	if ok then
		failures += 1
		print("FAIL (no error): " .. msg)
	elseif needle and not string.find(tostring(err), needle, 1, true) then
		failures += 1
		print("FAIL (wrong error " .. tostring(err) .. "): " .. msg)
	else
		passes += 1
	end
end
local function near(a, b, eps)
	return math.abs(a - b) <= (eps or 1e-6)
end
local function inst(class, name, parent)
	local o = Instance.new(class)
	o.Name = name
	if parent then
		o.Parent = parent
	end
	return o
end

-- module loading ----------------------------------------------------------------------------------------------------
local REQ = {}
ENV.require = function(m)
	local r = REQ[m]
	assert(r ~= nil, "require: unknown module " .. tostring(m))
	return r
end
local function setMode(mode)
	if mode == "edit" then
		M.flags.studio, M.flags.running, M.flags.client = true, false, true
	elseif mode == "server" then
		M.flags.studio, M.flags.running, M.flags.client = false, true, false
	else
		M.flags.studio, M.flags.running, M.flags.client = false, true, true
	end
end
local pluginRoot = inst("Folder", "LostCubePlugin")
local function loadVFX(src, mode, name)
	setMode(mode)
	local holder = inst("Folder", name or "VFXHolder", pluginRoot)
	local s = inst("ModuleScript", "VFX", holder)
	local vfx = M.load(src, name or "VFX", s)
	REQ[s] = vfx
	return vfx
end
local function loadEditor(src, vfx, mode)
	setMode(mode or "edit")
	local s = inst("ModuleScript", "Editor", pluginRoot)
	local v = inst("ModuleScript", "VFX", s)
	REQ[v] = vfx
	local editor = M.load(src, "Editor", s)
	REQ[s] = editor
	return editor
end

local NEW = loadVFX(SRC.NEW_VFX, "game", "NEW")
local NEW_EDIT = loadVFX(SRC.NEW_VFX, "edit", "NEW_EDIT")
local Editor = loadEditor(SRC.EDITOR, NEW_EDIT, "edit")
print(string.format("presets: %d, templates: %d, textures: %d, sounds: %d", #Editor.PRESETS, #Editor.TEMPLATES, #Editor.TEXTURES,
	#Editor.SOUNDS))

local function run(seconds, dt)
	dt = dt or 1 / 60
	local n = math.floor(seconds / dt + 0.5)
	for _ = 1, n do
		M.frame(dt)
	end
end
local function runUntilDone(h, limit)
	local t = 0
	while not h.Done and t < (limit or 20) do
		M.frame(1 / 60)
		t += 1 / 60
	end
	return t
end
local function hbCount()
	return #M.heartbeat.conns
end

-- 1. data -------------------------------------------------------------------------------------------------------------
do
	local KINDS = { PARTICLES = true, LIGHT = true, TRAIL = true, MESH = true, SOUND = true, CAMERA = true, BEAM = true }
	local soundKeys, seen = {}, {}
	for _, s in Editor.SOUNDS do
		soundKeys[s.key] = true
		check(s.url:match("^rbxasset://sounds/[%w_]+%.%w+$") ~= nil, "sound url " .. s.url)
	end
	local textureKeys = {}
	for _, t in Editor.TEXTURES do
		textureKeys[t.key] = true
	end
	local count = {}
	for _, p in Editor.PRESETS do
		check(not seen[p.key], "duplicate preset " .. p.key)
		seen[p.key] = true
		check(KINDS[p.kind], "preset kind " .. p.key)
		check(type(p.group) == "string", "preset group " .. p.key)
		count[p.kind] = (count[p.kind] or 0) + 1
		if p.props.soundId then
			check(soundKeys[p.props.soundId], "preset sound " .. p.key)
		end
		if p.props.texture then
			check(textureKeys[p.props.texture], "preset texture " .. p.key)
		end
	end
	check((count.SOUND or 0) >= 4 and (count.CAMERA or 0) >= 4 and (count.BEAM or 0) >= 3, "several presets per new kind")
	-- the verified built-in list (rbxManifest.txt of the client tracker, content\sounds)
	local VERIFIED = { "action_falling.ogg", "action_footsteps_plastic.mp3", "action_get_up.mp3", "action_jump.mp3", "action_jump_land.mp3",
		"action_swim.mp3", "impact_explosion_03.mp3", "impact_water.mp3", "oof.ogg", "ouch.ogg", "volume_slider.ogg" }
	for _, s in Editor.SOUNDS do
		check(table.find(VERIFIED, s.url:match("sounds/(.+)$")) ~= nil, "unverified built-in sound " .. s.url)
	end
end

-- 2. every template builds (edit mode), new kinds on the combat ones ------------------------------------------------------
local templateFx = {}
do
	setMode("edit")
	for _, tpl in Editor.TEMPLATES do
		local ok, fx = pcall(Editor.newFromTemplate, "T " .. tpl.key, tpl.key)
		check(ok, "template " .. tpl.key .. ": " .. tostring(fx))
		if ok then
			templateFx[tpl.key] = fx
			check(#Editor.elements(fx) == #tpl.elements, "template element count " .. tpl.key)
		end
	end
	local function kinds(fx)
		local out = {}
		for _, e in Editor.elements(fx) do
			out[Editor.kindOf(e)] = (out[Editor.kindOf(e)] or 0) + 1
		end
		return out
	end
	for _, key in { "PUNCH", "GROUND_SLAM", "FIRE_EXPLOSION", "LIGHTNING" } do
		local k = kinds(templateFx[key])
		check(k.SOUND == 1 and k.CAMERA == 1, "camera + sound in " .. key)
	end
	check(kinds(templateFx.LIGHTNING).BEAM == 1, "lightning beam")
	-- a recoloured, scaled template: beams and camera follow
	local fx = Editor.newFromTemplate("Fulger mare", "LIGHTNING", { color = Color3.fromRGB(255, 80, 80), scale = 2 })
	for _, e in Editor.elements(fx) do
		local d = Editor.read(e)
		if d.kind == "BEAM" then
			check(near(d.start.Y, 60) and near(d.width[1], 1.2), "beam scaled with the template")
			local h = d.color[#d.color]:ToHSV()
			check(h < 0.1 or h > 0.9, "beam recoloured (hue " .. h .. ")")
		elseif d.kind == "CAMERA" then
			check(near(d.radius, 160), "camera radius scaled " .. d.radius)
			check(d.flash == Color3.new(1, 1, 1), "white flash stays white")
		end
	end
	local fire = Editor.newFromTemplate("Foc verde", "FIRE_EXPLOSION", { color = Color3.fromRGB(80, 255, 80) })
	for _, e in Editor.elements(fire) do
		local d = Editor.read(e)
		if d.kind == "CAMERA" then
			local h = d.flash:ToHSV()
			check(h > 0.2 and h < 0.45, "coloured flash follows the recolour (" .. h .. ")")
		end
	end
end

-- 4. the shared scheduler, plans, pools ------------------------------------------------------------------------------------
do
	setMode("game")
	run(10)
	check(hbCount() == 0, "no Heartbeat connection left after all effects ended (" .. hbCount() .. ")")
	local fx = templateFx.GROUND_SLAM
	NEW.invalidate()
	local handles = {}
	for i = 1, 20 do
		table.insert(handles, NEW.play(fx, CFrame.new(i, 0, 0)))
	end
	check(hbCount() == 1, "20 effects, one Heartbeat connection (" .. hbCount() .. ")")
	run(4)
	check(hbCount() == 0, "connection dropped when the last effect ended")
	for _, h in handles do
		check(h.Done and h.Model.Parent == nil, "ended and cleaned")
	end
	local stats = NEW.stats()
	check(stats.pooled > 0 and stats.pooled <= 32 * 4 and stats.plans == 1, "mesh pieces pooled (" .. stats.pooled .. ")")
	-- a second play maps the cached plan: one GetDescendants (the copy's) and fewer clones of pieces
	M.descendantsCalls = 0
	M.clones = 0
	local h = NEW.play(fx, CFrame.new(0, 0, 0))
	check(M.descendantsCalls == 1, "cached plan: one GetDescendants per play (" .. M.descendantsCalls .. ")")
	local clonesWithPool = M.clones
	runUntilDone(h)
	NEW.invalidate(fx)
	check(NEW.stats().pooled == 0, "invalidate drops the pool")
	M.clones = 0
	h = NEW.play(fx, CFrame.new(0, 0, 0))
	check(M.clones > clonesWithPool, "pieces come from the pool (clones " .. clonesWithPool .. " vs " .. M.clones .. ")")
	runUntilDone(h)

	-- the plan is cached: an edit is seen only after invalidate (games never edit effects; Studio previews always invalidate)
	local punch = templateFx.PUNCH
	local h1 = NEW.play(punch, CFrame.new())
	runUntilDone(h1)
	punch:SetAttribute("LC_Duration", 3)
	local h2 = NEW.play(punch, CFrame.new())
	local t2 = runUntilDone(h2)
	NEW.invalidate(punch)
	local h3 = NEW.play(punch, CFrame.new())
	local t3 = runUntilDone(h3)
	check(t3 > t2 + 2, "after invalidate the new duration is used (" .. t2 .. " -> " .. t3 .. ")")
	punch:SetAttribute("LC_Duration", 0.5)
	NEW.invalidate()
	-- Studio's edit mode never caches: an edit shows at once
	setMode("edit")
	local e1 = NEW_EDIT.play(punch, CFrame.new())
	local te1 = runUntilDone(e1)
	punch:SetAttribute("LC_Duration", 2)
	local e2 = NEW_EDIT.play(punch, CFrame.new())
	local te2 = runUntilDone(e2)
	check(te2 > te1 + 1, "edit mode: edits show without invalidate")
	punch:SetAttribute("LC_Duration", 0.5)
	check(NEW_EDIT.stats().plans == 0, "edit mode keeps no plans")
	setMode("game")
	-- a copy that does not match the original (a non-Archivable part): plays from its own plan, still right
	local odd = Editor.duplicateEffect(templateFx.LANDING, "Odd")
	local extra = inst("Part", "NotSaved", odd)
	extra.Archivable = false
	local ho = NEW.play(odd, CFrame.new())
	check(not ho.Done, "plays with a non-Archivable part")
	runUntilDone(ho)
	check(ho.Done, "and ends")
	local ho2 = NEW.play(odd, CFrame.new())
	runUntilDone(ho2)
	check(ho2.Done, "second play too (per-copy plan)")
end

-- 5. quality, speed, distance, cap -------------------------------------------------------------------------------------------
do
	setMode("game")
	local fx = templateFx.GROUND_SLAM
	local function emitted(h)
		local n = 0
		for _, d in h.Model:GetDescendants() do
			if d.ClassName == "ParticleEmitter" then
				n += DATA[d].emitted or 0
			end
		end
		return n
	end
	local function maxPieces(h)
		local m = 0
		while not h.Done do
			local n = 0
			for _, c in h.Model:GetChildren() do
				if c.Name:sub(-1) == "_" then
					n += 1
				end
			end
			m = math.max(m, n)
			M.frame(1 / 60)
		end
		return m
	end
	NEW.Quality = 1
	local full = NEW.play(fx, CFrame.new())
	local e1 = emitted(full)
	local p1 = maxPieces(full)
	NEW.Quality = 0.5
	local half = NEW.play(fx, CFrame.new())
	local e2 = emitted(half)
	local p2 = maxPieces(half)
	check(e2 < e1 and e2 >= e1 * 0.4, "quality 0.5: about half the particles (" .. e1 .. " -> " .. e2 .. ")")
	check(p2 < p1, "quality 0.5: fewer 3D pieces (" .. p1 .. " -> " .. p2 .. ")")
	NEW.Quality = 0.01
	local tiny = NEW.play(templateFx.PUNCH, CFrame.new())
	run(0.3)
	for _, d in tiny.Model:GetDescendants() do
		if d.ClassName == "ParticleEmitter" and d:GetAttribute("LC_Bursts") then
			check((DATA[d].emitted or 0) >= 1, "a burst never drops to 0 particles")
		end
	end
	runUntilDone(tiny)
	NEW.Quality = 1
	-- quality from the graphics level
	M.userGameSettings.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1
	local q1 = loadVFX(SRC.NEW_VFX, "game", "Q1")
	check(near(q1.Quality, 0.25), "graphics level 1 -> quality 0.25 (" .. q1.Quality .. ")")
	M.userGameSettings.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel10
	M.qualitySignal.Fire()
	check(near(q1.Quality, 1), "follows the graphics slider")
	M.userGameSettings.SavedQualityLevel = nil
	M.qualitySignal.Fire()

	-- speed 2: particles really go faster (TimeScale stays 1: the mock rejects more)
	local sp = NEW.play(templateFx.SPARKLE_TEST or templateFx.TELEPORT, CFrame.new(), { speed = 2 })
	for _, d in sp.Model:GetDescendants() do
		if d.ClassName == "ParticleEmitter" then
			local tplEm = templateFx.TELEPORT:FindFirstChild(d.Name, true)
			if tplEm and tplEm.ClassName == "ParticleEmitter" then
				check(d.TimeScale == 1, "speed 2: TimeScale 1")
				check(near(d.Lifetime.Max, tplEm.Lifetime.Max / 2, 1e-4), "speed 2: lifetime halved " .. d.Name)
				check(near(d.Speed.Max, tplEm.Speed.Max * 2, 1e-4), "speed 2: speed doubled " .. d.Name)
				check(near(d.Acceleration.Y, tplEm.Acceleration.Y * 4, 1e-4), "speed 2: acceleration x4 " .. d.Name)
			end
		end
	end
	local tFast = runUntilDone(sp)
	local tNormal = runUntilDone(NEW.play(templateFx.TELEPORT, CFrame.new()))
	check(near(tFast, tNormal / 2, 0.1), "speed 2 ends twice as fast (" .. tFast .. " / " .. tNormal .. ")")

	-- far from the camera: skipped, the handle is Done and usable
	M.clones = 0
	local far = NEW.play(fx, CFrame.new(5000, 0, 0))
	check(far.Done and M.clones == 0, "far effect skipped without a clone")
	far:Stop()
	far:Pause()
	far:Resume()
	far:Destroy()
	check(typeof(far.Model) == "Instance" and far.Model.ClassName == "Model", "skipped handle still has a Model")
	NEW.MaxDistance = nil
	local farOk = NEW.play(fx, CFrame.new(5000, 0, 0))
	check(not farOk.Done, "MaxDistance = nil: plays anywhere")
	farOk:Destroy()
	NEW.MaxDistance = 300
	setMode("server")
	local srv = loadVFX(SRC.NEW_VFX, "server", "SRV")
	local hs = srv.play(fx, CFrame.new(5000, 0, 0))
	check(not hs.Done, "the server never culls by distance")
	hs:Destroy()
	setMode("game")

	-- cap: the oldest stop
	NEW.MaxActive = 5
	local list = {}
	for i = 1, 12 do
		table.insert(list, NEW.play(templateFx.POWER_AURA, CFrame.new(i, 0, 0)))
	end
	local running, live = 0, 0
	for _, h in list do
		if not h.Done then
			live += 1
			if not h.stopAt then
				running += 1
			end
		end
	end
	check(running <= 5 and live <= 10, "MaxActive 5: running " .. running .. ", live " .. live)
	check(not list[12].stopAt and not list[12].Done, "the newest keeps playing")
	NEW.MaxActive = 60
	run(8)
end

-- 6. sounds ----------------------------------------------------------------------------------------------------------------
do
	setMode("game")
	local fx = Editor.newEffect("Sunete", { duration = 0.4 })
	local hit = Editor.addElement(fx, "SOUND_HIT")
	local heavy = Editor.addElement(fx, "SOUND_HEAVY")
	local whoosh = Editor.addElement(fx, "SOUND_WHOOSH")
	check(Editor.kindOf(hit) == "SOUND" and hit.Parent.ClassName == "Attachment", "sound under an attachment")
	M.soundPlays = 0
	local h = NEW.play(fx, CFrame.new())
	check(M.soundPlays == 1 + 2 + 1, "plays at t = 0: hit 1, heavy 2 overlapping, whoosh loop (" .. M.soundPlays .. ")")
	local function soundIn(model, name)
		for _, d in model:GetDescendants() do
			if d.ClassName == "Sound" and d.Name == name then
				return d
			end
		end
		return nil
	end
	local function find(name)
		return soundIn(h.Model, name)
	end
	local s = find(hit.Name)
	check(s.PlaybackSpeed >= 0.85 and s.PlaybackSpeed <= 1.05, "random pitch in range " .. s.PlaybackSpeed)
	local copies = 0
	for _, d in h.Model:GetDescendants() do
		if d.ClassName == "Sound" and d.Name == heavy.Name then
			copies += 1
		end
	end
	check(copies == 2, "an overlapping play is a copy (" .. copies .. ")")
	local w = find(whoosh.Name)
	check(w.Looped and w.IsPlaying, "window: looped")
	run(0.1)
	check(near(w.Volume, 0.6, 1e-6), "faded in to its volume " .. w.Volume)
	run(0.25) -- window ends at 0.3, fade 0.12
	check(w.Volume < 0.6, "fading out")
	run(0.2)
	check(not w.IsPlaying and near(w.Volume, 0.6), "stopped after the fade, volume restored")
	-- the one-shots ring on after the effect's own end (mock sounds last 1.2 s / pitch)
	local t = 0.55
	while not h.Done and t < 8 do
		M.frame(1 / 60)
		t += 1 / 60
	end
	check(h.Done and t > 1.0 and t < 3.5, "cleaned when the sounds ended (" .. t .. " s)")
	-- pause / resume pause the sounds
	local h2 = NEW.play(fx, CFrame.new())
	h2:Pause()
	local paused = 0
	for _, d in h2.Model:GetDescendants() do
		if d.ClassName == "Sound" and DATA[d].paused then
			paused += 1
		end
	end
	check(paused == 4, "pause pauses every playing sound (" .. paused .. ")")
	run(1)
	h2:Resume()
	local s2 = soundIn(h2.Model, hit.Name)
	check(s2.IsPlaying, "resumed")
	h2:Destroy()
	check(not s2.IsPlaying, "destroyed: silent")
	-- a looping sound stops (fades) on Stop()
	local loopFx = Editor.newEffect("Buclă", { duration = 3 })
	Editor.addElement(loopFx, "SOUND", { name = "Zumzet", window = { 0, 3 }, fade = 0.2 })
	local hl = NEW.play(loopFx, CFrame.new())
	run(0.5)
	hl:Stop()
	run(0.3)
	local snd = hl.Done and nil or soundIn(hl.Model, "Zumzet")
	check(hl.Done or (snd and not snd.IsPlaying), "Stop(): the loop fades out")
	runUntilDone(hl)
	check(hl.Done, "and the effect ends")
end

-- 7. beams -----------------------------------------------------------------------------------------------------------------
do
	setMode("game")
	local fx = Editor.newEffect("Raze", { duration = 1 })
	local bolt = Editor.addElement(fx, "LIGHTNING_BEAM")
	local laser = Editor.addElement(fx, "LASER")
	check(bolt.Attachment0.Name == bolt.Name .. "_Start" and bolt.Attachment1.Name == bolt.Name .. "_End", "beam ends named")
	local h = NEW.play(fx, CFrame.new())
	local b = h.Model:FindFirstChild(bolt.Name, true)
	local l = h.Model:FindFirstChild(laser.Name, true)
	check(b.Enabled, "flash at t = 0")
	check(not l.Enabled, "window: starts invisible (fade in)")
	local end0 = b.Attachment1.Position
	check(end0.Magnitude > 0 and end0.Magnitude <= 2.5 * 1.5, "jitter moved the end point")
	M.frame(1 / 60)
	check(l.Enabled and l.Transparency.Keypoints[1].Value > 0.5, "window: fading in")
	run(0.07)
	check(b.Attachment1.Position ~= end0, "a new shape for the next flash")
	run(0.1)
	check(near(l.Transparency.Keypoints[1].Value, 0, 1e-6), "window: fully visible")
	run(0.1) -- last flash at 0.15 + 0.09
	check(not b.Enabled, "flashes over")
	run(0.45) -- off at 0.6, fade 0.06
	check(not l.Enabled, "window: gone after its fade")
	runUntilDone(h)
	check(h.Done, "beam effect ends")
	-- a beam without a LostCube timeline is left alone (as before)
	local plain = Editor.newEffect("Beam simplu", { duration = 0.3 })
	local root = plain.PrimaryPart
	local a0, a1 = inst("Attachment", "A", root), inst("Attachment", "B", root)
	local raw = inst("Beam", "Raw", root)
	raw.Attachment0, raw.Attachment1 = a0, a1
	local hp = NEW.play(plain, CFrame.new())
	check(hp.Model:FindFirstChild("Raw", true).Enabled, "untimed beam untouched")
	runUntilDone(hp)
end

-- 8. camera --------------------------------------------------------------------------------------------------------------------
do
	local cam = M.camera
	-- the camera scripts of a game: they rebuild the camera every frame and read its LookVector (like ClassicCamera)
	local state = { focus = Vector3.new(0, 5, 0), dist = 14 }
	local function cameraScript(c)
		local look = c.CFrame.LookVector
		local yaw = math.atan2(-look.X, -look.Z)
		local pitch = math.asin(math.clamp(look.Y, -1, 1))
		state.yaw, state.pitch = yaw, pitch
		c.CFrame = CFrame.new(state.focus) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0) * CFrame.new(0, 0, state.dist)
	end
	setMode("game")
	cam.CFrame = CFrame.new(state.focus) * CFrame.Angles(0, 0.3, 0) * CFrame.Angles(-0.2, 0, 0) * CFrame.new(0, 0, 14)
	cam.FieldOfView = 70
	M.cameraScript = cameraScript
	run(0.2)
	local before = cam.CFrame
	local fx = Editor.newEffect("Cameră", { duration = 0.6 })
	local kick = Editor.addElement(fx, "IMPACT_CAMERA")
	Editor.setProps(kick, { flash = Color3.new(1, 1, 1), flashAlpha = 0.6, flashTime = 0.2 })
	local h = NEW.play(fx, CFrame.new(0, 0, 0))
	check(#M.renderBinds == 2, "camera: two render steps bound (" .. #M.renderBinds .. ")")
	M.frame(1 / 60)
	M.frame(1 / 60)
	local moved = not (cam.CFrame == before)
	check(moved, "camera shakes")
	check(cam.FieldOfView > 70, "FOV punch")
	local cc = cam:FindFirstChildOfClass("ColorCorrectionEffect")
	check(cc and cc.Brightness > 0 and cc.Archivable == false, "flash on the camera")
	run(0.6)
	check(#M.renderBinds == 0, "render steps unbound after the kick")
	check(cam:FindFirstChildOfClass("ColorCorrectionEffect") == nil, "flash removed")
	check(cam.FieldOfView == 70, "FOV exactly back (" .. cam.FieldOfView .. ")")
	run(0.1)
	local after = cam.CFrame
	check((after.Position - before.Position).Magnitude < 1e-4 and after.LookVector:Dot(before.LookVector) > 0.9999999,
		"no drift: the camera scripts never saw the shake (" .. (after.Position - before.Position).Magnitude .. ")")
	runUntilDone(h)
	-- far away (outside its radius): nothing
	local h2 = NEW.play(fx, CFrame.new(0, 0, 200))
	M.frame(1 / 60)
	check(#M.renderBinds == 0 and cam.FieldOfView == 70, "outside the radius: camera untouched")
	runUntilDone(h2)
	-- the camera = false option, and the server
	local h3 = NEW.play(fx, CFrame.new(), { camera = false })
	M.frame(1 / 60)
	check(#M.renderBinds == 0, "camera = false: untouched")
	runUntilDone(h3)
	setMode("server")
	local srv = loadVFX(SRC.NEW_VFX, "server", "SRV2")
	local h4 = srv.play(fx, CFrame.new())
	M.frame(1 / 60)
	check(#M.renderBinds == 0 and cam.FieldOfView == 70, "server: no camera effects")
	runUntilDone(h4)
	setMode("game")
	-- rumble window + Destroy in the middle
	local rum = Editor.newEffect("Cutremur", { duration = 2 })
	Editor.addElement(rum, "RUMBLE", { window = { 0, 2 } })
	local hr = NEW.play(rum, CFrame.new())
	run(0.5)
	check(#M.renderBinds == 2, "rumble running")
	hr:Destroy()
	run(0.05)
	check(#M.renderBinds == 0, "destroyed: camera released")
	run(0.1)
	check((cam.CFrame.Position - before.Position).Magnitude < 1e-4, "and back where the scripts put it")
	M.cameraScript = nil

	-- Studio's edit mode: the static Studio camera is put back EXACTLY (same CFrame, same FOV)
	setMode("edit")
	cam.CFrame = CFrame.new(10, 8, 20) * CFrame.Angles(-0.3, 0.6, 0)
	cam.FieldOfView = 70
	local studioBefore = cam.CFrame
	local he = NEW_EDIT.play(fx, CFrame.new(0, 0, 0))
	check(#M.renderBinds == 0, "edit mode: no render steps (Heartbeat)")
	M.frame(1 / 60)
	M.frame(1 / 60)
	check(not (cam.CFrame == studioBefore), "edit mode: the preview shakes the Studio camera")
	runUntilDone(he)
	run(0.1)
	check(cam.CFrame == studioBefore, "edit mode: Studio camera exactly restored")
	check(cam.FieldOfView == 70, "edit mode: FOV exactly restored")
	check(hbCount() == 0, "edit mode: Heartbeat released")
	-- the user moves the Studio camera during the shake: their move stays, our shake goes
	local he2 = NEW_EDIT.play(fx, CFrame.new(0, 0, 0))
	run(0.05)
	cam.CFrame = cam.CFrame + Vector3.new(5, 0, 0)
	runUntilDone(he2)
	run(0.1)
	local expected = studioBefore + Vector3.new(5, 0, 0)
	check((cam.CFrame.Position - expected.Position).Magnitude < 0.05 and cam.CFrame.LookVector:Dot(expected.LookVector) > 0.9999,
		"edit mode: the user's move is kept, the shake removed (" .. (cam.CFrame.Position - expected.Position).Magnitude .. ")")
	-- Pause in a preview: the camera stays clean while paused
	cam.CFrame = studioBefore
	local hp = NEW_EDIT.play(fx, CFrame.new(0, 0, 0))
	run(0.05)
	hp:Pause()
	run(0.1)
	check(cam.CFrame == studioBefore, "paused preview: camera clean")
	hp:Resume()
	runUntilDone(hp)
	run(0.1)
	check(cam.CFrame == studioBefore, "after resume + end: exact")
	-- "not in Studio previews"
	Editor.setProps(kick, { studio = false })
	check(kick:GetAttribute("LC_Studio") == false and Editor.read(kick).studio == false, "studio toggle stored")
	local hn = NEW_EDIT.play(fx, CFrame.new(0, 0, 0))
	M.frame(1 / 60)
	check(cam.CFrame == studioBefore and cam.FieldOfView == 70, "LC_Studio = false: preview leaves the camera alone")
	runUntilDone(hn)
	Editor.setProps(kick, { studio = true })
	check(kick:GetAttribute("LC_Studio") == nil, "studio = true clears the attribute")
	setMode("game")
end

-- 9. pause / resume / stop of the classic elements still work -----------------------------------------------------------------
do
	setMode("game")
	local h = NEW.play(templateFx.POWER_AURA, CFrame.new())
	run(0.5)
	h:Pause()
	local frozen = true
	for _, d in h.Model:GetDescendants() do
		if d.ClassName == "ParticleEmitter" and d.TimeScale ~= 0 then
			frozen = false
		end
	end
	check(frozen, "pause: TimeScale 0")
	run(5)
	check(not h.Done, "paused effects do not end")
	h:Resume()
	for _, d in h.Model:GetDescendants() do
		if d.ClassName == "ParticleEmitter" then
			check(d.TimeScale == 1, "resume: TimeScale back")
			break
		end
	end
	local t = runUntilDone(h)
	check(h.Done and t > 2 and t < 4, "resumed effect finishes its time (" .. t .. ")")
end

-- 10. Editor API for the new kinds --------------------------------------------------------------------------------------------------
do
	setMode("edit")
	local ss = M.services.ServerStorage
	local sessionBefore = ss:FindFirstChild("LostCubeSession")
	if sessionBefore then
		sessionBefore:Destroy()
	end
	local hist = Editor.history()
	check(type(hist) == "table" and #hist == 0 and ss:FindFirstChild("LostCubeSession") == nil, "history() does not create the session folder")

	local fx = Editor.newEffect("Nou", { duration = 1 })
	check(ss:FindFirstChild("LostCubeSession") ~= nil, "recorded edits still log")
	local snd = Editor.addElement(fx, "SOUND")
	local cfg = Editor.addElement(fx, "CAMERA")
	local beam = Editor.addElement(fx, "BEAM")
	check(snd.Name == "Sunet" and cfg.Name == "Cameră" and beam.Name == "Rază", "default names")
	check(Editor.kindOf(snd) == "SOUND" and Editor.kindOf(cfg) == "CAMERA" and Editor.kindOf(beam) == "BEAM", "kindOf")
	check(snd:GetAttribute("LC_Bursts") == "0:1" and cfg:GetAttribute("LC_Bursts") == "0:1" and beam:GetAttribute("LC_On") == "0,0.5",
		"empty elements start with a timeline")
	local snd2 = Editor.addElement(fx, "SOUND")
	check(snd2.Name == "Sunet 2", "uniqueName")
	-- read / set
	local d = Editor.read(snd)
	check(d.sound == "HIT" and d.pitch[1] == 0.95 and d.pitch[2] == 1.05, "read sound")
	Editor.setProps(snd, { soundId = 12345, pitch = { 0.8, 1.2 }, Volume = 0.4, RollOffMaxDistance = 90, fade = 0.3 })
	d = Editor.read(snd)
	check(d.soundId == "rbxassetid://12345" and d.sound == "CUSTOM" and d.pitch[2] == 1.2 and d.Volume == 0.4 and d.fade == 0.3,
		"set sound props")
	Editor.setProps(snd, { soundId = "EXPLOSION" })
	check(Editor.read(snd).sound == "EXPLOSION", "sound by key")
	Editor.setProps(snd, { soundId = "rbxassetid://777" })
	check(snd.SoundId == "rbxassetid://777", "sound by url")
	Editor.setProps(cfg, { shake = 1.5, frequency = 20, shakeTime = 0.5, fov = -4, fovTime = 0.2, flash = Color3.new(1, 0, 0),
		flashAlpha = 0.7, flashTime = 0.3, radius = 40 })
	d = Editor.read(cfg)
	check(d.shake == 1.5 and d.frequency == 20 and d.shakeTime == 0.5 and d.fov == -4 and d.fovTime == 0.2 and d.flash == Color3.new(1, 0, 0)
		and d.flashAlpha == 0.7 and d.flashTime == 0.3 and d.radius == 40 and d.studio == true, "camera props")
	Editor.setProps(cfg, { flash = false, shake = 0 })
	check(Editor.read(cfg).flash == nil and cfg:GetAttribute("LC_Shake") == nil, "flash off, shake 0")
	expectError(function()
		Editor.setProps(cfg, { Bogus = 1 })
	end, "nu are proprietatea", "unknown camera prop")
	Editor.setProps(beam, { start = Vector3.new(1, 2, 3), finish = Vector3.new(4, 5, 6), width = { 1, 0.5 }, curve = { 2, -2 },
		Segments = 20, texture = "SPARKLES", TextureMode = "Wrap", TextureSpeed = 2, TextureLength = 3, color = { Color3.new(1, 1, 1),
			Color3.new(0, 0, 1) }, transparency = { 0.1, 0.5 }, LightEmission = 0.5, Brightness = 2, FaceCamera = false, flashTime = 0.2,
		fade = 0.1, jitter = 1 })
	d = Editor.read(beam)
	check(d.start == Vector3.new(1, 2, 3) and d.finish == Vector3.new(4, 5, 6) and d.width[2] == 0.5 and d.curve[2] == -2
		and d.Segments == 20 and d.texture == "SPARKLES" and d.TextureMode == "Wrap" and d.FaceCamera == false and d.flashTime == 0.2
		and d.fade == 0.1 and d.jitter == 1 and #d.color == 2, "beam props")
	check(Editor.position(beam) == Vector3.new(1, 2, 3), "beam position = its start")
	Editor.setProps(beam, { position = Vector3.new(0, 0, 0) })
	d = Editor.read(beam)
	check(d.start == Vector3.new(0, 0, 0) and d.finish == Vector3.new(3, 3, 3), "moving a beam keeps its vector")
	Editor.setProps(beam, { name = "Laser roșu" })
	check(beam.Attachment0.Name == "Laser roșu_Start" and beam.Attachment1.Name == "Laser roșu_End", "rename beam ends")
	Editor.setProps(cfg, { name = "Zguduire" })
	check(cfg.Parent.Name == "Zguduire", "rename camera holder")
	Editor.setProps(cfg, { position = Vector3.new(0, 3, 0) })
	check(Editor.position(cfg) == Vector3.new(0, 3, 0), "camera position")
	-- duplicate
	local dupS = Editor.duplicate(snd)
	check(dupS.Parent ~= snd.Parent and dupS.Parent.ClassName == "Attachment" and dupS.SoundId == snd.SoundId
		and dupS:GetAttribute("LC_Pitch") == snd:GetAttribute("LC_Pitch"), "duplicate sound: own attachment, same settings")
	local dupC = Editor.duplicate(cfg)
	check(Editor.kindOf(dupC) == "CAMERA" and dupC.Name ~= cfg.Name and Editor.read(dupC).frequency == 20, "duplicate camera")
	local dupB = Editor.duplicate(beam)
	check(dupB.Attachment0 ~= beam.Attachment0 and dupB.Attachment0.Position == beam.Attachment0.Position
		and dupB.Attachment1.Position == beam.Attachment1.Position and dupB:GetAttribute("LC_Jitter") == 1, "duplicate beam: own ends")
	-- retime + length
	Editor.setProps(cfg, { shake = 1, bursts = { { 0.2, 1 } } })
	local before = Editor.length(fx)
	Editor.retime(fx, 2)
	check(near(cfg:GetAttribute("LC_ShakeTime"), 1) and Editor.bursts(cfg)[1][1] == 0.4 and near(beam:GetAttribute("LC_FlashTime"), 0.4)
		and near(snd:GetAttribute("LC_Fade"), 0.6), "retime scales camera / beam / sound times")
	check(Editor.length(fx) > before, "length grows")
	check(near(Editor.length(fx), 2 + 1), "length = duration + longest tail (" .. Editor.length(fx) .. ")")
	-- presets: a camera preset replaces the camera settings (not the Studio choice)
	Editor.setProps(cfg, { studio = false })
	Editor.applyPreset(cfg, "WHITE_FLASH")
	d = Editor.read(cfg)
	check(d.shake == 0 and d.fov == 0 and d.flash == Color3.new(1, 1, 1) and d.studio == false, "applyPreset on camera")
	Editor.applyPreset(snd, "SOUND_WHOOSH")
	check(snd:GetAttribute("LC_Bursts") == nil and snd:GetAttribute("LC_On") == "0,0.3", "applyPreset on sound")
	-- remove
	local beamA0 = beam.Attachment0
	Editor.remove(beam)
	check(beam.Parent == nil and beamA0.Parent == nil, "remove beam with its ends")
	local holder = snd.Parent
	Editor.remove(snd)
	check(holder.Parent == nil, "remove sound with its attachment")
	-- describe still works, elements list includes the new kinds
	local desc = Editor.describe()
	check(#desc > 0, "describe")
	-- flipbooks
	local p = Editor.addElement(fx, "SPARKLES")
	d = Editor.read(p)
	check(d.FlipbookLayout == "None" and d.FlipbookMode == "Loop" and type(d.FlipbookFramerate) == "table" and d.FlipbookStartRandom == false,
		"flipbook fields read")
	Editor.setProps(p, { FlipbookLayout = "Grid4x4", FlipbookMode = "OneShot", FlipbookFramerate = { 10, 20 }, FlipbookStartRandom = true })
	d = Editor.read(p)
	check(d.FlipbookLayout == "Grid4x4" and d.FlipbookMode == "OneShot" and d.FlipbookFramerate[2] == 20 and d.FlipbookStartRandom, "flipbook set")
	local dp = Editor.duplicate(p)
	check(dp.FlipbookLayout.Name == "Grid4x4" and dp.FlipbookStartRandom, "duplicate keeps the flipbook")
	-- preview: invalidates and plays at full quality
	NEW_EDIT.Quality = 0.3
	local h = Editor.preview(fx, { target = CFrame.new() })
	check(h.quality == 1, "preview at full quality")
	h:Destroy()
	NEW_EDIT.Quality = 1
	-- the camera / sound / beam elements play from the editor's effects (edit mode)
	local hh = Editor.preview(templateFx.LIGHTNING, { target = CFrame.new(0, 0, -10) })
	local t = runUntilDone(hh)
	check(hh.Done and t < 8, "lightning template preview ends (" .. t .. ")")
	run(0.2)
	check(hbCount() == 0 and #M.renderBinds == 0, "nothing left running")
end

-- 11. the panel (fake UI kit): every kind renders and its controls apply ----------------------------------------------------------
do
	setMode("edit")
	local C3 = Color3
	local TREE
	local function node(kind, parent, fields)
		local n = fields or {}
		n.kind, n.children, n.parent = kind, {}, parent
		n.CaptureFocus = function() end
		if parent then
			table.insert(parent.children, n)
		end
		return n
	end
	local fakeUI = { C = setmetatable({}, { __index = function()
		return C3.new()
	end }) }
	fakeUI.fmt = function(v)
		return tostring(v)
	end
	function fakeUI.label(p, text, o)
		return node("label", p, { Text = text })
	end
	function fakeUI.button(p, text, click, o)
		return node("button", p, { Text = text, click = click, opts = o or {} })
	end
	function fakeUI.hstack(p)
		return node("hstack", p)
	end
	function fakeUI.vstack(p)
		return node("vstack", p)
	end
	function fakeUI.row(p, text)
		return node("row", p, { label = text })
	end
	function fakeUI.number(p, v, f, o)
		assert(type(v) == "number", "UI.number got " .. typeof(v))
		return node("number", p, { value = v, change = f, opts = o })
	end
	function fakeUI.textbox(p, v, f, o)
		return node("textbox", p, { Text = v or "", change = f, opts = o })
	end
	function fakeUI.toggle(p, v, f, text)
		return node("toggle", p, { Text = text, change = f, value = v })
	end
	function fakeUI.segmented(p, items, v, f)
		return node("segmented", p, { items = items, value = v, change = f })
	end
	function fakeUI.dropdown(p, items, v, f, o)
		return node("dropdown", p, { items = items, value = v, change = f, opts = o })
	end
	function fakeUI.color(p, c, f)
		assert(typeof(c) == "Color3", "UI.color got " .. typeof(c))
		return node("color", p, { value = c, change = f })
	end
	function fakeUI.section(p, title, o)
		return node("section", p, { title = title, opts = o })
	end
	function fakeUI.item(p, text, o)
		return node("item", p, { Text = text, opts = o })
	end
	function fakeUI.scrollList(p)
		return node("scroll", p)
	end
	function fakeUI.note(p, text, color)
		return node("note", p, { Text = text })
	end
	function fakeUI.spacer(p)
		return node("spacer", p)
	end
	local function walk(n, fn)
		fn(n)
		for _, c in n.children do
			walk(c, fn)
		end
	end
	local function find(pred)
		local out = {}
		walk(TREE, function(n)
			if pred(n) then
				table.insert(out, n)
			end
		end)
		return out
	end
	local folder = inst("Folder", "PanelFolder")
	local uiS, instS, panelS = inst("ModuleScript", "UI", folder), inst("ModuleScript", "Installer", folder),
		inst("ModuleScript", "VFXPanel", folder)
	REQ[uiS] = fakeUI
	REQ[instS] = { status = function()
		return { ok = true }
	end, install = function() end }
	local Panel = M.load(SRC.PANEL, "VFXPanel", panelS)
	local previews = 0
	local realPreview = Editor.preview
	Editor.preview = function()
		previews += 1
		return { Done = false, Destroy = function() end, Pause = function() end, Resume = function() end }
	end
	local ctx = { Editor = Editor }
	local panel = Panel.new(ctx)
	local function render()
		TREE = node("root", nil)
		local ok, e = pcall(function()
			panel:render(TREE)
		end)
		check(ok, "render failed: " .. tostring(e))
	end
	ctx.app = { refresh = render }
	render()
	local fx = Editor.newEffect("Panou", { duration = 1 })
	panel.effect = fx
	render()
	-- the add menu: new kinds, with icons, presets grouped
	local add = find(function(n)
		return n.kind == "dropdown" and n.opts and n.opts.text == "+ Adaugă element"
	end)[1]
	local labels = {}
	for _, it in add.items do
		if not it.header then
			labels[it.value] = it.label
		end
	end
	check(labels.SOUND and labels.SOUND:find("♪", 1, true) and labels.CAMERA:find("◎", 1, true) and labels.BEAM:find("⚡", 1, true),
		"add menu: empty new kinds with icons")
	check(labels.SHAKE_HEAVY and labels.SHAKE_HEAVY:find("◎", 1, true) and labels.LASER:find("⚡", 1, true)
		and labels.SOUND_HIT:find("♪", 1, true), "add menu: presets of the new kinds with icons")
	local headers = {}
	for _, it in add.items do
		if it.header then
			headers[it.label] = true
		end
	end
	check(headers["Cameră"] and headers["Sunet"] and headers["Raze (Beam)"], "add menu: new groups")
	-- each kind: add, render, poke every control
	local errorsBefore = failures
	for _, key in { "SOUND", "CAMERA", "BEAM", "SPARKLES", "SOUND_WHOOSH", "WHITE_FLASH", "LIGHTNING_BEAM", "RUMBLE", "ENERGY_BEAM" } do
		add.change(key)
		check(panel.element ~= nil and panel.error == nil, "added " .. key .. " " .. tostring(panel.error))
		local el = panel.element
		render()
		local pokes = 0
		for _, n in find(function(n)
			return (n.kind == "number" or n.kind == "toggle" or n.kind == "segmented" or n.kind == "dropdown" or n.kind == "color")
				and n.change ~= nil
		end) do
			if n.opts and n.opts.text == "+ Adaugă element" then
				continue
			end
			panel.element = el
			if n.kind == "number" then
				n.change(n.value + (n.opts and n.opts.step or 0.1))
			elseif n.kind == "toggle" then
				n.change(not n.value)
			elseif n.kind == "segmented" then
				n.change(n.items[#n.items].value)
			elseif n.kind == "dropdown" then
				local pick
				for _, it in n.items do
					if not it.header and it.value ~= "CUSTOM" then
						pick = it.value
					end
				end
				if pick and n.opts and n.opts.placeholder ~= "alege…" then
					n.change(pick)
				end
			elseif n.kind == "color" then
				n.change(Color3.fromRGB(10, 200, 30))
			end
			pokes += 1
			check(panel.error == nil, key .. ": control error " .. tostring(panel.error) .. " (" .. tostring(n.kind) .. ")")
			panel.error = nil
		end
		check(pokes >= 6, key .. ": controls found (" .. pokes .. ")")
		-- timeline buttons
		panel.element = el
		render()
		for _, b in find(function(n)
			return n.kind == "button" and (n.Text == "+ Redare" or n.Text == "+ Lovitură" or n.Text == "+ Flash" or n.Text == "+ Burst")
		end) do
			b.click()
			check(panel.error == nil, key .. ": add burst " .. tostring(panel.error))
		end
	end
	check(failures == errorsBefore, "panel controls all applied")
	-- the sound id box and the listen button
	panel.element = Editor.addElement(fx, "SOUND")
	panel.customSound = true
	render()
	local box = find(function(n)
		return n.kind == "textbox" and n.opts and n.opts.placeholder and n.opts.placeholder:find("rbxassetid")
	end)[1]
	box.change("https://create.roblox.com/store/asset/987654/Boom")
	check(panel.element.SoundId == "rbxassetid://987654", "sound id from a store address")
	box.change("rbxasset://sounds/oof.ogg")
	check(panel.element.SoundId == "rbxasset://sounds/oof.ogg", "built-in url kept")
	local listen = find(function(n)
		return n.kind == "button" and n.Text == "▶"
	end)[1]
	listen.click()
	check(M.localSound == panel.element, "listen plays the sound in Studio")
	-- flipbook section only for particles; studio toggle text
	panel.element = Editor.addElement(fx, "CAMERA")
	render()
	check(#find(function(n)
		return n.kind == "toggle" and n.Text == "Aplică și în previzualizarea din Studio"
	end) == 1, "studio toggle")
	panel.element = Editor.addElement(fx, "SPARKLES")
	render()
	check(#find(function(n)
		return n.kind == "section" and n.title == "Flipbook (textură animată)"
	end) == 1, "flipbook section")
	Editor.preview = realPreview
end

t.passes += passes
t.fails += failures
for i = 1, math.min(#M.log, 10) do
	print("mock warning: " .. M.log[i])
end
t.finish()
