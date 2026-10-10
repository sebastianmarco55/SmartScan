-- LostCube > Claude tab: what Claude (or you) did with LostCube, and the modules it needs in the game.
local UI = require(script.Parent.UI)
local Installer = require(script.Parent.Installer)
local C = UI.C

local Panel = {}
Panel.__index = Panel

local EXAMPLES = {
	"„fă-mi un efect de foc pe mână când lovește”",
	"„pune easing Bounce pe aterizare”",
	"„fă scânteile mai mari și mai albastre”",
	"„un cerc magic sub personaj la teleport”",
}

function Panel.new(ctx)
	return setmetatable({ ctx = ctx, Editor = ctx.Editor }, Panel)
end

function Panel:render(parent)
	local body = UI.section(parent, "Claude lucrează cu LostCube", { key = "claude.about" })
	UI.label(body, "Claude are acces direct la Studio și folosește aceleași funcții ca panourile LostCube "
		.. "(modulul ReplicatedStorage.LostCube.Editor). Spune-i în chat ce vrei, de exemplu:", { wrap = true, size = 12 })
	for _, e in EXAMPLES do
		UI.label(body, "•  " .. e, { dim = true, size = 12, wrap = true })
	end
	UI.note(body, "Fiecare pas e un singur <b>Ctrl+Z</b>. Efectele apar în tab-ul VFX imediat ce Claude le face.")

	local status = Installer.status()
	body = UI.section(parent, "Module în joc", { key = "claude.modules" })
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

	local history = self.Editor.history()
	body = UI.section(parent, "Ce s-a făcut  (" .. #history .. ")", { key = "claude.log" })
	if #history == 0 then
		UI.label(body, "Nimic încă în sesiunea asta.", { dim = true, size = 12 })
	end
	for i = #history, math.max(1, #history - 24), -1 do
		local h = history[i]
		UI.label(body, h.t .. "   " .. h.a, { size = 12, color = i == #history and C.text or C.dim })
	end
end

function Panel:destroy() end

return Panel
