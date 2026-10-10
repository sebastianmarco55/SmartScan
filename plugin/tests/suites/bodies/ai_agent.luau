-- AI.luau: JSON encoder, rawField, truncate, and the agent loop against a scripted HttpService (never the real API)
local AI = load("AI")
local Json = AI.Json
local store = {}
local plugin = { GetSetting = function(_, k) return store[k] end, SetSetting = function(_, k, v) store[k] = v end }

-- ---------------------------------------------------------------------------------------------
-- JSON encoder
-- ---------------------------------------------------------------------------------------------
check("empty table -> []", Json.encode({}) == "[]")
check("empty object -> {}", Json.encode(Json.object()) == "{}")
check("nested empty object", Json.encode({ input = Json.object({}) }) == '{"input":{}}')
check("array", Json.encode({ 1, 2, "a" }) == '[1,2,"a"]')
check("sorted keys", Json.encode({ b = 1, a = 2, c = { z = 1, y = 2 } }) == '{"a":2,"b":1,"c":{"y":2,"z":1}}')
check("ordered keys", Json.encode(Json.object({ type = "x", name = "n", extra = 1 }, { "name", "type" })) == '{"name":"n","type":"x","extra":1}')
check("escapes", Json.encode('a"b\\c\nd\te\1') == '"a\\"b\\\\c\\nd\\te\\u0001"', Json.encode('a"b\\c\nd\te\1'))
check("del escaped", Json.encode("\127") == '"\\u007f"')
check("utf8 kept", Json.encode("ăîșțâ 🎬") == '"ăîșțâ 🎬"')
check("invalid utf8 fixed", Json.encode("a\255b") == '"a\u{FFFD}b"')
check("cut multibyte fixed", utf8.len(JSON.decode(Json.encode(string.sub("ș", 1, 1)))) ~= nil)
check("numbers", Json.encode({ 1, 1.5, -3, 0.1, 1e20, 0 / 0, math.huge }) == "[1,1.5,-3,0.1,1e+20,0,0]",
	Json.encode({ 1, 1.5, -3, 0.1, 1e20, 0 / 0, math.huge }))
check("third", JSON.decode(Json.encode(1 / 3)) == 1 / 3)
check("bool/null", Json.encode({ a = true, b = false }) == '{"a":true,"b":false}')
check("raw", Json.encode({ content = Json.raw('[{"x" : 1}]') }) == '{"content":[{"x" : 1}]}')
check("mixed table -> object", Json.encode({ 1, 9, 13, mid = 0.45 }) == '{"1":1,"2":9,"3":13,"mid":0.45}')
check("function fails", not pcall(Json.encode, { f = print }))
local deep = {}
local node = deep
for _ = 1, 60 do node.x = {}; node = node.x end
check("too deep fails", not pcall(Json.encode, deep))
for _, v in { "plain", 'q"uote', "nl\nnl", "ctrl\0\31", "ăî🎬" } do
	check("roundtrip " .. v, JSON.decode(Json.encode(v)) == v)
end

-- ---------------------------------------------------------------------------------------------
-- rawField
-- ---------------------------------------------------------------------------------------------
local tricky = '{ "container" : {"content": "not this"}, "id":"m\\"}{[", "n": -1.5e3, "t": true, "z": null,\n'
	.. ' "content" :  [ {"type":"text","text":"a \\"]} [{ b"} , {"type":"tool_use","input":{}} ] , "after": 1 }'
check("rawField content", AI.rawField(tricky, "content") == '[ {"type":"text","text":"a \\"]} [{ b"} , {"type":"tool_use","input":{}} ]',
	AI.rawField(tricky, "content"))
check("rawField number", AI.rawField(tricky, "n") == "-1.5e3")
check("rawField literal", AI.rawField(tricky, "t") == "true")
check("rawField null", AI.rawField(tricky, "z") == "null")
check("rawField string", AI.rawField(tricky, "id") == '"m\\"}{["')
check("rawField after", AI.rawField(tricky, "after") == "1")
check("rawField missing", AI.rawField(tricky, "nope") == nil)
check("rawField not object", AI.rawField("[1,2]", "content") == nil)
check("rawField malformed", AI.rawField('{"content": [1, 2', "content") == nil)
check("rawField garbage", AI.rawField("<html>", "content") == nil)
check("rawField nil", AI.rawField(nil, "content") == nil)

-- ---------------------------------------------------------------------------------------------
-- truncate
-- ---------------------------------------------------------------------------------------------
check("short kept", AI.truncate("abc", 10) == "abc")
local long = string.rep("ș", 10) -- 20 bytes
local cut = AI.truncate(long, 5)
check("cut on char boundary", string.sub(cut, 1, 4) == "șș" and utf8.len(cut) ~= nil, cut)
check("cut note", has(cut, "tăiat: încă 16 caractere"), cut)

-- ---------------------------------------------------------------------------------------------
-- agent loop
-- ---------------------------------------------------------------------------------------------
AI.setKey(plugin, "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789XYZW")
local Tools = load("Tools")
local defs = Tools.definitions()

local function respond(body)
	return { StatusCode = 200, Body = body, Headers = {} }
end
local function message(content, stop, usage)
	return respond(Json.encode(Json.object({ id = "msg", type = "message", role = "assistant", model = "claude-opus-5-5",
		content = content, stop_reason = stop, usage = usage or { input_tokens = 10, output_tokens = 5 } })))
end
local function tool(id, name, input)
	return Json.object({ type = "tool_use", id = id, name = name, input = input or Json.object() })
end

-- every request body: valid JSON, and the next one starts with the exact bytes of the previous one
local function bodies()
	local out = {}
	for _, r in Http.sent do table.insert(out, r.Body) end
	return out
end
local function checkAppendOnly(label, list)
	for i, b in list do
		local ok, decoded = pcall(JSON.decode, b)
		check(label .. ": body " .. i .. " is valid JSON", ok, decoded)
		print("BODY>>>" .. label .. "|" .. i .. "|" .. b .. "<<<BODY")
		if i > 1 then
			local prev = list[i - 1]
			local prefix = string.sub(prev, 1, #prev - 2) -- without the closing "]}"
			check(label .. ": body " .. i .. " extends body " .. (i - 1) .. " byte for byte",
				string.sub(b, 1, #prefix + 1) == prefix .. ",")
		end
	end
end

-- scenario 1: thinking + text + 3 tool calls (one with an empty input) -> a write refused -> final answer
local resp1 = '{\n  "id": "msg_01", "type": "message", "role": "assistant", "model": "claude-opus-5-5",\n'
	.. '  "container": {"content": "decoy"},\n'
	.. '  "content": [\n'
	.. '    {"type": "thinking", "thinking": "", "signature": "EqQBCkgIBxABGAIiQL\\"}{[sig]\\\\/=="},\n'
	.. '    {"type": "text", "text": "Mă uit întâi la selecție. {\\"x\\": [1]} \\u0103"},\n'
	.. '    {"type": "tool_use", "id": "toolu_01", "name": "get_selection", "input": {}},\n'
	.. '    {"type": "tool_use", "id": "toolu_02", "name": "list_effects", "input": {}},\n'
	.. '    {"type": "tool_use", "id": "toolu_03", "name": "find_instances", "input": {"query": "Sword", "limit": 5}}\n'
	.. '  ],\n'
	.. '  "stop_reason": "tool_use", "stop_details": null,\n'
	.. '  "usage": {"input_tokens": 1200, "cache_creation_input_tokens": 5000, "cache_read_input_tokens": 0, "output_tokens": 150}\n}'
Http.sent = {}
Http.queue = {
	respond(resp1),
	message({ Json.object({ type = "text", text = "Creez efectul." }),
		tool("toolu_04", "create_effect_from_template", Json.object({ name = "Hit", template = "PUNCH", color = "#FF8A3D" })) },
		"tool_use", { input_tokens = 50, cache_read_input_tokens = 6200, output_tokens = 80 }),
	message({ Json.object({ type = "text", text = "Gata, am creat efectul." }) }, "end_turn",
		{ input_tokens = 30, cache_read_input_tokens = 6400, output_tokens = 40 }),
}
local ran = {}
local events = {}
local bigResult = string.rep("ă", 7000) -- 14000 bytes: cut to 12000 on a character boundary
local ok, text, info = AI.runAgent(plugin, {
	question = "Fă-mi un efect de lovitură",
	history = { { role = "user", content = "salut" }, { role = "assistant", content = "Salut! [Unelte folosite: x]" } },
	context = "# Joc\nUn joc de luptă.",
	live = "Selecția: nimic",
	tools = defs,
	runTool = function(block)
		table.insert(ran, block)
		if block.name == "get_selection" then return "Nu e nimic selectat.", false end
		if block.name == "list_effects" then return "boom", true end
		if block.name == "find_instances" then return bigResult, false end
		if block.name == "create_effect_from_template" then return "The developer refused this change.", true end
		return "?", true
	end,
	onStep = function(e) table.insert(events, e.type .. ":" .. tostring(e.iteration or "")) end,
})
local list = bodies()
check("s1 ok", ok == true, text)
check("s1 final text", text == "Gata, am creat efectul.", text)
check("s1 three requests", #list == 3, #list)
check("s1 iterations", info.iterations == 3)
check("s1 tool calls", info.toolCalls == 4, info.toolCalls)
check("s1 input tokens summed", info.inputTokens == 1200 + 5000 + 50 + 6200 + 30 + 6400, info.inputTokens)
check("s1 cached summed", info.cachedTokens == 12600)
check("s1 output summed", info.outputTokens == 270)
check("s1 tools ran in order", #ran == 4 and ran[1].id == "toolu_01" and ran[3].id == "toolu_03" and ran[4].id == "toolu_04")
check("s1 decoded input query", ran[3].input.query == "Sword" and ran[3].input.limit == 5)
check("s1 events", table.concat(events, ",") == "request:1,response:1,text:1,request:2,response:2,text:2,request:3,response:3",
	table.concat(events, ","))
checkAppendOnly("s1", list)
local b1, b2, b3 = JSON.decode(list[1]), JSON.decode(list[2]), JSON.decode(list[3])
check("s1 model", b1.model == "claude-opus-5-5")
check("s1 max_tokens", b1.max_tokens == AI.MAX_TOKENS_AGENT)
check("s1 effort", b1.output_config.effort == "medium")
check("s1 fallbacks", b1.fallbacks == "default")
check("s1 top-level cache_control", b1.cache_control and b1.cache_control.type == "ephemeral")
check("s1 tool_choice auto", b1.tool_choice.type == "auto" and not has(list[1], '"type":"any"'))
check("s1 no thinking param / no temperature", b1.thinking == nil and b1.temperature == nil)
check("s1 beta header", Http.sent[1].Headers["anthropic-beta"] == "server-side-fallback-2026-07-01")
check("s1 system agent prompt", has(b1.system[1].text, "act in Studio through tools") and b1.system[1].cache_control.type == "ephemeral")
check("s1 system untrusted note", has(b1.system[1].text, "untrusted data"))
check("s1 system context", has(b1.system[1].text, "Un joc de luptă."))
check("s1 system live block", b1.system[2] and has(b1.system[2].text, "Selecția: nimic"))
check("s1 tools count", #b1.tools == #Tools.LIST and #b1.tools == 17, #b1.tools)
check("s1 no empty properties array", not has(list[1], '"properties":[]'))
check("s1 empty properties object", has(list[1], '"name":"get_selection","description":') and has(list[1], '"properties":{}'))
local strictCount, byName = 0, {}
for _, t in b1.tools do
	byName[t.name] = t
	if t.strict then strictCount += 1 end
	check("schema object " .. t.name, t.input_schema.type == "object" and t.input_schema.additionalProperties == false
		and type(t.input_schema.required) == "table")
	for pname, p in t.input_schema.properties do
		check("param described " .. t.name .. "." .. pname, type(p.description) == "string" and p.description ~= "")
		if p.type == "object" then
			check("free object only in non-strict " .. t.name, t.strict ~= true)
		end
	end
end
check("s1 strict count", strictCount == 15, strictCount)
check("s1 add_element not strict", byName.add_element.strict == nil and byName.set_element_props.strict == nil)
check("s1 run_luau strict + required", byName.run_luau.strict == true and #byName.run_luau.input_schema.required == 2)
check("s1 enum attach", byName.create_effect_from_template.input_schema.properties.attach.enum[1] == "GROUND")
check("s1 paths array", byName.select_instances.input_schema.properties.paths.items.type == "string")
-- history: old turns as plain text, then the question
check("s1 messages start", #b1.messages == 3 and b1.messages[1].content == "salut" and b1.messages[3].content == "Fă-mi un efect de lovitură")
-- the assistant turn is copied unchanged
local rawContent = AI.rawField(resp1, "content")
check("s1 raw assistant content in body 2", has(list[2], '{"role":"assistant","content":' .. rawContent .. "}"))
check("s1 signature unchanged", b2.messages[4].content[1].signature == 'EqQBCkgIBxABGAIiQL"}{[sig]\\/==')
check("s1 empty input stays an object", has(list[2], '"name": "get_selection", "input": {}'))
local results = b2.messages[5]
check("s1 one user message with all results", results.role == "user" and #results.content == 3)
check("s1 result ids in order", results.content[1].tool_use_id == "toolu_01" and results.content[2].tool_use_id == "toolu_02"
	and results.content[3].tool_use_id == "toolu_03")
check("s1 result type", results.content[1].type == "tool_result" and results.content[1].content == "Nu e nimic selectat.")
check("s1 is_error only on errors", results.content[1].is_error == nil and results.content[2].is_error == true)
local r3 = results.content[3].content
check("s1 big result truncated", #r3 < 12200 and has(r3, "tăiat") and utf8.len(r3) ~= nil, #r3)
check("s1 refusal result", b3.messages[7].content[1].is_error == true and has(b3.messages[7].content[1].content, "refused"))
check("s1 body 3 messages", #b3.messages == 7, #b3.messages)
check("s1 tools identical", list[1]:sub(1, 2000) == list[3]:sub(1, 2000))
check("s1 lastError cleared", AI.lastError == nil)

-- fallback when the raw text cannot be cut out: tool inputs stay objects
local enc = Json.encode(AI.assistantContent(nil, { content = { { type = "tool_use", id = "x", name = "get_selection", input = {} },
	{ type = "text", text = "t" } } }))
check("fallback keeps {} input", has(enc, '"input":{}') and not has(enc, '"input":[]'), enc)
local enc2 = Json.encode(AI.assistantContent('{"content": [1, 2', { content = { { type = "tool_use", id = "y", input = {} } } }))
check("fallback on malformed raw", has(enc2, '"input":{}'), enc2)

-- scenario 2: iteration cap -> the last response's tools are not run
Http.sent = {}
Http.queue = {}
for i = 1, 3 do
	table.insert(Http.queue, message({ tool("t" .. i, "get_selection") }, "tool_use"))
end
ran = {}
ok, text, info = AI.runAgent(plugin, { question = "loop", tools = defs, maxIterations = 3,
	runTool = function(block) table.insert(ran, block.id); return "ok", false end })
check("s2 ok", ok == true)
check("s2 three requests", #Http.sent == 3)
check("s2 last tools not run", #ran == 2 and ran[2] == "t2", table.concat(ran, ","))
check("s2 stopped limit", info.stopped == "limit" and info.pending[1] == "get_selection")
check("s2 note", has(text, "limita de 3 pași") and has(text, "get_selection"), text)
checkAppendOnly("s2", bodies())

-- default cap is 12
Http.sent = {}
Http.queue = {}
for i = 1, 13 do
	table.insert(Http.queue, message({ tool("c" .. i, "list_effects") }, "tool_use"))
end
ok, text, info = AI.runAgent(plugin, { question = "loop", tools = defs, runTool = function() return "ok" end })
check("s2b default cap 12", #Http.sent == 12 and info.iterations == 12 and info.stopped == "limit", #Http.sent)

-- scenario 3: cancel while the tools of a response run -> remaining tools "Not run", no new request
Http.sent = {}
Http.queue = { message({ tool("a", "get_selection"), tool("b", "list_effects") }, "tool_use"),
	message({ Json.object({ type = "text", text = "never" }) }, "end_turn") }
local cancelled = false
ran = {}
ok, text, info = AI.runAgent(plugin, { question = "x", tools = defs,
	isCancelled = function() return cancelled end,
	runTool = function(block) table.insert(ran, block.id); cancelled = true; return "done", false end })
check("s3 one request", #Http.sent == 1)
check("s3 only first tool ran", #ran == 1 and ran[1] == "a")
check("s3 stopped", ok == true and info.stopped == "cancelled" and has(text, "Oprit de tine după 1 pas"), text)
check("s3 queue left", #Http.queue == 1)

-- cancel before the first request
Http.sent = {}
ok, text, info = AI.runAgent(plugin, { question = "x", tools = defs, isCancelled = function() return true end })
check("s3b nothing sent", #Http.sent == 0 and info.stopped == "cancelled")

-- cancel between two requests (after the tools, before the next request)
Http.sent = {}
Http.queue = { message({ tool("a", "get_selection") }, "tool_use"), message({ Json.object({ type = "text", text = "x" }) }, "end_turn") }
local nTools = 0
ok, text, info = AI.runAgent(plugin, { question = "x", tools = defs,
	isCancelled = function() return nTools > 0 end,
	runTool = function() nTools += 1; return "r" end })
check("s3c one request", #Http.sent == 1 and info.stopped == "cancelled")
Http.queue = {}

-- scenario 4: refusal, max_tokens, empty end after tools, HTTP errors, retries, network error, crash, no key
Http.sent = {}
Http.queue = { respond('{"model":"claude-opus-5-5","content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"},"usage":{"input_tokens":5,"output_tokens":0}}') }
ok, text, info = AI.runAgent(plugin, { question = "x", tools = defs })
check("s4 refusal", ok == false and has(text, "refuzat") and has(text, "cyber"), text)
check("s4 refusal info", info and info.iterations == 1)

Http.queue = { message({ Json.object({ type = "text", text = "partial" }) }, "max_tokens") }
ok, text = AI.runAgent(plugin, { question = "x", tools = defs })
check("s4 max_tokens", ok == true and has(text, "partial") and has(text, "limita de lungime"), text)

Http.queue = { message({ tool("a", "get_selection") }, "tool_use"), message({}, "end_turn") }
ok, text = AI.runAgent(plugin, { question = "x", tools = defs, runTool = function() return "r" end })
check("s4 empty end after tools", ok == true and text == "Gata.", text)

Http.queue = { message({}, "end_turn") }
ok, text = AI.runAgent(plugin, { question = "x", tools = defs })
check("s4 empty answer without tools", ok == false and has(text, "gol"), text)

Http.sent = {}
Http.queue = { message({ tool("a", "get_selection") }, "tool_use"),
	{ StatusCode = 400, Body = '{"type":"error","error":{"type":"invalid_request_error","message":"messages.1: thinking blocks cannot be modified"}}', Headers = {} } }
ok, text, info = AI.runAgent(plugin, { question = "x", tools = defs, runTool = function() return "r" end })
check("s4 http 400 mid-loop", ok == false and has(text, "(400)") and has(text, "thinking blocks"), text)
check("s4 partial usage kept", info and info.iterations == 2 and info.toolCalls == 1)
check("s4 lastError", AI.lastError == text)

Http.sent = {}
WAITS = {}
Http.queue = { { StatusCode = 529, Body = '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}', Headers = { ["retry-after"] = "2" } },
	message({ Json.object({ type = "text", text = "after retry" }) }, "end_turn") }
local statuses = {}
ok, text = AI.runAgent(plugin, { question = "x", tools = defs, onStatus = function(s) table.insert(statuses, s) end })
check("s4 529 retried once", ok == true and text == "after retry" and #Http.sent == 2 and WAITS[1] == 2, text)
check("s4 retry status", has(statuses[1], "reîncerc în 2 s"))
check("s4 retry same body", Http.sent[1].Body == Http.sent[2].Body)

Http.queue = { "HttpError: Timedout" }
ok, text = AI.runAgent(plugin, { question = "x", tools = defs })
check("s4 network error", ok == false and has(text, "prea mult"), text)

Http.queue = { respond("<html>bad gateway</html>") }
ok, text = AI.runAgent(plugin, { question = "x", tools = defs })
check("s4 garbage 200", ok == false and has(text, "neînțeles"), text)

Http.sent = {}
Http.queue = { message({ tool("a", "get_selection") }, "tool_use"), message({ Json.object({ type = "text", text = "ok" }) }, "end_turn") }
ok, text = AI.runAgent(plugin, { question = "x", tools = defs, runTool = function() error("kaboom") end })
local b = JSON.decode(Http.sent[2].Body)
check("s4 crash -> error result", ok == true and b.messages[3].content[1].is_error == true and has(b.messages[3].content[1].content, "kaboom"))

Http.sent = {}
Http.queue = { message({ tool("a", "get_selection") }, "tool_use"), message({ Json.object({ type = "text", text = "ok" }) }, "end_turn") }
ok, text = AI.runAgent(plugin, { question = "x", tools = defs, runTool = function() return "", false end })
b = JSON.decode(Http.sent[2].Body)
check("s4 empty result -> placeholder", b.messages[3].content[1].content == "(no output)")

-- haiku: no fallbacks, no beta header
Http.sent = {}
Http.queue = { message({ Json.object({ type = "text", text = "ok" }) }, "end_turn") }
ok = AI.runAgent(plugin, { question = "x", tools = defs, model = "claude-haiku-5-5", effort = "low" })
b = JSON.decode(Http.sent[1].Body)
check("s4 haiku", ok and b.fallbacks == nil and Http.sent[1].Headers["anthropic-beta"] == nil and b.output_config.effort == "low")

-- long history is cut from the front; the question stays last
local past = {}
for i = 1, 40 do table.insert(past, { role = i % 2 == 1 and "user" or "assistant", content = "m" .. i }) end
Http.sent = {}
Http.queue = { message({ Json.object({ type = "text", text = "ok" }) }, "end_turn") }
AI.runAgent(plugin, { question = "last", history = past, tools = defs })
b = JSON.decode(Http.sent[1].Body)
check("s4 history cut", b.messages[1].role == "user" and b.messages[#b.messages].content == "last" and #b.messages <= AI.MAX_HISTORY + 1,
	#b.messages)

ok, text = AI.runAgent(plugin, { question = "   ", tools = defs })
check("s4 empty question", ok == false)
AI.setKey(plugin, nil)
ok, text = AI.runAgent(plugin, { question = "x", tools = defs })
check("s4 no key", ok == false and has(text, "cheia API"))

-- settings
check("agent off by default", AI.getAgentMode(plugin) == false and AI.getAllowCode(plugin) == false)
AI.setAgentMode(plugin, true)
AI.setAllowCode(plugin, true)
check("agent settings saved", AI.getAgentMode(plugin) == true and AI.getAllowCode(plugin) == true)
check("describeInfo agent", has(AI.describeInfo({ model = "claude-opus-5-5", inputTokens = 1000, outputTokens = 10,
	iterations = 3, toolCalls = 4, seconds = 12 }), "3 pași · 4 unelte · 12 s"))
check("describeInfo plain unchanged", not has(AI.describeInfo({ model = "claude-opus-5-5", inputTokens = 1, outputTokens = 1 }), "pași"))

