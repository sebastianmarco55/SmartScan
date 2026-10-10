-- AnimGen against a small Roblox mock (Instance, CFrame, Enum, ServerStorage, ChangeHistoryService): generate builds a
-- KeyframeSequence (poses under the right parents, easing, markers, loop, priority), save puts it where the Animation
-- Editor looks (ServerStorage.RBX_ANIMSAVES, one undo step), measure reads the proportions of a rig.
local LC = ...
local t = LC.kit.new("animgen_build")
local function check(cond, msg)
	t.check(cond, msg)
end
local M -- filled after AnimGen loads

-- Vector3 / CFrame ---------------------------------------------------------------------------
local V3 = {}
V3.__index = function(v, k)
	if k == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	end
	return nil
end
local function vec(x, y, z)
	return setmetatable({ X = x, Y = y, Z = z }, V3)
end
V3.__sub = function(a, b)
	return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
V3.__add = function(a, b)
	return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end

local CF = {}
CF.__index = function(c, k)
	if k == "Position" then
		return vec(c.p[1], c.p[2], c.p[3])
	end
	return nil
end
local CFrame = {}
function CFrame.new(x, y, z, ...)
	local r = { ... }
	if #r == 0 then
		r = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
	end
	assert(#r == 9, "CFrame.new needs 0 or 9 rotation components")
	return setmetatable({ p = { x or 0, y or 0, z or 0 }, r = r }, CF)
end
CF.__mul = function(a, b)
	local q = M.apply(a.r, b.p)
	return setmetatable({ r = M.mul(a.r, b.r), p = { a.p[1] + q[1], a.p[2] + q[2], a.p[3] + q[3] } }, CF)
end

-- Enum ---------------------------------------------------------------------------------------
local Enum = setmetatable({}, { __index = function(_, enumName)
	return setmetatable({}, { __index = function(_, item)
		return { enum = enumName, name = item }
	end })
end })

-- Instance -----------------------------------------------------------------------------------
local Methods = {}
local IMT = {}
IMT.__index = function(t, k)
	if k == "Parent" then
		return rawget(t, "_parent")
	end
	return Methods[k]
end
IMT.__newindex = function(t, k, v)
	if k == "Parent" then
		local old = rawget(t, "_parent")
		if old then
			local list = old._children
			for i, c in list do
				if c == t then
					table.remove(list, i)
					break
				end
			end
		end
		rawset(t, "_parent", v)
		if v then
			table.insert(v._children, t)
		end
	else
		rawset(t, k, v)
	end
end
local Instance = {}
function Instance.new(class)
	return setmetatable({ ClassName = class, Name = class, _children = {}, _attrs = {}, _markers = {} }, IMT)
end
local BASES = { Part = { BasePart = true }, Motor6D = { JointInstance = true } }
function Methods:IsA(class)
	return self.ClassName == class or (BASES[self.ClassName] and BASES[self.ClassName][class]) or false
end
function Methods:FindFirstChild(name)
	for _, c in self._children do
		if c.Name == name then
			return c
		end
	end
	return nil
end
function Methods:FindFirstChildOfClass(class)
	for _, c in self._children do
		if c.ClassName == class then
			return c
		end
	end
	return nil
end
function Methods:GetChildren()
	return table.clone(self._children)
end
function Methods:GetDescendants()
	local out = {}
	local function walk(i)
		for _, c in i._children do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(self)
	return out
end
function Methods:SetAttribute(k, v)
	assert(type(k) == "string" and not k:find("[^%w_]"), "bad attribute name " .. tostring(k))
	self._attrs[k] = v
end
function Methods:GetAttribute(k)
	return self._attrs[k]
end
function Methods:AddMarker(m)
	assert(self.ClassName == "Keyframe")
	table.insert(self._markers, m)
end
function Methods:GetMarkers()
	return self._markers
end
function Methods:GetFullName()
	local names, i = {}, self
	while i and i.ClassName ~= "DataModel" do
		table.insert(names, 1, i.Name)
		i = i._parent
	end
	return table.concat(names, ".")
end

-- game ---------------------------------------------------------------------------------------
local recordings = {}
local services = {
	ServerStorage = Instance.new("ServerStorage"),
	ChangeHistoryService = {
		TryBeginRecording = function(_, name)
			table.insert(recordings, { name = name })
			return "rec" .. #recordings
		end,
		FinishRecording = function(_, id, op)
			recordings[#recordings].finished = op.name
		end,
	},
}
services.ServerStorage.Name = "ServerStorage"
local game = { GetService = function(_, name)
	return services[name]
end }


-- load the real AnimGen with these globals ------------------------------------------------------------------------
local tree = LC.modtree.new{ env = LC.env{ game = game, Instance = Instance, CFrame = CFrame, Enum = Enum, Vector3 = { new = vec } } }
local AnimGen = tree.load("AnimGen")
M = AnimGen.M

-- generate -----------------------------------------------------------------------------------
for _, rigType in { "R15", "R6" } do
	for _, item in AnimGen.LIST do
		local ok, kfs = pcall(AnimGen.generate, item.key, rigType, { hipHeight = 2 })
		check(ok, item.key .. " " .. rigType .. " generates: " .. tostring(kfs))
		if ok then
			check(kfs.ClassName == "KeyframeSequence" and kfs.Loop == item.looped, item.key .. ": KFS loop")
			check(kfs.Priority.name == item.priority, item.key .. ": priority")
			check(kfs.AuthoredHipHeight == 2, item.key .. ": authored hip height")
			check(kfs:GetAttribute("LC_Gen") == item.key, item.key .. ": attribute")
			local markerCount, last = 0, -1
			for _, kf in kfs:GetChildren() do
				check(kf.ClassName == "Keyframe", "keyframe class")
				check(kf.Time > last, item.key .. ": increasing keyframe times")
				last = kf.Time
				markerCount += #kf:GetMarkers()
				local poses = kf:GetChildren()
				if #poses > 0 then
					check(#poses == 1 and poses[1].Name == "HumanoidRootPart" and poses[1].Weight == 0,
						item.key .. ": one root pose HumanoidRootPart (weight 0)")
					for _, p in poses[1]:GetDescendants() do
						check(p.ClassName == "Pose", "pose class")
						check(p.Weight == 1 or p.Weight == 0, "pose weight")
						if p.Weight == 1 then
							check(getmetatable(p.CFrame) == CF, item.key .. ": animated pose has a CFrame")
						end
						check(p.EasingStyle ~= nil and p.EasingDirection ~= nil, "pose easing")
						local parent = p.Parent
						local expected = AnimGen.RIGS[rigType].parent[p.Name]
						check(parent.Name == expected, string.format("%s: %s under %s (got %s)", item.key, p.Name,
							tostring(expected), parent.Name))
					end
				end
			end
			check(markerCount == #item.markers, item.key .. ": markers on keyframes")
			check(math.abs(last - item.length) < 1e-6, item.key .. ": ends at its length")
		end
	end
end
do
	local kfs = AnimGen.generate("punch_combo", "R15")
	local pose = kfs:GetChildren()[2]:GetChildren()[1]:FindFirstChild("LowerTorso")
	check(pose and pose.EasingStyle.name == "CubicV2", "Cubic uses CubicV2 when available")
	check(pose and pose:FindFirstChild("UpperTorso") ~= nil, "nested UpperTorso pose")
	local mirrored = AnimGen.generate("wave", "R15", { mirror = true })
	check(mirrored.Name:find("oglindit") ~= nil, "mirrored name")
end

-- save ---------------------------------------------------------------------------------------
do
	local rig = Instance.new("Model")
	rig.Name = "Dummy"
	local a = AnimGen.save(AnimGen.generate("kick", "R15"), rig)
	local b = AnimGen.save(AnimGen.generate("kick", "R15"), rig)
	local c = AnimGen.save(AnimGen.generate("kick", "R6"), nil)
	local saves = services.ServerStorage:FindFirstChild("RBX_ANIMSAVES")
	check(saves and saves.ClassName == "Model", "RBX_ANIMSAVES created as Model")
	local entry = saves:FindFirstChild("Dummy")
	check(entry and entry.ClassName == "ObjectValue" and entry.Value == rig, "rig entry is an ObjectValue -> rig")
	check(a.Parent == entry and b.Parent == entry and a.Name ~= b.Name, "unique names: " .. a.Name .. " / " .. b.Name)
	check(c.Parent == saves:FindFirstChild("LostCube"), "no rig -> LostCube entry")
	check(#recordings == 3 and recordings[1].finished == "Commit", "one committed recording per save")
	check(a:GetFullName() == "ServerStorage.RBX_ANIMSAVES.Dummy.Lovitură cu piciorul", "full name " .. a:GetFullName())
end

-- measure ------------------------------------------------------------------------------------
do
	local function part(name, parent, cf, size)
		local p = Instance.new("Part")
		p.Name, p.CFrame, p.Size, p.Position = name, cf, size, cf.Position
		p.Parent = parent
		return p
	end
	local function motor(name, p0, p1, c0, c1)
		local m = Instance.new("Motor6D")
		m.Name, m.Part0, m.Part1, m.C0, m.C1 = name, p0, p1, c0, c1
		m.Parent = p1
	end
	local rig = Instance.new("Model")
	local hum = Instance.new("Humanoid")
	hum.HipHeight = 2
	hum.Parent = rig
	local hrp = part("HumanoidRootPart", rig, CFrame.new(0, 3, 0), vec(2, 2, 1))
	local lt = part("LowerTorso", rig, CFrame.new(0, 2.25, 0), vec(2, 0.4, 1))
	local ul = part("RightUpperLeg", rig, CFrame.new(0.5, 1.5, 0), vec(1, 1.2, 1))
	local ll = part("RightLowerLeg", rig, CFrame.new(0.5, 0.8, 0), vec(1, 1.1, 1))
	local ft = part("RightFoot", rig, CFrame.new(0.5, 0.15, 0), vec(1, 0.3, 1))
	motor("Root", hrp, lt, CFrame.new(0, -0.65, 0), CFrame.new(0, 0.1, 0))
	motor("RightHip", lt, ul, CFrame.new(0.5, -0.27, 0), CFrame.new(0, 0.45, 0))
	motor("RightKnee", ul, ll, CFrame.new(0, -0.43, 0), CFrame.new(0, 0.3, 0))
	motor("RightAnkle", ll, ft, CFrame.new(0, -0.58, 0), CFrame.new(0, 0.07, 0))
	local info = AnimGen.measure(rig)
	check(info.rigType == "R15", "measure: rig type")
	check(info.rootHeight and math.abs(info.rootHeight - 2.35) < 1e-6, "measure: root height " .. tostring(info.rootHeight))
	check(info.thigh and math.abs(info.thigh - 0.88) < 1e-6 and math.abs(info.shin - 0.88) < 1e-6, "measure: leg lengths")
	check(info.hipHeight == 2, "measure: hip height")
	local ok = pcall(AnimGen.generate, "death", "R15", info)
	check(ok, "generate with measured info")

	local r6 = Instance.new("Model")
	local h6 = Instance.new("Humanoid")
	h6.Parent = r6
	local hrp6 = part("HumanoidRootPart", r6, CFrame.new(0, 3, 0), vec(2, 2, 1))
	local torso = part("Torso", r6, CFrame.new(0, 3, 0), vec(2, 2, 1))
	part("Right Leg", r6, CFrame.new(0.5, 1, 0), vec(1, 2, 1))
	local q = { -1, 0, 0, 0, 0, 1, 0, 1, 0 }
	motor("RootJoint", hrp6, torso, CFrame.new(0, 0, 0, table.unpack(q)), CFrame.new(0, 0, 0, table.unpack(q)))
	local i6 = AnimGen.measure(r6)
	check(i6.rigType == "R6" and i6.rootHeight and math.abs(i6.rootHeight - 3) < 1e-6, "measure R6 root height " .. tostring(i6.rootHeight))
	check(next(AnimGen.measure(Instance.new("Model"))) == nil, "measure on an empty model is empty")
end



t.finish()
