-- ClaudePanel end to end: real UI + AI + Markdown + ClaudePanel on the strict GUI mock. The connect block and key entry,
-- connection test, model / effort, a chat turn with rich Markdown (headings, lists, code surface, table), retry, clearing
-- while a request is in flight, the conversation fitted to the window, key change and deletion (with confirmation), and
-- the design rules (no emoji, no exclamation marks).
local LC = ...
local t = LC.kit.new("claude_panel")

local env = LC.env()
local gui = LC.run("tests/mocks/gui.luau", env)
local Instance, task = env.Instance, env.task
local runQueue, findAll, findText, click = gui.runQueue, gui.findAll, gui.findText, gui.click
local MOCK_ERRORS = gui.errors

-- services
local Http = { queue = {}, sent = {}, decoded = {} }
function Http:JSONEncode(t) self.encoded = t; return "<json>" end
function Http:JSONDecode(s) local v = self.decoded[s]; if v == nil then error("bad json") end; return v end
function Http:RequestAsync(req)
	table.insert(self.sent, req)
	local nxt = table.remove(self.queue, 1)
	if type(nxt) == "string" then error(nxt) end
	return nxt or { StatusCode = 500, Body = "", Headers = {} }
end
local selection = {}
local services = {
	HttpService = Http,
	UserInputService = { IsKeyDown = function() return false end },
	Selection = { Get = function() return selection end },
}
env.game = { GetService = function(_, n) return services[n] or error("no service " .. n) end }

local store = {}
local plugin = { GetSetting = function(_, k) return store[k] end, SetSetting = function(_, k, v) store[k] = v end }
local Installer = { status = function() return { version = "1.6.0", editor = "1.6.0", vfx = "1.5.0", ok = false } end,
	install = function() end }
local Analyzer = { load = function() return { ok = true } end,
	context = function(report, max) return "## Joc\nUn joc de luptă. Max " .. tostring(max) end }
local Editor = {
	describe = function() return { { name = "Boom", duration = 0.6, attach = "GROUND", elements = { { name = "Scântei", kind = "PARTICLES", preset = "SPARKLES" } } } } end,
	history = function() return { { t = "12:00:00", a = "efect nou Boom" } } end,
	PRESETS = { { key = "SPARKLES", kind = "PARTICLES", label = "Scântei" } },
}

-- the real UI / AI / Markdown / ClaudePanel; Installer, Analyzer and Editor are small fakes
local tree = LC.modtree.new{ env = env, mocks = { Installer = Installer, Analyzer = Analyzer, Editor = Editor } }
local UI = tree.load("UI")
local Panel = tree.load("ClaudePanel")
local AI = tree.load("AI")

local root = Instance.new("Frame")
UI.setRoot(root)
local content = Instance.new("Frame")
content.Parent = root
local panel
local renders = 0
local app = {}
function app:refresh()
	task.defer(function()
		renders += 1
		for _, c in content:GetChildren() do c:Destroy() end
		local ok, err = pcall(function() panel:render(content) end)
		if not ok then table.insert(MOCK_ERRORS, "render: " .. tostring(err)); print("RENDER ERROR", err) end
	end)
end
panel = Panel.new({ plugin = plugin, Editor = Editor, app = app })

local function check(name, cond)
	t.check(cond, name)
end
local function render()
	app:refresh()
	runQueue()
end

-- toasts go away by themselves (the mock's task.delay does not wait): remember every one
local toasts = {}
local realToast = UI.toast
UI.toast = function(text, kind, opts)
	table.insert(toasts, { text = text, kind = kind or "info" })
	return realToast(text, kind, opts)
end
local function toasted(text, kind)
	for _, t_ in toasts do
		if string.find(t_.text, text, 1, true) and (kind == nil or t_.kind == kind) then
			return true
		end
	end
	return false
end
local function button(container, text)
	return findAll(container, function(c) return c.ClassName == "TextButton" and c.Text == text end)[1]
end
local function named(container, name)
	return findAll(container, function(c) return c.Name == name end)
end
local function input()
	return findAll(content, function(c) return c.ClassName == "TextBox" and c.MultiLine == true and c.TextEditable ~= false end)[1]
end
-- the design system: no emoji or symbol icons, no exclamation marks in what the panel shows
local function plainCopy(label)
	local bad = {}
	for _, c in findAll(content, function(c) return type(c.__data.props.Text) == "string" end) do
		local text = c.__data.props.Text
		for _, symbol in { "⚠", "✓", "✗", "◆", "🧠", "⏹", "›", "✎", "⌕", "✨", "🎬", "📚", "×", "!" } do
			if string.find(text, symbol, 1, true) then
				table.insert(bad, symbol .. " in " .. string.sub(text, 1, 60))
			end
		end
	end
	check(label .. ": no emoji / symbols / exclamation marks" .. (#bad > 0 and (" (" .. bad[1] .. ")") or ""), #bad == 0)
end

-- 1. no key: the connect block, the settings, modules, activity and notes; no conversation yet
render()
check("connect block", #findText(content, "Conectează Claude") == 1)
check("settings section", #findText(content, "<uc>Setări</uc>") == 1)
check("modules section kept", #findText(content, "Module în joc") == 1)
check("log section kept", #findText(content, "<uc>Activitate</uc>") == 1)
check("log entry", #findText(content, "efect nou Boom") == 1)
check("about section", #findText(content, "<uc>Despre</uc>") == 1)
check("no conversation without a key", #findText(content, "Conversație") == 0 and #named(content, "Composer") == 0)
check("modules need an update", #findText(content, "De actualizat") == 1)
plainCopy("no key")

-- sending without a key: nothing is sent, a toast says what to do
panel:send("Ce animații lipsesc?")
runQueue()
check("no key -> no request", #Http.sent == 0)
check("no key toast", toasted("Adaugă întâi cheia API", "warning"))

-- 2. enter the key in the masked box
local keyBox = findAll(content, function(c) return c.ClassName == "TextBox" end)[1]
check("key box hidden text", keyBox.TextTransparency == 1)
keyBox.Text = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789XYZW"
check("mask shows count", #findText(keyBox, "caractere") == 1)
keyBox.FocusLost:Fire(true)
runQueue()
check("key saved", AI.getKey(plugin) == "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789XYZW")
check("masked key shown", #findText(content, "sk-ant-…XYZW") == 1)
check("full key never shown", #findText(content, "abcdefghijklmnop") == 0)
check("saved toast", toasted("Cheia a fost salvată doar pe acest calculator", "success"))
check("conversation with a key", #findText(content, "<uc>Conversație</uc>") == 1 and #named(content, "Composer") == 1
	and #findText(content, "Conectează Claude") == 0)
check("context ok label", #findText(content, "Analiza jocului e inclusă") == 1)
check("quick prompts as chips", #findAll(content, function(c) return c.Name == "Chip" and c.Text == "Ce animații lipsesc?" end) == 1)
check("send button", button(content, "Trimite") ~= nil and button(content, "Oprește") == nil)
plainCopy("empty conversation")

-- 3. test connection: the result is a toast
Http.decoded.OK = { model = "claude-opus-5-5", stop_reason = "end_turn", content = { { type = "text", text = "merge" } },
	usage = { input_tokens = 12, output_tokens = 3 } }
Http.queue = { { StatusCode = 200, Body = "OK", Headers = {} } }
click(button(content, "Testează conexiunea"))
runQueue()
check("test toast", toasted("Conexiunea merge", "success"))
check("test button back", button(content, "Testează conexiunea") ~= nil)

-- model + effort controls
click(button(content, "Atent"))
runQueue()
check("effort saved", AI.getEffort(plugin) == "high")
check("effort shown in the composer", button(content, "Opus 5.5 · Atent") ~= nil)

-- 4. a chat turn with rich Markdown
local answer = table.concat({
	"## Efecte potrivite", "Paleta e **rece** (albastru) — folosește `#66D9FF`.", "",
	"1. **Lovitură**: `SPARKLES` + `FLASH`", "2. Teleport", "   - cerc magic", "",
	"```lua", "local Editor = require(game.ReplicatedStorage.LostCube.Editor)", "local fx = Editor.newEffect(\"Hit\", { duration = 0.5 })", "```",
	"| Efect | Preset |", "|---|---|", "| Hit | SPARKLES |", "", "> notă", "---", "- [x] gata",
}, "\n")
Http.decoded.ANSWER = { model = "claude-opus-5-5", stop_reason = "end_turn", content = { { type = "text", text = answer } },
	usage = { input_tokens = 100, cache_read_input_tokens = 5000, output_tokens = 300 } }
Http.queue = { { StatusCode = 200, Body = "ANSWER", Headers = {} } }
selection[1] = Instance.new("Frame")
check("multiline input", input() ~= nil)
input().Text = "Ce efecte să fac?"
click(button(content, "Trimite"))
runQueue()
check("request sent", #Http.sent == 2)
local body = Http.encoded
check("history question", body.messages[#body.messages].content == "Ce efecte să fac?")
check("context passed", string.find(body.system[1].text, "Un joc de luptă. Max 60000", 1, true) ~= nil)
check("live effects passed", body.system[2] and string.find(body.system[2].text, "Boom (0.6 s, GROUND)", 1, true) ~= nil)
check("selection passed", body.system[2] and string.find(body.system[2].text, "Selecția din Explorer", 1, true) ~= nil)
check("input cleared", input().Text == "")
check("user message on the right", #named(content, "UserMessage") == 1 and #findText(content, "Ce efecte să fac?") >= 1)
check("heading rendered", #findText(content, "Efecte potrivite") == 1)
local codeBoxes = findAll(content, function(c) return c.ClassName == "TextBox" and c.TextEditable == false end)
check("code surface", #codeBoxes == 1 and #named(content, "Code") == 1 and #findText(content, "Luau") >= 1)
check("code in Builder Mono", codeBoxes[1] and codeBoxes[1].FontFace and string.find(codeBoxes[1].FontFace.Family, "BuilderMono", 1, true) ~= nil)
check("usage shown", #findText(content, "5 100 tokeni intrare (5 000 din cache)") == 1)
check("table is a grid", #named(content, "Table") == 1 and #named(content, "TableHeader") == 1 and #named(content, "TableRow") == 1)
check("task list box", #named(content, "Check") == 1)
check("inline code uses the theme", #findText(content, "BuilderMono.json") >= 1 and #findText(content, "D7B8FF") == 0)
local selectBtn = button(content, "Selectează")
click(selectBtn)
check("select all", codeBoxes[1].__data.focused == true and codeBoxes[1].SelectionStart == 1)
plainCopy("answer")

-- draft survives re-render
input().Text = "ciornă"
render()
check("draft kept", input().Text == "ciornă")
check("conversation kept", #findText(content, "Efecte potrivite") == 1)

-- 5. error + retry
Http.decoded.E401 = { type = "error", error = { type = "authentication_error", message = "invalid x-api-key" } }
Http.queue = { { StatusCode = 401, Body = "E401", Headers = {} } }
input().Text = "Plan de upgrade"
click(button(content, "Trimite"))
runQueue()
check("error note", #findText(content, "Cheie API invalidă (401)") == 1 and #named(content, "Note") >= 1)
Http.queue = { { StatusCode = 200, Body = "OK", Headers = {} } }
local before = #Http.sent
click(button(content, "Reîncearcă"))
runQueue()
check("retried", #Http.sent == before + 1)
check("error gone after retry", #findText(content, "Cheie API invalidă (401)") == 0)
local sentMsgs = Http.encoded.messages
check("failed pair not in history", sentMsgs[#sentMsgs - 1].role == "assistant" and sentMsgs[#sentMsgs - 1].content == answer)

-- 6. clear while waiting: hold the request in a 529 retry wait, clear, then let it finish
Http.decoded.E529 = { type = "error", error = { type = "overloaded_error", message = "Overloaded" } }
Http.queue = { { StatusCode = 529, Body = "E529", Headers = {} }, { StatusCode = 200, Body = "OK", Headers = {} } }
input().Text = "Ce animații lipsesc?"
click(button(content, "Trimite"))
check("busy label", #findText(content, "Claude scrie") >= 1 or #findText(content, "Serverele Anthropic") >= 1)
check("send disabled while waiting", button(content, "Trimite") ~= nil and button(content, "Trimite"):GetAttribute("Disabled") == true)
click(named(content, "IconButton_plus")[1])
runQueue()
check("cleared", #findText(content, "Efecte potrivite") == 0)
check("late answer dropped", #panel.messages == 0 and not panel.busy)

-- 7. the conversation fills the window: inside the App's scrolling page the list grows until the composer reaches the
-- bottom of the visible area (here: page 800 px, composer 20 px, 4 px gap, 12 px room)
local page = Instance.new("ScrollingFrame")
page.Parent = root
page.__data.props.AbsoluteSize = { X = 300, Y = 800, __t = "Vector2" }
local inner = Instance.new("Frame")
inner.Parent = page
panel:render(inner)
runQueue()
local messages = findAll(inner, function(c) return c.Name == "Messages" end)[1]
check("chat fits the window", messages ~= nil and messages.Size.Y.Offset == 800 - 20 - 4 - 12)
page.__data.props.AbsoluteSize = { X = 300, Y = 100, __t = "Vector2" }
page:GetPropertyChangedSignal("AbsoluteSize"):Fire()
runQueue()
check("never smaller than the minimum", messages.Size.Y.Offset == 240)
page:Destroy()
render()

-- change key / delete key (with confirmation)
click(button(content, "Schimbă"))
runQueue()
check("editing key box", #findText(content, "sk-ant-…") >= 1 and button(content, "Anulează") ~= nil)
click(button(content, "Anulează"))
runQueue()
check("editing cancelled", button(content, "Schimbă") ~= nil)
click(named(content, "IconButton_trash")[1])
runQueue()
check("asks first", AI.getKey(plugin) ~= nil and #findText(root, "Ștergi cheia API?") == 1)
click(button(root, "Șterge"))
runQueue()
check("key deleted", AI.getKey(plugin) == nil)
check("deleted toast", toasted("Cheia API a fost ștearsă"))
check("connect block again", #findText(content, "Conectează Claude") == 1)

-- destroy
panel:destroy()
runQueue()

for _, e in MOCK_ERRORS do
	t.fail("mock / runtime error: " .. tostring(e))
end
t.finish()
