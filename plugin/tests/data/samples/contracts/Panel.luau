-- sample consumer for the contracts self-test: two wrong references (lines 7 and 9), the rest is fine
local UI = require(script.Parent.UI)
local C = UI.C
local Panel = {}
function Panel.render(parent)
	UI.button(parent, "ok")
	UI.buton(parent, "typo")
	UI.label(parent, "ok", C.text)
	local bad = C.dangr
	return C.accent, bad
end
return Panel
