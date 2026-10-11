-- Mock for the agent-mode suites (AI.runAgent, Tools, ClaudePanel agent): a strict JSON decoder and a loose encoder, a
-- scheduler with a virtual clock (task.wait advances it), Roblox datatypes, ONE Instance mock for GUI classes (strict
-- property whitelist) and DataModel classes, services (HttpService queue, Selection, ChangeHistoryService, LogService ...).
-- Run it in a fresh environment (like mocks/gui.luau): its globals land there, including the test helpers check / has
-- and the counters PASS / FAIL / MOCK_ERRORS.
--     local env = LC.env(); LC.run("tests/mocks/agent_env.luau", env, LC)
--     env.TREE = LC.modtree.new{ env = env, mocks = env.MOCKS, require = function(ref) return env.reqInstance(ref) end }
MOCK_ERRORS = {}
local function fail(msg) table.insert(MOCK_ERRORS, msg); error(msg, 3) end

-- ---------------------------------------------------------------------------------------------
-- JSON
-- ---------------------------------------------------------------------------------------------
JSON = {}
function JSON.decode(s)
	assert(type(s) == "string", "decode: not a string")
	local i = 1
	local function ws() i = string.find(s, "[^ \t\r\n]", i) or (#s + 1) end
	local value
	local ESC = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
	local function str()
		local out = {}
		i += 1
		while true do
			local j = string.find(s, '["\\%c]', i)
			if not j then error("unterminated string") end
			local ch = string.sub(s, j, j)
			if ch ~= '"' and ch ~= "\\" then error("raw control character in string at " .. j) end
			table.insert(out, string.sub(s, i, j - 1))
			if ch == '"' then i = j + 1; break end
			local esc = string.sub(s, j + 1, j + 1)
			if esc == "u" then
				local cp = tonumber(string.sub(s, j + 2, j + 5), 16) or error("bad \\u")
				i = j + 6
				if cp >= 0xD800 and cp <= 0xDBFF and string.sub(s, i, i + 1) == "\\u" then
					local lo = tonumber(string.sub(s, i + 2, i + 5), 16)
					cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
					i += 6
				end
				table.insert(out, utf8.char(cp))
			else
				table.insert(out, ESC[esc] or error("bad escape \\" .. esc))
				i = j + 2
			end
		end
		local text = table.concat(out)
		if not utf8.len(text) then error("invalid UTF-8 in string") end
		return text
	end
	function value()
		ws()
		local c = string.sub(s, i, i)
		if c == "{" then
			i += 1
			local t = {}
			ws()
			if string.sub(s, i, i) == "}" then i += 1; return t end
			while true do
				ws()
				if string.sub(s, i, i) ~= '"' then error("key expected at " .. i) end
				local k = str()
				ws()
				if string.sub(s, i, i) ~= ":" then error(": expected at " .. i) end
				i += 1
				t[k] = value()
				ws()
				local d = string.sub(s, i, i)
				i += 1
				if d == "}" then return t elseif d ~= "," then error(", or } expected at " .. (i - 1)) end
			end
		elseif c == "[" then
			i += 1
			local t, n = {}, 0
			ws()
			if string.sub(s, i, i) == "]" then i += 1; return t end
			while true do
				n += 1
				t[n] = value()
				ws()
				local d = string.sub(s, i, i)
				i += 1
				if d == "]" then return t elseif d ~= "," then error(", or ] expected at " .. (i - 1)) end
			end
		elseif c == '"' then
			return str()
		elseif string.sub(s, i, i + 3) == "true" then i += 4; return true
		elseif string.sub(s, i, i + 4) == "false" then i += 5; return false
		elseif string.sub(s, i, i + 3) == "null" then i += 4; return nil
		else
			local num = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", i)
			if not num or num == "" then error("unexpected '" .. c .. "' at " .. i) end
			i += #num
			return tonumber(num) or error("bad number " .. num)
		end
	end
	local v = value()
	ws()
	if i <= #s then error("trailing characters at " .. i) end
	return v
end

-- loose encoder for the mock HttpService:JSONEncode (empty table -> [] like Roblox)
function JSON.encode(v)
	local t = type(v)
	if t == "string" then
		return '"' .. string.gsub(v, '[%c"\\]', function(c)
			local m = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
			return m[c] or string.format("\\u%04x", string.byte(c))
		end) .. '"'
	elseif t == "number" then return tostring(v)
	elseif t == "boolean" then return tostring(v)
	elseif v == nil then return "null"
	elseif t == "table" then
		local n = 0
		for _ in v do n += 1 end
		if n == #v then
			local parts = {}
			for _, x in ipairs(v) do table.insert(parts, JSON.encode(x)) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for k, x in v do table.insert(parts, JSON.encode(tostring(k)) .. ":" .. JSON.encode(x)) end
		table.sort(parts)
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("JSON.encode: cannot encode " .. t)
end

function deepEq(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in a do if not deepEq(v, b[k]) then return false end end
	for k in b do if a[k] == nil then return false end end
	return true
end

-- ---------------------------------------------------------------------------------------------
-- scheduler with a virtual clock (task.wait(s) advances it)
-- ---------------------------------------------------------------------------------------------
CLOCK = 1000
local MAIN = coroutine.running() -- the CLI's main thread cannot yield to the mock scheduler
local queue = {}
local function resume(co, ...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then table.insert(MOCK_ERRORS, "task error: " .. tostring(err)); print("TASK ERROR", err, debug.traceback(co)) end
end
WAITS = {}
task = {
	spawn = function(f, ...) local co = coroutine.create(f); resume(co, ...); return co end,
	defer = function(f, ...) local args = { ... }; table.insert(queue, function() resume(coroutine.create(f), table.unpack(args)) end) end,
	delay = function(_, f, ...) local args = { ... }; table.insert(queue, function() resume(coroutine.create(f), table.unpack(args)) end) end,
	wait = function(s)
		table.insert(WAITS, s or 0)
		CLOCK += (s and s > 0) and s or 0.03
		local co = coroutine.running()
		if co == MAIN or not coroutine.isyieldable() then return s or 0 end
		table.insert(queue, function() resume(co) end)
		coroutine.yield()
		return s or 0
	end,
}
function runQueue(maxSteps)
	local steps = 0
	while #queue > 0 and steps < (maxSteps or 400) do
		steps += 1
		local f = table.remove(queue, 1)
		f()
	end
	return steps
end
DateTime = { now = function() return { UnixTimestampMillis = CLOCK * 1000 } end }
warn = function(...) print("WARN", ...) end

-- ---------------------------------------------------------------------------------------------
-- data types
-- ---------------------------------------------------------------------------------------------
local TYPE = setmetatable({}, { __mode = "k" }) -- table -> Roblox type name
local realTypeof = typeof
typeof = function(v)
	if type(v) == "table" and TYPE[v] then return TYPE[v] end
	return realTypeof(v)
end
local function typed(t, name) TYPE[t] = name; return t end

local function vec2(x, y) return typed({ X = x or 0, Y = y or 0 }, "Vector2") end
Vector2 = { new = vec2, zero = vec2(0, 0) }
local V3MT = {}
V3MT.__index = V3MT
function V3MT.__eq(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
Vector3 = { new = function(x, y, z) return typed(setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3MT), "Vector3") end }
UDim = { new = function(s, o) return { Scale = s, Offset = o } end }
UDim2 = {
	new = function(a, b, c, d) return typed({ X = { Scale = a or 0, Offset = b or 0 }, Y = { Scale = c or 0, Offset = d or 0 } }, "UDim2") end,
	fromScale = function(a, b) return UDim2.new(a, 0, b, 0) end,
	fromOffset = function(a, b) return UDim2.new(0, a, 0, b) end,
}
local function color(r, g, b)
	local c = { R = r, G = g, B = b }
	function c.ToHex() return string.format("%02X%02X%02X", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5)) end
	return typed(c, "Color3")
end
Color3 = {
	new = function(r, g, b) return color(r or 0, g or 0, b or 0) end,
	fromRGB = function(r, g, b) return color((r or 0) / 255, (g or 0) / 255, (b or 0) / 255) end,
	fromHex = function(hex)
		hex = string.gsub(hex, "^#", "")
		if #hex == 3 then hex = string.gsub(hex, "(%x)", "%1%1") end
		assert(string.match(hex, "^%x%x%x%x%x%x$"), "Unable to convert characters to hex value")
		return Color3.fromRGB(tonumber(string.sub(hex, 1, 2), 16), tonumber(string.sub(hex, 3, 4), 16), tonumber(string.sub(hex, 5, 6), 16))
	end,
}
Font = { new = function(family, weight, style) return typed({ Family = family, Weight = weight, Style = style }, "Font") end }
local enumCache = {}
Enum = setmetatable({}, { __index = function(_, enumName)
	enumCache[enumName] = enumCache[enumName] or setmetatable({}, { __index = function(t, item)
		local e = typed({ Name = item, EnumType = enumName }, "EnumItem")
		rawset(t, item, e)
		return e
	end })
	return enumCache[enumName]
end })

-- ---------------------------------------------------------------------------------------------
-- signals and instances
-- ---------------------------------------------------------------------------------------------
function Signal()
	local s = { conns = {} }
	function s:Connect(f) local c = { f = f, Disconnect = function(c) c.dead = true end }; table.insert(self.conns, c); return c end
	function s:Fire(...) for _, c in self.conns do if not c.dead then resume(coroutine.create(c.f), ...) end end end
	return s
end

local GUI = { "Name", "Parent", "Size", "Position", "AnchorPoint", "BackgroundColor3", "BackgroundTransparency",
	"BorderSizePixel", "LayoutOrder", "AutomaticSize", "Visible", "ZIndex", "ClipsDescendants", "Active", "Rotation" }
local TEXT = { "Text", "Font", "FontFace", "TextSize", "TextColor3", "TextXAlignment", "TextYAlignment", "TextWrapped", "RichText",
	"TextTruncate", "LineHeight", "TextTransparency" }
local IMAGE = { "Image", "ImageColor3", "ImageTransparency", "ImageRectOffset", "ImageRectSize", "ScaleType", "ResampleMode" }
local function set(...) local t = {}; for _, list in { ... } do for _, k in list do t[k] = true end end; return t end
local GUIPROPS = {
	Frame = set(GUI),
	TextLabel = set(GUI, TEXT),
	TextButton = set(GUI, TEXT, { "AutoButtonColor" }),
	TextBox = set(GUI, TEXT, { "PlaceholderText", "PlaceholderColor3", "ClearTextOnFocus", "MultiLine", "TextEditable",
		"CursorPosition", "SelectionStart" }),
	ScrollingFrame = set(GUI, { "CanvasSize", "AutomaticCanvasSize", "ScrollBarThickness", "ScrollBarImageColor3",
		"ScrollingDirection", "VerticalScrollBarInset", "CanvasPosition" }),
	UICorner = set({ "Name", "Parent", "CornerRadius" }),
	UIStroke = set({ "Name", "Parent", "Color", "Thickness", "ApplyStrokeMode", "Transparency" }),
	ImageLabel = set(GUI, IMAGE),
	ImageButton = set(GUI, IMAGE, { "AutoButtonColor" }),
	UIGradient = set({ "Name", "Parent", "Color", "Transparency", "Rotation", "Offset" }),
	UIPadding = set({ "Name", "Parent", "PaddingTop", "PaddingRight", "PaddingBottom", "PaddingLeft" }),
	UIListLayout = set({ "Name", "Parent", "SortOrder", "Padding", "FillDirection", "VerticalAlignment",
		"HorizontalAlignment", "HorizontalFlex" }),
	UISizeConstraint = set({ "Name", "Parent", "MaxSize", "MinSize" }),
	UIGridLayout = set({ "Name", "Parent", "CellSize", "CellPadding", "SortOrder" }),
}
local GUIOBJ = { Frame = true, TextLabel = true, TextButton = true, TextBox = true, ScrollingFrame = true, ImageLabel = true,
	ImageButton = true }
local EVENTS = { MouseButton1Click = true, MouseEnter = true, MouseLeave = true, FocusLost = true, InputChanged = true,
	Focused = true, ChildAdded = true, DescendantAdded = true, DescendantRemoving = true, InputBegan = true, InputEnded = true,
	MouseButton1Down = true, MouseButton1Up = true }
SUPER = { Part = "BasePart", MeshPart = "BasePart", BasePart = "PVInstance", Model = "PVInstance", PVInstance = "Instance",
	Script = "BaseScript", LocalScript = "BaseScript", BaseScript = "LuaSourceContainer", ModuleScript = "LuaSourceContainer",
	LuaSourceContainer = "Instance", KeyframeSequence = "AnimationClip", AnimationClip = "Instance", ObjectValue = "ValueBase",
	StringValue = "ValueBase", ValueBase = "Instance", Workspace = "Model", TextButton = "GuiButton", GuiButton = "GuiObject",
	ImageButton = "GuiButton" }
for k in GUIOBJ do SUPER[k] = SUPER[k] or "GuiObject" end
SUPER.GuiObject = "Instance"

local Inst = {}
function Inst.new(class, props)
	local gui = GUIPROPS[class]
	local data = { ClassName = class, Name = class, children = {}, signals = {}, propSignals = {}, attributes = {},
		props = { AbsoluteSize = vec2(300, 20), AbsolutePosition = vec2(0, 0), AbsoluteCanvasSize = vec2(300, 600),
			AbsoluteContentSize = vec2(300, 100), CanvasPosition = vec2(0, 0) } }
	if gui then data.props.Text = "" end
	if class == "ModuleScript" and MODULE_SOURCE_ERROR then data.readonly = { Source = MODULE_SOURCE_ERROR } end
	local obj
	local methods = {}
	function methods:IsA(c)
		local k = class
		while k do
			if k == c then return true end
			k = SUPER[k] or (k ~= "Instance" and "Instance" or nil)
		end
		return false
	end
	function methods:GetChildren() local t = {}; for _, c in data.children do table.insert(t, c) end; return t end
	function methods:GetDescendants()
		local out = {}
		local function walk(n) for _, c in n.__data.children do table.insert(out, c); walk(c) end end
		walk(obj)
		return out
	end
	function methods:FindFirstChild(n) for _, c in data.children do if c.Name == n then return c end end; return nil end
	function methods:FindFirstChildOfClass(n) for _, c in data.children do if c.ClassName == n then return c end end; return nil end
	function methods:FindFirstAncestorWhichIsA(c)
		local p = data.parent
		while p do if p:IsA(c) then return p end; p = p.Parent end
		return nil
	end
	function methods:Destroy() if data.parent then obj.Parent = nil end; data.destroyed = true end
	function methods:GetPropertyChangedSignal(p)
		data.propSignals[p] = data.propSignals[p] or Signal()
		return data.propSignals[p]
	end
	function methods:CaptureFocus() data.focused = true end
	function methods:IsFocused() return data.focused == true end
	function methods:GetFullName()
		local names, n = {}, obj
		while n and n ~= game do table.insert(names, 1, n.Name); n = n.Parent end
		return table.concat(names, ".")
	end
	function methods:GetAttribute(k) return data.attributes[k] end
	function methods:SetAttribute(k, v) data.attributes[k] = v end
	function methods:GetAttributes() return table.clone(data.attributes) end
	function methods:GetPivot() return { Position = data.props.PivotPosition or Vector3.new(0, 0, 0) } end
	function methods:GetExtentsSize() return Vector3.new(4, 5, 1) end
	obj = setmetatable({}, {
		__index = function(_, k)
			if methods[k] then return methods[k] end
			if k == "ClassName" then return class end
			if k == "Name" then return data.Name end
			if k == "Parent" then return data.parent end
			if k == "__data" then return data end
			if EVENTS[k] then data.signals[k] = data.signals[k] or Signal(); return data.signals[k] end
			if data.props[k] ~= nil then return data.props[k] end
			if not gui then
				for _, c in data.children do if c.Name == k then return c end end
			end
			if gui then
				if gui[k] then return nil end
				fail("mock: " .. class .. " has no member " .. tostring(k))
			end
			if data.known and data.known[k] then return nil end
			error(tostring(k) .. " is not a valid member of " .. class, 2)
		end,
		__newindex = function(_, k, v)
			if gui and not gui[k] then fail("mock: cannot set " .. class .. "." .. tostring(k)) end
			if data.destroyed and k == "Parent" and v ~= nil then fail("mock: reparenting destroyed " .. class) end
			if data.readonly and data.readonly[k] then error(data.readonly[k], 2) end
			if k == "Parent" then
				if data.parent then
					local siblings = data.parent.__data.children
					for i, c in siblings do if c == obj then table.remove(siblings, i); break end end
				end
				data.parent = v
				if v then table.insert(v.__data.children, obj) end
			elseif k == "Name" then
				data.Name = v
			else
				data.props[k] = v
				if data.propSignals[k] then data.propSignals[k]:Fire() end
			end
		end,
	})
	typed(obj, "Instance")
	for k, v in props or {} do
		if k == "Parent" then obj.Parent = v elseif k == "Name" then obj.Name = v else data.props[k] = v end
	end
	return obj
end
Instance = Inst

function findAll(root, pred, out)
	out = out or {}
	for _, c in root.__data.children do
		if pred(c) then table.insert(out, c) end
		findAll(c, pred, out)
	end
	return out
end
function findText(root, text)
	return findAll(root, function(c) return c.__data.props.Text ~= nil and string.find(c.__data.props.Text, text, 1, true) ~= nil end)
end
function click(btn) assert(btn, "click: no button"); btn.MouseButton1Click:Fire() end

-- ---------------------------------------------------------------------------------------------
-- the DataModel and services
-- ---------------------------------------------------------------------------------------------
Http = { queue = {}, sent = {}, encoded = nil }
function Http:JSONEncode(t) self.encoded = t; return JSON.encode(t) end
function Http:JSONDecode(s) return JSON.decode(s) end
function Http:RequestAsync(req)
	table.insert(self.sent, req)
	local nxt = table.remove(self.queue, 1)
	if type(nxt) == "function" then nxt = nxt(req) end
	if type(nxt) == "string" then error(nxt) end
	return nxt or { StatusCode = 500, Body = '{"type":"error","error":{"type":"api_error","message":"queue empty"}}', Headers = {} }
end
SELECTION = {}
local Selection = { Get = function() return table.clone(SELECTION) end, Set = function(_, list) SELECTION = table.clone(list) end }
CHS = { log = {}, n = 0 }
function CHS:TryBeginRecording(name)
	if self.active then return nil end
	self.n += 1
	self.active = "rec" .. self.n
	table.insert(self.log, "begin " .. name)
	return self.active
end
function CHS:FinishRecording(id, op)
	assert(id == self.active, "finish of a recording that is not active")
	self.active = nil
	table.insert(self.log, "finish " .. op.Name)
end
CHS.OnUndo = Signal()
CHS.OnRedo = Signal()
LogService = { MessageOut = Signal() }
local services = {
	HttpService = Http,
	Selection = Selection,
	ChangeHistoryService = CHS,
	LogService = LogService,
	UserInputService = { IsKeyDown = function() return false end },
	CollectionService = { GetTags = function(_, inst) return inst.__data.tags or {} end },
	ScriptEditorService = { GetEditorSource = function(_, s) return s.__data.props.Source end },
}
game = Inst.new("DataModel")
game.Name = "Game"
for _, name in { "Workspace", "ReplicatedStorage", "ServerScriptService", "ServerStorage", "StarterGui", "StarterPack",
	"StarterPlayer", "Lighting", "SoundService" } do
	local s = Inst.new(name == "Workspace" and "Workspace" or "Folder")
	s.Name = name
	s.Parent = game
	services[name] = s
end
workspace = services.Workspace
game.__data.props.GetService = function(_, n) return services[n] or error("no service " .. n) end
game.__data.props.FindService = function(_, n) return services[n] end

-- ---------------------------------------------------------------------------------------------
-- module loader: the suite creates TREE (LC.modtree, the real sources); MOCKS[name] = table replaces a module;
-- require(ModuleScript instance) compiles the Source of an instance made inside the mock DataModel
-- ---------------------------------------------------------------------------------------------
MOCKS = {}
function reqInstance(ref)
	local fn, err = loadstring(ref.Source, "=" .. ref.Name)
	if not fn then
		LogService.MessageOut:Fire(ref.Name .. ":" .. tostring(err), Enum.MessageType.MessageError)
		error("Requested module experienced an error while loading", 2)
	end
	setfenv(fn, setmetatable({ script = ref }, { __index = getfenv(1) }))
	return fn()
end
function load(name) -- "AnalyzerReal" = the real Analyzer, loaded before the test replaces MOCKS.Analyzer by a fake
	return TREE.load((string.gsub(name, "Real$", "")))
end
function require(ref)
	if typeof(ref) == "Instance" and ref.ClassName == "ModuleScript" then
		return reqInstance(ref)
	end
	return TREE.require(ref)
end

-- checks
PASS, FAIL = 0, 0
function check(name, cond, detail)
	if cond then PASS += 1 else FAIL += 1; print("FAIL " .. name .. (detail and ("\n   " .. tostring(detail)) or "")) end
end
function has(s, sub) return type(s) == "string" and string.find(s, sub, 1, true) ~= nil end
