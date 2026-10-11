-- LostCube > Claude tab: a chat with Claude about this game (Anthropic API, the developer's own key). Layout: the settings
-- (key, model, effort, agent mode) in a folded "Setări" section, the conversation, the composer under it (sized so it sits
-- at the bottom of the window), then the modules Claude needs in the game, the activity log and the "Despre" notes.
-- Agent mode: Claude also gets tools (Tools.luau) and acts in Studio; every change waits for the developer's click on its
-- card in the chat (Permite / Refuză / Permite mereu), and "Oprește" ends the turn.
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
local CHAT_HEIGHT = 420 -- the conversation before the window size is known
local CHAT_MIN, CHAT_MAX = 240, 1200 -- the conversation follows the window between these
local MESSAGE_GAP = 14
local BOTTOM_ROOM = 12 -- between the composer and the bottom of the window

local QUICK = {
	{ label = "Ce efecte i se potrivesc jocului?", prompt = "Ce efecte VFX i se potrivesc jocului? Ține cont de genul "
		.. "jocului, de paleta de culori a hărții și de lumini. Propune 3–5 efecte concrete (nume, când se declanșează, "
		.. "unde se prind, culori hex, ce preseturi LostCube combin) și dă-mi codul Luau cu Editor-ul LostCube pentru cel "
		.. "mai important." },
	{ label = "Ce animații lipsesc?", prompt = "Ce animații lipsesc din joc? Uită-te la personaje, NPC-uri, arme și "
		.. "animațiile existente și spune-mi ce să adaug, în ordinea priorității, cu timing și easing pentru fiecare "
		.. "(îl reglez în tab-ul Animații din LostCube) și ce efecte să pun pe markerele lor." },
	{ label = "Probleme de securitate", prompt = "Verifică securitatea jocului: posibile backdoor-uri (require "
		.. "cu ID de asset, getfenv / loadstring, cod ofuscat, scripturi din modele gratuite sau din locuri neobișnuite) și "
		.. "RemoteEvent-uri / RemoteFunction-uri care au încredere în client. Pentru fiecare: calea exactă, de ce e "
		.. "riscant și cum repar, cu cod pentru verificările pe server." },
	{ label = "Plan de upgrade în 10 pași", prompt = "Fă-mi un plan de upgrade în 10 pași pentru joc, ordonat după "
		.. "impact și efort. Pentru fiecare pas: ce schimb, unde (căi exacte), cu ce unealtă (inclusiv LostCube) și ce "
		.. "rezultat se vede în joc." },
}

-- agent mode: Claude reads the game by itself and asks before every change
local QUICK_AGENT = {
	{ label = "Efect de lovitură pentru joc", prompt = "Creează un efect de lovitură potrivit jocului: "
		.. "uită-te la genul jocului, la paleta hărții și la efectele care există deja, alege șablonul și culoarea "
		.. "potrivite, creează efectul și arată-mi-l cu o previzualizare. La final spune-mi cum îl pornesc din cod "
		.. "când lovește personajul." },
	{ label = "Animațiile de luptă lipsă", prompt = "Verifică ce animații de luptă are jocul "
		.. "(scripturile de luptă, animațiile existente și cele din RBX_ANIMSAVES) și generează-le pe cele care lipsesc, "
		.. "pentru tipul de rig al jocului. La final spune-mi ce markere au și cum le leg de efecte." },
	{ label = "Verifică scripturile suspecte", prompt = "Verifică scriptele suspecte din joc: pornește de la problemele de "
		.. "securitate din analiză, caută require cu ID de asset, getfenv / setfenv, loadstring, cod ofuscat și "
		.. "scripturi din modele gratuite, citește-le și spune-mi pentru fiecare dacă e periculos și ce face. Nu "
		.. "modifica și nu șterge nimic fără să mă întrebi." },
	{ label = "Îmbunătățește selecția", prompt = "Uită-te la ce am selectat în Explorer (citește și "
		.. "scripturile, dacă e cazul) și spune-mi ce pot îmbunătăți. Propune modificările, dar fă-le doar pe cele pe "
		.. "care le aprob." },
}

-- tool card status -> badge text, badge kind
local STATUS = {
	pending = { "Așteaptă", "warning" },
	running = { "Rulează", "accent" },
	done = { "Gata", "success" },
	error = { "Eroare", "danger" },
	refused = { "Refuzat", "neutral" },
}
-- the same, in the text sent back to Claude in later turns
local STATUS_LOG = { done = "gata", error = "eroare", refused = "refuzat", pending = "neterminat", running = "neterminat" }

-- the glyph of each tool on its card
local TOOL_ICON = {
	get_game_overview = "game", find_instances = "search", get_instance = "info", read_script = "script",
	get_selection = "locate", list_effects = "list", describe_effect = "info", list_templates_and_presets = "list",
	list_animations = "list", preview_effect = "play", export_effect = "copy", suggest_effect_colors = "grid",
	create_effect_from_template = "plus", create_effect = "plus", add_element = "plus", set_element_props = "gear",
	import_effect = "import", recolor_effect = "gear", generate_animation = "animation", select_instances = "locate",
	run_luau = "runScript",
}

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

-- a message for a toast: the technical detail AI adds in parentheses on its own line stays out (it goes to warn)
local function short(message: string): string
	return (string.gsub(tostring(message), "\n%(.*%)%s*$", ""))
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

-- ---------------------------------------------------------------------------------------------
-- small widgets (only here)
-- ---------------------------------------------------------------------------------------------
local function autoFrame(parent: Instance, name: string, children: { Instance }?)
	return UI.make("Frame", { Name = name, Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, children)
end

-- a horizontal bar: items on the left, `right` (a frame) on the right
local function bar(parent: Instance, height: number)
	local frame = UI.make("Frame", { Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, height) })
	local left = UI.make("Frame", { Name = "Left", Parent = frame, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) },
		{ UI.hlist(UI.SPACE.sm, false) })
	local right = UI.make("Frame", { Name = "Right", Parent = frame, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0), Size = UDim2.fromScale(1, 1) },
		{ UI.make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, UI.SPACE.xs),
			FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Center }) })
	return frame, left, right
end

-- a label as wide as its text
local function inlineLabel(parent: Instance, text: string, opts: { [string]: any })
	local l = UI.label(parent, text, opts)
	l.Size = UDim2.new(0, 0, 0, opts.height or UI.H)
	l.AutomaticSize = Enum.AutomaticSize.X
	l.TextTruncate = Enum.TextTruncate.None
	return l
end

-- the API key field: the text itself is never shown, a mask is drawn over it
local function keyField(parent: Instance, onSave: (string) -> ())
	local box = UI.textbox(parent, "", function(text)
		onSave(text)
	end, { mono = true })
	box.TextTransparency = 1
	local props = { Name = "Mask", Parent = box, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = "sk-ant-…" }
	UI.textStyle(props, "body")
	local mask = UI.make("TextLabel", props)
	UI.skin(mask, { TextColor3 = "textDisabled" })
	box:GetPropertyChangedSignal("Text"):Connect(function()
		local n = #box.Text
		mask.Text = n == 0 and "sk-ant-…" or (string.rep("•", math.min(n, 18)) .. "  " .. n .. " caractere")
		UI.skin(mask, { TextColor3 = n == 0 and "textDisabled" or "text" })
	end)
	return box
end

-- switches the window to another tab (App: tab / save / render), when the app allows it
local function openTab(app, key: string)
	if type(app) ~= "table" or app.tab == key or type(app.render) ~= "function" then
		return
	end
	app.tab = key
	if type(app.save) == "function" then
		pcall(app.save, app, "tab", key)
	end
	app:render()
end

function Panel.new(ctx)
	return setmetatable({ ctx = ctx, Editor = ctx.Editor, plugin = ctx.plugin, messages = {}, draft = "", busy = false,
		gen = 0, allowAlways = {}, chatHeight = CHAT_HEIGHT }, Panel)
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
	if self.fitConns then
		for _, c in self.fitConns do
			pcall(function()
				c:Disconnect()
			end)
		end
	end
	self.fitConns = {}
	self.chatList, self.composer, self.input, self.actions = nil, nil, nil, nil
	local key = AI.getKey(self.plugin)
	if not key then
		self:renderConnect(parent)
	end
	self:renderSettings(parent, key)
	if key then
		self:renderChat(parent)
	end
	self:renderModules(parent)
	self:renderLog(parent)
	self:renderAbout(parent)
	if key then
		self:watchFit(parent)
	end
end

-- ---------------------------------------------------------------------------------------------
-- API key, model, effort, modes
-- ---------------------------------------------------------------------------------------------
function Panel:saveKey(text)
	local key = string.gsub(text or "", "%s", "")
	if key == "" or key == AI.getKey(self.plugin) then
		return
	end
	if not AI.setKey(self.plugin, key) then
		UI.toast("Cheia nu s-a putut salva. Setările merg doar când LostCube rulează ca plugin.", "error")
	elseif AI.looksLikeKey(key) then
		UI.toast("Cheia a fost salvată doar pe acest calculator.", "success")
	else
		UI.toast("Cheia a fost salvată, dar nu arată ca o cheie Anthropic (începe cu „sk-ant-”).", "warning")
	end
	self.editingKey = false
	self:refresh()
end

function Panel:deleteKey()
	UI.confirm("Ștergi cheia API?", "Va trebui să o introduci din nou ca să vorbești cu Claude.", "Șterge", function()
		AI.setKey(self.plugin, nil)
		self.editingKey = false
		UI.toast("Cheia API a fost ștearsă de pe acest calculator.")
		self:refresh()
	end, { danger = true })
end

function Panel:test()
	if self.testing then
		return
	end
	self.testing = true
	self:refresh()
	task.spawn(function()
		local ok, message = AI.test(self.plugin)
		self.testing = false
		if not ok then
			warn("LostCube:", message)
		end
		UI.toast(short(message), ok and "success" or "error")
		if not self.destroyed then
			self:refresh()
		end
	end)
end

-- no key yet: what Claude needs, the key field and where the key stays
function Panel:renderConnect(parent)
	local frame = autoFrame(parent, "Connect", { UI.pad(UI.SPACE.xl, 0, UI.SPACE.lg, 0),
		UI.make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, UI.SPACE.sm),
			HorizontalAlignment = Enum.HorizontalAlignment.Center }) })
	UI.icon(frame, "chat", { size = 24, color = "textDisabled" })
	UI.label(frame, "Conectează Claude", { role = "emphasis", color = "textBright", align = Enum.TextXAlignment.Center,
		height = 20 })
	UI.label(frame, "Adaugă o cheie API Anthropic ca să vorbești cu Claude despre joc.", { dim = true, wrap = true,
		align = Enum.TextXAlignment.Center })
	UI.spacer(frame, 4)
	local row = UI.hstack(frame, { height = UI.H_LARGE, fill = false })
	local box = keyField(row, function(text)
		self:saveKey(text)
	end)
	box.Size = UDim2.new(1, -(84 + UI.SPACE.sm), 0, UI.H_LARGE)
	UI.button(row, "Salvează", function()
		self:saveKey(box.Text)
	end, { style = "primary", width = 84, height = UI.H_LARGE })
	UI.label(frame, "Cheia rămâne doar pe acest calculator. Detalii în „Despre”.", { role = "meta", dim = true, wrap = true,
		align = Enum.TextXAlignment.Center })
end

function Panel:renderSettings(parent, key: string?)
	local body = UI.section(parent, "Setări", { key = "claude.settings", collapsed = true, onToggle = function()
		self:scheduleFit()
	end })
	if key then
		if self.editingKey then
			local area = UI.row(body, "Cheie API")
			local box = keyField(area, function(text)
				self:saveKey(text)
			end)
			local buttons = UI.hstack(body, { fill = false })
			UI.spacer(buttons, 0).Size = UDim2.new(0, UI.LABEL_W, 0, 0)
			UI.button(buttons, "Salvează", function()
				self:saveKey(box.Text)
			end, { autoWidth = true })
			UI.button(buttons, "Anulează", function()
				self.editingKey = false
				self:refresh()
			end, { style = "ghost", autoWidth = true, tip = "Păstrează cheia salvată" })
		else
			local area = UI.row(body, "Cheie API")
			local layout = area:FindFirstChildOfClass("UIListLayout")
			if layout then -- the mask takes the room, the buttons keep their size
				layout.HorizontalFlex = Enum.UIFlexAlignment.None
			end
			local masked = UI.label(area, AI.mask(key), { role = "code" })
			masked.Size = UDim2.new(1, -(64 + 24 + 8), 1, 0)
			UI.button(area, "Schimbă", function()
				self.editingKey = true
				self:refresh()
			end, { style = "ghost", width = 64 })
			UI.iconButton(area, "trash", function()
				self:deleteKey()
			end, { danger = true, tip = "Șterge cheia de pe acest calculator" })
		end
	end
	local models = {}
	for _, m in AI.MODELS do
		table.insert(models, { value = m.id, label = m.label })
	end
	UI.dropdown(UI.row(body, "Model"), models, AI.getModel(self.plugin), function(id)
		AI.setModel(self.plugin, id)
		self:refresh()
	end, { menuWidth = 250, tip = "Opus răspunde cel mai bine; Haiku e cel mai rapid și cel mai ieftin" })
	local effort = UI.segmented(UI.row(body, "Efort"), AI.EFFORTS, AI.getEffort(self.plugin), function(value)
		AI.setEffort(self.plugin, value)
		self:refresh()
	end)
	UI.tip(effort, "Cât se gândește Claude înainte să răspundă; Atent folosește mai mulți tokeni")
	if Tools then
		UI.spacer(body, 4)
		local agent = self:isAgent()
		UI.toggle(body, agent, function(on)
			self:setAgent(on)
			self:refresh()
		end, "Mod agent", { tip = "Claude primește unelte: citește singur jocul și, cu acordul tău pentru fiecare "
			.. "modificare, creează efecte, generează animații, selectează și rulează cod" })
		if agent then
			local allowCode = self:allowCode()
			local toggle = UI.toggle(body, allowCode, function(on)
				self:setAllowCode(on)
				self:refresh()
			end, "Cod fără confirmare", { tip = "Pornit: la codul Luau apare și „Permite mereu” (doar în conversația "
				.. "curentă). Oprit: vezi și aprobi fiecare bucată de cod." })
			if allowCode then -- a risky setting: the switch and its label in the danger colour
				UI.skin(toggle, { TextColor3 = "danger" })
				local track = toggle:FindFirstChild("Switch")
				if track then
					UI.skin(track, { BackgroundColor3 = "danger" })
				end
				UI.label(body, "Codul Luau poate rula fără să-l mai aprobi.", { role = "meta", color = "danger", wrap = true })
			end
		end
	end
	UI.spacer(body, 4)
	local actions = UI.hstack(body, { fill = false })
	UI.button(actions, self.testing and "Se testează…" or "Testează conexiunea", function()
		self:test()
	end, { autoWidth = true, disabled = self.testing == true,
		tip = "O cerere foarte mică: verifică cheia, modelul și permisiunea HTTP" })
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

-- the line under the conversation while Claude works: "Claude lucrează… · pas 2/12 · 14 s · tokens"
function Panel:waitLine(): string
	local seconds = math.floor(now() - (self.startedAt or now()))
	local run = self.run
	local status = string.gsub(self.waitText or (run and "Claude lucrează…" or "Claude scrie…"), "^%l", string.upper)
	if not run then
		return string.format("%s · %d s", status, seconds)
	end
	local parts = { status }
	if (run.iteration or 0) > 0 then
		table.insert(parts, string.format("pas %d/%d", run.iteration, AI.MAX_ITERATIONS))
	end
	table.insert(parts, string.format("%d s", seconds))
	local info = run.info
	if info and (info.inputTokens or 0) > 0 then
		table.insert(parts, string.format("%s tokeni intrare · %s ieșire", AI.thousands(info.inputTokens),
			AI.thousands(info.outputTokens or 0)))
	end
	return table.concat(parts, " · ")
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
		UI.toast("Adaugă întâi cheia API Anthropic.", "warning")
		return
	end
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
			print("LostCube: Claude așteaptă aprobarea ta în tab-ul Claude (" .. def.label .. ").")
			UI.toast("Claude așteaptă aprobarea ta: " .. def.label .. ".", "info", { action = { text = "Deschide",
				onClick = function()
					openTab(self.ctx.app, "Claude")
				end } })
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

-- "Oprește": no new request and no new tool; pending cards are refused; the current request finishes first
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
	self:redrawChat()
end

-- ---------------------------------------------------------------------------------------------
-- messages
-- ---------------------------------------------------------------------------------------------
-- the developer's message: a quiet surface on the right, as wide as its text (up to 85 % of the conversation)
local function userMessage(list: Instance, text: string)
	local line = autoFrame(list, "UserMessage", { UI.make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Right }) })
	local available = 0
	pcall(function()
		available = list.AbsoluteSize.X - 12
	end)
	local width = UI.textWidth(text, "body") + 26
	-- before the first layout the list has no width yet: 220 px fits in the narrowest dock
	local limit = available > 0 and available * 0.85 or 220
	local oneLine = not string.find(text, "\n", 1, true) and width <= limit
	local bubble = UI.make("Frame", { Name = "Bubble", Parent = line, AutomaticSize = Enum.AutomaticSize.Y,
		Size = oneLine and UDim2.new(0, width, 0, 0) or UDim2.new(0.85, 0, 0, 0) },
		{ UI.corner(UI.RADIUS.surface), UI.pad(6, 10, 7, 10) })
	UI.skin(bubble, { BackgroundColor3 = "raised" })
	local props = { Parent = bubble, Text = Markdown.escape(text), RichText = true, TextWrapped = true, LineHeight = 1.15,
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top }
	UI.textStyle(props, "body")
	UI.skin(UI.make("TextLabel", props), { TextColor3 = "text" })
	return line
end

-- a failed request: what happened (danger note) and "Reîncearcă"
function Panel:errorView(parent: Instance, text: string, index: number)
	UI.note(parent, Markdown.escape(text), "danger")
	local row = UI.hstack(parent, { fill = false })
	UI.button(row, "Reîncearcă", function()
		self:retry(index)
	end, { icon = "refresh", autoWidth = true })
end

-- the status of a tool call: a badge
local function statusBadge(parent: Instance, status: string)
	local s = STATUS[status] or STATUS.running
	local badge = UI.badge(parent, s[1], s[2])
	badge.Name = "Status"
	return badge
end

-- a read-only tool call: one quiet line (glyph, what, on what, status)
function Panel:toolLine(parent: Instance, step)
	local def = Tools and Tools.get(step.name)
	local frame = autoFrame(parent, "ToolLine", { UI.vlist(2) })
	local head = UI.make("Frame", { Parent = frame, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20) })
	UI.icon(head, TOOL_ICON[step.name] or "info", { size = 14, anchor = Vector2.new(0, 0.5),
		position = UDim2.new(0, 0, 0.5, 0) })
	local summary = Tools and Tools.summary(step.name, step.input) or ""
	local text = '<font weight="medium">' .. UI.escape(def and def.label or step.name) .. "</font>"
	if summary ~= "" then
		text ..= '  <font color="#' .. C.textDim:ToHex() .. '">' .. UI.escape(summary) .. "</font>"
	end
	local label = UI.label(head, text, { rich = true, color = "text", height = 20 })
	label.Position = UDim2.fromOffset(20, 0)
	label.Size = UDim2.new(1, -(20 + 72), 1, 0)
	local right = UI.make("Frame", { Parent = head, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 70, 1, 0) },
		{ UI.make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center }) })
	if step.status == "done" then
		local check = UI.icon(right, "check", { size = 14, color = "success" })
		check.Name = "Done"
		if type(step.result) == "string" and step.result ~= "" then -- what the tool returned, on hover
			UI.tip(head, preview(step.result, 6, 400))
		end
	else
		statusBadge(right, step.status)
	end
	if step.status == "error" and type(step.result) == "string" and step.result ~= "" then
		local err = UI.label(frame, preview(step.result, 3, 280), { role = "meta", color = "danger", wrap = true })
		UI.pad(0, 0, 0, 20).Parent = err
	end
	return frame
end

-- a change: a card with what it does, its status, the code it runs, and the approval buttons while it waits
function Panel:toolCard(parent: Instance, step)
	local def = Tools and Tools.get(step.name)
	if not (def and def.write) and step.status ~= "pending" then
		return self:toolLine(parent, step)
	end
	local pending = step.status == "pending"
	-- a card that waits for the developer is filled (it is the one thing to act on); the others are outlined
	local card = UI.make("Frame", { Name = "ToolCard", Parent = parent, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = pending and 0 or 1 }, { UI.corner(UI.RADIUS.surface),
		UI.stroke(pending and "fieldBorderHover" or "border"), UI.pad(8, 10, 10, 10), UI.vlist(6) })
	UI.skin(card, { BackgroundColor3 = "raised" })
	card:SetAttribute("Status", step.status)
	local head = UI.make("Frame", { Parent = card, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20) })
	UI.icon(head, TOOL_ICON[step.name] or "info", { size = 14, color = pending and "text" or "textDim",
		anchor = Vector2.new(0, 0.5), position = UDim2.new(0, 0, 0.5, 0) })
	local title = UI.label(head, def and def.label or step.name, { role = "control", color = "text", height = 20 })
	title.Position = UDim2.fromOffset(20, 0)
	title.Size = UDim2.new(1, -(20 + 80), 1, 0)
	local badge = statusBadge(head, step.status)
	badge.AnchorPoint = Vector2.new(1, 0.5)
	badge.Position = UDim2.new(1, 0, 0.5, 0)
	local summary = Tools and Tools.summary(step.name, step.input) or ""
	if summary ~= "" then
		UI.label(card, summary, { dim = true, wrap = true })
	end
	if step.name == "run_luau" and type(step.input.code) == "string" then
		Markdown.code(card, step.input.code, "Luau")
	end
	if pending then
		local row = UI.hstack(card, { fill = false })
		UI.button(row, "Permite", function()
			self:decide(step, "allow")
		end, { style = "primary", autoWidth = true, tip = "Rulează această modificare (un singur Ctrl+Z)" })
		UI.button(row, "Refuză", function()
			self:decide(step, "deny")
		end, { autoWidth = true, tip = "Nu schimbă nimic; Claude te întreabă ce vrei în loc" })
		if self:canAlwaysAllow(step.name) then
			UI.button(row, "Permite mereu", function()
				self:decide(step, "always")
			end, { style = "ghost", autoWidth = true, tip = "Nu mai întreabă pentru „" .. (def and def.label or step.name)
				.. "” până la o conversație nouă" })
		end
	elseif type(step.result) == "string" and step.result ~= "" and step.status ~= "running" then
		UI.label(card, preview(step.result, 3, 280), { role = "meta", wrap = true,
			color = step.status == "error" and "danger" or "textDim" })
	end
	return card
end

-- an agent turn: what Claude said and did, in order, then its final answer
function Panel:agentView(list: Instance, m, index: number)
	local frame = autoFrame(list, "AgentTurn", { UI.vlist(8) })
	local tools = nil -- consecutive tool calls share one group (4 px apart)
	for _, step in m.steps do
		if step.kind == "text" then
			tools = nil
			Markdown.render(frame, step.text)
		else
			if not tools then
				tools = autoFrame(frame, "Tools", { UI.vlist(4) })
			end
			self:toolCard(tools, step)
		end
	end
	if type(m.content) == "string" and m.content ~= "" then
		Markdown.render(frame, m.content)
	end
	if m.error then
		self:errorView(frame, m.error, index)
	end
	if m.info then
		UI.label(frame, AI.describeInfo(m.info), { role = "meta", color = "textDisabled", wrap = true })
	end
end

function Panel:messageView(list: Instance, m, index: number)
	if m.agent then
		self:agentView(list, m, index)
		return
	end
	if m.role == "user" then
		userMessage(list, m.content)
		return
	end
	local frame = autoFrame(list, m.error and "Failed" or "Answer", { UI.vlist(6) })
	if m.error then
		self:errorView(frame, m.content, index)
		return
	end
	Markdown.render(frame, m.content)
	if m.info then -- token usage of each reply (the newest is the last reply's)
		UI.label(frame, AI.describeInfo(m.info), { role = "meta", color = "textDisabled", wrap = true })
	end
end

-- nothing said yet: one sentence and the quick prompts as chips
function Panel:emptyView(list: Instance)
	local agent = self:isAgent()
	local report = storedReport()
	local frame = UI.empty(list, agent and "Claude citește jocul singur și îți cere voie înainte de fiecare modificare."
		or "Claude vede analiza jocului, efectele LostCube și selecția din Explorer.", nil, nil,
		{ icon = "chat", title = agent and "Ce să facă Claude?" or "Întreabă despre joc" })
	for _, q in (agent and QUICK_AGENT or QUICK) do
		UI.chip(frame, q.label, { onClick = function()
			self:send(q.prompt)
		end, tip = "Trimite: " .. q.label })
	end
	if not report then
		UI.spacer(frame, 2)
		UI.button(frame, "Analizează jocul în tab-ul Joc", function()
			openTab(self.ctx.app, "Game")
		end, { style = "link", autoWidth = true, tip = "Fără analiză, Claude nu cunoaște jocul" })
	end
end

-- the send / stop button of the composer, for the current state
function Panel:drawActions()
	local actions = self.actions
	if not (actions and actions.Parent) then
		return
	end
	for _, child in actions:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	if self.run then
		local stopping = self.run.cancelled
		self.stopButton = UI.button(actions, stopping and "Se oprește…" or "Oprește", function()
			self:stop()
		end, { icon = "stop", autoWidth = true, disabled = stopping, tip = "Claude nu mai face niciun pas (cererea în curs "
			.. "se termină; ce așteaptă aprobarea e refuzat)" })
	else
		self.stopButton = nil
		self.sendButton = UI.button(actions, "Trimite", function()
			if self.input then
				self:send(self.input.Text, true)
			end
		end, { style = "primary", autoWidth = true, disabled = self.busy })
	end
end

-- rebuilds only the conversation (the input box keeps its focus and text); falls back to a full redraw (only while
-- the Claude tab is the one shown: the agent keeps working, and its state is drawn when the tab opens)
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
		self:emptyView(list)
	end
	for i, m in self.messages do
		self:messageView(list, m, i)
	end
	self.waitLabel = nil
	if self.busy then
		self.waitLabel = UI.label(list, self:waitLine(), { role = "meta", dim = true, wrap = true })
		self.waitLabel.Name = "Waiting"
	end
	self:drawActions()
	-- show the newest message
	for _, delay in { 0.05, 0.25 } do
		task.delay(delay, function()
			if list.Parent then
				list.CanvasPosition = Vector2.new(0, math.max(0, list.AbsoluteCanvasSize.Y - list.AbsoluteSize.Y))
			end
		end)
	end
end

-- the conversation fills the window down to the composer (the composer sits at the bottom of the visible area)
function Panel:fitChat()
	local list, composer, scroll = self.chatList, self.composer, self.pageScroll
	if not (list and list.Parent and composer and composer.Parent and scroll and scroll.Parent) then
		return
	end
	local ok, wanted = pcall(function()
		local top = list.AbsolutePosition.Y - scroll.AbsolutePosition.Y + scroll.CanvasPosition.Y
		return scroll.AbsoluteSize.Y - top - composer.AbsoluteSize.Y - UI.SPACE.xs - BOTTOM_ROOM
	end)
	if not ok or type(wanted) ~= "number" or wanted ~= wanted then
		return
	end
	local height = math.clamp(math.floor(wanted), CHAT_MIN, CHAT_MAX)
	if math.abs(height - self.chatHeight) >= 2 then
		self.chatHeight = height
		list.Size = UDim2.new(1, 0, 0, height)
	end
end

-- fits the conversation once the layout has settled (now and a moment later: positions update after the next frame)
function Panel:scheduleFit()
	local function fit()
		if not self.destroyed then
			self:fitChat()
		end
	end
	task.defer(fit)
	task.delay(0.1, fit)
end

function Panel:watchFit(parent: Instance)
	local scroll = parent.Parent
	while scroll and not scroll:IsA("ScrollingFrame") do
		scroll = scroll.Parent
	end
	self.pageScroll = scroll
	if not scroll then
		return
	end
	local function fit()
		self:scheduleFit()
	end
	table.insert(self.fitConns, scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit))
	if self.composer then
		table.insert(self.fitConns, self.composer:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit))
	end
	fit()
end

function Panel:renderChat(parent)
	local report = storedReport()
	local body = UI.section(parent, "Conversație", { key = "claude.chat", collapsible = false, right = function(r)
		UI.iconButton(r, "plus", function()
			self:clear()
		end, { tip = "Conversație nouă" })
	end, rightWidth = 28 })
	local context = UI.make("Frame", { Name = "Context", Parent = body, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16) },
		{ UI.hlist(6, false) })
	local dot = UI.make("Frame", { Name = "Dot", Parent = context, Size = UDim2.fromOffset(6, 6) }, { UI.corner(3) })
	UI.skin(dot, { BackgroundColor3 = report and "success" or "warning" })
	inlineLabel(context, report and "Analiza jocului e inclusă" or "Fără analiza jocului", { role = "meta", dim = true,
		height = 16 })
	UI.tip(context, report and "Claude primește analiza salvată a jocului (tab-ul Joc), efectele LostCube și selecția."
		or "Analizează jocul în tab-ul Joc ca să-l cunoască Claude.")

	local list = UI.make("ScrollingFrame", { Name = "Messages", Parent = body, BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, self.chatHeight), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4, ScrollingDirection = Enum.ScrollingDirection.Y,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar }, { UI.vlist(MESSAGE_GAP), UI.pad(8, 8, 8, 0) })
	UI.skin(list, { ScrollBarImageColor3 = "scrollbar" })
	self.chatList = list

	-- the composer: a multi-line box and its toolbar in one field
	local composer = UI.make("Frame", { Name = "Composer", Parent = body, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.corner(UI.RADIUS.surface), UI.vlist(0) })
	UI.skin(composer, { BackgroundColor3 = "field" })
	local border = UI.stroke("fieldBorder")
	border.Parent = composer
	self.composer = composer
	local agent = self:isAgent()
	local props = { Name = "Input", Parent = composer, Text = self.draft or "", PlaceholderText = agent
		and "Spune-i lui Claude ce să facă…" or "Întreabă ceva despre joc…", ClearTextOnFocus = false, MultiLine = true,
		TextWrapped = true, BackgroundTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }
	UI.textStyle(props, "body")
	local box = UI.make("TextBox", props, { UI.pad(9, 10, 4, 10),
		UI.make("UISizeConstraint", { MinSize = Vector2.new(0, 44), MaxSize = Vector2.new(math.huge, 220) }) })
	UI.skin(box, { TextColor3 = "text", PlaceholderColor3 = "textDisabled" })
	box:GetPropertyChangedSignal("Text"):Connect(function()
		self.draft = box.Text
	end)
	box.Focused:Connect(function()
		UI.skin(border, { Color = "focus" })
	end)
	box.FocusLost:Connect(function()
		UI.skin(border, { Color = "fieldBorder" })
	end)
	self.input = box
	local toolbar, left, right = bar(composer, 32)
	UI.pad(0, 6, 4, 4).Parent = toolbar
	local model = AI.modelInfo(AI.getModel(self.plugin))
	local effortLabel = "?"
	for _, e in AI.EFFORTS do
		if e.value == AI.getEffort(self.plugin) then
			effortLabel = e.label
		end
	end
	UI.button(left, (model and model.short or "Claude") .. " · " .. effortLabel, function()
		UI.collapsed["claude.settings"] = false
		if UI.onCollapse then
			UI.onCollapse()
		end
		self:refresh()
	end, { style = "ghost", autoWidth = true, height = 22, tip = "Model și efort: schimbă-le în Setări" })
	if agent then
		local badge = UI.badge(left, "Agent", "neutral")
		UI.tip(badge, "Mod agent: Claude acționează în Studio, cu aprobarea ta pentru fiecare modificare")
	end
	right.Size = UDim2.new(0, 120, 1, 0)
	left.Size = UDim2.new(1, -124, 1, 0)
	self.actions = right
	self:redrawChat()
end

-- ---------------------------------------------------------------------------------------------
-- modules in the game, activity log, notes
-- ---------------------------------------------------------------------------------------------
function Panel:renderModules(parent)
	local status = Installer.status()
	local missing = status.vfx == nil or status.editor == nil
	local outdated = not missing and (status.vfx ~= status.version or status.editor ~= status.version)
	local body = UI.section(parent, "Module în joc", { key = "claude.modules", collapsed = true,
		right = (missing or outdated) and function(r)
			UI.badge(r, missing and "Lipsesc" or "De actualizat", "warning")
		end or nil, rightWidth = 96, onToggle = function()
			self:scheduleFit()
		end })
	local function version(label: string, value: string?, tip: string)
		local area = UI.row(body, label)
		local ok = value == status.version
		UI.label(area, value and ("v" .. value .. (ok and "" or ("  ·  pluginul are v" .. status.version))) or "lipsește",
			{ color = ok and "text" or "warning" })
		UI.tip(area.Parent, tip)
	end
	version("Editor", status.editor, "Modulul prin care Claude creează și modifică efecte (ReplicatedStorage.LostCube.Editor)")
	version("VFX", status.vfx, "Playerul care redă efectele în joc (ReplicatedStorage.LostCube.VFX)")
	local row = UI.hstack(body, { fill = false })
	UI.button(row, missing and "Instalează modulele" or (outdated and "Actualizează modulele" or "Reinstalează"), function()
		local ok, err = pcall(Installer.install)
		if ok then
			UI.toast("Modulele LostCube sunt în joc (v" .. tostring(status.version) .. ").", "success")
		else
			warn("LostCube:", err)
			UI.toast("Modulele nu s-au putut instala: " .. short(tostring(err)), "error")
		end
		self.ctx.app:refresh()
	end, { autoWidth = true, style = (missing or outdated) and "normal" or "ghost" })
end

function Panel:renderLog(parent)
	local history = self.Editor.history()
	local body = UI.section(parent, "Activitate", { key = "claude.log", collapsed = true, badge = #history > 0 and #history or nil,
		onToggle = function()
			self:scheduleFit()
		end })
	if #history == 0 then
		UI.label(body, "Nimic încă în sesiunea asta.", { dim = true })
		return
	end
	for i = #history, math.max(1, #history - 24), -1 do
		local h = history[i]
		local row = UI.make("Frame", { Name = "Entry", Parent = body, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20) },
			{ UI.hlist(UI.SPACE.sm, false) })
		UI.label(row, tostring(h.t), { role = "meta", dim = true, width = 52, height = 20 })
		local text = UI.label(row, tostring(h.a), { color = i == #history and "text" or "textDim", height = 20 })
		text.Size = UDim2.new(1, -60, 1, 0)
	end
end

local EXAMPLES = {
	"„fă-mi un efect de foc pe mână când lovește”",
	"„pune easing Bounce pe aterizare”",
	"„fă scânteile mai mari și mai albastre”",
	"„un cerc magic sub personaj la teleport”",
}

function Panel:renderAbout(parent)
	local body = UI.section(parent, "Despre", { key = "claude.about", collapsed = true, onToggle = function()
		self:scheduleFit()
	end })
	local function paragraph(title: string, text: string)
		UI.label(body, title, { medium = true, height = 20 })
		UI.label(body, text, { dim = true, wrap = true, rich = true })
		UI.spacer(body, 4)
	end
	paragraph("Cheia API", "Cheia o iei de pe <b>console.anthropic.com</b> → API Keys. Cererile se plătesc din contul tău "
		.. "Anthropic: Opus costă cel mai mult, Haiku cel mai puțin, iar efortul Atent folosește mai mulți tokeni. Cheia "
		.. "rămâne în setările pluginului pe acest calculator; nu se salvează în joc și nu ajunge la colaboratori.")
	paragraph("Permisiunea HTTP", "La prima cerere Studio întreabă dacă LostCube poate accesa <b>api.anthropic.com</b>: "
		.. "alege Allow. Dacă ai refuzat: Plugins → Manage Plugins → LostCube → permisiuni.")
	paragraph("Claude Code în Studio", "Conectat la Studio, Claude Code folosește aceleași funcții ca panourile LostCube "
		.. "(ReplicatedStorage.LostCube.Editor). Fiecare pas e un singur Ctrl+Z. Exemple de cereri:")
	for _, e in EXAMPLES do
		UI.label(body, e, { dim = true, wrap = true })
	end
end

function Panel:destroy()
	self.destroyed = true
	if self.run then
		self.run.cancelled = true
	end
	self.gen += 1
	for _, c in self.fitConns or {} do
		pcall(function()
			c:Disconnect()
		end)
	end
	self.fitConns = {}
end

return Panel
