-- Claude tab: the real ClaudePanel + AI + Markdown with an API key stored, a short conversation (a Markdown answer and an agent
-- turn with tool cards, one waiting for approval) and the activity log.
local LC, P, ARGS, common = ...
local S = LC.run("tests/preview/scenes/game.luau", nil, LC, P, ARGS, common)

local scene
local mounted = false
local editor = common.fakeEditor({
	history = function()
		if ARGS.state == "empty" then return {} end
		return {
			{ t = "14:02:11", a = "efect nou Explozie de foc" }, { t = "14:02:40", a = "adăugat Flash în Explozie de foc" },
			{ t = "14:03:05", a = "modificat Flash" }, { t = "14:05:52", a = "animație generată: ServerStorage.RBX_ANIMSAVES.Lovitură" },
		}
	end,
	describe = function()
		if ARGS.state == "empty" then return {} end
		return { { name = "Explozie de foc", duration = 1.3, attach = "GROUND", elements = { { name = "Flash", kind = "PARTICLES", preset = "FLASH" },
			{ name = "Cameră", kind = "CAMERA" } } } }
	end,
})
scene = S.scene{
	editor = editor,
	mocks = {
		Installer = { status = function() return { version = editor.VERSION, editor = editor.VERSION, vfx = "2.0.0", ok = false } end, install = function() end },
		-- (App.mount opens the Game tab when there is no report: the "no report" state of an empty place is shown after the mount)
		Analyzer = { load = function() return (ARGS.state ~= "empty" or not mounted) and { version = 1 } or nil end,
			context = function() return "## Joc" end },
	},
}
mounted = true
-- preview-only states, asked for with pseudo section keys: --open preview.empty (a key, no conversation yet),
-- --open preview.code (the agent waits for approval of Luau code), --open preview.done (the agent turn finished),
-- --open preview.allowcode ("Cod fără confirmare" on)
local function wants(key)
	return table.find(ARGS.open or {}, key) ~= nil
end
local panel = scene.app:panel("Claude")
if ARGS.state ~= "empty" then
	local AI = scene.tree.load("AI")
	AI.setKey(scene.plugin, "sk-ant-api03-Qx83kLm0aPzVn21RtYh7uJcWdE4sBf9gXyZ5qNoMiK6TlA")
	if wants("preview.empty") then
		return scene
	end
	AI.setAgentMode(scene.plugin, true)
	if wants("preview.allowcode") then
		AI.setAllowCode(scene.plugin, true)
	end
	local pending = { kind = "tool", id = "t3", name = "create_effect_from_template",
		input = { name = "Lovitură", template = "PUNCH", color = "#9B5CFF" }, status = "pending" }
	if wants("preview.code") then
		pending = { kind = "tool", id = "t3", name = "run_luau", status = "pending", input = { summary = "Leagă efectul Lovitură de markerul Hit al animației de atac.",
			code = "local VFX = require(game.ReplicatedStorage.LostCube.VFX)\nlocal track = humanoid:LoadAnimation(attack)\n"
				.. "VFX.bindMarkers(track, character, { Hit = \"Lovitură\" })\ntrack:Play()" } }
	end
	local done = wants("preview.done")
	if done then
		pending.status, pending.result = "done", "Am creat efectul Lovitură din șablonul PUNCH (5 elemente)."
	end
	local turn = { role = "assistant", agent = true, running = not done, question = "Fă-mi lovitura și arat-o.",
		content = done and "Gata: efectul **Lovitură** e în tab-ul Efecte. Îl pornești din cod cu `VFX.play(\"Lovitură\", character)`." or nil,
		info = done and { model = "claude-opus-5-5", inputTokens = 5120, outputTokens = 840, cachedTokens = 4600, iterations = 3, toolCalls = 3, seconds = 21 } or nil,
		steps = {
			{ kind = "text", text = "Mă uit întâi ce efecte există deja și ce am selectat." },
			{ kind = "tool", id = "t1", name = "list_effects", input = {}, status = "done", result = "Explozie de foc (1.3 s, GROUND): Flash, Cameră\nVindecare (1 s)" },
			{ kind = "tool", id = "t2", name = "suggest_effect_colors", input = {}, status = "done", result = "#9B5CFF, #FFB13D, #3DE0FF" },
			{ kind = "text", text = "Nu există un efect de lovitură. Creez **Lovitură** din șablonul `PUNCH`, în violetul hărții (`#9B5CFF`)." },
			pending,
		} }
	panel.messages = {
		{ role = "user", content = "Ce efecte VFX i se potrivesc jocului?" },
		{ role = "assistant", info = { model = "claude-opus-5-5", inputTokens = 4210, outputTokens = 611, cachedTokens = 3900, seconds = 9 },
			content = "## Efecte potrivite\nPaleta hărții e **rece** (violet / albastru) și are multe elemente neon, deci merg:\n\n"
				.. "1. **Lovitură**: `HIT_SPARK` + `FLASH`, culoare `#9B5CFF`\n2. **Aterizare**: `LAND_DUST` și un `SHAKE_LIGHT`\n"
				.. "3. **Teleport**: cerc magic + ridicare de scântei\n   - durată scurtă, sub 0.6 s\n\n### Codul pentru lovitură\n```lua\nlocal Editor = require(game.ReplicatedStorage.LostCube.Editor)\n"
				.. "Editor.newFromTemplate(\"Lovitură\", \"PUNCH\", { color = Color3.fromRGB(155, 92, 255) })\n```\n\n"
				.. "| Efect | Preset | Atașat |\n|---|---|---|\n| Lovitură | PUNCH | RIGHT_HAND |\n| Aterizare | LANDING | GROUND |\n\n"
				.. "- [x] paleta hărții citită\n- [ ] efectele legate de animații\n\n> Începe cu lovitura: se vede cel mai des." },
		{ role = "user", content = "Fă-mi lovitura și arat-o." },
		turn,
	}
	if not done then
		panel.busy = true
		panel.gen += 1
		panel.run = { gen = panel.gen, turn = turn, cancelled = false, iteration = 3,
			info = { inputTokens = 5120, outputTokens = 412 } }
		panel.startedAt = os.time() - 14
		panel.waitText = "așteaptă aprobarea ta"
	end
end
return scene
