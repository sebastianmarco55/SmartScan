--[[ LostCube VFX player
Plays the effects made with LostCube (the Studio plugin's VFX tab, or the Blender exporter).

	local VFX = require(ReplicatedStorage.LostCube.VFX)
	VFX.Library = ReplicatedStorage.LostCube.Effects     -- optional: by default, the Effects folder next to this module

	VFX.play("TeleportCast", character)                  -- on a character (uses the effect's "Prins de")
	VFX.play("Boom", CFrame.new(0, 5, 0))                -- at a place
	local h = VFX.play(effect, part, { scale = 1.5, speed = 1, attach = "ROOT", parent = workspace })
	VFX.play("Scrape", character, { attach = "RIGHT_FOOT", facing = moveDirection }) -- front = facing
	h:Stop()                                             -- stop emitting; cleans up when the last particle is gone
	h:Pause() / h:Resume()                               -- freeze on the current moment (to look at it)

	VFX.bindMarkers(track, character, { Cast = "TeleportCast" })  -- play effects on animation markers

	VFX.Quality = 0.5      -- 0..1: emission rates, burst counts and 3D pieces (default: the player's graphics level)
	VFX.MaxDistance = 300  -- client: an effect farther than this from the camera is skipped (its handle is Done); nil = off
	VFX.MaxActive = 60     -- more live effects than this: the oldest ones are stopped; nil = no cap
	VFX.invalidate(effect) -- after changing an effect while the game runs (each effect is compiled once, on its first play)
	play options: scale, speed, attach, facing, parent, quality (overrides VFX.Quality), camera (false = no camera effects)

Timeline written by LostCube on each element (attributes, seconds):
	LC_On     "t0,t1;t2,t3"   continuous emission windows (ParticleEmitter / Trail)
	LC_Bursts "t:n;t:n"       Emit(n) at time t
	LC_Keys   "t,b,r;..."     PointLight Brightness + Range over time (linear between keys)
	LC_Muted  true            element switched off in the editor (not played)
3D mesh elements: a Part in the effect with LC_Mode = Ring | Crack | Pulse | Puff | Trail | Debris; the
player spawns pieces from it (same Shape / Material / Color) - LC_Rate, LC_Life "min,max", LC_Grow "g0,g1",
LC_Alpha "a0,a1", LC_ColorEnd, LC_Speed "min,max", LC_Spread "x,y", LC_Dir (Top, Back...), LC_Rise, LC_Spin,
LC_Count, LC_Radius "r0,r1", LC_Jitter, LC_Ground (sit on the floor under it).
Ground ribbons: a Trail with LC_Ground = true lies flat on the floor under the effect's root and follows its path
(its two attachments give the width and the sideways / forward offset); the texture is stretched over its length.
LC_Lift (studs above the floor, stack ribbons without z-fighting), LC_Flow (a bright band running along it, cycles/s).
Trail curves (Color / Transparency / WidthScale) are mapped by the AGE of each point (age / Lifetime), and a trail
shrinks from the tail as points reach Lifetime: to hold and fade without shrinking, Lifetime = hold + fade + margin and
Transparency reaches 1 before the end.
Sounds: a Sound under an Attachment (positional). LC_Bursts "t:n" plays it at t (n = overlapping copies), LC_On "t0,t1"
loops it from t0 to t1 (fades in quickly, out over LC_Fade s, default 0.15), LC_Pitch "min,max" = random PlaybackSpeed.
Volume / RollOffMaxDistance / SoundId are the Sound's own. A one-shot sound may outlive the effect: the effect is cleaned
up when it ends (at most 6 s later).
Camera: a Configuration with LC_Kind = "CAMERA" (under an Attachment) - only on the client, for the local camera, when the
effect is within LC_Radius studs (full strength in the inner 30%, fading to 0 at the radius). LC_Bursts = kicks at t:
shake of LC_Shake degrees at LC_Freq Hz decaying over LC_ShakeTime s, FOV punch of LC_FOV degrees over LC_FovTime s,
screen flash LC_Flash (Color3) of strength LC_FlashAlpha 0..1 over LC_FlashTime s. LC_On = a steady rumble (LC_Shake)
between t0 and t1. In Studio previews it is applied too (LC_Studio = false: not) and the camera CFrame / FOV are put back.
Beams: a Beam under Root between Attachment0 (start) and Attachment1 (end). LC_On = visible from t0 to t1 (fade in / out
over LC_Fade s, default 0.08), LC_Bursts = a flash of LC_FlashTime s (default 0.12) at t, e.g. a lightning bolt; LC_Jitter =
random studs added to the end point (and to the curve) on each flash. Beams without LC_On / LC_Bursts are left alone.
Effect (Model) attributes: LC_Duration, LC_Attach (GROUND, GROUND_FOLLOW, ROOT, TORSO, HEAD, RIGHT_HAND,
LEFT_HAND, RIGHT_FOOT, LEFT_FOOT, WORLD). Effects are meant to be played on the client (each client plays its own copy).

Performance: an effect is compiled once into a plan (parsed timeline, element lists by kind, tail); each play clones it,
maps the plan onto the copy with one GetDescendants() and sets only what differs from the template. One Heartbeat
connection drives every live effect (disconnected when none is left) and 3D mesh pieces are reused from a small pool.
In Studio's edit mode nothing is cached, so a preview always shows the latest edit.
]]
local RunService = game:GetService("RunService")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")

local VFX = {}
VFX.Library = nil :: Instance?
VFX.MaxDistance = 300 :: number?
VFX.MaxActive = 60 :: number?
VFX.PoolSize = 32 -- 3D mesh pieces kept for reuse, per mesh element of an effect

local IS_STUDIO = RunService:IsStudio()
local IS_CLIENT = RunService:IsClient()

-- the player's graphics level -> VFX.Quality (Automatic = 1, level 1 = 0.25 ... level 10 = 1)
local function graphicsQuality(): number
	local ok, level = pcall(function()
		return (UserSettings() :: any):GetService("UserGameSettings").SavedQualityLevel
	end)
	if not ok or typeof(level) ~= "EnumItem" or level.Value <= 0 then
		return 1
	end
	return math.clamp(0.25 + 0.75 * (level.Value - 1) / 9, 0.25, 1)
end
local autoQuality = graphicsQuality()
VFX.Quality = autoQuality
pcall(function() -- follows the graphics slider, unless the game set VFX.Quality itself
	local settings = (UserSettings() :: any):GetService("UserGameSettings")
	settings:GetPropertyChangedSignal("SavedQualityLevel"):Connect(function()
		local q = graphicsQuality()
		if VFX.Quality == autoQuality then
			VFX.Quality = q
		end
		autoQuality = q
	end)
end)

-- where effects named by a string are looked up: VFX.Library, else ReplicatedStorage.LostCube.Effects (installed next to us)
local function library(): Instance?
	return VFX.Library or (script.Parent and script.Parent:FindFirstChild("Effects"))
end

local PARTS = {
	ROOT = { "HumanoidRootPart" },
	TORSO = { "UpperTorso", "Torso" },
	HEAD = { "Head" },
	RIGHT_HAND = { "RightHand", "Right Arm" },
	LEFT_HAND = { "LeftHand", "Left Arm" },
}
-- the sole of the foot (R15 foot / bottom of the R6 leg): for effects that touch the ground
local FEET = {
	RIGHT_FOOT = { "RightFoot", "Right Leg" },
	LEFT_FOOT = { "LeftFoot", "Left Leg" },
}

local function parseList(s): { { number } }
	local out = {}
	if type(s) ~= "string" then
		return out
	end
	for item in string.gmatch(s, "[^;]+") do
		local values = {}
		for v in string.gmatch(item, "[^,:]+") do
			table.insert(values, tonumber(v) or 0)
		end
		table.insert(out, values)
	end
	return out
end

-- the floor under a character, facing where it faces
local function groundCFrame(character: Model): (CFrame, BasePart?)
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return character:GetPivot(), nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local drop = root.Size.Y / 2 + 2 -- R6: 2-stud legs under the root
	if humanoid and humanoid.RigType == Enum.HumanoidRigType.R15 then
		drop = humanoid.HipHeight + root.Size.Y / 2
	end
	local pos = root.Position - Vector3.new(0, drop, 0)
	local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	if look.Magnitude < 1e-3 then
		return CFrame.new(pos), root
	end
	return CFrame.lookAt(pos, pos + look), root
end

local function resolve(target, attach): (CFrame, BasePart?)
	local kind = typeof(target)
	if kind == "CFrame" then
		return target, nil
	elseif kind == "Vector3" then
		return CFrame.new(target), nil
	elseif kind ~= "Instance" then
		error("LostCubeVFX: target must be a CFrame, Vector3, Model, BasePart or Attachment")
	end
	if target:IsA("Model") then
		if attach == "GROUND" or attach == "WORLD" then
			return (groundCFrame(target)), nil
		elseif attach == "GROUND_FOLLOW" then
			return groundCFrame(target)
		elseif FEET[attach] then
			for _, name in FEET[attach] do
				local part = target:FindFirstChild(name)
				if part and part:IsA("BasePart") then
					return part.CFrame * CFrame.new(0, -part.Size.Y / 2, 0), part
				end
			end
		end
		for _, name in PARTS[attach] or PARTS.ROOT do
			local part = target:FindFirstChild(name)
			if part and part:IsA("BasePart") then
				return part.CFrame, part
			end
		end
		return target:GetPivot(), nil
	elseif target:IsA("BasePart") then
		if attach == "GROUND" or attach == "WORLD" then
			return target.CFrame, nil
		end
		return target.CFrame, target
	elseif target:IsA("Attachment") then
		return target.WorldCFrame, target.Parent :: BasePart
	end
	error("LostCubeVFX: unsupported target " .. target:GetFullName())
end

local function scaleSequence(seq: NumberSequence, k: number): NumberSequence
	local points = {}
	for _, kp in seq.Keypoints do
		table.insert(points, NumberSequenceKeypoint.new(kp.Time, kp.Value * k, kp.Envelope * k))
	end
	return NumberSequence.new(points)
end

local function lightAt(keys, t)
	if t <= keys[1][1] then
		return keys[1][2], keys[1][3]
	end
	for i = 2, #keys do
		local a, b = keys[i - 1], keys[i]
		if t <= b[1] then
			local f = (t - a[1]) / math.max(b[1] - a[1], 1e-6)
			return a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f
		end
	end
	local last = keys[#keys]
	return last[2], last[3]
end

local function pair(s, a, b)
	local list = parseList(s)[1]
	if not list then
		return a, b
	end
	return list[1] or a, list[2] or list[1] or b
end

local function rnd(a, b)
	return a + (b - a) * math.random()
end

-- burst / piece counts at a quality below 1 (never below 1 when something was asked for)
local function scaled(n: number, q: number): number
	if q >= 1 or n <= 0 then
		return n
	end
	return math.max(1, math.floor(n * q + 0.5))
end

-- ---------------------------------------------------------------------------------------------
-- plans: an effect compiled once (its timeline parsed, its elements listed by kind as indices into GetDescendants())
-- ---------------------------------------------------------------------------------------------
local OP_ON, OP_OFF, OP_EMIT = 1, 2, 3
local OP_MESH_ON, OP_MESH_OFF, OP_MESH_SPAWN = 4, 5, 6
local OP_SOUND, OP_SOUND_ON, OP_SOUND_OFF = 7, 8, 9
local OP_BEAM_FLASH, OP_BEAM_ON, OP_BEAM_OFF = 10, 11, 12
local OP_CAM_KICK, OP_CAM_ON, OP_CAM_OFF = 13, 14, 15

local PART_FIX = { CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false, Massless = true, Transparency = 1 }

local function compile(model: Instance)
	local desc = model:GetDescendants()
	local rootPart = (model :: any).PrimaryPart or model:FindFirstChild("Root")
	local plan = {
		count = #desc, check = {}, root = nil :: number?, slots = {}, events = {}, dead = false,
		duration = model:GetAttribute("LC_Duration") or 1, attach = model:GetAttribute("LC_Attach"),
		parts = {}, fix = {}, loose = {}, attachments = {}, emitters = {}, trails = {}, rangeLights = {},
		lights = {}, mutedLights = {}, meshes = {}, grounders = {}, sounds = {}, beams = {}, cameras = {},
		tail = 0, trailLife = 0, pools = {}, protos = {},
	}
	local seq = 0
	local function at(t, op, s, n)
		seq += 1
		table.insert(plan.events, { t = t, op = op, s = s, n = n, seq = seq })
	end
	local function slot(i, data)
		data.i = i
		table.insert(plan.slots, data)
		return #plan.slots
	end
	local function windows(d, s, onOp, offOp)
		for _, w in parseList(d:GetAttribute("LC_On")) do
			at(w[1] or 0, onOp, s)
			at(w[2] or 0, offOp, s)
		end
	end
	local function bursts(d, s, op)
		for _, b in parseList(d:GetAttribute("LC_Bursts")) do
			at(b[1] or 0, op, s, b[2] or 1)
		end
	end
	for i, d in desc do
		local muted = d:GetAttribute("LC_Muted") == true
		if d:IsA("BasePart") then
			plan.check[i] = d.ClassName
			if d == rootPart then
				plan.root = i
			else
				table.insert(plan.parts, i)
			end
			local fix = nil
			for prop, value in PART_FIX do
				if (d :: any)[prop] ~= value then
					fix = fix or {}
					fix[prop] = value
				end
			end
			if fix then
				plan.fix[i] = fix
			end
			if not d.Anchored then
				plan.loose[i] = true
			end
			local mode = d:GetAttribute("LC_Mode")
			if mode and not muted then -- 3D mesh element: pieces spawned from this part
				local e = {
					kind = "M", mode = mode, rate = d:GetAttribute("LC_Rate") or 0, colorEnd = d:GetAttribute("LC_ColorEnd"),
					dir = d:GetAttribute("LC_Dir") or "Top", rise = d:GetAttribute("LC_Rise") or 0,
					spin = d:GetAttribute("LC_Spin") or 0, count = d:GetAttribute("LC_Count") or 16,
					jitter = d:GetAttribute("LC_Jitter") or 0, ground = d:GetAttribute("LC_Ground") == true, color = d.Color,
				}
				e.life0, e.life1 = pair(d:GetAttribute("LC_Life"), 0.5, 0.5)
				e.g0, e.g1 = pair(d:GetAttribute("LC_Grow"), 1, 1)
				e.a0, e.a1 = pair(d:GetAttribute("LC_Alpha"), 0, 1)
				e.s0, e.s1 = pair(d:GetAttribute("LC_Speed"), 0, 0)
				e.sx, e.sy = pair(d:GetAttribute("LC_Spread"), 0, 0)
				e.r0, e.r1 = pair(d:GetAttribute("LC_Radius"), 1, 6)
				local s = slot(i, e)
				table.insert(plan.meshes, s)
				windows(d, s, OP_MESH_ON, OP_MESH_OFF)
				bursts(d, s, OP_MESH_SPAWN)
				plan.tail = math.max(plan.tail, math.max(e.life0, e.life1) + 0.2)
			end
		elseif d:IsA("Attachment") then
			plan.check[i] = "Attachment"
			table.insert(plan.attachments, i)
		elseif d:IsA("ParticleEmitter") then
			plan.check[i] = "ParticleEmitter"
			table.insert(plan.emitters, { i = i, enabled = d.Enabled, timeScale = d.TimeScale, rate = d.Rate })
			if not muted then
				local s = slot(i, { kind = "P" })
				windows(d, s, OP_ON, OP_OFF)
				bursts(d, s, OP_EMIT)
				plan.tail = math.max(plan.tail, d.Lifetime.Max)
			end
		elseif d:IsA("Trail") then
			plan.check[i] = "Trail"
			table.insert(plan.trails, { i = i, enabled = d.Enabled, life = d.Lifetime })
			if not muted then
				local s = slot(i, { kind = "T" })
				windows(d, s, OP_ON, OP_OFF)
				plan.trailLife = math.max(plan.trailLife, d.Lifetime)
				if d:GetAttribute("LC_Ground") then -- ribbon lying on the floor
					table.insert(plan.grounders, i)
				end
			end
		elseif d:IsA("PointLight") or d:IsA("SpotLight") or d:IsA("SurfaceLight") then
			plan.check[i] = d.ClassName
			table.insert(plan.rangeLights, i)
			if d:IsA("PointLight") then
				if muted then
					table.insert(plan.mutedLights, i)
				else
					local keys = parseList(d:GetAttribute("LC_Keys"))
					if #keys > 0 then
						table.insert(plan.lights, { i = i, keys = keys })
					end
				end
			end
		elseif d:IsA("Sound") then
			local timed = d:GetAttribute("LC_Bursts") ~= nil or d:GetAttribute("LC_On") ~= nil
			if timed then
				plan.check[i] = "Sound"
				local p0, p1 = pair(d:GetAttribute("LC_Pitch"), d.PlaybackSpeed, d.PlaybackSpeed)
				local fade = d:GetAttribute("LC_Fade") or 0.15
				local data = { kind = "S", p0 = math.max(0.01, p0), p1 = math.max(0.01, p1), volume = d.Volume, fade = fade,
					muted = muted }
				local s = slot(i, data)
				table.insert(plan.sounds, s)
				if not muted then
					bursts(d, s, OP_SOUND)
					windows(d, s, OP_SOUND_ON, OP_SOUND_OFF)
					if d:GetAttribute("LC_On") then
						plan.tail = math.max(plan.tail, fade)
					end
				end
			end
		elseif d:IsA("Beam") then
			local timed = d:GetAttribute("LC_Bursts") ~= nil or d:GetAttribute("LC_On") ~= nil
			if timed then -- only beams with a LostCube timeline are driven; others stay as they are
				plan.check[i] = "Beam"
				local kps = {}
				for _, kp in d.Transparency.Keypoints do
					table.insert(kps, { kp.Time, kp.Value, kp.Envelope })
				end
				local data = { kind = "B", flash = d:GetAttribute("LC_FlashTime") or 0.12, fade = d:GetAttribute("LC_Fade") or 0.08,
					jitter = d:GetAttribute("LC_Jitter") or 0, alpha = kps, muted = muted }
				local s = slot(i, data)
				table.insert(plan.beams, s)
				if not muted then
					bursts(d, s, OP_BEAM_FLASH)
					windows(d, s, OP_BEAM_ON, OP_BEAM_OFF)
					plan.tail = math.max(plan.tail, data.flash, data.fade)
				end
			end
		elseif d:IsA("Configuration") and d:GetAttribute("LC_Kind") == "CAMERA" then
			if not muted then
				plan.check[i] = "Configuration"
				local flash = d:GetAttribute("LC_Flash")
				local data = {
					kind = "C", shake = d:GetAttribute("LC_Shake") or 0, freq = d:GetAttribute("LC_Freq") or 12,
					shakeTime = math.max(0.01, d:GetAttribute("LC_ShakeTime") or 0.4), fov = d:GetAttribute("LC_FOV") or 0,
					fovTime = math.max(0.01, d:GetAttribute("LC_FovTime") or 0.35),
					flash = typeof(flash) == "Color3" and flash or nil, flashAlpha = d:GetAttribute("LC_FlashAlpha") or 0.5,
					flashTime = math.max(0.01, d:GetAttribute("LC_FlashTime") or 0.25), radius = d:GetAttribute("LC_Radius") or 60,
					studio = d:GetAttribute("LC_Studio") ~= false,
				}
				local s = slot(i, data)
				table.insert(plan.cameras, s)
				bursts(d, s, OP_CAM_KICK)
				windows(d, s, OP_CAM_ON, OP_CAM_OFF)
				if d:GetAttribute("LC_Bursts") then
					plan.tail = math.max(plan.tail, data.shake > 0 and data.shakeTime or 0, data.fov ~= 0 and data.fovTime or 0,
						data.flash and data.flashTime or 0)
				end
			end
		end
	end
	-- events at the same moment keep their written order (a window that ends where the next one starts stays on)
	table.sort(plan.events, function(a, b)
		if a.t ~= b.t then
			return a.t < b.t
		end
		return a.seq < b.seq
	end)
	return plan
end

local PLANS: { [Instance]: any } = {}
local PER_COPY = { perCopy = true } -- this effect's copies never match the original (e.g. non-Archivable parts)

local function dropPlan(plan)
	if not plan or plan == PER_COPY then
		return
	end
	plan.dead = true
	for _, pool in plan.pools do
		for _, p in pool do
			p:Destroy()
		end
		table.clear(pool)
	end
	for _, proto in plan.protos do
		proto:Destroy()
	end
	table.clear(plan.protos)
end

-- the cached plan maps onto this copy (same descendants, same classes, in the same order)
local function matches(plan, desc): boolean
	if #desc ~= plan.count then
		return false
	end
	for i, className in plan.check do
		if desc[i].ClassName ~= className then
			return false
		end
	end
	return true
end

local planCount = 0

-- -> (plan, owned): an owned plan belongs to this play only (it is dropped with it)
local function planFor(template: Instance, desc, model: Instance, edit: boolean)
	if edit then -- Studio's edit mode: always from the copy (the effect may have just been edited)
		return compile(model), true
	end
	local plan = PLANS[template]
	if plan and plan ~= PER_COPY and matches(plan, desc) then
		return plan, false
	end
	if plan ~= PER_COPY then
		-- first play, or the effect changed / was still replicating: compile it again
		local fresh = compile(template)
		dropPlan(plan)
		if plan == nil then
			planCount += 1
			if planCount > 256 then -- a game that plays fresh copies every time: forget the ones that are gone
				for t, old in PLANS do
					if not t.Parent then
						dropPlan(old)
						PLANS[t] = nil
						planCount -= 1
					end
				end
			end
			pcall(function()
				template.Destroying:Once(function()
					if PLANS[template] then
						dropPlan(PLANS[template])
						PLANS[template] = nil
						planCount -= 1
					end
				end)
			end)
		end
		if matches(fresh, desc) then
			PLANS[template] = fresh
			return fresh, false
		end
		PLANS[template] = PER_COPY
	end
	return compile(model), true
end

-- forget the compiled form of an effect (or of all effects): its next play reads it again
function VFX.invalidate(template: Instance?)
	if template then
		if PLANS[template] then
			dropPlan(PLANS[template])
			PLANS[template] = nil
			planCount -= 1
		end
	else
		for _, plan in PLANS do
			dropPlan(plan)
		end
		table.clear(PLANS)
		planCount = 0
	end
end

-- ---------------------------------------------------------------------------------------------
-- 3D mesh elements: pieces spawned from a Part template (rings, cracks, smoke balls, grooves, debris)
-- ---------------------------------------------------------------------------------------------
local NORMALS = {
	Top = Vector3.yAxis, Bottom = -Vector3.yAxis, Front = -Vector3.zAxis, Back = Vector3.zAxis,
	Right = Vector3.xAxis, Left = -Vector3.xAxis,
}

-- a direction of the template's space with a random spread (degrees), in world space
local function spreadDir(cf, name, sx, sy)
	local d = NORMALS[name or "Top"] or Vector3.yAxis
	local rot
	if math.abs(d.Y) > 0.9 then
		rot = CFrame.fromAxisAngle(Vector3.xAxis, math.rad(rnd(-sx, sx))) * CFrame.fromAxisAngle(Vector3.zAxis, math.rad(rnd(-sy, sy)))
	else -- horizontal directions: fan out sideways (x) and upwards (y)
		rot = CFrame.fromAxisAngle(Vector3.yAxis, math.rad(rnd(-sx, sx)))
			* CFrame.fromAxisAngle(d:Cross(Vector3.yAxis).Unit, math.rad(rnd(0, sy)))
	end
	return cf:VectorToWorldSpace(rot:VectorToWorldSpace(d))
end

local function newMesh(model, ignore, plan, quality)
	local self = { tweens = {}, debris = {}, paused = false, elements = {} }
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore

	-- marks that lie on the ground (LC_Ground): snapped onto the floor under them, keeping their heading
	local function onGround(cf)
		local hit = workspace:Raycast(cf.Position + Vector3.new(0, 1.5, 0), Vector3.new(0, -6, 0), params)
		if not hit then
			return cf
		end
		local look = cf.LookVector - hit.Normal * cf.LookVector:Dot(hit.Normal)
		if look.Magnitude < 1e-3 then
			look = cf.RightVector:Cross(hit.Normal)
		end
		return CFrame.lookAt(hit.Position + hit.Normal * 0.012, hit.Position + hit.Normal * 0.012 + look.Unit, hit.Normal)
	end

	-- a piece: from the pool of this element when there is one, else a copy of its bare prototype (the template part
	-- without children / attributes, made once per element)
	local function piece(e, cf, size, alpha)
		local p = table.remove(e.pool)
		if p then
			p.Color = e.d.color -- a fade may have tweened it to LC_ColorEnd
			p.Anchored = true
		else
			local proto = plan.protos[e.index]
			if not proto then
				proto = e.t:Clone()
				for _, c in proto:GetChildren() do
					c:Destroy()
				end
				for name in proto:GetAttributes() do
					proto:SetAttribute(name, nil)
				end
				proto.Name = e.t.Name .. "_"
				proto.Anchored = true
				proto.CanCollide, proto.CanQuery, proto.CanTouch, proto.CastShadow = false, false, false, false
				plan.protos[e.index] = proto
			end
			p = proto:Clone()
		end
		p.Size = size
		p.CFrame = cf
		p.Transparency = alpha
		p.Parent = model
		return p
	end

	-- a piece whose fade has really ended goes back to the pool (or away when the pool is full / the plan is gone)
	local function release(e, p)
		if p.Parent == model and not plan.dead and #e.pool < (VFX.PoolSize or 0) then
			p.Parent = nil
			table.insert(e.pool, p)
		else
			p:Destroy()
		end
	end

	local function tween(inst, time, goal, style, dir)
		local tw = TweenService:Create(inst, TweenInfo.new(math.max(time, 0.01), style or Enum.EasingStyle.Quad,
			dir or Enum.EasingDirection.Out), goal)
		self.tweens[tw] = true
		tw.Completed:Once(function()
			self.tweens[tw] = nil
		end)
		if not self.paused then
			tw:Play()
		end
		return tw
	end

	local function fadeOut(e, p, life)
		local goal = { Transparency = e.d.a1 }
		if e.d.colorEnd then
			goal.Color = e.d.colorEnd
		end
		-- removed when the fade has really ended: a paused preview keeps its pieces and they still go away afterwards
		local tw = tween(p, life, goal, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tw.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed then
				release(e, p)
			end
		end)
	end

	function self.add(index, template, scale, speed)
		local d = plan.slots[index]
		plan.pools[index] = plan.pools[index] or {}
		local e = {
			index = index, d = d, t = template, scale = scale, speed = speed, acc = 0, on = false, pool = plan.pools[index],
			rate = d.rate * math.min(quality, 1), base = template.Size, -- the template size, already scaled
		}
		self.elements[index] = e
		return e
	end

	function self.spawn(e, n)
		local d = e.d
		for _ = 1, n or 1 do
			local t, k = e.t, e.scale
			local cf = d.ground and onGround(t.CFrame) or t.CFrame
			local life = rnd(d.life0, d.life1) / e.speed
			local jit = 1 + (math.random() * 2 - 1) * d.jitter
			local base = e.base * jit
			if d.mode == "Ring" then
				local count = math.max(3, scaled(d.count, quality))
				local r0, r1 = d.r0 * k, d.r1 * k
				for i = 1, count do
					local a = (i - 1) / count * math.pi * 2
					local function at(r)
						return cf * CFrame.new(math.cos(a) * r, 0, math.sin(a) * r) * CFrame.Angles(0, -(a + math.pi / 2), 0)
					end
					local len0 = math.max(base.X * d.g0, 2 * math.pi * r0 / count * 1.02)
					local len1 = math.max(base.X * d.g1, 2 * math.pi * r1 / count * 1.02)
					local p = piece(e, at(r0), Vector3.new(len0, base.Y * d.g0, base.Z * d.g0), d.a0)
					tween(p, life, { CFrame = at(r1), Size = Vector3.new(len1, base.Y * d.g1, base.Z * d.g1) },
						Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
					fadeOut(e, p, life)
				end
			elseif d.mode == "Crack" then
				local count = math.max(1, scaled(d.count, quality))
				for i = 1, count do
					local a = (i - 1) / count * math.pi * 2 + rnd(-0.35, 0.35)
					local dir = cf:VectorToWorldSpace(Vector3.new(math.cos(a), 0, math.sin(a)))
					local len = rnd(d.r0, d.r1) * k
					local function at(l)
						return CFrame.lookAt(cf.Position, cf.Position + dir) * CFrame.new(0, 0, -l / 2)
					end
					local p = piece(e, at(0.1), Vector3.new(base.X, base.Y, 0.2), d.a0)
					tween(p, math.min(0.14, life * 0.3), { CFrame = at(len), Size = Vector3.new(base.X, base.Y, len) },
						Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
					fadeOut(e, p, life)
				end
			elseif d.mode == "Pulse" then
				local p = piece(e, cf, base * d.g0, d.a0)
				tween(p, life, { Size = base * d.g1 }, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
				fadeOut(e, p, life)
			elseif d.mode == "Puff" then
				local dir = spreadDir(cf, d.dir, d.sx, d.sy)
				local speed = rnd(d.s0, d.s1) * k
				local from = cf.Position + Vector3.new(rnd(-0.3, 0.3), rnd(0, 0.2), rnd(-0.3, 0.3)) * k
				local to = from + dir * speed * life * 0.45 + Vector3.new(0, d.rise * k, 0)
				local spin = CFrame.Angles(math.random() * 6.28, math.random() * 6.28, math.random() * 6.28)
				local p = piece(e, CFrame.new(from) * spin, base * d.g0, d.a0)
				tween(p, life, { CFrame = CFrame.new(to) * spin, Size = base * d.g1 }, Enum.EasingStyle.Quart,
					Enum.EasingDirection.Out)
				fadeOut(e, p, life)
			elseif d.mode == "Trail" then
				local yaw = CFrame.new(0, rnd(0, 0.012), 0) * CFrame.Angles(0, math.rad(rnd(-2.5, 2.5)), 0) -- no z-fighting
				local p = piece(e, cf * yaw, base * d.g0, d.a0)
				tween(p, life, { Size = base * d.g1 }, Enum.EasingStyle.Linear)
				fadeOut(e, p, life)
			elseif d.mode == "Debris" then
				local p = piece(e, cf * CFrame.new(rnd(-0.2, 0.2) * k, 0.15 * k, rnd(-0.2, 0.2) * k)
					* CFrame.Angles(math.random() * 6.28, math.random() * 6.28, math.random() * 6.28), base * d.g0, d.a0)
				p.Anchored = self.paused
				p.CanCollide = true
				p.Massless = false
				p.CustomPhysicalProperties = PhysicalProperties.new(0.4, 0.6, 0.35)
				p.AssemblyLinearVelocity = spreadDir(cf, d.dir, d.sx, d.sy) * rnd(d.s0, d.s1) * k
				p.AssemblyAngularVelocity = Vector3.new(rnd(-1, 1), rnd(-1, 1), rnd(-1, 1)) * d.spin
				self.debris[p] = true
				task.delay(life * 0.6, function()
					if p.Parent == model then
						local tw = tween(p, life * 0.4, { Transparency = d.a1, Size = base * d.g1 }, Enum.EasingStyle.Quad,
							Enum.EasingDirection.In)
						tw.Completed:Once(function(state)
							if state == Enum.PlaybackState.Completed then
								self.debris[p] = nil
								release(e, p)
							end
						end)
					end
				end)
			end
		end
	end

	function self.step(dt)
		for _, e in self.elements do
			if e.on and e.rate > 0 then
				e.acc += dt * e.rate
				local n = math.floor(e.acc)
				if n > 0 then
					e.acc -= n
					self.spawn(e, n)
				end
			end
		end
	end

	function self.pause(on)
		self.paused = on
		for tw in self.tweens do
			if on then
				tw:Pause()
			else
				tw:Play()
			end
		end
		for p in self.debris do
			if p.Parent then
				p.Anchored = on
			end
		end
	end

	return self
end

-- ---------------------------------------------------------------------------------------------
-- ground ribbons: a Trail (attribute LC_Ground) whose width lies flat on the floor under the effect.
-- It follows the path of the effect's root (e.g. a foot dragging) and stretches ONE texture over the whole
-- ribbon, so it grows and bends with the movement; Lifetime / Transparency fade it from the oldest end.
-- ---------------------------------------------------------------------------------------------
local function groundRibbon(trail: Trail, root: BasePart, model: Model, ignore, facing: Vector3?)
	local a0, a1 = trail.Attachment0, trail.Attachment1
	if not a0 or not a1 then
		return nil
	end
	local width = (a0.Position - a1.Position).Magnitude
	local center = (a0.Position + a1.Position) / 2 -- X: sideways offset, Z: forward offset
	local follower = Instance.new("Part")
	follower.Name = "GroundFollower"
	follower.Size = Vector3.new(0.2, 0.2, 0.2)
	follower.Transparency = 1
	follower.Anchored = true
	follower.CanCollide, follower.CanQuery, follower.CanTouch, follower.CastShadow = false, false, false, false
	follower.CFrame = root.CFrame
	follower.Parent = model
	local b0, b1 = Instance.new("Attachment"), Instance.new("Attachment")
	b0.Name, b1.Name = "RibbonA", "RibbonB"
	b0.Position = Vector3.new(center.X + width / 2, 0, 0)
	b1.Position = Vector3.new(center.X - width / 2, 0, 0)
	b0.Parent, b1.Parent = follower, follower
	trail.Attachment0, trail.Attachment1 = b0, b1
	trail.FaceCamera = false

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore

	local look = facing and Vector3.new(facing.X, 0, facing.Z) or Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	local heading = look.Magnitude > 1e-3 and look.Unit or Vector3.new(0, 0, -1)
	local fixed = facing ~= nil and look.Magnitude > 1e-3
	local last = root.Position
	local moved = false
	local lift = trail:GetAttribute("LC_Lift") or 0

	-- "flow": a bright band runs along the ribbon (head -> tail) and keeps repeating, like energy leaking out
	local flow = trail:GetAttribute("LC_Flow")
	local base = flow and trail.Color.Keypoints
	local function baseColor(t)
		for i = 2, #base do
			if t <= base[i].Time then
				local a, b = base[i - 1], base[i]
				return a.Value:Lerp(b.Value, (t - a.Time) / math.max(b.Time - a.Time, 1e-6))
			end
		end
		return base[#base].Value
	end
	local s0, s1 -- when the ribbon started / stopped being drawn
	local function updateFlow()
		local now = os.clock()
		if trail.Enabled then
			s0 = s0 or now
			s1 = now
		elseif s0 and not s1 then
			s1 = now
		end
		if not s0 then
			return
		end
		-- Trail colour is mapped by AGE (age / Lifetime): the ribbon covers only the ages [now - s1, now - s0],
		-- so the bright band sweeps exactly that window, head (youngest) -> tail (oldest), once per 1/flow seconds
		local life = trail.Lifetime
		local lo, hi = (now - s1) / life, (now - s0) / life
		if hi >= 1 or hi - lo < 1e-4 then
			return
		end
		local f = lo + ((now * flow) % 1) * (hi - lo)
		local sigma = math.max((hi - lo) * 0.12, 0.003)
		local times = { 0, 1 }
		for i = 1, #base do
			table.insert(times, base[i].Time)
		end
		for _, d in { -2, -1, -0.5, 0, 0.5, 1, 2 } do
			local t = f + d * sigma
			if t > 0 and t < 1 then
				table.insert(times, t)
			end
		end
		table.sort(times)
		local points, prev = {}, -1
		for _, t in times do
			if t - prev > 1e-4 then
				local g = math.exp(-(((t - f) / sigma) ^ 2))
				table.insert(points, ColorSequenceKeypoint.new(t, baseColor(t):Lerp(Color3.fromRGB(255, 244, 255), 0.55 * g)))
				prev = t
			end
		end
		points[1] = ColorSequenceKeypoint.new(0, points[1].Value)
		points[#points] = ColorSequenceKeypoint.new(1, points[#points].Value)
		if #points > 20 then -- ColorSequence takes at most 20 keypoints: keep the ends, thin out the middle evenly
			local thinned = {}
			for i = 1, 20 do
				table.insert(thinned, points[math.floor(1 + (i - 1) * (#points - 1) / 19 + 0.5)])
			end
			points = thinned
		end
		trail.Color = ColorSequence.new(points)
	end

	return function()
		if flow then
			updateFlow()
		end
		local pos = root.Position
		if not fixed then -- no direction given: follow where the effect moves (so the ribbon bends with a curved path)
			local d = Vector3.new(pos.X - last.X, 0, pos.Z - last.Z)
			if d.Magnitude > 0.04 then
				heading = moved and heading:Lerp(d.Unit, 0.35).Unit or d.Unit -- the first move sets the heading at once
				moved = true
			end
		end
		last = pos
		local hit = workspace:Raycast(pos + Vector3.new(0, 2, 0), Vector3.new(0, -9, 0), params)
		local ground = hit and hit.Position or Vector3.new(pos.X, pos.Y - 2.5, pos.Z)
		local normal = hit and hit.Normal or Vector3.yAxis
		local flat = heading - normal * heading:Dot(normal)
		flat = flat.Magnitude > 1e-3 and flat.Unit or heading
		local origin = ground + normal * (0.04 + lift) + flat * center.Z
		follower.CFrame = CFrame.lookAt(origin, origin + flat, normal)
	end
end

-- ---------------------------------------------------------------------------------------------
-- camera: shakes, FOV punches and flashes of every live effect, summed into one offset of the local camera.
-- The offset is added after the camera scripts ran (RenderPriority.Camera + 1) and taken out again before they run
-- (Camera - 1), so they never build on it; when the last one ends the camera is exactly where it would have been.
-- ---------------------------------------------------------------------------------------------
local cam = {
	list = {}, bound = false, mode = nil :: string?, key = "LostCubeVFX_Camera_" .. math.random(1, 1e9),
	camera = nil :: Camera?, base = nil :: CFrame?, applied = nil :: CFrame?, offset = nil :: CFrame?,
	baseFov = nil :: number?, appliedFov = nil :: number?, flash = nil :: ColorCorrectionEffect?,
}
local RUMBLE_FADE = 0.12
local WHITE = Color3.new(1, 1, 1)

local function nearlySame(a: CFrame, b: CFrame): boolean
	return (a.Position - b.Position).Magnitude < 1e-3 and a.LookVector:Dot(b.LookVector) > 0.999999
		and a.UpVector:Dot(b.UpVector) > 0.999999
end

-- takes this frame's shake out of the camera (before the camera scripts / Studio read it)
local function camUndo()
	local c = cam.camera
	if not c then
		return
	end
	if cam.applied then
		local cur = c.CFrame
		if nearlySame(cur, cam.applied :: CFrame) then
			c.CFrame = cam.base :: CFrame -- exactly where it was
		else
			c.CFrame = cur * (cam.offset :: CFrame):Inverse() -- moved meanwhile (e.g. the Studio camera): only our part out
		end
		cam.applied = nil
	end
	if cam.appliedFov then
		if math.abs(c.FieldOfView - cam.appliedFov) < 1e-3 then
			c.FieldOfView = cam.baseFov :: number
		end -- else someone else changed the FOV meanwhile: theirs stays
		cam.appliedFov = nil
	end
end

local function camUnbind()
	if cam.mode == "render" then
		pcall(RunService.UnbindFromRenderStep, RunService, cam.key .. "_Pre")
		pcall(RunService.UnbindFromRenderStep, RunService, cam.key .. "_Post")
	end
	cam.bound = false
	cam.mode = nil
	if cam.flash then
		cam.flash:Destroy()
		cam.flash = nil
	end
end

local function effectTime(h, now: number): number
	return ((h.pausedAt or now) - h.start) * h.speed
end

local function punch(p: number): number -- quick out, slow back
	if p < 0.12 then
		return p / 0.12
	end
	return (1 - (p - 0.12) / 0.88) ^ 2
end

local function camApply()
	local c = workspace.CurrentCamera
	if c ~= cam.camera then
		cam.camera, cam.applied, cam.appliedFov = c, nil, nil
	end
	local now = os.clock()
	local rx, ry, rz, px, py, pz, fov, flashA = 0, 0, 0, 0, 0, 0, 0, 0
	local shaking = false
	local flashColor = WHITE
	local list = cam.list
	local j = 0
	for i = 1, #list do
		local s = list[i]
		local h, d = s.h, s.d
		local keep = false
		if h.pausedAt and not h.Done then
			keep = true -- frozen: the camera stays clean until it resumes
		elseif not h.Done then
			local t = effectTime(h, now)
			local age = t - s.t0
			local amp = 0
			if s.rumble then
				local k = math.clamp(age / RUMBLE_FADE, 0, 1)
				if s.tOff then
					k = math.min(k, 1 - math.clamp((t - s.tOff) / RUMBLE_FADE, 0, 1))
				end
				keep = not s.tOff or k > 0
				amp = d.shake * s.falloff * k
			else
				if d.shake > 0 and age < d.shakeTime then
					keep = true
					amp = d.shake * s.falloff * (1 - age / d.shakeTime) ^ 2
				end
				if d.fov ~= 0 and age < d.fovTime then
					keep = true
					fov += d.fov * s.falloff * punch(age / d.fovTime)
				end
				if d.flash and age < d.flashTime then
					keep = true
					local a = d.flashAlpha * s.falloff * (1 - age / d.flashTime) ^ 2
					if a > flashA then
						flashA, flashColor = a, d.flash
					end
				end
			end
			if amp > 0 then -- smooth noise (math.noise is about -0.5..0.5): amplitude in degrees, a little sway in studs
				shaking = true
				local n = t * d.freq
				rx += math.noise(n, s.seed, 0.31) * 2 * amp
				ry += math.noise(s.seed, n, 0.73) * 2 * amp
				rz += math.noise(0.17, s.seed, n) * amp
				px += math.noise(n, 0.59, s.seed) * amp * 0.04
				py += math.noise(0.43, n, s.seed) * amp * 0.04
			end
		end
		if keep then
			j += 1
			list[j] = s
		end
	end
	for i = j + 1, #list do
		list[i] = nil
	end
	if not c or j == 0 then
		camUnbind() -- the camera was already put back by camUndo (this frame)
		return
	end
	if shaking then -- (nothing to add, e.g. a paused preview: the camera is not written at all)
		local offset = CFrame.new(px, py, pz) * CFrame.Angles(math.rad(rx), math.rad(ry), math.rad(rz))
		local base = c.CFrame
		local applied = base * offset
		c.CFrame = applied
		cam.base, cam.applied, cam.offset = base, applied, offset
	end
	if fov ~= 0 then
		local baseFov = c.FieldOfView
		local f = math.clamp(baseFov + fov, 1, 120)
		c.FieldOfView = f
		cam.baseFov, cam.appliedFov = baseFov, f
	end
	if flashA > 0.002 then
		local cc = cam.flash
		if not cc or cc.Parent ~= c then
			if cc then
				cc:Destroy()
			end
			cc = Instance.new("ColorCorrectionEffect")
			cc.Name = "LostCubeFlash"
			cc.Archivable = false
			cc.Parent = c
			cam.flash = cc
		end
		cc.Brightness = math.min(flashA, 1)
		cc.TintColor = WHITE:Lerp(flashColor, math.min(flashA, 1))
	elseif cam.flash then
		cam.flash:Destroy()
		cam.flash = nil
	end
end

local function camStart(edit: boolean)
	if cam.bound then
		return
	end
	cam.bound = true
	local ok = not edit and pcall(function()
		RunService:BindToRenderStep(cam.key .. "_Pre", Enum.RenderPriority.Camera.Value - 1, camUndo)
		RunService:BindToRenderStep(cam.key .. "_Post", Enum.RenderPriority.Camera.Value + 1, camApply)
	end)
	if ok then
		cam.mode = "render"
	else -- Studio's edit mode (or no render steps): undo + apply on the effects' Heartbeat
		pcall(RunService.UnbindFromRenderStep, RunService, cam.key .. "_Pre")
		cam.mode = "heartbeat"
	end
end

-- a camera element starts (kick or rumble) if the local camera is near enough
local function camAdd(h, d, rumble: boolean)
	local c = workspace.CurrentCamera
	if not c or h.noCamera then
		return nil
	end
	if h.edit then
		if not d.studio then
			return nil
		end
	elseif not IS_CLIENT then
		return nil
	end
	local root = h.root
	local pos = root and root.Position or c.CFrame.Position
	local r = math.max(d.radius * h.scale, 0.01)
	local dist = (c.CFrame.Position - pos).Magnitude
	local falloff = dist <= r * 0.3 and 1 or math.clamp(1 - (dist - r * 0.3) / (r * 0.7), 0, 1)
	if falloff <= 0 then
		return nil
	end
	local s = { h = h, d = d, t0 = h.t, falloff = falloff, seed = math.random() * 100 + 0.5, rumble = rumble }
	table.insert(cam.list, s)
	camStart(h.edit)
	return s
end

-- ---------------------------------------------------------------------------------------------
-- handles + the shared scheduler (one Heartbeat connection for every live effect)
-- ---------------------------------------------------------------------------------------------
export type Handle = {
	Model: Model,
	Done: boolean,
	Stop: (Handle) -> (),
	Destroy: (Handle) -> (),
	Pause: (Handle) -> (),
	Resume: (Handle) -> (),
}

local Handle = {}
Handle.__index = Handle

local active = {} -- live handles, oldest first
local heartbeat: RBXScriptConnection? = nil

local function finish(h)
	if h.Done then
		return
	end
	h.Done = true
	if h.Model then
		h.Model:Destroy()
	end
	if h.ownPlan then -- its pooled pieces are of no use to anyone else
		dropPlan(h.plan)
	end
end

local function beamAlpha(h, slot, inst, alpha)
	local st = h.beamState[slot]
	if alpha == st.shown or (alpha > 0 and alpha < 1 and math.abs(alpha - st.shown) < 0.01) then
		return
	end
	st.shown = alpha
	if alpha <= 0 then
		inst.Enabled = false
		return
	end
	inst.Enabled = true
	local points = {}
	for _, kp in h.plan.slots[slot].alpha do
		table.insert(points, NumberSequenceKeypoint.new(kp[1], 1 - (1 - kp[2]) * alpha, kp[3]))
	end
	inst.Transparency = NumberSequence.new(points)
end

local function playSound(h, d, sound, n)
	for k = 1, math.max(1, n or 1) do
		local s = sound
		if k > 1 or sound.IsPlaying then -- overlapping plays need their own copy
			s = sound:Clone()
			s.Parent = sound.Parent
			s.Ended:Once(function()
				s:Destroy()
			end)
		end
		s.PlaybackSpeed = rnd(d.p0, d.p1)
		s.TimePosition = 0
		s:Play()
		h.playing[s] = true
	end
end

local function fire(h, ev)
	local op = ev.op
	local d = h.plan.slots[ev.s]
	local inst = h.desc[d.i]
	if op == OP_ON then
		inst.Enabled = true
	elseif op == OP_OFF then
		inst.Enabled = false
	elseif op == OP_EMIT then
		inst:Emit(scaled(ev.n, h.quality))
	elseif op == OP_MESH_ON or op == OP_MESH_OFF then
		h.mesh.elements[ev.s].on = op == OP_MESH_ON
	elseif op == OP_MESH_SPAWN then
		h.mesh.spawn(h.mesh.elements[ev.s], scaled(ev.n, h.quality))
	elseif op == OP_SOUND then
		playSound(h, d, inst, ev.n)
	elseif op == OP_SOUND_ON then
		inst.Looped = true
		inst.Volume = 0
		if not inst.IsPlaying then
			inst.PlaybackSpeed = rnd(d.p0, d.p1)
			inst.TimePosition = 0
			inst:Play()
		end
		h.playing[inst] = true
		h.fades[ev.s] = { from = 0, to = d.volume, t0 = h.t, dur = 0.06 }
	elseif op == OP_SOUND_OFF then
		h.fades[ev.s] = { from = inst.Volume, to = 0, t0 = h.t, dur = math.max(d.fade, 0.01), stop = true }
	elseif op == OP_BEAM_ON then
		h.beamState[ev.s].on, h.beamState[ev.s].off = h.t, nil
	elseif op == OP_BEAM_OFF then
		h.beamState[ev.s].off = h.t
	elseif op == OP_BEAM_FLASH then
		local st = h.beamState[ev.s]
		st.flash = h.t
		if d.jitter > 0 then -- a new shape for every flash (lightning)
			local a1 = inst.Attachment1
			st.base = st.base or { a1 and a1.Position, inst.CurveSize0, inst.CurveSize1 }
			local j = d.jitter * h.scale
			if a1 and st.base[1] then
				a1.Position = st.base[1] + Vector3.new(rnd(-j, j), rnd(-j, j) * 0.5, rnd(-j, j))
			end
			inst.CurveSize0 = st.base[2] + rnd(-j, j)
			inst.CurveSize1 = st.base[3] + rnd(-j, j)
		end
	elseif op == OP_CAM_KICK then
		camAdd(h, d, false)
	elseif op == OP_CAM_ON then
		h.rumbles[ev.s] = camAdd(h, d, true)
	elseif op == OP_CAM_OFF then
		local s = h.rumbles[ev.s]
		if s then
			s.tOff = h.t
		end
	end
end

local function step(h, now: number)
	if h.pausedAt then
		return
	end
	if h.follow and not h.follow.Parent then
		h.root.Anchored = true
		h.follow = nil
	end
	if h.grounders then
		for _, update in h.grounders do
			update()
		end
	end
	local t = (now - h.start) * h.speed
	h.t = t
	if not h.stopAt then
		local events = h.plan.events
		local n = h.nextEvent
		while n <= #events and events[n].t <= t do
			fire(h, events[n])
			n += 1
		end
		h.nextEvent = n
		if h.mesh then
			h.mesh.step(math.max(0, t - h.lastT))
		end
	end
	h.lastT = t
	local plan = h.plan
	local desc = h.desc
	for n, l in plan.lights do
		local b, r = lightAt(l.keys, t)
		r *= h.scale
		local last = h.lightVals[n]
		if not last or last[1] ~= b or last[2] ~= r then -- after the last key nothing changes: no writes
			local light = desc[l.i]
			light.Brightness = b
			light.Range = r
			if last then
				last[1], last[2] = b, r
			else
				h.lightVals[n] = { b, r }
			end
		end
	end
	if h.fades then
		for s, f in h.fades do
			local sound = desc[plan.slots[s].i]
			local k = math.clamp((t - f.t0) / f.dur, 0, 1)
			sound.Volume = f.from + (f.to - f.from) * k
			if k >= 1 then
				h.fades[s] = nil
				if f.stop then
					sound:Stop()
					sound.Volume = plan.slots[s].volume
				end
			end
		end
	end
	if h.beamState then
		for s, st in h.beamState do
			local d = plan.slots[s]
			local alpha = 0
			if st.on then
				alpha = math.clamp((t - st.on) / d.fade, 0, 1)
				if st.off then
					alpha = math.min(alpha, 1 - math.clamp((t - st.off) / d.fade, 0, 1))
					if t - st.off >= d.fade then
						st.on, st.off = nil, nil
					end
				end
			end
			if st.flash then
				local p = (t - st.flash) / d.flash
				if p >= 1 then
					st.flash = nil
				else
					alpha = math.max(alpha, p < 0.5 and 1 or 1 - (p - 0.5) / 0.5)
				end
			end
			beamAlpha(h, s, desc[d.i], alpha)
		end
	end
	if t >= (h.stopAt or h.duration) + h.tail then
		-- one-shot sounds play to their end (but not forever)
		h.endedAt = h.endedAt or now
		if now - h.endedAt < 6 then
			for s in h.playing do
				if s.Parent and s.IsPlaying and not s.Looped then
					return
				end
			end
		end
		finish(h)
	end
end

local function tick()
	local now = os.clock()
	local n = #active
	local j = 0
	for i = 1, n do
		local h = active[i]
		if not h.Done then
			local ok, err = pcall(step, h, now)
			if not ok then
				warn("LostCubeVFX:", err)
				finish(h)
			end
		end
		if not h.Done then
			j += 1
			active[j] = h
		end
	end
	local last = #active -- effects started during this loop stay, in order
	for i = n + 1, last do
		j += 1
		active[j] = active[i]
	end
	for i = j + 1, last do
		active[i] = nil
	end
	if cam.mode == "heartbeat" then
		camUndo()
		camApply()
	end
	if j == 0 and heartbeat and cam.mode ~= "heartbeat" then
		heartbeat:Disconnect()
		heartbeat = nil
	end
end

-- more live effects than VFX.MaxActive: the oldest ones stop emitting (and twice as many: they go at once)
local function enforceCap()
	local cap = VFX.MaxActive
	if not cap then
		return
	end
	local live, running = 0, 0
	for _, h in active do
		if not h.Done then
			live += 1
			if not h.stopAt then
				running += 1
			end
		end
	end
	for _, h in active do
		if running <= cap and live <= cap * 2 then
			break
		end
		if not h.Done then
			if live > cap * 2 then
				live -= 1
				if not h.stopAt then
					running -= 1
				end
				finish(h)
			elseif not h.stopAt then
				running -= 1
				h:Stop()
			end
		end
	end
end

function Handle:Stop()
	if self.Done or self.stopAt then
		return
	end
	self.stopAt = effectTime(self, os.clock())
	local plan, desc = self.plan, self.desc
	for _, e in plan.emitters do
		desc[e.i].Enabled = false
	end
	for _, e in plan.trails do
		desc[e.i].Enabled = false
	end
	if self.mesh then
		for _, e in self.mesh.elements do
			e.on = false
		end
	end
	for _, s in plan.sounds do -- loops fade out; one-shots play to their end
		local sound = desc[plan.slots[s].i]
		if sound.Looped and sound.IsPlaying and not (self.fades[s] and self.fades[s].stop) then
			self.fades[s] = { from = sound.Volume, to = 0, t0 = self.stopAt, dur = math.max(plan.slots[s].fade, 0.01), stop = true }
		end
	end
	for _, st in self.beamState do
		if st.on and not st.off then
			st.off = self.stopAt
		end
	end
	for _, r in self.rumbles do
		r.tOff = r.tOff or self.stopAt
	end
end

function Handle:Destroy()
	finish(self)
end

-- freezes the effect (particles included) on the current moment - handy to look at it closely
function Handle:Pause()
	if self.Done or self.pausedAt then
		return
	end
	self.pausedAt = os.clock()
	local desc = self.desc
	for _, e in self.plan.emitters do
		desc[e.i].TimeScale = 0
	end
	if self.mesh then
		self.mesh.pause(true)
	end
	for s in self.playing do
		if s.Parent and s.IsPlaying then
			s:Pause()
			self.paused[s] = true
		end
	end
end

function Handle:Resume()
	if not self.pausedAt then
		return
	end
	self.start += os.clock() - self.pausedAt
	self.pausedAt = nil
	local desc = self.desc
	for _, e in self.plan.emitters do
		desc[e.i].TimeScale = self.timeScale
	end
	if self.mesh then
		self.mesh.pause(false)
	end
	for s in self.paused do
		if s.Parent then
			s:Resume()
		end
	end
	table.clear(self.paused)
end

-- the handle of an effect that was not played (too far from the camera): already Done, every method works
local Culled = {
	__index = function(self, key)
		if key == "Model" then -- made only if someone looks at it
			local m = Instance.new("Model")
			m.Name = "LostCubeSkipped"
			rawset(self, "Model", m)
			return m
		end
		return Handle[key]
	end,
}

-- ---------------------------------------------------------------------------------------------
-- play
-- ---------------------------------------------------------------------------------------------
function VFX.play(effect: Instance | string, target: any, options: { [string]: any }?): Handle
	local opts = options or {}
	if type(effect) == "string" then
		local lib = library()
		local found = lib and lib:FindFirstChild(effect)
		assert(found, "LostCubeVFX: no effect named " .. effect)
		effect = found
	end
	local template = effect :: Instance
	local scale = opts.scale or 1
	local speed = opts.speed or 1
	local edit = IS_STUDIO and not RunService:IsRunning()
	local quality = math.clamp(opts.quality or VFX.Quality or 1, 0, 1)

	local cached = not edit and PLANS[template]
	local attach = opts.attach or (cached and cached ~= PER_COPY and cached.attach) or template:GetAttribute("LC_Attach") or "GROUND"
	local base, follow = resolve(target, attach)
	if opts.facing then -- point the effect's front along a direction (e.g. where a slide goes)
		local f = Vector3.new(opts.facing.X, 0, opts.facing.Z)
		if f.Magnitude > 1e-3 then
			base = CFrame.lookAt(base.Position, base.Position + f)
		end
	end
	-- far from the camera: not played at all (the handle is already Done)
	local maxDistance = VFX.MaxDistance
	if maxDistance and IS_CLIENT and not edit then
		local c = workspace.CurrentCamera
		if c and (c.CFrame.Position - base.Position).Magnitude > maxDistance then
			return setmetatable({ Done = true }, Culled) :: any
		end
	end

	local model = template:Clone() :: Model
	local desc = model:GetDescendants()
	local plan, ownPlan = planFor(template, desc, model, edit)
	local root = plan.root and desc[plan.root] :: BasePart
	assert(root, "LostCubeVFX: the effect has no Root part")
	model:PivotTo(base)

	-- scale: sizes, distances, particle sizes / speeds, light ranges (keyed lights are set again every frame: r * scale)
	if scale ~= 1 then
		local rootCf = root.CFrame
		for _, i in plan.parts do
			local d = desc[i]
			local rel = rootCf:ToObjectSpace(d.CFrame)
			d.Size *= scale
			d.CFrame = rootCf * (rel - rel.Position + rel.Position * scale)
		end
		for _, i in plan.attachments do
			local a = desc[i]
			a.Position *= scale
		end
		for _, e in plan.emitters do
			local d = desc[e.i]
			d.Size = scaleSequence(d.Size, scale)
			d.Speed = NumberRange.new(d.Speed.Min * scale, d.Speed.Max * scale)
			d.Acceleration *= scale
		end
		for _, i in plan.rangeLights do
			local l = desc[i]
			l.Range = math.min(l.Range * scale, 60)
		end
		for _, s in plan.beams do
			local b = desc[plan.slots[s].i]
			b.Width0 *= scale
			b.Width1 *= scale
			b.CurveSize0 *= scale
			b.CurveSize1 *= scale
		end
	end

	-- parts: invisible, no physics; anchored, or welded to what the effect follows
	for i, fix in plan.fix do
		local d = desc[i]
		for prop, value in fix do
			d[prop] = value
		end
	end
	if follow then
		for _, i in plan.parts do
			local d = desc[i]
			d.Anchored = false
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = d
			weld.Parent = d
		end
		root.Anchored = false
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = follow
		weld.Part1 = root
		weld.Parent = root
	else
		for i in plan.loose do
			desc[i].Anchored = true
		end
	end

	-- emitters: off until their time. TimeScale only goes up to 1, so a faster play shortens lives and speeds particles up
	local timeScale = math.min(speed, 1)
	for _, e in plan.emitters do
		local d = desc[e.i]
		if e.enabled then
			d.Enabled = false
		end
		if e.timeScale ~= timeScale then
			d.TimeScale = timeScale
		end
		if speed > 1 then
			local s = speed
			d.Lifetime = NumberRange.new(d.Lifetime.Min / s, d.Lifetime.Max / s)
			d.Speed = NumberRange.new(d.Speed.Min * s, d.Speed.Max * s)
			d.Acceleration *= s * s
			d.RotSpeed = NumberRange.new(d.RotSpeed.Min * s, d.RotSpeed.Max * s)
			d.Drag *= s
			d.FlipbookFramerate = NumberRange.new(d.FlipbookFramerate.Min * s, d.FlipbookFramerate.Max * s)
		end
		if quality < 1 or speed > 1 then
			d.Rate = e.rate * math.min(quality, 1) * math.max(speed, 1)
		end
	end
	for _, e in plan.trails do
		local d = desc[e.i]
		if e.enabled then
			d.Enabled = false
		end
		local life = math.clamp(e.life / speed, 0.01, 20)
		if life ~= e.life then
			d.Lifetime = life
		end
	end
	for _, i in plan.mutedLights do
		desc[i].Enabled = false
	end
	for _, s in plan.beams do
		desc[plan.slots[s].i].Enabled = false
	end
	model.Parent = opts.parent or workspace

	local h = setmetatable({
		Model = model, Done = false, plan = plan, desc = desc, root = root, follow = follow, speed = speed, scale = scale,
		quality = quality, timeScale = timeScale, edit = edit, noCamera = opts.camera == false, ownPlan = ownPlan,
		start = os.clock(), t = 0, lastT = 0, nextEvent = 1, stopAt = nil :: number?, pausedAt = nil :: number?,
		duration = plan.duration, tail = math.max(plan.tail, plan.trailLife > 0 and math.clamp(plan.trailLife / speed, 0.01, 20) * speed or 0),
		playing = {}, paused = {}, fades = {}, beamState = {}, rumbles = {}, lightVals = {},
	}, Handle)
	for _, s in plan.beams do
		h.beamState[s] = { shown = 0 }
	end

	local ignore = { model }
	if typeof(target) == "Instance" then
		table.insert(ignore, target) -- the character / part the effect is on
	end
	if #plan.grounders > 0 then
		h.grounders = {}
		for _, i in plan.grounders do
			local update = groundRibbon(desc[i], root, model, ignore, opts.facing)
			if update then
				table.insert(h.grounders, update)
				update()
			end
		end
	end
	if #plan.meshes > 0 then
		h.mesh = newMesh(model, ignore, plan, quality)
		for _, s in plan.meshes do
			h.mesh.add(s, desc[plan.slots[s].i], scale, speed)
		end
	end

	table.insert(active, h)
	enforceCap()
	if not heartbeat then
		heartbeat = RunService.Heartbeat:Connect(tick)
	end
	local ok, err = pcall(step, h, h.start) -- what happens at t = 0 happens now
	if not ok then
		finish(h)
		error(err, 0)
	end
	return h
end

-- plays effects when an animation reaches its markers (LostCube exports timeline markers)
function VFX.bindMarkers(track: AnimationTrack, target: any, map: { [string]: string | Instance }, options: { [string]: any }?)
	local conns = {}
	for marker, effect in map do
		table.insert(conns, track:GetMarkerReachedSignal(marker):Connect(function()
			VFX.play(effect, target, options)
		end))
	end
	table.insert(conns, track.Ended:Connect(function()
		for _, c in conns do
			c:Disconnect()
		end
	end))
	return conns
end

-- loads the textures and sounds of a folder of effects before they are first played (avoids a blank first play)
function VFX.preload(folder: Instance?)
	local list = {}
	local source = folder or library()
	if not source then
		return
	end
	for _, d in source:GetDescendants() do
		if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") or d:IsA("Sound") then
			table.insert(list, d)
		end
	end
	task.spawn(function()
		pcall(ContentProvider.PreloadAsync, ContentProvider, list)
	end)
end

-- what the player holds right now (for debugging / profiling)
function VFX.stats()
	local live, plans, pooled = 0, 0, 0
	for _, h in active do
		if not h.Done then
			live += 1
		end
	end
	for _, plan in PLANS do
		if plan ~= PER_COPY then
			plans += 1
			for _, pool in plan.pools do
				pooled += #pool
			end
		end
	end
	return { active = live, plans = plans, pooled = pooled, scheduler = heartbeat ~= nil, camera = #cam.list }
end

return VFX
