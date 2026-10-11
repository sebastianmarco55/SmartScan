-- LostCube preview: a lenient Roblox GUI mock that records everything the plugin does to its GUI instances, a virtual
-- scheduler, Studio theme / settings() / StudioService mocks and a JSON dump of the resulting GUI tree.
-- It is NOT a test mock (nothing is validated: an unknown property is just stored); render.py turns the dump into HTML.
--
--   local P = LC.run("tests/preview/gui.luau", nil, LC, ARGS)
--   P.install(env, { enumMerge = baseEnum })   -- adds Instance (GUI classes), UDim2, Color3, Enum, Font, task, settings ...
--   P.newRoot(width, height)                   -- the widget the App is mounted in
--   P.drain()  P.click("text")  P.dump(root)   -- run deferred tasks / click a button by its text / the JSON string
-- ARGS: { theme, width, height, measure = { [id] = { x, y, w, h, cw, ch, tw, th } } } (see render.py)
local LC, ARGS = ...
ARGS = ARGS or {}
local P = { warnings = {}, errors = {}, measureReads = 0 }
local MEASURE = ARGS.measure or {}

local function warnOnce(key, msg)
	if not P.warnings[key] then
		P.warnings[key] = msg
	end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- datatypes: userdata like in Roblox (type(v) == "userdata"), a `__type` in the metatable for typeof
-- ---------------------------------------------------------------------------------------------------------------------
local D = {}
local DATA = setmetatable({}, { __mode = "k" })
local function make(mt, fields)
	local o = newproxy(true)
	local m = getmetatable(o)
	for k, v in mt do
		m[k] = v
	end
	DATA[o] = fields
	return o
end
-- a datatype: `methods` (name -> function) and `computed` (name -> function(self) for derived members)
local function datatype(name, methods, computed)
	local mt = { __type = name }
	mt.__index = function(self, k)
		local d = DATA[self]
		local v = d[k]
		if v ~= nil then
			return v
		end
		if computed and computed[k] then
			return computed[k](d)
		end
		return methods[k]
	end
	mt.__newindex = function(_, k)
		error("Unable to assign property " .. tostring(k) .. " of " .. name .. ": it is read only", 2)
	end
	return mt
end

-- Vector2 --
local V2M = {}
local V2MT = datatype("Vector2", V2M, {
	Magnitude = function(d) return math.sqrt(d.X * d.X + d.Y * d.Y) end,
})
local function v2(x, y)
	return make(V2MT, { X = x or 0, Y = y or 0 })
end
V2MT.__index = (function(base)
	return function(self, k)
		if k == "Unit" then
			local d = DATA[self]
			local m = math.sqrt(d.X * d.X + d.Y * d.Y)
			return m == 0 and v2(0, 0) or v2(d.X / m, d.Y / m)
		end
		return base(self, k)
	end
end)(V2MT.__index)
V2M.Dot = function(a, b) return a.X * b.X + a.Y * b.Y end
V2M.Lerp = function(a, b, t) return v2(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t) end
V2MT.__add = function(a, b) return v2(a.X + b.X, a.Y + b.Y) end
V2MT.__sub = function(a, b) return v2(a.X - b.X, a.Y - b.Y) end
V2MT.__mul = function(a, b)
	if type(a) == "number" then return v2(a * b.X, a * b.Y) end
	if type(b) == "number" then return v2(a.X * b, a.Y * b) end
	return v2(a.X * b.X, a.Y * b.Y)
end
V2MT.__div = function(a, b)
	if type(b) == "number" then return v2(a.X / b, a.Y / b) end
	return v2(a.X / b.X, a.Y / b.Y)
end
V2MT.__unm = function(a) return v2(-a.X, -a.Y) end
V2MT.__eq = function(a, b) return a.X == b.X and a.Y == b.Y end
V2MT.__tostring = function(a) return string.format("%g, %g", a.X, a.Y) end
D.Vector2 = { new = v2, zero = v2(0, 0), one = v2(1, 1), xAxis = v2(1, 0), yAxis = v2(0, 1) }

-- UDim / UDim2 --
local UDMT = datatype("UDim", {})
local function ud(s, o)
	return make(UDMT, { Scale = s or 0, Offset = o or 0 })
end
UDMT.__add = function(a, b) return ud(a.Scale + b.Scale, a.Offset + b.Offset) end
UDMT.__sub = function(a, b) return ud(a.Scale - b.Scale, a.Offset - b.Offset) end
UDMT.__eq = function(a, b) return a.Scale == b.Scale and a.Offset == b.Offset end
UDMT.__tostring = function(a) return string.format("%g, %g", a.Scale, a.Offset) end
D.UDim = { new = ud }

local UD2M = {}
local UD2MT = datatype("UDim2", UD2M)
local function ud2(xs, xo, ys, yo)
	if type(xs) == "userdata" then -- UDim2.new(UDim, UDim)
		return make(UD2MT, { X = xs, Y = xo, Width = xs, Height = xo })
	end
	local x, y = ud(xs, xo), ud(ys, yo)
	return make(UD2MT, { X = x, Y = y, Width = x, Height = y })
end
UD2M.Lerp = function(a, b, t)
	return ud2(a.X.Scale + (b.X.Scale - a.X.Scale) * t, a.X.Offset + (b.X.Offset - a.X.Offset) * t,
		a.Y.Scale + (b.Y.Scale - a.Y.Scale) * t, a.Y.Offset + (b.Y.Offset - a.Y.Offset) * t)
end
UD2MT.__add = function(a, b) return ud2(a.X.Scale + b.X.Scale, a.X.Offset + b.X.Offset, a.Y.Scale + b.Y.Scale, a.Y.Offset + b.Y.Offset) end
UD2MT.__sub = function(a, b) return ud2(a.X.Scale - b.X.Scale, a.X.Offset - b.X.Offset, a.Y.Scale - b.Y.Scale, a.Y.Offset - b.Y.Offset) end
UD2MT.__eq = function(a, b) return a.X == b.X and a.Y == b.Y end
UD2MT.__tostring = function(a) return string.format("{%g, %g}, {%g, %g}", a.X.Scale, a.X.Offset, a.Y.Scale, a.Y.Offset) end
D.UDim2 = {
	new = ud2,
	fromScale = function(x, y) return ud2(x, 0, y, 0) end,
	fromOffset = function(x, y) return ud2(0, x, 0, y) end,
}

-- Color3 --
local C3M = {}
local C3MT = datatype("Color3", C3M)
local function c3(r, g, b)
	return make(C3MT, { R = r, G = g, B = b })
end
local function clamp01(x) return math.max(0, math.min(1, x)) end
local function byte(x) return math.floor(clamp01(x) * 255 + 0.5) end
C3M.ToHex = function(c) return string.format("%02x%02x%02x", byte(c.R), byte(c.G), byte(c.B)) end
C3M.Lerp = function(a, b, t) return c3(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t) end
C3M.ToHSV = function(c)
	local r, g, b = c.R, c.G, c.B
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	local d = mx - mn
	local h = 0
	if d > 0 then
		if mx == r then h = ((g - b) / d) % 6 elseif mx == g then h = (b - r) / d + 2 else h = (r - g) / d + 4 end
		h = h / 6
	end
	return h, mx == 0 and 0 or d / mx, mx
end
C3MT.__eq = function(a, b) return a.R == b.R and a.G == b.G and a.B == b.B end
C3MT.__tostring = function(a) return string.format("%g, %g, %g", a.R, a.G, a.B) end
local function hsv(h, s, v)
	h = h % 1
	local i = math.floor(h * 6)
	local f = h * 6 - i
	local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	i = i % 6
	if i == 0 then return c3(v, t, p) elseif i == 1 then return c3(q, v, p) elseif i == 2 then return c3(p, v, t)
	elseif i == 3 then return c3(p, q, v) elseif i == 4 then return c3(t, p, v) else return c3(v, p, q) end
end
D.Color3 = {
	new = function(r, g, b) return c3(r or 0, g or 0, b or 0) end,
	fromRGB = function(r, g, b) return c3((r or 0) / 255, (g or 0) / 255, (b or 0) / 255) end,
	fromHSV = hsv,
	fromHex = function(hex)
		hex = string.gsub(hex, "^#", "")
		if #hex == 3 then
			hex = string.gsub(hex, ".", function(c) return c .. c end)
		end
		assert(#hex == 6 and tonumber(hex, 16), "bad hex " .. hex)
		return c3(tonumber(string.sub(hex, 1, 2), 16) / 255, tonumber(string.sub(hex, 3, 4), 16) / 255, tonumber(string.sub(hex, 5, 6), 16) / 255)
	end,
}

-- Rect --
local RMT = datatype("Rect", {})
D.Rect = { new = function(a, b, c, d)
	local x0, y0, x1, y1 = a, b, c, d
	if type(a) == "userdata" then
		x0, y0, x1, y1 = a.X, a.Y, b.X, b.Y
	end
	return make(RMT, { Min = v2(x0, y0), Max = v2(x1, y1), Width = x1 - x0, Height = y1 - y0 })
end }

-- sequences (the typed base mock has its own; these are used when it has none)
local NSKMT = datatype("NumberSequenceKeypoint", {})
local NSMT = datatype("NumberSequence", {})
D.NumberSequenceKeypoint = { new = function(t, v, e) return make(NSKMT, { Time = t, Value = v, Envelope = e or 0 }) end }
D.NumberSequence = { new = function(a, b)
	local points
	if type(a) == "table" then points = a
	elseif b then points = { D.NumberSequenceKeypoint.new(0, a), D.NumberSequenceKeypoint.new(1, b) }
	else points = { D.NumberSequenceKeypoint.new(0, a), D.NumberSequenceKeypoint.new(1, a) } end
	return make(NSMT, { Keypoints = points })
end }
local CSKMT = datatype("ColorSequenceKeypoint", {})
local CSMT = datatype("ColorSequence", {})
D.ColorSequenceKeypoint = { new = function(t, c) return make(CSKMT, { Time = t, Value = c }) end }
D.ColorSequence = { new = function(a, b)
	local points
	if type(a) == "table" then points = a
	elseif b then points = { D.ColorSequenceKeypoint.new(0, a), D.ColorSequenceKeypoint.new(1, b) }
	else points = { D.ColorSequenceKeypoint.new(0, a), D.ColorSequenceKeypoint.new(1, a) } end
	return make(CSMT, { Keypoints = points })
end }
local NRMT = datatype("NumberRange", {})
D.NumberRange = { new = function(a, b) return make(NRMT, { Min = a, Max = b or a }) end }

-- ---------------------------------------------------------------------------------------------------------------------
-- Enum (any member exists; items are cached so == works) and Font
-- ---------------------------------------------------------------------------------------------------------------------
local EnumItemMT = datatype("EnumItem", {})
EnumItemMT.__tostring = function(e) return "Enum." .. e.EnumName .. "." .. e.Name end
local ENUM_VALUES = { -- the few enums whose numbers matter
	FontWeight = { Thin = 100, ExtraLight = 200, Light = 300, Regular = 400, Medium = 500, SemiBold = 600, Bold = 700, ExtraBold = 800, Heavy = 900 },
}
local enums = {}
local function enumOf(name)
	if enums[name] then
		return enums[name]
	end
	local items = {}
	local enum = setmetatable({}, { __index = function(_, item)
		if type(item) ~= "string" then
			return nil
		end
		if not items[item] then
			items[item] = make(EnumItemMT, { Name = item, EnumName = name, EnumType = name, Value = (ENUM_VALUES[name] or {})[item] or 0 })
		end
		return items[item]
	end, __type = "Enum" })
	enums[name] = enum
	return enum
end
D.Enum = setmetatable({}, { __index = function(_, name)
	return enumOf(name)
end })
local Enum = D.Enum

-- legacy Enum.Font -> (family file, weight)
local LEGACY = {
	BuilderSans = { "BuilderSans", "Regular" }, BuilderSansMedium = { "BuilderSans", "Medium" },
	BuilderSansBold = { "BuilderSans", "Bold" }, BuilderSansExtraBold = { "BuilderSans", "ExtraBold" },
	SourceSans = { "SourceSansPro", "Regular" }, SourceSansBold = { "SourceSansPro", "Bold" },
	SourceSansLight = { "SourceSansPro", "Light" }, SourceSansSemibold = { "SourceSansPro", "SemiBold" },
	Gotham = { "GothamSSm", "Regular" }, GothamMedium = { "GothamSSm", "Medium" }, GothamBold = { "GothamSSm", "Bold" },
	GothamBlack = { "GothamSSm", "Heavy" }, Arial = { "Arimo", "Regular" }, ArialBold = { "Arimo", "Bold" },
	Arimo = { "Arimo", "Regular" }, ArimoBold = { "Arimo", "Bold" }, Code = { "RobotoMono", "Regular" },
	RobotoMono = { "RobotoMono", "Regular" }, Roboto = { "Roboto", "Regular" },
}
local FontMT = datatype("Font", {})
local function fontNew(family, weight, style)
	weight = weight or Enum.FontWeight.Regular
	style = style or Enum.FontStyle.Normal
	return make(FontMT, { Family = family, Weight = weight, Style = style, Bold = weight.Value >= 700 })
end
FontMT.__eq = function(a, b) return a.Family == b.Family and a.Weight == b.Weight and a.Style == b.Style end
local FONT_PREFIX = "rbxasset://fonts/families/"
D.Font = {
	new = fontNew,
	fromName = function(name, weight, style) return fontNew(FONT_PREFIX .. name .. ".json", weight, style) end,
	fromId = function(id, weight, style) return fontNew("rbxassetid://" .. tostring(id), weight, style) end,
	fromEnum = function(item)
		local entry = LEGACY[item.Name] or { item.Name, "Regular" }
		return fontNew(FONT_PREFIX .. entry[1] .. ".json", Enum.FontWeight[entry[2]], Enum.FontStyle.Normal)
	end,
}

P.datatypes = D

-- ---------------------------------------------------------------------------------------------------------------------
-- the virtual scheduler
-- ---------------------------------------------------------------------------------------------------------------------
local clock = 0
local queue = {}
local seq = 0
local function schedule(at, fn, co)
	seq += 1
	table.insert(queue, { at = at, n = seq, fn = fn, co = co })
end
local function resume(co, ...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		table.insert(P.errors, tostring(err))
	end
	return ok
end
local scheduler = {}
function scheduler.spawn(f, ...)
	local co = type(f) == "thread" and f or coroutine.create(f)
	resume(co, ...)
	return co
end
function scheduler.defer(f, ...)
	local args = table.pack(...)
	local co = type(f) == "thread" and f or coroutine.create(f)
	schedule(clock, function() resume(co, table.unpack(args, 1, args.n)) end, co)
	return co
end
function scheduler.delay(t, f, ...)
	local args = table.pack(...)
	local co = type(f) == "thread" and f or coroutine.create(f)
	schedule(clock + (t or 0), function() resume(co, table.unpack(args, 1, args.n)) end, co)
	return co
end
function scheduler.wait(t)
	if not coroutine.isyieldable() then
		clock += t or 0.03
		return t or 0.03
	end
	local co = coroutine.running()
	schedule(clock + (t or 0.03), function() resume(co, t or 0.03) end, co)
	return coroutine.yield()
end
function scheduler.cancel(co)
	for i = #queue, 1, -1 do
		if queue[i].co == co then
			table.remove(queue, i)
		end
	end
	if type(co) == "thread" and coroutine.status(co) ~= "running" then
		pcall(coroutine.close, co)
	end
end
function scheduler.synchronize() end
function scheduler.desynchronize() end
P.task = scheduler

-- runs everything that is due within `seconds` of virtual time (default 3), the earliest first
function P.drain(seconds)
	local limit = clock + (seconds or 10)
	local steps = 0
	while #queue > 0 and steps < 50000 do
		table.sort(queue, function(a, b)
			if a.at ~= b.at then return a.at < b.at end
			return a.n < b.n
		end)
		local item = queue[1]
		if item.at > limit then
			break
		end
		table.remove(queue, 1)
		if item.at > clock then
			clock = item.at
		end
		steps += 1
		item.fn()
	end
	if #queue == 0 or queue[1].at > limit then
		clock = math.max(clock, limit)
	end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- signals
-- ---------------------------------------------------------------------------------------------------------------------
local SignalMT = { __type = "RBXScriptSignal" }
SignalMT.__index = SignalMT
local ConnMT = { __type = "RBXScriptConnection" }
ConnMT.__index = ConnMT
function ConnMT.Disconnect(c)
	c.Connected = false
	local list = c._list
	for i, x in list do
		if x == c then
			table.remove(list, i)
			break
		end
	end
end
local function newSignal()
	return setmetatable({ _conns = {}, _waiters = {} }, SignalMT)
end
function SignalMT.Connect(sig, fn)
	local c = setmetatable({ Connected = true, _fn = fn, _list = sig._conns }, ConnMT)
	table.insert(sig._conns, c)
	return c
end
SignalMT.connect = SignalMT.Connect
function SignalMT.Once(sig, fn)
	local c
	c = sig:Connect(function(...)
		c:Disconnect()
		fn(...)
	end)
	return c
end
function SignalMT.Wait(sig)
	local co = coroutine.running()
	table.insert(sig._waiters, co)
	return coroutine.yield()
end
function SignalMT.Fire(sig, ...)
	for _, c in table.clone(sig._conns) do
		if c.Connected then
			local co = coroutine.create(c._fn)
			resume(co, ...)
		end
	end
	for _, co in sig._waiters do
		resume(co, ...)
	end
	sig._waiters = {}
end
P.newSignal = newSignal

-- ---------------------------------------------------------------------------------------------------------------------
-- classes
-- ---------------------------------------------------------------------------------------------------------------------
local OBJ = { "GuiObject", "GuiBase2d" }
local CLASSES = {
	Frame = OBJ, TextLabel = OBJ, TextBox = OBJ, ImageLabel = OBJ, ScrollingFrame = OBJ, CanvasGroup = OBJ, ViewportFrame = OBJ,
	VideoFrame = OBJ, TextButton = { "GuiObject", "GuiButton", "GuiBase2d" }, ImageButton = { "GuiObject", "GuiButton", "GuiBase2d" },
	ScreenGui = { "LayerCollector", "GuiBase2d" }, SurfaceGui = { "LayerCollector", "GuiBase2d" },
	BillboardGui = { "LayerCollector", "GuiBase2d" }, DockWidgetPluginGui = { "PluginGui", "LayerCollector", "GuiBase2d" },
	UIListLayout = { "UIGridStyleLayout", "UILayout", "UIComponent" }, UIGridLayout = { "UIGridStyleLayout", "UILayout", "UIComponent" },
	UIPageLayout = { "UIGridStyleLayout", "UILayout", "UIComponent" }, UITableLayout = { "UIGridStyleLayout", "UILayout", "UIComponent" },
	UISizeConstraint = { "UIConstraint", "UIComponent" }, UIAspectRatioConstraint = { "UIConstraint", "UIComponent" },
	UITextSizeConstraint = { "UIConstraint", "UIComponent" },
}
local function isGuiClass(class)
	return CLASSES[class] ~= nil or string.sub(class, 1, 2) == "UI"
end
P.isGuiClass = isGuiClass

local TEXTY = { TextLabel = true, TextButton = true, TextBox = true }
local IMAGEY = { ImageLabel = true, ImageButton = true }
local function defaultsFor(class)
	local d = {}
	if CLASSES[class] and (CLASSES[class][1] == "GuiObject") then
		d.Position, d.Size, d.AnchorPoint = ud2(0, 0, 0, 0), ud2(0, 0, 0, 0), v2(0, 0)
		d.Visible, d.ZIndex, d.LayoutOrder, d.Rotation = true, 1, 0, 0
		d.BackgroundColor3, d.BackgroundTransparency = c3(163 / 255, 162 / 255, 165 / 255), 0
		d.BorderColor3, d.BorderSizePixel, d.BorderMode = c3(27 / 255, 42 / 255, 53 / 255), 1, Enum.BorderMode.Outline
		d.ClipsDescendants, d.Active, d.Selectable = false, false, true
		d.AutomaticSize, d.SizeConstraint = Enum.AutomaticSize.None, Enum.SizeConstraint.RelativeXY
	end
	if TEXTY[class] then
		d.Text = class == "TextLabel" and "Label" or (class == "TextButton" and "Button" or "")
		d.TextSize, d.TextColor3, d.TextTransparency = 14, c3(27 / 255, 27 / 255, 27 / 255), 0
		d.Font, d.TextXAlignment, d.TextYAlignment = Enum.Font.SourceSans, Enum.TextXAlignment.Center, Enum.TextYAlignment.Center
		d.TextWrapped, d.RichText, d.TextScaled, d.LineHeight = false, false, false, 1
		d.TextTruncate, d.TextStrokeTransparency, d.TextStrokeColor3 = Enum.TextTruncate.None, 1, c3(0, 0, 0)
		d.TextBounds, d.TextFits = v2(0, 0), true
		d.MaxVisibleGraphemes = -1
		d.FontFace = nil
	end
	if class == "TextBox" then
		d.PlaceholderText, d.PlaceholderColor3 = "", c3(178 / 255, 178 / 255, 178 / 255)
		d.MultiLine, d.TextEditable, d.ClearTextOnFocus, d.ShowNativeInput = false, true, true, true
		d.CursorPosition, d.SelectionStart = -1, -1
	end
	if class == "TextButton" or class == "ImageButton" then
		d.AutoButtonColor, d.Modal, d.Selected = true, false, false
	end
	if IMAGEY[class] then
		d.Image, d.ImageColor3, d.ImageTransparency = "", c3(1, 1, 1), 0
		d.ScaleType, d.ImageRectOffset, d.ImageRectSize = Enum.ScaleType.Stretch, v2(0, 0), v2(0, 0)
	end
	if class == "ScrollingFrame" then
		d.CanvasSize, d.CanvasPosition = ud2(0, 0, 2, 0), v2(0, 0)
		d.ScrollBarThickness, d.ScrollingEnabled = 12, true
		d.AutomaticCanvasSize, d.ScrollingDirection = Enum.AutomaticSize.None, Enum.ScrollingDirection.XY
		d.ScrollBarImageColor3, d.ScrollBarImageTransparency = c3(0, 0, 0), 0
		d.VerticalScrollBarInset, d.HorizontalScrollBarInset = Enum.ScrollBarInset.None, Enum.ScrollBarInset.None
		d.VerticalScrollBarPosition = Enum.VerticalScrollBarPosition.Right
	end
	if class == "UICorner" then d.CornerRadius = ud(0, 8) end
	if class == "UIStroke" then
		d.Color, d.Thickness, d.Transparency, d.Enabled = c3(0, 0, 0), 1, 0, true
		d.ApplyStrokeMode, d.LineJoinMode = Enum.ApplyStrokeMode.Contextual, Enum.LineJoinMode.Round
	end
	if class == "UIPadding" then
		d.PaddingTop, d.PaddingRight, d.PaddingBottom, d.PaddingLeft = ud(0, 0), ud(0, 0), ud(0, 0), ud(0, 0)
	end
	if class == "UIListLayout" or class == "UIGridLayout" then
		d.FillDirection, d.SortOrder = Enum.FillDirection.Vertical, Enum.SortOrder.LayoutOrder
		d.HorizontalAlignment, d.VerticalAlignment = Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top
		d.Padding = ud(0, 0)
	end
	if class == "UIGridLayout" then
		d.CellSize, d.CellPadding, d.StartCorner = ud2(0, 100, 0, 100), ud2(0, 5, 0, 5), Enum.StartCorner.TopLeft
		d.FillDirection = Enum.FillDirection.Horizontal
	end
	return d
end

-- names that are signals, not properties
local EVENTS = {}
for name in string.gmatch([[MouseButton1Click MouseButton1Down MouseButton1Up MouseButton2Click MouseButton2Down MouseButton2Up
	MouseEnter MouseLeave MouseMoved MouseWheelForward MouseWheelBackward InputBegan InputChanged InputEnded FocusLost Focused
	ReturnPressedFromOnScreenKeyboard Activated TouchTap TouchLongPress TouchSwipe TouchPan TouchPinch TouchRotate SelectionGained
	SelectionLost ChildAdded ChildRemoved DescendantAdded DescendantRemoving Destroying AncestryChanged Changed
	AttributeChanged Heartbeat]], "%S+") do
	EVENTS[name] = true
end

local PARENT_ABS_ROOT = { w = 360, h = 900 }

-- ---------------------------------------------------------------------------------------------------------------------
-- instances
-- ---------------------------------------------------------------------------------------------------------------------
local methods = {}
local InstMT = { __type = "Instance" }
local nextId = 0
local ALL = setmetatable({}, { __mode = "v" })

local function dataOf(o) return DATA[o] end

local function fireChange(d, name)
	local sig = d.propSignals[name]
	if sig then
		sig:Fire()
	end
end

local function measureOf(d)
	local m = MEASURE[tostring(d.id)]
	if m and m.c == d.class then
		return m
	end
	return nil
end

-- estimate of the absolute rectangle when the browser has not measured it yet (first pass): sizes resolved against the
-- parent's, list layouts / padding / anchors ignored
local function guessRect(o)
	local d = dataOf(o)
	local parent = d.parent
	local px, py, pw, ph = 0, 0, PARENT_ABS_ROOT.w, PARENT_ABS_ROOT.h
	if parent and isGuiClass(parent.ClassName) then
		local pr = guessRect(parent)
		px, py, pw, ph = pr[1], pr[2], pr[3], pr[4]
	end
	local size = d.props.Size or (d.defaults and d.defaults.Size)
	local pos = d.props.Position or (d.defaults and d.defaults.Position)
	local w, h, x, y = pw, ph, px, py
	if size then
		w, h = size.X.Scale * pw + size.X.Offset, size.Y.Scale * ph + size.Y.Offset
	end
	if pos then
		x, y = px + pos.X.Scale * pw + pos.X.Offset, py + pos.Y.Scale * ph + pos.Y.Offset
	end
	return { x, y, math.max(0, w), math.max(0, h) }
end

local function dataMembers(o, d, k)
	-- computed read-only members
	if k == "AbsoluteSize" or k == "AbsolutePosition" or k == "AbsoluteContentSize" or k == "AbsoluteCanvasSize"
		or k == "AbsoluteWindowSize" or k == "TextBounds" or k == "AbsoluteRotation" then
		if k == "AbsoluteRotation" then
			return d.props.Rotation or 0
		end
		P.measureReads += 1 -- the code depends on the layout: render.py iterates until the numbers settle
		if k == "AbsoluteContentSize" then -- a layout: the content of its parent
			local pd = d.parent and dataOf(d.parent)
			local m = pd and measureOf(pd)
			if m and m.cw then
				return v2(m.cw, m.ch)
			end
			return v2(0, 0)
		end
		local m = measureOf(d)
		if k == "TextBounds" then
			if m and m.tw then
				return v2(m.tw, m.th)
			end
			local text = d.props.Text or ""
			local size = d.props.TextSize or 14
			local lines = 1
			for _ in string.gmatch(text, "\n") do lines += 1 end
			return v2(utf8.len(text) and utf8.len(text) * size * 0.55 or #text * size * 0.55, lines * size * 1.26)
		end
		if k == "AbsoluteCanvasSize" then
			if m and m.cvw then
				return v2(m.cvw, m.cvh)
			end
			local r = guessRect(o)
			return v2(r[3], r[4])
		end
		if k == "AbsoluteWindowSize" then
			local r = m and { m.x, m.y, m.w, m.h } or guessRect(o)
			return v2(r[3], r[4])
		end
		if m then
			if k == "AbsoluteSize" then return v2(m.w, m.h) end
			return v2(m.x, m.y)
		end
		local r = guessRect(o)
		if k == "AbsoluteSize" then return v2(r[3], r[4]) end
		return v2(r[1], r[2])
	end
	return nil
end

InstMT.__index = function(o, k)
	local m = methods[k]
	if m then
		return m
	end
	local d = dataOf(o)
	if k == "ClassName" then return d.class end
	if k == "Name" then return d.name end
	if k == "Parent" then return d.parent end
	local v = d.props[k]
	if v ~= nil then
		return v
	end
	local computed = dataMembers(o, d, k)
	if computed ~= nil then
		return computed
	end
	if EVENTS[k] then
		local sig = d.signals[k]
		if not sig then
			sig = newSignal()
			d.signals[k] = sig
		end
		return sig
	end
	local default = d.defaults[k]
	if default ~= nil then
		return default
	end
	for _, c in d.children do
		if dataOf(c).name == k then
			return c
		end
	end
	warnOnce(d.class .. "." .. tostring(k), "read of unknown member " .. d.class .. "." .. tostring(k))
	return nil
end

local function detach(o, d)
	local old = d.parent
	if old then
		local list = dataOf(old).children
		for i, c in list do
			if c == o then
				table.remove(list, i)
				break
			end
		end
		local od = dataOf(old)
		if od.signals.ChildRemoved then od.signals.ChildRemoved:Fire(o) end
		d.parent = nil
	end
end

InstMT.__newindex = function(o, k, v)
	local d = dataOf(o)
	if k == "Parent" then
		if d.parent == v then
			return
		end
		detach(o, d)
		d.parent = v
		if v ~= nil then
			table.insert(dataOf(v).children, o)
			local pd = dataOf(v)
			if pd.signals.ChildAdded then pd.signals.ChildAdded:Fire(o) end
		end
		fireChange(d, "Parent")
		return
	end
	if k == "Name" then
		d.name = v
		fireChange(d, "Name")
		return
	end
	if k == "ClassName" then
		error("ClassName is read-only", 2)
	end
	local old = d.props[k]
	d.props[k] = v
	if old ~= v then
		fireChange(d, k)
	end
end
InstMT.__tostring = function(o) return dataOf(o).name end

local function newGui(class)
	nextId += 1
	local d = { class = class, name = class, id = nextId, props = {}, children = {}, signals = {}, propSignals = {},
		attrs = {}, attrSignals = {}, defaults = defaultsFor(class) }
	local o = make(InstMT, nil)
	DATA[o] = d
	ALL[nextId] = o
	return o
end

function methods.IsA(o, class)
	local d = dataOf(o)
	if class == d.class or class == "Instance" then return true end
	for _, b in CLASSES[d.class] or { "GuiComponent" } do
		if b == class then return true end
	end
	return false
end
function methods.GetChildren(o) return table.clone(dataOf(o).children) end
function methods.GetDescendants(o)
	local out = {}
	local function walk(x)
		for _, c in dataOf(x).children do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(o)
	return out
end
function methods.FindFirstChild(o, name, recursive)
	for _, c in dataOf(o).children do
		if dataOf(c).name == name then return c end
	end
	if recursive then
		for _, c in dataOf(o).children do
			local f = methods.FindFirstChild(c, name, true)
			if f then return f end
		end
	end
	return nil
end
methods.WaitForChild = function(o, name) return methods.FindFirstChild(o, name) end
function methods.FindFirstChildOfClass(o, class)
	for _, c in dataOf(o).children do
		if dataOf(c).class == class then return c end
	end
	return nil
end
function methods.FindFirstChildWhichIsA(o, class)
	for _, c in dataOf(o).children do
		if methods.IsA(c, class) then return c end
	end
	return nil
end
function methods.FindFirstAncestor(o, name)
	local p = dataOf(o).parent
	while p do
		if dataOf(p).name == name then return p end
		p = dataOf(p).parent
	end
	return nil
end
function methods.FindFirstAncestorOfClass(o, class)
	local p = dataOf(o).parent
	while p do
		if dataOf(p).class == class then return p end
		p = dataOf(p).parent
	end
	return nil
end
function methods.FindFirstAncestorWhichIsA(o, class)
	local p = dataOf(o).parent
	while p do
		if methods.IsA(p, class) then return p end
		p = dataOf(p).parent
	end
	return nil
end
function methods.IsDescendantOf(o, ancestor)
	local p = dataOf(o).parent
	while p do
		if p == ancestor then return true end
		p = dataOf(p).parent
	end
	return false
end
function methods.IsAncestorOf(o, descendant) return methods.IsDescendantOf(descendant, o) end
function methods.GetFullName(o)
	local names, x = {}, o
	while x do
		table.insert(names, 1, dataOf(x).name)
		x = dataOf(x).parent
	end
	return table.concat(names, ".")
end
function methods.Destroy(o)
	local d = dataOf(o)
	if d.destroyed then return end
	d.destroyed = true
	if d.signals.Destroying then d.signals.Destroying:Fire() end
	for _, c in table.clone(d.children) do
		methods.Destroy(c)
	end
	detach(o, d)
end
function methods.ClearAllChildren(o)
	for _, c in table.clone(dataOf(o).children) do
		methods.Destroy(c)
	end
end
function methods.Clone(o)
	local d = dataOf(o)
	local c = newGui(d.class)
	local cd = dataOf(c)
	cd.name = d.name
	for k, v in d.props do
		cd.props[k] = v
	end
	for _, child in d.children do
		local cc = methods.Clone(child)
		cc.Parent = c
	end
	return c
end
function methods.GetPropertyChangedSignal(o, name)
	local d = dataOf(o)
	if not d.propSignals[name] then
		d.propSignals[name] = newSignal()
	end
	return d.propSignals[name]
end
function methods.SetAttribute(o, k, v) dataOf(o).attrs[k] = v end
function methods.GetAttribute(o, k) return dataOf(o).attrs[k] end
function methods.GetAttributes(o) return table.clone(dataOf(o).attrs) end
function methods.GetAttributeChangedSignal(o, k)
	local d = dataOf(o)
	d.attrSignals[k] = d.attrSignals[k] or newSignal()
	return d.attrSignals[k]
end
function methods.CaptureFocus(o)
	local d = dataOf(o)
	d.focused = true
	if d.signals.Focused then d.signals.Focused:Fire() end
end
function methods.ReleaseFocus(o)
	local d = dataOf(o)
	d.focused = false
	if d.signals.FocusLost then d.signals.FocusLost:Fire(false) end
end
function methods.IsFocused(o) return dataOf(o).focused == true end
function methods.TweenSize(o, size) o.Size = size return true end
function methods.TweenPosition(o, pos) o.Position = pos return true end
function methods.TweenSizeAndPosition(o, size, pos) o.Size = size o.Position = pos return true end
function methods.GetActor() return nil end

-- ---------------------------------------------------------------------------------------------------------------------
-- Studio theme, settings(), StudioService
-- ---------------------------------------------------------------------------------------------------------------------
-- Approximate colours of Studio's built-in Dark / Light themes (Roblox does not publish the table).
local function rgb(r, g, b) return D.Color3.fromRGB(r, g, b) end
local THEMES = {
	Dark = {
		MainBackground = { 46, 46, 46 }, Titlebar = { 53, 53, 53 }, Dropdown = { 37, 37, 37 }, Tooltip = { 37, 37, 37 },
		Notification = { 37, 37, 37 }, ScrollBar = { 56, 56, 56 }, ScrollBarBackground = { 41, 41, 41 }, TabBar = { 41, 41, 41 },
		Tab = { 41, 41, 41 }, FilterButtonDefault = { 34, 34, 34 }, FilterButtonHover = { 66, 66, 66 }, FilterButtonChecked = { 11, 90, 175 },
		FilterButtonAccent = { 0, 162, 255 }, FilterButtonBorder = { 26, 26, 26 }, FilterButtonBorderAlt = { 26, 26, 26 },
		RibbonTab = { 41, 41, 41 }, RibbonTabTopBar = { 34, 34, 34 }, Button = { 60, 60, 60 }, MainButton = { 0, 162, 255 },
		RibbonButton = { 53, 53, 53 }, ViewPortBackground = { 37, 37, 37 }, InputFieldBackground = { 37, 37, 37 },
		Item = { 46, 46, 46 }, TableItem = { 46, 46, 46 }, CategoryItem = { 41, 41, 41 }, GameSettingsTableItem = { 46, 46, 46 },
		GameSettingsTooltip = { 37, 37, 37 }, EmulatorBar = { 41, 41, 41 }, EmulatorDropDown = { 53, 53, 53 },
		ColorPickerFrame = { 53, 53, 53 }, CurrentMarker = { 0, 162, 255 }, Border = { 34, 34, 34 }, DropShadow = { 0, 0, 0 },
		Shadow = { 0, 0, 0 }, Light = { 53, 53, 53 }, Dark = { 34, 34, 34 }, Mid = { 41, 41, 41 }, MainText = { 204, 204, 204 },
		SubText = { 170, 170, 170 }, TitlebarText = { 204, 204, 204 }, BrightText = { 255, 255, 255 }, DimmedText = { 102, 102, 102 },
		LinkText = { 0, 162, 255 }, WarningText = { 255, 204, 0 }, ErrorText = { 255, 68, 68 }, InfoText = { 0, 162, 255 },
		SensitiveText = { 255, 68, 68 }, ScriptBackground = { 30, 30, 30 }, ScriptText = { 204, 204, 204 },
		Separator = { 34, 34, 34 }, ButtonBorder = { 34, 34, 34 }, ButtonText = { 204, 204, 204 }, InputFieldBorder = { 26, 26, 26 },
		CheckedFieldBackground = { 37, 37, 37 }, CheckedFieldBorder = { 26, 26, 26 }, CheckedFieldIndicator = { 0, 162, 255 },
		HeaderSection = { 34, 34, 34 }, Midlight = { 66, 66, 66 }, StatusBar = { 41, 41, 41 }, DialogButton = { 60, 60, 60 },
		DialogButtonText = { 204, 204, 204 }, DialogButtonBorder = { 34, 34, 34 }, DialogMainButton = { 0, 162, 255 },
		DialogMainButtonText = { 255, 255, 255 }, InfoBarWarningBackground = { 77, 62, 0 }, InfoBarWarningText = { 255, 204, 0 },
		AttributeCog = { 170, 170, 170 },
	},
	Light = {
		MainBackground = { 255, 255, 255 }, Titlebar = { 255, 255, 255 }, Dropdown = { 255, 255, 255 }, Tooltip = { 255, 255, 255 },
		Notification = { 255, 255, 255 }, ScrollBar = { 245, 245, 245 }, ScrollBarBackground = { 255, 255, 255 }, TabBar = { 238, 238, 238 },
		Tab = { 238, 238, 238 }, FilterButtonDefault = { 238, 238, 238 }, FilterButtonHover = { 224, 224, 224 }, FilterButtonChecked = { 213, 232, 247 },
		FilterButtonAccent = { 0, 162, 255 }, FilterButtonBorder = { 182, 182, 182 }, FilterButtonBorderAlt = { 182, 182, 182 },
		RibbonTab = { 238, 238, 238 }, RibbonTabTopBar = { 238, 238, 238 }, Button = { 255, 255, 255 }, MainButton = { 0, 162, 255 },
		RibbonButton = { 238, 238, 238 }, ViewPortBackground = { 255, 255, 255 }, InputFieldBackground = { 255, 255, 255 },
		Item = { 255, 255, 255 }, TableItem = { 255, 255, 255 }, CategoryItem = { 238, 238, 238 }, GameSettingsTableItem = { 255, 255, 255 },
		GameSettingsTooltip = { 255, 255, 255 }, EmulatorBar = { 238, 238, 238 }, EmulatorDropDown = { 238, 238, 238 },
		ColorPickerFrame = { 245, 245, 245 }, CurrentMarker = { 0, 162, 255 }, Border = { 182, 182, 182 }, DropShadow = { 0, 0, 0 },
		Shadow = { 0, 0, 0 }, Light = { 255, 255, 255 }, Dark = { 182, 182, 182 }, Mid = { 238, 238, 238 }, MainText = { 27, 27, 27 },
		SubText = { 102, 102, 102 }, TitlebarText = { 27, 27, 27 }, BrightText = { 0, 0, 0 }, DimmedText = { 170, 170, 170 },
		LinkText = { 0, 114, 187 }, WarningText = { 204, 102, 0 }, ErrorText = { 204, 0, 0 }, InfoText = { 0, 114, 187 },
		SensitiveText = { 204, 0, 0 }, ScriptBackground = { 255, 255, 255 }, ScriptText = { 27, 27, 27 },
		Separator = { 227, 227, 227 }, ButtonBorder = { 182, 182, 182 }, ButtonText = { 27, 27, 27 }, InputFieldBorder = { 182, 182, 182 },
		CheckedFieldBackground = { 255, 255, 255 }, CheckedFieldBorder = { 182, 182, 182 }, CheckedFieldIndicator = { 0, 162, 255 },
		HeaderSection = { 238, 238, 238 }, Midlight = { 224, 224, 224 }, StatusBar = { 238, 238, 238 }, DialogButton = { 255, 255, 255 },
		DialogButtonText = { 27, 27, 27 }, DialogButtonBorder = { 182, 182, 182 }, DialogMainButton = { 0, 162, 255 },
		DialogMainButtonText = { 255, 255, 255 }, InfoBarWarningBackground = { 255, 242, 204 }, InfoBarWarningText = { 102, 77, 0 },
		AttributeCog = { 102, 102, 102 },
	},
}
-- Hover / Pressed / Selected / Disabled variants: a shift of the default colour (good enough to judge a layout)
local function shift(color, modifier, dark)
	local function mix(c, t, a) return c + (t - c) * a end
	local r, g, b = color[1], color[2], color[3]
	local up = dark and 255 or 0
	local down = dark and 0 or 255
	if modifier == "Hover" then r, g, b = mix(r, up, 0.08), mix(g, up, 0.08), mix(b, up, 0.08)
	elseif modifier == "Pressed" then r, g, b = mix(r, down, 0.12), mix(g, down, 0.12), mix(b, down, 0.12)
	elseif modifier == "Selected" then r, g, b = mix(r, up, 0.16), mix(g, up, 0.16), mix(b, up, 0.16)
	elseif modifier == "Disabled" then r, g, b = mix(r, dark and 46 or 255, 0.5), mix(g, dark and 46 or 255, 0.5), mix(b, dark and 46 or 255, 0.5) end
	return rgb(math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5))
end

local themeName = ARGS.theme == "light" and "Light" or "Dark"
local themeSignal = newSignal()
local Theme = { Name = themeName }
function Theme.GetColor(self, color, modifier)
	local name = color and color.Name or tostring(color)
	local table_ = THEMES[themeName]
	local c = table_[name]
	if not c then
		warnOnce("theme." .. tostring(name), "StudioStyleGuideColor." .. tostring(name) .. " is not in the preview theme table (magenta)")
		return rgb(255, 0, 255)
	end
	local mod = modifier and modifier.Name or "Default"
	if mod == "Default" then
		return rgb(c[1], c[2], c[3])
	end
	return shift(c, mod, themeName == "Dark")
end
function Theme.GetEnumItems() return {} end
P.themeBackground = function() return THEMES[themeName].MainBackground end
local StudioSettings = setmetatable({ Theme = setmetatable(Theme, { __type = "StudioTheme" }), ThemeChanged = themeSignal }, {
	__index = function(_, k)
		if k == "Font" then return Enum.Font.SourceSans end
		return nil
	end,
})
local GlobalSettings = setmetatable({ Studio = StudioSettings }, { __index = function() return nil end })

-- class icons: { class -> index } is provided by render.py (ReflectionMetadata of Roblox); 16x16 tiles of ClassImages.PNG
local ICONS = ARGS.classIcons or {}
local ICON_COLUMNS = ARGS.classIconColumns or 16
local StudioService = {}
function StudioService.GetClassIcon(_, className)
	local index = ICONS[className] or ICONS.Instance or 0
	return {
		Image = "rbxasset://textures/ClassImages.PNG",
		ImageRectSize = v2(16, 16),
		ImageRectOffset = v2((index % ICON_COLUMNS) * 16, math.floor(index / ICON_COLUMNS) * 16),
	}
end
StudioService.Theme = Theme
StudioService.ThemeChanged = themeSignal
setmetatable(StudioService, { __type = "Instance", __index = function(t, k)
	if k == "ClassName" then return "StudioService" end
	if k == "IsA" then return function(_, c) return c == "StudioService" or c == "Instance" end end
	return nil
end })
P.StudioService = StudioService

-- ---------------------------------------------------------------------------------------------------------------------
-- services the GUI kit may use: TweenService (applies the goal at once), TextService (rough text sizes), anything else is a
-- stub that accepts every call / member (so an unknown service never stops a preview)
-- ---------------------------------------------------------------------------------------------------------------------
local function stub(name)
	local t = {}
	return setmetatable(t, {
		__type = "Instance",
		__index = function(self, k)
			if k == "ClassName" then return name end
			local s = stub(name .. "." .. tostring(k))
			rawset(self, k, s)
			return s
		end,
		__call = function() return stub(name .. "()") end,
		__tostring = function() return name end,
	})
end
P.stub = stub

local TweenService = {}
function TweenService.Create(_, inst, info, goal)
	local tween = { PlaybackState = "Begin", Completed = newSignal(), Instance = inst }
	function tween.Play()
		for k, v in goal do
			inst[k] = v
		end
		tween.PlaybackState = "Completed"
		tween.Completed:Fire("Completed")
	end
	function tween.Cancel() tween.PlaybackState = "Cancelled" end
	function tween.Pause() end
	function tween.Destroy() end
	return tween
end
TweenService.GetValue = function(_, alpha) return alpha end

local TextService = {}
local function textSize(text, size, width)
	local lines, longest = 1, 0
	for line in string.gmatch(text .. "\n", "(.-)\n") do
		longest = math.max(longest, (utf8.len(line) or #line) * size * 0.52 / 1.26)
	end
	for _ in string.gmatch(text, "\n") do lines += 1 end
	if width and width > 0 and longest > width then
		lines = math.max(lines, math.ceil(longest / width))
		longest = width
	end
	return v2(longest, lines * size)
end
function TextService.GetTextSize(_, text, size, _, bounds)
	return textSize(text, size, bounds and bounds.X)
end
function TextService.GetTextBoundsAsync(_, params)
	return textSize(params.Text or "", params.Size or 14, params.Width)
end

D.TweenInfo = { new = function(t, style, direction, repeatCount, reverses, delayTime)
	return make(datatype("TweenInfo", {}), { Time = t or 1, EasingStyle = style, EasingDirection = direction, RepeatCount = repeatCount or 0,
		Reverses = reverses or false, DelayTime = delayTime or 0 })
end }
D.Random = D.Random or nil
P.services = { TweenService = TweenService, TextService = TextService, StudioService = StudioService }

-- a game:GetService(name) that falls back to the helpers above and then to a stub; `lookup(name)` is the world's own
function P.getService(lookup, name)
	if P.services[name] then
		return P.services[name]
	end
	local ok, service = pcall(lookup, name)
	if ok and service ~= nil then
		return service
	end
	return stub(name)
end

-- ---------------------------------------------------------------------------------------------------------------------
-- install into an environment
-- ---------------------------------------------------------------------------------------------------------------------
-- opts.baseInstance: the table with .new for non-GUI classes (default: error); opts.keep = datatypes names the env already
-- has and must keep (default: none are kept, GUI datatypes are always replaced)
function P.install(env, opts)
	opts = opts or {}
	local baseNew = env.Instance and env.Instance.new
	local REPLACE = { Color3 = true, UDim = true, UDim2 = true, Vector2 = true, Font = true, Rect = true }
	for name, value in D do
		if name ~= "Enum" and (REPLACE[name] or env[name] == nil) then
			env[name] = value
		end
	end
	-- Enum: the base mock's (typed) enums win when it has the enum, mine otherwise
	local baseEnum = env.Enum
	if baseEnum and opts.mergeEnum then
		env.Enum = setmetatable({}, { __index = function(_, name)
			local ok, e = pcall(function() return baseEnum[name] end)
			if ok and e ~= nil then return e end
			return enumOf(name)
		end })
	else
		env.Enum = D.Enum
	end
	env.Instance = { new = function(class)
		if isGuiClass(class) then
			return newGui(class)
		end
		if baseNew then
			local ok, inst = pcall(baseNew, class)
			if ok then
				return inst
			end
		end
		-- a class the base mock does not know (a BindableEvent in a typed mock...): a generic instance
		warnOnce("new." .. class, "Instance.new(" .. tostring(class) .. "): not in the base mock, made a generic GUI-mock instance")
		return newGui(class)
	end }
	env.task = scheduler
	env.warn = function(...)
		local parts = {}
		for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
		table.insert(P.errors, "warn: " .. table.concat(parts, " ") .. "\n" .. debug.traceback("", 2))
	end
	env.settings = function() return GlobalSettings end
	local builtin = env.typeof or typeof
	env.typeof = function(v)
		local t = type(v)
		if t == "table" then
			local mt = getmetatable(v)
			if type(mt) == "table" and rawget(mt, "__type") then
				return rawget(mt, "__type")
			end
		end
		return builtin(v)
	end
	env.tick = env.tick or function() return clock end
	env.time = env.time or function() return clock end
	return env
end

-- ---------------------------------------------------------------------------------------------------------------------
-- the widget, finding / clicking
-- ---------------------------------------------------------------------------------------------------------------------
function P.newRoot(width, height)
	local root = newGui("DockWidgetPluginGui")
	root.Name = "LostCube"
	root.Size = ud2(0, width, 0, height)
	root.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	root.Title = "LostCube"
	root.Enabled = true
	P.root = root
	PARENT_ABS_ROOT.w, PARENT_ABS_ROOT.h = width, height
	return root
end

local function textOf(o)
	local t = dataOf(o).props.Text
	return type(t) == "string" and t or nil
end

-- every GUI descendant whose Text / PlaceholderText contains `needle` (plain find)
function P.findText(root, needle)
	local out = {}
	for _, d in methods.GetDescendants(root) do
		local t = textOf(d)
		if t and string.find(t, needle, 1, true) then
			table.insert(out, d)
		end
	end
	return out
end

-- the nearest button (the object itself or an ancestor) of an instance
local function buttonOf(o)
	local x = o
	while x do
		if methods.IsA(x, "GuiButton") then
			return x
		end
		x = dataOf(x).parent
	end
	return nil
end

-- clicks the button that shows `needle` (its own Text or the text of a label inside it); returns the button or nil
function P.click(root, needle)
	for _, d in P.findText(root, needle) do
		local b = buttonOf(d)
		if b and dataOf(b).signals.MouseButton1Click then
			dataOf(b).signals.MouseButton1Click:Fire()
			P.drain()
			return b
		end
	end
	return nil
end

-- Roblox fires the Absolute* change signals after layout: once the browser has measured (second pass on), do the same, so
-- code that only reacts to AbsoluteSize / AbsoluteContentSize changes sees its numbers too
function P.fireLayoutSignals(root)
	if next(MEASURE) == nil then
		return
	end
	local function visit(o)
		local d = dataOf(o)
		for _, name in { "AbsoluteSize", "AbsolutePosition", "AbsoluteContentSize", "AbsoluteCanvasSize", "TextBounds" } do
			local sig = d.propSignals[name]
			if sig then
				sig:Fire()
			end
		end
		for _, c in table.clone(d.children) do
			visit(c)
		end
	end
	visit(root)
	P.drain(1)
end

-- fires MouseEnter on the button that shows `needle` (hover colours, tooltips after their delay)
function P.hover(root, needle)
	for _, d in P.findText(root, needle) do
		local b = buttonOf(d) or d
		if dataOf(b).signals.MouseEnter then
			dataOf(b).signals.MouseEnter:Fire()
			P.drain(1)
			return b
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------------------------------------------------
-- JSON dump
-- ---------------------------------------------------------------------------------------------------------------------
local function num(n)
	if n ~= n or n == math.huge or n == -math.huge then
		return "null"
	end
	if n == math.floor(n) and math.abs(n) < 1e15 then
		return string.format("%d", n)
	end
	return string.format("%.9g", n)
end
local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f" }
local function str(s)
	return '"' .. string.gsub(s, '[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", string.byte(c)) end) .. '"'
end

P.jsonString = str

local function tname(v)
	local t = type(v)
	if t == "table" then
		local mt = getmetatable(v)
		if type(mt) == "table" and rawget(mt, "__type") then
			return rawget(mt, "__type")
		end
		return "table"
	end
	if t == "userdata" then
		local ok, mt = pcall(getmetatable, v)
		if ok and type(mt) == "table" and mt.__type then
			return mt.__type
		end
	end
	return t
end

local function arr(list)
	return "[" .. table.concat(list, ",") .. "]"
end

local function enc(v)
	local t = tname(v)
	if t == "number" then return num(v) end
	if t == "string" then return str(v) end
	if t == "boolean" then return tostring(v) end
	if t == "Color3" then return '{"$":"C3","v":' .. arr({ num(v.R), num(v.G), num(v.B) }) .. "}" end
	if t == "UDim2" then
		return '{"$":"UD2","v":' .. arr({ num(v.X.Scale), num(v.X.Offset), num(v.Y.Scale), num(v.Y.Offset) }) .. "}"
	end
	if t == "UDim" then return '{"$":"UD","v":' .. arr({ num(v.Scale), num(v.Offset) }) .. "}" end
	if t == "Vector2" then return '{"$":"V2","v":' .. arr({ num(v.X), num(v.Y) }) .. "}" end
	if t == "Rect" then return '{"$":"R","v":' .. arr({ num(v.Min.X), num(v.Min.Y), num(v.Max.X), num(v.Max.Y) }) .. "}" end
	if t == "EnumItem" then
		return '{"$":"E","e":' .. str(tostring(v.EnumName or v.EnumType)) .. ',"n":' .. str(v.Name) .. "}"
	end
	if t == "Font" then
		return '{"$":"F","f":' .. str(v.Family) .. ',"w":' .. num(v.Weight.Value) .. ',"s":' .. str(v.Style.Name) .. "}"
	end
	if t == "ColorSequence" then
		local pts = {}
		for _, k in v.Keypoints do
			table.insert(pts, arr({ num(k.Time), num(k.Value.R), num(k.Value.G), num(k.Value.B) }))
		end
		return '{"$":"CS","v":' .. arr(pts) .. "}"
	end
	if t == "NumberSequence" then
		local pts = {}
		for _, k in v.Keypoints do
			table.insert(pts, arr({ num(k.Time), num(k.Value) }))
		end
		return '{"$":"NS","v":' .. arr(pts) .. "}"
	end
	if t == "NumberRange" then return '{"$":"NR","v":' .. arr({ num(v.Min), num(v.Max) }) .. "}" end
	return nil
end

local function dumpInstance(o, out)
	local d = dataOf(o)
	local keys = {}
	for k in d.props do
		table.insert(keys, k)
	end
	table.sort(keys)
	local props = {}
	for _, k in keys do
		local e = enc(d.props[k])
		if e then
			table.insert(props, str(k) .. ":" .. e)
		end
	end
	local kids = {}
	for _, c in d.children do
		if isGuiClass(dataOf(c).class) then
			table.insert(kids, dumpInstance(c))
		end
	end
	return '{"id":' .. d.id .. ',"c":' .. str(d.class) .. ',"n":' .. str(d.name) .. ',"p":{' .. table.concat(props, ",") .. '},"k":['
		.. table.concat(kids, ",") .. "]}"
end

-- the JSON text of the tree under `root` plus notes (warnings, errors)
function P.dump(root, extra)
	local notes = {}
	local keys = {}
	for k in P.warnings do table.insert(keys, k) end
	table.sort(keys)
	for _, k in keys do table.insert(notes, str(P.warnings[k])) end
	local errors = {}
	for _, e in P.errors do table.insert(errors, str(e)) end
	return '{"root":' .. dumpInstance(root) .. ',"notes":' .. arr(notes) .. ',"errors":' .. arr(errors) .. ',"measureReads":'
		.. P.measureReads .. (extra and ("," .. extra) or "") .. "}"
end

P.methods = methods
P.dataOf = dataOf
P.newGui = newGui
P.v2, P.ud2, P.ud, P.c3 = v2, ud2, ud, c3
return P
