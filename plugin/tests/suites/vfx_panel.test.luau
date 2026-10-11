-- VFXPanel (the real panel) on the typed Roblox mock with a fake UI kit (tests/mocks/vfx_fake_ui.luau): no emoji or symbol
-- glyphs anywhere; the effects list (search filtered in place, duplicate with undo, delete through a confirmation), the
-- grouped "add element" menu (every preset reachable, class icons), the template builder (picker, colour, scale, name,
-- errors as toasts, every template created from the panel), share codes (live description, import with a free name,
-- libraries, damaged codes, the library and effect codes), the colour / scale / variant tools ("match the map"
-- suggestions from the stored analysis), the timeline strip (lanes, marks, selection) and its playhead (one Heartbeat
-- connection, none while paused / stopped / destroyed), the free-VFX import flow (pasted Creator Store address, rich text
-- escaped, failures, import from the selection) and the texture picker.
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
local typeof = ENV.typeof
local F = LC.run("tests/mocks/vfx_fake_ui.luau", nil, { Color3 = Color3, typeof = typeof })
local find, button, hasButton = F.find, F.button, F.hasButton

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

-- the real VFXPanel with the fake kit and the typed Roblox mock; a RunService whose Heartbeat we fire
local deferred = {}
local penv = {}
for k, v in ENV do
	penv[k] = v
end
penv.Enum = F.globals(penv)
penv.task = {
	defer = function(f, ...) table.insert(deferred, { f, ... }) end,
	spawn = function(f, ...) local co = coroutine.create(f); assert(coroutine.resume(co, ...)); return co end,
	delay = function() end, wait = function() coroutine.yield(); return 0.05 end,
}
local heartbeat = F.signal()
local services = ENV.__services
services.RunService = services.RunService or {}
services.RunService.Heartbeat = heartbeat
local undos = 0
services.ChangeHistoryService.Undo = function() undos += 1 end
local report -- what Analyzer.load() returns (the analysis of the Game tab)
local clock = 100 -- os.clock of the panel (the env is copied when the module loads: set before)
penv.os = setmetatable({ clock = function() return clock end }, { __index = os })
local tree = LC.modtree.new{ env = penv, mocks = { UI = F.UI, Installer = { status = function() return { ok = true } end,
	install = function() end }, Analyzer = { load = function() return report end } } }
local Panel = tree.load("VFXPanel")

local played = 0
Editor.preview = function()
	played += 1
	return { Done = false, start = clock, speed = 1, Destroy = function(h) h.Done = true end, Pause = function(h) h.pausedAt = clock end,
		Resume = function(h) h.start += clock - h.pausedAt; h.pausedAt = nil end }
end
local ctx = { Editor = Editor }
local panel = Panel.new(ctx)
local renders = 0
local function render()
	F.reset()
	local ok, e = pcall(function() panel:render(F.root) end)
	check(ok, "render failed: " .. tostring(e))
	renders += 1
end
ctx.app = { refresh = function() render() end }
local function flush() local q = deferred; deferred = {}; for _, d in q do d[1](table.unpack(d, 2)) end end
local function toastsWith(needle)
	local n = 0
	for _, toast in F.toasts do
		if string.find(toast.text, needle, 1, true) then
			n += 1
		end
	end
	return n
end
local function notes() local out = {}; for _, n in F.all("note") do table.insert(out, n.Text) end; return table.concat(out, "\n") end
local function noSymbols(where)
	for _, s in F.text() do
		local bad = F.symbolIn(s)
		check(bad == nil, where .. ": no emoji / symbol glyph (" .. tostring(bad) .. ") in " .. string.format("%q", s))
	end
end
-- design.md: one primary action per view
local function onePrimary(where)
	local list = {}
	for _, n in F.find(function(n) return (n.kind == "button" or n.kind == "dropdown") and n.opts and n.opts.style == "primary" end) do
		table.insert(list, tostring(n.Text or n.opts.text))
	end
	check(#list <= 1, where .. ": at most one primary action, got " .. table.concat(list, ", "))
end
local function sectionTitles() local out = {}; for _, s in F.all("section") do table.insert(out, s.title) end; return out end

render()
check(hasButton("Efect nou") and hasButton("Din șablon"), "both creation buttons exist")
check(button("Efect nou").opts.style == "primary" and button("Efect nou").opts.icon == "plus", "Efect nou: the primary action, plus glyph")
check(F.section("Import și export") ~= nil, "import / export section exists")
check(#F.all("search") == 1 and F.all("search")[1].opts.placeholder == "Caută efecte", "the effects list has a search field")
check(F.section("Efecte").opts.badge == #Editor.effects(), "effect count in the section badge, not in the title")
noSymbols("first render")
onePrimary("first render")

-- the effects list: one row per effect with the effects glyph, actions as glyphs with tips -----------------------------
local fxs = Editor.effects()
panel.effect = fxs[1]
render()
check(button("Efect nou").opts.style ~= "primary", "while an effect is edited, Efect nou is not the primary action")
local rows = F.all("item")
local effectRows = F.find(function(n) return n.kind == "item" and n.opts.icon == "effects" end)
check(#effectRows == #fxs, "one row per effect: " .. #effectRows)
for _, row in effectRows do
	local glyphs = {}
	for _, a in row.opts.actions do
		check(a.icon ~= nil and a.text == nil and a.tip ~= nil, "row action is a glyph with a tip")
		table.insert(glyphs, a.icon)
	end
	check(table.concat(glyphs, ",") == "duplicate,trash", "effect row actions: " .. table.concat(glyphs, ","))
end
check(#rows >= #fxs, "rows rendered")

-- add-element menu: the plus of the Elements section opens a grouped menu with class icons; nothing lost
local elementsSection = F.section("Elemente")
check(elementsSection ~= nil and elementsSection.title == "Elemente" and elementsSection.opts.key == "vfx.elements", "Elemente section")
local plus = F.icon("plus", "Adaugă element")
F.menus = {}
plus.click()
local menu = F.menus[1]
check(menu ~= nil and menu.anchor == plus, "the add menu opens under the plus button")
local headers, seenKeys = 0, {}
for _, item in menu.items do
	if item.header then
		headers += 1
	else
		check(item.classIcon ~= nil and item.onClick ~= nil, "menu item with a class icon: " .. tostring(item.label))
		check(F.symbolIn(item.label) == nil, "menu label without symbols: " .. item.label)
		seenKeys[item.value] = true
	end
end
for _, p in Editor.PRESETS do check(seenKeys[p.key], "preset in the add menu: " .. p.key) end
for _, kind in { "PARTICLES", "LIGHT", "TRAIL", "MESH", "SOUND", "CAMERA", "BEAM" } do check(seenKeys[kind], "empty element in the add menu: " .. kind) end
local presetGroups, groupSeen = 0, {}
for _, p in Editor.PRESETS do
	if not groupSeen[p.group] then
		groupSeen[p.group] = true
		presetGroups += 1
	end
end
check(headers >= presetGroups + 1, "grouped add menu: " .. headers .. " headers for " .. presetGroups .. " preset groups + empty")
check(menu.items[1].header == true, "headers first")
-- picking an item adds the element and selects it
local before = #Editor.elements(panel.effect)
for _, item in menu.items do
	if item.value == "FLASH" then item.onClick() end
end
check(#Editor.elements(panel.effect) == before + 1 and panel.element and panel.element:GetAttribute("LC_Preset") == "FLASH",
	"menu item adds the element and selects it")

-- template flow ---------------------------------------------------------------------------------------------------------
local function templatePicker()
	for _, d in F.all("dropdown") do
		for _, item in d.items do
			if item.value == Editor.TEMPLATES[1].key then return d end
		end
	end
	return nil
end
button("Din șablon").click()
check(panel.templating == true, "template builder opened")
check(button("Din șablon").opts.selected == true and button("Efect nou").opts.style ~= "primary"
	and button("Creează și redă").opts.style == "primary", "while building, the builder holds the primary action")
onePrimary("template builder")
local picker = templatePicker()
check(picker ~= nil, "template picker exists")
local cats = {}
for _, item in picker.items do
	if item.header then table.insert(cats, item.label)
	else check(item.hint and item.hint:find(" s$") ~= nil, "template item shows its duration: " .. tostring(item.hint)) end
end
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
local colorBox = F.all("color")[1]
check(colorBox.value == HEAL_MAIN, "colour defaults to the template's main")
check(#F.icons("undo", "Culorile originale") == 0, "no reset button before a colour is chosen")
colorBox.change(Color3.fromRGB(255, 80, 0))
check(#F.icons("undo", "Culorile originale") == 1, "reset button after choosing a colour")
local scaleBox = find(function(n) return n.kind == "scrub" and n.label == "Scară" end)[1]
check(scaleBox ~= nil and scaleBox.opts.unit == "×", "scale is a scrub field")
scaleBox.change(1.5)
check(panel.tplScale == 1.5, "scale stored")
local function nameBox() return find(function(n) return n.kind == "textbox" and n.opts.placeholder == "Numele efectului" end)[1] end
check(nameBox().Text:find("^Vindecare") ~= nil and Editor.folder(false):FindFirstChild(nameBox().Text) == nil,
	"default name is a free one from the template label: " .. tostring(nameBox().Text))
before = #Editor.effects()
played = 0
nameBox().Text = "Vindecare focoasă"
button("Creează și redă").click()
flush()
check(#Editor.effects() == before + 1, "effect created from the panel")
check(panel.effect and panel.effect.Name == "Vindecare focoasă", "new effect selected")
check(played == 1, "preview played once (" .. played .. ")")
check(panel.templating == false, "builder closed")
-- recoloured + scaled for real
local sp
for _, el in Editor.elements(panel.effect) do if el.Name == "Sclipiri" then sp = Editor.read(el) end end
local h = sp.color[2]:ToHSV()
check(h < 0.12, "orange recolour applied via the panel: hue " .. tostring(h))

-- a duplicate name becomes an error toast, the builder stays
button("Din șablon").click()
nameBox().Text = "Vindecare focoasă"
local toastsBefore = #F.toasts
button("Creează și redă").click()
check(#F.toasts == toastsBefore + 1 and F.lastToast().kind == "error" and F.lastToast().text:find("xistă deja", 1, true) ~= nil,
	"duplicate name error is a toast: " .. tostring(F.lastToast() and F.lastToast().text))
check(F.lastToast().text:find("LostCube", 1, true) == nil, "error toast without the module prefix")
check(panel.templating == true, "builder stays open after an error")
button("Anulează").click()
check(panel.templating == false, "builder closes")

-- every template can be created from the panel
for _, tpl in Editor.TEMPLATES do
	button("Din șablon").click()
	templatePicker().change(tpl.key)
	nameBox().Text = "Panou " .. tpl.key
	button("Creează și redă").click()
	flush()
	check(panel.effect and panel.effect.Name == "Panou " .. tpl.key, "panel created " .. tpl.key)
end
check(history.active == nil, "recording left open by the panel")

-- the effect panel renders for template effects (elements list, properties of every element), with no symbols
for _, fx in Editor.effects() do
	panel.effect = fx
	for _, el in Editor.elements(fx) do
		panel.element = el
		render()
	end
end
noSymbols("every element of every template")
panel.element = nil

-- effects list: search filters in place, duplicate (toast with undo), delete through a confirmation -------------------------
panel.effect = Editor.effect("Panou LIGHTNING")
render()
local search = F.all("search")[1]
search.change("panou light")
local visible = {}
for _, row in F.find(function(n) return n.kind == "item" and n.opts.icon == "effects" end) do
	if row.Visible then table.insert(visible, row.Text) end
end
check(#visible == 1 and visible[1] == "Panou LIGHTNING", "search filters the list in place: " .. table.concat(visible, ", "))
check(panel.search == "panou light", "search text kept for the next render")
local noMatch = find(function(n) return n.kind == "label" and n.Text and n.Text:find("Niciun efect nu se potrivește", 1, true) end)
search.change("nu există așa ceva")
check(noMatch[1] and noMatch[1].Visible == true, "no-match line shown")
search.change("")
check(noMatch[1].Visible == false, "no-match line hidden again")
render()
local function effectRow(name)
	return find(function(n) return n.kind == "item" and n.opts.icon == "effects" and n.Text == name end)[1]
end
local count0 = #Editor.effects()
local function action(row, glyph) for _, a in row.opts.actions do if a.icon == glyph then return a end end end
action(effectRow("Panou LIGHTNING"), "duplicate").onClick()
check(#Editor.effects() == count0 + 1 and panel.effect.Name ~= "Panou LIGHTNING", "duplicate selects the copy: " .. panel.effect.Name)
check(F.lastToast().kind == "success" and F.lastToast().opts.action and F.lastToast().opts.action.text == "Anulează",
	"duplicate toast offers undo")
undos = 0
F.lastToast().opts.action.onClick()
check(undos == 1, "the toast's undo calls ChangeHistoryService:Undo")
local copy = panel.effect
render()
F.confirms = {}
action(effectRow(copy.Name), "trash").onClick()
check(#F.confirms == 1 and F.confirms[1].opts.danger == true and F.confirms[1].confirmText == "Șterge", "delete asks first")
check(copy.Parent ~= nil, "nothing deleted before the confirmation")
F.confirms[1].onConfirm()
check(copy.Parent == nil and panel.effect == nil and #Editor.effects() == count0, "deleted after the confirmation")
check(F.lastToast().text:find("a fost șters", 1, true) ~= nil, "delete toast")

-- the selected effect: header, transport, timeline strip -------------------------------------------------------------------
local light = Editor.effect("Panou LIGHTNING")
panel.effect, panel.element = light, nil
render()
local header = F.all("header")[1]
check(header and header.title == "Panou LIGHTNING" and header.opts.subtitle:find("elemente", 1, true), "effect header with a subtitle")
for _, glyph in { "play", "pause", "stop" } do check(#F.icons(glyph) >= 1, "transport: " .. glyph) end
local loopButton = find(function(n) return n.kind == "iconButton" and n.opts.name == "IconButton_loop" end)[1]
check(loopButton ~= nil and not loopButton.opts.active, "loop button, off")
local speed = find(function(n) return n.kind == "dropdown" and n.value == 1 and n.items[1].value == 0.1 end)[1]
check(speed ~= nil, "speed dropdown")
speed.change(0.25)
check(panel.speed == 0.25, "speed chosen")
panel.speed = 1
render()
check(find(function(n) return n.kind == "scrub" and n.label == "Durată" and n.opts.unit == "s" end)[1] ~= nil, "duration scrub in seconds")
local lanes = find(function(n) return n.ClassName == "TextButton" and n.Name == "Lane" end)
local els = Editor.elements(light)
check(#lanes == #els, "one timeline lane per element: " .. #lanes .. " / " .. #els)
local ticks, wanted = #find(function(n) return n.Name == "Tick" end), 0
for _, e in els do
	local d = Editor.read(e)
	wanted += d.bursts and #d.bursts or 0
end
check(ticks == wanted and wanted > 0, "a tick per burst: " .. ticks .. " / " .. wanted)
lanes[2].MouseButton1Click:Fire()
check(panel.element == els[2], "a click on a lane selects the element")
local selectedLanes = find(function(n) return n.Name == "Lane" and n.attributes.Selected == true end)
check(#selectedLanes == 1, "the lane of the selected element is marked")
-- lane marks
local marks = Panel.laneMarks({ kind = "PARTICLES", lifetime = { 0.2, 0.5 }, window = { 0.1, 0.4 }, bursts = { { 0, 10 }, { 0.3, 5 } } }, 1)
local kinds = {}
for _, m in marks do table.insert(kinds, m.kind .. "@" .. m.t0 .. (m.t1 and ("-" .. m.t1) or "")) end
check(table.concat(kinds, " ") == "bar@0.1-0.4 life@0.4-0.9 life@0-0.5 tick@0 life@0.3-0.8 tick@0.3", "particle marks: " .. table.concat(kinds, " "))
marks = Panel.laneMarks({ kind = "LIGHT", keys = { { 0, 0, 10 }, { 0.2, 4, 12 }, { 0.5, 0, 8 } } }, 1)
check(#marks == 4 and marks[1].kind == "bar" and marks[1].t0 == 0 and marks[1].t1 == 0.5 and marks[4].kind == "dot", "light keys: a bar and dots")
marks = Panel.laneMarks({ kind = "LIGHT", keys = {} }, 2)
check(#marks == 1 and marks[1].faint and marks[1].t1 == 2, "a light without keys: on for the whole duration")
marks = Panel.laneMarks({ kind = "TRAIL", lifetime = 0.3, window = nil }, 1)
check(#marks == 0, "a trail without a window draws nothing")

-- the playhead: one Heartbeat connection while playing, none while paused / stopped / done / destroyed
panel:stopPreview()
panel.element = nil
render()
check(heartbeat.live() == 0 and panel.hb == nil, "no Heartbeat connection before playing")
local head = find(function(n) return n.Name == "Head" end)[1]
check(head ~= nil and head.Visible == false, "playhead hidden while nothing plays")
F.icon("play").click()
check(heartbeat.live() == 1, "playing: one Heartbeat connection")
local length = Editor.length(light)
clock += length / 2
heartbeat:Fire()
head = panel.playhead
check(head.Visible == true and math.abs(head.Position.X.Scale - 0.5) < 1e-6, "playhead at the middle: " .. tostring(head.Position.X.Scale))
check(panel.readout.Text == string.format("%.2f / %.2f s", length / 2, length), "time read-out: " .. panel.readout.Text)
F.icon("play").click() -- again: still one connection
check(heartbeat.live() == 1, "a second play keeps one connection")
F.icon("pause").click()
check(heartbeat.live() == 0 and panel.paused, "paused: no connection")
clock += 1
check(panel:elapsed() == 0, "time stands still while paused")
F.icon("pause").click()
check(heartbeat.live() == 1 and not panel.paused, "resumed: connection back")
panel.handle.Done = true
heartbeat:Fire()
check(heartbeat.live() == 0 and panel.playhead.Visible == false, "finished: connection gone, playhead hidden")
F.icon("play").click()
check(heartbeat.live() == 1, "playing again")
F.icon("stop").click()
check(heartbeat.live() == 0 and panel.handle == nil, "stopped: connection gone")
F.icon("play").click()
panel:destroy()
check(heartbeat.live() == 0, "destroy disconnects the playhead")
loopButton = find(function(n) return n.kind == "iconButton" and n.opts.name == "IconButton_loop" end)[1]
loopButton.click()
check(panel.loop == true, "loop on")
panel:setLoop(false)
panel:stopPreview()

-- share codes: the effect's code, import (live description, free name), libraries, damaged codes --------------------------------
local exports = 0
local realExport = Editor.exportEffect
Editor.exportEffect = function(...) exports += 1; return realExport(...) end
local function setTool(mode) local seg = find(function(n) return n.kind == "segmented" and n.items[1].value == "color" end)[1]; seg.change(mode) end
render()
F.icon("copy", "Cod de partajare").click()
check(panel.toolMode == "share", "the copy glyph of the header opens the share tool")
local codeBoxes = find(function(n) return n.ClassName == "TextBox" and n.Name == "Code" end)
check(#codeBoxes == 1 and codeBoxes[1].TextEditable == false and codeBoxes[1].Text:sub(1, 4) == "LC1:", "effect code in a read-only box")
local info = Editor.describeCode(codeBoxes[1].Text)
check(info and info.kind == "effect" and info.effects[1].name == "Panou LIGHTNING", "the box holds this effect's code")
local toastsNow = #F.toasts
button("Selectează").click()
check(#F.toasts == toastsNow + 1 and F.lastToast().text:find("Ctrl+C", 1, true), "Selectează tells how to copy")
local shared = codeBoxes[1].Text
exports = 0
render()
check(find(function(n) return n.Name == "Code" end)[1].Text == shared and exports == 0, "code kept between renders (no new export)")
Editor.setEffect(light, { duration = 1.25 })
render()
check(exports == 1, "a new code after an edit")
Editor.setEffect(light, { duration = 1 })
render()
shared = find(function(n) return n.Name == "Code" end)[1].Text

local function ioMode(mode) find(function(n) return n.kind == "segmented" and n.items[1].value == "code" end)[1].change(mode) end
ioMode("code")
local paste = find(function(n) return n.kind == "textbox" and n.Name == "PasteCode" end)[1]
check(paste ~= nil and paste.opts.mono == true, "paste field")
local status = find(function(n) return n.Name == "CodeStatus" end)[1]
check(status.Text:find("bibliotecă", 1, true) ~= nil and status.opts.color == "textDim", "status hint before a code")
check(button("Importă").opts.style ~= "primary", "nothing to import: the button is not the primary action")
paste.change(shared)
status = find(function(n) return n.Name == "CodeStatus" end)[1]
check(status.Text:find("„Panou LIGHTNING”", 1, true) == 1 and status.opts.color == "success", "pasted code described: " .. status.Text)
check(button("Importă").opts.style == "primary", "a valid code: Importă becomes the primary action")
onePrimary("valid code pasted")
-- live: the description follows the text while typing (no redraw)
paste = find(function(n) return n.kind == "textbox" and n.Name == "PasteCode" end)[1]
local liveDelay
penv.task.delay = function(_, f) liveDelay = f end
paste.Text = "LC1:nimic"
paste:GetPropertyChangedSignal("Text"):Fire()
check(liveDelay ~= nil, "a description is scheduled while typing")
liveDelay()
check(status.Text ~= "" and status.skin and status.skin.TextColor3 == "danger", "live description of a bad code: " .. status.Text)
penv.task.delay = function() end
paste.Text = shared
local n0 = #Editor.effects()
button("Importă").click()
check(#Editor.effects() == n0 + 1, "imported")
check(panel.effect.Name ~= "Panou LIGHTNING" and panel.effect.Name:find("^Panou LIGHTNING") ~= nil, "the copy got a free name: " .. panel.effect.Name)
check(F.lastToast().kind == "success" and F.lastToast().text:find("Am importat", 1, true) and F.lastToast().opts.action, "import toast with undo")
check(panel.pasteCode == nil, "paste field cleared after the import")
-- a name typed for the import
paste = find(function(n) return n.kind == "textbox" and n.Name == "PasteCode" end)[1]
paste.Text = shared
find(function(n) return n.kind == "textbox" and n.opts.placeholder == "Numele din cod" end)[1].Text = "Fulger din cod"
button("Importă").click()
check(panel.effect.Name == "Fulger din cod", "import under the typed name")
-- damaged code: an error toast, nothing created
n0 = #Editor.effects()
paste = find(function(n) return n.kind == "textbox" and n.Name == "PasteCode" end)[1]
paste.Text = shared:sub(1, 30) .. (shared:sub(31, 31) == "Q" and "R" or "Q") .. shared:sub(32)
button("Importă").click()
check(#Editor.effects() == n0 and F.lastToast().kind == "error", "damaged code refused: " .. F.lastToast().text)
paste = find(function(n) return n.kind == "textbox" and n.Name == "PasteCode" end)[1]
paste.Text = ""
button("Importă").click()
check(F.lastToast().kind == "error" and F.lastToast().text:find("Lipește", 1, true), "empty code: asks for one")
-- the library: exported in the same tab, imported as a whole
button("Exportă biblioteca").click()
check(panel.libraryOpen == true, "library export opened")
local libBox = find(function(n) return n.ClassName == "TextBox" and n.Name == "Code" end)
local libCode
for _, b in libBox do
	local d = Editor.describeCode(b.Text)
	if d and d.kind == "library" then libCode = b.Text; check(#d.effects == #Editor.effects(), "library code holds every effect") end
end
check(libCode ~= nil, "library code shown")
n0 = #Editor.effects()
paste = find(function(n) return n.kind == "textbox" and n.Name == "PasteCode" end)[1]
paste.change(libCode)
status = find(function(n) return n.Name == "CodeStatus" end)[1]
check(status.Text:find("^Bibliotecă") ~= nil, "library described: " .. status.Text)
paste = find(function(n) return n.kind == "textbox" and n.Name == "PasteCode" end)[1]
button("Importă").click()
check(#Editor.effects() == n0 * 2, "library imported: " .. #Editor.effects() .. " / " .. n0 * 2)
check(F.lastToast().text:find("Am importat " .. n0, 1, true) ~= nil, "library toast: " .. F.lastToast().text)
check(history.active == nil, "no recording left open by the codes")
button("Exportă biblioteca").click()
check(panel.libraryOpen == false, "library export closed")

-- colour tools: recolour from the main colour, suggestions from the map ---------------------------------------------------------
panel.effect = Editor.effect("Panou LIGHTNING")
render()
setTool("color")
local main = find(function(n) return n.kind == "color" and n.opts.tip and n.opts.tip:find("Culoarea principală", 1, true) end)[1]
check(main ~= nil, "main colour field")
main.change(Color3.fromRGB(255, 40, 40))
check(F.lastToast().kind == "success" and F.lastToast().text:find("roșu", 1, true), "recolour toast: " .. F.lastToast().text)
local reds = 0
for _, e in Editor.elements(panel.effect) do
	local d = Editor.read(e)
	local c = d.color or d.Color
	if type(c) == "table" then c = c[1] end
	if typeof(c) == "Color3" then
		local hh, ss = c:ToHSV()
		if ss > 0.3 and (hh < 0.06 or hh > 0.94) then reds += 1 end
	end
end
check(reds > 0, "the effect turned red: " .. reds .. " elements")
report = nil
button("Potrivește cu harta").click()
check(F.lastToast().kind == "error" and F.lastToast().text:find("analiz", 1, true), "no analysis: says to run it: " .. F.lastToast().text)
report = { style = { lighting = { clockTime = 14 }, colors = { { hex = "4B7A3A", share = 50 }, { hex = "8C8577", share = 30 } } } }
button("Potrivește cu harta").click()
local swatches = find(function(n) return n.Name == "Swatch" end)
check(#swatches >= 3 and #swatches <= 5, "suggestions as swatches: " .. #swatches)
for _, s in swatches do
	check(s.tipText and s.tipText:find("#", 1, true) ~= nil, "suggestion reason + hex as tooltip")
end
local suggested = swatches[1].BackgroundColor3
swatches[1].MouseButton1Click:Fire()
check(F.lastToast().kind == "success" and F.lastToast().text:find(swatches[1].tipText:match("#%x+"), 1, true),
	"a swatch recolours the effect: " .. F.lastToast().text)
check(typeof(suggested) == "Color3", "swatch shows the data colour")

-- scale and time
setTool("scale")
local sized
for _, e in Editor.elements(panel.effect) do if e:IsA("ParticleEmitter") then sized = e; break end end
local size0 = sized.Size.Keypoints[1].Value
button("×1.25").click()
check(math.abs(sized.Size.Keypoints[1].Value - size0 * 1.25) < 1e-4, "×1.25 scales the effect")
local dur0 = panel.effect:GetAttribute("LC_Duration")
button("×1.15").click()
check(math.abs(panel.effect:GetAttribute("LC_Duration") - dur0 * 1.15) < 1e-3, "×1.15 stretches the time")

-- variants
setTool("variants")
n0 = #Editor.effects()
find(function(n) return n.kind == "scrub" and n.label == "Câte" end)[1].change(2)
check(panel.varCount == 2, "variant count")
local hue = find(function(n) return n.kind == "slider" and n.opts.unit == "°" end)[1]
check(hue.value == 120, "hue step defaults to 360 / (count + 1): " .. tostring(hue.value))
hue.change(90)
local planned = find(function(n) return n.Name == "Swatch" end)
check(#planned == 3, "planned colours: the original and 2 variants")
button("Creează variantele").click()
check(#Editor.effects() == n0 + 2, "two variants made")
check(F.lastToast().text:find("2 variante", 1, true) ~= nil, "variants toast: " .. F.lastToast().text)
noSymbols("tools")
onePrimary("tools")

-- elements list: mute, duplicate, delete with undo ---------------------------------------------------------------------------
panel.effect = Editor.effect("Panou LIGHTNING")
panel.element = nil
render()
local function elementRow(name) return find(function(n) return n.kind == "item" and n.opts.classIcon and n.Text == name end)[1] end
local first = Editor.elements(panel.effect)[1]
local row = elementRow(first.Name)
check(row ~= nil, "element row with a class icon")
action(row, "eye").onClick()
check(first:GetAttribute("LC_Muted") == true, "eye mutes")
check(action(elementRow(first.Name), "eyeOff") ~= nil, "muted row shows eyeOff")
action(elementRow(first.Name), "eyeOff").onClick()
check(first:GetAttribute("LC_Muted") ~= true, "eyeOff unmutes")
local nEl = #Editor.elements(panel.effect)
action(elementRow(first.Name), "duplicate").onClick()
check(#Editor.elements(panel.effect) == nEl + 1 and panel.element ~= first, "duplicate selects the copy")
local victim = panel.element
action(elementRow(victim.Name), "trash").onClick()
check(victim.Parent == nil and panel.element == nil, "delete at once")
check(F.lastToast().opts.action and F.lastToast().opts.action.text == "Anulează", "delete toast offers undo")
-- an effect without elements: an empty state whose action opens the add menu
local bare = Editor.newEffect("Gol", { duration = 1 })
panel.effect = bare
render()
local empty = F.all("empty")
check(#empty == 1 and empty[1].opts.title == "Niciun element", "empty elements state")
F.menus = {}
button("Adaugă element").click()
check(#F.menus == 1, "the empty state's action opens the add menu")

-- import flow (Creator Store) -----------------------------------------------------------------------------------------------
local loadedFor
ENV.game.GetObjects = function(_, url) loadedFor = url; return { build() } end
ioMode("store")
renders = 0
local function idBox() return find(function(n) return n.kind == "textbox" and n.opts.placeholder and n.opts.placeholder:find("ID sau adresa", 1, true) end)[1] end
local function storeName() return find(function(n) return n.kind == "textbox" and n.opts.placeholder == "Import <ID>" end)[1] end
check(button("Importă").opts.style ~= "primary", "no asset id yet: Importă is not primary")
idBox().change("4242")
check(button("Importă").opts.style == "primary", "an asset id: Importă is the primary action")
onePrimary("Creator Store")
idBox().Text = "nu e un număr"
button("Importă").click()
check(F.lastToast().kind == "error" and F.lastToast().text:find("Scrie ID", 1, true) ~= nil, "bad id message")
idBox().Text = "https://create.roblox.com/store/asset/4242/Super-VFX"
storeName().Text = "Import <b>din magazin</b>"
local n1 = #Editor.effects()
button("Importă").click()
check(loadedFor == "rbxassetid://4242", "asset id taken from the pasted address: " .. tostring(loadedFor))
check(#Editor.effects() == n1 + 1 and panel.effect.Name == "Import <b>din magazin</b>", "imported effect is selected")
check(panel.importing == false and panel.importReport and panel.importReport.ok, "import finished")
check(F.lastToast().kind == "success" and F.lastToast().text:find("&lt;b&gt;", 1, true) ~= nil, "success toast, name escaped")
local shown = notes()
check(shown:find("Scripturi șterse: 3", 1, true) ~= nil, "report shows the removed scripts")
check(shown:find("&lt;b&gt;", 1, true) ~= nil and shown:find("<b>", 1, true) == nil, "rich text in names is escaped")
check(F.symbolIn(shown) == nil, "report without the Editor's marks: " .. tostring(F.symbolIn(shown)))
-- failure is a toast and a red report
ENV.game.GetObjects = function() error("HTTP 403") end
ENV.__services.InsertService.LoadAsset = function() error("403") end
idBox().Text = "99"
storeName().Text = ""
button("Importă").click()
check(F.lastToast().kind == "error" and F.lastToast().text:find("Nu am putut încărca", 1, true) ~= nil, "import failure toast: " .. F.lastToast().text)
check(F.all("note")[1] and F.all("note")[1].color == F.UI.C.danger, "failure report in red")
-- import from the selection
local src = build()
ENV.__services.Selection.Get = function() return { src } end
local target = Editor.newEffect("Pentru selecție", { duration = 1 })
panel.effect = target
render()
button("Din selecție").click()
check(#Editor.elements(target) == 8 and panel.importReport.ok, "import from the selection: " .. table.concat(panel.importReport.lines, " / "))
check(F.lastToast().kind == "success" and F.lastToast().text:find("Pentru selecție", 1, true), "selection import toast")
ENV.__services.Selection.Get = function() return {} end
render()
button("Din selecție").click()
check(F.lastToast().kind == "error" and F.lastToast().text:find("Selectează în Explorer", 1, true) ~= nil, "nothing selected message")
panel.effect = nil
render()
button("Din selecție").click()
check(F.lastToast().kind == "error" and F.lastToast().text:find("Alege mai întâi un efect", 1, true) ~= nil, "no effect chosen message")

-- texture picker: grouped, current texture shown
panel.effect = Editor.effects()[1]
for _, el in Editor.elements(panel.effect) do
	if Editor.kindOf(el) == "PARTICLES" then panel.element = el; break end
end
render()
local tex
for _, d in F.all("dropdown") do
	for _, item in d.items do if item.value == "CUSTOM" then tex = d end end
end
check(tex ~= nil, "texture dropdown")
local th = {}
for _, item in tex.items do if item.header then table.insert(th, item.label) end end
local textureGroups, textureSeen = 0, {}
for _, x in Editor.TEXTURES do
	if not textureSeen[x.group] then
		textureSeen[x.group] = true
		textureGroups += 1
	end
end
check(#th >= textureGroups, "a header per texture group (" .. textureGroups .. ") + custom: " .. table.concat(th, " | "))
local keys = {}
for _, item in tex.items do if item.value then keys[item.value] = true end end
for _, x in Editor.TEXTURES do check(keys[x.key], "texture in picker " .. x.key) end
-- the element's groups, in order of meaning
local titles = table.concat(sectionTitles(), " | ")
check(titles:find("Aspect | Mișcare | Formă", 1, true) ~= nil and titles:find("Cronologie", 1, true) ~= nil, "particle groups: " .. titles)
check(renders > 0, "the panel rendered")

-- the empty place: an empty state with a template action
for _, fx in Editor.effects() do fx:Destroy() end
panel.effect, panel.element = nil, nil
render()
empty = F.all("empty")
check(#empty == 1 and empty[1].opts.title == "Niciun efect încă", "empty library state")
button("Alege un șablon").click()
check(panel.templating == true and templatePicker() ~= nil, "the empty state's action opens the templates")
noSymbols("empty place")
onePrimary("empty place")

t.finish()
