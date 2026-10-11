-- LostCube - Roblox Studio plugin: game analysis, VFX editor with live preview, animations, modelling and Claude
-- (ReplicatedStorage.LostCube.Editor). Toolbar "LostCube" opens the panel.
local App = require(script.App)
local Theme = require(script.Theme)
local Icons = require(script.Icons)

-- the toolbar icon is Studio's own cube glyph (Icons.TOOLBAR), in the variant of the current Studio theme
local toolbar = plugin:CreateToolbar("LostCube")
local button = toolbar:CreateButton("LostCube", "Deschide LostCube: analiza jocului, efecte, animații, modelare, Claude",
	Icons.toolbar(), "LostCube")
button.ClickableWhenViewportHidden = true

local info = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 360, 760, 300, 360)
-- CreateDockWidgetPluginGuiAsync replaces the deprecated CreateDockWidgetPluginGui (both wait for Studio); the old call
-- stays as the fallback for a Studio that does not have the new one
local okAsync, created = pcall(function()
	return plugin:CreateDockWidgetPluginGuiAsync("LostCubeMain", info)
end)
local widget = okAsync and created or plugin:CreateDockWidgetPluginGui("LostCubeMain", info)
widget.Title = "LostCube"
widget.Name = "LostCube"
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local app

local function open()
	if app then
		return
	end
	app = App.mount(widget, { plugin = plugin })
end

button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

-- shortcuts for the VFX preview; a key is bound in Studio: File > Advanced > Customize Shortcuts > "LostCube"
local playAction = plugin:CreatePluginAction("LostCube_PlayEffect", "LostCube: redă efectul",
	"Redă efectul ales în tab-ul Efecte", Icons.toolbar(), true)
local stopAction = plugin:CreatePluginAction("LostCube_StopPreview", "LostCube: oprește previzualizarea",
	"Oprește și scoate previzualizarea din scenă", Icons.toolbar(), true)
playAction.Triggered:Connect(function()
	if app then
		app:panel("VFX"):play()
	end
end)
stopAction.Triggered:Connect(function()
	if app then
		app:panel("VFX"):stopPreview()
	end
end)

-- the toolbar icon follows the Studio theme (the window re-skins itself through Theme)
Theme.watch()
local themeConn = Theme.onChanged(function()
	pcall(function()
		button.Icon = Icons.toolbar()
	end)
end)

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	button:SetActive(widget.Enabled)
	if widget.Enabled then
		open()
	end
end)

if widget.Enabled then
	button:SetActive(true)
	open()
end

plugin.Unloading:Connect(function()
	themeConn:Disconnect()
	if app then
		app:destroy()
		app = nil
	end
	Theme.unwatch()
end)
