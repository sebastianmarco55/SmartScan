-- AnalysisPanel: the real UI + Analyzer + AnalysisPanel on the DataModel mock with GUI enabled. First render starts the
-- analysis by itself, the full report renders section by section, issue rows open the script at the line, the severity
-- filter, "Analiză cu Claude" (AI is a fake), an old report from another version, the read-only context box.
local LC = ...
local T = LC.kit.new("analysis_panel")
local function check(cond, what)
	T.check(cond, what)
end

local M = LC.run("tests/mocks/datamodel.luau")
M.enableGui()
local new, service, Instance, methods = M.new, M.service, M.Instance, M.methods
local Color3, Enum, V3, workspace = M.Color3, M.Enum, M.V3, M.workspace
local drain, opened = M.gui.drain, M.gui.opened
service("UserInputService")
service("Selection")
service("RunService")
service("ScriptEditorService")

local mocks = {}
local tree = LC.modtree.new{ env = LC.env(M.globals()), mocks = mocks }
local UIModule = tree.load("UI")
local AnalyzerModule = tree.load("Analyzer")

-- a small game
local SS = service("ServerStorage")
local SSS = service("ServerScriptService", { LoadStringEnabled = false })
service("ReplicatedStorage")
service("StarterGui")
service("StarterPlayer", { CharacterWalkSpeed = 16 })
service("Lighting", { Technology = Enum.Technology.Future, ClockTime = 14 })
local function part(name, props)
	local base = { Anchored = true, Size = V3(4, 1, 2), Position = V3(0, 0, 0), Color = Color3.fromRGB(163, 162, 165),
		Material = Enum.Material.Plastic, Transparency = 0, CanCollide = true }
	for k, v in props or {} do
		base[k] = v
	end
	return new("Part", name, base)
end
for i = 1, 5 do
	part("Wall" .. i, { Color = Color3.fromRGB(200, 40 * i, 50) }).Parent = workspace
end
local bad = new("Script", "Vaccine", { Source = "local x = require(4567891234)\n\nlocal y = getfenv(0)" })
bad.Parent = workspace
new("Script", "Combat", { Source = "remote.OnServerEvent:Connect(function(p, dmg)\n\tp.leaderstats.Cash.Value += dmg\nend)\n"
	.. "wait(1)" }).Parent = SSS

-- AI and Markdown are fakes (the panel uses them when they are there); everything else is real
local aiCalls = 0
mocks.AI = {
	getKey = function()
		return "sk-ant-test"
	end,
	analyzeGame = function(plugin, context, opts)
		aiCalls += 1
		assert(type(context) == "string" and #context > 100, "context sent")
		opts.onStatus("aștept răspunsul")
		M.task.wait()
		return true, "## Analiza jocului\n- totul bine", { model = "claude-opus-5-5" }
	end,
}
local markdownCalls = 0
mocks.Markdown = { render = function(parent, text)
	markdownCalls += 1
	return UIModule.label(parent, text, { wrap = true })
end }
local Panel = tree.load("AnalysisPanel")

local refreshes = 0
local plugin = new("Plugin", "Plugin")
local ctx = { plugin = plugin }
local root = Instance.new("Frame")
UIModule.setRoot(root)
local content
local panel
local function render()
	content = Instance.new("Frame")
	content.Parent = root
	panel:render(content)
end
ctx.app = { refresh = function()
	refreshes += 1
end }
panel = Panel.new(ctx)

local function texts(inst, out)
	out = out or {}
	for _, d in inst:GetDescendants() do
		local ok, t = pcall(function()
			return rawget(d, "_data").Text
		end)
		if ok and type(t) == "string" and t ~= "" then
			table.insert(out, t)
		end
	end
	return table.concat(out, "\n")
end

-- 1. no report: first render starts the analysis by itself
render()
check(panel.running == true, "auto analysis started")
local shown = texts(content)
check(string.find(shown, "Analizez jocul", 1, true) ~= nil and string.find(shown, "Prima analiză", 1, true) ~= nil,
	"progress shown")
check(panel.progressUI ~= nil, "progress widgets kept")
local fillBefore = panel.progressUI.fill.Size
drain()
check(panel.running == false and panel.report ~= nil, "analysis finished")
check(panel.error == nil, "no error: " .. tostring(panel.error))
check(refreshes >= 2, "refreshed")

-- 2. full report
render()
shown = texts(content)
for _, want in { "Probleme", "Sugestii", "Analiză Claude", "Securitate", "Performanță", "Cod", "Avatar",
	"Efecte și animații", "Stil vizual", "UI și audio", "Context pentru Claude", "Instanțe", "Scripturi" } do
	check(string.find(shown, want, 1, true) ~= nil, "section " .. want)
end
local function descendants(pred)
	local out = {}
	for _, d in content:GetDescendants() do
		if pred(d, rawget(d, "_data")) then
			table.insert(out, d)
		end
	end
	return out
end
check(#descendants(function(d) return d:GetAttribute("SectionError") == true end) == 0, "no section errors")
check(#descendants(function(_, data) return data.Name == "IconButton_refresh" end) == 1, "reanalyze icon button")
check(#descendants(function(_, data) return data.Name == "IconButton_explorer" end) == 1, "report in Explorer icon button")
-- the design system: no emoji or symbol icons, no exclamation marks in the panel's text
for _, symbol in { "⚠", "✓", "✗", "◆", "🧠", "🔄", "🔍", "💡", "🛡", "⚡", "📜", "🧍", "✨", "🎨", "🖥", "📋", "↳", "🎬", "▶", "✦", "⇄", "👍" } do
	check(string.find(shown, symbol, 1, true) == nil, "no symbol " .. symbol)
end
check(string.find(shown, "!", 1, true) == nil, "no exclamation marks")
check(string.find(shown, "require(4567891234)", 1, true) ~= nil, "issue listed")
-- every finding row carries its severity (Studio's alert glyph) and kind
local rows = descendants(function(d) return d:GetAttribute("Severity") ~= nil end)
check(#rows >= 3, "issue rows " .. #rows)
local severities = {}
for _, row in rows do
	severities[row:GetAttribute("Severity")] = true
end
check(severities.high and severities.medium, "high and medium findings shown")
check(string.find(shown, "Workspace.Vaccine:1", 1, true) ~= nil, "path with the line")

-- clicking an issue selects the script and opens it at the line
local clicked = false
for _, d in content:GetDescendants() do
	local data = rawget(d, "_data")
	if data.ClassName == "TextButton" and data._signals and data._signals.MouseButton1Click then
		for _, c in d:GetDescendants() do
			local t = rawget(c, "_data").Text
			if type(t) == "string" and string.find(t, "require(4567891234)", 1, true) then
				data._signals.MouseButton1Click:Fire()
				clicked = true
				break
			end
		end
	end
	if clicked then
		break
	end
end
check(clicked, "issue row clickable")
check(#opened == 1 and opened[1][1] == bad and opened[1][2] == 1, "script opened at line " .. tostring(opened[1] and opened[1][2]))
local selected = M.gui.selected()
check(selected and selected[1] == bad, "selected")

-- severity filter (chips) and kind filter (header menu)
local function count(severity)
	local n = 0
	for _, d in content:GetDescendants() do
		if rawget(d, "_data").Name == "Issue" and (severity == nil or d:GetAttribute("Severity") == severity) then
			n += 1
		end
	end
	return n
end
local allLows, all = count("low"), count()
check(allLows > 0, "low findings listed " .. allLows)
panel.filter = "high"
render()
check(count("low") == 0 and count("high") == count() and count() > 0, "filter keeps only high " .. count())
panel.filter = "all"
panel.kind = "security"
render()
local kinds = {}
for _, d in content:GetDescendants() do
	if rawget(d, "_data").Name == "Issue" then
		table.insert(kinds, tostring(d:GetAttribute("Kind")))
	end
end
local onlySecurity = #kinds > 0
for _, k in kinds do
	onlySecurity = onlySecurity and string.sub(k, 1, 9) == "security."
end
check(onlySecurity and #kinds < all, "kind filter keeps only security findings (" .. table.concat(kinds, ", ") .. ")")
panel.kind = "all"
render()
check(count() == all, "all findings again")
-- a finding whose instance is gone: a toast, no redraw
local before = refreshes
panel:open("Workspace.Gone.Script", 3)
check(panel.error ~= nil and string.find(panel.error, "Nu mai găsesc", 1, true) ~= nil and refreshes == before, "missing path")
local toast = false
for _, d in root:GetDescendants() do
	if rawget(d, "_data").Name == "Toast" then
		toast = toast or string.find(texts(d), "Nu mai găsesc", 1, true) ~= nil
	end
end
check(toast, "missing path toast")

-- 3. Claude
check(markdownCalls == 0, "no AI text yet")
panel:askClaude()
check(panel.aiRunning == true, "ai running")
render()
check(string.find(texts(content), "Claude analizează", 1, true) ~= nil, "ai status shown")
check(panel.aiUI ~= nil and panel.aiUI.track.Parent ~= nil, "ai progress bar")
drain()
check(panel.aiRunning == false and aiCalls == 1, "ai done")
check(panel.aiError == nil, "ai error: " .. tostring(panel.aiError))
check(panel.report.ai and panel.report.ai.model == "claude-opus-5-5", "ai stored on report")
check(AnalyzerModule.load().ai.text == "## Analiza jocului\n- totul bine", "ai saved in place")
render()
check(markdownCalls >= 1, "markdown rendered")

-- 4. a report from another version with missing fields: sections fail alone, the panel still renders
panel.report = { version = 0, at = 0, issues = { { severity = "high", kind = "security.x", message = "m", path = "Workspace.Vaccine" } } }
panel.contextFor = nil
local ok, err = pcall(render)
check(ok, "old report renders: " .. tostring(err))
check(string.find(texts(content), "Analiza e veche", 1, true) ~= nil, "stale warning")

-- 5. select all in the context box (its section starts folded and is only built when opened)
panel.report = AnalyzerModule.load()
render()
check(select(2, string.gsub(texts(content), "Context pentru Claude", "")) >= 1, "context section is listed")
local function textBoxes()
	local n = 0
	for _, d in content:GetDescendants() do
		if rawget(d, "_data").ClassName == "TextBox" then
			n += 1
		end
	end
	return n
end
check(textBoxes() == 0, "a folded section is not built (no context box yet)")
UIModule.collapsed["game.context"] = false
render()
check(textBoxes() == 1, "the context box is built when the section is opened")
local box
for _, d in content:GetDescendants() do
	if rawget(d, "_data").ClassName == "TextBox" then
		box = d
	end
end
check(box ~= nil, "context box")
if box then
	box:CaptureFocus()
	check(box.SelectionStart == 1 and box.CursorPosition == #box.Text + 1, "select all")
	box.Text = "typed"
	methods.GetPropertyChangedSignal(box, "Text"):Fire()
	check(box.Text ~= "typed", "read-only")
end

panel:destroy()

-- ---------------------------------------------------------------------------------------------
-- folded sections are built when opened, the stale warning comes from the background count, Claude's answer goes
-- on a copy of the shared report
-- ---------------------------------------------------------------------------------------------
T.section("lazy sections, background stale count, shared report", function()
	local function ok2(cond, what)
		T.check(cond, what)
	end
	ctx.app.tab = "Game"
	M.task.defer = function(f, ...) -- a real deferred thread (the base mock runs it at once, inside the caller)
		M.task.spawn(f, ...)
	end
	local function clickByText(container, want)
		for _, d in container:GetDescendants() do
			local data = rawget(d, "_data")
			if data.ClassName == "TextButton" and data._signals and data._signals.MouseButton1Click then
				for _, c in d:GetDescendants() do
					local t = rawget(c, "_data").Text
					if type(t) == "string" and string.find(t, want, 1, true) then
						data._signals.MouseButton1Click:Fire()
						return true
					end
				end
			end
		end
		return false
	end

	-- 1. folded sections are not built until they are opened
	for _, key in { "game.perf", "game.code", "game.avatar", "game.vfx", "game.style", "game.ui", "game.context" } do
		UIModule.collapsed[key] = nil
	end
	panel = Panel.new(ctx)
	panel.report = AnalyzerModule.load()
	panel.loaded = true
	render()
	local shown1 = texts(content)
	ok2(string.find(shown1, "Performanță", 1, true) and string.find(shown1, "Stil vizual", 1, true), "section titles are drawn")
	ok2(not string.find(shown1, "Bucle per frame", 1, true), "perf rows are not built while folded")
	ok2(not string.find(shown1, "Framework-uri", 1, true), "code rows are not built while folded")
	local countFolded = #content:GetDescendants()
	ok2(clickByText(content, "Performanță"), "perf header clickable")
	local shown2 = texts(content)
	ok2(string.find(shown2, "Bucle per frame", 1, true) ~= nil, "perf rows are built on open")
	ok2(UIModule.collapsed["game.perf"] == false, "the section is remembered as open")
	ok2(#content:GetDescendants() > countFolded, "opening adds the rows")
	-- closing and opening again does not build twice
	local n1 = #content:GetDescendants()
	clickByText(content, "Performanță")
	clickByText(content, "Performanță")
	ok2(#content:GetDescendants() == n1, "no duplicate rows after toggling")
	-- a redraw with the section open builds it at once
	render()
	ok2(string.find(texts(content), "Bucle per frame", 1, true) ~= nil, "open section is built by the redraw")
	-- the context section: text box only when open
	UIModule.collapsed["game.context"] = true
	render()
	local hasBox = false
	for _, d in content:GetDescendants() do
		if rawget(d, "_data").ClassName == "TextBox" then hasBox = true end
	end
	ok2(not hasBox, "no text box while the context section is folded")
	-- an error inside a folded section shows up in it when opened, not in the click handler
	local brokenReport = panel.report
	panel.report = { version = brokenReport.version, at = brokenReport.at, totals = brokenReport.totals, performance = "oops" }
	UIModule.collapsed["game.perf"] = true
	render()
	local okClick = pcall(clickByText, content, "Performanță")
	ok2(okClick, "opening a broken section does not raise")
	panel.report = brokenReport

	-- 2. the stale warning comes from the background count
	local fakeOffset = 0
	local os = M.os
	local realTime = os.time
	os.time = function(...)
		if select("#", ...) > 0 then return realTime(...) end
		return realTime() + fakeOffset
	end
	panel = Panel.new(ctx)
	panel.report = AnalyzerModule.load()
	panel.loaded = true
	render()
	ok2(string.find(texts(content), "Analiza e veche", 1, true) == nil, "fresh: no warning")
	for i = 1, 900 do
		new("Part", "More" .. i).Parent = workspace
	end
	fakeOffset = 100000 -- count cache expired (the report itself is only a few seconds old... make it look recent)
	panel.report = table.clone(panel.report)
	panel.report.at = os.time()
	local before = refreshes
	render()
	drain()
	ok2(refreshes == before + 1, "background count finished -> one redraw requested: " .. (refreshes - before))
	render()
	ok2(string.find(texts(content), "Analiza e veche", 1, true) ~= nil, "warning shown after the count")
	local again = refreshes
	render()
	drain()
	ok2(refreshes == again, "no redraw loop")
	-- another tab on screen: no redraw
	ctx.app.tab = "VFX"
	fakeOffset = 300000
	panel.report.at = os.time()
	for _, d in workspace:GetChildren() do
		if string.sub(d.Name, 1, 4) == "More" then d:Destroy() end
	end
	local other = refreshes
	render()
	drain()
	ok2(refreshes == other, "no redraw while another tab is on screen")
	ctx.app.tab = "Game"
	os.time = realTime

	-- 3. Claude's answer never edits the shared report table
	local shared = AnalyzerModule.load()
	panel = Panel.new(ctx)
	panel.report = shared
	panel.loaded = true
	local aiBefore = shared.ai
	panel:askClaude()
	drain()
	ok2(shared.ai == aiBefore, "the loaded report was not changed in place")
	ok2(panel.report ~= shared and panel.report.ai and panel.report.ai.text == "## Analiza jocului\n- totul bine", "panel shows the answer on a copy")
	ok2(AnalyzerModule.load().ai.text == "## Analiza jocului\n- totul bine", "answer saved in the place")
	ok2(panel.report.code == shared.code, "the copy shares the data")
	panel:destroy()
	ok2(panel.dead == true, "destroy marks the panel dead")

end)

-- ---------------------------------------------------------------------------------------------
-- no analysis and none running (a play test): an empty state with one action that starts it
-- ---------------------------------------------------------------------------------------------
T.section("empty state", function()
	panel = Panel.new(ctx)
	panel.loaded = true
	render()
	local shown = texts(content)
	T.check(string.find(shown, "Jocul nu e analizat încă", 1, true) ~= nil, "empty state title")
	local started = false
	for _, d in content:GetDescendants() do
		local data = rawget(d, "_data")
		if data.ClassName == "TextButton" and data.Text == "Analizează jocul" and data._signals and data._signals.MouseButton1Click then
			data._signals.MouseButton1Click:Fire()
			started = true
		end
	end
	T.check(started and panel.running == true, "the empty state's action starts the analysis")
	drain()
	T.check(panel.running == false and panel.report ~= nil, "analysis done")
	panel:destroy()
end)

T.finish()
