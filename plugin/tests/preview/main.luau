-- Entry of the GUI preview (a "suite" for tests/lib/boot.luau, written into the generated file by render.py): builds the
-- scene of one tab on a mock place, mounts the REAL App, drives it (tab, sections, clicks) and prints the GUI tree as JSON.
--   tests/preview/args.luau   (generated)  the CLI options + the browser's measurements of the previous pass
local LC = ...
local ARGS = LC.run("tests/preview/args.luau")
local P = LC.run("tests/preview/gui.luau", nil, LC, ARGS)
local common = LC.run("tests/preview/common.luau", nil, LC, P, ARGS)

local SCENES = { VFX = "vfx", Anim = "anim", Library = "library", Game = "game", Build = "build", Claude = "claude",
	Selftest = "selftest" }
local file = SCENES[ARGS.tab]
assert(file, "unknown tab " .. tostring(ARGS.tab))
local scene = LC.run("tests/preview/scenes/" .. file .. ".luau", nil, LC, P, ARGS, common)

if not scene.noDrive then
	common.drive(scene)
end

-- the sections the panels drew (UI.collapsed: key -> folded), for --open / --close
local extra
if scene.UI and type(scene.UI.collapsed) == "table" then
	local keys = {}
	for k in scene.UI.collapsed do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts = {}
	for _, k in keys do
		table.insert(parts, P.jsonString(tostring(k)) .. ":" .. tostring(scene.UI.collapsed[k] == true))
	end
	extra = '"sections":{' .. table.concat(parts, ",") .. "}"
end
print("PREVIEW-JSON-BEGIN")
print(P.dump(scene.root, extra))
print("PREVIEW-JSON-END")
