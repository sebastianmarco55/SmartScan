-- ClaudePanel in agent mode: a scripted conversation through the mocked UI (approval cards, re-render, stop, clear)
local store = {}
local plugin = { GetSetting = function(_, k) return store[k] end, SetSetting = function(_, k, v) store[k] = v end }
MOCKS.Installer = { status = function() return { version = "2.0.0", editor = "2.0.0", vfx = "2.0.0", ok = true } end,
	install = function() end }
MOCKS.Analyzer = { load = function() return { ok = true } end,
	context = function(_, max) return "## Joc\nUn joc de luptă. Max " .. tostring(max) end,
	resolve = function() return nil end }
local created = {}
local Editor = {
	VERSION = "2.0.0",
	PRESETS = { { key = "SPARKLES", kind = "PARTICLES", label = "Scântei" } },
	TEMPLATES = { { key = "PUNCH", label = "Lovitură de pumn", category = "Luptă", duration = 0.5, attach = "TORSO" } },
	describe = function() return { { name = "Boom", duration = 0.6, attach = "GROUND", elements = { { name = "Scântei", kind = "PARTICLES", preset = "SPARKLES" } } } } end,
	history = function() return { { t = "12:00:00", a = "efect nou Boom" } } end,
	log = function() end,
	elements = function() return {} end,
	kindOf = function() return "PARTICLES" end,
	newFromTemplate = function(name, key, opts)
		table.insert(created, name)
		return Instance.new("Model", { Name = name })
	end,
}
MOCKS.Editor = Editor

local AI = load("AI")
local UI = load("UI")
local Panel = load("ClaudePanel")
local Json = AI.Json
AI.setKey(plugin, "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789XYZW")

local root = Instance.new("Frame")
UI.setRoot(root)
local content = Instance.new("Frame")
content.Parent = root
local panel
local renders = 0
local app = { tab = "Claude" }
function app:refresh()
	task.defer(function()
		renders += 1
		for _, c in content:GetChildren() do c:Destroy() end
		local ok, err = pcall(function() panel:render(content) end)
		if not ok then table.insert(MOCK_ERRORS, "render: " .. tostring(err)); print("RENDER ERROR", err) end
	end)
end
panel = Panel.new({ plugin = plugin, Editor = Editor, app = app })
local function render() app:refresh(); runQueue() end
local function texts(s) return #findText(content, s) end
local function button(s)
	local found = findAll(content, function(c) return c.ClassName == "TextButton" and c.Text == s end)
	return found[1]
end
local function input() return findAll(content, function(c) return c.ClassName == "TextBox" and c.MultiLine == true and c.TextEditable ~= false end)[1] end

local function respond(body) return { StatusCode = 200, Body = body, Headers = {} } end
local function message(content_, stop, usage)
	return respond(Json.encode(Json.object({ id = "msg", type = "message", role = "assistant", model = "claude-opus-5-5",
		content = content_, stop_reason = stop, usage = usage or { input_tokens = 100, cache_read_input_tokens = 900, output_tokens = 20 } })))
end
local function tool(id, name, input_) return Json.object({ type = "tool_use", id = id, name = name, input = input_ or Json.object() }) end
local function txt(s) return Json.object({ type = "text", text = s }) end
local function thinking() return Json.object({ type = "thinking", thinking = "", signature = "sig==" }) end
local turnBodies = {}
local function dumpBodies(label, from)
	for i = from, #Http.sent do
		print("BODY>>>" .. label .. "|" .. (i - from + 1) .. "|" .. Http.sent[i].Body .. "<<<BODY")
	end
end

-- 1. plain chat by default; the toggle switches agent mode on
render()
check("agent toggle", texts("Mod agent: Claude poate acționa în Studio") == 1 and texts("✓ Mod agent") == 0)
check("plain quick prompts", texts("›  Ce animații lipsesc?") == 1 and texts("›  Verifică scriptele suspecte") == 0)
check("modules + log kept", texts("Module în joc") == 1 and texts("Ce s-a făcut  (1)") == 1)
click(findText(content, "Mod agent: Claude poate acționa în Studio")[1])
runQueue()
check("agent saved", store["LostCube.AI.Agent"] == true)
check("agent on", texts("✓ Mod agent: Claude poate acționa în Studio") == 1)
check("agent quick prompts", texts("›  Creează un efect de lovitură potrivit jocului") == 1 and texts("›  Generează animațiile de luptă care lipsesc") == 1
	and texts("›  Verifică scriptele suspecte") == 1 and texts("›  Ce animații lipsesc?") == 0)
check("allow-code toggle off", texts("Permite cod fără confirmare") == 1 and texts("✓ Permite cod fără confirmare") == 0)
check("agent note", texts("îți cere voie înainte de fiecare modificare") >= 1)
check("stop hidden", button("⏹ Oprește") and button("⏹ Oprește").Visible == false)

-- 2. an agent turn: reads run by themselves, the change waits for a click
Http.sent = {}
Http.queue = {
	message({ thinking(), txt("Mă uit întâi la selecție și la efecte."), tool("t1", "get_selection"), tool("t2", "list_effects") }, "tool_use"),
	message({ txt("Creez efectul **Hit**."), tool("t3", "create_effect_from_template", Json.object({ name = "Hit", template = "PUNCH", color = "#FF8A3D" })) }, "tool_use"),
	message({ tool("t4", "run_luau", Json.object({ code = "print('x')\n\tlocal a = 1", summary = "Testează ceva." })) }, "tool_use"),
	message({ txt("Gata! Am creat **Hit**.") }, "end_turn"),
}
click(findText(content, "›  Creează un efect de lovitură potrivit jocului")[1])
runQueue(50)
check("two requests so far", #Http.sent == 2, #Http.sent)
check("read cards done", texts("⌕  Citește selecția") == 1 and texts("⌕  Listează efectele") == 1 and texts("gata") >= 2)
check("text step rendered", texts("Mă uit întâi la selecție și la efecte.") == 1)
check("pending card", texts("✎  Creează efect din șablon") == 1 and texts("așteaptă aprobarea") >= 1)
check("pending summary", texts("„Hit” din șablonul PUNCH · culoare #FF8A3D") == 1)
check("approve buttons", button("✓ Permite") ~= nil and button("✗ Refuză") ~= nil
	and button("Permite mereu „Creează efect din șablon” în conversația asta") ~= nil)
check("stop visible", button("⏹ Oprește").Visible == true and button("Claude lucrează…") ~= nil)
check("wait line", texts("așteaptă aprobarea ta") == 1 and texts("pas 2/12") == 1 and texts("tokeni intrare") == 1)
check("nothing created yet", #created == 0)
-- a full re-render (effects changed, tab switch...) keeps the pending card and the draft
input().Text = "ciornă"
render()
runQueue(20)
check("pending card survives re-render", button("✓ Permite") ~= nil and texts("✎  Creează efect din șablon") == 1)
check("draft kept", input().Text == "ciornă")
check("still waiting", #Http.sent == 2)
click(button("✓ Permite"))
runQueue(50)
check("approved -> created", #created == 1 and created[1] == "Hit")
check("third request", #Http.sent == 3)
check("code card", texts("✎  Rulează cod Luau") == 1 and texts("Testează ceva.") == 1)
local codeBoxes = findAll(content, function(c) return c.ClassName == "TextBox" and c.TextEditable == false and has(c.Text, "print('x')") end)
check("code shown monospace", #codeBoxes == 1 and codeBoxes[1].Font == Enum.Font.Code and has(codeBoxes[1].Text, "    local a = 1"))
check("no always for code", button("Permite mereu „Rulează cod Luau” în conversația asta") == nil and button("✓ Permite") ~= nil)
click(button("✗ Refuză"))
runQueue(50)
check("four requests", #Http.sent == 4)
check("final text", texts("Gata! Am creat <b>Hit</b>.") == 1)
check("refused card", texts("refuzat") >= 1 and texts("Refuzat de tine.") == 1)
check("usage line", texts("4 pași · 4 unelte") == 1, "")
check("idle again", button("⏹ Oprește").Visible == false and button("Trimite") ~= nil and not panel.busy)
local last = JSON.decode(Http.sent[4].Body)
local results = last.messages[#last.messages].content
check("refusal sent as error", results[1].is_error == true and has(results[1].content, "refused") and results[1].tool_use_id == "t4")
check("approved result sent", JSON.decode(Http.sent[3].Body).messages[5].content[1].content:find("Am creat efectul Hit", 1, true) ~= nil)
check("system has agent prompt + context", has(last.system[1].text, "act in Studio through tools") and has(last.system[1].text, "Max 60000"))
check("live state in system", last.system[2] and has(last.system[2].text, "Boom (0.6 s, GROUND)"))
dumpBodies("p1", 1)
local history = panel:history()
check("history: question + one assistant text", #history == 2 and history[1].content == "Creează un efect de lovitură potrivit jocului: "
	.. "uită-te la genul jocului, la paleta hărții și la efectele care există deja, alege șablonul și culoarea potrivite, creează "
	.. "efectul și arată-mi-l cu o previzualizare. La final spune-mi cum îl pornesc din cod când lovește personajul.")
check("history: tool log", has(history[2].content, "Gata! Am creat **Hit**.") and has(history[2].content, "[Unelte folosite în tura asta: get_selection")
	and has(history[2].content, "create_effect_from_template („Hit” din șablonul PUNCH · culoare #FF8A3D) → gata")
	and has(history[2].content, "run_luau (Testează ceva.) → refuzat"), history[2].content)

-- 3. second turn: "Permite mereu" lasts for the conversation; old tool blocks are not replayed
Http.sent = {}
Http.queue = {
	message({ tool("u1", "create_effect_from_template", Json.object({ name = "Hit2", template = "PUNCH" })) }, "tool_use"),
	message({ tool("u2", "create_effect_from_template", Json.object({ name = "Hit3", template = "PUNCH" })) }, "tool_use"),
	message({ txt("Am făcut două.") }, "end_turn"),
}
input().Text = "Mai fă două efecte."
click(button("Trimite"))
runQueue(50)
check("input cleared", input().Text == "")
check("pending again", button("Permite mereu „Creează efect din șablon” în conversația asta") ~= nil)
click(button("Permite mereu „Creează efect din șablon” în conversația asta"))
runQueue(80)
check("both created, second without asking", #created == 3 and created[3] == "Hit3" and #Http.sent == 3, #Http.sent)
check("turn 2 done", texts("Am făcut două.") == 1)
local b1 = JSON.decode(Http.sent[1].Body)
check("turn 2 history is text only", #b1.messages == 3 and type(b1.messages[2].content) == "string"
	and has(b1.messages[2].content, "Unelte folosite") and not has(Http.sent[1].Body, '"tool_use"'))
dumpBodies("p2", 1)

-- 4. code with "permite cod fără confirmare" + stop while a card waits
click(findText(content, "Permite cod fără confirmare")[1])
runQueue()
check("allow code saved", store["LostCube.AI.AllowCode"] == true and texts("✓ Permite cod fără confirmare") == 1)
Http.sent = {}
Http.queue = {
	message({ tool("v1", "run_luau", Json.object({ code = "return 1", summary = "Unu." })), tool("v2", "get_selection") }, "tool_use"),
	message({ txt("never") }, "end_turn"),
}
input().Text = "Rulează ceva."
click(button("Trimite"))
runQueue(30)
check("always offered for code now", button("Permite mereu „Rulează cod Luau” în conversația asta") ~= nil)
click(button("⏹ Oprește"))
runQueue(60)
check("stop: one request only", #Http.sent == 1)
check("stop: card refused", texts("Oprit înainte să ruleze.") == 1)
check("stop: note", texts("Oprit de tine după 1 pas") == 1)
check("stop: idle", not panel.busy and panel.run == nil and button("⏹ Oprește").Visible == false)
Http.queue = {}

-- 5. "Golește" while a card waits: the loop ends, nothing more is sent, "Permite mereu" is forgotten
Http.sent = {}
Http.queue = { message({ tool("w1", "create_effect_from_template", Json.object({ name = "Hit4", template = "PUNCH" })) }, "tool_use"),
	message({ txt("never") }, "end_turn") }
input().Text = "Încă unul."
click(button("Trimite"))
runQueue(30)
-- "Permite mereu" from turn 3 still applies -> created without asking; then the loop ends normally
check("always still on", #created == 4)
runQueue(30)
Http.sent = {}
Http.queue = { message({ tool("w2", "run_luau", Json.object({ code = "return 2", summary = "Doi." })) }, "tool_use"),
	message({ txt("never") }, "end_turn") }
input().Text = "Cod."
click(button("Trimite"))
runQueue(30)
check("code pending", button("✓ Permite") ~= nil)
click(button("Golește"))
runQueue(60)
check("cleared", #panel.messages == 0 and not panel.busy and #Http.sent == 1)
check("always forgotten", next(panel.allowAlways) == nil)
Http.queue = {}

-- 6. errors: after a tool ran the turn stays (retry asks again); without tools the pair leaves the conversation
Http.sent = {}
Http.queue = { message({ tool("x1", "get_selection") }, "tool_use"),
	{ StatusCode = 400, Body = '{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}', Headers = {} } }
input().Text = "Eroare după unealtă."
click(button("Trimite"))
runQueue(40)
check("error shown", texts("Cererea a fost respinsă (400)") == 1 and button("Reîncearcă") ~= nil)
history = panel:history()
check("error turn kept in history", #history == 2 and has(history[2].content, "Tura s-a întrerupt cu o eroare"), history[2] and history[2].content)
Http.queue = { { StatusCode = 401, Body = '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}', Headers = {} } }
click(button("Reîncearcă"))
runQueue(40)
check("retry = new turn", #panel.messages == 4 and texts("Cheie API invalidă (401)") == 1)
history = panel:history()
check("failed turn without tools not in history", #history == 2)
Http.queue = { message({ txt("Acum merge.") }, "end_turn") }
local retries = findAll(content, function(c) return c.ClassName == "TextButton" and c.Text == "Reîncearcă" end)
click(retries[#retries])
runQueue(40)
check("retry without tools replaces the pair", #panel.messages == 4 and texts("Acum merge.") == 1 and texts("Cheie API invalidă") == 0)

-- 7. while another tab is shown, the agent keeps its state without redrawing that tab
Http.sent = {}
Http.queue = { message({ tool("y1", "create_effect_from_template", Json.object({ name = "Hit5", template = "PUNCH" })) }, "tool_use"),
	message({ txt("Gata și aici.") }, "end_turn") }
input().Text = "Pe alt tab."
click(button("Trimite"))
runQueue(20)
for _, c in content:GetChildren() do c:Destroy() end -- the App shows another tab
app.tab = "VFX"
local rendersBefore = renders
runQueue(40)
check("no redraw of another tab", renders == rendersBefore)
app.tab = "Claude"
render()
check("pending card when coming back", button("✓ Permite") ~= nil)
click(button("✓ Permite"))
runQueue(40)
check("finished after coming back", texts("Gata și aici.") == 1 and #created == 5)

-- 8. agent off -> the plain chat again (no tools in the request)
click(findText(content, "✓ Mod agent: Claude poate acționa în Studio")[1])
runQueue()
check("agent off", store["LostCube.AI.Agent"] == false and texts("›  Ce animații lipsesc?") == 1)
Http.sent = {}
Http.queue = { message({ txt("Răspuns simplu.") }, "end_turn") }
input().Text = "Întrebare simplă"
click(button("Trimite"))
runQueue(40)
local plainBody = JSON.decode(Http.sent[1].Body)
check("plain request has no tools", plainBody.tools == nil and plainBody.tool_choice == nil and texts("Răspuns simplu.") == 1)
check("plain request sees agent turns as text", has(plainBody.messages[#plainBody.messages - 1].content, "Gata și aici."))

panel:destroy()
runQueue()
print(string.format("panel: %d passed, %d failed, %d mock/runtime errors, %d renders", PASS, FAIL, #MOCK_ERRORS, renders))
for _, e in MOCK_ERRORS do print("  ERR", e) end
