--[[ LostCube VFX player
Plays the effects made with LostCube (the Studio plugin's VFX tab, or the Blender exporter).

	local VFX = require(ReplicatedStorage.LostCube.VFX)
	VFX.Library = ReplicatedStorage.LostCube.Effects     -- folder with the exported effects

	VFX.play("TeleportCast", character)                  -- on a character (uses the effect's "Prins de")
	VFX.play("Boom", CFrame.new(0, 5, 0))                -- at a place
	local h = VFX.play(effect, part, { scale = 1.5, speed = 1, attach = "ROOT", parent = workspace })
	VFX.play("Scrape", character, { attach = "RIGHT_FOOT", facing = moveDirection }) -- front = facing
	h:Stop()                                             -- stop emitting; cleans up when the last particle is gone
	h:Pause() / h:Resume()                               -- freeze on the current moment (to look at it)

	VFX.bindMarkers(track, character, { Cast = "TeleportCast" })  -- play effects on animation markers

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
Effect (Model) attributes: LC_Duration, LC_Attach (GROUND, GROUND_FOLLOW, ROOT, TORSO, HEAD, RIGHT_HAND,
LEFT_HAND, RIGHT_FOOT, LEFT_FOOT, WORLD). Effects are meant to be played on the client (each client plays its own copy).
]]
local RunService = game:GetService("RunService")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")

local VFX = {}
VFX.Library = nil :: Instance?

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

local function applyScale(model: Model, root: BasePart, k: number)
	if k == 1 then
		return
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= root then
			local rel = root.CFrame:ToObjectSpace(d.CFrame)
			d.Size *= k
			d.CFrame = root.CFrame * (rel - rel.Position + rel.Position * k)
		elseif d:IsA("Attachment") then
			d.Position *= k
		elseif d:IsA("ParticleEmitter") then
			d.Size = scaleSequence(d.Size, k)
			d.Speed = NumberRange.new(d.Speed.Min * k, d.Speed.Max * k)
			d.Acceleration *= k
		end
	end
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

-- ---------------------------------------------------------------------------------------------
-- 3D mesh elements: pieces spawned from a Part template (rings, cracks, smoke balls, grooves, debris)
-- ---------------------------------------------------------------------------------------------
local NORMALS = {
	Top = Vector3.yAxis, Bottom = -Vector3.yAxis, Front = -Vector3.zAxis, Back = Vector3.zAxis,
	Right = Vector3.xAxis, Left = -Vector3.xAxis,
}

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

local function newMesh(model, ignore)
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

	local function piece(template, cf, size, alpha)
		local p = template:Clone()
		for _, c in p:GetChildren() do
			c:Destroy()
		end
		for name in p:GetAttributes() do
			p:SetAttribute(name, nil)
		end
		p.Name = template.Name .. "_"
		p.Anchored = true
		p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = false, false, false, false
		p.Size = size
		p.CFrame = cf
		p.Transparency = alpha
		p.Parent = model
		return p
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

	local function fadeOut(p, life, a1, colorEnd)
		local goal = { Transparency = a1 }
		if colorEnd then
			goal.Color = colorEnd
		end
		tween(p, life, goal, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(life + 0.05, function()
			if not self.paused then
				p:Destroy()
			end
		end)
	end

	function self.add(template, scale, speed)
		local e = {
			t = template, scale = scale, speed = speed, acc = 0, on = false,
			mode = template:GetAttribute("LC_Mode"), rate = template:GetAttribute("LC_Rate") or 0,
			colorEnd = template:GetAttribute("LC_ColorEnd"),
			dir = template:GetAttribute("LC_Dir") or "Top", rise = template:GetAttribute("LC_Rise") or 0,
			spin = template:GetAttribute("LC_Spin") or 0, count = template:GetAttribute("LC_Count") or 16,
			jitter = template:GetAttribute("LC_Jitter") or 0, base = template.Size,
			ground = template:GetAttribute("LC_Ground") == true,
		}
		e.life0, e.life1 = pair(template:GetAttribute("LC_Life"), 0.5, 0.5)
		e.g0, e.g1 = pair(template:GetAttribute("LC_Grow"), 1, 1)
		e.a0, e.a1 = pair(template:GetAttribute("LC_Alpha"), 0, 1)
		e.s0, e.s1 = pair(template:GetAttribute("LC_Speed"), 0, 0)
		e.sx, e.sy = pair(template:GetAttribute("LC_Spread"), 0, 0)
		e.r0, e.r1 = pair(template:GetAttribute("LC_Radius"), 1, 6)
		table.insert(self.elements, e)
		return e
	end

	function self.tail(e)
		return math.max(e.life0, e.life1) + 0.2
	end

	function self.spawn(e, n)
		for _ = 1, n or 1 do
			local t, k = e.t, e.scale
			local cf = e.ground and onGround(t.CFrame) or t.CFrame
			local life = rnd(e.life0, e.life1) / e.speed
			local jit = 1 + (math.random() * 2 - 1) * e.jitter
			local base = e.base * k * jit
			if e.mode == "Ring" then
				local count = math.max(3, e.count)
				local r0, r1 = e.r0 * k, e.r1 * k
				for i = 1, count do
					local a = (i - 1) / count * math.pi * 2
					local function at(r)
						return cf * CFrame.new(math.cos(a) * r, 0, math.sin(a) * r) * CFrame.Angles(0, -(a + math.pi / 2), 0)
					end
					local len0 = math.max(base.X * e.g0, 2 * math.pi * r0 / count * 1.02)
					local len1 = math.max(base.X * e.g1, 2 * math.pi * r1 / count * 1.02)
					local p = piece(t, at(r0), Vector3.new(len0, base.Y * e.g0, base.Z * e.g0), e.a0)
					tween(p, life, { CFrame = at(r1), Size = Vector3.new(len1, base.Y * e.g1, base.Z * e.g1) },
						Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
					fadeOut(p, life, e.a1, e.colorEnd)
				end
			elseif e.mode == "Crack" then
				local count = math.max(1, e.count)
				for i = 1, count do
					local a = (i - 1) / count * math.pi * 2 + rnd(-0.35, 0.35)
					local dir = cf:VectorToWorldSpace(Vector3.new(math.cos(a), 0, math.sin(a)))
					local len = rnd(e.r0, e.r1) * k
					local function at(l)
						return CFrame.lookAt(cf.Position, cf.Position + dir) * CFrame.new(0, 0, -l / 2)
					end
					local p = piece(t, at(0.1), Vector3.new(base.X, base.Y, 0.2), e.a0)
					tween(p, math.min(0.14, life * 0.3), { CFrame = at(len), Size = Vector3.new(base.X, base.Y, len) },
						Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
					fadeOut(p, life, e.a1, e.colorEnd)
				end
			elseif e.mode == "Pulse" then
				local p = piece(t, cf, base * e.g0, e.a0)
				tween(p, life, { Size = base * e.g1 }, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
				fadeOut(p, life, e.a1, e.colorEnd)
			elseif e.mode == "Puff" then
				local dir = spreadDir(cf, e.dir, e.sx, e.sy)
				local speed = rnd(e.s0, e.s1) * k
				local from = cf.Position + Vector3.new(rnd(-0.3, 0.3), rnd(0, 0.2), rnd(-0.3, 0.3)) * k
				local to = from + dir * speed * life * 0.45 + Vector3.new(0, e.rise * k, 0)
				local spin = CFrame.Angles(math.random() * 6.28, math.random() * 6.28, math.random() * 6.28)
				local p = piece(t, CFrame.new(from) * spin, base * e.g0, e.a0)
				tween(p, life, { CFrame = CFrame.new(to) * spin, Size = base * e.g1 }, Enum.EasingStyle.Quart,
					Enum.EasingDirection.Out)
				fadeOut(p, life, e.a1, e.colorEnd)
			elseif e.mode == "Trail" then
				local yaw = CFrame.new(0, rnd(0, 0.012), 0) * CFrame.Angles(0, math.rad(rnd(-2.5, 2.5)), 0) -- no z-fighting
				local p = piece(t, cf * yaw, base * e.g0, e.a0)
				tween(p, life, { Size = base * e.g1 }, Enum.EasingStyle.Linear)
				fadeOut(p, life, e.a1, e.colorEnd)
			elseif e.mode == "Debris" then
				local p = piece(t, cf * CFrame.new(rnd(-0.2, 0.2) * k, 0.15 * k, rnd(-0.2, 0.2) * k)
					* CFrame.Angles(math.random() * 6.28, math.random() * 6.28, math.random() * 6.28), base * e.g0, e.a0)
				p.Anchored = self.paused
				p.CanCollide = true
				p.Massless = false
				p.CustomPhysicalProperties = PhysicalProperties.new(0.4, 0.6, 0.35)
				p.AssemblyLinearVelocity = spreadDir(cf, e.dir, e.sx, e.sy) * rnd(e.s0, e.s1) * k
				p.AssemblyAngularVelocity = Vector3.new(rnd(-1, 1), rnd(-1, 1), rnd(-1, 1)) * e.spin
				self.debris[p] = true
				task.delay(life * 0.6, function()
					if p.Parent then
						tween(p, life * 0.4, { Transparency = e.a1, Size = base * e.g1 }, Enum.EasingStyle.Quad,
							Enum.EasingDirection.In)
					end
				end)
				task.delay(life + 0.05, function()
					if not self.paused then
						self.debris[p] = nil
						p:Destroy()
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

export type Handle = {
	Model: Model,
	Done: boolean,
	Stop: (Handle) -> (),
	Destroy: (Handle) -> (),
	Pause: (Handle) -> (),
	Resume: (Handle) -> (),
}

function VFX.play(effect: Instance | string, target: any, options: { [string]: any }?): Handle
	local opts = options or {}
	if type(effect) == "string" then
		local found = VFX.Library and VFX.Library:FindFirstChild(effect)
		assert(found, "LostCubeVFX: no effect named " .. effect)
		effect = found
	end
	local template = effect :: Instance
	local scale = opts.scale or 1
	local speed = opts.speed or 1
	local model = template:Clone() :: Model
	local root = (model.PrimaryPart or model:FindFirstChild("Root")) :: BasePart
	assert(root, "LostCubeVFX: the effect has no Root part")
	local attach = opts.attach or model:GetAttribute("LC_Attach") or "GROUND"
	local base, follow = resolve(target, attach)
	if opts.facing then -- point the effect's front along a direction (e.g. where a slide goes)
		local f = Vector3.new(opts.facing.X, 0, opts.facing.Z)
		if f.Magnitude > 1e-3 then
			base = CFrame.lookAt(base.Position, base.Position + f)
		end
	end
	model:PivotTo(base)
	applyScale(model, root, scale)

	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
			d.Massless = true
			d.Transparency = 1
			d.Anchored = follow == nil
			if follow and d ~= root then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = root
				weld.Part1 = d
				weld.Parent = d
			end
		elseif d:IsA("ParticleEmitter") then
			d.Enabled = false
			d.TimeScale = speed
		elseif d:IsA("Trail") then
			d.Enabled = false
		end
	end
	if follow then
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = follow
		weld.Part1 = root
		weld.Parent = root
	end
	model.Parent = opts.parent or workspace

	-- timeline
	local events = {}
	local lights = {}
	local tail = 0
	local ignore = { model }
	if typeof(target) == "Instance" then
		table.insert(ignore, target) -- the character / part the effect is on
	end
	local mesh = newMesh(model, ignore)
	local grounders = {}
	local function at(t, fn)
		table.insert(events, { t = t, fn = fn })
	end
	for _, d in model:GetDescendants() do
		if d:GetAttribute("LC_Muted") then -- switched off in the editor
			if d:IsA("PointLight") then
				d.Enabled = false
			end
			continue
		end
		if d:IsA("Trail") and d:GetAttribute("LC_Ground") then -- ribbon lying on the floor
			local update = groundRibbon(d, root, model, ignore, opts.facing)
			if update then
				table.insert(grounders, update)
				update()
			end
		end
		if d:IsA("BasePart") and d:GetAttribute("LC_Mode") then -- 3D mesh element
			local e = mesh.add(d, scale, speed)
			for _, w in parseList(d:GetAttribute("LC_On")) do
				at(w[1] or 0, function()
					e.on = true
				end)
				at(w[2] or 0, function()
					e.on = false
				end)
			end
			for _, b in parseList(d:GetAttribute("LC_Bursts")) do
				at(b[1] or 0, function()
					mesh.spawn(e, b[2] or 1)
				end)
			end
			tail = math.max(tail, mesh.tail(e) / speed)
		elseif d:IsA("ParticleEmitter") or d:IsA("Trail") then
			local emitter = d
			for _, w in parseList(d:GetAttribute("LC_On")) do
				at(w[1] or 0, function()
					emitter.Enabled = true
				end)
				at(w[2] or 0, function()
					emitter.Enabled = false
				end)
			end
			if d:IsA("ParticleEmitter") then
				local particles = d
				for _, b in parseList(d:GetAttribute("LC_Bursts")) do
					at(b[1] or 0, function()
						particles:Emit(b[2] or 1)
					end)
				end
				tail = math.max(tail, d.Lifetime.Max)
			else
				tail = math.max(tail, (d :: Trail).Lifetime)
			end
		elseif d:IsA("PointLight") then
			local keys = parseList(d:GetAttribute("LC_Keys"))
			if #keys > 0 then
				table.insert(lights, { light = d, keys = keys })
			end
		end
	end
	table.sort(events, function(a, b)
		return a.t < b.t
	end)

	local duration = model:GetAttribute("LC_Duration") or 1
	local start = os.clock()
	local nextEvent = 1
	local stopAt: number? = nil
	local pausedAt: number? = nil
	local conn: RBXScriptConnection? = nil
	local handle = { Model = model, Done = false } :: any

	local function cleanup()
		if conn then
			conn:Disconnect()
			conn = nil
		end
		handle.Done = true
		model:Destroy()
	end

	local lastT = 0
	local function step()
		if pausedAt then
			return
		end
		for _, update in grounders do
			update()
		end
		local t = (os.clock() - start) * speed
		while not stopAt and nextEvent <= #events and events[nextEvent].t <= t do
			events[nextEvent].fn()
			nextEvent += 1
		end
		if not stopAt then
			mesh.step(math.max(0, t - lastT))
		end
		lastT = t
		for _, l in lights do
			local b, r = lightAt(l.keys, t)
			l.light.Brightness = b
			l.light.Range = r * scale
		end
		if t >= (stopAt or duration) + tail then
			cleanup()
		end
	end

	function handle:Stop()
		if self.Done or stopAt then
			return
		end
		stopAt = (os.clock() - start) * speed
		for _, d in model:GetDescendants() do
			if d:IsA("ParticleEmitter") or d:IsA("Trail") then
				d.Enabled = false
			end
		end
		for _, e in mesh.elements do
			e.on = false
		end
	end

	function handle:Destroy()
		cleanup()
	end

	-- freezes the effect (particles included) on the current moment - handy to look at it closely
	function handle:Pause()
		if self.Done or pausedAt then
			return
		end
		pausedAt = os.clock()
		for _, d in model:GetDescendants() do
			if d:IsA("ParticleEmitter") then
				d.TimeScale = 0
			end
		end
		mesh.pause(true)
	end

	function handle:Resume()
		if not pausedAt then
			return
		end
		start += os.clock() - pausedAt
		pausedAt = nil
		for _, d in model:GetDescendants() do
			if d:IsA("ParticleEmitter") then
				d.TimeScale = speed
			end
		end
		mesh.pause(false)
	end

	conn = RunService.Heartbeat:Connect(step)
	step() -- what happens at t = 0 happens now
	return handle
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

-- loads the textures of a folder of effects before they are first played (avoids a blank first play)
function VFX.preload(folder: Instance?)
	local list = {}
	for _, d in (folder or VFX.Library or Instance.new("Folder")):GetDescendants() do
		if d:IsA("ParticleEmitter") or d:IsA("Trail") then
			table.insert(list, d)
		end
	end
	task.spawn(function()
		pcall(ContentProvider.PreloadAsync, ContentProvider, list)
	end)
end

return VFX
