-- ClaudePanel end to end: real UI + AI + Markdown + ClaudePanel on the strict GUI mock. Key entry, connection test,
-- model / effort, a chat turn with rich Markdown, retry, clearing while a request is in flight, key deletion.
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

-- 1. no key
render()
check("rendered key section", #findText(content, "Cheie API Anthropic") == 1)
check("chat section", #findText(content, "Chat cu Claude") == 1)
check("modules section kept", #findText(content, "Module în joc") == 1)
check("log section kept", #findText(content, "Ce s-a făcut  (1)") == 1)
check("log entry", #findText(content, "efect nou Boom") == 1)
check("no-key note", #findText(content, "Pune cheia API") >= 1)
check("context ok label", #findText(content, "primește analiza jocului") == 1)
check("quick prompts", #findText(content, "›  Ce animații lipsesc?") == 1)

-- send without key -> note
click(findText(content, "›  Ce animații lipsesc?")[1])
runQueue()
check("no key -> no request", #Http.sent == 0)
check("no key note in chat", #findText(content, "Pune întâi cheia API") == 1)

-- 2. enter the key in the masked box
local boxes = findAll(content, function(c) return c.ClassName == "TextBox" end)
local keyBox = boxes[1]
check("key box hidden text", keyBox.TextTransparency == 1)
keyBox.Text = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789XYZW"
check("mask shows count", #findText(keyBox, "caractere") == 1)
keyBox.FocusLost:Fire(true)
runQueue()
check("key saved", AI.getKey(plugin) == "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789XYZW")
check("masked key shown", #findText(content, "sk-ant-…XYZW") == 1)
check("full key never shown", #findText(content, "abcdefghijklmnop") == 0)
check("saved status", #findText(content, "Cheie salvată doar pe calculatorul tău") == 1)

-- 3. test connection
Http.decoded.OK = { model = "claude-opus-5-5", stop_reason = "end_turn", content = { { type = "text", text = "merge" } },
	usage = { input_tokens = 12, output_tokens = 3 } }
Http.queue = { { StatusCode = 200, Body = "OK", Headers = {} } }
click(findText(content, "Testează conexiunea")[1])
runQueue()
check("test status", #findText(content, "Conexiunea merge") == 1)

-- model + effort controls
click(findText(content, "Atent")[1])
runQueue()
check("effort saved", AI.getEffort(plugin) == "high")

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
local input = findAll(content, function(c) return c.ClassName == "TextBox" and c.MultiLine == true and c.TextEditable ~= false end)[1]
check("multiline input", input ~= nil)
input.Text = "Ce efecte să fac?"
click(findText(content, "Trimite")[1])
runQueue()
check("request sent", #Http.sent == 2)
local body = Http.encoded
check("history question", body.messages[#body.messages].content == "Ce efecte să fac?")
check("context passed", string.find(body.system[1].text, "Un joc de luptă. Max 60000", 1, true) ~= nil)
check("live effects passed", body.system[2] and string.find(body.system[2].text, "Boom (0.6 s, GROUND)", 1, true) ~= nil)
check("selection passed", body.system[2] and string.find(body.system[2].text, "Selecția din Explorer", 1, true) ~= nil)
check("input cleared", input.Text == "")
check("user bubble", #findText(content, "Ce efecte să fac?") >= 1)
check("heading rendered", #findText(content, "Efecte potrivite") == 1)
check("code box", #findAll(content, function(c) return c.ClassName == "TextBox" and c.TextEditable == false end) == 1)
check("usage shown", #findText(content, "5 100 tokeni intrare (5 000 din cache)") == 1)
check("table rendered", #findText(content, "│") >= 1)
local selectBtn = findText(content, "Selectează tot")[1]
click(selectBtn)
check("select all", true)

-- draft survives re-render
input = findAll(content, function(c) return c.ClassName == "TextBox" and c.MultiLine == true and c.TextEditable ~= false end)[1]
input.Text = "ciornă"
render()
input = findAll(content, function(c) return c.ClassName == "TextBox" and c.MultiLine == true and c.TextEditable ~= false end)[1]
check("draft kept", input.Text == "ciornă")
check("conversation kept", #findText(content, "Efecte potrivite") == 1)

-- 5. error + retry
Http.decoded.E401 = { type = "error", error = { type = "authentication_error", message = "invalid x-api-key" } }
Http.queue = { { StatusCode = 401, Body = "E401", Headers = {} } }
click(findText(content, "›  Plan de upgrade în 10 pași")[1])
runQueue()
check("error bubble", #findText(content, "Cheie API invalidă (401)") == 1)
Http.queue = { { StatusCode = 200, Body = "OK", Headers = {} } }
local before = #Http.sent
click(findText(content, "Reîncearcă")[1])
runQueue()
check("retried", #Http.sent == before + 1)
check("error gone after retry", #findText(content, "Cheie API invalidă (401)") == 0)
local sentMsgs = Http.encoded.messages
check("failed pair not in history", sentMsgs[#sentMsgs - 1].role == "assistant" and sentMsgs[#sentMsgs - 1].content == answer)

-- 6. clear while waiting: hold the request in a 529 retry wait, clear, then let it finish
Http.decoded.E529 = { type = "error", error = { type = "overloaded_error", message = "Overloaded" } }
Http.queue = { { StatusCode = 529, Body = "E529", Headers = {} }, { StatusCode = 200, Body = "OK", Headers = {} } }
click(findText(content, "›  Ce animații lipsesc?")[1])
check("busy label", #findText(content, "Claude scrie") >= 1)
click(findText(content, "Golește")[1])
runQueue()
check("cleared", #findText(content, "Efecte potrivite") == 0)
check("late answer dropped", #panel.messages == 0 and not panel.busy)

-- change key / delete key
click(findText(content, "Schimbă")[1])
runQueue()
check("editing key box", #findText(content, "lipește cheia aici") == 1)
click(findText(content, "×")[1])
runQueue()
click(findText(content, "Șterge")[1])
runQueue()
check("key deleted", AI.getKey(plugin) == nil)

-- destroy
panel:destroy()
runQueue()

for _, e in MOCK_ERRORS do
	t.fail("mock / runtime error: " .. tostring(e))
end
t.finish()
