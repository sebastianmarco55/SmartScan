-- LostCube > Claude tab: chat with Claude about this game (Anthropic API, your own key), the key / model settings,
-- the modules Claude needs in the game, and what was done with LostCube.
local UI = require(script.Parent.UI)
local Installer = require(script.Parent.Installer)
local AI = require(script.Parent.AI)
local Markdown = require(script.Parent.Markdown)
local C = UI.C

local Panel = {}
Panel.__index = Panel

local CONTEXT_CHARS = 60000 -- game analysis sent with every question (cached by the API after the first one)
local CHAT_HEIGHT = 440

local QUICK = {
	{ label = "Ce efecte VFX i se potrivesc jocului?", prompt = "Ce efecte VFX i se potrivesc jocului? Ține cont de genul "
		.. "jocului, de paleta de culori a hărții și de lumini. Propune 3–5 efecte concrete (nume, când se declanșează, "
		.. "unde se prind, culori hex, ce preseturi LostCube combin) și dă-mi codul Luau cu Editor-ul LostCube pentru cel "
		.. "mai important." },
	{ label = "Ce animații lipsesc?", prompt = "Ce animații lipsesc din joc? Uită-te la personaje, NPC-uri, arme și "
		.. "animațiile existente și spune-mi ce să adaug, în ordinea priorității, cu timing și easing pentru fiecare "
		.. "(îl reglez în tab-ul 🎬 Anim din LostCube) și ce efecte să pun pe markerele lor." },
	{ label = "Găsește probleme de securitate", prompt = "Verifică securitatea jocului: posibile backdoor-uri (require "
		.. "cu ID de asset, getfenv / loadstring, cod ofuscat, scripturi din modele gratuite sau din locuri neobișnuite) și "
		.. "RemoteEvent-uri / RemoteFunction-uri care au încredere în client. Pentru fiecare: calea exactă, de ce e "
		.. "riscant și cum repar, cu cod pentru verificările pe server." },
	{ label = "Plan de upgrade în 10 pași", prompt = "Fă-mi un plan de upgrade în 10 pași pentru joc, ordonat după "
		.. "impact și efort. Pentru fiecare pas: ce schimb, unde (căi exacte), cu ce unealtă (inclusiv LostCube) și ce "
		.. "rezultat se vede în joc." },
}

local function trim(s: string): string
	return (string.gsub(s, "^%s+", ""):gsub("%s+$", ""))
end

local function now(): number
	local ok, t = pcall(function()
		return DateTime.now().UnixTimestampMillis / 1000
	end)
	return ok and t or os.time()
end

-- the stored game analysis (Analyzer is optional: older builds / not scanned yet -> nil)
local function analyzer()
	local ok, module = pcall(function()
		return require(script.Parent:FindFirstChild("Analyzer"))
	end)
	return ok and type(module) == "table" and module or nil
end

local function storedReport()
	local Analyzer = analyzer()
	if not Analyzer or type(Analyzer.load) ~= "function" then
		return nil
	end
	local ok, report = pcall(Analyzer.load)
	return ok and report or nil
end

local function gameContext(): string?
	local Analyzer = analyzer()
	local report = storedReport()
	if not report or type(Analyzer.context) ~= "function" then
		return nil
	end
	local ok, text = pcall(Analyzer.context, report, CONTEXT_CHARS)
	return (ok and type(text) == "string" and text ~= "") and text or nil
end

-- what changes during a chat (sent after the cached part): the LostCube effects and the Studio selection
local function liveState(Editor): string
	local lines = {}
	local ok, effects = pcall(Editor.describe)
	if ok and type(effects) == "table" and #effects > 0 then
		table.insert(lines, "Efecte LostCube în ReplicatedStorage.LostCube.Effects:")
		for i, fx in effects do
			if i > 40 then
				table.insert(lines, string.format("- … încă %d", #effects - 40))
				break
			end
			local els = {}
			for _, e in fx.elements or {} do
				table.insert(els, string.format("%s [%s%s]", e.name, tostring(e.kind), e.preset and (", " .. e.preset) or ""))
			end
			table.insert(lines, string.format("- %s (%s s, %s): %s", fx.name, tostring(fx.duration or "?"),
				tostring(fx.attach or "?"), #els > 0 and table.concat(els, "; ") or "fără elemente"))
		end
	else
		table.insert(lines, "Nu există încă efecte LostCube în joc.")
	end
	local okSel, selection = pcall(function()
		return game:GetService("Selection"):Get()
	end)
	if okSel and type(selection) == "table" and #selection > 0 then
		local names = {}
		for i, inst in selection do
			if i > 10 then
				break
			end
			local okName, full = pcall(function()
				return inst:GetFullName() .. " (" .. inst.ClassName .. ")"
			end)
			table.insert(names, okName and full or "?")
		end
		table.insert(lines, "Selecția din Explorer: " .. table.concat(names, ", "))
	end
	local text = table.concat(lines, "\n")
	-- the cut drops a partial multi-byte character at the end (invalid UTF-8 would break the JSON of the request)
	return #text > 6000 and (string.gsub(string.sub(text, 1, 6000), "[\192-\255][\128-\191]*$", "") .. "\n…") or text
end

-- a growing multi-line text box (the UI kit only has single-line ones)
local function multiline(parent: Instance, text: string, placeholder: string)
	return UI.make("TextBox", { Parent = parent, Text = text or "", PlaceholderText = placeholder, Font = UI.FONT,
		TextSize = 13, TextColor3 = C.text, PlaceholderColor3 = C.dim, BackgroundColor3 = C.input, ClearTextOnFocus = false,
		MultiLine = true, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top, Size = UDim2.new(1, 0, 0, 60), AutomaticSize = Enum.AutomaticSize.Y },
		{ UI.corner(4), UI.stroke(C.border), UI.pad(6, 8, 6, 8) })
end

function Panel.new(ctx)
	return setmetatable({ ctx = ctx, Editor = ctx.Editor, plugin = ctx.plugin, messages = {}, draft = "", busy = false,
		gen = 0 }, Panel)
end

function Panel:refresh()
	self.ctx.app:refresh()
end

function Panel:render(parent)
	local key = AI.getKey(self.plugin)
	self:renderKey(parent, key)
	self:renderChat(parent, key ~= nil)
	self:renderModules(parent)
	self:renderLog(parent)
	self:renderAbout(parent)
end

-- ---------------------------------------------------------------------------------------------
-- API key, model, effort
-- ---------------------------------------------------------------------------------------------
function Panel:saveKey(text)
	local key = string.gsub(text or "", "%s", "")
	if key == "" or key == AI.getKey(self.plugin) then
		return
	end
	if not AI.setKey(self.plugin, key) then
		self.keyStatus = { "Nu am putut salva cheia (setările merg doar când LostCube rulează ca plugin).", C.danger }
	elseif AI.looksLikeKey(key) then
		self.keyStatus = { "Cheie salvată doar pe calculatorul tău.", C.good }
	else
		self.keyStatus = { "Cheie salvată, dar nu arată ca o cheie Anthropic (cheile încep cu „sk-ant-”).", C.warn }
	end
	self.editingKey = false
	self.testStatus = nil
	self:refresh()
end

function Panel:test()
	if self.testing then
		return
	end
	self.testing = true
	self.testStatus = { "Se testează… (prima dată Studio îți poate cere permisiunea pentru api.anthropic.com)", C.dim }
	self:refresh()
	task.spawn(function()
		local ok, message = AI.test(self.plugin)
		self.testing = false
		self.testStatus = { message, ok and C.good or C.danger }
		if not self.destroyed then
			self:refresh()
		end
	end)
end

function Panel:renderKey(parent, key: string?)
	local body = UI.section(parent, "Cheie API Anthropic", { key = "claude.key", collapsed = key ~= nil })
	if key and not self.editingKey then
		local area = UI.row(body, "Cheie salvată")
		UI.label(area, AI.mask(key), { size = 12, color = C.good })
		UI.button(area, "Schimbă", function()
			self.editingKey = true
			self:refresh()
		end, { width = 66 })
		UI.button(area, "Șterge", function()
			AI.setKey(self.plugin, nil)
			self.keyStatus = { "Cheia a fost ștearsă de pe acest calculator.", C.dim }
			self.testStatus = nil
			self:refresh()
		end, { width = 58, style = "danger" })
	else
		-- the key is never shown: the box text is hidden and a mask is drawn over it
		local area = UI.hstack(body, { height = UI.H })
		local box = UI.textbox(area, "", function(text)
			self:saveKey(text)
		end)
		box.TextTransparency = 1
		local mask = UI.make("TextLabel", { Parent = box, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
			Font = UI.FONT, TextSize = 13, TextColor3 = C.dim, TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd, Text = "lipește cheia aici (sk-ant-…)" })
		box:GetPropertyChangedSignal("Text"):Connect(function()
			local n = #box.Text
			mask.Text = n == 0 and "lipește cheia aici (sk-ant-…)" or (string.rep("•", math.min(n, 18)) .. "  " .. n .. " caractere")
			mask.TextColor3 = n == 0 and C.dim or C.text
		end)
		UI.button(area, "Salvează", function()
			self:saveKey(box.Text)
		end, { width = 72, style = "primary" })
		if key then
			UI.button(area, "×", function()
				self.editingKey = false
				self:refresh()
			end, { width = 26, style = "ghost", tip = "Păstrează cheia salvată" })
		end
	end
	if self.keyStatus then
		UI.label(body, self.keyStatus[1], { size = 12, wrap = true, color = self.keyStatus[2] })
	end

	local models = {}
	for _, m in AI.MODELS do
		table.insert(models, { value = m.id, label = m.label })
	end
	UI.dropdown(UI.row(body, "Model"), models, AI.getModel(self.plugin), function(id)
		AI.setModel(self.plugin, id)
		self:refresh()
	end, { menuWidth = 250 })
	UI.segmented(UI.row(body, "Efort"), AI.EFFORTS, AI.getEffort(self.plugin), function(value)
		AI.setEffort(self.plugin, value)
		self:refresh()
	end)
	UI.button(UI.hstack(body, { height = 26 }), self.testing and "Se testează…" or "Testează conexiunea", function()
		self:test()
	end, { height = 26, tip = "O cerere foarte mică: verifică cheia, modelul și permisiunea HTTP" })
	if self.testStatus then
		UI.label(body, self.testStatus[1], { size = 12, wrap = true, color = self.testStatus[2] })
	end
	UI.note(body, "Cheia o iei de pe <b>console.anthropic.com</b> → <b>API Keys</b>. Cererile se plătesc din contul tău "
		.. "Anthropic (Opus e cel mai scump, Haiku cel mai ieftin; efortul „Atent” folosește mai mulți tokeni). "
		.. "Cheia rămâne doar în setările pluginului pe acest calculator: nu se salvează în joc și nu ajunge la "
		.. "colaboratori.")
	UI.note(body, "La prima cerere Studio întreabă dacă LostCube are voie să acceseze <b>api.anthropic.com</b>: alege "
		.. "<b>Allow</b>. Dacă ai refuzat: Plugins → Manage Plugins → LostCube → permisiuni.")
end

-- ---------------------------------------------------------------------------------------------
-- chat
-- ---------------------------------------------------------------------------------------------
-- previous turns that got an answer (failed questions and errors are not sent back)
function Panel:history()
	local out = {}
	for _, m in self.messages do
		if not m.error and not m.failed then
			table.insert(out, { role = m.role, content = m.content })
		end
	end
	return out
end

function Panel:send(text: string?, fromInput: boolean?)
	text = trim(text or "")
	if text == "" or self.busy then
		return
	end
	if not AI.getKey(self.plugin) then
		self.chatNote = { "Pune întâi cheia API în secțiunea „Cheie API Anthropic”.", C.warn }
		self:redrawChat()
		return
	end
	self.chatNote = nil
	local history = self:history()
	local question = { role = "user", content = text }
	table.insert(self.messages, question)
	if fromInput then
		self.draft = ""
		if self.input and self.input.Parent then
			self.input.Text = ""
		end
	end
	self.busy = true
	self.gen += 1
	local gen = self.gen
	self.startedAt = now()
	self.waitText = "Claude scrie…"
	self:redrawChat()
	task.spawn(function() -- ticking "Claude scrie… 12 s"
		while self.busy and self.gen == gen and not self.destroyed do
			local label = self.waitLabel
			if label and label.Parent then
				label.Text = string.format("◆  %s  %d s", self.waitText or "Claude scrie…", math.floor(now() - self.startedAt))
			end
			task.wait(0.5)
		end
	end)
	task.spawn(function()
		local ok, answer, info = AI.ask(self.plugin, text, history, gameContext(), {
			live = liveState(self.Editor),
			onStatus = function(status)
				if self.gen == gen then
					self.waitText = status
				end
			end,
		})
		if self.gen ~= gen or self.destroyed then -- cleared while waiting
			return
		end
		self.busy = false
		if ok then
			table.insert(self.messages, { role = "assistant", content = answer, info = info })
			self.lastInfo = info
		else
			question.failed = true
			table.insert(self.messages, { role = "assistant", content = answer, error = true, question = text })
		end
		self:redrawChat()
	end)
end

-- sends a failed question again (the failed pair leaves the conversation)
function Panel:retry(index: number)
	local m = self.messages[index]
	if not m or not m.error or self.busy then
		return
	end
	table.remove(self.messages, index)
	local prev = self.messages[index - 1]
	if prev and prev.failed then
		table.remove(self.messages, index - 1)
	end
	self:send(m.question)
end

function Panel:clear()
	self.gen += 1 -- an answer still on its way is dropped
	self.busy = false
	self.messages = {}
	self.lastInfo = nil
	self.chatNote = nil
	self:redrawChat()
end

function Panel:messageView(list: Instance, m, index: number)
	if m.role == "user" then
		local frame = UI.make("Frame", { Parent = list, BackgroundColor3 = C.accentDark, BackgroundTransparency = 0.25,
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, { UI.corner(6), UI.pad(6, 8, 7, 8), UI.vlist(2) })
		UI.label(frame, "Tu", { size = 11, bold = true, color = C.accentHover, height = 14 })
		UI.label(frame, Markdown.escape(m.content), { wrap = true, rich = true, size = 13 })
		return
	end
	if m.error then
		local frame = UI.make("Frame", { Parent = list, BackgroundColor3 = Color3.fromRGB(58, 30, 36),
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, { UI.corner(6), UI.pad(6, 8, 7, 8), UI.vlist(4) })
		UI.label(frame, "⚠  Nu a mers", { size = 11, bold = true, color = C.danger, height = 14 })
		UI.label(frame, Markdown.escape(m.content), { wrap = true, rich = true, size = 12 })
		UI.button(UI.hstack(frame, { height = 24, fill = false }), "Reîncearcă", function()
			self:retry(index)
		end, { width = 96 })
		return
	end
	local frame = UI.make("Frame", { Parent = list, BackgroundColor3 = C.item, BackgroundTransparency = 0.4,
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, { UI.corner(6), UI.pad(6, 8, 8, 8), UI.vlist(4) })
	UI.label(frame, "◆  Claude", { size = 11, bold = true, color = C.accent, height = 14 })
	Markdown.render(frame, m.content)
	if m.info then -- token usage of each reply (the newest is the last reply's)
		UI.label(frame, AI.describeInfo(m.info), { size = 10, dim = true, wrap = true })
	end
end

-- rebuilds only the conversation (the input box keeps its focus and text); falls back to a full redraw
function Panel:redrawChat()
	local list = self.chatList
	if not (list and list.Parent) then
		self:refresh()
		return
	end
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	if #self.messages == 0 and not self.busy then
		UI.label(list, "Întreabă orice despre joc sau alege o întrebare de mai sus. Claude vede analiza jocului "
			.. "(tab-ul 🧠 Joc), efectele LostCube și selecția din Explorer.", { dim = true, size = 12, wrap = true })
	end
	for i, m in self.messages do
		self:messageView(list, m, i)
	end
	self.waitLabel = nil
	if self.busy then
		self.waitLabel = UI.label(list, string.format("◆  %s  %d s", self.waitText or "Claude scrie…",
			math.floor(now() - (self.startedAt or now()))), { size = 12, color = C.accentHover })
	end
	if self.chatNote then
		UI.label(list, self.chatNote[1], { size = 12, wrap = true, color = self.chatNote[2] })
	end
	if self.sendButton and self.sendButton.Parent then
		self.sendButton.Text = self.busy and "Claude scrie…" or "Trimite"
	end
	-- show the newest message
	for _, delay in { 0.05, 0.25 } do
		task.delay(delay, function()
			if list.Parent then
				list.CanvasPosition = Vector2.new(0, math.max(0, list.AbsoluteCanvasSize.Y - list.AbsoluteSize.Y))
			end
		end)
	end
end

function Panel:renderChat(parent, hasKey: boolean)
	local body = UI.section(parent, "Chat cu Claude", { key = "claude.chat" })
	local report = storedReport()
	UI.label(body, report and "✓ Claude primește analiza jocului salvată (tab-ul 🧠 Joc)."
		or "Fără analiză salvată: scanează jocul în tab-ul 🧠 Joc ca să-l cunoască Claude.",
		{ size = 12, wrap = true, color = report and C.good or C.warn })
	if not hasKey then
		UI.note(body, "Pune cheia API în secțiunea de mai sus ca să poți vorbi cu Claude.", C.warn)
	end
	for _, q in QUICK do
		UI.button(body, "›  " .. q.label, function()
			self:send(q.prompt)
		end, { height = 24, textSize = 12, align = Enum.TextXAlignment.Left })
	end

	self.chatList = UI.scrollList(body, CHAT_HEIGHT)

	local box = multiline(body, self.draft, "Întreabă ceva despre joc…  (Enter = rând nou; trimiți cu butonul)")
	box:GetPropertyChangedSignal("Text"):Connect(function()
		self.draft = box.Text
	end)
	self.input = box
	local bar = UI.hstack(body, { height = 28 })
	self.sendButton = UI.button(bar, "Trimite", function()
		self:send(box.Text, true)
	end, { style = "primary", bold = true, height = 28 })
	UI.button(bar, "Golește", function()
		self:clear()
	end, { height = 28, width = 84, tip = "Începe o conversație nouă" })
	self:redrawChat()
end

-- ---------------------------------------------------------------------------------------------
-- modules in the game, activity log, Claude Code
-- ---------------------------------------------------------------------------------------------
function Panel:renderModules(parent)
	local status = Installer.status()
	local body = UI.section(parent, "Module în joc", { key = "claude.modules" })
	UI.label(body, string.format("LostCube %s", status.version), { medium = true })
	UI.label(body, "VFX (player în joc): " .. (status.vfx or "lipsește"), { dim = true, size = 12,
		color = status.vfx == status.version and C.good or C.warn })
	UI.label(body, "Editor (pentru Claude): " .. (status.editor or "lipsește"), { dim = true, size = 12,
		color = status.editor == status.version and C.good or C.warn })
	UI.button(UI.hstack(body, { height = 28 }), status.ok and "Reinstalează modulele" or "Instalează / actualizează modulele",
		function()
			local ok, err = pcall(Installer.install)
			if not ok then
				warn("LostCube:", err)
			end
			self.ctx.app:refresh()
		end, { style = status.ok and "normal" or "primary", bold = true, height = 28 })
end

function Panel:renderLog(parent)
	local history = self.Editor.history()
	local body = UI.section(parent, "Ce s-a făcut  (" .. #history .. ")", { key = "claude.log" })
	if #history == 0 then
		UI.label(body, "Nimic încă în sesiunea asta.", { dim = true, size = 12 })
	end
	for i = #history, math.max(1, #history - 24), -1 do
		local h = history[i]
		UI.label(body, h.t .. "   " .. h.a, { size = 12, color = i == #history and C.text or C.dim })
	end
end

local EXAMPLES = {
	"„fă-mi un efect de foc pe mână când lovește”",
	"„pune easing Bounce pe aterizare”",
	"„fă scânteile mai mari și mai albastre”",
	"„un cerc magic sub personaj la teleport”",
}

function Panel:renderAbout(parent)
	local body = UI.section(parent, "Claude Code în Studio", { key = "claude.about", collapsed = true })
	UI.label(body, "Dacă folosești Claude Code conectat la Studio, Claude folosește aceleași funcții ca panourile "
		.. "LostCube (modulul ReplicatedStorage.LostCube.Editor). Spune-i în chat ce vrei, de exemplu:", { wrap = true, size = 12 })
	for _, e in EXAMPLES do
		UI.label(body, "•  " .. e, { dim = true, size = 12, wrap = true })
	end
	UI.note(body, "Fiecare pas e un singur <b>Ctrl+Z</b>. Efectele apar în tab-ul VFX imediat ce Claude le face.")
end

function Panel:destroy()
	self.destroyed = true
	self.gen += 1
end

return Panel
