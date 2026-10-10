-- LostCube > Claude tab: chat with Claude about this game (Anthropic API, your own key), the key / model settings,
-- the modules Claude needs in the game, and what was done with LostCube.
-- Agent mode ("Mod agent"): Claude also gets tools (Tools.luau) and acts in Studio; every change waits for the
-- developer's click on its card in the chat (Permite / Refuză / Permite mereu), and "⏹ Oprește" ends the turn.
local UI = require(script.Parent.UI)
local Installer = require(script.Parent.Installer)
local AI = require(script.Parent.AI)
local Markdown = require(script.Parent.Markdown)
local C = UI.C

-- the agent tools (optional: without them the tab is the plain chat)
local Tools = (function()
	local ok, module = pcall(function()
		return require(script.Parent:FindFirstChild("Tools") :: any)
	end)
	return ok and type(module) == "table" and module or nil
end)()

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

-- agent mode: Claude reads the game by itself and asks before every change
local QUICK_AGENT = {
	{ label = "Creează un efect de lovitură potrivit jocului", prompt = "Creează un efect de lovitură potrivit jocului: "
		.. "uită-te la genul jocului, la paleta hărții și la efectele care există deja, alege șablonul și culoarea "
		.. "potrivite, creează efectul și arată-mi-l cu o previzualizare. La final spune-mi cum îl pornesc din cod "
		.. "când lovește personajul." },
	{ label = "Generează animațiile de luptă care lipsesc", prompt = "Verifică ce animații de luptă are jocul "
		.. "(scripturile de luptă, animațiile existente și cele din RBX_ANIMSAVES) și generează-le pe cele care lipsesc, "
		.. "pentru tipul de rig al jocului. La final spune-mi ce markere au și cum le leg de efecte." },
	{ label = "Verifică scriptele suspecte", prompt = "Verifică scriptele suspecte din joc: pornește de la problemele de "
		.. "securitate din analiză, caută require cu ID de asset, getfenv / setfenv, loadstring, cod ofuscat și "
		.. "scripturi din modele gratuite, citește-le și spune-mi pentru fiecare dacă e periculos și ce face. Nu "
		.. "modifica și nu șterge nimic fără să mă întrebi." },
	{ label = "Ce am selectat și ce pot îmbunătăți?", prompt = "Uită-te la ce am selectat în Explorer (citește și "
		.. "scripturile, dacă e cazul) și spune-mi ce pot îmbunătăți. Propune modificările, dar fă-le doar pe cele pe "
		.. "care le aprob." },
}

-- tool card status -> text, color
local STATUS = {
	pending = { "așteaptă aprobarea", C.warn },
	running = { "rulează…", C.accentHover },
	done = { "gata", C.good },
	error = { "eroare", C.danger },
	refused = { "refuzat", C.dim },
}
-- the same, in the text sent back to Claude in later turns
local STATUS_LOG = { done = "gata", error = "eroare", refused = "refuzat", pending = "neterminat", running = "neterminat" }

local CODE_BG = Color3.fromRGB(16, 16, 20)

local function trim(s: string): string
	return (string.gsub(s, "^%s+", ""):gsub("%s+$", ""))
end

-- the first lines of a tool result, for its card
local function preview(text: string, maxLines: number, maxChars: number): string
	local lines = {}
	for line in string.gmatch(text .. "\n", "(.-)\n") do
		if #lines >= maxLines then
			table.insert(lines, "…")
			break
		end
		table.insert(lines, line)
	end
	local out = table.concat(lines, "\n")
	if #out > maxChars then
		out = string.gsub(string.sub(out, 1, maxChars), "[\192-\255][\128-\191]*$", "") .. "…"
	end
	return out
end

-- a tool of an agent turn that actually ran (its effects may be in the place)
local function ranTools(m): boolean
	for _, step in m.steps or {} do
		if step.kind == "tool" and step.status == "done" then
			return true
		end
	end
	return false
end

-- what a finished agent turn leaves in the conversation for the next turns: the final text plus a short log of the
-- tools (old thinking / tool blocks are never replayed)
local function agentHistoryText(m): string
	if m.running then
		return ""
	end
	local parts = {}
	if m.error then
		if not ranTools(m) then
			return ""
		end
		table.insert(parts, "(Tura s-a întrerupt cu o eroare: " .. (string.match(m.error, "^[^\n]*") or "") .. ")")
	elseif type(m.content) == "string" and trim(m.content) ~= "" then
		table.insert(parts, trim(m.content))
	end
	local log = {}
	for _, step in m.steps or {} do
		if step.kind == "tool" and Tools then
			local summary = Tools.summary(step.name, step.input)
			table.insert(log, string.format("%s%s → %s", step.name, summary ~= "" and (" (" .. summary .. ")") or "",
				STATUS_LOG[step.status] or tostring(step.status)))
		end
	end
	if #log > 24 then
		log = { "…", table.unpack(log, #log - 23) }
	end
	if #log > 0 then
		table.insert(parts, "[Unelte folosite în tura asta: " .. table.concat(log, "; ") .. "]")
	end
	return table.concat(parts, "\n\n")
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
		gen = 0, allowAlways = {} }, Panel)
end

-- agent mode and "code without confirmation" (plugin settings; kept on the panel when settings are unavailable)
function Panel:isAgent(): boolean
	if not Tools then
		return false
	end
	if self.agentLocal ~= nil then
		return self.agentLocal
	end
	return AI.getAgentMode(self.plugin)
end

function Panel:setAgent(on: boolean)
	if not AI.setAgentMode(self.plugin, on) then
		self.agentLocal = on
	end
end

function Panel:allowCode(): boolean
	if self.allowCodeLocal ~= nil then
		return self.allowCodeLocal
	end
	return AI.getAllowCode(self.plugin)
end

function Panel:setAllowCode(on: boolean)
	if not AI.setAllowCode(self.plugin, on) then
		self.allowCodeLocal = on
	end
	if not on then
		self.allowAlways.run_luau = nil
	end
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
-- previous turns that got an answer (failed questions and errors are not sent back; an agent turn leaves its final
-- text and a log of its tools)
function Panel:history()
	local out = {}
	for _, m in self.messages do
		if m.agent then
			local text = agentHistoryText(m)
			if text ~= "" then
				table.insert(out, { role = "assistant", content = text })
			end
		elseif not m.error and not m.failed then
			table.insert(out, { role = m.role, content = m.content })
		end
	end
	return out
end

-- the line under the conversation while Claude works: "◆ Claude lucrează…  ·  pas 2/12  ·  14 s  ·  tokens"
function Panel:waitLine(): string
	local seconds = math.floor(now() - (self.startedAt or now()))
	local run = self.run
	if not run then
		return string.format("◆  %s  %d s", self.waitText or "Claude scrie…", seconds)
	end
	local parts = { "◆  " .. (self.waitText or "Claude lucrează…") }
	if (run.iteration or 0) > 0 then
		table.insert(parts, string.format("pas %d/%d", run.iteration, AI.MAX_ITERATIONS))
	end
	table.insert(parts, string.format("%d s", seconds))
	local info = run.info
	if info and (info.inputTokens or 0) > 0 then
		table.insert(parts, string.format("%s tokeni intrare · %s ieșire", AI.thousands(info.inputTokens),
			AI.thousands(info.outputTokens or 0)))
	end
	return table.concat(parts, "  ·  ")
end

-- keeps the wait line ticking while a turn runs
function Panel:startTicker(gen: number)
	task.spawn(function()
		while self.busy and self.gen == gen and not self.destroyed do
			local label = self.waitLabel
			if label and label.Parent then
				label.Text = self:waitLine()
			end
			task.wait(0.5)
		end
	end)
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
	if fromInput then
		self.draft = ""
		if self.input and self.input.Parent then
			self.input.Text = ""
		end
	end
	if self:isAgent() then
		self:sendAgent(text, history)
		return
	end
	local question = { role = "user", content = text }
	table.insert(self.messages, question)
	self.busy = true
	self.gen += 1
	local gen = self.gen
	self.startedAt = now()
	self.waitText = "Claude scrie…"
	self:redrawChat()
	self:startTicker(gen)
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

-- ---------------------------------------------------------------------------------------------
-- agent mode
-- ---------------------------------------------------------------------------------------------
function Panel:sendAgent(text: string, history)
	local question = { role = "user", content = text }
	table.insert(self.messages, question)
	local turn = { role = "assistant", agent = true, steps = {}, running = true, question = text }
	table.insert(self.messages, turn)
	self.busy = true
	self.gen += 1
	local gen = self.gen
	local run = { gen = gen, turn = turn, cancelled = false, iteration = 0 }
	self.run = run
	self.startedAt = now()
	self.waitText = "Claude lucrează…"
	self:redrawChat()
	self:startTicker(gen)
	task.spawn(function()
		local ok, answer, info = AI.runAgent(self.plugin, {
			question = text,
			history = history,
			context = gameContext(),
			live = liveState(self.Editor),
			tools = Tools.definitions(),
			isCancelled = function()
				return run.cancelled or self.gen ~= gen or self.destroyed == true
			end,
			runTool = function(block)
				return self:runTool(run, block)
			end,
			onStep = function(event)
				if self.gen ~= gen then
					return
				end
				if event.type == "request" then
					run.iteration = event.iteration
					if not run.cancelled then
						self.waitText = "Claude lucrează…"
					end
				elseif event.type == "response" then
					run.info = event.info
				elseif event.type == "text" then
					table.insert(turn.steps, { kind = "text", text = event.text })
					self:redrawChat()
				end
			end,
			onStatus = function(status)
				if self.gen == gen then
					self.waitText = status
				end
			end,
		})
		if self.gen ~= gen or self.destroyed then -- cleared while it ran
			return
		end
		self.busy = false
		self.run = nil
		turn.running = false
		turn.info = info
		if ok then
			turn.content = answer
			self.lastInfo = info
		else
			turn.error = answer
			if not ranTools(turn) then
				question.failed = true -- nothing happened: the question leaves the conversation, like in the plain chat
			end
		end
		self:redrawChat()
	end)
end

-- "Permite mereu" is offered for every change except code, unless the developer allowed code without confirmation
function Panel:canAlwaysAllow(name: string): boolean
	return name ~= "run_luau" or self:allowCode()
end

function Panel:autoApproved(name: string): boolean
	return self.allowAlways[name] == true and self:canAlwaysAllow(name)
end

-- runs one tool call of the agent (yields): read-only tools at once, changes after the developer's click
function Panel:runTool(run, block): (string, boolean)
	local name = tostring(block.name)
	local input = type(block.input) == "table" and block.input or {}
	local step = { kind = "tool", id = block.id, name = name, input = input, status = "running" }
	table.insert(run.turn.steps, step)
	local function alive(): boolean
		return not run.cancelled and self.gen == run.gen and not self.destroyed
	end
	local def = Tools.get(name)
	if not def then
		step.status, step.result = "error", "Unealtă necunoscută."
		self:redrawChat()
		return "Unknown tool: " .. name .. ". Use only the tools you were given.", true
	end
	if def.write and not self:autoApproved(name) then
		-- the decision lives in the step, so a redraw of the panel keeps the card and its buttons
		step.status = "pending"
		self.waitText = "așteaptă aprobarea ta"
		self:redrawChat()
		local app = self.ctx.app
		if app and app.tab and app.tab ~= "Claude" then
			print("LostCube: Claude așteaptă aprobarea ta în tab-ul ◆ Claude (" .. def.label .. ").")
		end
		while step.decision == nil do
			if not alive() then
				step.decision = "cancel"
				break
			end
			task.wait(0.1)
		end
		if step.decision == "always" and self:canAlwaysAllow(name) then
			self.allowAlways[name] = true
		end
		if step.decision == "deny" or step.decision == "cancel" then
			step.status = "refused"
			step.result = step.decision == "cancel" and "Oprit înainte să ruleze." or "Refuzat de tine."
			if self.gen == run.gen then
				self.waitText = "Claude lucrează…"
				self:redrawChat()
			end
			if step.decision == "cancel" then
				return "Not run: the developer stopped the agent.", true
			end
			return "The developer refused this change, so nothing was changed. Do not try to make it another way; "
				.. "ask what they would like instead.", true
		end
	end
	if not alive() then
		step.status, step.result = "refused", "Oprit înainte să ruleze."
		return "Not run: the developer stopped the agent.", true
	end
	step.status = "running"
	self.waitText = "rulează: " .. def.label
	self:redrawChat()
	local ok, text = Tools.run(name, input, { Editor = self.Editor, plugin = self.plugin })
	step.status = ok and "done" or "error"
	step.result = text
	if self.gen == run.gen then
		if not run.cancelled then
			self.waitText = "Claude lucrează…"
		end
		self:redrawChat()
	end
	return text, not ok
end

-- a click on a card: "allow" | "deny" | "always"
function Panel:decide(step, decision: string)
	if step.status ~= "pending" or step.decision ~= nil then
		return
	end
	step.decision = decision
	step.status = decision == "deny" and "refused" or "running"
	self:redrawChat()
end

-- "⏹ Oprește": no new request and no new tool; pending cards are refused; the current request finishes first
function Panel:stop()
	local run = self.run
	if not run or run.cancelled then
		return
	end
	run.cancelled = true
	self.waitText = "se oprește după răspunsul curent…"
	self:redrawChat()
end

-- sends a failed question again (the failed pair leaves the conversation; an agent turn that already changed
-- something stays, and the question is asked again in a new turn)
function Panel:retry(index: number)
	local m = self.messages[index]
	if not m or not m.error or self.busy then
		return
	end
	if m.agent and ranTools(m) then
		self:send(m.question)
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
	if self.run then
		self.run.cancelled = true -- pending approvals are refused, the loop stops
	end
	self.run = nil
	self.gen += 1 -- an answer still on its way is dropped
	self.busy = false
	self.messages = {}
	self.allowAlways = {} -- "Permite mereu" lasts one conversation
	self.lastInfo = nil
	self.chatNote = nil
	self:redrawChat()
end

-- read-only, selectable monospace box (the code Claude wants to run, shown whole before it is approved)
local function codeBox(parent: Instance, code: string)
	local frame = UI.make("Frame", { Parent = parent, BackgroundColor3 = CODE_BG, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.corner(4), UI.stroke(C.border), UI.pad(4, 6, 5, 6) })
	UI.make("TextBox", { Parent = frame, Text = (string.gsub(code, "\t", "    ")), Font = Enum.Font.Code, TextSize = 12,
		TextColor3 = Color3.fromRGB(214, 220, 236), BackgroundTransparency = 1, ClearTextOnFocus = false, TextEditable = false,
		MultiLine = true, TextWrapped = true, RichText = false, TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
	return frame
end

-- one tool call of an agent turn: name, what it does, status; buttons while it waits for approval
function Panel:toolCard(parent: Instance, step)
	local def = Tools and Tools.get(step.name)
	local status = STATUS[step.status] or STATUS.running
	local pending = step.status == "pending"
	local card = UI.make("Frame", { Parent = parent, BackgroundColor3 = C.input, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.corner(4), UI.stroke(pending and C.warn or C.border), UI.pad(5, 8, 6, 8),
		UI.vlist(3) })
	local head = UI.make("Frame", { Parent = card, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16) })
	UI.make("TextLabel", { Parent = head, Text = ((def and def.write) and "✎  " or "⌕  ") .. (def and def.label or step.name),
		Font = UI.FONT_MED, TextSize = 12, TextColor3 = C.text, BackgroundTransparency = 1, Size = UDim2.new(1, -120, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })
	UI.make("TextLabel", { Parent = head, Text = status[1], Font = UI.FONT_MED, TextSize = 11, TextColor3 = status[2],
		BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 116, 1, 0), TextXAlignment = Enum.TextXAlignment.Right })
	local summary = Tools and Tools.summary(step.name, step.input) or ""
	if summary ~= "" then
		UI.label(card, summary, { size = 12, dim = true, wrap = true })
	end
	if step.name == "run_luau" and type(step.input.code) == "string" then
		codeBox(card, step.input.code)
	end
	if pending then
		local bar = UI.hstack(card, { height = 24 })
		UI.button(bar, "✓ Permite", function()
			self:decide(step, "allow")
		end, { style = "primary", bold = true, height = 24 })
		UI.button(bar, "✗ Refuză", function()
			self:decide(step, "deny")
		end, { style = "danger", height = 24 })
		if self:canAlwaysAllow(step.name) then
			UI.button(card, "Permite mereu „" .. (def and def.label or step.name) .. "” în conversația asta", function()
				self:decide(step, "always")
			end, { height = 22, textSize = 11, style = "ghost", align = Enum.TextXAlignment.Left })
		end
	elseif type(step.result) == "string" and step.result ~= "" and step.status ~= "running" then
		UI.label(card, preview(step.result, 3, 280), { size = 11, wrap = true,
			color = step.status == "error" and C.danger or C.dim })
	end
	return card
end

-- an agent turn: what Claude said and did, in order, then its final answer
function Panel:agentView(list: Instance, m, index: number)
	local frame = UI.make("Frame", { Parent = list, BackgroundColor3 = C.item, BackgroundTransparency = 0.4,
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, { UI.corner(6), UI.pad(6, 8, 8, 8), UI.vlist(4) })
	UI.label(frame, "◆  Claude · agent", { size = 11, bold = true, color = C.accent, height = 14 })
	for _, step in m.steps do
		if step.kind == "text" then
			Markdown.render(frame, step.text)
		else
			self:toolCard(frame, step)
		end
	end
	if type(m.content) == "string" and m.content ~= "" then
		Markdown.render(frame, m.content)
	end
	if m.error then
		UI.label(frame, "⚠  " .. Markdown.escape(m.error), { wrap = true, rich = true, size = 12, color = C.danger })
		UI.button(UI.hstack(frame, { height = 24, fill = false }), "Reîncearcă", function()
			self:retry(index)
		end, { width = 96 })
	end
	if m.info then
		UI.label(frame, AI.describeInfo(m.info), { size = 10, dim = true, wrap = true })
	end
end

function Panel:messageView(list: Instance, m, index: number)
	if m.agent then
		self:agentView(list, m, index)
		return
	end
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

-- rebuilds only the conversation (the input box keeps its focus and text); falls back to a full redraw (only while
-- the ◆ Claude tab is the one shown: the agent keeps working, and its state is drawn when the tab opens)
function Panel:redrawChat()
	local list = self.chatList
	if not (list and list.Parent) then
		local app = self.ctx.app
		if not (app and app.tab and app.tab ~= "Claude") then
			self:refresh()
		end
		return
	end
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	if #self.messages == 0 and not self.busy then
		UI.label(list, self:isAgent() and ("Mod agent: cere-i lui Claude ce vrei să facă. Citește singur jocul (scripturi, "
			.. "instanțe, efecte, selecția) și îți cere voie înainte de fiecare modificare; fiecare modificare aprobată e un "
			.. "Ctrl+Z.") or ("Întreabă orice despre joc sau alege o întrebare de mai sus. Claude vede analiza jocului "
			.. "(tab-ul 🧠 Joc), efectele LostCube și selecția din Explorer."), { dim = true, size = 12, wrap = true })
	end
	for i, m in self.messages do
		self:messageView(list, m, i)
	end
	self.waitLabel = nil
	if self.busy then
		self.waitLabel = UI.label(list, self:waitLine(), { size = 12, color = C.accentHover, wrap = true })
	end
	if self.chatNote then
		UI.label(list, self.chatNote[1], { size = 12, wrap = true, color = self.chatNote[2] })
	end
	if self.sendButton and self.sendButton.Parent then
		self.sendButton.Text = self.busy and (self.run and "Claude lucrează…" or "Claude scrie…") or "Trimite"
	end
	if self.stopButton and self.stopButton.Parent then
		self.stopButton.Visible = self.run ~= nil
		self.stopButton.Text = (self.run and self.run.cancelled) and "Se oprește…" or "⏹ Oprește"
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
	local agent = self:isAgent()
	if Tools then
		UI.toggle(UI.hstack(body, { height = UI.H }), agent, function(on)
			self:setAgent(on)
			self:refresh()
		end, "Mod agent: Claude poate acționa în Studio", { tip = "Claude primește unelte: citește jocul singur și, cu "
			.. "acordul tău pentru fiecare modificare, creează efecte, generează animații, selectează și rulează cod" })
	end
	if agent then
		local allowCode = self:allowCode()
		UI.toggle(UI.hstack(body, { height = UI.H }), allowCode, function(on)
			self:setAllowCode(on)
			self:refresh()
		end, "Permite cod fără confirmare", { tip = "Pornit: la codul Luau apare și „Permite mereu” (doar în conversația "
			.. "curentă). Oprit: vezi și aprobi fiecare bucată de cod." })
		UI.note(body, "Claude citește singur jocul și îți cere voie înainte de fiecare modificare: <b>✓ Permite</b>, "
			.. "<b>✗ Refuză</b> sau <b>Permite mereu</b> (până golești conversația). Fiecare modificare aprobată e un "
			.. "<b>Ctrl+Z</b>; codul Luau îl vezi întreg înainte să ruleze." .. (allowCode
				and " <b>Atenție:</b> poți permite și codul fără confirmare." or ""), allowCode and C.warn or nil)
	end
	for _, q in (agent and QUICK_AGENT or QUICK) do
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
	self.stopButton = UI.button(bar, "⏹ Oprește", function()
		self:stop()
	end, { height = 28, width = 96, style = "danger", tip = "Claude nu mai face niciun pas (cererea în curs se termină; "
		.. "ce așteaptă aprobarea e refuzat)" })
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
	if self.run then
		self.run.cancelled = true
	end
	self.gen += 1
end

return Panel
