-- LostCube - Roblox Studio plugin: VFX editor with live preview, animation preview + Moon-style easing,
-- and the same tools for Claude (ReplicatedStorage.LostCube.Editor). Toolbar "LostCube" opens the panel.
local App = require(script.App)

local toolbar = plugin:CreateToolbar("LostCube")
local button = toolbar:CreateButton("LostCube", "LostCube: VFX + animații (și Claude)", "rbxasset://textures/sparkle.png")
button.ClickableWhenViewportHidden = true

local info = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 360, 760, 300, 360)
local widget = plugin:CreateDockWidgetPluginGui("LostCubeMain", info)
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
	if app then
		app:destroy()
		app = nil
	end
end)
