-- BuildPanel (the Modelare tab): the REAL panel, UI kit and Modeling engine on the typed Roblox mock of the engine's tests
-- (tests/mocks/modeling_env.luau) with the strict GUI mock (tests/mocks/gui.luau) for the GUI classes. Every generator's
-- form draws from its schema; the ghost preview is debounced, lives in the camera, is not archivable and goes away
-- with the tab / mode / panel; Plasează and Actualizează are one undo step each and select the result; selecting a
-- generated model loads its parameters; operations are disabled (with the reason) when the selection does not fit and
-- run as one undo step with an undo toast; the optimizer reports first; Modeling.selfCheck runs once; no emoji.
local LC = ...
local t = LC.kit.new("build_panel")

local ENV = LC.run("tests/mocks/modeling_env.luau", nil, LC)
local G = LC.env()
local gui = LC.run("tests/mocks/gui.luau", G)
local services = ENV.__services
local history, csg = ENV.__history, ENV.__csg
local Vector3, CFrame, Color3, workspace = ENV.Vector3, ENV.CFrame, ENV.Color3, ENV.workspace

-- the environment of the panel: the engine's mock for the place, the strict GUI mock for GUI objects and datatypes
local baseEnum, guiEnum = ENV.Enum, G.Enum
ENV.Enum = setmetatable({}, { __index = function(_, name)
	local ok, e = pcall(function()
		return baseEnum[name]
	end)
	if ok and e ~= nil then
		return e
	end
	return guiEnum[name]
end })
for _, name in { "Vector2", "UDim", "UDim2", "Font" } do
	ENV[name] = G[name]
end
local GUI_CLASSES = { Frame = true, TextLabel = true, TextButton = true, TextBox = true, ScrollingFrame = true, UICorner = true,
	UIStroke = true, ImageLabel = true, ImageButton = true, UIGradient = true, UIPadding = true, UIListLayout = true,
	UISizeConstraint = true, UIGridLayout = true }
local baseNew = ENV.Instance.new
ENV.Instance = { new = function(class, parent)
	if GUI_CLASSES[class] then
		local inst = G.Instance.new(class)
		if parent then
			inst.Parent = parent
		end
		return inst
	end
	return baseNew(class, parent)
end }
local warnings = {}
ENV.warn = function(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring((select(i, ...)))
	end
	table.insert(warnings, table.concat(parts, " "))
end

-- a scheduler with a clock (task.delay / defer run when the clock gets there)
local clock, queue = 0, {}
ENV.task = {
	spawn = function(f, ...)
		f(...)
	end,
	defer = function(f, ...)
		table.insert(queue, { at = clock, f = f, args = { ... } })
	end,
	delay = function(dt, f, ...)
		table.insert(queue, { at = clock + (dt or 0), f = f, args = { ... } })
	end,
	wait = function()
		return 0
	end,
}
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

-- Selection fires SelectionChanged like Studio; ChangeHistoryService:Undo is counted
local function signal()
	local s = { conns = {} }
	function s:Connect(f)
		local c = { f = f, connected = true }
		function c:Disconnect()
			self.connected = false
		end
		table.insert(self.conns, c)
		return c
	end
	function s:Fire(...)
		for _, c in table.clone(self.conns) do
			if c.connected then
				c.f(...)
			end
		end
	end
	function s:live()
		local n = 0
		for _, c in self.conns do
			if c.connected then
				n += 1
			end
		end
		return n
	end
	return s
end
local Selection = services.Selection
local selectionChanged = signal()
Selection.SelectionChanged = selectionChanged
local baseSet = Selection.Set
Selection.Set = function(self, list)
	baseSet(self, list)
	selectionChanged:Fire()
end
local undos = 0
services.ChangeHistoryService.Undo = function()
	undos += 1
end

local tree = LC.modtree.new({ env = ENV })
local UI = tree.load("UI")
local Modeling = tree.load("Modeling")
local Panel = tree.load("BuildPanel")
local camera = workspace.CurrentCamera

local baseplate = ENV.part("Part", Vector3.new(512, 1, 512), CFrame.new(0, -0.5, 0))
baseplate.Name = "Baseplate"

-- the window: a root (toasts) and the content the panel draws into
local root = ENV.Instance.new("Frame")
UI.setRoot(root)
local content = ENV.Instance.new("Frame")
content.Parent = root
local refreshes = 0
local app = { tab = "Build", root = root, saved = {} }
function app:refresh()
	refreshes += 1
end
function app:setting(key)
	return self.saved[key]
end
function app:save(key, value)
	self.saved[key] = value
end
local panel = Panel.new({ app = app })

local function render()
	for _, c in content:GetChildren() do
		c:Destroy()
	end
	panel:render(content)
	advance(0)
end
local function texts(rootInst)
	local out = {}
	for _, d in gui.findAll(rootInst or content, function()
		return true
	end) do
		local text = d.__data.props.Text
		if type(text) == "string" and text ~= "" then
			table.insert(out, text)
		end
	end
	return out
end
local function hasText(needle, rootInst)
	for _, text in texts(rootInst) do
		if string.find(text, needle, 1, true) then
			return true
		end
	end
	return false
end
-- the button whose own text is exactly `text`
local function button(text)
	local found = {}
	for _, d in gui.findAll(content, function(x)
		return x.ClassName == "TextButton" and x.__data.props.Text == text
	end) do
		table.insert(found, d)
	end
	return found[1], #found
end
local function disabled(b)
	return b ~= nil and b:GetAttribute("Disabled") == true
end
local function click(b)
	gui.click(b)
	advance(0)
end
local function named(name)
	return gui.findAll(content, function(x)
		return x.Name == name
	end)
end
local function toasts()
	return texts(root)
end
local function steps(fn)
	local n0, out0 = #history.log, history.outside
	fn()
	local added = {}
	for i = n0 + 1, #history.log do
		table.insert(added, history.log[i])
	end
	return added, history.outside - out0
end
local function oneStep(label, added)
	t.check(#added == 2 and string.find(added[1], "^begin LostCube: ") ~= nil and added[2] == "finish Commit",
		label .. ": one committed undo step (" .. table.concat(added, " | ") .. ")")
end
local function noEmoji(label)
	local bad = {}
	for _, text in texts(root) do
		for _, cp in utf8.codes(text) do
			if cp >= 0x2600 or (cp >= 0x25A0 and cp <= 0x25FF) then
				table.insert(bad, text)
				break
			end
		end
	end
	t.eq(label .. ": no emoji / symbol glyphs (" .. table.concat(bad, " | ") .. ")", #bad, 0)
end

t.section("first render: header, modes, generator tiles, self-check once", function()
	render()
	t.check(hasText("Modelare") and hasText("Nimic selectat"), "title and status")
	t.check(button("Generatoare") ~= nil and button("Operații") ~= nil, "the two modes")
	t.eq("a tile per generator", #gui.findAll(content, function(x)
		return string.sub(x.Name, 1, 5) == "Tile_"
	end), #Modeling.GENERATORS)
	t.check(hasText("Alege ce construiești"), "a hint until a generator is chosen")
	render()
	local checks = 0
	for _, line in history.log do
		if line == "begin LostCube: verificare" then
			checks += 1
		end
	end
	t.eq("Modeling.selfCheck ran once (quietly)", checks, 1)
	t.check(not hasText("Verificarea pieselor-pană", root), "no warning toast when the shapes check out")
	noEmoji("first render")
end)

t.section("every generator's form draws from its schema", function()
	for _, g in Modeling.GENERATORS do
		for _, key in { "build.form", "build.form.structure", "build.form.windows", "build.form.door", "build.form.roof",
			"build.form.look", "build.form.steps", "build.form.spiral", "build.form.details", "build.form.marks",
			"build.form.other" } do
			UI.collapsed[key] = false
		end
		panel:choose(g.key)
		local errors0 = #gui.errors
		local ok, err = pcall(render)
		t.check(ok, g.key .. ": renders (" .. tostring(err) .. ")")
		t.eq(g.key .. ": no GUI mock error", #gui.errors - errors0, 0)
		local result = panel:compute()
		t.check(result ~= nil, g.key .. ": the defaults generate")
		t.check(button("Plasează") ~= nil, g.key .. ": Plasează")
		t.check(not hasText("?"), g.key .. ": a real part count in the badge")
		-- every schema field has a control: its label (short) or its tooltip text appears
		local rows = 0
		for _, d in gui.findAll(content, function(x)
			return x.Name == "Row" or x.Name == "Scrub"
		end) do
			rows += 1
			_ = d
		end
		t.check(rows >= #g.params - 1, g.key .. ": a row per field (" .. rows .. " for " .. #g.params .. ")")
	end
	noEmoji("forms")
	for key in UI.collapsed do
		if string.find(key, "^build%.form%.") then
			UI.collapsed[key] = true
		end
	end
end)

t.section("ghost preview: debounced, in the camera, outside undo, follows the tab", function()
	panel:choose("building")
	render()
	advance(0.1)
	t.check(camera:FindFirstChild("LostCube previzualizare") == nil, "nothing before the debounce")
	local log0 = #history.log
	advance(0.3)
	local ghost = camera:FindFirstChild("LostCube previzualizare")
	t.check(ghost ~= nil, "the preview is in workspace.CurrentCamera")
	t.eq("no undo recording for the preview", #history.log, log0)
	t.eq("the preview is not archivable", ghost.Archivable, false)
	local result = panel:compute()
	local parts = ghost:GetChildren()
	t.eq("a ghost part per piece", #parts, #result.pieces)
	local p = parts[1]
	t.check(p.Archivable == false and p.Locked == true and p.CanQuery == false and p.CanCollide == false and p.CastShadow == false
		and p.Transparency > 0.3, "ghost parts: unselectable, no queries / collisions / shadows, translucent")
	-- a burst of changes rebuilds once, after the last one
	local values = panel:valuesOf("building")
	for w = 26, 34, 2 do
		values.width = w
		panel:edited(true)
		advance(0.05)
	end
	t.check(camera:FindFirstChild("LostCube previzualizare") == ghost, "not rebuilt during the burst")
	advance(0.3)
	local rebuilt = camera:FindFirstChild("LostCube previzualizare")
	t.check(rebuilt ~= nil and rebuilt ~= ghost and ghost.Parent == nil, "rebuilt once after it, the old one removed")
	t.eq("one preview only", #camera:GetChildren(), 1)
	-- the eye switch, the mode, the tab
	panel:setPreview(false)
	t.check(camera:FindFirstChild("LostCube previzualizare") == nil, "preview off removes it")
	panel:setPreview(true)
	advance(0.3)
	t.check(camera:FindFirstChild("LostCube previzualizare") ~= nil, "preview on brings it back")
	app.tab = "VFX"
	advance(1)
	t.check(camera:FindFirstChild("LostCube previzualizare") == nil, "another tab: the preview goes away")
	app.tab = "Build"
	render()
	advance(0.3)
	t.check(camera:FindFirstChild("LostCube previzualizare") ~= nil, "back on the tab: the preview again")
	panel:setMode("ops")
	t.check(camera:FindFirstChild("LostCube previzualizare") == nil, "operations mode: no preview")
	t.eq("the mode is remembered", app.saved["build.mode"], "ops")
	panel:setMode("gen")
	advance(0.3)
	values.width = 24
	panel:edited()
	advance(0.3)
end)

local placed
t.section("Plasează: one undo step, selected, then Actualizează with its parameters", function()
	render()
	local added = steps(function()
		click(button("Plasează"))
	end)
	oneStep("Plasează", added)
	placed = Selection:Get()[1]
	t.check(placed ~= nil and placed.Parent == workspace and placed:GetAttribute("LC_Generator") == "building", "the model is selected")
	t.check(camera:FindFirstChild("LostCube previzualizare") == nil, "the preview made room for it")
	t.check(hasText("Am plasat „Clădire”", root) and hasText("Anulează", root), "a toast with Anulează")
	-- the toast's undo calls ChangeHistoryService:Undo
	for _, d in gui.findAll(root, function(x)
		return x.ClassName == "TextButton" and x.__data.props.Text == "Anulează"
	end) do
		gui.click(d)
		break
	end
	t.eq("Anulează asks Studio to undo", undos, 1)
	render()
	local update = button("Actualizează")
	t.check(update ~= nil and disabled(update), "Actualizează, disabled until something changes")
	t.check(button("Plasează copie") ~= nil and button("Plasează") == nil, "Plasează copie instead of Plasează")
	t.check(hasText("Clădire · clădire") or hasText("· clădire ·"), "the status names the generated model")
	advance(0.5)
	t.check(camera:FindFirstChild("LostCube previzualizare") == nil, "no preview while nothing changed")
	panel:valuesOf("building").floors = 3
	panel:edited()
	render()
	advance(0.3)
	t.check(not disabled(button("Actualizează")), "a change enables Actualizează")
	local ghost = camera:FindFirstChild("LostCube previzualizare")
	t.check(ghost ~= nil and (ghost.WorldPivot.Position - placed.WorldPivot.Position).Magnitude < 1e-6,
		"the preview shows the change on the model")
	local before = placed
	added = steps(function()
		click(button("Actualizează"))
	end)
	oneStep("Actualizează", added)
	local fresh = Selection:Get()[1]
	t.check(fresh ~= before and before.Parent == nil and fresh:GetAttribute("LC_Generator") == "building", "rebuilt and selected")
	t.check(string.find(fresh:GetAttribute("LC_Params"), '"floors":3', 1, true) ~= nil, "with the new parameters")
	t.check(hasText("Am actualizat", root), "a toast")
	placed = fresh
end)

t.section("where it goes: on the selection, copies in front of the camera", function()
	Selection:Set({})
	panel:choose("tree")
	panel.where = "selection"
	local box = ENV.part("Part", Vector3.new(10, 4, 10), CFrame.new(200, 2, 200))
	Selection:Set({ box })
	render()
	t.check(not hasText("Nimic selectat: modelul"), "no 'nothing selected' note")
	advance(0.3)
	local ghost = camera:FindFirstChild("LostCube previzualizare")
	t.check(ghost ~= nil and (ghost.WorldPivot.Position - Vector3.new(200, 4, 200)).Magnitude < 1e-6,
		"the preview stands on top of the selection")
	-- facing the camera: the model's front (-Z, the LookVector) points toward it
	local toCamera = camera.CFrame.Position - ghost.WorldPivot.Position
	toCamera = Vector3.new(toCamera.X, 0, toCamera.Z).Unit
	t.check(ghost.WorldPivot.LookVector:Dot(toCamera) > 0.99, "the front faces the camera")
	local added = steps(function()
		click(button("Plasează"))
	end)
	oneStep("Plasează on the selection", added)
	local tree1 = Selection:Get()[1]
	t.check((tree1.WorldPivot.Position - Vector3.new(200, 4, 200)).Magnitude < 1e-6, "placed where the preview was")
	render()
	added = steps(function()
		click(button("Plasează copie"))
	end)
	oneStep("Plasează copie", added)
	local copy = Selection:Get()[1]
	t.check(copy ~= tree1 and (copy.WorldPivot.Position - panel:cameraAnchor().Position).Magnitude < 1e-6,
		"the copy goes in front of the camera, not on top of the original")
	panel.where = "camera"
	Selection:Set({})
	panel:choose("building")
end)

t.section("selecting a generated model loads its kind and parameters", function()
	local palm = Modeling.generate("tree", { kind = "palm", height = 20, seed = 9 }, nil, CFrame.new(-60, 0, 0))
	Selection:Set({ palm })
	t.eq("the form switched to the tree", panel.kind, "tree")
	t.eq("its stored kind", panel:valuesOf("tree").kind, "palm")
	t.eq("its stored seed", panel:valuesOf("tree").seed, 9)
	t.check(refreshes > 0, "the panel asked for a redraw")
	render()
	t.check(hasText("Palmier"), "the form shows it")
	Selection:Set({})
	render()
	t.check(button("Plasează") ~= nil, "nothing selected: a new model again")
	-- a model of an older version (an unknown stored key) still loads
	palm:SetAttribute("LC_Params", '{"kind":"round","height":12,"oldKey":1}')
	Selection:Set({ palm })
	t.eq("unknown stored keys are dropped", panel:valuesOf("tree").kind, "round")
	Selection:Set({})
	palm:Destroy()
end)

t.section("operations: empty state, disabled reasons, one undo step each", function()
	panel:setMode("ops")
	Selection:Set({})
	render()
	t.check(hasText("Nimic selectat") and button("Pornește de la un generator") ~= nil, "empty state with a pointer to generators")
	click(button("Pornește de la un generator"))
	t.eq("the pointer opens the generators", panel.mode, "gen")
	panel:setMode("ops")
	local a = ENV.part("Part", Vector3.new(2, 1, 2), CFrame.new(10, 0.5, 10))
	a.Name = "A"
	local b = ENV.part("Part", Vector3.new(2, 1, 2), CFrame.new(18, 0.5, 10))
	b.Name = "B"
	local c = ENV.part("Part", Vector3.new(2, 1, 2), CFrame.new(10, 0.5, 18))
	c.Name = "C"
	UI.collapsed["build.op.fill"] = false
	Selection:Set({ a })
	render()
	local fill = button("Umple")
	t.check(disabled(fill) and hasText("Selectează exact 3 piese sau atașamente."), "Umple disabled, with the reason")
	t.check(not disabled(button("Repetă")) and not disabled(button("Oglindește")), "one object: arrays and mirror work")
	t.check(disabled(button("Aliniază")) and disabled(button("Distribuie")), "align / distribute need more objects")
	Selection:Set({ a, b, c })
	render()
	t.check(hasText("3 obiecte · 3 piese"), "the status counts the selection")
	local added = steps(function()
		click(button("Umple"))
	end)
	oneStep("Umple", added)
	local wedges = Selection:Get()
	t.check(#wedges >= 1 and wedges[1].ClassName == "WedgePart", "the fill is selected")
	t.check(hasText("Am umplut", root), "a toast")
	-- linear array: copies side by side along the object's X (size + gap)
	Selection:Set({ a })
	render()
	local n0 = #workspace:GetChildren()
	added = steps(function()
		click(button("Repetă"))
	end)
	oneStep("Repetă", added)
	t.eq("4 copies (5 in total)", #workspace:GetChildren() - n0, 4)
	local xs = {}
	for _, child in workspace:GetChildren() do
		if child.Name == "A" then
			table.insert(xs, child.Position.X)
		end
	end
	table.sort(xs)
	t.check(#xs == 5 and math.abs(xs[2] - xs[1] - 2) < 1e-6, "copies touch (step = size along X)")
	-- align: two objects
	Selection:Set({ b, c })
	render()
	added = steps(function()
		click(button("Aliniază"))
	end)
	oneStep("Aliniază", added)
	noEmoji("operations")
end)

t.section("solids: a CSG failure is a clear toast and changes nothing", function()
	local a = ENV.part("Part", Vector3.new(4, 4, 4), CFrame.new(60, 2, 0))
	local b = ENV.part("Part", Vector3.new(4, 4, 4), CFrame.new(62, 2, 0))
	UI.collapsed["build.op.solid"] = false
	Selection:Set({ a, b })
	render()
	csg.fail = "test"
	local added = steps(function()
		click(button("Unește"))
	end)
	t.check(#added == 0 or added[#added] == "finish Cancel", "rolled back (" .. table.concat(added, " | ") .. ")")
	t.check(a.Parent == workspace and b.Parent == workspace, "the parts are still there")
	t.check(hasText("Încearcă mai puține piese", root), "the failure toast says what to do")
	csg.fail = false
	added = steps(function()
		click(button("Unește"))
	end)
	oneStep("Unește", added)
	t.check(Selection:Get()[1] and Selection:Get()[1].ClassName == "UnionOperation", "the union is selected")
end)

t.section("optimize: the report first, then apply", function()
	local model = ENV.Instance.new("Model")
	model.Name = "Decor"
	for i = 1, 4 do
		local p = ENV.part("Part", Vector3.new(0.5, 0.5, 0.5), CFrame.new(i, 0.25, -40), model)
		p.Anchored = false
	end
	model.Parent = workspace
	UI.collapsed["build.op.optimize"] = false
	Selection:Set({ model })
	render()
	t.check(button("Aplică") == nil, "no apply before the report")
	local added = steps(function()
		click(button("Analizează"))
	end)
	t.eq("the report changes nothing", #added, 0)
	render()
	t.check(hasText("Piese de ancorat") and hasText("Proprietăți de schimbat"), "a table of changes")
	local apply
	for _, d in gui.findAll(content, function(x)
		return x.ClassName == "TextButton" and string.find(x.__data.props.Text, "^Aplică") ~= nil
	end) do
		apply = d
	end
	t.check(apply ~= nil and not disabled(apply), "Aplică is ready")
	added = steps(function()
		click(apply)
	end)
	oneStep("Aplică", added)
	t.check(model:GetChildren()[1].Anchored == true, "applied")
	t.check(panel.optReport == nil, "the report is cleared")
end)

t.section("destroy: no preview, no connection", function()
	panel:setMode("gen")
	panel:choose("rock")
	render()
	advance(0.3)
	t.check(camera:FindFirstChild("LostCube previzualizare") ~= nil, "a preview exists")
	panel:destroy()
	t.check(camera:FindFirstChild("LostCube previzualizare") == nil, "destroy removes it")
	t.eq("SelectionChanged disconnected", selectionChanged:live(), 0)
	advance(2)
	t.check(camera:FindFirstChild("LostCube previzualizare") == nil, "nothing comes back afterwards")
	t.eq("plural", Panel.plural(1, "piesă", "piese") .. "|" .. Panel.plural(20, "piesă", "piese") .. "|" .. Panel.plural(101, "piesă", "piese"),
		"1 piesă|20 de piese|101 piese")
end)

for _, w in warnings do
	t.fail("warn: " .. w)
end
for _, e in gui.errors do
	t.fail("GUI mock error: " .. tostring(e))
end
t.finish()
