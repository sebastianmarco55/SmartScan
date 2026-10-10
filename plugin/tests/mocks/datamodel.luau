-- DataModel mock: arbitrary-property Instances in a game tree (services, children, attributes), a JSON codec that
-- refuses what HttpService refuses, ChangeHistoryService recordings, Roblox datatypes carrying a `__type`.
-- Written for the Analyzer (it scans a whole place); `M.enableGui()` adds what AnalysisPanel needs on top (GUI datatypes,
-- lenient instances whose unknown members are signals, a task scheduler).
--
--     local M = LC.run("tests/mocks/datamodel.luau")
--     local env = LC.env(M.globals())     -- what the plugin sources see (game, workspace, Instance, Enum, os, task, ...)
--     M.new("Part", "Name", { Size = M.V3(1, 2, 3) }, { children })     M.service("ServerStorage", { props })
local builtinTypeof = typeof
local function typeof(v)
	if type(v) == "table" then
		local mt = getmetatable(v)
		if type(mt) == "table" and rawget(mt, "__type") then
			return rawget(mt, "__type")
		end
	end
	return builtinTypeof(v)
end

-- a slow machine: every os.clock() call costs 4 ms, so the frame budget runs out and the scan must yield
local realOs = os
local fakeClock = 0
local os = setmetatable({ clock = function()
	fakeClock += 0.004
	return fakeClock
end }, { __index = realOs })

-- Roblox datatypes ------------------------------------------------------------------------------
local Color3MT = { __type = "Color3" }
Color3MT.__index = Color3MT
function Color3MT.ToHex(c)
	return string.format("%02x%02x%02x", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end
local Color3 = {}
function Color3.fromRGB(r, g, b)
	return setmetatable({ R = r / 255, G = g / 255, B = b / 255 }, Color3MT)
end
function Color3.new(r, g, b)
	return setmetatable({ R = r, G = g, B = b }, Color3MT)
end
local function V3(x, y, z)
	return setmetatable({ X = x, Y = y, Z = z }, { __type = "Vector3" })
end
local function NR(a, b)
	return setmetatable({ Min = a, Max = b or a }, { __type = "NumberRange" })
end
local function CS(...)
	local kps = {}
	for _, c in { ... } do
		table.insert(kps, { Value = c })
	end
	return setmetatable({ Keypoints = kps }, { __type = "ColorSequence" })
end
local function UD2(xs, xo, ys, yo)
	return setmetatable({ X = { Scale = xs, Offset = xo }, Y = { Scale = ys, Offset = yo } }, { __type = "UDim2" })
end

local EnumMT = { __type = "EnumItem" }
EnumMT.__index = EnumMT
EnumMT.__tostring = function(e)
	return "Enum." .. e.EnumType .. "." .. e.Name
end
local Enum = setmetatable({}, { __index = function(t, enumType)
	local items = setmetatable({}, { __index = function(items, name)
		local item = setmetatable({ Name = name, EnumType = enumType }, EnumMT)
		rawset(items, name, item)
		return item
	end })
	rawset(t, enumType, items)
	return items
end })

-- Instances -------------------------------------------------------------------------------------
local BASES = {
	Part = { "BasePart", "PVInstance" }, MeshPart = { "BasePart", "PVInstance" }, UnionOperation = { "BasePart", "PVInstance" },
	SpawnLocation = { "BasePart", "Part" }, Seat = { "BasePart" }, VehicleSeat = { "BasePart" }, Terrain = { "BasePart" },
	Frame = { "GuiObject" }, TextButton = { "GuiObject", "GuiButton" }, TextLabel = { "GuiObject" }, TextBox = { "GuiObject" },
	ImageLabel = { "GuiObject" }, ScreenGui = { "LayerCollector" }, RopeConstraint = { "Constraint" },
	StringValue = { "ValueBase" }, IntValue = { "ValueBase" }, Script = { "LuaSourceContainer", "BaseScript" },
	LocalScript = { "LuaSourceContainer", "BaseScript", "Script" }, ModuleScript = { "LuaSourceContainer" },
	Model = { "PVInstance" }, Keyframe = {}, KeyframeMarker = {}, Pose = {},
}
local InstMT = {}
local methods = {}
local function new(class, name, props, kids)
	local data = { ClassName = class, Name = name or class, _children = {}, _attrs = {} }
	local o = setmetatable({ _data = data }, InstMT)
	for k, v in props or {} do
		data[k] = v
	end
	for _, c in kids or {} do
		c.Parent = o
	end
	return o
end
InstMT.__type = "Instance"
InstMT.__index = function(o, k)
	local m = methods[k]
	if m then
		return m
	end
	local data = rawget(o, "_data")
	local v = data[k]
	if v == nil and k ~= "Parent" then
		-- like Roblox: a child with that name, else an error for an unknown member
		for _, c in data._children do
			if c.Name == k then
				return c
			end
		end
		error(tostring(k) .. " is not a valid member of " .. data.ClassName, 2)
	end
	return v
end
InstMT.__newindex = function(o, k, v)
	local data = rawget(o, "_data")
	if k == "Parent" then
		local old = data.Parent
		if old then
			local list = rawget(old, "_data")._children
			for i, c in list do
				if c == o then
					table.remove(list, i)
					break
				end
			end
		end
		data.Parent = v
		if v then
			table.insert(rawget(v, "_data")._children, o)
		end
	else
		data[k] = v
	end
end
InstMT.__tostring = function(o)
	return rawget(o, "_data").Name
end
function methods.GetChildren(o)
	return table.clone(rawget(o, "_data")._children)
end
function methods.GetDescendants(o)
	local out = {}
	local function walk(x)
		for _, c in rawget(x, "_data")._children do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(o)
	return out
end
function methods.IsA(o, class)
	local own = rawget(o, "_data").ClassName
	if own == class or class == "Instance" then
		return true
	end
	for _, b in BASES[own] or {} do
		if b == class then
			return true
		end
	end
	return false
end
function methods.FindFirstChild(o, name)
	for _, c in rawget(o, "_data")._children do
		if c.Name == name then
			return c
		end
	end
	return nil
end
function methods.FindFirstChildOfClass(o, class)
	for _, c in rawget(o, "_data")._children do
		if c.ClassName == class then
			return c
		end
	end
	return nil
end
function methods.FindFirstAncestorOfClass(o, class)
	local p = o.Parent
	while p do
		if p.ClassName == class then
			return p
		end
		p = p.Parent
	end
	return nil
end
function methods.FindFirstAncestor(o, name)
	local p = o.Parent
	while p do
		if p.Name == name then
			return p
		end
		p = p.Parent
	end
	return nil
end
function methods.IsDescendantOf(o, ancestor)
	local p = o.Parent
	while p do
		if p == ancestor then
			return true
		end
		p = p.Parent
	end
	return false
end
function methods.GetFullName(o)
	local names = {}
	local x = o
	while x and x.ClassName ~= "DataModel" do
		table.insert(names, 1, x.Name)
		x = x.Parent
	end
	return table.concat(names, ".")
end
function methods.GetAttribute(o, k)
	return rawget(o, "_data")._attrs[k]
end
function methods.SetAttribute(o, k, v)
	rawget(o, "_data")._attrs[k] = v
end
function methods.Destroy(o)
	o.Parent = nil
end
function methods.CountCells()
	return 1234
end
local Instance = { new = function(class)
	local props = {}
	if class == "StringValue" then
		props.Value = ""
	end
	return new(class, class, props)
end }

-- JSON like HttpService (errors on what Roblox cannot encode) ------------------------------------
local function encode(v)
	local t = type(v)
	if t == "nil" then
		return "null"
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "number" then
		assert(v == v and v ~= math.huge and v ~= -math.huge, "JSON: bad number")
		if v == math.floor(v) and math.abs(v) < 1e15 then
			return string.format("%d", v)
		end
		return string.format("%.14g", v)
	elseif t == "string" then
		return '"' .. string.gsub(v, '[%c"\\]', function(c)
			local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
			return map[c] or string.format("\\u%04x", string.byte(c))
		end) .. '"'
	elseif t == "table" then
		assert(getmetatable(v) == nil, "JSON: Roblox type " .. typeof(v))
		local n, entries, strings = #v, 0, 0
		for k in v do
			entries += 1
			if type(k) == "string" then
				strings += 1
			end
		end
		if entries == n then
			local out = {}
			for i = 1, n do
				out[i] = encode(v[i])
			end
			return "[" .. table.concat(out, ",") .. "]"
		end
		assert(strings == entries, "JSON: Can't convert mixed table")
		local out = {}
		for k, x in v do
			table.insert(out, encode(k) .. ":" .. encode(x))
		end
		return "{" .. table.concat(out, ",") .. "}"
	end
	error("JSON: Can't convert " .. t)
end
local function decode(s)
	local pos = 1
	local function ws()
		pos = string.find(s, "[^ \t\r\n]", pos) or #s + 1
	end
	local value
	local function str()
		pos += 1
		local out = {}
		while true do
			if pos > #s then
				error("JSONDecode: unterminated string") -- like Roblox: invalid JSON raises, it does not loop
			end
			local c = string.sub(s, pos, pos)
			if c == '"' then
				pos += 1
				return table.concat(out)
			elseif c == "\\" then
				local e = string.sub(s, pos + 1, pos + 1)
				if e == "u" then
					table.insert(out, utf8.char(tonumber(string.sub(s, pos + 2, pos + 5), 16)))
					pos += 6
				else
					table.insert(out, ({ n = "\n", r = "\r", t = "\t" })[e] or e)
					pos += 2
				end
			else
				table.insert(out, c)
				pos += 1
			end
		end
	end
	function value()
		ws()
		local c = string.sub(s, pos, pos)
		if c == "{" then
			pos += 1
			local t = {}
			ws()
			if string.sub(s, pos, pos) == "}" then
				pos += 1
				return t
			end
			while true do
				ws()
				local k = str()
				ws()
				pos += 1 -- :
				t[k] = value()
				ws()
				local d = string.sub(s, pos, pos)
				pos += 1
				if d == "}" then
					return t
				end
			end
		elseif c == "[" then
			pos += 1
			local t = {}
			ws()
			if string.sub(s, pos, pos) == "]" then
				pos += 1
				return t
			end
			while true do
				table.insert(t, value())
				ws()
				local d = string.sub(s, pos, pos)
				pos += 1
				if d == "]" then
					return t
				end
			end
		elseif c == '"' then
			return str()
		elseif string.sub(s, pos, pos + 3) == "true" then
			pos += 4
			return true
		elseif string.sub(s, pos, pos + 4) == "false" then
			pos += 5
			return false
		elseif string.sub(s, pos, pos + 3) == "null" then
			pos += 4
			return nil
		else
			local num = string.match(s, "^-?[%d%.eE%+%-]+", pos)
			if not num then
				error("JSONDecode: unexpected character '" .. c .. "' at " .. pos)
			end
			pos += #num
			return tonumber(num)
		end
	end
	local result = value()
	ws()
	if pos <= #s then
		error("JSONDecode: unexpected trailing characters at " .. pos)
	end
	return result
end

-- services + game -------------------------------------------------------------------------------
local recordings = { begun = 0, finished = 0 }
local HttpService = new("HttpService", "HttpService", { HttpEnabled = false })
methods.JSONEncode = function(_, v)
	return encode(v)
end
methods.JSONDecode = function(_, s)
	return decode(s)
end
methods.TryBeginRecording = function()
	recordings.begun += 1
	return "rec" .. recordings.begun
end
methods.FinishRecording = function()
	recordings.finished += 1
end
local ChangeHistoryService = new("ChangeHistoryService", "ChangeHistoryService")
local game = new("DataModel", "TestPlace", { PlaceId = 0, GameId = 0, CreatorType = Enum.CreatorType.User, CreatorId = 1,
	PlaceVersion = 3 })
local services = {}
local function service(class, props)
	local s = new(class, class, props)
	s.Parent = game
	services[class] = s
	return s
end
methods.GetService = function(o, name)
	if o == game then
		return services[name] or (name == "HttpService" and HttpService) or (name == "ChangeHistoryService" and ChangeHistoryService)
			or error("no service " .. name)
	end
	error("GetService on non-game")
end
methods.FindService = function(o, name)
	return services[name]
end

local yields = 0
local task = { wait = function()
	yields += 1
	if coroutine.isyieldable() then
		coroutine.yield()
	end
end }
local function warn(...)
	print("WARN", ...)
end
local workspace = service("Workspace", { StreamingEnabled = false, Gravity = 196.2 })

local M = {
	new = new, service = service, V3 = V3, NR = NR, CS = CS, UD2 = UD2, methods = methods, services = services,
	recordings = recordings, Instance = Instance, Enum = Enum, Color3 = Color3, typeof = typeof, os = os, task = task,
	warn = warn, game = game, workspace = workspace, realOs = realOs, ChangeHistoryService = ChangeHistoryService,
	HttpService = HttpService,
}
function M.yieldCount()
	return yields
end
function M.globals()
	local g = { game = game, workspace = workspace, Instance = Instance, Enum = Enum, Color3 = Color3, typeof = typeof,
		os = os, task = task, warn = warn }
	for k, v in M.guiGlobals or {} do
		g[k] = v
	end
	return g
end
function M.enableGui()
	local PENDING = {}
	-- extra mocks for rendering the panel: GUI datatypes, lenient instances (unknown members are signals), script/require
	local function UDimV(scale, offset)
		return setmetatable({ Scale = scale, Offset = offset }, { __type = "UDim" })
	end
	local UDim = { new = UDimV }
	local UDim2 = {
		new = function(xs, xo, ys, yo)
			return setmetatable({ X = UDimV(xs, xo), Y = UDimV(ys, yo) }, { __type = "UDim2" })
		end,
	}
	function UDim2.fromScale(x, y)
		return UDim2.new(x, 0, y, 0)
	end
	function UDim2.fromOffset(x, y)
		return UDim2.new(0, x, 0, y)
	end
	local Vector2 = { new = function(x, y)
		return setmetatable({ X = x, Y = y }, { __type = "Vector2" })
	end }
	Vector2.zero = Vector2.new(0, 0)
	function Color3.fromHex(hex)
		hex = string.gsub(hex, "#", "")
		assert(#hex == 6, "bad hex " .. hex)
		return Color3.fromRGB(tonumber(string.sub(hex, 1, 2), 16), tonumber(string.sub(hex, 3, 4), 16), tonumber(string.sub(hex, 5, 6), 16))
	end

	-- lenient instances: unknown members are signals (Connect stores the handler, :Fire calls them)
	local SignalMT = {}
	SignalMT.__index = SignalMT
	function SignalMT.Connect(sig, fn)
		table.insert(sig.handlers, fn)
		return { Disconnect = function() end }
	end
	function SignalMT.Fire(sig, ...)
		for _, fn in sig.handlers do
			fn(...)
		end
	end
	local GUI_DEFAULTS = { AbsoluteContentSize = Vector2.new(100, 40), AbsoluteSize = Vector2.new(300, 24),
		AbsolutePosition = Vector2.new(0, 0), Text = "", SelectionStart = -1, CursorPosition = -1 }
	local strictIndex = InstMT.__index
	InstMT.__index = function(o, k)
		local ok, v = pcall(strictIndex, o, k)
		if ok then
			return v
		end
		local data = rawget(o, "_data")
		if GUI_DEFAULTS[k] ~= nil and data.gui then
			return GUI_DEFAULTS[k]
		end
		if data.gui or data.lenient then
			data._signals = data._signals or {}
			local sig = data._signals[k]
			if not sig then
				sig = setmetatable({ handlers = {} }, SignalMT)
				data._signals[k] = sig
			end
			return sig
		end
		error(v, 2)
	end
	for _, class in { "Frame", "TextLabel", "TextButton", "TextBox", "ScrollingFrame", "ImageLabel", "ImageButton" } do
		BASES[class] = BASES[class] or {}
		table.insert(BASES[class], "GuiObject")
	end
	local strictNewInstance = Instance.new
	Instance.new = function(class)
		local o = strictNewInstance(class)
		rawget(o, "_data").gui = true
		return o
	end
	function methods.GetPropertyChangedSignal(o, name)
		local data = rawget(o, "_data")
		data._signals = data._signals or {}
		local key = "Changed:" .. name
		data._signals[key] = data._signals[key] or setmetatable({ handlers = {} }, SignalMT)
		return data._signals[key]
	end
	function methods.CaptureFocus(o)
		rawget(o, "_data").focused = true
		o.Focused:Fire()
	end
	function methods.IsFocused(o)
		return rawget(o, "_data").focused == true
	end
	local selected = nil
	function methods.Set(_, list)
		selected = list
	end
	function methods.IsEdit()
		return true
	end
	local opened = {}
	function methods.OpenScript(_, s, line)
		table.insert(opened, { s, line })
	end
	function methods.GetSetting()
		return nil
	end
	function methods.SetSetting() end
	task.spawn = function(f, ...)
		local co = coroutine.create(f)
		local ok, err = coroutine.resume(co, ...)
		assert(ok, err)
		table.insert(PENDING, co)
	end
	task.defer = function(f, ...)
		f(...)
	end
	task.delay = function() end
	local function drain()
		local again = true
		while again do
			again = false
			for i = #PENDING, 1, -1 do
				local co = PENDING[i]
				if coroutine.status(co) == "dead" then
					table.remove(PENDING, i)
				else
					again = true
					local ok, err = coroutine.resume(co)
					assert(ok, err)
				end
			end
		end
	end

	M.guiGlobals = { UDim = UDim, UDim2 = UDim2, Vector2 = Vector2 }
	M.gui = {
		SignalMT = SignalMT, InstMT = InstMT, BASES = BASES, -- for suites that count or replace signal connections
		drain = drain,
		pending = PENDING,
		opened = opened,
		selected = function()
			return selected
		end,
	}
end

return M
