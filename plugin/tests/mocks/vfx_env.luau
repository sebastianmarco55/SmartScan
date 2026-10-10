-- Typed Roblox mock for the VFX runtime tests: instances are checked against the API dump (property names, types,
-- read-only flags, enum members; data in tests/data/api_subset.json), every property access / method call is a counted "bridge
-- call", a fake clock drives tweens, task.delay, render steps and Heartbeat (M.frame(dt)), camera, sounds, quality settings.
--     local ENV = LC.run("tests/mocks/vfx_env.luau", nil, LC); local M = ENV.__M
--     M.load(sourceText, name, scriptInstance)  runs a module with its own `script`; M.frame(1 / 60) advances one frame
local LC = ...
local API = LC.run("tests/data/api_subset.luau")

local M = { now = 0, calls = 0, clones = 0, descendantsCalls = 0, connects = 0, log = {} }
local DATA = setmetatable({}, { __mode = "k" })
local ENV = setmetatable({}, { __index = _G })
ENV.__M = M

local function typeofx(v)
	local t = type(v)
	if t == "userdata" then
		local d = DATA[v]
		if d then
			return d.__type
		end
	end
	return typeof(v)
end
ENV.typeof = typeofx

local function new(typeName, fields, mt)
	local o = newproxy(true)
	local m = getmetatable(o)
	for k, f in mt do
		m[k] = f
	end
	fields.__type = typeName
	DATA[o] = fields
	return o
end

-- Vector3 ------------------------------------------------------------------------------------------------
local V3MT
local function v3(x, y, z)
	return new("Vector3", { X = x, Y = y, Z = z }, V3MT)
end
local function V(o)
	return DATA[o]
end
V3MT = {
	__index = function(self, k)
		local d = DATA[self]
		local r = d[k]
		if r ~= nil and k ~= "__type" then
			return r
		end
		if k == "Magnitude" then
			return math.sqrt(d.X * d.X + d.Y * d.Y + d.Z * d.Z)
		elseif k == "Unit" then
			local m = math.sqrt(d.X * d.X + d.Y * d.Y + d.Z * d.Z)
			if m == 0 then
				return v3(0 / 0, 0 / 0, 0 / 0)
			end
			return v3(d.X / m, d.Y / m, d.Z / m)
		elseif k == "Dot" then
			return function(a, b)
				return V(a).X * V(b).X + V(a).Y * V(b).Y + V(a).Z * V(b).Z
			end
		elseif k == "Cross" then
			return function(a, b)
				local p, q = V(a), V(b)
				return v3(p.Y * q.Z - p.Z * q.Y, p.Z * q.X - p.X * q.Z, p.X * q.Y - p.Y * q.X)
			end
		elseif k == "Lerp" then
			return function(a, b, t)
				local p, q = V(a), V(b)
				return v3(p.X + (q.X - p.X) * t, p.Y + (q.Y - p.Y) * t, p.Z + (q.Z - p.Z) * t)
			end
		end
		error("Vector3 has no member " .. tostring(k), 2)
	end,
	__add = function(a, b)
		local p, q = V(a), V(b)
		return v3(p.X + q.X, p.Y + q.Y, p.Z + q.Z)
	end,
	__sub = function(a, b)
		local p, q = V(a), V(b)
		return v3(p.X - q.X, p.Y - q.Y, p.Z - q.Z)
	end,
	__mul = function(a, b)
		if type(a) == "number" then
			local q = V(b)
			return v3(a * q.X, a * q.Y, a * q.Z)
		elseif type(b) == "number" then
			local p = V(a)
			return v3(p.X * b, p.Y * b, p.Z * b)
		end
		local p, q = V(a), V(b)
		return v3(p.X * q.X, p.Y * q.Y, p.Z * q.Z)
	end,
	__div = function(a, b)
		local p = V(a)
		if type(b) == "number" then
			return v3(p.X / b, p.Y / b, p.Z / b)
		end
		local q = V(b)
		return v3(p.X / q.X, p.Y / q.Y, p.Z / q.Z)
	end,
	__unm = function(a)
		local p = V(a)
		return v3(-p.X, -p.Y, -p.Z)
	end,
	__eq = function(a, b)
		local p, q = V(a), V(b)
		return p.X == q.X and p.Y == q.Y and p.Z == q.Z
	end,
	__tostring = function(a)
		local p = V(a)
		return string.format("%.3f, %.3f, %.3f", p.X, p.Y, p.Z)
	end,
}
ENV.Vector3 = {
	new = function(x, y, z)
		return v3(x or 0, y or 0, z or 0)
	end,
	zero = v3(0, 0, 0), one = v3(1, 1, 1), xAxis = v3(1, 0, 0), yAxis = v3(0, 1, 0), zAxis = v3(0, 0, 1),
}

local V2MT = {
	__index = function(self, k)
		local r = DATA[self][k]
		if r == nil then
			error("Vector2 has no member " .. tostring(k), 2)
		end
		return r
	end,
	__eq = function(a, b)
		return DATA[a].X == DATA[b].X and DATA[a].Y == DATA[b].Y
	end,
}
ENV.Vector2 = { new = function(x, y)
	return new("Vector2", { X = x or 0, Y = y or 0 }, V2MT)
end }

-- CFrame: position p + rotation matrix (columns = right, up, back) -------------------------------------------------
local CFMT
local function cf(px, py, pz, m)
	-- m = { r00, r01, r02, r10, r11, r12, r20, r21, r22 } (row major)
	return new("CFrame", { px = px, py = py, pz = pz, m = m }, CFMT)
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
local function C(o)
	return DATA[o]
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
		elseif k == "RightVector" then
			return v3(m[1], m[4], m[7])
		elseif k == "UpVector" then
			return v3(m[2], m[5], m[8])
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
				local q, w = C(a), V(v)
				return v3(rotV(q.m, w.X, w.Y, w.Z))
			end
		elseif k == "VectorToObjectSpace" then
			return function(a, v)
				local q, w = C(a), V(v)
				return v3(rotV(transpose(q.m), w.X, w.Y, w.Z))
			end
		elseif k == "Lerp" then
			return function(a, b, t)
				local p, q = C(a), C(b)
				return cf(p.px + (q.px - p.px) * t, p.py + (q.py - p.py) * t, p.pz + (q.pz - p.pz) * t, t < 0.5 and p.m or q.m)
			end
		end
		error("CFrame has no member " .. tostring(k), 2)
	end,
	__mul = function(a, b)
		local p = C(a)
		if typeofx(b) == "Vector3" then
			local w = V(b)
			local x, y, z = rotV(p.m, w.X, w.Y, w.Z)
			return v3(p.px + x, p.py + y, p.pz + z)
		end
		local q = C(b)
		local x, y, z = rotV(p.m, q.px, q.py, q.pz)
		return cf(p.px + x, p.py + y, p.pz + z, mulM(p.m, q.m))
	end,
	__add = function(a, b)
		local p, w = C(a), V(b)
		return cf(p.px + w.X, p.py + w.Y, p.pz + w.Z, p.m)
	end,
	__sub = function(a, b)
		local p, w = C(a), V(b)
		return cf(p.px - w.X, p.py - w.Y, p.pz - w.Z, p.m)
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
local function axisAngle(ax, ay, az, angle)
	local m = math.sqrt(ax * ax + ay * ay + az * az)
	ax, ay, az = ax / m, ay / m, az / m
	local c, s = math.cos(angle), math.sin(angle)
	local t = 1 - c
	return {
		t * ax * ax + c, t * ax * ay - s * az, t * ax * az + s * ay,
		t * ax * ay + s * az, t * ay * ay + c, t * ay * az - s * ax,
		t * ax * az - s * ay, t * ay * az + s * ax, t * az * az + c,
	}
end
ENV.CFrame = {
	new = function(a, b, c)
		if a == nil then
			return cf(0, 0, 0, ID)
		elseif typeofx(a) == "Vector3" then
			local w = V(a)
			return cf(w.X, w.Y, w.Z, ID)
		end
		return cf(a, b or 0, c or 0, ID)
	end,
	Angles = function(rx, ry, rz)
		local mx = axisAngle(1, 0, 0, rx)
		local my = axisAngle(0, 1, 0, ry)
		local mz = axisAngle(0, 0, 1, rz)
		return cf(0, 0, 0, mulM(mulM(mx, my), mz))
	end,
	fromAxisAngle = function(axis, angle)
		local w = V(axis)
		return cf(0, 0, 0, axisAngle(w.X, w.Y, w.Z, angle))
	end,
	lookAt = function(at, target, up)
		local p, q = V(at), V(target)
		up = up or ENV.Vector3.yAxis
		local look = (target - at).Unit
		local right = look:Cross(up)
		if right.Magnitude < 1e-6 then
			right = look:Cross(ENV.Vector3.zAxis)
		end
		right = right.Unit
		local up2 = right:Cross(look).Unit
		local r, u, l = V(right), V(up2), V(look)
		return cf(p.X, p.Y, p.Z, { r.X, u.X, -l.X, r.Y, u.Y, -l.Y, r.Z, u.Z, -l.Z })
	end,
}
ENV.CFrame.identity = ENV.CFrame.new()

-- Color3 ----------------------------------------------------------------------------------------------------------
local C3MT
local function c3(r, g, b)
	return new("Color3", { R = r, G = g, B = b }, C3MT)
end
C3MT = {
	__index = function(self, k)
		local d = DATA[self]
		if k == "R" or k == "G" or k == "B" then
			return d[k]
		elseif k == "Lerp" then
			return function(a, b, t)
				local p, q = DATA[a], DATA[b]
				return c3(p.R + (q.R - p.R) * t, p.G + (q.G - p.G) * t, p.B + (q.B - p.B) * t)
			end
		elseif k == "ToHSV" then
			return function(c)
				local r, g, b = c.R, c.G, c.B
				local mx, mn = math.max(r, g, b), math.min(r, g, b)
				local dl = mx - mn
				local h = 0
				if dl > 0 then
					if mx == r then
						h = ((g - b) / dl) % 6
					elseif mx == g then
						h = (b - r) / dl + 2
					else
						h = (r - g) / dl + 4
					end
					h /= 6
				end
				return h, mx == 0 and 0 or dl / mx, mx
			end
		elseif k == "ToHex" then
			return function(c)
				return string.format("%02x%02x%02x", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
			end
		end
		error("Color3 has no member " .. tostring(k), 2)
	end,
	__eq = function(a, b)
		local p, q = DATA[a], DATA[b]
		return p.R == q.R and p.G == q.G and p.B == q.B
	end,
}
local function hsv(h, s, v)
	h %= 1
	local i = math.floor(h * 6)
	local f = h * 6 - i
	local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	i %= 6
	if i == 0 then
		return v, t, p
	elseif i == 1 then
		return q, v, p
	elseif i == 2 then
		return p, v, t
	elseif i == 3 then
		return p, q, v
	elseif i == 4 then
		return t, p, v
	end
	return v, p, q
end
ENV.Color3 = {
	new = function(r, g, b)
		return c3(r or 0, g or 0, b or 0)
	end,
	fromRGB = function(r, g, b)
		return c3((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
	end,
	fromHSV = function(h, s, v)
		return c3(hsv(h, s, v))
	end,
	fromHex = function(s)
		s = s:gsub("#", "")
		assert(#s == 6, "Unable to convert characters to hex value")
		return c3(tonumber(s:sub(1, 2), 16) / 255, tonumber(s:sub(3, 4), 16) / 255, tonumber(s:sub(5, 6), 16) / 255)
	end,
}

-- NumberRange / sequences -------------------------------------------------------------------------------------------
local function plainMT(name)
	return {
		__index = function(self, k)
			local r = DATA[self][k]
			if r == nil or k == "__type" then
				error(name .. " has no member " .. tostring(k), 2)
			end
			return r
		end,
	}
end
local NRMT, NSKMT, NSMT, CSKMT, CSMT = plainMT("NumberRange"), plainMT("NumberSequenceKeypoint"), plainMT("NumberSequence"),
	plainMT("ColorSequenceKeypoint"), plainMT("ColorSequence")
ENV.NumberRange = { new = function(a, b)
	b = b or a
	assert(b >= a, "NumberRange: invalid range")
	return new("NumberRange", { Min = a, Max = b }, NRMT)
end }
ENV.NumberSequenceKeypoint = { new = function(t, v, e)
	assert(t >= 0 and t <= 1, "NumberSequenceKeypoint time out of range")
	return new("NumberSequenceKeypoint", { Time = t, Value = v, Envelope = e or 0 }, NSKMT)
end }
ENV.ColorSequenceKeypoint = { new = function(t, c)
	assert(t >= 0 and t <= 1)
	return new("ColorSequenceKeypoint", { Time = t, Value = c }, CSKMT)
end }
local function seqNew(kind, kpNew, mt, max)
	return function(a, b)
		local points
		if type(a) == "table" then
			points = a
			assert(#points >= 2, kind .. " needs at least 2 keypoints")
			assert(#points <= max, kind .. ": too many keypoints")
			assert(DATA[points[1]].Time == 0 and DATA[points[#points]].Time == 1, kind .. " must start at 0 and end at 1")
			for i = 2, #points do
				assert(DATA[points[i]].Time > DATA[points[i - 1]].Time, kind .. " keypoints must be in increasing time order")
			end
		else
			points = { kpNew(0, a), kpNew(1, b == nil and a or b) }
		end
		return new(kind, { Keypoints = points }, mt)
	end
end
ENV.NumberSequence = { new = seqNew("NumberSequence", ENV.NumberSequenceKeypoint.new, NSMT, 20) }
ENV.ColorSequence = { new = seqNew("ColorSequence", ENV.ColorSequenceKeypoint.new, CSMT, 20) }

local function plainNew(name, fields)
	return new(name, fields, plainMT(name))
end
ENV.TweenInfo = { new = function(time, style, dir)
	return plainNew("TweenInfo", { Time = time or 1, EasingStyle = style, EasingDirection = dir })
end }
ENV.PhysicalProperties = { new = function(a, b, c)
	return plainNew("PhysicalProperties", { Density = a, Friction = b, Elasticity = c })
end }
ENV.RaycastParams = { new = function()
	local o = newproxy(true)
	local store = { FilterType = nil, FilterDescendantsInstances = {} }
	DATA[o] = { __type = "RaycastParams" }
	getmetatable(o).__index = function(_, k)
		return store[k]
	end
	getmetatable(o).__newindex = function(_, k, v)
		assert(k == "FilterType" or k == "FilterDescendantsInstances", "RaycastParams has no " .. k)
		store[k] = v
	end
	return o
end }

-- Enum ----------------------------------------------------------------------------------------------------------------
local EIMT = plainMT("EnumItem")
local ENUMS = {}
ENV.Enum = setmetatable({}, { __index = function(_, name)
	if ENUMS[name] then
		return ENUMS[name]
	end
	local list = API.enums[name]
	if not list then
		error(tostring(name) .. " is not a valid member of Enums", 2)
	end
	local items = {}
	local enum = setmetatable({}, { __index = function(_, item)
		local r = items[item]
		if r == nil then
			error(tostring(item) .. " is not a valid member of Enum." .. name, 2)
		end
		return r
	end })
	for _, it in list do
		items[it[1]] = new("EnumItem", { Name = it[1], Value = it[2], EnumType = enum, EnumName = name }, EIMT)
	end
	ENUMS[name] = enum
	return enum
end })

-- signals + fake clock ---------------------------------------------------------------------------------------------
local function signal()
	local sig = { conns = {} }
	local function connect(fn, once)
		M.connects += 1
		local c = { fn = fn, once = once, connected = true }
		table.insert(sig.conns, c)
		c.Disconnect = function()
			c.connected = false
			local i = table.find(sig.conns, c)
			if i then
				table.remove(sig.conns, i)
			end
		end
		return c
	end
	sig.Connect = function(_, fn)
		return connect(fn, false)
	end
	sig.Once = function(_, fn)
		return connect(fn, true)
	end
	sig.Fire = function(...)
		for _, c in table.clone(sig.conns) do
			if c.connected then
				if c.once then
					c:Disconnect()
				end
				c.fn(...)
			end
		end
	end
	return sig
end
M.signal = signal

local timers = {}
ENV.task = {
	delay = function(t, fn, ...)
		table.insert(timers, { at = M.now + (t or 0), fn = fn, args = table.pack(...) })
	end,
	spawn = function(fn, ...)
		fn(...)
	end,
	defer = function(fn, ...)
		table.insert(timers, { at = M.now, fn = fn, args = table.pack(...) })
	end,
	wait = function()
		return 0
	end,
}
ENV.os = setmetatable({ clock = function()
	return M.now
end }, { __index = os })
ENV.warn = function(...)
	table.insert(M.log, table.concat({ ... }, " "))
end
ENV.print = print

-- Instances ----------------------------------------------------------------------------------------------------------
local INMT
local METHODS = {}
local CLASS_EXTRA = { -- methods / events that are not properties
}
local function info(class)
	local i = API.classes[class]
	if not i then
		error("Unable to create an Instance of type \"" .. class .. "\"", 3)
	end
	return i
end
local function isA(d, cls)
	return table.find(d.info.chain, cls) ~= nil
end
local defaults
local function newInstance(class)
	local o = newproxy(true)
	local m = getmetatable(o)
	for k, f in INMT do
		m[k] = f
	end
	DATA[o] = { __type = "Instance", class = class, info = info(class), props = { Name = class }, attrs = {}, children = {},
		parent = nil, destroyed = false, signals = {} }
	return o
end
M.newInstance = newInstance

local function sigOf(self, name)
	local d = DATA[self]
	d.signals[name] = d.signals[name] or signal()
	return d.signals[name]
end

local function setParent(self, parent)
	local d = DATA[self]
	if d.destroyed then
		error("The Parent property of " .. d.props.Name .. " is locked, current parent: NULL, new parent " .. tostring(parent), 3)
	end
	if d.parent then
		local sibs = DATA[d.parent].children
		table.remove(sibs, table.find(sibs, self))
	end
	d.parent = parent
	if parent then
		table.insert(DATA[parent].children, self)
	end
end

local function descendants(d, out)
	for _, c in d.children do
		table.insert(out, c)
		descendants(DATA[c], out)
	end
	return out
end

defaults = function(d, k, t)
	local cat, name = t:match("^(%a):([^:]+)")
	local class = d.class
	-- a few defaults that matter for the code under test
	if k == "Transparency" and cat == "P" then
		return 0
	elseif k == "Size" and name == "Vector3" then
		return ENV.Vector3.new(4, 1, 2)
	elseif k == "Anchored" or k == "CanCollide" or k == "CanQuery" or k == "CanTouch" or k == "CastShadow" then
		return k ~= "Anchored"
	elseif k == "Enabled" then
		return true
	elseif k == "TimeScale" or k == "PlaybackSpeed" or k == "Brightness" and class ~= "ColorCorrectionEffect" then
		return 1
	elseif k == "Volume" then
		return 0.5
	elseif k == "Lifetime" and class == "Trail" then
		return 2
	elseif k == "Lifetime" then
		return ENV.NumberRange.new(5, 10)
	elseif k == "Rate" then
		return 20
	elseif k == "Range" then
		return 8
	elseif k == "FieldOfView" then
		return 70
	elseif k == "TimeLength" then
		return d.props.SoundId ~= "" and 1.2 or 0
	elseif k == "Width0" or k == "Width1" then
		return 1
	elseif k == "Segments" then
		return 10
	elseif k == "RollOffMaxDistance" then
		return 10000
	elseif k == "RollOffMinDistance" then
		return 10
	end
	if cat == "P" then
		if name == "bool" then
			return false
		elseif name == "string" then
			return ""
		end
		return 0
	elseif cat == "E" then
		local list = API.enums[name]
		return ENV.Enum[name][list[1][1]]
	elseif cat == "D" then
		if name == "NumberRange" then
			return ENV.NumberRange.new(1, 1)
		elseif name == "NumberSequence" then
			return ENV.NumberSequence.new(k == "Transparency" and 0 or 1)
		elseif name == "ColorSequence" then
			return ENV.ColorSequence.new(ENV.Color3.new(1, 1, 1))
		elseif name == "Vector2" then
			return ENV.Vector2.new(0, 0)
		elseif name == "Vector3" then
			return ENV.Vector3.new(0, 0, 0)
		elseif name == "Color3" then
			return ENV.Color3.new(0.64, 0.64, 0.64)
		elseif name == "CFrame" then
			return ENV.CFrame.new()
		elseif name == "ContentId" or name == "Content" then
			return ""
		end
	end
	return nil
end

local function checkType(d, prop, t, v)
	local cat, name, ro = t:match("^(%a):([^:]+):?(.*)")
	if ro == "ro" then
		error(prop .. " is read-only (" .. d.class .. ")", 4)
	end
	local got = typeofx(v)
	local ok = true
	if cat == "P" then
		if name == "bool" then
			ok = got == "boolean"
		elseif name == "string" then
			ok = got == "string"
		else
			ok = got == "number"
			if ok and v ~= v then
				error("NaN assigned to " .. d.class .. "." .. prop, 4)
			end
		end
	elseif cat == "E" then
		ok = got == "EnumItem" and DATA[v].EnumName == name
	elseif cat == "D" then
		if name == "ContentId" or name == "Content" then
			ok = got == "string"
		else
			ok = got == name
		end
	elseif cat == "C" then
		ok = v == nil or (got == "Instance" and isA(DATA[v], name))
	end
	if not ok then
		error(string.format("Unable to assign property %s.%s: expected %s, got %s", d.class, prop, t, got), 4)
	end
end

-- world CFrame of a part / attachment
local function worldCF(o)
	local d = DATA[o]
	if d.class == "Attachment" then
		local p = d.parent
		local base = (p and DATA[p].props.CFrame) or ENV.CFrame.new()
		return base * (d.props.CFrame or ENV.CFrame.new())
	end
	return d.props.CFrame or ENV.CFrame.new()
end

local function bridge()
	M.calls += 1
end

function METHODS.IsA(self, cls)
	return isA(DATA[self], cls)
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
function METHODS.GetChildren(self)
	return table.clone(DATA[self].children)
end
function METHODS.GetDescendants(self)
	M.descendantsCalls += 1
	return descendants(DATA[self], {})
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
function METHODS.GetFullName(self)
	local parts = {}
	local o = self
	while o do
		table.insert(parts, 1, DATA[o].props.Name)
		o = DATA[o].parent
	end
	return table.concat(parts, ".")
end
function METHODS.SetAttribute(self, k, v)
	local t = typeofx(v)
	assert(v == nil or t == "string" or t == "number" or t == "boolean" or t == "Color3" or t == "Vector3" or t == "NumberRange"
		or t == "Vector2" or t == "ColorSequence" or t == "NumberSequence" or t == "CFrame", "SetAttribute: unsupported type " .. t)
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
	if d.signals.Destroying then
		d.signals.Destroying.Fire()
	end
	for _, c in table.clone(d.children) do
		METHODS.Destroy(c)
	end
	if d.parent then
		setParent(self, nil)
	end
	d.destroyed = true
	if d.class == "Sound" then
		d.playing = false
	end
end
function METHODS.Clone(self)
	M.clones += 1
	local d = DATA[self]
	if d.props.Archivable == false then
		return nil
	end
	local map = {}
	local function copy(o)
		local s = DATA[o]
		local c = newInstance(s.class)
		map[o] = c
		local cd = DATA[c]
		for k, v in s.props do
			cd.props[k] = v
		end
		for k, v in s.attrs do
			cd.attrs[k] = v
		end
		for _, ch in s.children do
			if DATA[ch].props.Archivable ~= false then
				local cc = copy(ch)
				DATA[cc].parent = c
				table.insert(cd.children, cc)
			end
		end
		return c
	end
	local root = copy(self)
	-- references inside the copy point to the copies (PrimaryPart, Attachment0/1, Part0/1)
	for orig, c in map do
		for k, v in DATA[c].props do
			if typeofx(v) == "Instance" and map[v] then
				DATA[c].props[k] = map[v]
			end
		end
	end
	return root
end
function METHODS.WaitForChild(self, name)
	return METHODS.FindFirstChild(self, name)
end
function METHODS.GetPivot(self)
	local d = DATA[self]
	if d.class == "Model" then
		local pp = d.props.PrimaryPart
		return pp and worldCF(pp) or ENV.CFrame.new()
	end
	return worldCF(self)
end
function METHODS.PivotTo(self, target)
	local d = DATA[self]
	if d.class ~= "Model" then
		d.props.CFrame = target
		return
	end
	local pivot = METHODS.GetPivot(self)
	local delta = target * pivot:Inverse()
	for _, o in descendants(d, {}) do
		local od = DATA[o]
		if isA(od, "BasePart") then
			od.props.CFrame = delta * (od.props.CFrame or ENV.CFrame.new())
		end
	end
end
function METHODS.GetPropertyChangedSignal(self, name)
	return sigOf(self, "Changed:" .. name)
end
-- ParticleEmitter
function METHODS.Emit(self, n)
	local d = DATA[self]
	assert(d.class == "ParticleEmitter", "Emit on " .. d.class)
	assert(type(n) == "number" and n >= 0, "Emit count")
	d.emitted = (d.emitted or 0) + n
	M.emits = (M.emits or 0) + n
end
function METHODS.Clear(self)
	DATA[self].emitted = 0
end
-- Sound
function METHODS.Play(self)
	local d = DATA[self]
	assert(d.class == "Sound")
	d.playing, d.paused, d.playedAt = true, false, M.now
	d.plays = (d.plays or 0) + 1
	M.soundPlays = (M.soundPlays or 0) + 1
end
function METHODS.Stop(self)
	local d = DATA[self]
	d.playing, d.paused = false, false
end
function METHODS.Pause(self)
	local d = DATA[self]
	if d.playing then
		d.playing, d.paused = false, true
	end
end
function METHODS.Resume(self)
	local d = DATA[self]
	if d.paused then
		d.playing, d.paused = true, false
	end
end
-- Workspace
function METHODS.Raycast(self, origin, dir, params)
	-- the floor: the plane y = 0
	local o, dd = V(origin), V(dir)
	if dd.Y >= 0 or o.Y < 0 or o.Y + dd.Y > 0 then
		return nil
	end
	local t = -o.Y / dd.Y
	return { Position = ENV.Vector3.new(o.X + dd.X * t, 0, o.Z + dd.Z * t), Normal = ENV.Vector3.yAxis, Instance = nil }
end
function METHODS.GetMarkerReachedSignal(self, name)
	return sigOf(self, "Marker:" .. name)
end

local EVENTS = { Ended = true, Destroying = true, Changed = true, AncestryChanged = true, ChildAdded = true }

INMT = {
	__index = function(self, k)
		bridge()
		local d = DATA[self]
		if d.destroyed and k == "Parent" then
			return nil
		end
		if k == "ClassName" then
			return d.class
		elseif k == "Parent" then
			return d.parent
		end
		local m = METHODS[k]
		if m then
			return function(s, ...)
				return m(s, ...)
			end
		end
		if EVENTS[k] then
			return sigOf(self, k)
		end
		local t = d.info.props[k]
		if t then
			if d.class == "Sound" then
				if k == "IsPlaying" or k == "Playing" then
					return d.playing == true
				elseif k == "IsPaused" then
					return d.paused == true
				end
			end
			if d.class == "Attachment" then
				if k == "Position" then
					return (d.props.CFrame or ENV.CFrame.new()).Position
				elseif k == "WorldCFrame" then
					return worldCF(self)
				elseif k == "WorldPosition" then
					return worldCF(self).Position
				end
			end
			if k == "Position" and d.info.props.CFrame then
				return (d.props.CFrame or ENV.CFrame.new()).Position
			end
			local v = d.props[k]
			if v == nil then
				v = defaults(d, k, t)
				d.props[k] = v
			end
			return v
		end
		local c = METHODS.FindFirstChild(self, k)
		if c then
			return c
		end
		error(tostring(k) .. " is not a valid member of " .. d.class .. " \"" .. tostring(d.props.Name) .. "\"", 2)
	end,
	__newindex = function(self, k, v)
		bridge()
		local d = DATA[self]
		if k == "Parent" then
			setParent(self, v)
			return
		end
		if d.destroyed then
			-- Roblox allows property writes on destroyed instances (only Parent is locked)
		end
		local t = d.info.props[k]
		if not t then
			error(tostring(k) .. " is not a valid member of " .. d.class, 2)
		end
		if k == "Position" and d.info.props.CFrame then
			checkType(d, k, "D:Vector3", v)
			local old = d.props.CFrame or ENV.CFrame.new()
			d.props.CFrame = old - old.Position + v
			return
		end
		if k == "WorldPosition" or k == "WorldCFrame" then
			error("mock: world writes not supported", 2)
		end
		checkType(d, k, t, v)
		if d.class == "Sound" and k == "Playing" then
			d.playing = v
			return
		end
		if k == "TimeScale" then
			assert(v >= 0 and v <= 1, "TimeScale out of range " .. v) -- clamped by Roblox; the code must not rely on more
		end
		if k == "Brightness" and d.class == "ColorCorrectionEffect" then
			assert(v >= -1 and v <= 1, "ColorCorrectionEffect.Brightness out of range")
		end
		d.props[k] = v
		local s = d.signals["Changed:" .. k]
		if s then
			s.Fire()
		end
	end,
	__tostring = function(self)
		return DATA[self].props.Name
	end,
}
ENV.Instance = { new = function(class, parent)
	local o = newInstance(class)
	if parent then
		setParent(o, parent)
	end
	return o
end }
M.DATA = DATA

-- services -------------------------------------------------------------------------------------------------------------
local services = {}
M.services = services
local workspaceInst = newInstance("Workspace")
DATA[workspaceInst].props.Name = "Workspace"
local camera = newInstance("Camera")
DATA[camera].props.Name = "Camera"
DATA[camera].props.CFrame = ENV.CFrame.new(0, 10, 30)
setParent(camera, workspaceInst)
DATA[workspaceInst].props.CurrentCamera = camera
ENV.workspace = workspaceInst
M.camera = camera

-- render steps + Heartbeat
local heartbeat = signal()
local renderStepped = signal()
local renderBinds = {}
M.flags = { studio = false, running = true, client = true, renderSteps = true }
services.RunService = setmetatable({
	Heartbeat = heartbeat, RenderStepped = renderStepped, Stepped = signal(), PreRender = signal(),
	IsStudio = function()
		bridge()
		return M.flags.studio
	end,
	IsRunning = function()
		bridge()
		return M.flags.running
	end,
	IsClient = function()
		bridge()
		return M.flags.client
	end,
	IsServer = function()
		return not M.flags.client
	end,
	BindToRenderStep = function(_, name, priority, fn)
		bridge()
		if not M.flags.renderSteps then
			error("BindToRenderStep is not available here")
		end
		assert(type(name) == "string" and type(priority) == "number" and type(fn) == "function")
		for _, b in renderBinds do
			assert(b.name ~= name, "duplicate render step " .. name)
		end
		table.insert(renderBinds, { name = name, priority = priority, fn = fn })
		table.sort(renderBinds, function(a, b)
			return a.priority < b.priority
		end)
	end,
	UnbindFromRenderStep = function(_, name)
		bridge()
		for i, b in renderBinds do
			if b.name == name then
				table.remove(renderBinds, i)
				return
			end
		end
	end,
}, { __index = function(_, k)
	error("RunService." .. tostring(k) .. " not mocked")
end })
M.renderBinds = renderBinds

-- tweens
local tweens = {}
services.TweenService = { Create = function(_, inst, ti, goal)
	bridge()
	assert(typeofx(inst) == "Instance")
	for k, v in goal do -- the goal must be valid properties
		local d = DATA[inst]
		assert(d.info.props[k], "tween goal: no property " .. k)
		checkType(d, k, d.info.props[k], v)
	end
	local tw = { inst = inst, time = DATA[ti].Time, goal = goal, elapsed = 0, state = "Begin", Completed = signal() }
	function tw.Play(t)
		bridge()
		if t.state ~= "Completed" and t.state ~= "Cancelled" then
			t.state = "Playing"
			if not table.find(tweens, t) then
				table.insert(tweens, t)
			end
		end
	end
	function tw.Pause(t)
		bridge()
		if t.state == "Playing" then
			t.state = "Paused"
		end
	end
	function tw.Cancel(t)
		t.state = "Cancelled"
		t.Completed.Fire(ENV.Enum.PlaybackState.Cancelled)
	end
	M.tweensCreated = (M.tweensCreated or 0) + 1
	return tw
end }
M.tweens = tweens

services.ContentProvider = { PreloadAsync = function(_, list)
	M.preloaded = list
end }
local userGameSettings = { SavedQualityLevel = nil }
M.userGameSettings = userGameSettings
local qualitySignal = signal()
ENV.UserSettings = function()
	return { GetService = function(_, name)
		assert(name == "UserGameSettings")
		return setmetatable({ GetPropertyChangedSignal = function(_, p)
			assert(p == "SavedQualityLevel")
			return qualitySignal
		end }, { __index = function(_, k)
			if k == "SavedQualityLevel" then
				return userGameSettings.SavedQualityLevel or ENV.Enum.SavedQualitySetting.Automatic
			end
			error("UserGameSettings." .. k)
		end })
	end }
end
M.qualitySignal = qualitySignal

-- the camera scripts: each render frame (priority Camera) they set the camera from their own state, reading LookVector
M.cameraScript = nil -- function(camera) or nil
local function camScriptStep()
	if M.cameraScript then
		M.cameraScript(camera)
	end
end

function M.frame(dt)
	dt = dt or 1 / 60
	M.now += dt
	-- timers
	local due = {}
	for i = #timers, 1, -1 do
		if timers[i].at <= M.now then
			table.insert(due, 1, table.remove(timers, i))
		end
	end
	table.sort(due, function(a, b)
		return a.at < b.at
	end)
	for _, t in due do
		t.fn(table.unpack(t.args, 1, t.args.n))
	end
	-- sounds end
	for o, d in DATA do
		if type(d) == "table" and d.class == "Sound" and d.playing and not d.destroyed then
			local len = (d.props.SoundId or "") ~= "" and 1.2 or 0
			local speed = d.props.PlaybackSpeed or 1
			if not d.props.Looped and M.now - d.playedAt >= len / speed then
				d.playing = false
				if d.signals.Ended then
					d.signals.Ended.Fire(d.props.SoundId)
				end
			end
		end
	end
	-- render: binds below Camera, the camera scripts, the rest
	local ranCam = false
	for _, b in table.clone(renderBinds) do
		if b.priority >= 200 and not ranCam then
			ranCam = true
			camScriptStep()
		end
		b.fn(dt)
	end
	if not ranCam then
		camScriptStep()
	end
	renderStepped.Fire(dt)
	-- tweens
	for i = #tweens, 1, -1 do
		local tw = tweens[i]
		if tw.state == "Playing" then
			tw.elapsed += dt
			if tw.elapsed >= tw.time then
				table.remove(tweens, i)
				tw.state = "Completed"
				for k, v in tw.goal do
					DATA[tw.inst].props[k] = v
				end
				tw.Completed.Fire(ENV.Enum.PlaybackState.Completed)
			end
		elseif tw.state == "Completed" or tw.state == "Cancelled" then
			table.remove(tweens, i)
		end
	end
	heartbeat.Fire(dt)
end
M.heartbeat = heartbeat

-- editor-side services
local history = { active = nil, n = 0, log = {} }
M.history = history
services.ChangeHistoryService = {
	TryBeginRecording = function(_, name)
		if history.active then
			return nil
		end
		history.n += 1
		history.active = history.n
		return history.n
	end,
	FinishRecording = function(_, id, op)
		assert(history.active == id)
		history.active = nil
		table.insert(history.log, DATA[op].Name)
	end,
}
services.HttpService = {
	JSONEncode = function(_, v)
		return "[]"
	end,
	JSONDecode = function()
		return {}
	end,
}
services.Selection = { Get = function()
	return M.selection or {}
end, Set = function(_, list)
	M.selection = list
end }
local rs = newInstance("Folder")
DATA[rs].props.Name = "ReplicatedStorage"
services.ReplicatedStorage = rs
local ss = newInstance("Folder")
DATA[ss].props.Name = "ServerStorage"
services.ServerStorage = ss
services.SoundService = { PlayLocalSound = function(_, s)
	M.localSound = s
end }
services.InsertService = { LoadAsset = function()
	error("no network")
end }
services.Workspace = workspaceInst
ENV.game = {
	GetService = function(_, name)
		return services[name] or error("no service " .. name)
	end,
	GetObjects = function()
		error("no network")
	end,
}

function M.reset()
	table.clear(timers)
	table.clear(tweens)
	M.calls, M.clones, M.descendantsCalls, M.connects = 0, 0, 0, 0
end
M.timers = timers

-- module loading: each module gets its own `script`
function M.load(src, name, scriptInst)
	local chunk, err = loadstring(src, "=" .. name)
	assert(chunk, err)
	local env = setmetatable({ script = scriptInst }, { __index = ENV })
	setfenv(chunk, env)
	return chunk()
end

return ENV
