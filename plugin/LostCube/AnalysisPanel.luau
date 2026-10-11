-- LostCube > Game tab ("Joc"): what LostCube knows about this game (the analysis stored in the place). An overview at the
-- top (place, genre, when it was analysed, the main numbers), then the issues (severity / kind filters, a click opens the
-- script at the line), the suggestions, Claude's analysis, folded detail sections (performance, code, security, avatar,
-- effects and animations, visual style, UI and audio) and the context sent to Claude.
-- The first time it opens in a place it analyzes the game by itself (Analyzer.run, in the background).
local Selection = game:GetService("Selection")
local RunService = game:GetService("RunService")

local UI = require(script.Parent.UI)
local Analyzer = require(script.Parent.Analyzer)
local C = UI.C

local Panel = {}
Panel.__index = Panel

local SEVERITIES = { "high", "medium", "low" }
-- severity -> Studio's coloured alert glyph, its colour token, the chip label, the tooltip
local SEVERITY = {
	high = { icon = "errorColor", token = "danger", chip = "Mari", tip = "Gravitate mare" },
	medium = { icon = "warningColor", token = "warning", chip = "Medii", tip = "Gravitate medie" },
	low = { icon = "infoColor", token = "textDim", chip = "Mici", tip = "Gravitate mică" },
}
local KIND_ORDER = { "security", "remote", "data", "market", "rules", "perf", "anim", "code", "ui", "structure", "deprecated" }
local ISSUES_SHOWN = 40 -- issues listed before "show all"
local AI_EXPECTED = 45 -- seconds a Claude analysis usually takes (the progress bar eases towards it)

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

local escape = UI.escape

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

-- "acum 5 min", "acum 3 ore", "ieri", then the date
local function ago(t)
	local seconds = os.time() - (tonumber(t) or 0)
	if seconds < 60 then
		return "chiar acum"
	elseif seconds < 3600 then
		return "acum " .. math.floor(seconds / 60) .. " min"
	elseif seconds < 86400 then
		local h = math.floor(seconds / 3600)
		return h == 1 and "acum o oră" or ("acum " .. h .. " ore")
	elseif seconds < 2 * 86400 then
		return "ieri"
	elseif seconds < 7 * 86400 then
		return "acum " .. math.floor(seconds / 86400) .. " zile"
	end
	return date(t)
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

local UPPER = { ["ă"] = "Ă", ["â"] = "Â", ["î"] = "Î", ["ș"] = "Ș", ["ț"] = "Ț", ["ş"] = "Ş", ["ţ"] = "Ţ" }
local function capitalize(s)
	s = tostring(s)
	for lower, upper in UPPER do
		if string.sub(s, 1, #lower) == lower then
			return upper .. string.sub(s, #lower + 1)
		end
	end
	return (string.gsub(s, "^%l", string.upper))
end

-- a finding starts with a capital letter, unless it starts with code ("require(…)", "getfenv/setfenv", "wait()")
local function sentence(text)
	text = tostring(text or "")
	local first = string.match(text, "^[^%s]*") or ""
	if string.find(first, "[%(%)/%._:]") then
		return text
	end
	return capitalize(text)
end

-- "security.require" -> "security"
local function kindOf(issue)
	return string.match(issue.kind or "", "^[^%.]+") or "other"
end

local function kindLabel(kind)
	return capitalize(Analyzer.KIND_LABEL and Analyzer.KIND_LABEL[kind] or kind)
end

-- ---------------------------------------------------------------------------------------------
-- small widgets (only here)
-- ---------------------------------------------------------------------------------------------
local function autoFrame(parent, name, children)
	return UI.make("Frame", { Name = name, Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, children)
end

-- a label as wide as its text
local function inlineLabel(parent, text, opts)
	local l = UI.label(parent, text, opts)
	l.Size = UDim2.new(0, 0, 0, opts.height or UI.H)
	l.AutomaticSize = Enum.AutomaticSize.X
	l.TextTruncate = Enum.TextTruncate.None
	return l
end

-- a "label  value" row; color: a token for a value that needs attention ("warning", "danger")
local function stat(body, label, value, color)
	return UI.label(UI.row(body, label), tostring(value), { color = color })
end

-- a small dim group title inside a section (sections are one level only)
local function subhead(body, text)
	UI.spacer(body, 4)
	return UI.label(body, text, { role = "meta", dim = true, medium = true, height = 20 })
end

-- a wrapped line with a small dot in front (suggestions, UI groups)
local function bullet(parent, text)
	local row = autoFrame(parent, "Bullet", { UI.make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder,
		FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Top, Padding = UDim.new(0, 8) }) })
	local holder = UI.make("Frame", { Parent = row, BackgroundTransparency = 1, Size = UDim2.fromOffset(6, 16) })
	local dot = UI.make("Frame", { Parent = holder, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(4, 4) }, { UI.corner(2) })
	UI.skin(dot, { BackgroundColor3 = "textDisabled" })
	local label = UI.label(row, text, { wrap = true })
	label.Size = UDim2.new(1, -14, 0, 0)
	label.LineHeight = 1.15
	return row
end

-- colours as swatches with their share of the surface under them (hex strings or { hex =, share = % })
local function swatches(parent, colors)
	local row = autoFrame(parent, "Swatches", { UI.make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder,
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), Wraps = true }) })
	for _, c in colors or {} do
		local hex = type(c) == "table" and c.hex or c
		local ok, color = pcall(Color3.fromHex, tostring(hex))
		if ok and color then
			local share = type(c) == "table" and tonumber(c.share) or nil
			local cell = UI.make("Frame", { Name = "Swatch", Parent = row, BackgroundTransparency = 1,
				Size = UDim2.fromOffset(34, share and 38 or 20) })
			local sw = UI.make("Frame", { Parent = cell, BackgroundColor3 = color, Size = UDim2.new(1, 0, 0, 20) },
				{ UI.corner(UI.RADIUS.control), UI.stroke("border") }) -- a data colour: shown as it is
			sw.Name = "Color"
			if share then
				local l = UI.label(cell, UI.fmt(share, share < 10 and 1 or 0) .. " %", { role = "meta", dim = true,
					align = Enum.TextXAlignment.Center, height = 16 })
				l.Position = UDim2.fromOffset(0, 22)
			end
			UI.tip(cell, "#" .. string.upper(tostring(hex)) .. (share and ("  ·  " .. UI.fmt(share, 1) .. " % din suprafață") or ""))
		end
	end
	return row
end

-- one finding: Studio's severity glyph, the message, where it is (monospace, dim) and its kind; clickable when it points
-- at something
local function issueRow(parent, issue, onClick)
	local severity = SEVERITY[issue.severity] or SEVERITY.low
	local clickable = onClick ~= nil and issue.path ~= nil
	local row = UI.make("TextButton", { Name = "Issue", Parent = parent, Text = "", AutoButtonColor = false,
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y },
		{ UI.corner(UI.RADIUS.control), UI.pad(6, 8, 6, 8), UI.make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder,
			FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Top,
			Padding = UDim.new(0, 8) }) })
	UI.skin(row, { BackgroundColor3 = "surfaceHover" })
	row:SetAttribute("Severity", issue.severity)
	row:SetAttribute("Kind", issue.kind)
	local glyph = UI.make("Frame", { Name = "Severity", Parent = row, BackgroundTransparency = 1, Size = UDim2.fromOffset(14, 16) })
	UI.icon(glyph, severity.icon, { size = 14, position = UDim2.fromOffset(0, 1) })
	UI.tip(glyph, severity.tip)
	local col = UI.make("Frame", { Parent = row, BackgroundTransparency = 1, Size = UDim2.new(1, -22, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.vlist(2) })
	local message = UI.label(col, sentence(issue.message), { wrap = true })
	message.LineHeight = 1.15
	if issue.path then
		local meta = UI.make("Frame", { Parent = col, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16) })
		local kind = issue.kind and kindLabel(kindOf(issue)) or ""
		local kindW = kind ~= "" and (UI.textWidth(kind, "meta") + 4) or 0
		if issue.path then
			local where = UI.label(meta, tostring(issue.path) .. (issue.line and (":" .. tostring(issue.line)) or ""),
				{ role = "code", dim = true, height = 16 })
			where.Size = UDim2.new(1, -(kindW + 8), 1, 0)
			where.TextTruncate = Enum.TextTruncate.AtEnd
		end
		if kind ~= "" then
			local k = UI.label(meta, kind, { role = "meta", color = "textDisabled", width = kindW, height = 16,
				align = Enum.TextXAlignment.Right })
			k.AnchorPoint = Vector2.new(1, 0)
			k.Position = UDim2.fromScale(1, 0)
		end
	end
	if clickable then
		row.MouseEnter:Connect(function()
			row.BackgroundTransparency = 0
		end)
		row.MouseLeave:Connect(function()
			row.BackgroundTransparency = 1
		end)
		row.MouseButton1Click:Connect(onClick)
		UI.tip(row, issue.line and ("Deschide scriptul la linia " .. tostring(issue.line)) or "Selectează în Explorer")
	end
	return row
end

-- read-only but selectable text on a code surface (Ctrl+A / Ctrl+C work; typing is undone)
local function textArea(parent, text, height)
	local scroll = UI.make("ScrollingFrame", { Name = "TextArea", Parent = parent, Size = UDim2.new(1, 0, 0, height),
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.Y, VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar },
		{ UI.corner(UI.RADIUS.control), UI.stroke("border") })
	UI.skin(scroll, { BackgroundColor3 = "field", ScrollBarImageColor3 = "scrollbar" })
	local props = { Parent = scroll, Text = text, BackgroundTransparency = 1, ClearTextOnFocus = false, MultiLine = true,
		TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }
	UI.textStyle(props, "code")
	local box = UI.make("TextBox", props, { UI.pad(8, 10, 8, 10) })
	UI.skin(box, { TextColor3 = "text" })
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
		local note = UI.note(parent, "Secțiunea nu s-a putut afișa: " .. escape(clean(err)), "danger")
		note:SetAttribute("SectionError", true)
		warn("LostCube:", err)
	end
end

-- A section that starts folded is not built until it is opened: the whole tab is redrawn on every refresh, and most of
-- these sections are long lists nobody is looking at (the context box alone is 15000 characters of text layout).
local function lazySection(parent, title, opts, build)
	local body
	local built = false
	local function fill()
		if not built then
			built = true
			safe(body, build, body)
		end
	end
	opts.onToggle = function(collapsed)
		if not collapsed then
			fill()
		end
	end
	body = UI.section(parent, title, opts)
	if not UI.collapsed[opts.key or title] then
		fill()
	end
	return body
end

-- ---------------------------------------------------------------------------------------------
-- state + actions
-- ---------------------------------------------------------------------------------------------
function Panel.new(ctx)
	local self = setmetatable({ ctx = ctx, report = nil, loaded = false, running = false, fraction = 0, label = "",
		filter = "all", kind = "all", showAll = false, aiRunning = false }, Panel)
	-- the instance count that decides "the game changed a lot" runs in the background (Analyzer.isStale): when it is
	-- done, redraw only if the answer changed and this tab is the one on screen
	self.onCounts = function()
		local app = self.ctx.app
		if self.dead or self.running or not self.report or (app and app.tab ~= "Game") then
			return
		end
		local ok, stale = pcall(Analyzer.isStale, self.report)
		if ok and (stale == true) ~= (self.staleShown == true) then
			self:refresh()
		end
	end
	return self
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
	local again = self.report ~= nil
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
				UI.toast(self.error, "warning")
			elseif again then
				UI.toast("Analiza jocului s-a actualizat.", "success")
			end
		else
			self.error = "Analiza a eșuat: " .. clean(result)
			UI.toast(self.error, "error")
			warn("LostCube:", result)
		end
		self:refresh()
	end)
end

function Panel:updateProgress()
	local ui = self.progressUI
	if ui and ui.track.Parent then
		ui.set(self.fraction)
		ui.percent.Text = math.floor(self.fraction * 100 + 0.5) .. " %"
		ui.label.Text = tostring(self.label or "")
	end
end

-- selects what a finding points at; scripts open in the editor at the line
function Panel:open(path, line)
	local inst = Analyzer.resolve(path)
	if not inst then
		self.error = "Nu mai găsesc „" .. tostring(path) .. "”. A fost mutat sau șters? Reanalizează jocul."
		UI.toast(self.error, "warning")
		return
	end
	self.error = nil
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
		self.contextText = ok and text or ("Contextul nu s-a putut genera: " .. clean(text))
		self.contextFor = report
	end
	return self.contextText
end

-- the Claude analysis line while it runs: elapsed seconds and a bar that eases towards the usual duration
function Panel:updateAIProgress()
	local ui = self.aiUI
	if not (ui and ui.track.Parent) then
		return
	end
	local elapsed = math.max(0, os.clock() - (self.aiStarted or os.clock()))
	ui.set(math.min(0.95, 1 - math.exp(-elapsed / AI_EXPECTED)))
	ui.time.Text = math.floor(elapsed) .. " s"
	ui.status.Text = self.aiStatus and capitalize(self.aiStatus) or "Poate dura până la un minut."
end

function Panel:startAITicker()
	task.spawn(function()
		while self.aiRunning and not self.dead do
			self:updateAIProgress()
			task.wait(0.5)
		end
	end)
end

-- Claude's analysis of the game (AI.luau); yields, so it runs in the background
function Panel:askClaude()
	local AI = optional("AI")
	if self.aiRunning or not self.report then
		return
	end
	if not AI or type(AI.analyzeGame) ~= "function" then
		self.aiError = "Legătura cu Claude lipsește din această versiune a pluginului."
		self:refresh()
		return
	end
	self.aiRunning, self.aiError, self.aiStatus, self.aiInfo = true, nil, nil, nil
	self.aiStarted = os.clock()
	local context = self:context(self.report)
	self:refresh()
	self:startAITicker()
	task.spawn(function()
		local ok, success, text, info = pcall(AI.analyzeGame, self.ctx.plugin, context, {
			onStatus = function(status)
				self.aiStatus = status
				self:updateAIProgress()
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
			self.aiInfo = type(info) == "table" and info or nil
			local current = self.report -- the report may be the table Analyzer.load() shares: a copy gets the answer
			if current then
				local updated = table.clone(current)
				updated.ai = { text = text, model = model, at = os.time() }
				if self.contextFor == current then
					self.contextFor = updated -- the Markdown for Claude does not include its own answer
				end
				self.report = updated
			end
			local saved, err = pcall(Analyzer.setAI, text, model)
			if not saved then
				self.aiError = "Analiza lui Claude nu s-a putut salva în joc: " .. clean(err)
				UI.toast(self.aiError, "warning")
			else
				UI.toast("Analiza lui Claude e gata și s-a salvat în joc.", "success")
			end
		else
			self.aiError = clean(ok and (text or "Claude nu a răspuns.") or success)
			UI.toast("Analiza lui Claude a eșuat.", "error")
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
	self.progressUI, self.aiUI = nil, nil
	local report = self.report
	if not report then
		if self.running then
			self:renderFirstScan(parent)
		else
			UI.empty(parent, "LostCube citește scripturile, harta, efectele și interfața, apoi salvează analiza în joc, "
				.. "ca Claude să-l cunoască.", "Analizează jocul", function()
				self:analyze()
			end, { icon = "game", title = "Jocul nu e analizat încă" })
		end
		return
	end
	safe(parent, self.renderOverview, self, parent, report)
	safe(parent, self.renderIssues, self, parent, report)
	safe(parent, self.renderSuggestions, self, parent, report)
	safe(parent, self.renderAI, self, parent, report)
	safe(parent, self.renderPerformance, self, parent, report)
	safe(parent, self.renderCode, self, parent, report)
	safe(parent, self.renderSecurity, self, parent, report)
	safe(parent, self.renderAvatar, self, parent, report)
	safe(parent, self.renderVFX, self, parent, report)
	safe(parent, self.renderStyle, self, parent, report)
	safe(parent, self.renderInterface, self, parent, report)
	safe(parent, self.renderContext, self, parent, report)
end

-- the progress of an analysis: what it does, how far it is, the bar
function Panel:progressBlock(parent)
	local block = autoFrame(parent, "Progress", { UI.vlist(6) })
	local head = UI.make("Frame", { Parent = block, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20) })
	local title = UI.label(head, self.report and "Reanalizez jocul…" or "Analizez jocul…", { medium = true, height = 20 })
	title.Size = UDim2.new(1, -56, 1, 0)
	local percent = UI.label(head, "", { role = "meta", dim = true, width = 52, height = 20, align = Enum.TextXAlignment.Right })
	percent.AnchorPoint = Vector2.new(1, 0)
	percent.Position = UDim2.fromScale(1, 0)
	local track, set = UI.progress(block, self.fraction)
	local label = UI.label(block, "", { role = "meta", dim = true, height = 16 })
	self.progressUI = { track = track, fill = track:FindFirstChild("Fill"), set = set, percent = percent, label = label }
	self:updateProgress()
	return block
end

-- no analysis yet and the first one is running
function Panel:renderFirstScan(parent)
	local frame = autoFrame(parent, "FirstScan", { UI.pad(UI.SPACE.xl, 0, UI.SPACE.lg, 0), UI.vlist(UI.SPACE.md) })
	local top = autoFrame(frame, "Intro", { UI.make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, UI.SPACE.sm), HorizontalAlignment = Enum.HorizontalAlignment.Center }) })
	UI.icon(top, "game", { size = 24, color = "textDisabled" })
	UI.label(top, "Prima analiză a jocului", { role = "emphasis", color = "textBright", align = Enum.TextXAlignment.Center,
		height = 20 })
	UI.label(top, "Durează puțin la jocurile mari. Studio rămâne utilizabil între timp.", { dim = true, wrap = true,
		align = Enum.TextXAlignment.Center })
	self:progressBlock(frame)
end

-- one number of the overview: value over a dim label
local function statCell(parent, width, value, label, first)
	local cell = UI.make("Frame", { Name = "Stat", Parent = parent, BackgroundTransparency = 1,
		Size = UDim2.new(width, 0, 1, 0) }, { UI.pad(0, 0, 0, first and 0 or 12) })
	if not first then
		local line = UI.make("Frame", { Name = "Divider", Parent = cell, Position = UDim2.fromOffset(-12, 4),
			Size = UDim2.new(0, 1, 1, -8) })
		UI.skin(line, { BackgroundColor3 = "divider" })
	end
	local holder = UI.make("Frame", { Name = "Value", Parent = cell, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20) },
		{ UI.hlist(4, false) })
	if value then
		inlineLabel(holder, value, { role = "emphasis", color = "textBright", height = 20 })
	end
	local l = UI.label(cell, label, { role = "meta", dim = true, height = 16 })
	l.Position = UDim2.fromOffset(0, 20)
	return cell, holder
end

function Panel:renderOverview(parent, r)
	local place, totals, genre = r.place or {}, r.totals or {}, r.genre or {}
	local head = autoFrame(parent, "Overview", { UI.vlist(UI.SPACE.sm), UI.pad(UI.SPACE.xs, 0, UI.SPACE.xs, 0) })

	-- place name, actions
	local titleRow = UI.make("Frame", { Name = "Title", Parent = head, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24) })
	local title = UI.label(titleRow, tostring(place.title or place.name or "Jocul"), { role = "title", color = "textBright" })
	title.Size = UDim2.new(1, -60, 1, 0)
	local actions = UI.make("Frame", { Parent = titleRow, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 56, 1, 0) },
		{ UI.make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4),
			FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Center }) })
	UI.iconButton(actions, "explorer", function()
		local okStorage, storage = pcall(function()
			return game:GetService("ServerStorage"):FindFirstChild(Analyzer.FOLDER)
		end)
		if okStorage and storage then
			Selection:Set({ storage })
		end
	end, { tip = "Arată raportul în Explorer (ServerStorage.LostCubeAnalysis)" })
	UI.iconButton(actions, "refresh", function()
		self:analyze()
	end, { tip = "Reanalizează jocul: citește din nou tot și înlocuiește analiza salvată", disabled = self.running })

	-- genre (with its confidence) and when it was analysed
	local meta = UI.make("Frame", { Name = "Meta", Parent = head, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18) },
		{ UI.hlist(UI.SPACE.sm, false) })
	local confidence = math.floor((tonumber(genre.confidence) or 0) * 100 + 0.5)
	local genreName = string.gsub(tostring(genre.label or "necunoscut"), "%s*%b()%s*$", "")
	local badge = UI.badge(meta, confidence > 0 and string.format("%s · %d %%", capitalize(genreName), confidence)
		or ("Gen " .. genreName), confidence >= 60 and "accent" or "neutral")
	local tip = { "Gen: " .. tostring(genre.label or "?") .. " (încredere " .. tostring(genre.level or "?") .. ")" }
	if genre.secondary then
		table.insert(tip, "Seamănă și cu: " .. tostring(genre.secondary.label))
	end
	if #(genre.evidence or {}) > 0 then
		table.insert(tip, "Indicii: " .. list(genre.evidence, 8))
	end
	UI.tip(badge, table.concat(tip, "\n"))
	local when = inlineLabel(meta, "Analizat " .. ago(r.at), { role = "meta", dim = true, height = 18 })
	UI.tip(when, date(r.at) .. " · durata analizei " .. tostring(r.duration or "?") .. " s"
		.. ((tonumber(place.placeId) or 0) > 0 and ("\nPlaceId " .. tostring(place.placeId)) or ""))

	local okStale, stale = pcall(Analyzer.isStale, r, self.onCounts)
	self.staleShown = okStale and stale or false
	if okStale and stale and not self.running then
		UI.note(head, "Analiza e veche sau jocul s-a schimbat mult de atunci. Reanalizează jocul.", "warning")
	end

	if self.running then
		self:progressBlock(head)
		return
	end
	-- the main numbers
	local issues = r.issues or {}
	local counts = { high = 0, medium = 0, low = 0 }
	for _, issue in issues do
		counts[issue.severity] = (counts[issue.severity] or 0) + 1
	end
	local stats = UI.make("Frame", { Name = "Stats", Parent = head, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36) },
		{ UI.hlist(0, false) })
	UI.tip(statCell(stats, 0.28, num(totals.instances), "Instanțe", true), num(totals.parts) .. " piese · "
		.. num(totals.remotes) .. " remote-uri")
	UI.tip(statCell(stats, 0.28, num(totals.scripts), "Scripturi"), num(totals.lines) .. " linii de cod")
	local cell, holder = statCell(stats, 0.44, nil, "Probleme")
	for _, severity in SEVERITIES do
		local s = SEVERITY[severity]
		local pair = UI.make("Frame", { Name = "Count_" .. severity, Parent = holder, BackgroundTransparency = 1,
			Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X }, { UI.hlist(5, false) })
		local dot = UI.make("Frame", { Parent = pair, Size = UDim2.fromOffset(6, 6) }, { UI.corner(3) })
		UI.skin(dot, { BackgroundColor3 = severity == "low" and "textDisabled" or s.token })
		inlineLabel(pair, num(counts[severity]), { role = "emphasis", color = counts[severity] > 0 and "textBright" or "textDim",
			height = 20 })
		UI.spacer(holder, 0).Size = UDim2.fromOffset(4, 0)
	end
	UI.tip(cell, string.format("%d mari · %d medii · %d mici", counts.high, counts.medium, counts.low))
end

function Panel:renderIssues(parent, r)
	local issues = r.issues or {}
	-- kinds present (for the kind filter), in the Analyzer's order
	local kindCount = {}
	for _, issue in issues do
		local k = kindOf(issue)
		kindCount[k] = (kindCount[k] or 0) + 1
	end
	if self.kind ~= "all" and not kindCount[self.kind] then
		self.kind = "all"
	end
	local kindItems = { { value = "all", label = "Toate tipurile" }, { separator = true } }
	local known = {}
	for _, k in KIND_ORDER do
		if kindCount[k] then
			table.insert(kindItems, { value = k, label = kindLabel(k), hint = tostring(kindCount[k]) })
			known[k] = true
		end
	end
	for k, n in kindCount do
		if not known[k] then
			table.insert(kindItems, { value = k, label = kindLabel(k), hint = tostring(n) })
		end
	end
	local body = UI.section(parent, "Probleme", { key = "game.issues", badge = #issues,
		right = #issues > 0 and function(right)
			UI.dropdown(right, kindItems, self.kind, function(value)
				self.kind, self.showAll = value, false
				self:refresh()
			end, { style = "ghost", text = self.kind == "all" and "Toate tipurile" or kindLabel(self.kind), width = 118,
				menuWidth = 190, tip = "Filtrează după tip" })
		end or nil, rightWidth = 120 })
	if #issues == 0 then
		UI.empty(body, "Nu am găsit probleme în joc.", nil, nil, { icon = "check" })
		return
	end
	-- severity chips (counts of the chosen kind)
	local counts = { all = 0, high = 0, medium = 0, low = 0 }
	for _, issue in issues do
		if self.kind == "all" or kindOf(issue) == self.kind then
			counts.all += 1
			counts[issue.severity] = (counts[issue.severity] or 0) + 1
		end
	end
	local chips = UI.make("Frame", { Name = "Filters", Parent = body, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H) },
		{ UI.hlist(UI.SPACE.xs, false) })
	local dimHex = C.textDim:ToHex()
	for _, f in { { "all", "Toate" }, { "high", SEVERITY.high.chip }, { "medium", SEVERITY.medium.chip },
		{ "low", SEVERITY.low.chip } } do
		local value, label = f[1], f[2]
		local chip = UI.chip(chips, label, { selected = self.filter == value, onClick = function()
			self.filter, self.showAll = value, false
			self:refresh()
		end })
		chip.RichText = true
		chip.Text = escape(label) .. '  <font color="#' .. dimHex .. '">' .. tostring(counts[value] or 0) .. "</font>"
		chip.Name = "Filter_" .. value
	end
	local shown = {}
	for _, issue in issues do
		if (self.filter == "all" or issue.severity == self.filter) and (self.kind == "all" or kindOf(issue) == self.kind) then
			table.insert(shown, issue)
		end
	end
	if #shown == 0 then
		UI.label(body, "Nicio problemă cu acest filtru.", { dim = true })
		return
	end
	local scroll = UI.scrollList(body, 440)
	for i, issue in shown do
		if i > ISSUES_SHOWN and not self.showAll then
			break
		end
		issueRow(scroll, issue, function()
			self:open(issue.path, issue.line)
		end)
	end
	if #shown > ISSUES_SHOWN and not self.showAll then
		local row = UI.hstack(body, { fill = false })
		UI.button(row, "Arată toate", function()
			self.showAll = true
			self:refresh()
		end, { style = "ghost", autoWidth = true })
		UI.badge(row, tostring(#shown))
	end
end

function Panel:renderSuggestions(parent, r)
	local suggestions = r.suggestions or {}
	if #suggestions == 0 then
		return
	end
	local body = UI.section(parent, "Sugestii", { key = "game.suggestions", badge = #suggestions })
	for _, s in suggestions do
		bullet(body, tostring(s))
	end
end

function Panel:renderAI(parent, r)
	local body = UI.section(parent, "Analiză Claude", { key = "game.ai" })
	local AI = optional("AI")
	local hasKey = false
	if AI and type(AI.getKey) == "function" then
		local ok, key = pcall(AI.getKey, self.ctx.plugin)
		hasKey = ok and type(key) == "string" and key ~= ""
	end
	local ai = r.ai
	local hasAnswer = type(ai) == "table" and type(ai.text) == "string" and ai.text ~= ""
	if not AI then
		UI.note(body, "Legătura cu Claude lipsește din această versiune a pluginului.", "warning")
	elseif not hasKey then
		UI.note(body, "Adaugă cheia API Anthropic în tab-ul Claude ca să ceri o analiză a jocului: ce merge, ce lipsește "
			.. "și ce să faci mai întâi.")
		local row = UI.hstack(body, { fill = false })
		UI.button(row, "Deschide tab-ul Claude", function()
			local app = self.ctx.app
			if app and type(app.render) == "function" then
				app.tab = "Claude"
				if type(app.save) == "function" then
					pcall(app.save, app, "tab", "Claude")
				end
				app:render()
			end
		end, { style = "link", autoWidth = true })
	end
	if self.aiRunning then
		local block = autoFrame(body, "ClaudeProgress", { UI.vlist(6) })
		local head = UI.make("Frame", { Parent = block, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20) })
		local title = UI.label(head, "Claude analizează jocul…", { medium = true, height = 20 })
		title.Size = UDim2.new(1, -56, 1, 0)
		local time = UI.label(head, "0 s", { role = "meta", dim = true, width = 52, height = 20, align = Enum.TextXAlignment.Right })
		time.AnchorPoint = Vector2.new(1, 0)
		time.Position = UDim2.fromScale(1, 0)
		local track, set = UI.progress(block, 0)
		local status = UI.label(block, "", { role = "meta", dim = true, height = 16 })
		self.aiUI = { track = track, set = set, time = time, status = status }
		self:updateAIProgress()
	elseif AI and hasKey and not hasAnswer then
		local row = UI.hstack(body, { height = UI.H_LARGE, fill = false })
		UI.button(row, "Analizează cu Claude", function()
			self:askClaude()
		end, { style = "primary", icon = "chat", autoWidth = true, height = UI.H_LARGE })
		UI.label(body, "Trimite contextul jocului (" .. num(#self:context(r)) .. " caractere). Răspunsul se salvează în joc.",
			{ role = "meta", dim = true, wrap = true })
	end
	if self.aiError then
		UI.note(body, escape(self.aiError), "danger")
	end
	if not hasAnswer then
		return
	end
	-- the answer: who and when, a quiet surface with the Markdown, the usage
	local metaRow = UI.make("Frame", { Name = "AnswerMeta", Parent = body, BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, UI.H) })
	local modelName = tostring(ai.model ~= "" and ai.model or "Claude")
	if AI and type(AI.modelInfo) == "function" then
		local okInfo, info = pcall(AI.modelInfo, ai.model)
		if okInfo and type(info) == "table" and info.short then
			modelName = info.short
		end
	end
	local who = UI.label(metaRow, string.format("%s · %s", modelName, date(ai.at)), { role = "meta", dim = true })
	who.Size = UDim2.new(1, -120, 1, 0)
	if AI and hasKey and not self.aiRunning then
		local again = UI.button(metaRow, "Analiză nouă", function()
			self:askClaude()
		end, { style = "ghost", icon = "refresh", autoWidth = true,
			tip = "Trimite din nou contextul jocului (" .. num(#self:context(r)) .. " caractere)" })
		again.AnchorPoint = Vector2.new(1, 0)
		again.Position = UDim2.fromScale(1, 0)
	end
	local surface = UI.make("Frame", { Name = "Answer", Parent = body, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.corner(UI.RADIUS.surface), UI.pad(12, 12, 12, 12), UI.vlist(4) })
	UI.skin(surface, { BackgroundColor3 = "raised" })
	local Markdown = optional("Markdown")
	local ok = Markdown and type(Markdown.render) == "function" and pcall(Markdown.render, surface, ai.text)
	if not ok then
		for _, child in surface:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		UI.label(surface, ai.text, { wrap = true })
	end
	if self.aiInfo and AI and type(AI.describeInfo) == "function" then
		local okInfo, usage = pcall(AI.describeInfo, self.aiInfo)
		if okInfo and type(usage) == "string" and usage ~= "" then
			UI.label(body, usage, { role = "meta", color = "textDisabled", wrap = true })
		end
	end
end

function Panel:renderPerformance(parent, r)
	lazySection(parent, "Performanță", { key = "game.perf", collapsed = true }, function(body)
		self:fillPerformance(body, r)
	end)
end

function Panel:fillPerformance(body, r)
	local p = r.performance or {}
	local function warnIf(cond)
		return cond and "warning" or nil
	end
	stat(body, "Piese", string.format("%s  (Workspace %s)", num(p.parts), num(p.workspaceParts)))
	stat(body, "Neancorate", num(p.loose) .. " libere · " .. num(p.unanchored) .. " total", warnIf((p.loose or 0) > 300))
	stat(body, "MeshPart", string.format("%s · %s unice · %s coliziune precisă", num(p.meshParts), num(p.uniqueMeshes),
		num(p.preciseCollision)), warnIf((p.preciseCollision or 0) > 150))
	stat(body, "Union", num(p.unions), warnIf((p.unions or 0) > 400))
	stat(body, "Particule", string.format("%s emițătoare · %s /s · %s dense", num(p.emitters), num(p.particleRate),
		num(p.heavyEmitters)), warnIf((p.particleRate or 0) > 3000))
	stat(body, "Lumini", string.format("%s  (%s cu umbre)", num(p.lights), num(p.shadowLights)),
		warnIf((p.shadowLights or 0) > 25))
	stat(body, "NPC (Humanoid)", num(p.humanoids), warnIf((p.humanoids or 0) > 80))
	stat(body, "Bucle per frame", string.format("%s Heartbeat · %s RenderStepped", num(p.runService),
		num(p.renderStepped)), warnIf((p.runService or 0) > 40))
	stat(body, "Touched", num(p.touched), warnIf((p.touched or 0) > 150))
	stat(body, "while fără wait", num(p.busyLoops), (p.busyLoops or 0) > 0 and "danger" or nil)
	stat(body, "Sunete, decal-uri", string.format("%s · %s  (%s texturi unice)", num(p.sounds), num(p.decals),
		num(p.uniqueTextures)))
	stat(body, "Streaming", yes(p.streamingEnabled))
	stat(body, "Teren", (p.terrainCells or 0) > 0 and (num(p.terrainCells) .. " celule") or "nu")
end

function Panel:renderCode(parent, r)
	lazySection(parent, "Cod", { key = "game.code", collapsed = true }, function(body)
		self:fillCode(body, r)
	end)
end

function Panel:fillCode(body, r)
	local code = r.code or {}
	stat(body, "Scripturi", string.format("%s Script · %s Local · %s Module", num(code.scripts), num(code.localScripts),
		num(code.modules)))
	stat(body, "Linii", num(code.lines) .. ((code.disabled or 0) > 0 and ("  ·  " .. num(code.disabled) .. " dezactivate") or ""))
	local frameworks = list(code.frameworks, 10, function(fw)
		return fw.name
	end)
	stat(body, "Framework-uri", frameworks ~= "" and frameworks or "niciunul detectat")
	local ds = code.datastore or {}
	stat(body, "DataStore", ds.used and string.format("BindToClose %s · %s Set · %s Update", yes(ds.bindToClose), num(ds.set),
		num(ds.update)) or "nu", ds.used and not ds.bindToClose and "warning" or nil)
	local market = code.marketplace or {}
	stat(body, "Monetizare", string.format("%s gamepass · %s produse · ProcessReceipt %s", num(#(market.gamepasses or {})),
		num(#(market.products or {})), num(market.processReceipt)))
	stat(body, "Remote handler", string.format("%s  (%s fără validare)", num(code.remoteHandlers), num(code.unvalidated)),
		(code.unvalidated or 0) > 0 and "warning" or nil)
	if #(code.services or {}) > 0 then
		UI.label(body, "Servicii: " .. list(code.services, 14, function(s)
			return s.name .. " " .. tostring(s.count)
		end), { role = "meta", dim = true, wrap = true })
	end

	if #(code.largest or {}) > 0 then
		subhead(body, "Cele mai mari scripturi")
		for i, s in code.largest do
			if i > 8 then
				break
			end
			UI.item(body, tostring(s.path), { classIcon = s.class or "Script", note = num(s.lines) .. " linii", noteWidth = 72,
				height = 24, onClick = function()
					self:open(s.path, 1)
				end })
		end
	end
	local remotes = code.remotes or {}
	if #remotes > 0 then
		subhead(body, "Remote-uri și Bindable-uri")
		local scroll = UI.scrollList(body, 200)
		for _, rem in remotes do
			UI.item(scroll, tostring(rem.name), { classIcon = tostring(rem.class), note = rem.path and tostring(rem.path) or nil,
				noteWidth = 120, height = 24, onClick = function()
					self:open(rem.path)
				end })
		end
	end
	if #(code.deprecated or {}) > 0 then
		subhead(body, "API-uri învechite")
		for _, d in code.deprecated do
			UI.item(body, tostring(d.label) .. " → " .. tostring(d.fix), { icon = "script", note = (tonumber(d.count) == 1 and "1 loc" or (num(d.count) .. " locuri")),
				noteWidth = 64, height = 24, muted = true, onClick = function()
					self:open(d.path, d.line)
				end })
		end
	end
end

function Panel:renderSecurity(parent, r)
	local found = {}
	for _, issue in r.issues or {} do
		local kind = issue.kind or ""
		if string.sub(kind, 1, 9) == "security." or string.sub(kind, 1, 7) == "remote." then
			table.insert(found, issue)
		end
	end
	lazySection(parent, "Securitate", { key = "game.security", collapsed = true, badge = #found }, function(body)
		self:fillSecurity(body, r, found)
	end)
end

function Panel:fillSecurity(body, r, found)
	local security = r.security or {}
	local counts = security.counts or {}
	if #found == 0 then
		UI.note(body, "Nu am găsit semnături de backdoor: require cu ID, loadstring, cod ofuscat, cumpărări ascunse, "
			.. "scripturi în locuri ciudate.", "success")
	else
		local row = UI.make("Frame", { Name = "Counts", Parent = body, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20) },
			{ UI.hlist(UI.SPACE.xs, false) })
		UI.badge(row, num(counts.high or 0) .. " mari", (counts.high or 0) > 0 and "danger" or "neutral")
		UI.badge(row, num(counts.medium or 0) .. " medii", (counts.medium or 0) > 0 and "warning" or "neutral")
		UI.badge(row, num(counts.low or 0) .. " mici", "neutral")
		local scroll = UI.scrollList(body, 320)
		for i, issue in found do
			if i > 30 then
				break
			end
			issueRow(scroll, issue, function()
				self:open(issue.path, issue.line)
			end)
		end
	end
	stat(body, "LoadString", security.loadStringEnabled and "activat" or "oprit", security.loadStringEnabled and "warning" or nil)
	stat(body, "HttpService", security.httpEnabled and "activat" or "oprit")
	if #(security.hosts or {}) > 0 then
		UI.label(body, "Adrese web din cod: " .. list(security.hosts, 12), { role = "meta", dim = true, wrap = true })
	end
	UI.label(body, "Un free model se verifică înainte de a-l pune în joc cu Analyzer.scanInstance(model).",
		{ role = "meta", dim = true, wrap = true })
end

function Panel:renderAvatar(parent, r)
	lazySection(parent, "Avatar", { key = "game.avatar", collapsed = true }, function(body)
		self:fillAvatar(body, r)
	end)
end

function Panel:fillAvatar(body, r)
	local a = r.avatar or {}
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
		UI.label(body, "StarterCharacterScripts: " .. list(a.characterScripts, 15), { role = "meta", dim = true, wrap = true })
	end
	if #(a.playerScripts or {}) > 0 then
		UI.label(body, "StarterPlayerScripts: " .. list(a.playerScripts, 15), { role = "meta", dim = true, wrap = true })
	end
end

function Panel:renderVFX(parent, r)
	lazySection(parent, "Efecte și animații", { key = "game.vfx", collapsed = true }, function(body)
		self:fillVFX(body, r)
	end)
end

function Panel:fillVFX(body, r)
	local vfx, anim = r.vfx or {}, r.animations or {}
	local counts = {}
	for class, n in vfx.counts or {} do
		table.insert(counts, { class = class, n = tonumber(n) or 0 })
	end
	table.sort(counts, function(a, b)
		return a.n > b.n or (a.n == b.n and a.class < b.class)
	end)
	if #counts == 0 then
		UI.label(body, "Niciun efect în joc.", { dim = true })
	end
	for i, c in counts do
		if i > 8 then
			break
		end
		UI.item(body, c.class, { classIcon = c.class, note = num(c.n), height = 24 })
	end
	stat(body, "Efecte LostCube", num(vfx.lostCubeEffects))
	if #(vfx.colors or {}) > 0 then
		subhead(body, "Culorile efectelor")
		swatches(body, vfx.colors)
	end
	if #(vfx.textures or {}) > 0 then
		UI.label(body, "Texturi: " .. list(vfx.textures, 6, function(t)
			return tostring(t.id):gsub("^rbxassetid://", "") .. " (" .. tostring(t.count) .. ")"
		end), { role = "meta", dim = true, wrap = true })
	end
	if #(vfx.examples or {}) > 0 then
		subhead(body, "Exemple")
		for i, e in vfx.examples do
			if i > 6 then
				break
			end
			UI.item(body, tostring(e.name), { classIcon = tostring(e.class), note = (tostring(e.class):gsub("Emitter", "")),
				noteWidth = 72, height = 24, onClick = function()
					self:open(e.path)
				end })
		end
	end

	subhead(body, "Animații")
	stat(body, "Animation", string.format("%s  (%s ID-uri)", num(anim.count), num(anim.uniqueIds)))
	stat(body, "KeyframeSeq.", num(anim.kfsCount))
	stat(body, "Controller", num(anim.controllers))
	local items = {}
	for _, k in anim.kfs or {} do
		table.insert(items, { text = tostring(k.name), note = tostring(k.rig) .. " · " .. UI.fmt(tonumber(k.length) or 0, 2) .. " s",
			class = "KeyframeSequence", path = k.path })
	end
	for _, a in anim.list or {} do
		table.insert(items, { text = tostring(a.name), note = a.id ~= "" and tostring(a.id) or "fără ID", class = "Animation",
			path = a.path })
	end
	if #items > 0 then
		local scroll = UI.scrollList(body, 220)
		for _, it in items do
			UI.item(scroll, it.text, { classIcon = it.class, note = it.note, noteWidth = 96, height = 24, onClick = function()
				self:open(it.path)
			end })
		end
	end
end

function Panel:renderStyle(parent, r)
	lazySection(parent, "Stil vizual", { key = "game.style", collapsed = true }, function(body)
		self:fillStyle(body, r)
	end)
end

function Panel:fillStyle(body, r)
	local style = r.style or {}
	local l = style.lighting or {}
	if #(style.colors or {}) > 0 then
		subhead(body, "Culori dominante")
		swatches(body, style.colors)
	end
	if #(style.materials or {}) > 0 then
		stat(body, "Materiale", list(style.materials, 4, function(m)
			return tostring(m.name) .. " " .. UI.fmt(tonumber(m.share) or 0, 0) .. " %"
		end))
	end
	stat(body, "Lighting", string.format("%s · ora %s · luminozitate %s", tostring(l.technology or "?"), tostring(l.clockTime),
		tostring(l.brightness)), (l.technology == "Voxel" or l.technology == "Compatibility") and "warning" or nil)
	local ambient = {}
	for _, hex in { l.ambient, l.outdoorAmbient, l.fogColor } do
		if hex then
			table.insert(ambient, hex)
		end
	end
	if #ambient > 0 then
		subhead(body, "Ambient · OutdoorAmbient · ceață")
		swatches(body, ambient)
	end
	local atmosphere = style.atmosphere
	stat(body, "Atmosphere", atmosphere and string.format("density %s · haze %s", tostring(atmosphere.density),
		tostring(atmosphere.haze)) or "nu")
	stat(body, "Sky", style.sky and (style.sky.custom and "personalizat" or "implicit") or "nu")
	stat(body, "Post-efecte", #(style.effects or {}) > 0 and table.concat(style.effects, "; ") or "niciunul")
	local b = style.bounds
	stat(body, "Harta", b and string.format("%s × %s × %s studs", num(b.x), num(b.y), num(b.z)) or "?")
	local terrain = style.terrain or {}
	stat(body, "Teren", (terrain.cells or 0) > 0 and ("da" .. (terrain.clouds and " · nori" or "")) or "nu")
	stat(body, "SpawnLocation", num(style.spawns))
end

function Panel:renderInterface(parent, r)
	lazySection(parent, "UI și audio", { key = "game.ui", collapsed = true }, function(body)
		self:fillInterface(body, r)
	end)
end

function Panel:fillInterface(body, r)
	local ui, audio = r.ui or {}, r.audio or {}
	stat(body, "ScreenGui", num(ui.screenGuis) .. "  ·  " .. num(ui.guiObjects) .. " elemente")
	if #(ui.names or {}) > 0 then
		UI.label(body, list(ui.names, 20), { role = "meta", dim = true, wrap = true })
	end
	for _, cat in ui.categories or {} do
		bullet(body, tostring(cat.label) .. ": " .. table.concat(cat.names or {}, ", "))
	end
	stat(body, "Mărime fixă", num(ui.fixedSize) .. " meniuri", (ui.fixedSize or 0) >= 3 and "warning" or nil)
	stat(body, "Billboard, Surface", num(ui.billboards) .. " · " .. num(ui.surfaceGuis))
	stat(body, "Sunete", string.format("%s  (%s unice · %s în buclă)", num(audio.sounds), num(audio.uniqueIds), num(audio.looped)))
	stat(body, "Muzică", audio.music and ("da: " .. list(audio.musicNames, 4)) or "nu")
end

function Panel:renderContext(parent, r)
	lazySection(parent, "Context pentru Claude", { key = "game.context", collapsed = true }, function(body)
		self:fillContext(body, r)
	end)
end

function Panel:fillContext(body, r)
	local text = self:context(r)
	UI.label(body, num(#text) .. " caractere · ServerStorage.LostCubeAnalysis.Context", { role = "meta", dim = true })
	local box = textArea(body, text, 220)
	local row = UI.hstack(body, { fill = false })
	UI.button(row, "Selectează tot", function()
		box:CaptureFocus()
	end, { autoWidth = true, tip = "Selectează textul, apoi Ctrl+C; Claude Code îl citește direct din joc" })
	inlineLabel(row, "apoi Ctrl+C", { role = "meta", dim = true })
end

return Panel
