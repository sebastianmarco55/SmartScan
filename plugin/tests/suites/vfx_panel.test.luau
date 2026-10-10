-- VFXPanel (the real panel) on the typed Roblox mock with a fake UI kit: both creation buttons, the grouped
-- "add element" menu (every preset reachable), the template builder (picker, colour, scale, name, errors, every template
-- created from the panel), the free-VFX import flow (pasted Creator Store address, rich text escaped in names, failure
-- messages, import from the selection) and the texture picker.
local LC = ...
local t = LC.kit.new("vfx_panel")
local function check(cond, msg)
	t.check(cond, msg)
end

local ENV = LC.run("tests/mocks/api_env.luau", nil, LC)
local Color3 = ENV.Color3
local Editor = LC.load("LostCube/Editor/init.luau", ENV)()
local history = ENV.__history
local build = ENV.freeModel

-- the panel starts from an existing effect with a particle element
do
	local first = Editor.newEffect("Primul", { duration = 1 })
	Editor.addElement(first, "SPARKLES")
end
local HEAL_MAIN
for _, tpl in Editor.TEMPLATES do
	if tpl.key == "HEAL" then
		HEAL_MAIN = tpl.main
	end
end
check(HEAL_MAIN ~= nil, "template HEAL exists")

local C3 = Color3
local TREE
local function node(kind, parent, fields)
	local n = fields or {}
	n.kind, n.children, n.parent = kind, {}, parent
	n.CaptureFocus = function() end
	if parent then table.insert(parent.children, n) end
	return n
end
local fakeUI = { C = { bg = C3.new(), section = C3.new(), header = C3.new(), item = C3.new(), hover = C3.new(), input = C3.new(),
	border = C3.new(), text = C3.new(), dim = C3.new(), accent = C3.new(), accentHover = C3.new(), accentDark = C3.new(),
	good = C3.fromRGB(0, 255, 0), danger = C3.new(), warn = C3.fromRGB(255, 200, 0) } }
fakeUI.fmt = function(v) return tostring(v) end
function fakeUI.label(p, text, o) return node("label", p, { Text = text }) end
function fakeUI.button(p, text, click, o) return node("button", p, { Text = text, click = click, opts = o or {} }) end
function fakeUI.hstack(p) return node("hstack", p) end
function fakeUI.vstack(p) return node("vstack", p) end
function fakeUI.row(p, text) return node("row", p, { label = text }) end
function fakeUI.number(p, v, f, o) return node("number", p, { Text = tostring(v), value = v, change = f, opts = o }) end
function fakeUI.textbox(p, v, f, o) return node("textbox", p, { Text = v or "", change = f, opts = o }) end
function fakeUI.toggle(p, v, f, text) return node("toggle", p, { Text = text, change = f, value = v }) end
function fakeUI.segmented(p, items, v, f) return node("segmented", p, { items = items, value = v, change = f }) end
function fakeUI.dropdown(p, items, v, f, o) return node("dropdown", p, { items = items, value = v, change = f, opts = o }) end
function fakeUI.color(p, c, f, o) return node("color", p, { value = c, change = f }) end
function fakeUI.section(p, title, o) return node("section", p, { title = title, opts = o }) end
function fakeUI.item(p, text, o) return node("item", p, { Text = text, opts = o }) end
function fakeUI.scrollList(p) return node("scroll", p) end
function fakeUI.note(p, text, color) return node("note", p, { Text = text, color = color }) end
function fakeUI.spacer(p) return node("spacer", p) end
local function walk(n, fn) fn(n); for _, c in n.children do walk(c, fn) end end
local function find(pred) local out = {}; walk(TREE, function(n) if pred(n) then table.insert(out, n) end end); return out end
local function button(text) local f = find(function(n) return n.kind == "button" and n.Text == text end); assert(#f == 1, "button '" .. text .. "' x" .. #f); return f[1] end
local function hasButton(text) return #find(function(n) return n.kind == "button" and n.Text == text end) > 0 end
local function notes() local t = {}; walk(TREE, function(n) if n.kind == "note" then table.insert(t, n.Text) end end); return table.concat(t, "\n") end


-- the real VFXPanel with a fake UI kit (it records widgets as plain nodes) and the typed Roblox mock
local deferred = {}
local penv = {}
for k, v in ENV do
	penv[k] = v
end
penv.task = {
	defer = function(f, ...) table.insert(deferred, { f, ... }) end,
	spawn = function(f, ...) local co = coroutine.create(f); assert(coroutine.resume(co, ...)); return co end,
	delay = function() end, wait = function() return 0 end,
}
local tree = LC.modtree.new{ env = penv, mocks = { UI = fakeUI, Installer = { status = function() return { ok = true } end, install = function() end } } }
local Panel = tree.load("VFXPanel")

local played = 0
Editor.preview = function() played += 1; return { Done = false, Destroy = function() end, Pause = function() end, Resume = function() end } end
local ctx = { Editor = Editor }
local panel = Panel.new(ctx)
local renders = 0
local function render()
	TREE = node("root", nil)
	local ok, e = pcall(function() panel:render(TREE) end)
	check(ok, "render failed: " .. tostring(e))
	renders += 1
end
ctx.app = { refresh = function() render() end }
local function flush() local q = deferred; deferred = {}; for _, d in q do d[1](table.unpack(d, 2)) end end
local function lines(report) return table.concat(report.lines, " / ") end

render()
check(hasButton("+ Efect nou") and hasButton("+ Din șablon"), "both creation buttons exist")
check(#find(function(n) return n.kind == "section" and n.title:find("Importă VFX gratuit") end) == 1, "import section exists")

-- add-element dropdown: grouped, icon + label, nothing lost
local fxs = Editor.effects()
panel.effect = fxs[1]
render()
local add = find(function(n) return n.kind == "dropdown" and n.opts and n.opts.text == "+ Adaugă element" end)[1]
check(add ~= nil, "add-element dropdown exists")
local headers, entries, seenKeys = 0, 0, {}
for _, item in add.items do
	if item.header then headers += 1 else entries += 1; if item.value then seenKeys[item.value] = true end end
end
for _, p in Editor.PRESETS do check(seenKeys[p.key], "preset in the add menu: " .. p.key) end
local presetGroups, groupSeen = 0, {}
for _, p in Editor.PRESETS do
	if not groupSeen[p.group] then
		groupSeen[p.group] = true
		presetGroups += 1
	end
end
check(headers >= presetGroups, "grouped add menu: " .. headers .. " headers for " .. presetGroups .. " preset groups")
check(add.items[1].header == true and add.items[2].label:find("  ", 1, true) ~= nil, "headers first, icons in labels")

-- template flow
button("+ Din șablon").click()
check(panel.templating == true, "template builder opened")
local picker
for _, d in find(function(n) return n.kind == "dropdown" and n.opts and n.opts.menuWidth == 230 end) do picker = d end
check(picker ~= nil, "template picker exists")
local cats = {}
for _, item in picker.items do if item.header then table.insert(cats, item.label) end end
local categories, categorySeen = 0, {}
for _, tpl in Editor.TEMPLATES do
	if not categorySeen[tpl.category] then
		categorySeen[tpl.category] = true
		categories += 1
	end
end
check(#cats == categories, "one header per template category: " .. table.concat(cats, ", "))
check(picker.value == Editor.TEMPLATES[1].key, "first template preselected")
picker.change("HEAL")
check(panel.tplKey == "HEAL", "template chosen")
local colorBox = find(function(n) return n.kind == "color" end)[1]
check(colorBox.value == HEAL_MAIN, "colour defaults to the template's main")
check(not hasButton("↺"), "no reset button before a colour is chosen")
colorBox.change(Color3.fromRGB(255, 80, 0))
check(hasButton("↺"), "reset button after choosing a colour")
local scaleBox = find(function(n) return n.kind == "number" end)[1]
scaleBox.change(1.5)
check(panel.tplScale == 1.5, "scale stored")
local nameBox = find(function(n) return n.kind == "textbox" and n.opts and n.opts.placeholder == "Numele efectului" end)[2] or find(function(n) return n.kind == "textbox" and n.opts and n.opts.placeholder == "Numele efectului" end)[1]
check(nameBox.Text:find("^Vindecare") ~= nil and Editor.folder(false):FindFirstChild(nameBox.Text) == nil, "default name is a free one from the template label: " .. tostring(nameBox.Text))
local before = #Editor.effects()
played = 0
nameBox.Text = "Vindecare focoasă"
button("Creează și redă").click()
flush()
check(#Editor.effects() == before + 1, "effect created from the panel")
check(panel.effect and panel.effect.Name == "Vindecare focoasă", "new effect selected")
check(played == 1, "preview played once (" .. played .. ")")
check(panel.templating == false, "builder closed")
local made = Editor.read(Editor.elements(panel.effect)[1])
check(made ~= nil, "elements readable")
-- recoloured + scaled for real
local sp
for _, el in Editor.elements(panel.effect) do if el.Name == "Sclipiri" then sp = Editor.read(el) end end
local h = sp.color[2]:ToHSV()
check(h < 0.12, "orange recolour applied via the panel: hue " .. tostring(h))

-- duplicate name is shown as an error, builder stays
button("+ Din șablon").click()
local nb = find(function(n) return n.kind == "textbox" and n.opts and n.opts.placeholder == "Numele efectului" end)[1]
nb.Text = "Vindecare focoasă"
button("Creează și redă").click()
check(notes():find("există deja", 1, true) ~= nil, "duplicate name error is shown: " .. notes())
check(panel.templating == true, "builder stays open after an error")
button("×").click()
check(panel.templating == false, "builder closes")

-- every template can be created from the panel
for _, t in Editor.TEMPLATES do
	button("+ Din șablon").click()
	local pk
	for _, d in find(function(n) return n.kind == "dropdown" and n.opts and n.opts.menuWidth == 230 end) do pk = d end
	pk.change(t.key)
	local nb2 = find(function(n) return n.kind == "textbox" and n.opts and n.opts.placeholder == "Numele efectului" end)[1]
	nb2.Text = "Panou " .. t.key
	button("Creează și redă").click()
	flush()
	check(panel.effect and panel.effect.Name == "Panou " .. t.key, "panel created " .. t.key)
end
check(history.active == nil, "recording left open by the panel")

-- the effect panel renders for template effects (elements list, properties of every element)
for _, fx in Editor.effects() do
	panel.effect = fx
	for _, el in Editor.elements(fx) do
		panel.element = el
		render()
	end
end
panel.element = nil

-- import flow
local loadedFor
ENV.game.GetObjects = function(_, url) loadedFor = url; return { build() } end
renders = 0
local importSection = find(function(n) return n.kind == "section" and n.title:find("Importă VFX gratuit") end)[1]
local idBox = find(function(n) return n.kind == "textbox" and n.opts and n.opts.placeholder and n.opts.placeholder:find("ex. 123456789", 1, true) end)[1]
idBox.Text = "nu e un număr"
button("Importă").click()
check(notes():find("Scrie ID", 1, true) ~= nil, "bad id message")
idBox = find(function(n) return n.kind == "textbox" and n.opts and n.opts.placeholder and n.opts.placeholder:find("ex. 123456789", 1, true) end)[1]
idBox.Text = "https://create.roblox.com/store/asset/4242/Super-VFX"
local nm = find(function(n) return n.kind == "textbox" and n.opts and n.opts.placeholder == "gol = Import <ID>" end)[1]
nm.Text = "Import <b>din magazin</b>"
local n0 = #Editor.effects()
button("Importă").click()
check(loadedFor == "rbxassetid://4242", "asset id taken from the pasted address: " .. tostring(loadedFor))
check(#Editor.effects() == n0 + 1 and panel.effect.Name == "Import <b>din magazin</b>", "imported effect is selected")
check(panel.importing == false and panel.importReport and panel.importReport.ok, "import finished")
local shown = notes()
check(shown:find("Scripturi șterse: 3", 1, true) ~= nil, "report shows the removed scripts")
check(shown:find("&lt;b&gt;", 1, true) ~= nil and shown:find("<b>", 1, true) == nil, "rich text in names is escaped")
-- failure is shown
ENV.game.GetObjects = function() error("HTTP 403") end
ENV.__services.InsertService.LoadAsset = function() error("403") end
find(function(n) return n.kind == "textbox" and n.opts and n.opts.placeholder and n.opts.placeholder:find("ex. 123456789", 1, true) end)[1].Text = "99"
find(function(n) return n.kind == "textbox" and n.opts and n.opts.placeholder == "gol = Import <ID>" end)[1].Text = ""
button("Importă").click()
check(notes():find("Nu am putut încărca", 1, true) ~= nil, "import failure shown: " .. notes())
-- import from the selection
local src = build()
ENV.__services.Selection.Get = function() return { src } end
local target = Editor.newEffect("Pentru selecție", { duration = 1 })
panel.effect = target
render()
button("Din selecție").click()
check(#Editor.elements(target) == 8 and panel.importReport.ok, "import from the selection: " .. lines(panel.importReport))
ENV.__services.Selection.Get = function() return {} end
render()
button("Din selecție").click()
check(notes():find("Selectează în Explorer", 1, true) ~= nil, "nothing selected message")
panel.effect = nil
render()
button("Din selecție").click()
check(notes():find("Alege mai întâi un efect", 1, true) ~= nil, "no effect chosen message")

-- texture picker: grouped, current texture shown
panel.effect = Editor.effects()[1]
for _, el in Editor.elements(panel.effect) do
	if Editor.kindOf(el) == "PARTICLES" then panel.element = el; break end
end
render()
local tex
for _, d in find(function(n) return n.kind == "dropdown" end) do
	for _, item in d.items do if item.value == "CUSTOM" then tex = d end end
end
check(tex ~= nil, "texture dropdown")
local th = {}
for _, item in tex.items do if item.header then table.insert(th, item.label) end end
local textureGroups, textureSeen = 0, {}
for _, tex in Editor.TEXTURES do
	if not textureSeen[tex.group] then
		textureSeen[tex.group] = true
		textureGroups += 1
	end
end
check(#th >= textureGroups, "a header per texture group (" .. textureGroups .. ") + custom: " .. table.concat(th, " | "))
local keys = {}
for _, item in tex.items do if item.value then keys[item.value] = true end end
for _, t in Editor.TEXTURES do check(keys[t.key], "texture in picker " .. t.key) end
check(renders > 0, "the panel rendered")

t.finish()
