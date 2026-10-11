-- AI.luau: settings, request body, headers, response parsing, error messages, retry, history trimming.
-- HttpService is a mock queue (no network); the real AI.luau runs with it.
local LC = ...
local t = LC.kit.new("ai")
local eq, has = t.eq, t.has

local Http = { queue = {}, sent = {}, decoded = {}, encoded = nil }
function Http:JSONEncode(v)
	self.encoded = v
	return "<json>"
end
function Http:JSONDecode(s)
	local v = self.decoded[s]
	if v == nil then
		error("bad json")
	end
	return v
end
function Http:RequestAsync(req)
	table.insert(self.sent, req)
	local nxt = table.remove(self.queue, 1)
	if type(nxt) == "string" then
		error(nxt)
	end
	return nxt
end
local game = { GetService = function(_, name) return Http end }
local waited = {}
local task = { wait = function(s) table.insert(waited, s) end }

-- the cheat sheet reads the live modules when it can: here Editor is absent (static fallback), the others are real
local tree = LC.modtree.new{ env = LC.env{ game = game, task = task }, mocks = { Editor = LC.modtree.MISSING } }
local AI = tree.load("AI")

local store = {}
local plugin = {
	GetSetting = function(_, k) return store[k] end,
	SetSetting = function(_, k, v) store[k] = v end,
}

-- settings
eq("no key", AI.getKey(plugin), nil)
eq("request without key", (AI.request(plugin, { messages = { { role = "user", content = "x" } } })), false)
AI.setKey(plugin, "  sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789XYZW\n")
eq("key trimmed", AI.getKey(plugin), "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789XYZW")
eq("mask", AI.mask(AI.getKey(plugin)), "sk-ant-…XYZW")
eq("looks like key", AI.looksLikeKey(AI.getKey(plugin)), true)
eq("not a key", AI.looksLikeKey("hello"), false)
eq("default model", AI.getModel(plugin), "claude-opus-5-5")
eq("set bad model", AI.setModel(plugin, "gpt"), false)
eq("set sonnet", AI.setModel(plugin, "claude-sonnet-5-5"), true)
eq("model saved", AI.getModel(plugin), "claude-sonnet-5-5")
eq("default effort", AI.getEffort(plugin), "medium")
AI.setEffort(plugin, "turbo")
eq("bad effort ignored", AI.getEffort(plugin), "medium")
AI.setEffort(plugin, "high")
eq("effort saved", AI.getEffort(plugin), "high")
eq("no plugin", AI.getKey(nil), nil)
eq("plugin GetSetting error", AI.getKey({ GetSetting = function() error("x") end }), nil)

-- messages
local m = AI.cleanMessages({
	{ role = "assistant", content = "hi" }, { role = "user", content = " a " }, { role = "user", content = "b" },
	{ role = "assistant", content = "" }, { role = "system", content = "x" }, { role = "assistant", content = "c" },
	{ role = "user", content = "d" }, { role = "assistant", content = "prefill" },
})
eq("clean count", #m, 3)
eq("clean merged", m[1].content, "a\n\nb")
eq("clean last user", m[#m].role, "user")

-- body
local body = AI.buildBody({ messages = { { role = "user", content = "q" } }, system = "S", maxTokens = 4000.7 },
	"claude-opus-5-5", "medium")
eq("body model", body.model, "claude-opus-5-5")
eq("body max", body.max_tokens, 4000)
eq("body effort", body.output_config.effort, "medium")
eq("body fallback opus", body.fallbacks, "default")
eq("no thinking", body.thinking, nil)
eq("no temperature", body.temperature, nil)
local hb = AI.buildBody({ messages = { { role = "user", content = "q" } } }, "claude-haiku-5-5", "low")
eq("haiku no fallback", hb.fallbacks, nil)
eq("haiku no beta", AI.headers("k", "claude-haiku-5-5")["anthropic-beta"], nil)
eq("opus beta", AI.headers("k", "claude-opus-5-5")["anthropic-beta"], "server-side-fallback-2026-07-01")
eq("sonnet beta", AI.headers("k", "claude-sonnet-5-5")["anthropic-beta"], "server-side-fallback-2026-07-01")
eq("version header", AI.headers("k", "claude-opus-5-5")["anthropic-version"], "2023-06-01")
eq("empty body refused", (AI.buildBody({ messages = {} }, "claude-opus-5-5", "low")), nil)

-- parse
local ok, text, info = AI.parseResponse({
	model = "claude-opus-5-5", stop_reason = "end_turn",
	content = { { type = "thinking", thinking = "" }, { type = "text", text = "Salut " }, { type = "text", text = "lume" } },
	usage = { input_tokens = 100, cache_read_input_tokens = 900, cache_creation_input_tokens = 0, output_tokens = 42 },
})
eq("parse ok", ok, true)
eq("parse text joined, thinking skipped", text, "Salut lume")
eq("parse input tokens", info.inputTokens, 1000)
eq("parse cached", info.cachedTokens, 900)
eq("parse out", info.outputTokens, 42)
ok, text = AI.parseResponse({ stop_reason = "refusal", content = {}, stop_details = { category = "cyber" } })
eq("refusal not ok", ok, false)
has("refusal msg", text, "refuzat")
has("refusal category", text, "cyber")
ok, text = AI.parseResponse({ stop_reason = "refusal", content = {}, stop_details = nil })
has("refusal no details", text, "refuzat cererea.")
ok, text = AI.parseResponse({ stop_reason = "max_tokens", content = { { type = "text", text = "partial" } } })
eq("max tokens ok", ok, true)
has("max tokens text", text, "partial\n\n_(Răspunsul a fost tăiat")
ok, text = AI.parseResponse({ stop_reason = "max_tokens", content = { { type = "thinking" } } })
eq("max tokens empty ok", ok, true)
has("max tokens only note", text, "tăiat")
ok, text = AI.parseResponse({ stop_reason = "end_turn", content = {} })
eq("empty answer", ok, false)
ok, text = AI.parseResponse("garbage")
eq("non-table", ok, false)

-- http errors
local msg, retry = AI.describeHttpError(401, { type = "error", error = { type = "authentication_error", message = "invalid x-api-key" } }, {})
has("401", msg, "Cheie API invalidă")
has("401 detail", msg, "invalid x-api-key")
eq("401 no retry", retry, nil)
msg, retry = AI.describeHttpError(429, nil, { ["Retry-After"] = "5" })
has("429", msg, "peste 5 s")
eq("429 short retry", retry, 5)
msg, retry = AI.describeHttpError(429, nil, { ["retry-after"] = "60" })
eq("429 long no retry", retry, nil)
msg, retry = AI.describeHttpError(429, nil, {})
eq("429 no header", retry, nil)
has("429 minute", msg, "un minut")
msg, retry = AI.describeHttpError(529, { error = { type = "overloaded_error", message = "Overloaded" } }, {})
has("529", msg, "supraîncărcate")
eq("529 retry", retry, 3)
msg, retry = AI.describeHttpError(500, nil, nil)
eq("500 retry", retry, 3)
msg = AI.describeHttpError(400, { error = { type = "invalid_request_error", message = "Your credit balance is too low" } }, {})
has("400 credit", msg, "Billing")
msg = AI.describeHttpError(400, { error = { message = "messages: bad" } }, {})
has("400 shows message", msg, "messages: bad")
msg = AI.describeHttpError(418, nil, {})
has("other", msg, "418")

-- network errors
has("permission", AI.describeNetworkError("Http requests to this domain are not allowed"), "Manage Plugins")
has("not enabled", AI.describeNetworkError("Http requests are not enabled. Enable via game settings"), "Manage Plugins")
has("timeout", AI.describeNetworkError("HttpError: Timedout"), "prea mult")
has("connect", AI.describeNetworkError("HttpError: ConnectFail"), "conecta")
has("other net", AI.describeNetworkError("weird"), "weird")

-- describeInfo
eq("thousands", AI.thousands(1234567), "1 234 567")
eq("thousands small", AI.thousands(12), "12")
eq("thousands 3", AI.thousands(123), "123")
eq("describe", AI.describeInfo({ model = "claude-opus-5-5", requestedModel = "claude-opus-5-5", inputTokens = 12345,
	cachedTokens = 10000, outputTokens = 640, seconds = 13.6 }),
	"Opus 5.5 · 12 345 tokeni intrare (10 000 din cache) · 640 ieșire · 14 s")
has("describe fallback", AI.describeInfo({ model = "claude-opus-4-8", requestedModel = "claude-opus-5-5", inputTokens = 1, outputTokens = 1 }),
	"claude-opus-4-8 (în locul lui Opus 5.5)")

-- full request: 529 then 200 (one automatic retry)
AI.setModel(plugin, "claude-opus-5-5")
Http.decoded["E529"] = { type = "error", error = { type = "overloaded_error", message = "Overloaded" } }
Http.decoded["OK"] = { model = "claude-opus-5-5", stop_reason = "end_turn", content = { { type = "text", text = "Răspuns" } },
	usage = { input_tokens = 10, output_tokens = 5 } }
Http.queue = { { StatusCode = 529, Body = "E529", Headers = {} }, { StatusCode = 200, Body = "OK", Headers = {} } }
local statuses = {}
local okR, textR, infoR = AI.ask(plugin, "  Ce animații lipsesc?  ",
	{ { role = "user", content = "q1" }, { role = "assistant", content = "a1" } }, "## Joc\nUn joc.",
	{ live = "Efecte: Boom", onStatus = function(s) table.insert(statuses, s) end })
eq("ask ok after retry", okR, true)
eq("ask text", textR, "Răspuns")
eq("ask requests", #Http.sent, 2)
eq("waited once", #waited, 1)
eq("wait 3s", waited[1], 3)
has("status shown", statuses[1], "reîncerc")
eq("info requested", infoR.requestedModel, "claude-opus-5-5")
local req = Http.sent[1]
eq("url", req.Url, "https://api.anthropic.com/v1/messages")
eq("method", req.Method, "POST")
eq("key header", req.Headers["x-api-key"], "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789XYZW")
local sentBody = Http.encoded
eq("sent effort (saved high)", sentBody.output_config.effort, "high")
eq("sent max chat", sentBody.max_tokens, 4000)
eq("sent msgs", #sentBody.messages, 3)
eq("sent question trimmed", sentBody.messages[3].content, "Ce animații lipsesc?")
eq("system blocks", #sentBody.system, 2)
eq("system cached", sentBody.system[1].cache_control.type, "ephemeral")
eq("live not cached", sentBody.system[2].cache_control, nil)
has("context in system", sentBody.system[1].text, "## Joc\nUn joc.")
has("cheat sheet in system", sentBody.system[1].text, "Editor.newEffect")
has("presets fallback list", sentBody.system[1].text, "GROUND_RIBBON")
has("live text", sentBody.system[2].text, "Efecte: Boom")
eq("last error cleared", AI.lastError, nil)

-- 529 twice -> error (only one retry)
Http.sent, waited = {}, {}
Http.queue = { { StatusCode = 529, Body = "E529", Headers = {} }, { StatusCode = 529, Body = "E529", Headers = {} } }
okR, textR = AI.ask(plugin, "x", nil, nil)
eq("529 twice fails", okR, false)
eq("529 twice requests", #Http.sent, 2)
has("lastError set", AI.lastError, "supraîncărcate")
has("no context note", Http.encoded.system[1].text, "Nu există încă o analiză")
eq("no live block", #Http.encoded.system, 1)

-- network error (permission)
Http.sent = {}
Http.queue = { "Http requests to this domain are not allowed" }
okR, textR = AI.ask(plugin, "x", {}, nil)
eq("perm fails", okR, false)
has("perm msg", textR, "api.anthropic.com")

-- 401 no retry
Http.sent = {}
Http.decoded["E401"] = { type = "error", error = { type = "authentication_error", message = "invalid x-api-key" } }
Http.queue = { { StatusCode = 401, Body = "E401", Headers = {} } }
okR, textR = AI.ask(plugin, "x", {}, nil)
eq("401 single request", #Http.sent, 1)
has("401 text", textR, "401")

-- non-JSON error body
Http.sent = {}
Http.queue = { { StatusCode = 502, Body = "<html>bad gateway</html>", Headers = {} }, { StatusCode = 200, Body = "OK", Headers = {} } }
okR = AI.ask(plugin, "x", {}, nil)
eq("502 html retried ok", okR, true)

-- analyze
Http.sent = {}
Http.queue = { { StatusCode = 200, Body = "OK", Headers = {} } }
okR, textR = AI.analyzeGame(plugin, "# Scan\nParts: 10")
eq("analyze ok", okR, true)
eq("analyze max tokens", Http.encoded.max_tokens, 8000)
has("analyze scan in user msg", Http.encoded.messages[1].content, "<scan>\n# Scan\nParts: 10\n</scan>")
has("analyze prompt", Http.encoded.system[1].text, "## Plan de upgrade în 10 pași")
eq("analyze fallbacks", Http.encoded.fallbacks, "default")
okR, textR = AI.analyzeGame(plugin, "   ")
eq("analyze empty refused", okR, false)

-- haiku request: no fallbacks, no beta header
AI.setModel(plugin, "claude-haiku-5-5")
Http.sent = {}
Http.queue = { { StatusCode = 200, Body = "OK", Headers = {} } }
okR = AI.ask(plugin, "x", {}, nil)
eq("haiku ok", okR, true)
eq("haiku body no fallbacks", Http.encoded.fallbacks, nil)
eq("haiku req no beta", Http.sent[1].Headers["anthropic-beta"], nil)

-- test()
Http.queue = { { StatusCode = 200, Body = "OK", Headers = {} } }
local okT, msgT = AI.test(plugin)
eq("test ok", okT, true)
has("test msg", msgT, "Conexiunea merge")
eq("test effort low", Http.encoded.output_config.effort, "low")

-- history trimmed to MAX_HISTORY
local long = {}
for i = 1, 40 do
	table.insert(long, { role = i % 2 == 1 and "user" or "assistant", content = "m" .. i })
end
Http.queue = { { StatusCode = 200, Body = "OK", Headers = {} } }
AI.ask(plugin, "nou", long, nil)
local sentMsgs = Http.encoded.messages
eq("history first is user", sentMsgs[1].role, "user")
eq("history ends with question", sentMsgs[#sentMsgs].content, "nou")
eq("history size", #sentMsgs <= AI.MAX_HISTORY + 1, true)

-- clear key
AI.setKey(plugin, nil)
eq("key cleared", AI.getKey(plugin), nil)


-- the cheat sheet lists the real animation packs / generated animations when those modules are there
do
	local AnimLibrary = tree.load("AnimLibrary")
	local AnimGen = tree.load("AnimGen")
	local sheet = AI.editorCheatSheet()
	has("sheet lists the first real pack", sheet, AnimLibrary.PACKS[1].label)
	has("sheet lists the last real pack", sheet, AnimLibrary.PACKS[#AnimLibrary.PACKS].label)
	has("sheet lists a real generated animation", sheet, AnimGen.LIST[1].label)
end

-- ... and the live Editor presets / templates when Editor is there (a fresh AI: the sheet is cached per module)
do
	local tree2 = LC.modtree.new{ env = LC.env{ game = game, task = task }, mocks = {
		Editor = { PRESETS = { { key = "ZZ_PRESET", kind = "PARTICLES", label = "Zed" } },
			TEMPLATES = { { key = "ZZ_TEMPLATE", category = "Cat", label = "Zeta" } } } } }
	local sheet = tree2.load("AI").editorCheatSheet()
	has("live preset in the sheet", sheet, "ZZ_PRESET (PARTICLES: Zed)")
	has("live template in the sheet", sheet, "ZZ_TEMPLATE (Cat: Zeta)")
	eq("static preset list replaced", string.find(sheet, "GROUND_RIBBON", 1, true), nil)
end

-- the prompts: every Editor function the reference names exists in the real Editor, the new ones are there, every tool the
-- agent prompt names exists, every tool that changes the place is in the approval sentence, and no emoji / tab icons
do
	local sheet = AI.editorCheatSheet()
	local editorSource = LC.files["LostCube/Editor/init.luau"] or ""
	local toolsSource = LC.files["LostCube/Tools.luau"] or ""
	local seen = {}
	for name in string.gmatch(sheet .. AI.CHAT_PROMPT, "Editor%.([%a_]+)%(") do
		if not seen[name] then
			seen[name] = true
			has("Editor." .. name .. " exists", editorSource, "function Editor." .. name .. "(")
		end
	end
	for _, name in { "exportEffect", "importEffect", "exportAll", "importMany", "describeCode", "recolorEffect", "paletteOf",
		"suggestColors", "matchPalette", "makeVariants", "scaleEffect" } do
		has("sheet documents Editor." .. name, sheet, "Editor." .. name .. "(")
	end
	local approval = string.match(AI.AGENT_PROMPT, "Tools that change the place %(([^%)]+)%) wait until the developer approves")
	t.check(approval ~= nil, "approval sentence")
	local writes = 0
	for name in string.gmatch(toolsSource, 'name = "([%w_]+)", label = "[^"]+", write = true') do
		writes += 1
		has("write tool " .. name .. " needs approval", approval or "", name)
	end
	t.check(writes >= 9, "write tools found in Tools.luau: " .. writes)
	has("import_effect needs approval", approval or "", "import_effect")
	has("recolor_effect needs approval", approval or "", "recolor_effect")
	local readOnly = string.match(AI.AGENT_PROMPT, "Read%-only tools run right away: ([^\n]+)") or ""
	for _, name in { "export_effect", "suggest_effect_colors" } do
		has("read-only " .. name .. " listed", readOnly, name)
	end
	for name in string.gmatch(readOnly .. ", " .. (approval or ""), "([%w_]+)") do
		has("tool " .. name .. " exists", toolsSource, 'name = "' .. name .. '"')
	end
	for _, text in { sheet, AI.ANALYSIS_PROMPT, AI.CHAT_PROMPT, AI.AGENT_PROMPT } do
		for _, symbol in { "🧠", "✨", "◆", "🎬", "📚", "⚠", "✓" } do
			eq("no " .. symbol .. " in the prompts", string.find(text, symbol, 1, true), nil)
		end
	end
	has("tabs named as in the app", sheet, "Joc: game scan")
	has("effects tab named", AI.AGENT_PROMPT, "preview in the Efecte tab")
end

t.finish()
