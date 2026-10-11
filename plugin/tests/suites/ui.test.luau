-- UI kit 2.1 (UI + Theme + Icons, all real) on the strict GUI mock (an unknown or misspelled property is an error):
-- the 2.0 API still works for the panels, no emoji anywhere, typography and theme tokens, live re-skin from a fake Studio
-- theme, Studio icon paths that were checked against the Studio manifest, and every new component (switch, scrub, slider,
-- search, dropdown / menu with Escape and outside click, colour picker, toasts, confirm, empty, progress, tabs ...).
local LC = ...
local t = LC.kit.new("ui")

local env = LC.env()
local gui = LC.run("tests/mocks/gui.luau", env)
local Instance = env.Instance
local findAll, click = gui.findAll, gui.click
local MOCK_ERRORS = gui.errors
local VERIFIED = LC.run("tests/suites/data/studio_icons.luau")

-- Color3 with real hex conversion and value equality (like Roblox)
local ColorMT = {}
ColorMT.__index = { ToHex = function(c)
	return string.format("%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end }
ColorMT.__eq = function(a, b)
	return math.abs(a.R - b.R) < 1e-6 and math.abs(a.G - b.G) < 1e-6 and math.abs(a.B - b.B) < 1e-6
end
local function rgb(r, g, b)
	return setmetatable({ R = r, G = g, B = b }, ColorMT)
end
env.Color3 = {
	new = function(r, g, b) return rgb(r or 0, g or 0, b or 0) end,
	fromRGB = function(r, g, b) return rgb((r or 0) / 255, (g or 0) / 255, (b or 0) / 255) end,
	fromHex = function(hex)
		hex = string.gsub(hex, "^#", "")
		assert(string.match(hex, "^%x%x%x%x%x%x$"), "Unable to convert characters to hex value")
		return rgb(tonumber(string.sub(hex, 1, 2), 16) / 255, tonumber(string.sub(hex, 3, 4), 16) / 255, tonumber(string.sub(hex, 5, 6), 16) / 255)
	end,
}
local Color3 = env.Color3

-- a scheduler with a clock
local clock, queue = 0, {}
env.task.delay = function(dt, f, ...)
	table.insert(queue, { at = clock + (dt or 0), f = f, args = { ... } })
end
env.task.defer = function(f, ...)
	table.insert(queue, { at = clock, f = f, args = { ... } })
end
local function advance(dt)
	clock += dt or 0
	local progressed = true
	while progressed do
		progressed = false
		for i, entry in queue do
			if entry.at <= clock then
				table.remove(queue, i)
				entry.f(table.unpack(entry.args))
				progressed = true
				break
			end
		end
	end
end

local function signal()
	local s = { conns = {} }
	function s:Connect(f)
		local c = { f = f, connected = true }
		function c:Disconnect() self.connected = false end
		table.insert(self.conns, c)
		return c
	end
	function s:Fire(...)
		for _, c in table.clone(self.conns) do
			if c.connected then c.f(...) end
		end
	end
	function s:live()
		local n = 0
		for _, c in self.conns do
			if c.connected then n += 1 end
		end
		return n
	end
	return s
end

local UIS = { IsKeyDown = function() return false end, InputBegan = signal() }
local services = { UserInputService = UIS }
env.game = { GetService = function(_, n) return services[n] or error("no service " .. n) end }

-- settings(): nil until a test gives it a fake Studio (outside Studio, settings().Studio fails)
local fakeSettings = nil
env.settings = function() return fakeSettings end
local tree = LC.modtree.new{ env = env }
local UI = tree.load("UI")
local Theme = tree.load("Theme")
local Icons = tree.load("Icons")
local C = UI.C

local root = Instance.new("Frame")
root.__data.props.AbsoluteSize = env.Vector2.new(360, 600)
UI.setRoot(root)
local page = Instance.new("Frame")
page.Parent = root

local function child(parent, name)
	for _, c in parent:GetChildren() do
		if c.Name == name then return c end
	end
	return nil
end
local function all(parent, pred)
	return findAll(parent, pred)
end
local function byText(parent, text)
	return all(parent, function(c) return c.__data.props.Text == text end)[1]
end
local function isColor(c)
	return type(c) == "table" and type(c.R) == "number" and type(c.G) == "number" and type(c.B) == "number"
end
local function overlay()
	return child(root, "Overlay")
end
local function popupOpen()
	return overlay().Visible == true and #overlay():GetChildren() > 0
end
local function input(kind, x, y, extra)
	local i = { UserInputType = kind and ("UserInputType." .. kind) or nil, Position = { X = x or 0, Y = y or 0, Z = 0 } }
	for k, v in extra or {} do
		i[k] = v
	end
	function i:IsModifierKeyDown(m)
		return (self.mods or {})[m] == true
	end
	return i
end
local function clear(frame)
	for _, c in frame:GetChildren() do c:Destroy() end
end

-- ---------------------------------------------------------------------------------------------
t.section("2.0 API surface", function()
	for _, name in { "make", "corner", "stroke", "pad", "vlist", "hlist", "setRoot", "closePopup", "tip", "label", "button",
		"hstack", "vstack", "row", "number", "textbox", "toggle", "segmented", "dropdown", "color", "section", "item",
		"scrollList", "note", "spacer", "fmt" } do
		t.check(type(UI[name]) == "function", "UI." .. name .. " is a function")
	end
	for _, name in { "iconButton", "switch", "slider", "scrub", "search", "colorPicker", "badge", "chip", "toast", "confirm",
		"empty", "progress", "divider", "header", "tabs", "icon", "menu", "popover", "textStyle", "skin", "animate",
		"textWidth", "tabsMode", "release" } do
		t.check(type(UI[name]) == "function", "new UI." .. name)
	end
	t.check(type(UI.collapsed) == "table" and type(UI.H) == "number" and type(UI.LABEL_W) == "number", "collapsed / H / LABEL_W")
	t.check(UI.FONT ~= nil and UI.FONT_MED ~= nil and UI.FONT_BOLD ~= nil, "font enums kept")
	for _, key in { "bg", "section", "header", "item", "hover", "input", "border", "text", "dim", "accent", "accentHover",
		"accentDark", "good", "danger", "warn" } do
		t.check(isColor(C[key]), "UI.C." .. key .. " is a colour")
	end
	t.check(C.dim == Theme.tokens.textDim and C.warn == Theme.tokens.warning and C.good == Theme.tokens.success
		and C.accentDark == Theme.tokens.accentSoft and C.input == Theme.tokens.field, "2.0 names map to the tokens")
	t.eq("fmt", UI.fmt(1.50, 2), "1.5")
	t.eq("fmt int", UI.fmt(2.6, 0), "3")
end)

-- ---------------------------------------------------------------------------------------------
-- the panels' 2.0 calls, as VFXPanel / AnalysisPanel / ClaudePanel make them
local EMOJI = { "✓", "✗", "▼", "►", "◆", "★", "☀", "≈", "■", "📋", "🔁", "⏸", "▶", "⚠", "✨", "🎬", "📚", "🧠", "⏹", "↻" }
local function emojiIn(text)
	for _, e in EMOJI do
		if string.find(text, e, 1, true) then return e end
	end
	for _, cp in utf8.codes(text) do
		if cp >= 0x2600 or (cp >= 0x25A0 and cp <= 0x25FF) then return utf8.char(cp) end
	end
	return nil
end

t.section("2.0 calls render in the new style, no emoji", function()
	clear(page)
	local body = UI.section(page, "Efecte  (2)", { key = "t.fx", right = function(r)
		UI.button(r, "x", function() end, { width = 24, style = "ghost" })
	end, rightWidth = 30 })
	local bar = UI.hstack(body)
	UI.button(bar, "Efect nou", function() end, { style = "primary", bold = true })
	UI.button(bar, "Din șablon", function() end, { selected = true, tip = "efecte gata făcute" })
	UI.textbox(UI.hstack(body), "", nil, { placeholder = "Numele efectului" })
	local list = UI.scrollList(body, 200)
	UI.item(list, "Foc", { icon = "old-glyph", selected = true, note = "3 el.", onClick = function() end, actions = {
		{ text = "x", color = C.danger, onClick = function() end } } })
	UI.item(list, "Fum", { classIcon = "ParticleEmitter", muted = true, actions = { { icon = "copy", tip = "Duplică", onClick = function() end } } })
	UI.dropdown(UI.row(body, "Prins de"), { { header = true, label = "Grup" }, { value = "A", label = "Pe sol" }, { value = "B", label = "Pe mână" } },
		"A", function() end, { menuWidth = 200 })
	UI.dropdown(UI.hstack(body), { { value = "P", label = "Particule" } }, nil, function() end, { text = "Adaugă element", style = "primary" })
	UI.segmented(UI.row(body, "Viteză"), { { value = 1, label = "x1" }, { value = 2, label = "x2" } }, 1, function() end)
	UI.number(UI.row(body, "Durată"), 1.25, function() end, { min = 0, max = 10, step = 0.05, decimals = 2 })
	UI.toggle(UI.hstack(body), true, function() end, "Umbre")
	UI.color(UI.row(body, "Culoare"), Color3.fromRGB(255, 138, 61), function() end)
	UI.note(body, "Notă cu <b>text</b>.", C.warn)
	UI.note(body, "Notă neutră.")
	UI.label(body, "Text", { dim = true, size = 11, wrap = true })
	UI.label(body, "Titlu", { bold = true, size = 14 })
	UI.spacer(body, 6)
	UI.vstack(body, 6)
	t.eq("no mock errors (every property is real)", #MOCK_ERRORS, 0)
	for _, e in MOCK_ERRORS do print("  mock error:", e) end
	local offenders = {}
	for _, d in all(page, function() return true end) do
		local text = d.__data.props.Text
		if type(text) == "string" and emojiIn(text) then
			table.insert(offenders, text)
		end
	end
	t.eq("no emoji / symbol glyphs in the kit's own text: " .. table.concat(offenders, " | "), #offenders, 0)
	-- the kit draws no violet: every colour it paints is a theme token
	local titles = all(page, function(c) return c.ClassName == "TextLabel" and c.__data.props.Text == "<uc>Efecte  (2)</uc>" end)
	t.check(#titles == 1 and titles[1].RichText == true, "section title: <uc> rich text, the text itself unchanged")
	t.check(titles[1].TextSize == 11 and titles[1].TextColor3 == C.textDim, "section title: 11 px, dim")
	local images = all(page, function(c) return c.ClassName == "ImageLabel" end)
	t.check(#images >= 4, "glyphs are images (chevrons, class icon, action icons): " .. #images)
	for _, img in images do
		t.check(string.find(img.Image, "rbxasset://", 1, true) == 1, "image from Studio content: " .. tostring(img.Image))
	end
	local legacyGlyph = byText(page, "old-glyph")
	t.check(legacyGlyph ~= nil, "a 2.0 text glyph on an item still shows (panels pass their own)")
end)

-- ---------------------------------------------------------------------------------------------
t.section("typography", function()
	clear(page)
	local body = UI.label(page, "Corp")
	t.check(body.FontFace ~= nil and body.FontFace.Family == "rbxasset://fonts/families/BuilderSans.json", "Builder Sans FontFace")
	t.eq("body size", body.TextSize, 12)
	local title = UI.label(page, "Titlu", { role = "title" })
	t.eq("title size", title.TextSize, 15)
	t.eq("title weight", title.FontFace.Weight, "FontWeight.Bold")
	t.eq("meta size", UI.label(page, "x", { role = "meta" }).TextSize, 11)
	t.eq("emphasis size", UI.label(page, "x", { role = "emphasis" }).TextSize, 13)
	t.eq("2.0 explicit size kept", UI.label(page, "x", { size = 14 }).TextSize, 14)
	local b = UI.button(page, "Buton", nil)
	t.eq("button: control weight", b.FontFace.Weight, "FontWeight.Medium")
	for _, path in VERIFIED.fonts do
		t.check(Theme.FAMILY == "rbxasset://" .. path or Theme.MONO_FAMILY == "rbxasset://" .. path, "font family verified: " .. path)
	end
end)

-- ---------------------------------------------------------------------------------------------
t.section("toggle is a real switch", function()
	clear(page)
	local got = {}
	local b = UI.toggle(page, false, function(v) table.insert(got, v) end, "Mod agent")
	t.eq("text without a check-mark prefix", b.Text, "Mod agent")
	t.eq("state attribute", b:GetAttribute("Checked"), false)
	local track = child(b, "Switch")
	t.check(track ~= nil and child(track, "Knob") ~= nil, "track + knob")
	t.check(track.BackgroundColor3 == C.switchOff, "off track colour")
	click(b)
	t.eq("onChange(not value)", got[1], true)
	t.eq("attribute follows", b:GetAttribute("Checked"), true)
	t.check(track.BackgroundColor3 == C.accent, "on: accent track")
	local s = UI.switch(page, true, function(v) table.insert(got, v) end)
	click(s)
	t.eq("switch flips its own state", got[2], false)
	click(s)
	t.eq("and back", got[3], true)
end)

-- ---------------------------------------------------------------------------------------------
t.section("section: flat, collapsible, remembered", function()
	clear(page)
	local saves, toggled = 0, nil
	UI.onCollapse = function() saves += 1 end
	UI.collapsed["t.sec"] = nil
	local body = UI.section(page, "Mișcare", { key = "t.sec", onToggle = function(c) toggled = c end, badge = 3 })
	local frame = body.Parent
	local head = child(frame, "Header")
	t.check(child(frame, "Divider") ~= nil, "a divider, not a card")
	t.check(frame.BackgroundTransparency == 1, "no filled card")
	t.check(body.Visible == true and UI.collapsed["t.sec"] == false, "open by default")
	local arrow = child(head, "Icon")
	t.eq("chevron down when open", arrow.Rotation, 90)
	t.check(child(head, "Badge") ~= nil, "badge in the header")
	click(head)
	t.check(body.Visible == false and UI.collapsed["t.sec"] == true and toggled == true and saves == 1, "collapsed, saved, told")
	t.eq("chevron right when closed", arrow.Rotation, 0)
	local again = UI.section(page, "Mișcare", { key = "t.sec" })
	t.check(again.Visible == false, "the state survives a re-render")
	local static = UI.section(page, "Grup", { collapsible = false })
	click(child(static.Parent, "Header"))
	t.check(static.Visible == true and child(child(static.Parent, "Header"), "Icon") == nil, "collapsible = false: no chevron, stays open")
	UI.onCollapse = nil
end)

-- ---------------------------------------------------------------------------------------------
t.section("dropdown: menu inside the window, check mark, Escape, outside click", function()
	clear(page)
	local picked = {}
	local items = { { header = true, label = "Lumini" }, { value = "a", label = "Punct", classIcon = "PointLight" },
		{ separator = true }, { value = "b", label = "Spot" } }
	local b = UI.dropdown(page, items, "a", function(v) table.insert(picked, v) end)
	t.eq("shows the chosen label", b.Text, "Punct")
	t.check(child(b, "Icon") ~= nil, "chevron / item icon images")
	-- an anchor near the bottom of a 360 x 600 window: the menu opens above it
	b.__data.props.AbsolutePosition = env.Vector2.new(20, 560)
	b.__data.props.AbsoluteSize = env.Vector2.new(200, 24)
	click(b)
	t.check(popupOpen() and UI.busy(), "menu open (busy: App holds its redraws)")
	local popup = child(overlay(), "Popup")
	local p, s = popup.Position, popup.Size
	t.check(p.X.Offset >= 8 and p.X.Offset + s.X.Offset <= 352, "inside the window horizontally")
	t.check(p.Y.Offset >= 8 and p.Y.Offset + s.Y.Offset <= 560, "flipped above the anchor, inside the window")
	local rows = all(popup, function(c) return c.ClassName == "TextButton" and (c.Text == "Punct" or c.Text == "Spot") end)
	t.eq("two choices", #rows, 2)
	local chosen = all(popup, function(c) return c.ClassName == "TextButton" and c:GetAttribute("Checked") == true end)
	t.check(#chosen == 1 and chosen[1].Text == "Punct", "check mark on the chosen item")
	t.check(byText(popup, "<uc>Lumini</uc>") ~= nil, "group header")
	click(byText(popup, "Spot"))
	t.check(picked[1] == "b" and not popupOpen(), "pick -> onChange, menu closed")
	-- Escape on the overlay (input over the window), Escape from UserInputService, a click outside
	click(b)
	overlay().InputBegan:Fire({ KeyCode = "KeyCode.Escape" })
	t.check(not popupOpen(), "Escape closes (window input)")
	click(b)
	UIS.InputBegan:Fire({ KeyCode = "KeyCode.Escape" })
	t.check(not popupOpen(), "Escape closes (UserInputService)")
	click(b)
	click(overlay())
	t.check(not popupOpen() and #picked == 1, "outside click closes without choosing")
	-- many items: a filter box
	local many = {}
	for i = 1, 20 do
		table.insert(many, { value = i, label = "Element " .. i })
	end
	table.insert(many, { value = 99, label = "Altceva" })
	local big = UI.dropdown(page, many, 1, function(v) table.insert(picked, v) end)
	click(big)
	local search = child(child(overlay(), "Popup"), "Frame") and all(overlay(), function(c) return c.ClassName == "TextBox" end)[1]
	t.check(search ~= nil and search.PlaceholderText == "Filtrează", "filter box when the list is long")
	search.Text = "altc"
	advance(1)
	local visible = all(overlay(), function(c) return c.ClassName == "TextButton" and string.find(c.Text, "Element", 1, true) ~= nil end)
	t.check(#visible == 0 and byText(overlay(), "Altceva") ~= nil, "filter keeps only matches")
	click(byText(overlay(), "Altceva"))
	t.eq("pick after filtering", picked[2], 99)
end)

-- ---------------------------------------------------------------------------------------------
t.section("menu and icon buttons", function()
	clear(page)
	local log = {}
	local anchor = UI.iconButton(page, "more", function() end, { tip = "Mai multe" })
	t.eq("icon button name", anchor.Name, "IconButton_more")
	local img = child(anchor, "Icon")
	t.check(img and img.Image == Icons.BASE .. Icons.GLYPHS.more, "glyph image")
	t.check(img.ImageColor3 == C.textDim, "glyph tinted from the theme")
	UI.menu(anchor, { { label = "Duplică", icon = "duplicate", onClick = function() table.insert(log, "dup") end },
		{ separator = true }, { label = "Șterge", danger = true, onClick = function() table.insert(log, "del") end },
		{ label = "Indisponibil", disabled = true, onClick = function() table.insert(log, "no") end } })
	t.check(popupOpen(), "menu open")
	click(byText(overlay(), "Indisponibil"))
	t.check(#log == 0 and popupOpen(), "disabled item does nothing")
	click(byText(overlay(), "Șterge"))
	t.check(log[1] == "del" and not popupOpen(), "item runs and closes")
	local active = UI.iconButton(page, "eye", function() end, { active = true })
	t.eq("active attribute", active:GetAttribute("Active"), true)
	t.check(child(active, "Icon").ImageColor3 == C.accent, "active glyph in the accent")
end)

-- ---------------------------------------------------------------------------------------------
t.section("number field and scrub", function()
	clear(page)
	local got = {}
	local box = UI.number(page, 1, function(v) table.insert(got, v) end, { min = 0, max = 5, step = 0.5 })
	box.Text = "2,5"
	box.FocusLost:Fire()
	t.eq("comma decimal", got[1], 2.5)
	box.Text = "99"
	box.FocusLost:Fire()
	t.eq("clamped to max", got[2], 5)
	got = {}
	local live = {}
	local row, sbox = UI.scrub(page, "Durată", 1, function(v) table.insert(got, v) end, { min = 0, max = 3, step = 0.1,
		onInput = function(v) table.insert(live, v) end, unit = "s" })
	local handle = child(row, "ScrubHandle")
	t.eq("label is the handle", handle.Text, "Durată")
	local catcher = child(root, "DragCatcher")
	handle.InputBegan:Fire(input("MouseButton1", 100, 5))
	t.check(catcher.Visible == true and UI.busy(), "drag catcher shown, busy")
	catcher.InputChanged:Fire(input("MouseMovement", 105, 5))
	t.eq("5 px = 5 steps", sbox.Text, "1.5")
	catcher.InputChanged:Fire(input("MouseMovement", 150, 5))
	t.eq("clamped while dragging", sbox.Text, "3")
	catcher.InputChanged:Fire(input("MouseMovement", 108, 5))
	t.check(#live == 3 and #got == 0, "live updates, no commit yet")
	catcher.InputEnded:Fire(input("MouseButton1", 108, 5))
	t.check(#got == 1 and math.abs(got[1] - 1.8) < 1e-9 and catcher.Visible == false, "one commit on release: " .. tostring(got[1]))
	t.check(not UI.busy(), "not busy after the drag")
	-- Shift = fine (step / 10)
	local fine = input("MouseButton1", 100, 5)
	fine.mods = { ["ModifierKey.Shift"] = true }
	handle.InputBegan:Fire(fine)
	catcher.InputChanged:Fire(input("MouseMovement", 103, 5))
	catcher.InputEnded:Fire(input("MouseButton1", 103, 5))
	t.check(math.abs(got[2] - 1.83) < 1e-9, "Shift: fine steps: " .. tostring(got[2]))
	-- a press without movement commits nothing
	handle.InputBegan:Fire(input("MouseButton1", 100, 5))
	catcher.InputEnded:Fire(input("MouseButton1", 100, 5))
	t.eq("no change, no commit", #got, 2)
end)

-- ---------------------------------------------------------------------------------------------
t.section("slider", function()
	clear(page)
	local got, live = {}, {}
	local frame = UI.slider(page, 0.2, function(v) table.insert(got, v) end, { onInput = function(v) table.insert(live, v) end })
	local hit = child(frame, "Hit")
	local track = child(hit, "Track")
	track.__data.props.AbsolutePosition = env.Vector2.new(10, 0)
	track.__data.props.AbsoluteSize = env.Vector2.new(200, 4)
	local fill = child(track, "Fill")
	t.near("initial fill", fill.Size.X.Scale, 0.2, 1e-9)
	hit.InputBegan:Fire(input("MouseButton1", 110, 2))
	t.near("press sets the value", live[1], 0.5, 1e-9)
	local catcher = child(root, "DragCatcher")
	catcher.InputChanged:Fire(input("MouseMovement", 400, 2))
	t.near("clamped to max", live[2], 1, 1e-9)
	catcher.InputEnded:Fire(input("MouseButton1", 400, 2))
	t.check(#got == 1 and math.abs(got[1] - 1) < 1e-9, "one commit on release")
	local withField = UI.slider(page, 1, function(v) table.insert(got, v) end, { min = 0, max = 3, step = 0.5, field = true })
	local box = all(withField, function(c) return c.ClassName == "TextBox" end)[1]
	box.Text = "2"
	box.FocusLost:Fire()
	t.eq("typed value commits", got[2], 2)
end)

-- ---------------------------------------------------------------------------------------------
t.section("search", function()
	clear(page)
	local got = {}
	local frame, box = UI.search(page, "", function(v) table.insert(got, v) end)
	t.eq("placeholder", box.PlaceholderText, "Caută")
	local clearButton = child(frame, "IconButton_close")
	t.check(clearButton.Visible == false, "no clear button while empty")
	box.Text = "nin"
	t.check(clearButton.Visible == true and #got == 0, "clear button shows; the change waits")
	advance(0.2)
	t.eq("debounced change", got[1], "nin")
	box.Text = "ninj"
	box.Text = "ninja"
	advance(0.2)
	t.check(#got == 2 and got[2] == "ninja", "typing quickly sends once")
	click(clearButton)
	t.check(box.Text == "" and got[3] == "", "clear")
end)

-- ---------------------------------------------------------------------------------------------
t.section("colour picker", function()
	clear(page)
	table.clear(UI.recentColors)
	local saved
	UI.onRecentColors = function(list) saved = table.clone(list) end
	local got, live = {}, {}
	local b = UI.color(page, Color3.fromRGB(255, 0, 0), function(c) table.insert(got, c) end, { onInput = function(c) table.insert(live, c) end })
	t.eq("hex text", b.Text, "#FF0000")
	click(b)
	local popup = child(overlay(), "Popup")
	t.check(popup ~= nil and child(popup, "SV") ~= nil and child(popup, "Hue") ~= nil, "square + hue strip")
	local hex = all(popup, function(c) return c.ClassName == "TextBox" end)[1]
	t.eq("hex field", hex.Text, "#FF0000")
	hex.Text = "#00ff00"
	hex.FocusLost:Fire()
	t.check(#got == 1 and got[1] == Color3.fromRGB(0, 255, 0), "hex commits")
	t.check(UI.recentColors[1] == "00FF00" and saved and saved[1] == "00FF00", "recent colour remembered and saved")
	-- drag in the square: right edge, middle height -> full saturation, half value
	local square = child(popup, "SV")
	square.__data.props.AbsoluteSize = env.Vector2.new(200, 100)
	square.InputBegan:Fire(input("MouseButton1", 200, 50))
	t.check(#live == 1 and math.abs(live[1].G - 0.5) < 0.02 and live[1].R < 0.01, "live colour while dragging")
	child(root, "DragCatcher").InputEnded:Fire(input("MouseButton1", 200, 50))
	t.eq("drag end commits once", #got, 2)
	UI.closePopup()
	click(b)
	t.check(byText(child(overlay(), "Popup"), "<uc>Recente</uc>") ~= nil, "recent swatches row")
	UI.closePopup()
	-- HSV round trip
	for _, c in { Color3.fromRGB(255, 138, 61), Color3.fromRGB(12, 200, 99), Color3.fromRGB(80, 80, 80), Color3.new(0, 0, 0) } do
		local back = UI.fromHSV(UI.toHSV(c))
		t.check(math.abs(back.R - c.R) < 1e-6 and math.abs(back.G - c.G) < 1e-6 and math.abs(back.B - c.B) < 1e-6, "HSV round trip")
	end
	UI.onRecentColors = nil
end)

-- ---------------------------------------------------------------------------------------------
t.section("toasts", function()
	local host = child(root, "Toasts")
	t.check(host ~= nil, "toast host at the bottom of the window")
	clear(host)
	local acted = 0
	local a = UI.toast("Efectul a fost salvat.", "success", { action = { text = "Anulează", onClick = function() acted += 1 end } })
	t.eq("kind", a.frame:GetAttribute("Kind"), "success")
	t.check(byText(a.frame, "Efectul a fost salvat.") ~= nil, "text")
	local icon = child(a.frame, "Icon")
	t.check(icon and string.find(icon.Image, "Shared/Alerts/" .. Theme.name .. "/Standard/Success.png", 1, true) ~= nil, "kind icon")
	advance(3.9)
	t.check(a.frame.Parent == host, "still there before 4 s")
	advance(0.2)
	t.check(a.frame.Parent == nil, "gone after 4 s")
	local b = UI.toast("Cu acțiune", "info", { action = { text = "Anulează", onClick = function() acted += 1 end }, duration = 0 })
	click(byText(b.frame, "Anulează"))
	t.check(acted == 1 and b.frame.Parent == nil, "action runs and dismisses")
	local e = UI.toast("Eroare", "error")
	advance(5)
	t.check(e.frame.Parent == host, "errors stay longer")
	click(child(e.frame, "IconButton_close"))
	t.check(e.frame.Parent == nil, "close button")
	local list = {}
	for i = 1, 4 do
		list[i] = UI.toast("T" .. i, "warning", { duration = 0 })
	end
	t.check(list[1].frame.Parent == nil and list[4].frame.Parent == host, "at most three at a time (the oldest goes)")
	t.eq("unknown kind -> info", UI.toast("x", "weird", { duration = 0 }).frame:GetAttribute("Kind"), "info")
	clear(host)
end)

-- ---------------------------------------------------------------------------------------------
t.section("confirm", function()
	local done, cancelled = 0, 0
	local function open()
		return UI.confirm("Ștergi efectul?", "Se poate anula cu Ctrl+Z.", "Șterge", function() done += 1 end,
			{ danger = true, onCancel = function() cancelled += 1 end })
	end
	local dialog = open()
	t.check(popupOpen() and child(overlay(), "Scrim") ~= nil and dialog.Name == "Dialog", "modal with a scrim")
	click(byText(dialog, "Șterge"))
	t.check(done == 1 and not popupOpen(), "confirm")
	dialog = open()
	click(byText(dialog, "Anulează"))
	t.check(cancelled == 1 and done == 1 and not popupOpen(), "cancel button")
	open()
	overlay().InputBegan:Fire({ KeyCode = "KeyCode.Escape" })
	t.eq("Escape cancels", cancelled, 2)
	open()
	click(overlay())
	t.check(cancelled == 3 and done == 1, "a click outside cancels")
end)

-- ---------------------------------------------------------------------------------------------
t.section("empty, progress, badge, chip, divider, header", function()
	clear(page)
	local acted = 0
	local e = UI.empty(page, "Niciun efect încă.", "Efect nou", function() acted += 1 end, { icon = "effects", title = "Gol" })
	t.check(byText(e, "Niciun efect încă.") ~= nil and byText(e, "Gol") ~= nil, "sentence + title")
	click(byText(e, "Efect nou"))
	t.eq("one primary action", acted, 1)
	local quiet = UI.empty(page, "Nimic.")
	t.eq("no action -> no button", #all(quiet, function(c) return c.ClassName == "TextButton" end), 0)
	local track, set = UI.progress(page, 0.25)
	local fill = child(track, "Fill")
	t.near("fraction", fill.Size.X.Scale, 0.25, 1e-9)
	set(2)
	t.near("clamped", fill.Size.X.Scale, 1, 1e-9)
	t.check(UI.badge(page, "3", "danger").BackgroundColor3 == C.dangerSoft, "danger badge on the soft tint")
	t.check(UI.badge(page, "nou", "accent").TextColor3 == C.accentText, "accent badge")
	local removed = 0
	local chip = UI.chip(page, "Luptă", { selected = true, onRemove = function() removed += 1 end })
	t.eq("chip state", chip:GetAttribute("Selected"), true)
	click(child(chip, "IconButton_close"))
	t.eq("chip remove", removed, 1)
	t.check(UI.divider(page).Size.Y.Offset == 1, "1 px divider")
	local header = UI.header(page, "Efecte", { subtitle = "5 efecte", actions = { { icon = "plus", tip = "Nou", onClick = function() acted += 1 end } } })
	t.check(byText(header, "Efecte").TextSize == 15, "title 15 px")
	click(all(header, function(c) return c.Name == "IconButton_plus" end)[1])
	t.eq("header action", acted, 2)
end)

-- ---------------------------------------------------------------------------------------------
t.section("tabs: six tabs, compaction by width", function()
	clear(page)
	local tabs = { { key = "Game", label = "Joc", icon = "game" }, { key = "VFX", label = "Efecte", icon = "effects" },
		{ key = "Anim", label = "Animații", icon = "animation" }, { key = "Library", label = "Bibliotecă", icon = "library" },
		{ key = "Build", label = "Modelare", icon = "build" }, { key = "Claude", label = "Claude", icon = "chat" } }
	t.eq("wide window: every label", UI.tabsMode(640, tabs), "full")
	t.eq("dock width: only the open tab's label", UI.tabsMode(360, tabs), "compact")
	t.eq("very narrow: icons only", UI.tabsMode(220, tabs), "icons")
	local picked
	local nav = UI.tabs(page, tabs, "VFX", function(k) picked = k end, { mode = "compact" })
	local buttons = all(nav, function(c) return c.ClassName == "TextButton" end)
	t.eq("six tabs", #buttons, 6)
	local open = child(nav, "Tab_VFX")
	t.check(open:GetAttribute("Selected") == true and child(open, "Indicator") ~= nil, "open tab: indicator line")
	t.check(byText(open, "Efecte") ~= nil and byText(child(nav, "Tab_Library"), "Bibliotecă") == nil, "compact: only the open tab has a label")
	for _, b in buttons do
		t.check(#all(b, function(c) return c.ClassName == "ImageLabel" end) == 1, "a glyph on every tab")
	end
	click(child(nav, "Tab_Build"))
	t.eq("click", picked, "Build")
	local full = UI.tabs(page, tabs, "Game", function() end, { mode = "full" })
	t.check(byText(full, "Bibliotecă") ~= nil and byText(full, "Modelare") ~= nil, "full: every label")
end)

-- ---------------------------------------------------------------------------------------------
t.section("theme: built-in palettes, live re-skin", function()
	t.eq("outside Studio: the built-in dark palette", Theme.name, "Dark")
	local T = Theme.tokens
	for _, token in { "bg", "surface", "surfaceHover", "border", "text", "textDim", "textDisabled", "accent", "accentText",
		"danger", "warning", "success", "focus", "field", "divider", "accentSoft", "raised", "raisedStrong" } do
		t.check(isColor(T[token]), "token " .. token)
	end
	local cTable = UI.C
	local label = UI.label(page, "Re-skin")
	local darkText = T.text
	local changes = 0
	local conn = Theme.onChanged(function() changes += 1 end)
	Theme.force("Light")
	t.eq("forced light", Theme.name, "Light")
	t.check(T.bg == Color3.fromRGB(255, 255, 255) and T.text ~= darkText, "light tokens")
	t.check(UI.C == cTable and C.bg == T.bg and C.dim == T.textDim, "UI.C updated in place")
	t.check(label.TextColor3 == T.text, "a bound label re-skinned")
	t.eq("listener told", changes, 1)
	conn:Disconnect()
	-- a fake Studio: every colour comes from Theme:GetColor, ThemeChanged re-skins
	local asked = {}
	local studioColors = { ["StudioStyleGuideColor.MainBackground"] = Color3.fromRGB(30, 31, 32),
		["StudioStyleGuideColor.MainText"] = Color3.fromRGB(220, 221, 222),
		["StudioStyleGuideColor.MainButton"] = Color3.fromRGB(10, 120, 250) }
	local themeChanged = signal()
	local studioTheme = { GetColor = function(_, color, modifier)
		table.insert(asked, tostring(color) .. "/" .. tostring(modifier))
		return studioColors[color] or Color3.fromRGB(100, 100, 100)
	end }
	fakeSettings = { Studio = { Theme = studioTheme, ThemeChanged = themeChanged } }
	Theme.force(nil)
	t.check(T.bg == Color3.fromRGB(30, 31, 32) and T.text == Color3.fromRGB(220, 221, 222), "tokens from Studio's theme")
	t.check(T.accent == Color3.fromRGB(10, 120, 250) and C.accent == T.accent, "accent = Studio's main button")
	t.eq("dark Studio background -> dark", Theme.name, "Dark")
	local sawHover = false
	for _, a in asked do
		if a == "StudioStyleGuideColor.Item/StudioStyleGuideModifier.Hover" then sawHover = true end
	end
	t.check(sawHover, "modifiers are asked (Item / Hover)")
	Theme.watch()
	t.eq("one ThemeChanged connection", themeChanged:live(), 1)
	Theme.watch()
	t.eq("watch is idempotent", themeChanged:live(), 1)
	studioColors["StudioStyleGuideColor.MainBackground"] = Color3.fromRGB(250, 250, 250)
	studioColors["StudioStyleGuideColor.MainText"] = Color3.fromRGB(20, 20, 20)
	themeChanged:Fire()
	t.check(Theme.name == "Light" and label.TextColor3 == Color3.fromRGB(20, 20, 20), "Studio switched to light: re-skinned live")
	-- a colour the theme cannot give falls back to the palette
	studioTheme.GetColor = function() error("no such colour") end
	Theme.refresh()
	t.check(isColor(T.bg) and isColor(T.accent), "GetColor failing -> built-in palette")
	UI.release()
	t.eq("release disconnects ThemeChanged", themeChanged:live(), 0)
	fakeSettings = nil
	Theme.force("Dark")
	Theme.force(nil)
	UI.setRoot(root)
end)

-- ---------------------------------------------------------------------------------------------
t.section("icons: verified Studio paths, class icons", function()
	local verified = {}
	for _, p in VERIFIED.studio_svg_textures do
		verified[p] = true
	end
	local count = 0
	for name, path in Icons.GLYPHS do
		count += 1
		t.check(verified[path] == true, "glyph " .. name .. " is in the verified list: " .. path)
		local icon = Icons.get(name)
		t.check(icon.Image == "rbxasset://studio_svg_textures/" .. path and icon.tint == true, "get(" .. name .. ")")
	end
	t.check(count >= 40, "glyph set: " .. count)
	for _, needed in { "chevronRight", "chevronDown", "play", "pause", "stop", "plus", "close", "more", "search", "eye", "eyeOff",
		"copy", "refresh", "check", "warningColor", "info", "gear", "undo" } do
		t.check(Icons.get(needed) ~= nil, "needed glyph " .. needed)
	end
	for name, pattern in Icons.COLORED do
		for _, theme in { "Dark", "Light" } do
			t.check(verified[string.format(pattern, theme)] == true, "coloured " .. name .. " (" .. theme .. ") verified")
		end
	end
	for class, file in Icons.CLASSES do
		for _, theme in { "Dark", "Light" } do
			t.check(verified["Shared/InsertableObjects/" .. theme .. "/Standard/" .. file .. ".png"] == true, "class fallback " .. class)
		end
	end
	for _, theme in { "Dark", "Light" } do
		t.check(verified[string.format(Icons.TOOLBAR, theme)] == true, "toolbar icon (" .. theme .. ")")
	end
	t.check(string.find(Icons.toolbar(), "rbxasset://studio_svg_textures/", 1, true) == 1, "toolbar icon path")
	t.check(Icons.get("sparkles") == nil and not Icons.has("✨"), "no emoji names")
	-- no StudioService here: the verified files
	local trail = Icons.class("Trail")
	t.eq("class fallback", trail.Image, "rbxasset://studio_svg_textures/Shared/InsertableObjects/" .. Theme.name .. "/Standard/Trail.png")
	t.eq("unknown class -> placeholder", Icons.class("NoSuchClass").Image, Icons.BASE .. Icons.GLYPHS.placeholder)
	-- with StudioService: its dictionary as is
	local env2 = LC.env()
	LC.run("tests/mocks/gui.luau", env2)
	local calls = 0
	local rect = env2.Vector2.new(32, 16)
	local studio = { GetClassIcon = function(_, className)
		calls += 1
		if className == "Broken" then error("nope") end
		return { Image = "rbxasset://textures/ClassImages.PNG", ImageRectOffset = rect, ImageRectSize = env2.Vector2.new(16, 16) }
	end }
	env2.game = { GetService = function(_, n) return n == "StudioService" and studio or error("no service " .. n) end }
	local Icons2 = LC.modtree.new{ env = env2 }.load("Icons")
	local fx = Icons2.class("ParticleEmitter")
	t.check(fx.Image == "rbxasset://textures/ClassImages.PNG" and fx.ImageRectOffset == rect and fx.tint == false, "StudioService:GetClassIcon used")
	Icons2.class("ParticleEmitter")
	t.eq("cached", calls, 1)
	t.check(string.find(Icons2.class("Broken").Image, "Placeholder", 1, true) ~= nil, "an error -> fallback")
	-- glyphs drawn from frames
	local holder = Icons.draw(page, "cube", 16, C.text)
	t.eq("cube mark: 9 edges", #holder:GetChildren(), 9)
	t.eq("unknown drawing -> empty", #Icons.draw(page, "nothing", 16, C.text):GetChildren(), 0)
	t.check(Icons.drawable("check") and not Icons.drawable("nothing"), "drawable")
end)

t.eq("no mock errors at the end", #MOCK_ERRORS, 0)
for _, e in MOCK_ERRORS do print("  mock error:", e) end
t.finish()
