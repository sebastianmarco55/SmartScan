-- Typed Roblox mock driven by (a subset of) the real API dump: property names, value types and enum members of the
-- classes in tests/data/api_subset.json are enforced (assigning a wrong type or an unknown property raises, like Roblox).
-- Datatypes and instances are userdata (newproxy), so type(x) == "userdata" like in Roblox. Regenerate the subset with
-- checks/make_api_subset.py when a suite needs another class.
--
--     local ENV = LC.run("tests/mocks/api_env.luau", nil, LC)  -- the globals the plugin sources see (+ test helpers)
--     ENV.newInstance("Part")  ENV.__DATA[inst].destroyed  ENV.__history.log  ENV.__services.X  ENV.freeModel()
local LC = ...
local API = LC.run("tests/data/api_subset.luau")

local ENV = LC.env()
ENV.warn = function(...) print("WARN:", ...) end

local DATA = setmetatable({}, { __mode = "k" })
local function proto(name, mt)
	local class = { __type = name }
	for k, v in mt do class[k] = v end
	return class
end
local function make(class, fields)
	local o = newproxy(true)
	local m = getmetatable(o)
	for k, v in class do m[k] = v end
	DATA[o] = fields
	return o
end
local rawtypeof = typeof
local function typeofx(v)
	local ok, mt = pcall(getmetatable, v)
	if ok and type(mt) == "table" and mt.__type then
		return mt.__type
	end
	return rawtypeof(v)
end
ENV.typeof = typeofx

-- Vector3 -------------------------------------------------------------------------------------
local V3P
local function v3(x, y, z) return make(V3P, { X = x, Y = y, Z = z }) end
V3P = proto("Vector3", {
	__index = function(self, k)
		local d = DATA[self]
		if d[k] ~= nil then return d[k] end
		if k == "Magnitude" then return math.sqrt(d.X ^ 2 + d.Y ^ 2 + d.Z ^ 2) end
		if k == "Unit" then local m = math.sqrt(d.X ^ 2 + d.Y ^ 2 + d.Z ^ 2); return v3(d.X / m, d.Y / m, d.Z / m) end
		if k == "Dot" then return function(_, o) return d.X * o.X + d.Y * o.Y + d.Z * o.Z end end
		if k == "Cross" then return function(_, o) return v3(d.Y * o.Z - d.Z * o.Y, d.Z * o.X - d.X * o.Z, d.X * o.Y - d.Y * o.X) end end
		if k == "Lerp" then return function(_, o, a) return v3(d.X + (o.X - d.X) * a, d.Y + (o.Y - d.Y) * a, d.Z + (o.Z - d.Z) * a) end end
		error("Vector3 has no " .. tostring(k))
	end,
	__unm = function(a) return v3(-a.X, -a.Y, -a.Z) end,
	__add = function(a, b) return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end,
	__sub = function(a, b) return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end,
	__mul = function(a, b)
		if type(a) == "number" then return v3(a * b.X, a * b.Y, a * b.Z) end
		if type(b) == "number" then return v3(a.X * b, a.Y * b, a.Z * b) end
		return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
	end,
	__div = function(a, b)
		if type(b) == "number" then return v3(a.X / b, a.Y / b, a.Z / b) end
		return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
	end,
	__eq = function(a, b) return DATA[a].X == DATA[b].X and DATA[a].Y == DATA[b].Y and DATA[a].Z == DATA[b].Z end,
	__tostring = function(a) return string.format("(%g, %g, %g)", a.X, a.Y, a.Z) end,
})
ENV.Vector3 = { new = function(x, y, z) return v3(x or 0, y or 0, z or 0) end, zero = v3(0, 0, 0), one = v3(1, 1, 1),
	xAxis = v3(1, 0, 0), yAxis = v3(0, 1, 0), zAxis = v3(0, 0, 1) }

local V2P
V2P = proto("Vector2", { __index = function(self, k) return DATA[self][k] end,
	__eq = function(a, b) return DATA[a].X == DATA[b].X and DATA[a].Y == DATA[b].Y end })
ENV.Vector2 = { new = function(x, y) return make(V2P, { X = x or 0, Y = y or 0 }) end }

-- CFrame (position only: no rotations are needed by the code under test) ------------------------
local CFP
local function cf(p) return make(CFP, { p = p }) end
CFP = proto("CFrame", {
	__index = function(self, k)
		local d = DATA[self]
		if k == "Position" then return d.p end
		if k == "PointToObjectSpace" then return function(_, v) return v - d.p end end
		if k == "PointToWorldSpace" then return function(_, v) return d.p + v end end
		if k == "ToObjectSpace" then return function(_, o) return cf(o.Position - d.p) end end
		if k == "LookVector" then return v3(0, 0, -1) end
		error("CFrame has no " .. tostring(k))
	end,
	__mul = function(a, b)
		if typeofx(b) == "Vector3" then return a.Position + b end
		return cf(a.Position + b.Position)
	end,
	__sub = function(a, b) return cf(a.Position - b) end,
	__add = function(a, b) return cf(a.Position + b) end,
	__eq = function(a, b) return DATA[a].p == DATA[b].p end,
})
ENV.CFrame = { new = function(p) return cf(p or v3(0, 0, 0)) end }

-- Color3 ---------------------------------------------------------------------------------------
local C3P
local function c3(r, g, b) return make(C3P, { R = r, G = g, B = b }) end
local function hsv2rgb(h, s, v)
	h = h % 1
	local i = math.floor(h * 6)
	local f = h * 6 - i
	local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	i = i % 6
	if i == 0 then return v, t, p elseif i == 1 then return q, v, p elseif i == 2 then return p, v, t
	elseif i == 3 then return p, q, v elseif i == 4 then return t, p, v else return v, p, q end
end
C3P = proto("Color3", {
	__index = function(self, k)
		local d = DATA[self]
		if d[k] ~= nil then return d[k] end
		if k == "ToHSV" then
			return function(c)
				local r, g, b = c.R, c.G, c.B
				local mx, mn = math.max(r, g, b), math.min(r, g, b)
				local dlt = mx - mn
				local h = 0
				if dlt > 0 then
					if mx == r then h = ((g - b) / dlt) % 6 elseif mx == g then h = (b - r) / dlt + 2 else h = (r - g) / dlt + 4 end
					h = h / 6
				end
				return h, mx == 0 and 0 or dlt / mx, mx
			end
		elseif k == "ToHex" then
			return function(c) return string.format("%02x%02x%02x", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5)) end
		end
		error("Color3 has no " .. tostring(k))
	end,
	__eq = function(a, b) return DATA[a].R == DATA[b].R and DATA[a].G == DATA[b].G and DATA[a].B == DATA[b].B end,
	__tostring = function(a) return string.format("C3(%d,%d,%d)", a.R * 255 + 0.5, a.G * 255 + 0.5, a.B * 255 + 0.5) end,
})
ENV.Color3 = {
	new = function(r, g, b) return c3(r or 0, g or 0, b or 0) end,
	fromRGB = function(r, g, b) return c3(r / 255, g / 255, b / 255) end,
	fromHex = function(s) s = s:gsub("#", ""); assert(#s == 6, "bad hex"); return c3(tonumber(s:sub(1, 2), 16) / 255, tonumber(s:sub(3, 4), 16) / 255, tonumber(s:sub(5, 6), 16) / 255) end,
	fromHSV = function(h, s, v) local r, g, b = hsv2rgb(h, s, v); return c3(r, g, b) end,
}

-- sequences -------------------------------------------------------------------------------------
local NRP = proto("NumberRange", { __index = function(self, k) return DATA[self][k] end })
ENV.NumberRange = { new = function(a, b) return make(NRP, { Min = a, Max = b or a }) end }
local NSKP = proto("NumberSequenceKeypoint", { __index = function(self, k) return DATA[self][k] end })
ENV.NumberSequenceKeypoint = { new = function(t, v, e) assert(t >= 0 and t <= 1, "keypoint time out of range " .. tostring(t)); return make(NSKP, { Time = t, Value = v, Envelope = e or 0 }) end }
local NSP = proto("NumberSequence", { __index = function(self, k) return DATA[self][k] end })
ENV.NumberSequence = { new = function(a, b)
	local points
	if type(a) == "table" then
		points = a
		assert(#points >= 2, "NumberSequence needs at least 2 keypoints")
		assert(points[1].Time == 0 and points[#points].Time == 1, "NumberSequence must start at 0 and end at 1")
		for i = 2, #points do assert(points[i].Time > points[i - 1].Time, "NumberSequence keypoints must be increasing") end
	elseif b then points = { ENV.NumberSequenceKeypoint.new(0, a), ENV.NumberSequenceKeypoint.new(1, b) }
	else points = { ENV.NumberSequenceKeypoint.new(0, a), ENV.NumberSequenceKeypoint.new(1, a) } end
	return make(NSP, { Keypoints = points })
end }
local CSKP = proto("ColorSequenceKeypoint", { __index = function(self, k) return DATA[self][k] end })
ENV.ColorSequenceKeypoint = { new = function(t, c) assert(t >= 0 and t <= 1); return make(CSKP, { Time = t, Value = c }) end }
local CSP = proto("ColorSequence", { __index = function(self, k) return DATA[self][k] end })
ENV.ColorSequence = { new = function(a, b)
	local points
	if type(a) == "table" then
		points = a
		assert(#points >= 2, "ColorSequence needs at least 2 keypoints")
		assert(points[1].Time == 0 and points[#points].Time == 1, "ColorSequence must start at 0 and end at 1")
		for i = 2, #points do assert(points[i].Time > points[i - 1].Time, "ColorSequence keypoints must be increasing") end
	elseif b then points = { ENV.ColorSequenceKeypoint.new(0, a), ENV.ColorSequenceKeypoint.new(1, b) }
	else points = { ENV.ColorSequenceKeypoint.new(0, a), ENV.ColorSequenceKeypoint.new(1, a) } end
	return make(CSP, { Keypoints = points })
end }

-- Enum --------------------------------------------------------------------------------------------
local EIP = proto("EnumItem", { __index = function(self, k) return DATA[self][k] end, __tostring = function(s) return "Enum." .. DATA[s].EnumName .. "." .. DATA[s].Name end })
local ENUMS = {}
ENV.Enum = setmetatable({}, { __index = function(_, name)
	if ENUMS[name] then return ENUMS[name] end
	local list = API.enums[name]
	if not list then error("Enum." .. tostring(name) .. " is not an Enum (or not in the mock)") end
	local items = {}
	local enum = setmetatable({}, { __index = function(_, item)
		if items[item] then return items[item] end
		error(tostring(item) .. " is not a valid member of Enum." .. name)
	end })
	for _, item in list do items[item[1]] = make(EIP, { Name = item[1], Value = item[2], EnumName = name, EnumType = enum }) end
	ENUMS[name] = enum
	return enum
end })

-- Instance -----------------------------------------------------------------------------------------
local INP
local function typeParts(t) -- "D:Vector3:ro" -> "D", "Vector3", true
	local cat, name, ro = t:match("^(%a):([^:]+)(:?r?o?)$")
	return cat, name, ro == ":ro"
end
local function defaultFor(t)
	local cat, name = typeParts(t)
	if cat == "P" then
		if name == "bool" then return false elseif name == "string" then return "" else return 0 end
	elseif cat == "E" then
		return ENV.Enum[name][API.enums[name][1][1]]
	elseif cat == "D" then
		if name == "NumberRange" then return ENV.NumberRange.new(1, 1)
		elseif name == "NumberSequence" then return ENV.NumberSequence.new(1)
		elseif name == "ColorSequence" then return ENV.ColorSequence.new(ENV.Color3.new(1, 1, 1))
		elseif name == "Vector2" then return ENV.Vector2.new(0, 0)
		elseif name == "Vector3" then return ENV.Vector3.new(0, 0, 0)
		elseif name == "Color3" then return ENV.Color3.new(1, 1, 1)
		elseif name == "CFrame" then return ENV.CFrame.new()
		elseif name == "ContentId" then return ""
		end
	end
	return nil
end
local function checkType(class, prop, t, v)
	local cat, name, readOnly = typeParts(t)
	if readOnly then
		error(string.format("Unable to assign property %s.%s. Property is read only", class, prop))
	end
	local got = typeofx(v)
	local ok = true
	if cat == "P" then
		if name == "bool" then ok = got == "boolean" elseif name == "string" then ok = got == "string" else ok = got == "number" end
	elseif cat == "E" then
		ok = got == "EnumItem" and DATA[v].EnumName == name
	elseif cat == "D" then
		if name == "ContentId" or name == "ProtectedString" then ok = got == "string" else ok = got == name or name == "SecurityCapabilities" or name == "UniqueId" or name == "Content" end
	elseif cat == "C" then
		ok = v == nil or got == "Instance"
	end
	if not ok then
		error(string.format("Unable to assign property %s.%s: expected %s, got %s", class, prop, t, got))
	end
end

local function isA(d, cls)
	for _, c in d.info.chain do if c == cls then return true end end
	return false
end
local function descendants(d, out)
	for _, c in d.children do
		table.insert(out, c)
		descendants(DATA[c], out)
	end
	return out
end
local function setParent(self, parent)
	local d = DATA[self]
	if d.parent then
		local sibs = DATA[d.parent].children
		table.remove(sibs, table.find(sibs, self))
	end
	d.parent = parent
	if parent then table.insert(DATA[parent].children, self) end
end
local function newInstance(class)
	local info = API.classes[class]
	if not info then error("Unable to create an Instance of type " .. class) end
	local o = make(INP, { class = class, info = info, props = {}, attrs = {}, children = {}, parent = nil, destroyed = false })
	DATA[o].props.Name = class
	return o
end
local METHODS = {}
function METHODS.IsA(self, cls) return isA(DATA[self], cls) end
function METHODS.FindFirstChild(self, name, recursive)
	for _, c in DATA[self].children do if DATA[c].props.Name == name then return c end end
	if recursive then
		for _, c in DATA[self].children do local f = METHODS.FindFirstChild(c, name, true); if f then return f end end
	end
	return nil
end
function METHODS.FindFirstChildOfClass(self, cls) for _, c in DATA[self].children do if DATA[c].class == cls then return c end end return nil end
function METHODS.GetChildren(self) return table.clone(DATA[self].children) end
function METHODS.GetDescendants(self) return descendants(DATA[self], {}) end
function METHODS.IsDescendantOf(self, other)
	local p = DATA[self].parent
	while p do if p == other then return true end p = DATA[p].parent end
	return false
end
function METHODS.FindFirstAncestorWhichIsA(self, cls)
	local p = DATA[self].parent
	while p do if isA(DATA[p], cls) then return p end p = DATA[p].parent end
	return nil
end
function METHODS.SetAttribute(self, k, v) DATA[self].attrs[k] = v end
function METHODS.GetAttribute(self, k) return DATA[self].attrs[k] end
function METHODS.GetAttributes(self) return table.clone(DATA[self].attrs) end
function METHODS.Destroy(self)
	local d = DATA[self]
	if d.destroyed then return end
	d.destroyed = true
	for _, c in table.clone(d.children) do METHODS.Destroy(c) end
	setParent(self, nil)
end
function METHODS.WaitForChild(self, name) return METHODS.FindFirstChild(self, name) end
function METHODS.GetPivot(self)
	local pp = DATA[self].props.PrimaryPart
	return pp and pp.CFrame or ENV.CFrame.new()
end
function METHODS.Clone(self)
	local d = DATA[self]
	local c = newInstance(d.class)
	for k, v in d.props do DATA[c].props[k] = v end
	for k, v in d.attrs do DATA[c].attrs[k] = v end
	for _, ch in d.children do local cc = METHODS.Clone(ch); setParent(cc, c) end
	return c
end

INP = proto("Instance", {
	__index = function(self, k)
		local d = DATA[self]
		if k == "ClassName" then return d.class end
		if METHODS[k] then return METHODS[k] end
		if k == "Parent" then return d.parent end
		if d.info.props[k] then
			if d.props[k] ~= nil then return d.props[k] end
			local t = d.info.props[k]
			if d.class == "Attachment" and (k == "WorldCFrame" or k == "WorldPosition") then
				local base = d.parent and DATA[d.parent].props.CFrame or ENV.CFrame.new()
				local w = base * (d.props.CFrame or ENV.CFrame.new())
				return k == "WorldCFrame" and w or w.Position
			end
			if k == "Position" and d.info.props.CFrame then -- parts / attachments
				return (d.props.CFrame or ENV.CFrame.new()).Position
			end
			local v = defaultFor(t)
			if v ~= nil then d.props[k] = v end
			return v
		end
		local c = METHODS.FindFirstChild(self, k)
		if c then return c end
		error(tostring(k) .. " is not a valid member of " .. d.class)
	end,
	__newindex = function(self, k, v)
		local d = DATA[self]
		if d.destroyed and k ~= "Parent" then error("destroyed instance " .. d.props.Name) end
		if k == "Parent" then setParent(self, v) return end
		if k == "Position" and d.info.props.CFrame then
			d.props.CFrame = ENV.CFrame.new(v)
			return
		end
		local t = d.info.props[k]
		if not t then error(tostring(k) .. " is not a valid member of " .. d.class) end
		checkType(d.class, k, t, v)
		d.props[k] = v
		if k == "CFrame" then d.props.Position = nil end
	end,
	__tostring = function(self) return DATA[self].props.Name end,
})
ENV.Instance = { new = function(class) return newInstance(class) end }
ENV.__DATA = DATA

-- services ------------------------------------------------------------------------------------------
local services = {}
local history = { active = nil, log = {}, n = 0 }
services.ChangeHistoryService = {
	TryBeginRecording = function(self, name)
		if history.active then return nil end
		history.n += 1
		history.active = { id = history.n, name = name }
		table.insert(history.log, "begin " .. name)
		return history.active
	end,
	FinishRecording = function(self, id, op)
		assert(history.active == id, "FinishRecording: wrong id")
		history.active = nil
		table.insert(history.log, "finish " .. DATA[op].Name)
	end,
}
services.HttpService = { JSONEncode = function(_, v) return "[]" end, JSONDecode = function() return {} end }
services.Selection = { Get = function() return {} end }
services.ReplicatedStorage = newInstance("Folder")
DATA[services.ReplicatedStorage].props.Name = "ReplicatedStorage"
services.ServerStorage = newInstance("Folder")
DATA[services.ServerStorage].props.Name = "ServerStorage"
services.InsertService = { LoadAsset = function() error("InsertService not configured") end }
ENV.game = {
	GetService = function(_, name) return services[name] or error("no service " .. name) end,
	GetObjects = function() error("GetObjects not configured") end,
}
ENV.__history = history
ENV.__services = services

local pluginRoot = newInstance("Folder")
DATA[pluginRoot].props.Name = "LostCube"
local scriptInst = newInstance("ModuleScript")
DATA[scriptInst].props.Name = "Editor"
setParent(scriptInst, pluginRoot)
local vfxInst = newInstance("ModuleScript")
DATA[vfxInst].props.Name = "VFX"
setParent(vfxInst, scriptInst)
ENV.script = scriptInst
ENV.__pluginRoot = pluginRoot
local requires = { [vfxInst] = { play = function() end } }
ENV.require = function(m)
	if requires[m] == nil then error("require: unknown module " .. tostring(m)) end
	return requires[m]
end
ENV.__requires = requires
ENV.newInstance = newInstance

-- a free VFX model like the ones from the Creator Store: emitters (enabled, burst-only, counted, timed, on a shaped
-- part), a trail, lights, an unsupported Beam and three scripts (one of them a classic backdoor)
local function part(name, x, y, z)
	local p = newInstance("Part")
	p.Name = name
	p.Size = ENV.Vector3.new(2, 2, 2)
	p.CFrame = ENV.CFrame.new(ENV.Vector3.new(x, y, z))
	return p
end
local function build()
	local model = newInstance("Model")
	model.Name = "FreeFire"
	local base = part("Base", 10, 5, 10)
	base.Parent = model
	model.PrimaryPart = base
	local att = newInstance("Attachment"); att.Name = "FireAtt"; att.Position = ENV.Vector3.new(0, 2, 0); att.Parent = base
	local fire = newInstance("ParticleEmitter"); fire.Name = "Flame"; fire.Enabled = true; fire.Rate = 30
	fire.Texture = "rbxassetid://123"; fire.Lifetime = ENV.NumberRange.new(0.5, 1); fire.Speed = ENV.NumberRange.new(3, 5)
	fire.Color = ENV.ColorSequence.new(ENV.Color3.fromRGB(255, 120, 0), ENV.Color3.fromRGB(80, 0, 0)); fire.LightEmission = 0.7
	fire.Size = ENV.NumberSequence.new(2, 0); fire.Parent = att
	local burst = newInstance("ParticleEmitter"); burst.Name = "Pop"; burst.Enabled = false; burst.Rate = 12; burst.Parent = att
	local counted = newInstance("ParticleEmitter"); counted.Name = "Counted"; counted.Enabled = false
	counted:SetAttribute("EmitCount", 25); counted:SetAttribute("EmitDelay", 0.3); counted.Parent = att
	local timed = newInstance("ParticleEmitter"); timed.Name = "Timed"; timed:SetAttribute("EmitDuration", 1.5); timed:SetAttribute("EmitDelay", 0.5); timed.Parent = att
	local shaped = part("Shape", 12, 5, 10)
	shaped.Size = ENV.Vector3.new(4, 0.5, 4)
	shaped.Parent = model
	local se = newInstance("ParticleEmitter"); se.Name = "FromShape"; se.Shape = ENV.Enum.ParticleEmitterShape.Cylinder; se.Parent = shaped
	local a0 = newInstance("Attachment"); a0.Name = "T0"; a0.Position = ENV.Vector3.new(0, 1, 0); a0.Parent = base
	local a1 = newInstance("Attachment"); a1.Name = "T1"; a1.Position = ENV.Vector3.new(0, -1, 0); a1.Parent = base
	local trail = newInstance("Trail"); trail.Name = "Swoosh"; trail.Attachment0 = a0; trail.Attachment1 = a1; trail.Lifetime = 0.4; trail.Parent = base
	local light = newInstance("PointLight"); light.Name = "Glow"; light.Range = 18; light.Brightness = 3; light.Color = ENV.Color3.fromRGB(255, 160, 40); light.Parent = att
	local spot = newInstance("SpotLight"); spot.Name = "Beam"; spot.Enabled = false; spot.Parent = att
	local beam = newInstance("Beam"); beam.Parent = base
	local s1 = newInstance("Script"); s1.Name = "Backdoor"; s1.Source = "require(123456789).load(game)"; s1.Parent = model
	local s2 = newInstance("LocalScript"); s2.Name = "Harmless"; s2.Source = "print('hi')"; s2.Parent = base
	local s3 = newInstance("ModuleScript"); s3.Name = "Mod"; s3.Source = "return loadstring('x')"; s3.Parent = s2
	return model
end
ENV.part = part
ENV.freeModel = build
ENV.setParent = setParent
return ENV
