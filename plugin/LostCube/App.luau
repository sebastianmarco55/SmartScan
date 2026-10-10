-- LostCube window: header, tabs, the current panel; refreshes when effects change (also when Claude edits).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = require(script.Parent.UI)
local C = UI.C

local App = {}
App.__index = App

local TABS = {
	{ key = "VFX", label = "✨ VFX", module = "VFXPanel" },
	{ key = "Anim", label = "🎬 Animații", module = "AnimPanel" },
	{ key = "Claude", label = "◆  Claude", module = "ClaudePanel" },
}

function App.mount(container, ctx)
	ctx = ctx or {}
	ctx.Editor = ctx.Editor or require(script.Parent.Editor)
	local self = setmetatable({ ctx = ctx, tab = "VFX", conns = {}, panels = {} }, App)
	ctx.app = self

	local root = UI.make("Frame", { Name = "LostCube", Parent = container, Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.bg,
		ClipsDescendants = true })
	self.root = root

	-- header
	local header = UI.make("Frame", { Parent = root, Size = UDim2.new(1, 0, 0, 42), BackgroundColor3 = C.section },
		{ UI.pad(0, 12, 0, 12) })
	UI.make("TextLabel", { Parent = header, Text = "◆", Font = UI.FONT_BOLD, TextSize = 20, TextColor3 = C.accent,
		BackgroundTransparency = 1, Size = UDim2.new(0, 20, 1, 0) })
	UI.make("TextLabel", { Parent = header, Text = "LostCube", Font = UI.FONT_BOLD, TextSize = 17, TextColor3 = C.text,
		BackgroundTransparency = 1, Position = UDim2.fromOffset(26, 0), Size = UDim2.new(0, 120, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left })
	UI.make("TextLabel", { Parent = header, Text = "v" .. ctx.Editor.VERSION .. "  ·  Roblox VFX + animații", Font = UI.FONT,
		TextSize = 11, TextColor3 = C.dim, BackgroundTransparency = 1, Position = UDim2.new(0, 112, 0, 0),
		Size = UDim2.new(1, -112, 1, 0), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })

	-- tabs
	self.tabBar = UI.make("Frame", { Parent = root, Position = UDim2.fromOffset(0, 42), Size = UDim2.new(1, 0, 0, 34),
		BackgroundColor3 = C.section }, { UI.pad(4, 8, 6, 8), UI.hlist(4, true) })

	-- content
	self.scroll = UI.make("ScrollingFrame", { Parent = root, Position = UDim2.fromOffset(0, 76), Size = UDim2.new(1, 0, 1, -76),
		BackgroundTransparency = 1, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 6,
		ScrollBarImageColor3 = C.hover, ScrollingDirection = Enum.ScrollingDirection.Y, VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar })
	self.content = UI.make("Frame", { Parent = self.scroll, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.pad(8, 8, 16, 8), UI.vlist(8) })

	UI.setRoot(root)
	self:watch()
	self:render()
	return self
end

function App:panel(key)
	if not self.panels[key] then
		for _, t in TABS do
			if t.key == key then
				self.panels[key] = require(script.Parent[t.module]).new(self.ctx)
			end
		end
	end
	return self.panels[key]
end

function App:render()
	local scrollY = self.scroll.CanvasPosition.Y
	for _, child in self.tabBar:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	for _, t in TABS do
		UI.button(self.tabBar, t.label, function()
			if self.tab ~= t.key then
				self.tab = t.key
				self.scroll.CanvasPosition = Vector2.zero
				self:render()
			end
		end, { selected = self.tab == t.key, height = 24, bold = self.tab == t.key })
	end
	for _, child in self.content:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	UI.closePopup()
	local ok, err = pcall(function()
		self:panel(self.tab):render(self.content)
	end)
	if not ok then
		UI.note(self.content, "⚠ Eroare în panou: " .. tostring(err), C.danger)
		warn("LostCube:", err)
	end
	task.defer(function()
		if self.scroll.Parent then
			self.scroll.CanvasPosition = Vector2.new(0, scrollY)
		end
	end)
end

-- coalesces many changes into one redraw
function App:refresh()
	if self.pending then
		return
	end
	self.pending = true
	task.defer(function()
		self.pending = false
		if self.root.Parent then
			self:render()
		end
	end)
end

-- redraw when effects change from anywhere (other windows, Claude, undo)
function App:watch()
	local function hook()
		for _, c in self.watchConns or {} do
			c:Disconnect()
		end
		self.watchConns = {}
		local conns = self.watchConns
		local root = ReplicatedStorage:FindFirstChild("LostCube")
		table.insert(conns, ReplicatedStorage.ChildAdded:Connect(function(child)
			if child.Name == "LostCube" then
				task.defer(hook)
			end
		end))
		if not root then
			return
		end
		table.insert(conns, root.DescendantAdded:Connect(function(d)
			if d.Name == "Effects" then
				task.defer(hook)
			end
			self:refresh()
		end))
		table.insert(conns, root.DescendantRemoving:Connect(function()
			self:refresh()
		end))
		local effects = root:FindFirstChild("Effects")
		if effects then
			table.insert(conns, effects:GetAttributeChangedSignal("LC_Rev"):Connect(function()
				self:refresh()
			end))
		end
	end
	hook()
	-- the activity log (Claude tab) lives in ServerStorage.LostCubeSession, created on the first edit
	local ok, storage = pcall(function()
		return game:GetService("ServerStorage")
	end)
	if ok then
		local function hookLog(folder)
			if folder.Name == "LostCubeSession" then
				table.insert(self.conns, folder:GetAttributeChangedSignal("Log"):Connect(function()
					if self.tab == "Claude" then
						self:refresh()
					end
				end))
			end
		end
		local existing = storage:FindFirstChild("LostCubeSession")
		if existing then
			hookLog(existing)
		end
		table.insert(self.conns, storage.ChildAdded:Connect(hookLog))
	end
	table.insert(self.conns, game:GetService("ChangeHistoryService").OnUndo:Connect(function()
		self:refresh()
	end))
	table.insert(self.conns, game:GetService("ChangeHistoryService").OnRedo:Connect(function()
		self:refresh()
	end))
end

function App:destroy()
	for _, c in self.conns do
		c:Disconnect()
	end
	for _, c in self.watchConns or {} do
		c:Disconnect()
	end
	for _, p in self.panels do
		if p.destroy then
			p:destroy()
		end
	end
	self.root:Destroy()
end

return App
