-- LostCube > Game tab: what LostCube knows about this game (the analysis stored in the place): problems, suggestions,
-- performance, code, security, existing VFX / animations, visual style, Claude's analysis and the context for Claude.
-- The first time it opens in a place it analyzes the game by itself (Analyzer.run, in the background).
local Selection = game:GetService("Selection")
local RunService = game:GetService("RunService")

local UI = require(script.Parent.UI)
local Analyzer = require(script.Parent.Analyzer)
local C = UI.C

local Panel = {}
Panel.__index = Panel

local SEVERITY_COLOR = { high = C.danger, medium = C.warn, low = C.dim }
local SEVERITY_TAG = { high = "MARE", medium = "MEDIE", low = "MICĂ" }
local FILTERS = {
	{ value = "all", label = "Toate" }, { value = "high", label = "Mari" }, { value = "medium", label = "Medii" },
	{ value = "low", label = "Mici" },
}
local ISSUES_SHOWN = 40 -- issues listed before "show all"

-- "ReplicatedStorage.LostCube.Analyzer:123: LostCube: ..." -> "LostCube: ..."
local function clean(err)
	return (tostring(err):gsub("^.-:%d+: ", ""))
end

-- a sibling module that may be missing or broken (AI, Markdown): the panel works without it
local function optional(name)
	local module = script.Parent:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	return ok and type(result) == "table" and result or nil
end

local function escape(text)
	return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\"", "&quot;"))
end

-- 102002 -> "102 002"
local function num(x)
	local n = math.floor((tonumber(x) or 0) + 0.5)
	local s = string.reverse((string.gsub(string.reverse(tostring(math.abs(n))), "(%d%d%d)", "%1 ")))
	s = string.gsub(s, "^ ", "")
	return (n < 0 and "-" or "") .. s
end

local function yes(v)
	return v and "da" or "nu"
end

local function date(t)
	return os.date("%d.%m.%Y %H:%M", tonumber(t) or 0)
end

local function list(items, n, fn)
	local out = {}
	for i, v in items or {} do
		if n and i > n then
			table.insert(out, "…")
			break
		end
		table.insert(out, fn and fn(v) or tostring(v))
	end
	return table.concat(out, ", ")
end

-- ---------------------------------------------------------------------------------------------
-- small widgets (only here)
-- ---------------------------------------------------------------------------------------------
local function stat(body, label, value, color)
	return UI.label(UI.row(body, label), tostring(value), { size = 12, color = color })
end

local function progressBar(parent, fraction)
	local track = UI.make("Frame", { Parent = parent, BackgroundColor3 = C.input, Size = UDim2.new(1, 0, 0, 8) },
		{ UI.corner(4) })
	local fill = UI.make("Frame", { Parent = track, BackgroundColor3 = C.accent,
		Size = UDim2.new(math.clamp(fraction, 0, 1), 0, 1, 0) }, { UI.corner(4) })
	return fill
end

-- colors as a row of swatches (hex strings or { hex =, share = % }); hover shows the hex
local function swatches(parent, colors)
	local row = UI.make("Frame", { Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28) },
		{ UI.hlist(3, true) })
	for _, c in colors or {} do
		local hex = type(c) == "table" and c.hex or c
		local ok, color = pcall(Color3.fromHex, tostring(hex))
		if ok and color then
			local share = type(c) == "table" and tonumber(c.share) or nil
			local sw = UI.make("Frame", { Parent = row, BackgroundColor3 = color, Size = UDim2.new(0, 24, 1, 0) },
				{ UI.corner(4), UI.stroke(C.border) })
			if share then
				local light = (color.R * 0.3 + color.G * 0.59 + color.B * 0.11) > 0.55
				UI.make("TextLabel", { Parent = sw, Text = UI.fmt(share, share < 10 and 1 or 0) .. "%", Font = UI.FONT_MED,
					TextSize = 10, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
					TextColor3 = light and Color3.new(0, 0, 0) or Color3.new(1, 1, 1) })
			end
			UI.tip(sw, "#" .. tostring(hex) .. (share and ("  ·  " .. UI.fmt(share, 1) .. "% din suprafață") or ""))
		end
	end
	return row
end

-- one finding: severity tag + message (wrapped) + where; clickable when it points at something
local function issueRow(parent, issue, onClick)
	local color = SEVERITY_COLOR[issue.severity] or C.dim
	local row = UI.make("TextButton", { Parent = parent, Text = "", AutoButtonColor = false, BackgroundColor3 = C.item,
		BackgroundTransparency = 0.35, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y },
		{ UI.corner(4), UI.pad(5, 8, 5, 8), UI.vlist(1) })
	if issue.severity == "high" then
		UI.stroke(Color3.fromRGB(110, 44, 50)).Parent = row
	end
	UI.label(row, string.format('<font color="#%s"><b>%s</b></font>  %s', color:ToHex(),
		SEVERITY_TAG[issue.severity] or "?", escape(issue.message or "")), { rich = true, wrap = true, size = 12 })
	if issue.path then
		UI.label(row, "↳ " .. issue.path .. (issue.line and (" : " .. tostring(issue.line)) or ""),
			{ dim = true, size = 11, height = 16 })
	end
	if onClick and issue.path then
		row.MouseEnter:Connect(function()
			row.BackgroundTransparency = 0
		end)
		row.MouseLeave:Connect(function()
			row.BackgroundTransparency = 0.35
		end)
		row.MouseButton1Click:Connect(onClick)
	end
	return row
end

-- read-only but selectable text (Ctrl+A / Ctrl+C work; typing is undone)
local function textArea(parent, text, height)
	local scroll = UI.make("ScrollingFrame", { Parent = parent, BackgroundColor3 = C.input, Size = UDim2.new(1, 0, 0, height),
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.hover, ScrollingDirection = Enum.ScrollingDirection.Y,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar }, { UI.corner(4), UI.stroke(C.border) })
	local box = UI.make("TextBox", { Parent = scroll, Text = text, Font = UI.FONT, TextSize = 12, TextColor3 = C.text,
		BackgroundTransparency = 1, ClearTextOnFocus = false, MultiLine = true, TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.pad(6, 8, 6, 8) })
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if box.Text ~= text then
			box.Text = text
		end
	end)
	box.Focused:Connect(function()
		task.defer(function() -- after Studio placed the cursor: select everything, ready for Ctrl+C
			if box.Parent and box:IsFocused() then
				box.SelectionStart = 1
				box.CursorPosition = #box.Text + 1
			end
		end)
	end)
	return box
end

local function safe(parent, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then -- e.g. a report saved by an older version: one section fails, the others still show
		UI.note(parent, "⚠ " .. clean(err), C.warn)
		warn("LostCube:", err)
	end
end

-- ---------------------------------------------------------------------------------------------
-- state + actions
-- ---------------------------------------------------------------------------------------------
function Panel.new(ctx)
	return setmetatable({ ctx = ctx, report = nil, loaded = false, running = false, fraction = 0, label = "",
		filter = "all", showAll = false, aiRunning = false }, Panel)
end

function Panel:refresh()
	if not self.dead then
		self.ctx.app:refresh()
	end
end

-- full analysis in the background; the progress bar is updated in place (no redraw of the whole window per tick)
function Panel:analyze()
	if self.running or Analyzer.running then
		return
	end
	self.running, self.fraction, self.label, self.error = true, 0, "Pornesc analiza…", nil
	self:refresh()
	task.spawn(function()
		local ok, result = pcall(Analyzer.run, function(fraction, label)
			self.fraction, self.label = fraction, label
			self:updateProgress()
		end)
		self.running = false
		if ok then
			self.report, self.contextFor = result, nil
			if result.saveError then
				self.error = "Analiza nu s-a putut salva în joc: " .. clean(result.saveError)
			end
		else
			self.error = "Analiza a eșuat: " .. clean(result)
			warn("LostCube:", result)
		end
		self:refresh()
	end)
end

function Panel:updateProgress()
	local ui = self.progressUI
	if ui and ui.fill.Parent then
		ui.fill.Size = UDim2.new(math.clamp(self.fraction, 0, 1), 0, 1, 0)
		ui.label.Text = string.format("%d%%  ·  %s", math.floor(self.fraction * 100 + 0.5), self.label)
	end
end

-- selects what a finding points at; scripts open in the editor at the line
function Panel:open(path, line)
	local inst = Analyzer.resolve(path)
	if not inst then
		self.error = "Nu mai găsesc „" .. tostring(path) .. "” (mutat sau șters? Reanalizează jocul)."
		self:refresh()
		return
	end
	pcall(function()
		Selection:Set({ inst })
	end)
	if inst:IsA("LuaSourceContainer") then
		local plugin = self.ctx.plugin
		local opened = plugin and pcall(plugin.OpenScript, plugin, inst, tonumber(line) or 1)
		if not opened then
			task.spawn(function()
				pcall(function()
					game:GetService("ScriptEditorService"):OpenScriptDocumentAsync(inst)
				end)
			end)
		end
	end
end

function Panel:context(report)
	if self.contextFor ~= report then
		local ok, text = pcall(Analyzer.context, report)
		self.contextText = ok and text or ("⚠ " .. clean(text))
		self.contextFor = report
	end
	return self.contextText
end

-- Claude's analysis of the game (AI.luau); yields, so it runs in the background
function Panel:askClaude()
	local AI = optional("AI")
	if self.aiRunning or not self.report then
		return
	end
	if not AI or type(AI.analyzeGame) ~= "function" then
		self.aiError = "Modulul AI lipsește din plugin."
		self:refresh()
		return
	end
	self.aiRunning, self.aiError, self.aiStatus = true, nil, nil
	self.aiStarted = os.clock()
	local report = self.report
	local context = self:context(report)
	self:refresh()
	task.spawn(function()
		local ok, success, text, info = pcall(AI.analyzeGame, self.ctx.plugin, context, {
			onStatus = function(status)
				self.aiStatus = status
				if self.aiLabel and self.aiLabel.Parent then
					self.aiLabel.Text = "Claude analizează…  " .. tostring(status)
				end
			end,
		})
		self.aiRunning = false
		if ok and success and type(text) == "string" and text ~= "" then
			local model = type(info) == "table" and info.model or nil
			if not model and type(AI.getModel) == "function" then
				local okModel, id = pcall(AI.getModel, self.ctx.plugin)
				model = okModel and id or nil
			end
			model = tostring(model or "Claude")
			report.ai = { text = text, model = model, at = os.time() }
			local saved, err = pcall(Analyzer.setAI, text, model)
			if not saved then
				self.aiError = "Analiza lui Claude nu s-a putut salva în joc: " .. clean(err)
			end
		else
			self.aiError = clean(ok and (text or "Claude nu a răspuns.") or success)
		end
		self:refresh()
	end)
end

function Panel:destroy()
	self.dead = true
end

-- ---------------------------------------------------------------------------------------------
-- render
-- ---------------------------------------------------------------------------------------------
function Panel:render(parent)
	if not self.loaded then
		self.loaded = true
		local ok, report = pcall(Analyzer.load)
		self.report = ok and report or nil
		-- first time in this place: analyze it right away (only in Edit mode, not in a play test)
		local okEdit, isEdit = pcall(RunService.IsEdit, RunService)
		if not self.report and (not okEdit or isEdit) then
			task.defer(function()
				if not self.dead then
					self:analyze()
				end
			end)
		end
	end
	self.progressUI = nil
	if self.error then
		UI.note(parent, "⚠ " .. escape(self.error), C.warn)
	end
	if self.running then
		self:renderProgress(parent)
	end
	local report = self.report
	if not report then
		if not self.running then
			local body = UI.section(parent, "🧠 Jocul", { key = "game.overview" })
			UI.note(body, "LostCube nu a analizat încă jocul ăsta. Analiza citește tot jocul (scripturi, hartă, efecte, "
				.. "animații, UI) și se salvează în <b>ServerStorage.LostCubeAnalysis</b>, ca Claude să-l cunoască.")
			UI.button(UI.hstack(body, { height = 28 }), "🔍 Analizează jocul", function()
				self:analyze()
			end, { style = "primary", bold = true, height = 28 })
		end
		return
	end
	safe(parent, self.renderOverview, self, parent, report)
	safe(parent, self.renderIssues, self, parent, report)
	safe(parent, self.renderSuggestions, self, parent, report)
	safe(parent, self.renderAI, self, parent, report)
	safe(parent, self.renderSecurity, self, parent, report)
	safe(parent, self.renderPerformance, self, parent, report)
	safe(parent, self.renderCode, self, parent, report)
	safe(parent, self.renderAvatar, self, parent, report)
	safe(parent, self.renderVFX, self, parent, report)
	safe(parent, self.renderStyle, self, parent, report)
	safe(parent, self.renderInterface, self, parent, report)
	safe(parent, self.renderContext, self, parent, report)
end

function Panel:renderProgress(parent)
	local box = UI.make("Frame", { Parent = parent, BackgroundColor3 = C.section, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.corner(6), UI.pad(10, 10, 10, 10), UI.vlist(6) })
	UI.label(box, self.report and "🔄 Reanalizez jocul…" or "🧠 Învăț jocul ăsta…", { bold = true, size = 14 })
	local fill = progressBar(box, self.fraction)
	local label = UI.label(box, "", { dim = true, size = 12 })
	UI.label(box, "Durează puțin la jocurile mari; Studio rămâne utilizabil, poți lucra în celelalte tab-uri.",
		{ dim = true, size = 11, wrap = true })
	self.progressUI = { fill = fill, label = label }
	self:updateProgress()
end

function Panel:renderOverview(parent, r)
	local place, totals, genre = r.place or {}, r.totals or {}, r.genre or {}
	local body = UI.section(parent, "🧠 " .. tostring(place.title or place.name or "Jocul"), { key = "game.overview" })
	local confidence = math.floor((tonumber(genre.confidence) or 0) * 100 + 0.5)
	UI.label(body, string.format("Gen: <b>%s</b>   <font color=\"#%s\">încredere %d%% (%s)</font>",
		escape(genre.label or "?"), C.dim:ToHex(), confidence, escape(genre.level or "?")), { rich = true, wrap = true, size = 13 })
	if genre.secondary then
		UI.label(body, "Seamănă și cu: " .. tostring(genre.secondary.label), { dim = true, size = 12, wrap = true })
	end
	if #(genre.evidence or {}) > 0 then
		UI.label(body, "Indicii: " .. list(genre.evidence, 10), { dim = true, size = 11, wrap = true })
	end
	stat(body, "Instanțe", num(totals.instances))
	stat(body, "Scripturi", string.format("%s  (%s linii)", num(totals.scripts), num(totals.lines)))
	stat(body, "Piese", num(totals.parts))
	stat(body, "Remote-uri", num(totals.remotes))
	if (tonumber(place.placeId) or 0) > 0 then
		stat(body, "PlaceId", tostring(place.placeId) .. (place.creator and ("  ·  " .. tostring(place.creator)) or ""))
	end
	stat(body, "Analizat", string.format("%s  (%s s)", date(r.at), tostring(r.duration or "?")))
	local okStale, stale = pcall(Analyzer.isStale, r)
	if okStale and stale and not self.running then
		UI.note(body, "Analiza e veche sau jocul s-a schimbat mult de atunci — apasă <b>Reanalizează</b>.", C.warn)
	end
	local bar = UI.hstack(body, { height = 28 })
	UI.button(bar, self.running and "Analizez…" or "🔄 Reanalizează", function()
		self:analyze()
	end, { style = okStale and stale and "primary" or "normal", bold = true, height = 28,
		tip = "citește din nou tot jocul și înlocuiește analiza salvată" })
	UI.button(bar, "Raportul în Explorer", function()
		local okStorage, storage = pcall(function()
			return game:GetService("ServerStorage"):FindFirstChild(Analyzer.FOLDER)
		end)
		if okStorage and storage then
			Selection:Set({ storage })
		end
	end, { style = "ghost", height = 28, tip = "ServerStorage.LostCubeAnalysis (Report, Context, AI)" })
end

function Panel:renderIssues(parent, r)
	local issues = r.issues or {}
	local counts = { high = 0, medium = 0, low = 0 }
	for _, issue in issues do
		counts[issue.severity] = (counts[issue.severity] or 0) + 1
	end
	local body = UI.section(parent, string.format("⚠ Probleme  (%d mari · %d medii · %d mici)", counts.high, counts.medium,
		counts.low), { key = "game.issues" })
	if #issues == 0 then
		UI.note(body, "Nu am găsit probleme. 👍", C.good)
		return
	end
	UI.segmented(body, FILTERS, self.filter, function(v)
		self.filter, self.showAll = v, false
		self:refresh()
	end)
	local shown = {}
	for _, issue in issues do
		if self.filter == "all" or issue.severity == self.filter then
			table.insert(shown, issue)
		end
	end
	if #shown == 0 then
		UI.label(body, "Nimic de acest nivel.", { dim = true, size = 12 })
		return
	end
	local scroll = UI.scrollList(body, 420)
	for i, issue in shown do
		if i > ISSUES_SHOWN and not self.showAll then
			break
		end
		issueRow(scroll, issue, function()
			self:open(issue.path, issue.line)
		end)
	end
	if #shown > ISSUES_SHOWN and not self.showAll then
		UI.button(UI.hstack(body), "Arată toate (" .. #shown .. ")", function()
			self.showAll = true
			self:refresh()
		end, { style = "ghost" })
	end
	UI.label(body, "Clic pe o problemă: o selectează și deschide scriptul la linia respectivă.", { dim = true, size = 11, wrap = true })
end

function Panel:renderSuggestions(parent, r)
	local suggestions = r.suggestions or {}
	if #suggestions == 0 then
		return
	end
	local body = UI.section(parent, "💡 Sugestii  (" .. #suggestions .. ")", { key = "game.suggestions" })
	for _, s in suggestions do
		UI.label(body, "•  " .. tostring(s), { size = 12, wrap = true })
	end
end

function Panel:renderAI(parent, r)
	local body = UI.section(parent, "🧠 Analiză cu Claude", { key = "game.ai" })
	local AI = optional("AI")
	local hasKey = false
	if AI and type(AI.getKey) == "function" then
		local ok, key = pcall(AI.getKey, self.ctx.plugin)
		hasKey = ok and type(key) == "string" and key ~= ""
	end
	if not AI then
		UI.note(body, "Modulul AI lipsește din această versiune a pluginului.", C.warn)
	elseif not hasKey then
		UI.note(body, "Pune cheia API Anthropic în tab-ul <b>◆ Claude</b> ca să ceri lui Claude o analiză a jocului "
			.. "(ce merge, ce lipsește, ce să faci mai întâi).", C.warn)
	end
	self.aiLabel = nil
	if self.aiRunning then
		self.aiLabel = UI.label(body, "Claude analizează…  " .. (self.aiStatus or "poate dura până la un minut"),
			{ size = 12, color = C.accentHover, wrap = true })
	elseif AI and hasKey then
		UI.button(UI.hstack(body, { height = 28 }), r.ai and "🧠 Cere o analiză nouă" or "🧠 Analizează jocul cu Claude",
			function()
				self:askClaude()
			end, { style = r.ai and "normal" or "primary", bold = true, height = 28 })
		UI.label(body, "Trimite contextul de mai jos (" .. num(#self:context(r)) .. " caractere); răspunsul se salvează în joc.",
			{ dim = true, size = 11, wrap = true })
	end
	if self.aiError then
		UI.note(body, "⚠ " .. escape(self.aiError), C.danger)
	end
	local ai = r.ai
	if type(ai) == "table" and type(ai.text) == "string" and ai.text ~= "" then
		UI.label(body, string.format("%s  ·  %s", tostring(ai.model ~= "" and ai.model or "Claude"), date(ai.at)),
			{ dim = true, size = 11 })
		local holder = UI.vstack(body, 4)
		local Markdown = optional("Markdown")
		local ok = Markdown and type(Markdown.render) == "function" and pcall(Markdown.render, holder, ai.text)
		if not ok then
			for _, child in holder:GetChildren() do
				if child:IsA("GuiObject") then
					child:Destroy()
				end
			end
			UI.label(holder, ai.text, { size = 12, wrap = true })
		end
	end
end

function Panel:renderSecurity(parent, r)
	local security = r.security or {}
	local counts = security.counts or {}
	local found = {}
	for _, issue in r.issues or {} do
		local kind = issue.kind or ""
		if string.sub(kind, 1, 9) == "security." or string.sub(kind, 1, 7) == "remote." then
			table.insert(found, issue)
		end
	end
	local body = UI.section(parent, string.format("🛡 Securitate  (%d)", #found), { key = "game.security",
		collapsed = #found == 0 })
	if #found == 0 then
		UI.note(body, "Nu am găsit semnături de backdoor / virus (require cu ID, loadstring, cod ofuscat, cumpărări ascunse, "
			.. "scripturi în locuri ciudate).", C.good)
	else
		UI.label(body, string.format("%d mari · %d medii · %d mici", counts.high or 0, counts.medium or 0, counts.low or 0),
			{ size = 12, color = (counts.high or 0) > 0 and C.danger or C.warn })
		local scroll = UI.scrollList(body, 300)
		for i, issue in found do
			if i > 30 then
				break
			end
			issueRow(scroll, issue, function()
				self:open(issue.path, issue.line)
			end)
		end
	end
	stat(body, "LoadString", security.loadStringEnabled and "activat" or "oprit",
		security.loadStringEnabled and C.warn or nil)
	stat(body, "HttpService", security.httpEnabled and "activat" or "oprit")
	if #(security.hosts or {}) > 0 then
		UI.label(body, "Adrese web din cod: " .. list(security.hosts, 12), { dim = true, size = 11, wrap = true })
	end
	UI.label(body, "Verifici un free model înainte să-l pui în joc: Analyzer.scanInstance(model).", { dim = true, size = 11,
		wrap = true })
end

function Panel:renderPerformance(parent, r)
	local p = r.performance or {}
	local body = UI.section(parent, "⚡ Performanță", { key = "game.perf", collapsed = true })
	local function warnIf(cond)
		return cond and C.warn or nil
	end
	stat(body, "Piese", string.format("%s  (Workspace %s)", num(p.parts), num(p.workspaceParts)))
	stat(body, "Neancorate", num(p.loose) .. " libere  ·  " .. num(p.unanchored) .. " total", warnIf((p.loose or 0) > 300))
	stat(body, "MeshPart", string.format("%s  (%s unice · %s coliz. precisă)", num(p.meshParts), num(p.uniqueMeshes),
		num(p.preciseCollision)), warnIf((p.preciseCollision or 0) > 150))
	stat(body, "Union", num(p.unions), warnIf((p.unions or 0) > 400))
	stat(body, "Particule", string.format("%s emițătoare · %s/s · %s dense", num(p.emitters), num(p.particleRate),
		num(p.heavyEmitters)), warnIf((p.particleRate or 0) > 3000))
	stat(body, "Lumini", string.format("%s  (%s cu umbre)", num(p.lights), num(p.shadowLights)),
		warnIf((p.shadowLights or 0) > 25))
	stat(body, "NPC (Humanoid)", num(p.humanoids), warnIf((p.humanoids or 0) > 80))
	stat(body, "Bucle per frame", string.format("%s Heartbeat/Stepped · %s RenderStepped", num(p.runService),
		num(p.renderStepped)), warnIf((p.runService or 0) > 40))
	stat(body, "Touched", num(p.touched), warnIf((p.touched or 0) > 150))
	stat(body, "while fără wait", num(p.busyLoops), (p.busyLoops or 0) > 0 and C.danger or nil)
	stat(body, "Sunete / decal-uri", string.format("%s  ·  %s (%s texturi unice)", num(p.sounds), num(p.decals),
		num(p.uniqueTextures)))
	stat(body, "StreamingEnabled", yes(p.streamingEnabled))
	stat(body, "Teren", (p.terrainCells or 0) > 0 and (num(p.terrainCells) .. " celule") or "nu")
end

function Panel:renderCode(parent, r)
	local code = r.code or {}
	local body = UI.section(parent, "📜 Cod", { key = "game.code", collapsed = true })
	stat(body, "Scripturi", string.format("%s Script · %s Local · %s Module", num(code.scripts), num(code.localScripts),
		num(code.modules)))
	stat(body, "Linii", num(code.lines) .. ((code.disabled or 0) > 0 and ("  ·  " .. num(code.disabled) .. " dezactivate") or ""))
	local frameworks = list(code.frameworks, 10, function(fw)
		return fw.name
	end)
	UI.label(body, "Framework-uri: " .. (frameworks ~= "" and frameworks or "niciunul detectat"), { size = 12, wrap = true })
	if #(code.services or {}) > 0 then
		UI.label(body, "Servicii: " .. list(code.services, 14, function(s)
			return s.name .. " ×" .. tostring(s.count)
		end), { dim = true, size = 11, wrap = true })
	end
	local ds = code.datastore or {}
	stat(body, "DataStore", ds.used and string.format("da · BindToClose %s · %s SetAsync · %s UpdateAsync",
		yes(ds.bindToClose), num(ds.set), num(ds.update)) or "nu", ds.used and not ds.bindToClose and C.warn or nil)
	local market = code.marketplace or {}
	stat(body, "Monetizare", string.format("%s gamepass · %s produse · ProcessReceipt ×%s", num(#(market.gamepasses or {})),
		num(#(market.products or {})), num(market.processReceipt)))
	stat(body, "Remote handler", string.format("%s  (%s fără validare)", num(code.remoteHandlers), num(code.unvalidated)),
		(code.unvalidated or 0) > 0 and C.warn or nil)

	if #(code.largest or {}) > 0 then
		UI.label(body, "Cele mai mari scripturi", { medium = true, size = 12 })
		for i, s in code.largest do
			if i > 8 then
				break
			end
			UI.item(body, tostring(s.path), { icon = "📜", note = num(s.lines) .. " lin.", height = 24, onClick = function()
				self:open(s.path, 1)
			end })
		end
	end
	local remotes = code.remotes or {}
	if #remotes > 0 then
		UI.label(body, "Remote-uri și Bindable-uri  (" .. #remotes .. ")", { medium = true, size = 12 })
		local scroll = UI.scrollList(body, 200)
		for _, rem in remotes do
			UI.item(scroll, tostring(rem.name), { icon = "⇄", note = string.gsub(tostring(rem.class), "Remote", ""), height = 24,
				onClick = function()
					self:open(rem.path)
				end })
		end
	end
	if #(code.deprecated or {}) > 0 then
		UI.label(body, "API-uri învechite", { medium = true, size = 12 })
		for _, d in code.deprecated do
			UI.item(body, tostring(d.label) .. " → " .. tostring(d.fix), { note = "×" .. num(d.count), height = 24,
				muted = true, onClick = function()
					self:open(d.path, d.line)
				end })
		end
	end
end

function Panel:renderAvatar(parent, r)
	local a = r.avatar or {}
	local body = UI.section(parent, "🧍 Avatar și personaje", { key = "game.avatar", collapsed = true })
	stat(body, "Rig", tostring(a.rigType or "necunoscut") .. (a.rigSource and ("  (" .. a.rigSource .. ")") or ""))
	stat(body, "WalkSpeed", tostring(a.walkSpeed or "?"))
	stat(body, "Săritură", a.useJumpPower == false and ("JumpHeight " .. tostring(a.jumpHeight))
		or ("JumpPower " .. tostring(a.jumpPower or "?")))
	stat(body, "StarterCharacter", a.starterCharacter and ("da" .. (a.starterCharacterRig and (" (" .. a.starterCharacterRig .. ")")
		or "")) or "nu")
	stat(body, "Animate propriu", yes(a.customAnimate))
	stat(body, "Rig-uri în hartă", string.format("%s R15 · %s R6", num(a.rigs and a.rigs.r15), num(a.rigs and a.rigs.r6)))
	stat(body, "Cameră", string.format("%s · zoom max %s", tostring(a.cameraMode or "?"), tostring(a.maxZoom or "?")))
	if #(a.characterScripts or {}) > 0 then
		UI.label(body, "StarterCharacterScripts: " .. list(a.characterScripts, 15), { dim = true, size = 11, wrap = true })
	end
	if #(a.playerScripts or {}) > 0 then
		UI.label(body, "StarterPlayerScripts: " .. list(a.playerScripts, 15), { dim = true, size = 11, wrap = true })
	end
end

function Panel:renderVFX(parent, r)
	local vfx, anim = r.vfx or {}, r.animations or {}
	local body = UI.section(parent, "✨ Efecte și animații existente", { key = "game.vfx", collapsed = true })
	local counts = {}
	for class, n in vfx.counts or {} do
		table.insert(counts, class .. " " .. num(n))
	end
	table.sort(counts)
	UI.label(body, "Efecte: " .. (#counts > 0 and table.concat(counts, ", ") or "niciunul"), { size = 12, wrap = true })
	stat(body, "Efecte LostCube", num(vfx.lostCubeEffects))
	if #(vfx.colors or {}) > 0 then
		UI.label(body, "Culorile efectelor", { dim = true, size = 11 })
		swatches(body, vfx.colors)
	end
	if #(vfx.textures or {}) > 0 then
		UI.label(body, "Texturi: " .. list(vfx.textures, 6, function(t)
			return tostring(t.id):gsub("^rbxassetid://", "") .. " ×" .. tostring(t.count)
		end), { dim = true, size = 11, wrap = true })
	end
	for i, e in vfx.examples or {} do
		if i > 6 then
			break
		end
		UI.item(body, tostring(e.name), { icon = "✦", note = tostring(e.class):gsub("Emitter", ""), height = 24,
			onClick = function()
				self:open(e.path)
			end })
	end

	UI.label(body, string.format("Animații: %s Animation (%s ID-uri) · %s KeyframeSequence · %s AnimationController",
		num(anim.count), num(anim.uniqueIds), num(anim.kfsCount), num(anim.controllers)), { medium = true, size = 12, wrap = true })
	local items = {}
	for _, k in anim.kfs or {} do
		table.insert(items, { text = tostring(k.name), note = tostring(k.rig) .. " · " .. UI.fmt(tonumber(k.length) or 0, 2) .. "s",
			icon = "🎬", path = k.path })
	end
	for _, a in anim.list or {} do
		table.insert(items, { text = tostring(a.name), note = a.id ~= "" and tostring(a.id) or "fără ID", icon = "▶", path = a.path })
	end
	if #items > 0 then
		local scroll = UI.scrollList(body, 220)
		for _, it in items do
			UI.item(scroll, it.text, { icon = it.icon, note = it.note, height = 24, onClick = function()
				self:open(it.path)
			end })
		end
	end
end

function Panel:renderStyle(parent, r)
	local style = r.style or {}
	local l = style.lighting or {}
	local body = UI.section(parent, "🎨 Stil vizual", { key = "game.style", collapsed = true })
	if #(style.colors or {}) > 0 then
		UI.label(body, "Culori dominante (după suprafață)", { dim = true, size = 11 })
		swatches(body, style.colors)
	end
	if #(style.materials or {}) > 0 then
		UI.label(body, "Materiale: " .. list(style.materials, 8, function(m)
			return tostring(m.name) .. " " .. UI.fmt(tonumber(m.share) or 0, 0) .. "%"
		end), { size = 12, wrap = true })
	end
	stat(body, "Lighting", string.format("%s · ora %s · luminozitate %s", tostring(l.technology or "?"), tostring(l.clockTime),
		tostring(l.brightness)), (l.technology == "Voxel" or l.technology == "Compatibility") and C.warn or nil)
	local ambient = {}
	for _, hex in { l.ambient, l.outdoorAmbient, l.fogColor } do
		if hex then
			table.insert(ambient, hex)
		end
	end
	if #ambient > 0 then
		UI.label(body, "Ambient · OutdoorAmbient · ceață", { dim = true, size = 11 })
		swatches(body, ambient)
	end
	local atmosphere = style.atmosphere
	stat(body, "Atmosphere", atmosphere and string.format("density %s · haze %s", tostring(atmosphere.density),
		tostring(atmosphere.haze)) or "nu")
	stat(body, "Sky", style.sky and (style.sky.custom and "personalizat" or "implicit") or "nu")
	UI.label(body, "Post-efecte: " .. (#(style.effects or {}) > 0 and table.concat(style.effects, "; ") or "niciunul"),
		{ size = 12, wrap = true })
	local b = style.bounds
	stat(body, "Harta", b and string.format("%s × %s × %s studs", num(b.x), num(b.y), num(b.z)) or "?")
	local terrain = style.terrain or {}
	stat(body, "Teren", (terrain.cells or 0) > 0 and ("da" .. (terrain.clouds and " · nori" or "")) or "nu")
	stat(body, "SpawnLocation", num(style.spawns))
end

function Panel:renderInterface(parent, r)
	local ui, audio = r.ui or {}, r.audio or {}
	local body = UI.section(parent, "🖥 UI și audio", { key = "game.ui", collapsed = true })
	stat(body, "ScreenGui", num(ui.screenGuis) .. "  ·  " .. num(ui.guiObjects) .. " elemente")
	if #(ui.names or {}) > 0 then
		UI.label(body, list(ui.names, 20), { dim = true, size = 11, wrap = true })
	end
	for _, cat in ui.categories or {} do
		UI.label(body, "•  " .. tostring(cat.label) .. ": " .. table.concat(cat.names or {}, ", "), { size = 12, wrap = true })
	end
	stat(body, "Mărime fixă", num(ui.fixedSize) .. " meniuri", (ui.fixedSize or 0) >= 3 and C.warn or nil)
	stat(body, "Billboard / Surface", num(ui.billboards) .. " · " .. num(ui.surfaceGuis))
	stat(body, "Sunete", string.format("%s  (%s unice · %s în buclă)", num(audio.sounds), num(audio.uniqueIds), num(audio.looped)))
	stat(body, "Muzică", audio.music and ("da: " .. list(audio.musicNames, 4)) or "nu")
end

function Panel:renderContext(parent, r)
	local body = UI.section(parent, "📋 Copiază contextul pentru Claude", { key = "game.context", collapsed = true })
	local text = self:context(r)
	UI.label(body, "Descrierea jocului pentru Claude (" .. num(#text) .. " caractere). Clic în casetă, Ctrl+A, Ctrl+C și "
		.. "lipește-o oriunde. Claude (prin Studio MCP) o citește direct din ServerStorage.LostCubeAnalysis.Context.",
		{ dim = true, size = 11, wrap = true })
	local box = textArea(body, text, 240)
	UI.button(UI.hstack(body), "Selectează tot", function()
		box:CaptureFocus()
	end, { style = "ghost" })
end

return Panel
