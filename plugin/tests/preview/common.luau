-- Shared by the scenes: the plugin mock (settings), mounting the real App, driving it, small helpers.
local LC, P, ARGS = ...
local M = {}

function M.plugin(store)
	local plugin = { store = store }
	function plugin:GetSetting(key)
		return store[key]
	end
	function plugin:SetSetting(key, value)
		store[key] = value
	end
	return plugin
end

-- A small stand-in for the Editor module on the scenes that run on the DataModel mock (the real one needs the typed mock of
-- the VFX scene). Only what the panels read: the version, the effects / log / history views.
function M.fakeEditor(extra)
	local version = string.match(LC.files["LostCube/Editor/init.luau"] or "", 'Editor%.VERSION = "([^"]+)"') or "?"
	local editor = { VERSION = version, PRESETS = {}, TEMPLATES = {}, effects = function() return {} end,
		elements = function() return {} end, history = function() return {} end, describe = function() return {} end,
		log = function() end, folder = function() return nil end }
	for k, v in extra or {} do
		editor[k] = v
	end
	return editor
end

-- the real App in a new widget. `scene.tree` is a modtree (env already has the GUI layer installed), `scene.Editor`
-- the Editor module for ctx (App loads the real one otherwise), `scene.settings` initial plugin settings.
function M.mount(scene)
	local tree = scene.tree
	local UI = tree.load("UI")
	local App = tree.load("App")
	local root = P.newRoot(ARGS.width, ARGS.height)
	local store = scene.settings or {}
	local folded = {}
	for _, key in ARGS.open or {} do
		folded[key] = false
	end
	for _, key in ARGS.close or {} do
		folded[key] = true
	end
	store["LostCube.tab"] = ARGS.tab
	store["LostCube.collapsed"] = folded
	local plugin = M.plugin(store)
	local ctx = { plugin = plugin, Editor = scene.Editor }
	scene.ctx = ctx
	local app = App.mount(root, ctx)
	P.drain()
	scene.root, scene.app, scene.UI, scene.plugin = root, app, UI, plugin
	return scene
end

-- shows the wanted tab and applies --open / --close / --click
function M.drive(scene)
	local app, UI, root = scene.app, scene.UI, scene.root
	if app.tab ~= ARGS.tab then
		app.tab = ARGS.tab
		if app.save then
			app:save("tab", ARGS.tab)
		end
	end
	if type(UI.collapsed) == "table" then
		for _, key in ARGS.open or {} do
			UI.collapsed[key] = false
		end
		for _, key in ARGS.close or {} do
			UI.collapsed[key] = true
		end
	end
	app:render()
	P.drain()
	P.fireLayoutSignals(root)
	if scene.afterRender then
		scene.afterRender()
		P.drain()
	end
	for _, text in ARGS.hover or {} do
		local button = P.hover(root, text)
		if not button then
			table.insert(P.errors, "--hover: no button shows " .. string.format("%q", text))
		end
	end
	for _, text in ARGS.click or {} do
		local button = P.click(root, text)
		if not button then
			table.insert(P.errors, "--click: no button shows " .. string.format("%q", text))
		end
		P.drain()
	end
	P.drain()
	P.fireLayoutSignals(root)
end

return M
