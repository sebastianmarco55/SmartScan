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
local panel = scene.app:panel("Claude")
if ARGS.state ~= "empty" then
	local AI = scene.tree.load("AI")
	AI.setKey(scene.plugin, "sk-ant-api03-Qx83kLm0aPzVn21RtYh7uJcWdE4sBf9gXyZ5qNoMiK6TlA")
	panel.messages = {
		{ role = "user", content = "Ce efecte VFX i se potrivesc jocului?" },
		{ role = "assistant", info = { model = "claude-opus-5-5", inputTokens = 4210, outputTokens = 611, cacheRead = 3900 },
			content = "## Efecte potrivite\nPaleta hărții e **rece** (violet / albastru) și are multe elemente neon, deci merg:\n\n"
				.. "1. **Lovitură**: `HIT_SPARK` + `FLASH` — culoare `#9B5CFF`\n2. **Aterizare**: `LAND_DUST` și un `SHAKE_LIGHT`\n"
				.. "3. **Teleport**: cerc magic + ridicare de scântei\n\n```lua\nlocal Editor = require(game.ReplicatedStorage.LostCube.Editor)\n"
				.. "Editor.newFromTemplate(\"Lovitură\", \"PUNCH\", { color = Color3.fromRGB(155, 92, 255) })\n```\n\n"
				.. "| Efect | Preset |\n|---|---|\n| Lovitură | PUNCH |\n| Aterizare | LANDING |\n\n> Începe cu lovitura: se vede cel mai des." },
		{ role = "user", content = "Fă-mi lovitura și arat-o." },
		{ role = "assistant", agent = true, content = "Gata, efectul **Lovitură** e în tab-ul ✨ VFX. Îl pornești din cod cu `VFX.play(...)`.",
			info = { model = "claude-opus-5-5", inputTokens = 5120, outputTokens = 840 },
			steps = {
				{ kind = "text", text = "Mă uit întâi ce efecte există deja." },
				{ kind = "tool", id = "t1", name = "list_effects", input = {}, status = "done", result = "Explozie de foc (1.3 s, GROUND): Flash, Cameră\nVindecare (1 s)" },
				{ kind = "tool", id = "t2", name = "create_effect", input = { name = "Lovitură", template = "PUNCH" }, status = "pending" },
			} },
	}
end
return scene
