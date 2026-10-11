-- Typed Roblox mock for the Modeling engine: full CFrame maths (12-number constructor, fromMatrix, lookAt,
-- GetComponents, ToOrientation ...), instances typed after tests/data/api_subset.json (+ the few part classes the subset
-- lacks, derived from its Part / MeshPart rows with the members the API dump lists for them), raycasts against the real
-- shapes (box, ball, wedge, corner wedge as convex polyhedra), Terrain fills, CSG, EditableMesh, Selection and a strict
-- ChangeHistoryService that also counts changes made to the place OUTSIDE an undo recording.
--
--     local ENV = LC.run("tests/mocks/modeling_env.luau", nil, LC)
--     ENV.__history  { log, outside, active }    ENV.__terrain  { calls }    ENV.__csg  { fail, calls }
--     ENV.__mesh  { available, created, parts }  ENV.part(className, size, cframe, parent?)  ENV.__DATA[inst]
local LC = ...
local API = LC.run("tests/data/api_subset.luau")

local ENV = LC.env()
local DATA = setmetatable({}, { __mode = "k" })

local function make(typeName, fields, mt)
	local o = newproxy(true)
	local m = getmetatable(o)
	for k, v in mt do
		m[k] = v
	end
	m.__type = typeName
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

-- Vector3 -------------------------------------------------------------------------------------------------------------
local V3MT
local function v3(x, y, z)
	return make("Vector3", { X = x, Y = y, Z = z }, V3MT)
end
local function isV3(v)
	return typeofx(v) == "Vector3"
end
V3MT = {
	__index = function(self, k)
		local d = DATA[self]
		if k == "X" or k == "Y" or k == "Z" then
			return d[k]
		elseif k == "Magnitude" then
			return math.sqrt(d.X * d.X + d.Y * d.Y + d.Z * d.Z)
		elseif k == "Unit" then
			local m = math.sqrt(d.X * d.X + d.Y * d.Y + d.Z * d.Z)
			if m == 0 then
				return v3(0 / 0, 0 / 0, 0 / 0)
			end
			return v3(d.X / m, d.Y / m, d.Z / m)
		elseif k == "Dot" then
			return function(a, b)
				return a.X * b.X + a.Y * b.Y + a.Z * b.Z
			end
		elseif k == "Cross" then
			return function(a, b)
				return v3(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
			end
		elseif k == "Lerp" then
			return function(a, b, t)
				return v3(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t)
			end
		elseif k == "Abs" then
			return function(a)
				return v3(math.abs(a.X), math.abs(a.Y), math.abs(a.Z))
			end
		end
		error(tostring(k) .. " is not a valid member of Vector3", 2)
	end,
	__add = function(a, b)
		assert(isV3(a) and isV3(b), "Vector3 + expects two Vector3")
		return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
	end,
	__sub = function(a, b)
		assert(isV3(a) and isV3(b), "Vector3 - expects two Vector3")
		return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
	end,
	__mul = function(a, b)
		if type(a) == "number" then
			return v3(a * b.X, a * b.Y, a * b.Z)
		elseif type(b) == "number" then
			return v3(a.X * b, a.Y * b, a.Z * b)
		end
		return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
	end,
	__div = function(a, b)
		if type(b) == "number" then
			return v3(a.X / b, a.Y / b, a.Z / b)
		end
		return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
	end,
	__unm = function(a)
		return v3(-a.X, -a.Y, -a.Z)
	end,
	__eq = function(a, b)
		return a.X == b.X and a.Y == b.Y and a.Z == b.Z
	end,
	__tostring = function(a)
		return string.format("%g, %g, %g", a.X, a.Y, a.Z)
	end,
}
ENV.Vector3 = {
	new = function(x, y, z)
		for _, c in { x, y, z } do
			assert(c == nil or type(c) == "number", "Vector3.new expects numbers")
		end
		return v3(x or 0, y or 0, z or 0)
	end,
	zero = v3(0, 0, 0), one = v3(1, 1, 1), xAxis = v3(1, 0, 0), yAxis = v3(0, 1, 0), zAxis = v3(0, 0, 1),
}

-- CFrame (position + row-major rotation; columns = right, up, back) -----------------------------------------------------
local CFMT
local function cf(px, py, pz, m)
	return make("CFrame", { px = px, py = py, pz = pz, m = m }, CFMT)
end
local ID = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
local function mulM(a, b)
	local r = {}
	for i = 0, 2 do
		for j = 0, 2 do
			r[i * 3 + j + 1] = a[i * 3 + 1] * b[j + 1] + a[i * 3 + 2] * b[3 + j + 1] + a[i * 3 + 3] * b[6 + j + 1]
		end
	end
	return r
end
local function transpose(a)
	return { a[1], a[4], a[7], a[2], a[5], a[8], a[3], a[6], a[9] }
end
local function rotV(m, x, y, z)
	return m[1] * x + m[2] * y + m[3] * z, m[4] * x + m[5] * y + m[6] * z, m[7] * x + m[8] * y + m[9] * z
end
local function axisAngle(ax, ay, az, angle)
	local l = math.sqrt(ax * ax + ay * ay + az * az)
	ax, ay, az = ax / l, ay / l, az / l
	local c, s = math.cos(angle), math.sin(angle)
	local t = 1 - c
	return {
		t * ax * ax + c, t * ax * ay - s * az, t * ax * az + s * ay,
		t * ax * ay + s * az, t * ay * ay + c, t * ay * az - s * ax,
		t * ax * az - s * ay, t * ay * az + s * ax, t * az * az + c,
	}
end
local function C(o)
	return DATA[o]
end
local function isCF(v)
	return typeofx(v) == "CFrame"
end
CFMT = {
	__index = function(self, k)
		local d = DATA[self]
		local m = d.m
		if k == "Position" or k == "p" then
			return v3(d.px, d.py, d.pz)
		elseif k == "X" then
			return d.px
		elseif k == "Y" then
			return d.py
		elseif k == "Z" then
			return d.pz
		elseif k == "LookVector" then
			return v3(-m[3], -m[6], -m[9])
		elseif k == "RightVector" or k == "XVector" then
			return v3(m[1], m[4], m[7])
		elseif k == "UpVector" or k == "YVector" then
			return v3(m[2], m[5], m[8])
		elseif k == "ZVector" then
			return v3(m[3], m[6], m[9])
		elseif k == "Rotation" then
			return cf(0, 0, 0, m)
		elseif k == "GetComponents" then
			return function(a)
				local q = C(a)
				local r = q.m
				return q.px, q.py, q.pz, r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9]
			end
		elseif k == "Inverse" then
			return function(a)
				local q = C(a)
				local t = transpose(q.m)
				local x, y, z = rotV(t, -q.px, -q.py, -q.pz)
				return cf(x, y, z, t)
			end
		elseif k == "ToObjectSpace" then
			return function(a, b)
				return a:Inverse() * b
			end
		elseif k == "ToWorldSpace" then
			return function(a, b)
				return a * b
			end
		elseif k == "PointToObjectSpace" then
			return function(a, v)
				return a:Inverse() * v
			end
		elseif k == "PointToWorldSpace" then
			return function(a, v)
				return a * v
			end
		elseif k == "VectorToWorldSpace" then
			return function(a, v)
				return v3(rotV(C(a).m, v.X, v.Y, v.Z))
			end
		elseif k == "VectorToObjectSpace" then
			return function(a, v)
				return v3(rotV(transpose(C(a).m), v.X, v.Y, v.Z))
			end
		elseif k == "ToOrientation" or k == "ToEulerAnglesYXZ" then
			return function(a)
				local r = C(a).m
				local sx = math.max(-1, math.min(1, -r[6]))
				local x = math.asin(sx)
				if math.abs(sx) < 0.999999 then
					return x, math.atan2(r[3], r[9]), math.atan2(r[4], r[5])
				end
				return x, math.atan2(-r[7], r[1]), 0
			end
		end
		error(tostring(k) .. " is not a valid member of CFrame", 2)
	end,
	__mul = function(a, b)
		local p = C(a)
		if isV3(b) then
			local x, y, z = rotV(p.m, b.X, b.Y, b.Z)
			return v3(p.px + x, p.py + y, p.pz + z)
		end
		assert(isCF(b), "CFrame * expects a CFrame or a Vector3")
		local q = C(b)
		local x, y, z = rotV(p.m, q.px, q.py, q.pz)
		return cf(p.px + x, p.py + y, p.pz + z, mulM(p.m, q.m))
	end,
	__add = function(a, b)
		assert(isV3(b), "CFrame + expects a Vector3")
		local p = C(a)
		return cf(p.px + b.X, p.py + b.Y, p.pz + b.Z, p.m)
	end,
	__sub = function(a, b)
		assert(isV3(b), "CFrame - expects a Vector3")
		local p = C(a)
		return cf(p.px - b.X, p.py - b.Y, p.pz - b.Z, p.m)
	end,
	__eq = function(a, b)
		local p, q = C(a), C(b)
		if p.px ~= q.px or p.py ~= q.py or p.pz ~= q.pz then
			return false
		end
		for i = 1, 9 do
			if p.m[i] ~= q.m[i] then
				return false
			end
		end
		return true
	end,
	__tostring = function(a)
		local p = C(a)
		return string.format("CF(%.3f, %.3f, %.3f)", p.px, p.py, p.pz)
	end,
}
local function fromColumns(px, py, pz, x, y, z)
	return cf(px, py, pz, { x.X, y.X, z.X, x.Y, y.Y, z.Y, x.Z, y.Z, z.Z })
end
ENV.CFrame = {
	new = function(...)
		local n = select("#", ...)
		local a = ...
		if n == 0 then
			return cf(0, 0, 0, ID)
		elseif n == 1 then
			assert(isV3(a), "CFrame.new(Vector3)")
			return cf(a.X, a.Y, a.Z, ID)
		elseif n == 3 then
			local x, y, z = ...
			assert(type(x) == "number" and type(y) == "number" and type(z) == "number", "CFrame.new(x, y, z)")
			return cf(x, y, z, ID)
		elseif n == 12 then
			local args = { ... }
			for i = 1, 12 do
				assert(type(args[i]) == "number", "CFrame.new: 12 numbers")
			end
			return cf(args[1], args[2], args[3], { args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12] })
		end
		error("CFrame.new: unsupported argument count " .. n)
	end,
	fromMatrix = function(pos, vx, vy, vz)
		vz = vz or vx:Cross(vy)
		return fromColumns(pos.X, pos.Y, pos.Z, vx, vy, vz)
	end,
	lookAt = function(at, target, up)
		up = up or v3(0, 1, 0)
		local look = (target - at).Unit
		local right = look:Cross(up)
		if right.Magnitude < 1e-6 then
			right = look:Cross(v3(0, 0, 1))
		end
		right = right.Unit
		local up2 = right:Cross(look).Unit
		return fromColumns(at.X, at.Y, at.Z, right, up2, -look)
	end,
	Angles = function(rx, ry, rz)
		return cf(0, 0, 0, mulM(mulM(axisAngle(1, 0, 0, rx), axisAngle(0, 1, 0, ry)), axisAngle(0, 0, 1, rz)))
	end,
	fromEulerAnglesYXZ = function(rx, ry, rz)
		return cf(0, 0, 0, mulM(mulM(axisAngle(0, 1, 0, ry), axisAngle(1, 0, 0, rx)), axisAngle(0, 0, 1, rz)))
	end,
	fromAxisAngle = function(axis, angle)
		return cf(0, 0, 0, axisAngle(axis.X, axis.Y, axis.Z, angle))
	end,
}
ENV.CFrame.fromOrientation = ENV.CFrame.fromEulerAnglesYXZ
ENV.CFrame.identity = ENV.CFrame.new()

-- Color3 ----------------------------------------------------------------------------------------------------------------
local C3MT
local function c3(r, g, b)
	return make("Color3", { R = r, G = g, B = b }, C3MT)
end
C3MT = {
	__index = function(self, k)
		local d = DATA[self]
		if k == "R" or k == "G" or k == "B" then
			return d[k]
		elseif k == "ToHex" then
			return function(c)
				return string.format("%02x%02x%02x", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
			end
		end
		error(tostring(k) .. " is not a valid member of Color3", 2)
	end,
	__eq = function(a, b)
		return a.R == b.R and a.G == b.G and a.B == b.B
	end,
	__tostring = function(a)
		return string.format("C3(%d,%d,%d)", a.R * 255 + 0.5, a.G * 255 + 0.5, a.B * 255 + 0.5)
	end,
}
ENV.Color3 = {
	new = function(r, g, b)
		return c3(r or 0, g or 0, b or 0)
	end,
	fromRGB = function(r, g, b)
		return c3(r / 255, g / 255, b / 255)
	end,
	fromHex = function(s)
		s = string.gsub(s, "^#", "")
		assert(#s == 6 and not string.find(s, "%X"), "Color3.fromHex: bad hex " .. s)
		return c3(tonumber(string.sub(s, 1, 2), 16) / 255, tonumber(string.sub(s, 3, 4), 16) / 255, tonumber(string.sub(s, 5, 6), 16) / 255)
	end,
}

-- Enum (members from the API subset) ---------------------------------------------------------------------------------
local EIMT = { __index = function(self, k)
	local d = DATA[self]
	if d[k] ~= nil then
		return d[k]
	end
	error(tostring(k) .. " is not a valid member of EnumItem", 2)
end, __tostring = function(s)
	return "Enum." .. DATA[s].EnumName .. "." .. DATA[s].Name
end }
local ENUMS = {}
ENV.Enum = setmetatable({}, { __index = function(_, name)
	if ENUMS[name] then
		return ENUMS[name]
	end
	local list = API.enums[name]
	if not list then
		error("Enum." .. tostring(name) .. " is not in the mock (tests/data/api_subset.json)")
	end
	local items = {}
	local enum = setmetatable({}, { __index = function(_, item)
		if items[item] then
			return items[item]
		end
		error(tostring(item) .. " is not a valid member of Enum." .. name, 2)
	end })
	for _, item in list do
		items[item[1]] = make("EnumItem", { Name = item[1], Value = item[2], EnumName = name, EnumType = enum }, EIMT)
	end
	ENUMS[name] = enum
	return enum
end })
local Enum = ENV.Enum

-- Content / RaycastParams / RaycastResult -----------------------------------------------------------------------------------
local plain = { __index = function(self, k)
	local d = DATA[self]
	if d[k] ~= nil then
		return d[k]
	end
	error(tostring(k) .. " is not a valid member", 2)
end }
ENV.Content = { fromObject = function(o)
	assert(o ~= nil, "Content.fromObject(nil)")
	return make("Content", { Object = o }, plain)
end }
local RPMT = {
	__index = function(self, k)
		local d = DATA[self]
		if d.fields[k] == nil then
			error(tostring(k) .. " is not a valid member of RaycastParams", 2)
		end
		return d.values[k]
	end,
	__newindex = function(self, k, v)
		local d = DATA[self]
		local want = d.fields[k]
		if want == nil then
			error(tostring(k) .. " is not a valid member of RaycastParams", 2)
		end
		if want == "filterType" then
			assert(typeofx(v) == "EnumItem" and DATA[v].EnumName == "RaycastFilterType", "RaycastParams.FilterType expects Enum.RaycastFilterType")
		elseif want == "list" then
			assert(type(v) == "table", "FilterDescendantsInstances expects a table")
			for _, i in v do
				assert(typeofx(i) == "Instance", "FilterDescendantsInstances: only Instances")
			end
			v = table.clone(v)
		elseif want == "bool" then
			assert(type(v) == "boolean", k .. " expects a boolean")
		end
		d.values[k] = v
	end,
}
ENV.RaycastParams = { new = function()
	return make("RaycastParams", {
		fields = { FilterType = "filterType", FilterDescendantsInstances = "list", IgnoreWater = "bool", RespectCanCollide = "bool",
			CollisionGroup = "string", BruteForceAllSlow = "bool" },
		values = { FilterType = Enum.RaycastFilterType.Exclude, FilterDescendantsInstances = {}, IgnoreWater = false,
			RespectCanCollide = false, CollisionGroup = "Default", BruteForceAllSlow = false },
	}, RPMT)
end }

ENV.task = {
	wait = function()
		ENV.__waits = (ENV.__waits or 0) + 1
		return 0
	end,
	spawn = function(f, ...)
		f(...)
	end,
	defer = function(f, ...)
		f(...)
	end,
}

-- Instances --------------------------------------------------------------------------------------------------------------
-- classes the subset lacks, built from its Part / MeshPart rows + the members the API dump lists for them
local CLASSES = {}
for name, info in API.classes do
	CLASSES[name] = info
end
local function derive(base, chain, remove, add)
	local props = table.clone(API.classes[base].props)
	for _, k in remove do
		props[k] = nil
	end
	for k, v in add do
		props[k] = v
	end
	return { chain = chain, props = props }
end
local TRIMESH = { CollisionFidelity = "E:CollisionFidelity", CollisionPrecision = "P:float", FluidFidelity = "E:FluidFidelity",
	MeshSize = "D:Vector3:ro" }
local function merged(a, b)
	local out = table.clone(a)
	for k, v in b do
		out[k] = v
	end
	return out
end
CLASSES.WedgePart = derive("Part", { "WedgePart", "FormFactorPart", "BasePart", "PVInstance", "Instance", "Object" }, { "Shape" }, {})
CLASSES.CornerWedgePart = derive("Part", { "CornerWedgePart", "BasePart", "PVInstance", "Instance", "Object" },
	{ "Shape", "FormFactor", "formFactor" }, {})
CLASSES.Seat = derive("Part", { "Seat", "Part", "FormFactorPart", "BasePart", "PVInstance", "Instance", "Object" }, {},
	{ Disabled = "P:bool", Occupant = "C:Humanoid:ro" })
CLASSES.UnionOperation = derive("Part", { "UnionOperation", "PartOperation", "TriangleMeshPart", "BasePart", "PVInstance", "Instance", "Object" },
	{ "Shape", "FormFactor", "formFactor" },
	merged(TRIMESH, { RenderFidelity = "E:RenderFidelity", SmoothingAngle = "P:float", TriangleCount = "P:int:ro", UsePartColor = "P:bool" }))
CLASSES.Terrain = derive("Part", { "Terrain", "BasePart", "PVInstance", "Instance", "Object" }, { "Shape", "FormFactor", "formFactor" },
	{ WaterColor = "D:Color3", WaterReflectance = "P:float", WaterTransparency = "P:float", WaterWaveSize = "P:float", WaterWaveSpeed = "P:float" })
local NOT_CREATABLE = { Terrain = true, Workspace = true, BasePart = true, PVInstance = true, Instance = true, Object = true,
	FormFactorPart = true, TriangleMeshPart = true, PartOperation = true }

local function typeParts(t)
	local cat, name, ro = string.match(t, "^(%a):([^:]+)(:?r?o?)$")
	return cat, name, ro == ":ro"
end

local REAL_DEFAULTS = {
	Anchored = false, CanCollide = true, CanTouch = true, CanQuery = true, CastShadow = true, Archivable = true, Locked = false,
	Transparency = 0, Reflectance = 0, Massless = false, Enabled = true, UsePartColor = false, SmoothingAngle = 0, TriangleCount = 0,
	Range = 8, Brightness = 1, Disabled = false,
}
local function defaultFor(class, prop, t)
	if REAL_DEFAULTS[prop] ~= nil then
		return REAL_DEFAULTS[prop]
	end
	local cat, name = typeParts(t)
	if prop == "Size" and class ~= "Terrain" then
		return v3(4, 1, 2)
	elseif prop == "Color" then
		return ENV.Color3.fromRGB(163, 162, 165)
	elseif prop == "Material" then
		return Enum.Material.Plastic
	elseif prop == "TopSurface" then
		return Enum.SurfaceType.Studs
	elseif prop == "BottomSurface" then
		return Enum.SurfaceType.Inlet
	elseif prop == "Shape" then
		return Enum.PartType.Block
	elseif prop == "RenderFidelity" then
		return Enum.RenderFidelity.Automatic
	elseif prop == "CollisionFidelity" then
		return Enum.CollisionFidelity.Default
	end
	if cat == "P" then
		if name == "bool" then
			return false
		elseif name == "string" then
			return ""
		end
		return 0
	elseif cat == "E" then
		return Enum[name][API.enums[name][1][1]]
	elseif cat == "D" then
		if name == "Vector3" then
			return v3(0, 0, 0)
		elseif name == "Color3" then
			return c3(1, 1, 1)
		elseif name == "CFrame" then
			return ENV.CFrame.new()
		end
	end
	return nil
end

local history = { log = {}, active = nil, n = 0, outside = 0, inside = 0, outsideWhat = {} }
local INMT
local gameRoot -- the DataModel stand-in (children = services)

local function isA(d, cls)
	return table.find(d.info.chain, cls) ~= nil
end
local function inPlace(inst)
	local p = inst
	while p do
		if p == gameRoot then
			return true
		end
		p = DATA[p].parent
	end
	return false
end
-- every change to an instance of the place counts as inside / outside the active undo recording
local function touched(inst, what)
	if inPlace(inst) then
		if history.active then
			history.inside += 1
		else
			history.outside += 1
			table.insert(history.outsideWhat, DATA[inst].props.Name .. "." .. what)
		end
	end
end

local function setParent(self, parent)
	local d = DATA[self]
	if d.destroyed then
		error("The Parent property of " .. d.props.Name .. " is locked, current parent: NULL, new parent " .. tostring(parent), 3)
	end
	if parent ~= nil then
		assert(typeofx(parent) == "Instance", "Parent must be an Instance")
		local p = parent
		while p do
			assert(p ~= self, "Attempt to set parent of " .. d.props.Name .. " to itself or a descendant")
			p = DATA[p].parent
		end
	end
	touched(self, "Parent")
	if d.parent then
		local sibs = DATA[d.parent].children
		table.remove(sibs, table.find(sibs, self))
	end
	d.parent = parent
	if parent then
		table.insert(DATA[parent].children, self)
		touched(self, "Parent")
	end
end

local function newInstance(class)
	local info = CLASSES[class]
	if not info then
		error("Unable to create an Instance of type \"" .. tostring(class) .. "\"", 2)
	end
	local o = make("Instance", { class = class, info = info, props = { Name = class }, attrs = {}, children = {}, parent = nil, destroyed = false }, INMT)
	return o
end

local function checkType(class, prop, t, v)
	local cat, name, readOnly = typeParts(t)
	if readOnly then
		error(string.format("Unable to assign property %s. Property is read only", prop), 3)
	end
	local got = typeofx(v)
	local ok
	if cat == "P" then
		if name == "bool" then
			ok = got == "boolean"
		elseif name == "string" then
			ok = got == "string"
		else
			ok = got == "number" and v == v
		end
	elseif cat == "E" then
		ok = got == "EnumItem" and DATA[v].EnumName == name
	elseif cat == "D" then
		ok = got == name or (name == "ContentId" and got == "string") or name == "SecurityCapabilities" or name == "UniqueId"
	elseif cat == "C" then
		ok = v == nil or (got == "Instance" and isA(DATA[v], name))
	end
	if not ok then
		error(string.format("Unable to assign property %s.%s: expected %s, got %s", class, prop, t, got), 3)
	end
end

local function worldCF(d)
	return d.props.CFrame or ENV.CFrame.new()
end

local METHODS = {}
function METHODS.IsA(self, cls)
	return isA(DATA[self], cls)
end
function METHODS.GetChildren(self)
	return table.clone(DATA[self].children)
end
local function descendants(d, out)
	for _, c in d.children do
		table.insert(out, c)
		descendants(DATA[c], out)
	end
	return out
end
function METHODS.GetDescendants(self)
	return descendants(DATA[self], {})
end
function METHODS.FindFirstChild(self, name, recursive)
	for _, c in DATA[self].children do
		if DATA[c].props.Name == name then
			return c
		end
	end
	if recursive then
		for _, c in DATA[self].children do
			local f = METHODS.FindFirstChild(c, name, true)
			if f then
				return f
			end
		end
	end
	return nil
end
function METHODS.FindFirstChildOfClass(self, cls)
	for _, c in DATA[self].children do
		if DATA[c].class == cls then
			return c
		end
	end
	return nil
end
function METHODS.FindFirstChildWhichIsA(self, cls)
	for _, c in DATA[self].children do
		if isA(DATA[c], cls) then
			return c
		end
	end
	return nil
end
function METHODS.IsDescendantOf(self, other)
	local p = DATA[self].parent
	while p do
		if p == other then
			return true
		end
		p = DATA[p].parent
	end
	return false
end
function METHODS.FindFirstAncestorWhichIsA(self, cls)
	local p = DATA[self].parent
	while p do
		if isA(DATA[p], cls) then
			return p
		end
		p = DATA[p].parent
	end
	return nil
end
local ATTR_TYPES = { string = true, boolean = true, number = true, Vector3 = true, Color3 = true, CFrame = true, Vector2 = true,
	UDim = true, UDim2 = true, NumberRange = true, BrickColor = true }
function METHODS.SetAttribute(self, k, v)
	assert(type(k) == "string" and #k <= 100 and string.match(k, "^[%w_]+$"), "SetAttribute: invalid attribute name " .. tostring(k))
	assert(v == nil or ATTR_TYPES[typeofx(v)], "SetAttribute: unsupported value type " .. typeofx(v))
	touched(self, "@" .. k)
	DATA[self].attrs[k] = v
end
function METHODS.GetAttribute(self, k)
	return DATA[self].attrs[k]
end
function METHODS.GetAttributes(self)
	return table.clone(DATA[self].attrs)
end
function METHODS.Destroy(self)
	local d = DATA[self]
	if d.destroyed then
		return
	end
	for _, c in table.clone(d.children) do
		METHODS.Destroy(c)
	end
	if d.parent then
		setParent(self, nil)
	end
	d.destroyed = true
end
function METHODS.ClearAllChildren(self)
	for _, c in table.clone(DATA[self].children) do
		METHODS.Destroy(c)
	end
end
function METHODS.Clone(self)
	local map = {}
	local function copy(inst)
		local d = DATA[inst]
		if d.props.Archivable == false then
			return nil
		end
		local c = newInstance(d.class)
		local cd = DATA[c]
		for k, v in d.props do
			cd.props[k] = v
		end
		for k, v in d.attrs do
			cd.attrs[k] = v
		end
		map[inst] = c
		for _, ch in d.children do
			local cc = copy(ch)
			if cc then
				DATA[cc].parent = c
				table.insert(cd.children, cc)
			end
		end
		return c
	end
	local root = copy(self)
	-- references inside the copied subtree point to the copies (Part0 / Part1 / PrimaryPart ...)
	for orig, c in map do
		local cd = DATA[c]
		for k, t in cd.info.props do
			local cat = typeParts(t)
			if cat == "C" and k ~= "Parent" and cd.props[k] ~= nil and map[cd.props[k]] then
				cd.props[k] = map[cd.props[k]]
			end
		end
		local _ = orig
	end
	return root
end

-- pivots
local function partPivot(self)
	local d = DATA[self]
	return worldCF(d) * (d.props.PivotOffset or ENV.CFrame.new())
end
local function partsUnder(self)
	local out = {}
	for _, x in METHODS.GetDescendants(self) do
		if isA(DATA[x], "BasePart") then
			table.insert(out, x)
		end
	end
	return out
end
function METHODS.GetPivot(self)
	local d = DATA[self]
	if isA(d, "BasePart") then
		return partPivot(self)
	end
	assert(isA(d, "Model"), "GetPivot is a member of PVInstance")
	local pp = d.props.PrimaryPart
	if pp and not DATA[pp].destroyed and METHODS.IsDescendantOf(pp, self) then
		return partPivot(pp)
	end
	return d.props.WorldPivot or ENV.CFrame.new()
end
function METHODS.PivotTo(self, target)
	assert(isCF(target), "PivotTo expects a CFrame")
	local d = DATA[self]
	if isA(d, "BasePart") then
		self.CFrame = target * (d.props.PivotOffset or ENV.CFrame.new()):Inverse()
		return
	end
	local delta = target * METHODS.GetPivot(self):Inverse()
	for _, p in partsUnder(self) do
		p.CFrame = delta * worldCF(DATA[p])
	end
	if not (d.props.PrimaryPart and METHODS.IsDescendantOf(d.props.PrimaryPart, self)) then
		self.WorldPivot = target
	end
end
local function cornersOf(p)
	local d = DATA[p]
	local c = worldCF(d)
	local s = d.props.Size or v3(4, 1, 2)
	local out = {}
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				table.insert(out, c * v3(sx * s.X / 2, sy * s.Y / 2, sz * s.Z / 2))
			end
		end
	end
	return out
end
function METHODS.GetBoundingBox(self)
	local pivot = METHODS.GetPivot(self)
	local rot = pivot.Rotation
	local inv = rot:Inverse()
	local lo, hi
	for _, p in partsUnder(self) do
		for _, c in cornersOf(p) do
			local l = inv * c
			if not lo then
				lo, hi = l, l
			else
				lo = v3(math.min(lo.X, l.X), math.min(lo.Y, l.Y), math.min(lo.Z, l.Z))
				hi = v3(math.max(hi.X, l.X), math.max(hi.Y, l.Y), math.max(hi.Z, l.Z))
			end
		end
	end
	if not lo then
		return pivot, v3(0, 0, 0)
	end
	return rot + (rot * ((lo + hi) / 2)), hi - lo
end
function METHODS.GetExtentsSize(self)
	local _, size = METHODS.GetBoundingBox(self)
	return size
end
function METHODS.GetScale(self)
	return DATA[self].scale or 1
end
function METHODS.ScaleTo(self, s)
	assert(type(s) == "number" and s > 0, "ScaleTo expects a positive number")
	local d = DATA[self]
	local f = s / (d.scale or 1)
	local pivot = METHODS.GetPivot(self)
	for _, p in partsUnder(self) do
		local pd = DATA[p]
		local c = worldCF(pd)
		local rel = pivot:Inverse() * c
		local scaled = ENV.CFrame.new(rel.Position * f) * rel.Rotation
		p.Size = pd.props.Size * f
		p.CFrame = pivot * scaled
	end
	d.scale = s
end

-- CSG
local csg = { fail = false, calls = {} }
local function csgResult(self, others, op)
	if csg.fail then
		error("CSG failed: " .. tostring(csg.fail))
	end
	table.insert(csg.calls, { op = op, count = #others + 1 })
	local lo, hi
	for _, p in { self, table.unpack(others) } do
		for _, c in cornersOf(p) do
			if not lo then
				lo, hi = c, c
			else
				lo = v3(math.min(lo.X, c.X), math.min(lo.Y, c.Y), math.min(lo.Z, c.Z))
				hi = v3(math.max(hi.X, c.X), math.max(hi.Y, c.Y), math.max(hi.Z, c.Z))
			end
		end
	end
	if op == "subtract" then -- the result keeps the base's box
		local cs = cornersOf(self)
		lo, hi = cs[1], cs[1]
		for _, c in cs do
			lo = v3(math.min(lo.X, c.X), math.min(lo.Y, c.Y), math.min(lo.Z, c.Z))
			hi = v3(math.max(hi.X, c.X), math.max(hi.Y, c.Y), math.max(hi.Z, c.Z))
		end
	end
	local u = newInstance("UnionOperation")
	local ud, sd = DATA[u], DATA[self]
	ud.props.Size = hi - lo
	ud.props.CFrame = ENV.CFrame.new((lo + hi) / 2)
	ud.props.Color = sd.props.Color
	ud.props.Material = sd.props.Material
	ud.props.TriangleCount = 12 * (#others + 1)
	return u
end
local function checkCsgArgs(self, others, cfid, rfid)
	assert(isA(DATA[self], "BasePart"), "UnionAsync is a member of BasePart")
	assert(type(others) == "table", "UnionAsync: parts must be a table")
	for _, o in others do
		assert(typeofx(o) == "Instance" and isA(DATA[o], "BasePart"), "UnionAsync: only BaseParts")
		assert(not isA(DATA[o], "Terrain"), "CSG does not work on Terrain")
	end
	assert(typeofx(cfid) == "EnumItem" and DATA[cfid].EnumName == "CollisionFidelity", "UnionAsync: CollisionFidelity")
	assert(typeofx(rfid) == "EnumItem" and DATA[rfid].EnumName == "RenderFidelity", "UnionAsync: RenderFidelity")
end
function METHODS.UnionAsync(self, others, cfid, rfid)
	checkCsgArgs(self, others, cfid, rfid)
	return csgResult(self, others, "union")
end
function METHODS.SubtractAsync(self, others, cfid, rfid)
	checkCsgArgs(self, others, cfid, rfid)
	return csgResult(self, others, "subtract")
end

-- Terrain
local terrain = { calls = {} }
local function checkMaterial(m)
	assert(typeofx(m) == "EnumItem" and DATA[m].EnumName == "Material", "Terrain fill expects an Enum.Material")
end
function METHODS.FillBall(self, center, radius, material)
	assert(DATA[self].class == "Terrain", "FillBall is a member of Terrain")
	assert(isV3(center) and type(radius) == "number", "FillBall(center: Vector3, radius: number, material)")
	checkMaterial(material)
	touched(self, "FillBall")
	table.insert(terrain.calls, { op = "ball", center = center, radius = radius, material = material.Name })
end
function METHODS.FillBlock(self, cframe, size, material)
	assert(DATA[self].class == "Terrain", "FillBlock is a member of Terrain")
	assert(isCF(cframe) and isV3(size), "FillBlock(cframe: CFrame, size: Vector3, material)")
	checkMaterial(material)
	touched(self, "FillBlock")
	table.insert(terrain.calls, { op = "block", cframe = cframe, size = size, material = material.Name })
end
function METHODS.FillWedge(self, cframe, size, material)
	assert(DATA[self].class == "Terrain", "FillWedge is a member of Terrain")
	assert(isCF(cframe) and isV3(size), "FillWedge(cframe: CFrame, size: Vector3, material)")
	checkMaterial(material)
	touched(self, "FillWedge")
	table.insert(terrain.calls, { op = "wedge", cframe = cframe, size = size, material = material.Name })
end
function METHODS.FillCylinder(self, cframe, height, radius, material)
	assert(DATA[self].class == "Terrain", "FillCylinder is a member of Terrain")
	assert(isCF(cframe) and type(height) == "number" and type(radius) == "number", "FillCylinder(cframe, height, radius, material)")
	checkMaterial(material)
	touched(self, "FillCylinder")
	table.insert(terrain.calls, { op = "cylinder", cframe = cframe, height = height, radius = radius, material = material.Name })
end

-- raycasts: each part is a convex shape in its local space, planes { nx, ny, nz, d } with inside = n . p <= d
local function shapePlanes(d)
	local s = d.props.Size or v3(4, 1, 2)
	local hx, hy, hz = s.X / 2, s.Y / 2, s.Z / 2
	local box = { { 1, 0, 0, hx }, { -1, 0, 0, hx }, { 0, 1, 0, hy }, { 0, -1, 0, hy }, { 0, 0, 1, hz }, { 0, 0, -1, hz } }
	local shape = d.class == "WedgePart" and "Wedge" or d.class == "CornerWedgePart" and "CornerWedge"
		or (d.props.Shape and DATA[d.props.Shape].Name) or "Block"
	if shape == "Wedge" then -- right angle at (y = -hy, z = +hz): the slope hz*y - hy*z <= 0
		return { { 1, 0, 0, hx }, { -1, 0, 0, hx }, { 0, -1, 0, hy }, { 0, 0, 1, hz }, { 0, hz, -hy, 0 } }
	elseif shape == "CornerWedge" then -- apex over the bottom corner (+hx, -hz)
		return { { 0, -1, 0, hy }, { 1, 0, 0, hx }, { 0, 0, -1, hz }, { -hy, hx, 0, 0 }, { 0, hz, hy, 0 } }
	end
	return box, shape
end
local function rayPart(part, origin, dir)
	local d = DATA[part]
	local c = worldCF(d)
	local inv = c:Inverse()
	local o = inv * origin
	local v = c:VectorToObjectSpace(dir)
	local planes, shape = shapePlanes(d)
	if shape == "Ball" then
		local s = d.props.Size
		local r = math.min(s.X, s.Y, s.Z) / 2
		local b = o:Dot(v)
		local cc = o:Dot(o) - r * r
		local a = v:Dot(v)
		local disc = b * b - a * cc
		if disc < 0 then
			return nil
		end
		local t = (-b - math.sqrt(disc)) / a
		if t < 0 or t > 1 then
			return nil
		end
		local hitL = o + v * t
		return t, c * hitL, c:VectorToWorldSpace(hitL.Unit)
	end
	local tin, tout, nin = 0, 1, nil
	for _, pl in planes do
		local n = v3(pl[1], pl[2], pl[3])
		local denom = n:Dot(v)
		local dist = pl[4] - n:Dot(o)
		if math.abs(denom) < 1e-12 then
			if dist < 0 then
				return nil
			end
		else
			local t = dist / denom
			if denom < 0 then
				if t > tin then
					tin, nin = t, n
				end
			else
				if t < tout then
					tout = t
				end
			end
		end
		if tin > tout then
			return nil
		end
	end
	if not nin then -- the origin is inside the shape: Roblox does not report that part
		return nil
	end
	return tin, c * (o + v * tin), c:VectorToWorldSpace(nin.Unit)
end
local RRMT = plain

INMT = {
	__index = function(self, k)
		local d = DATA[self]
		if k == "ClassName" then
			return d.class
		elseif k == "Parent" then
			return d.parent
		end
		if METHODS[k] then
			return METHODS[k]
		end
		local t = d.info.props[k]
		if t then
			if k == "Position" and d.info.props.CFrame then
				return worldCF(d).Position
			elseif k == "Orientation" and d.info.props.CFrame then
				local x, y, z = worldCF(d):ToOrientation()
				return v3(math.deg(x), math.deg(y), math.deg(z))
			end
			if d.props[k] == nil then
				d.props[k] = defaultFor(d.class, k, t)
			end
			return d.props[k]
		end
		local child = METHODS.FindFirstChild(self, k)
		if child then
			return child
		end
		error(tostring(k) .. " is not a valid member of " .. d.class .. " \"" .. tostring(d.props.Name) .. "\"", 2)
	end,
	__newindex = function(self, k, v)
		local d = DATA[self]
		if k == "Parent" then
			setParent(self, v)
			return
		end
		if d.destroyed then
			error("cannot change " .. k .. " of destroyed " .. tostring(d.props.Name), 2)
		end
		local t = d.info.props[k]
		if not t then
			error(tostring(k) .. " is not a valid member of " .. d.class, 2)
		end
		if k == "Position" and d.info.props.CFrame then
			assert(isV3(v), "Position expects a Vector3")
			touched(self, k)
			d.props.CFrame = worldCF(d).Rotation + v
			return
		end
		checkType(d.class, k, t, v)
		if k == "Size" then -- Roblox clamps every axis to 0.001-2048
			v = v3(math.clamp(v.X, 0.001, 2048), math.clamp(v.Y, 0.001, 2048), math.clamp(v.Z, 0.001, 2048))
		end
		touched(self, k)
		d.props[k] = v
	end,
	__tostring = function(self)
		return DATA[self].props.Name
	end,
}

-- services ------------------------------------------------------------------------------------------------------------------
gameRoot = newInstance("Folder")
DATA[gameRoot].props.Name = "Game"
local workspaceInst = newInstance("Workspace")
DATA[workspaceInst].props.Name = "Workspace"
DATA[workspaceInst].parent = gameRoot
table.insert(DATA[gameRoot].children, workspaceInst)
local terrainInst = newInstance("Terrain")
DATA[terrainInst].props.Name = "Terrain"
DATA[terrainInst].props.Anchored = true
DATA[terrainInst].parent = workspaceInst
table.insert(DATA[workspaceInst].children, terrainInst)
DATA[workspaceInst].props.Terrain = terrainInst
local camera = newInstance("Camera")
DATA[camera].props.Name = "Camera"
DATA[camera].props.CFrame = ENV.CFrame.lookAt(v3(0, 20, 40), v3(0, 0, 0))
DATA[camera].parent = workspaceInst
table.insert(DATA[workspaceInst].children, camera)
DATA[workspaceInst].props.CurrentCamera = camera

function METHODS.Raycast(self, origin, direction, params)
	assert(DATA[self].class == "Workspace", "Raycast is a member of WorldRoot")
	assert(isV3(origin) and isV3(direction), "Raycast(origin: Vector3, direction: Vector3, params?)")
	assert(params == nil or typeofx(params) == "RaycastParams", "Raycast: params must be RaycastParams")
	local filterType = params and params.FilterType or Enum.RaycastFilterType.Exclude
	local list = params and params.FilterDescendantsInstances or {}
	local function listed(p)
		for _, f in list do
			if p == f or METHODS.IsDescendantOf(p, f) then
				return true
			end
		end
		return false
	end
	local include = DATA[filterType].Name == "Include"
	local best
	for _, p in METHODS.GetDescendants(self) do
		local pd = DATA[p]
		if isA(pd, "BasePart") and pd.class ~= "Terrain" and pd.props.CanQuery ~= false then
			local skip = include and not listed(p) or (not include and listed(p))
			if not skip then
				local t, pos, normal = rayPart(p, origin, direction)
				if t and (not best or t < best.t) then
					best = { t = t, pos = pos, normal = normal, part = p }
				end
			end
		end
	end
	if not best then
		return nil
	end
	return make("RaycastResult", { Instance = best.part, Position = best.pos, Normal = best.normal,
		Distance = best.t * direction.Magnitude, Material = DATA[best.part].props.Material or Enum.Material.Plastic }, RRMT)
end

local services = {}
services.Workspace = workspaceInst
local function service(name)
	local s = newInstance("Folder")
	DATA[s].props.Name = name
	DATA[s].parent = gameRoot
	table.insert(DATA[gameRoot].children, s)
	return s
end
services.ReplicatedStorage = service("ReplicatedStorage")
services.ServerStorage = service("ServerStorage")
services.ChangeHistoryService = {
	TryBeginRecording = function(self, name, displayName)
		assert(self == services.ChangeHistoryService, "TryBeginRecording must be called with :")
		assert(type(name) == "string", "TryBeginRecording(name: string)")
		if history.active then
			table.insert(history.log, "refused " .. name)
			return nil
		end
		history.n += 1
		history.active = "rec" .. history.n
		table.insert(history.log, "begin " .. name)
		return history.active
	end,
	FinishRecording = function(self, id, op)
		assert(self == services.ChangeHistoryService, "FinishRecording must be called with :")
		assert(id == history.active, "FinishRecording: wrong or finished id " .. tostring(id))
		assert(typeofx(op) == "EnumItem" and DATA[op].EnumName == "FinishRecordingOperation", "FinishRecording: operation enum")
		history.active = nil
		table.insert(history.log, "finish " .. DATA[op].Name)
	end,
}
local selection = {}
services.Selection = {
	Get = function(self)
		assert(self == services.Selection, "Selection:Get")
		return table.clone(selection)
	end,
	Set = function(self, list)
		assert(self == services.Selection, "Selection:Set")
		for _, i in list do
			assert(typeofx(i) == "Instance", "Selection:Set: only Instances")
		end
		selection = table.clone(list)
	end,
}
-- EditableMesh: limits from the API reference (60 000 vertices, 20 000 triangles)
local meshState = { available = true, created = 0, parts = 0, meshPartFails = false }
local EMMT = { __index = function(self, k)
	local d = DATA[self]
	if k == "AddVertex" then
		return function(_, p)
			assert(not d.destroyed, "EditableMesh destroyed")
			assert(isV3(p), "AddVertex(Vector3)")
			assert(#d.verts < 60000, "EditableMesh: too many vertices")
			table.insert(d.verts, p)
			return #d.verts
		end
	elseif k == "AddTriangle" then
		return function(_, a, b, c)
			assert(d.verts[a] and d.verts[b] and d.verts[c], "AddTriangle: unknown vertex id")
			assert(#d.tris < 20000, "EditableMesh: too many triangles")
			table.insert(d.tris, { a, b, c })
			return #d.tris
		end
	elseif k == "Destroy" then
		return function()
			d.destroyed = true
		end
	elseif k == "GetVertices" then
		return function()
			local out = {}
			for i in d.verts do
				table.insert(out, i)
			end
			return out
		end
	end
	error(tostring(k) .. " is not a valid member of EditableMesh", 2)
end }
services.AssetService = {
	CreateEditableMesh = function(self, options)
		assert(self == services.AssetService, "AssetService:CreateEditableMesh")
		assert(options == nil or type(options) == "table", "CreateEditableMesh(options?)")
		if not meshState.available then
			error("EditableMesh APIs are not enabled for this experience")
		end
		meshState.created += 1
		return make("Object", { verts = {}, tris = {} }, EMMT)
	end,
	CreateMeshPartAsync = function(self, content, options)
		assert(self == services.AssetService, "AssetService:CreateMeshPartAsync")
		assert(typeofx(content) == "Content", "CreateMeshPartAsync(content: Content, options)")
		assert(type(options) == "table", "CreateMeshPartAsync: options must be a table")
		for k, v in options do
			assert(k == "CollisionFidelity" or k == "RenderFidelity" or k == "FluidFidelity", "CreateMeshPartAsync: unknown option " .. tostring(k))
			assert(typeofx(v) == "EnumItem", "CreateMeshPartAsync: option values are enums")
		end
		if meshState.meshPartFails then
			error("CreateMeshPartAsync failed")
		end
		local em = DATA[DATA[content].Object]
		local lo, hi
		for _, p in em.verts do
			lo = lo and v3(math.min(lo.X, p.X), math.min(lo.Y, p.Y), math.min(lo.Z, p.Z)) or p
			hi = hi and v3(math.max(hi.X, p.X), math.max(hi.Y, p.Y), math.max(hi.Z, p.Z)) or p
		end
		local mp = newInstance("MeshPart")
		DATA[mp].props.Size = hi - lo
		DATA[mp].triangles = #em.tris
		meshState.parts += 1
		return mp
	end,
}
ENV.workspace = workspaceInst
ENV.game = make("Instance", {}, { __index = function(_, k)
	if k == "GetService" then
		return function(_, name)
			return services[name] or error("no service " .. tostring(name) .. " in the mock")
		end
	elseif k == "Workspace" then
		return workspaceInst
	end
	error(tostring(k) .. " is not a valid member of DataModel", 2)
end })

ENV.Instance = { new = function(class, parent)
	if NOT_CREATABLE[class] then
		error("Unable to create an Instance of type \"" .. tostring(class) .. "\"", 2)
	end
	local o = newInstance(class)
	if parent then
		o.Parent = parent
	end
	return o
end }

-- helpers for the suites
function ENV.part(className, size, cframe, parent)
	local p = ENV.Instance.new(className or "Part")
	p.Anchored = true
	p.Size = size or v3(4, 1, 2)
	p.CFrame = cframe or ENV.CFrame.new()
	if parent ~= false then
		p.Parent = parent or workspaceInst
	end
	return p
end
ENV.__DATA = DATA
ENV.__history = history
ENV.__terrain = terrain
ENV.__csg = csg
ENV.__mesh = meshState
ENV.__services = services
ENV.__selection = function()
	return selection
end
return ENV
