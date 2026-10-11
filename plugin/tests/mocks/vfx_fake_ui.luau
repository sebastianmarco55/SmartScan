-- A fake UI kit for the VFXPanel suites (vfx_panel, vfx_runtime): every component the panel calls records a plain node
-- (kind, fields, children), so a test can find a control and call its callback the way a click / an edit would. Toasts,
-- menus and confirmations are recorded too. Custom instances the panel builds with UI.make are permissive nodes with
-- signals (MouseButton1Click, MouseEnter, ...) that the test can fire.
--   local F = LC.run("tests/mocks/vfx_fake_ui.luau", nil, { Color3 = Color3, typeof = typeof })
--   F.UI            the kit to hand to the panel (mocks = { UI = F.UI })
--   F.reset()       a fresh root node (the parent of a render); F.root
--   F.find(pred), F.all(kind), F.button(text), F.icon(glyph, tip?), F.text() (every visible string), F.toasts, F.menus,
--   F.confirms, F.lastToast(), F.globals(ENV) -> Enum wrapper with the GUI enums the typed mocks do not have
local deps = ...
local Color3, typeofFn = deps.Color3, deps.typeof

local F = { toasts = {}, menus = {}, confirms = {} }

-- signals ---------------------------------------------------------------------------------------------------------------
local function signal()
	local s = { handlers = {} }
	function s.Connect(_, fn)
		local conn = { fn = fn, connected = true }
		function conn.Disconnect(c)
			c.connected = false
		end
		table.insert(s.handlers, conn)
		return conn
	end
	function s.Fire(_, ...)
		for _, conn in table.clone(s.handlers) do
			if conn.connected then
				conn.fn(...)
			end
		end
	end
	function s.live()
		local n = 0
		for _, conn in s.handlers do
			n += conn.connected and 1 or 0
		end
		return n
	end
	return s
end
F.signal = signal

local SIGNALS = { MouseButton1Click = true, MouseButton1Down = true, MouseButton1Up = true, MouseEnter = true, MouseLeave = true,
	FocusLost = true, Focused = true, InputBegan = true, InputChanged = true, InputEnded = true, Changed = true, Activated = true }

-- nodes -----------------------------------------------------------------------------------------------------------------
local NodeMT = {}
NodeMT.__index = function(self, k)
	if SIGNALS[k] then
		local s = signal()
		rawset(self, k, s)
		return s
	end
	return nil
end

local function node(kind, parent, fields)
	local n = fields or {}
	n.kind, n.children = kind, {}
	n.Visible = n.Visible == nil and true or n.Visible
	n.attributes = {}
	setmetatable(n, NodeMT)
	if parent then
		n.Parent = parent
		table.insert(parent.children, n)
	end
	n.CaptureFocus = function() end
	n.IsFocused = function() return false end
	n.SetAttribute = function(self, k, v)
		self.attributes[k] = v
	end
	n.GetAttribute = function(self, k)
		return self.attributes[k]
	end
	n.Destroy = function(self)
		self.Parent = nil
	end
	n.GetChildren = function(self)
		return self.children
	end
	n.GetPropertyChangedSignal = function(self, prop)
		local key = "Prop:" .. prop
		local s = rawget(self, key)
		if not s then
			s = signal()
			rawset(self, key, s)
		end
		return s
	end
	return n
end
F.node = node

-- the kit -----------------------------------------------------------------------------------------------------------------
local TOKENS = { "bg", "header", "surface", "surfaceHover", "surfacePressed", "raised", "raisedStrong", "field", "fieldBorder",
	"fieldBorderHover", "focus", "border", "divider", "button", "buttonHover", "buttonPressed", "buttonBorder", "buttonText", "text",
	"textDim", "textDisabled", "textBright", "accent", "accentHover", "accentPressed", "accentText", "accentSoft", "accentSoftHover",
	"link", "danger", "dangerSoft", "warning", "warningSoft", "success", "successSoft", "info", "scrollbar", "tooltip", "switchOff",
	"knob", "scrim" }
local C = {}
for i, name in TOKENS do
	C[name] = Color3.fromRGB(i, i, i) -- distinct values: a test can tell which token a note was given
end
local UI = { C = C, H = 24, H_LARGE = 28, LABEL_W = 96, SPACE = { xxs = 2, xs = 4, sm = 8, md = 12, lg = 16, xl = 24 },
	RADIUS = { control = 4, surface = 6, pill = 999 }, collapsed = {} }
F.UI = UI

local function number(v, what)
	assert(type(v) == "number", what .. " got " .. typeofFn(v))
end

function UI.fmt(v, decimals)
	if decimals == 0 then
		return tostring(math.floor(v + 0.5))
	end
	local s = string.format("%." .. (decimals or 2) .. "f", v)
	s = s:gsub("0+$", ""):gsub("%.$", "")
	return s == "-0" and "0" or s
end
function UI.escape(s)
	return (string.gsub(tostring(s), "[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end
function UI.make(class, props, children)
	local parent = props.Parent
	local fields = {}
	for k, v in props do
		if k ~= "Parent" then
			fields[k] = v
		end
	end
	fields.ClassName = class
	local n = node("make", parent, fields)
	for _, child in children or {} do
		if type(child) == "table" then
			child.Parent = n
			table.insert(n.children, child)
		end
	end
	return n
end
function UI.corner()
	return node("UICorner", nil)
end
function UI.stroke()
	return node("UIStroke", nil)
end
function UI.pad()
	return node("UIPadding", nil)
end
function UI.vlist()
	return node("UIListLayout", nil)
end
function UI.hlist()
	return node("UIListLayout", nil)
end
function UI.textStyle(target)
	return target
end
function UI.skin(inst, map)
	inst.skin = map
	return inst
end
function UI.tip(target, text)
	target.tipText = text
end
function UI.label(p, text, o)
	return node("label", p, { Text = text, opts = o or {} })
end
function UI.button(p, text, click, o)
	return node("button", p, { Text = text, click = click, opts = o or {} })
end
function UI.iconButton(p, glyph, click, o)
	o = o or {}
	return node("iconButton", p, { glyph = glyph, click = click, opts = o, tip = o.tip })
end
function UI.hstack(p)
	return node("hstack", p)
end
function UI.vstack(p)
	return node("vstack", p)
end
function UI.row(p, text)
	return node("row", p, { label = text })
end
function UI.spacer(p)
	return node("spacer", p)
end
function UI.divider(p)
	return node("divider", p)
end
function UI.number(p, v, f, o)
	number(v, "UI.number")
	return node("number", p, { Text = tostring(v), value = v, change = f, opts = o or {} })
end
function UI.scrub(p, label, v, f, o)
	number(v, "UI.scrub " .. tostring(label))
	local n = node("scrub", p, { label = label, value = v, change = f, opts = o or {} })
	return n, n
end
function UI.slider(p, v, f, o)
	number(v, "UI.slider")
	o = o or {}
	assert(o.min == nil or o.max == nil or o.min < o.max, "UI.slider: min < max")
	return node("slider", p, { value = v, change = f, opts = o })
end
function UI.textbox(p, v, f, o)
	return node("textbox", p, { Text = v or "", change = f, opts = o or {} })
end
function UI.search(p, v, f, o)
	local n = node("search", p, { Text = v or "", change = f, opts = o or {} })
	return n, n
end
function UI.toggle(p, v, f, text, o)
	assert(type(v) == "boolean", "UI.toggle " .. tostring(text) .. " got " .. typeofFn(v))
	return node("toggle", p, { Text = text, change = f, value = v, opts = o or {} })
end
function UI.switch(p, v, f, o)
	return node("toggle", p, { change = f, value = v, opts = o or {} })
end
function UI.segmented(p, items, v, f)
	return node("segmented", p, { items = items, value = v, change = f })
end
function UI.dropdown(p, items, v, f, o)
	local n = node("dropdown", p, { items = items, value = v, change = f, opts = o or {} })
	return n, node("chevron", nil)
end
function UI.menu(anchor, items, o)
	table.insert(F.menus, { anchor = anchor, items = items, opts = o or {} })
	return node("menu", nil)
end
function UI.color(p, c, f, o)
	assert(typeofFn(c) == "Color3", "UI.color got " .. typeofFn(c))
	return node("color", p, { value = c, change = f, opts = o or {} })
end
function UI.section(p, title, o)
	o = o or {}
	local n = node("section", p, { title = title, opts = o })
	if o.right then
		o.right(node("sectionRight", n))
	end
	return n
end
function UI.header(p, title, o)
	o = o or {}
	local n = node("header", p, { title = title, opts = o })
	for _, a in o.actions or {} do
		UI.iconButton(n, a.icon, a.onClick, { tip = a.tip, active = a.active, danger = a.danger })
	end
	return n
end
function UI.item(p, text, o)
	return node("item", p, { Text = text, opts = o or {} })
end
function UI.scrollList(p)
	return node("scroll", p)
end
function UI.note(p, text, color)
	return node("note", p, { Text = text, color = color })
end
function UI.badge(p, text, kind)
	return node("badge", p, { Text = text, badgeKind = kind })
end
function UI.empty(p, text, actionText, onAction, o)
	local n = node("empty", p, { Text = text, opts = o or {} })
	if actionText then
		node("button", n, { Text = actionText, click = onAction, opts = { style = "primary" } })
	end
	return n
end
function UI.toast(text, kind, o)
	local t = { text = text, kind = kind or "info", opts = o or {} }
	table.insert(F.toasts, t)
	return { dismiss = function() end, frame = node("toast", nil) }
end
function UI.confirm(title, text, confirmText, onConfirm, o)
	table.insert(F.confirms, { title = title, text = text, confirmText = confirmText, onConfirm = onConfirm, opts = o or {} })
	return node("dialog", nil)
end

-- finding things --------------------------------------------------------------------------------------------------------
function F.reset()
	F.root = node("root", nil)
	return F.root
end
F.reset()

local function walk(n, fn)
	fn(n)
	for _, c in n.children do
		walk(c, fn)
	end
end
F.walk = walk

function F.find(pred, root)
	local out = {}
	walk(root or F.root, function(n)
		if pred(n) then
			table.insert(out, n)
		end
	end)
	return out
end

function F.all(kind, root)
	return F.find(function(n)
		return n.kind == kind
	end, root)
end

-- the one button showing `text` (fails when there are none or several)
function F.button(text, root)
	local found = F.find(function(n)
		return n.kind == "button" and n.Text == text
	end, root)
	assert(#found == 1, "button '" .. text .. "' x" .. #found)
	return found[1]
end

function F.hasButton(text, root)
	return #F.find(function(n)
		return n.kind == "button" and n.Text == text
	end, root) > 0
end

-- icon buttons with this glyph (and this tip, when given)
function F.icons(glyph, tip, root)
	return F.find(function(n)
		return n.kind == "iconButton" and n.glyph == glyph and (tip == nil or n.tip == tip)
	end, root)
end

function F.icon(glyph, tip, root)
	local found = F.icons(glyph, tip, root)
	assert(#found == 1, "icon button '" .. glyph .. "' (" .. tostring(tip) .. ") x" .. #found)
	return found[1]
end

function F.section(title)
	local found = F.find(function(n)
		return n.kind == "section" and n.title == title
	end)
	return found[1], #found
end

function F.lastToast()
	return F.toasts[#F.toasts]
end

-- every string the panel shows (texts, labels, titles, placeholders, tips, menu / dropdown items, toasts, dialogs)
function F.text(root)
	local out = {}
	local function add(s)
		if type(s) == "string" then
			table.insert(out, s)
		end
	end
	walk(root or F.root, function(n)
		add(n.Text)
		add(n.label)
		add(n.title)
		add(n.tip)
		add(n.tipText)
		if type(n.opts) == "table" then
			add(n.opts.placeholder)
			add(n.opts.tip)
			add(n.opts.text)
			add(n.opts.note)
			add(n.opts.title)
			add(n.opts.subtitle)
			if type(n.opts.badge) == "string" then
				add(n.opts.badge)
			end
			for _, a in n.opts.actions or {} do
				add(a.tip)
				add(a.text)
			end
		end
		for _, item in n.items or {} do
			add(item.label)
			add(item.tip)
			add(item.hint)
		end
	end)
	for _, m in F.menus do
		for _, item in m.items do
			add(item.label)
			add(item.hint)
		end
	end
	for _, t in F.toasts do
		add(t.text)
		if t.opts.action then
			add(t.opts.action.text)
		end
	end
	for _, c in F.confirms do
		add(c.title)
		add(c.text)
		add(c.confirmText)
	end
	return out
end

-- an emoji or a symbol used as an icon (design.md: none, anywhere), or nil
local SYMBOLS = { "✓", "✗", "⚠", "•", "★", "☀", "≈", "■", "◆", "◎", "⚡", "♪", "▶", "⏸", "⏹", "🔁", "📋", "↺", "→", "←" }
function F.symbolIn(text)
	for _, s in SYMBOLS do
		if string.find(text, s, 1, true) then
			return s
		end
	end
	for _, cp in utf8.codes(text) do
		if (cp >= 0x2190 and cp <= 0x21FF) or (cp >= 0x2300 and cp <= 0x23FF) or (cp >= 0x25A0 and cp <= 0x27BF)
			or cp >= 0x1F000 then
			return utf8.char(cp)
		end
	end
	return nil
end

-- the GUI datatypes / enums the typed Roblox mocks do not model (the panel builds a few frames of its own): installs
-- UDim / UDim2 when missing and returns an Enum that knows TextXAlignment, TextYAlignment, AutomaticSize and UIFlexMode
-- (strictly: an unknown member errors) and defers to the mock's Enum for everything else
function F.globals(ENV)
	if ENV.UDim == nil then
		ENV.UDim = { new = function(s, o)
			return { Scale = s or 0, Offset = o or 0 }
		end }
	end
	if ENV.UDim2 == nil then
		local function udim2(xs, xo, ys, yo)
			return { X = { Scale = xs or 0, Offset = xo or 0 }, Y = { Scale = ys or 0, Offset = yo or 0 } }
		end
		ENV.UDim2 = { new = udim2, fromOffset = function(x, y)
			return udim2(0, x, 0, y)
		end, fromScale = function(x, y)
			return udim2(x, 0, y, 0)
		end }
	end
	local GUI = {}
	for name, members in { TextXAlignment = { "Left", "Right", "Center" }, TextYAlignment = { "Top", "Center", "Bottom" },
		AutomaticSize = { "None", "X", "Y", "XY" }, UIFlexMode = { "None", "Grow", "Shrink", "Fill", "Custom" } } do
		local items = {}
		for _, m in members do
			items[m] = { Name = m, EnumName = name }
		end
		GUI[name] = setmetatable({}, { __index = function(_, k)
			return items[k] or error(tostring(k) .. " is not a valid member of Enum." .. name, 2)
		end })
	end
	local base = ENV.Enum
	return setmetatable({}, { __index = function(_, name)
		return GUI[name] or base[name]
	end })
end

return F
