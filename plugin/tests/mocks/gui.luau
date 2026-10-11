-- Strict GUI mock: instances with a per-class whitelist of properties (a typo in a property name or an unknown member
-- raises an error), signals, a tiny task scheduler. Roblox datatypes are plain tables.
--
-- Run it in the environment the plugin sources will see; the globals it defines (Instance, Enum, UDim2, Color3,
-- task, warn, ...) land in that environment:
--     local env = LC.env()
--     local gui = LC.run("tests/mocks/gui.luau", env)
--     gui.runQueue() / gui.findText(root, "text") / gui.findAll(root, pred) / gui.click(button) / gui.errors
-- minimal Roblox mock: instances with per-class property whitelists, signals, a tiny task scheduler
local ERRORS = {}
local function fail(msg) table.insert(ERRORS, msg); error(msg, 3) end

local function vec2(x, y) return { X = x or 0, Y = y or 0, __t = "Vector2" } end
Vector2 = { new = vec2, zero = vec2(0, 0) }
UDim = { new = function(s, o) return { Scale = s, Offset = o } end }
UDim2 = {
	new = function(a, b, c, d) return { X = { Scale = a or 0, Offset = b or 0 }, Y = { Scale = c or 0, Offset = d or 0 } } end,
	fromScale = function(a, b) return UDim2.new(a, 0, b, 0) end,
	fromOffset = function(a, b) return UDim2.new(0, a, 0, b) end,
}
Color3 = {
	fromRGB = function(r, g, b) return { R = r / 255, G = g / 255, B = b / 255, ToHex = function() return "FFFFFF" end } end,
	new = function(r, g, b) return { R = r, G = g, B = b, ToHex = function() return "FFFFFF" end } end,
	fromHex = function() return Color3.new(1, 1, 1) end,
}
Font = { new = function(family, weight, style) return { Family = family, Weight = weight, Style = style } end }
Enum = setmetatable({}, { __index = function(_, enumName)
	return setmetatable({}, { __index = function(_, item) return enumName .. "." .. item end })
end })

-- scheduler
local queue = {}
local function resume(co, ...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then table.insert(ERRORS, "task error: " .. tostring(err)); print("TASK ERROR", err) end
end
task = {
	spawn = function(f, ...) local co = coroutine.create(f); resume(co, ...); return co end,
	defer = function(f, ...) local args = { ... }; table.insert(queue, function() resume(coroutine.create(f), table.unpack(args)) end) end,
	delay = function(_, f, ...) local args = { ... }; table.insert(queue, function() resume(coroutine.create(f), table.unpack(args)) end) end,
	wait = function(s)
		local co = coroutine.running()
		table.insert(queue, function() resume(co) end)
		coroutine.yield()
		return s or 0
	end,
}
function runQueue(maxSteps)
	local steps = 0
	while #queue > 0 and steps < (maxSteps or 200) do
		steps += 1
		local f = table.remove(queue, 1)
		f()
	end
	return steps
end
warn = function(...) print("WARN", ...) end

-- signals
local function Signal()
	local s = { conns = {} }
	function s:Connect(f) local c = { f = f, Disconnect = function(c) c.dead = true end }; table.insert(self.conns, c); return c end
	function s:Fire(...) for _, c in self.conns do if not c.dead then local co = coroutine.create(c.f); resume(co, ...) end end end
	return s
end

local GUI = { "Name", "Parent", "Size", "Position", "AnchorPoint", "BackgroundColor3", "BackgroundTransparency",
	"BorderSizePixel", "LayoutOrder", "AutomaticSize", "Visible", "ZIndex", "ClipsDescendants", "Active", "Rotation" }
local TEXT = { "Text", "Font", "FontFace", "TextSize", "TextColor3", "TextXAlignment", "TextYAlignment", "TextWrapped", "RichText",
	"TextTruncate", "LineHeight", "TextTransparency" }
local IMAGE = { "Image", "ImageColor3", "ImageTransparency", "ImageRectOffset", "ImageRectSize", "ScaleType", "ResampleMode" }
local function set(...) local t = {}; for _, list in { ... } do for _, k in list do t[k] = true end end; return t end
local PROPS = {
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
	Focused = true, InputBegan = true, InputEnded = true, MouseButton1Down = true, MouseButton1Up = true }

local Inst = {}
function Inst.new(class)
	assert(PROPS[class], "mock: unknown class " .. class)
	local data = { ClassName = class, Name = class, children = {}, signals = {}, propSignals = {}, props = {
		AbsoluteSize = vec2(300, 20), AbsolutePosition = vec2(0, 0), AbsoluteCanvasSize = vec2(300, 600),
		AbsoluteContentSize = vec2(300, 100), Text = "", CanvasPosition = vec2(0, 0) } }
	local obj
	local methods = {}
	function methods:IsA(c) return c == class or (c == "GuiObject" and GUIOBJ[class] == true) or c == "Instance" end
	function methods:GetChildren() local t = {}; for _, c in data.children do table.insert(t, c) end; return t end
	function methods:FindFirstChild(n) for _, c in data.children do if c.Name == n then return c end end; return nil end
	function methods:FindFirstChildOfClass(n) for _, c in data.children do if c.ClassName == n then return c end end; return nil end
	function methods:Destroy() obj.Parent = nil; data.destroyed = true end
	function methods:GetPropertyChangedSignal(p)
		data.propSignals[p] = data.propSignals[p] or Signal()
		return data.propSignals[p]
	end
	function methods:CaptureFocus() data.focused = true end
	function methods:IsFocused() return data.focused == true end
	function methods:GetFullName() return "Workspace." .. obj.Name end
	data.attributes = {}
	function methods:SetAttribute(k, v) data.attributes[k] = v end
	function methods:GetAttribute(k) return data.attributes[k] end
	obj = setmetatable({}, {
		__index = function(_, k)
			if methods[k] then return methods[k] end
			if k == "ClassName" then return class end
			if k == "Name" then return data.Name end
			if k == "Parent" then return data.parent end
			if EVENTS[k] then data.signals[k] = data.signals[k] or Signal(); return data.signals[k] end
			if k == "__data" then return data end
			if data.props[k] ~= nil then return data.props[k] end
			if PROPS[class][k] then return nil end
			fail("mock: " .. class .. " has no member " .. tostring(k))
		end,
		__newindex = function(_, k, v)
			if not PROPS[class][k] then fail("mock: cannot set " .. class .. "." .. tostring(k)) end
			if data.destroyed and k == "Parent" and v ~= nil then fail("mock: reparenting destroyed " .. class) end
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
function click(btn) btn.MouseButton1Click:Fire() end

return { errors = ERRORS, runQueue = runQueue, findAll = findAll, findText = findText, click = click }
