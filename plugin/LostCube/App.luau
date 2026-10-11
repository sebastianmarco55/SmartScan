-- LostCube window: a compact header, the tab bar, the current panel and the toasts; refreshes when effects change (also
-- when Claude edits) and re-skins when Studio changes theme.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = require(script.Parent.UI)
local Icons = require(script.Parent.Icons)
local Theme = require(script.Parent.Theme)
local C = UI.C

local App = {}
App.__index = App

-- key: saved in the plugin settings; label: short, shown in the tab bar; icon: Icons.GLYPHS; module: a panel module
-- next to App (a module that is not there yet shows a quiet "În lucru" state)
local TABS = {
	{ key = "Game", label = "Joc", icon = "game", module = "AnalysisPanel" },
	{ key = "VFX", label = "Efecte", icon = "effects", module = "VFXPanel" },
	{ key = "Anim", label = "Animații", icon = "animation", module = "AnimPanel" },
	{ key = "Library", label = "Bibliotecă", icon = "library", module = "LibraryPanel" },
	{ key = "Build", label = "Modelare", icon = "build", module = "BuildPanel" },
	{ key = "Claude", label = "Claude", icon = "chat", module = "ClaudePanel" },
}
App.TABS = TABS
local HEADER_H, TABS_H = Theme.HEIGHT.header, Theme.HEIGHT.tabs

local HELP = {
	"Trage de eticheta unui câmp numeric ca să schimbi valoarea; cu Shift pașii sunt fini.",
	"Ctrl + rotiță pe un câmp numeric: un pas (cu Shift, de 10 ori mai mult).",
	"Esc închide meniurile și dialogurile.",
	"Tastele pentru redare: File → Advanced → Customize Shortcuts, caută „LostCube”.",
}

function App.mount(container, ctx)
	ctx = ctx or {}
	ctx.Editor = ctx.Editor or require(script.Parent.Editor)
	local self = setmetatable({ ctx = ctx, tab = "VFX", conns = {}, panels = {} }, App)
	ctx.app = self
	-- remembered between Studio sessions: the open tab, the folded sections, the recent colours
	local savedTab = self:setting("tab")
	for _, t in TABS do
		if t.key == savedTab then
			self.tab = savedTab
		end
	end
	-- first time in this place: no analysis stored yet -> open on the game tab, which starts the analysis
	local okLoad, report = pcall(function()
		return require(script.Parent.Analyzer).load()
	end)
	if okLoad and report == nil then
		self.tab = "Game"
	end
	local folded = self:setting("collapsed")
	if type(folded) == "table" then
		for key, value in folded do
			if type(key) == "string" and type(value) == "boolean" then
				UI.collapsed[key] = value
			end
		end
	end
	UI.onCollapse = function()
		self:save("collapsed", UI.collapsed)
	end
	local recent = self:setting("recentColors")
	if type(recent) == "table" then
		table.clear(UI.recentColors)
		for _, hex in recent do
			if type(hex) == "string" and #UI.recentColors < 8 then
				table.insert(UI.recentColors, hex)
			end
		end
	end
	UI.onRecentColors = function(list)
		self:save("recentColors", list)
	end

	local root = UI.make("Frame", { Name = "LostCube", Parent = container, Size = UDim2.fromScale(1, 1), ClipsDescendants = true })
	UI.skin(root, { BackgroundColor3 = "bg" })
	self.root = root
	UI.setRoot(root)
	self:renderHeader()

	-- tabs (rebuilt only when the tab or the width class changes)
	self.tabBar = UI.make("Frame", { Name = "TabBar", Parent = root, Position = UDim2.fromOffset(0, HEADER_H),
		Size = UDim2.new(1, 0, 0, TABS_H), BackgroundTransparency = 1 })
	local line = UI.divider(root)
	line.Position = UDim2.fromOffset(0, HEADER_H + TABS_H)
	line.Size = UDim2.new(1, 0, 0, 1)

	-- content
	local top = HEADER_H + TABS_H + 1
	self.scroll = UI.make("ScrollingFrame", { Name = "Content", Parent = root, Position = UDim2.fromOffset(0, top),
		Size = UDim2.new(1, 0, 1, -top), BackgroundTransparency = 1, CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 6, ScrollingDirection = Enum.ScrollingDirection.Y,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar })
	UI.skin(self.scroll, { ScrollBarImageColor3 = "scrollbar" })
	self.content = UI.make("Frame", { Parent = self.scroll, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.pad(4, Theme.PAD, 24, Theme.PAD), UI.vlist(Theme.SPACE.sm) })

	-- a theme switch in Studio: chrome re-skins itself, the panels are drawn again with the new colours
	self.themeConn = Theme.onChanged(function()
		if not self.dead then
			self.barTab = nil
			self:render()
		end
	end)
	-- the tab bar shows fewer labels when the window gets narrow
	table.insert(self.conns, root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if not self.dead and UI.tabsMode(root.AbsoluteSize.X, TABS) ~= self.barMode then
			self:renderTabs()
		end
	end))
	self:watch()
	self:render()
	return self
end

-- the header: the LostCube mark, the name, the version; help and settings on the right
function App:renderHeader()
	local header = UI.make("Frame", { Name = "Header", Parent = self.root, Size = UDim2.new(1, 0, 0, HEADER_H),
		BackgroundTransparency = 1 })
	local brand = UI.make("Frame", { Name = "Brand", Parent = header, BackgroundTransparency = 1, Size = UDim2.new(1, -72, 1, 0) },
		{ UI.pad(0, 0, 0, Theme.PAD), UI.hlist(Theme.SPACE.sm, false) })
	local mark = Icons.draw(brand, "cube", 16, C.text, 1.25)
	for _, part in mark:GetChildren() do
		UI.skin(part, { BackgroundColor3 = "textBright" })
	end
	local name = UI.label(brand, "LostCube", { role = "emphasis", bold = true, color = "textBright", height = HEADER_H })
	name.Size = UDim2.fromOffset(0, HEADER_H)
	name.AutomaticSize = Enum.AutomaticSize.X
	local version = UI.label(brand, tostring(self.ctx.Editor.VERSION or ""), { role = "meta", dim = true, height = HEADER_H })
	version.Size = UDim2.fromOffset(0, HEADER_H)
	version.AutomaticSize = Enum.AutomaticSize.X
	local actions = UI.make("Frame", { Name = "Actions", Parent = header, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -Theme.SPACE.sm, 0, 0), Size = UDim2.new(0, 56, 1, 0) },
		{ UI.make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4),
			FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Center }) })
	local help
	help = UI.iconButton(actions, "help", function()
		self:showHelp(help)
	end, { tip = "Ajutor și scurtături" })
	local gear
	gear = UI.iconButton(actions, "gear", function()
		UI.menu(gear, {
			{ header = true, label = "LostCube " .. tostring(self.ctx.Editor.VERSION or "") },
			{ label = "Restrânge toate secțiunile", icon = "collapseAll", onClick = function()
				self:foldAll(true)
			end },
			{ label = "Extinde toate secțiunile", icon = "expandAll", onClick = function()
				self:foldAll(false)
			end },
		}, { width = 220 })
	end, { tip = "Setări" })
	return header
end

function App:showHelp(anchor)
	local frame = UI.popover(anchor, 280, 40 + #HELP * 44)
	local list = UI.make("Frame", { Parent = frame, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) },
		{ UI.pad(Theme.PAD, Theme.PAD, Theme.PAD, Theme.PAD), UI.vlist(Theme.SPACE.sm) })
	UI.label(list, "<uc>Scurtături</uc>", { role = "caps", dim = true, rich = true, height = 16 })
	for _, line in HELP do
		UI.label(list, line, { wrap = true })
	end
end

function App:foldAll(collapsed)
	for key in UI.collapsed do
		UI.collapsed[key] = collapsed
	end
	self:save("collapsed", UI.collapsed)
	self:render()
end

-- plugin settings (nothing is saved when the panels run outside a plugin, e.g. in a ScreenGui)
function App:setting(key)
	local plugin = self.ctx.plugin
	if not plugin then
		return nil
	end
	local ok, value = pcall(plugin.GetSetting, plugin, "LostCube." .. key)
	return ok and value or nil
end

function App:save(key, value)
	local plugin = self.ctx.plugin
	if plugin then
		pcall(plugin.SetSetting, plugin, "LostCube." .. key, value)
	end
end

-- a tab whose module is not in the plugin yet
local function placeholder(tab)
	return { render = function(_, parent)
		UI.empty(parent, "Apare într-o versiune următoare.", nil, nil, { icon = tab.icon, title = "În lucru" })
	end }
end

function App:panel(key)
	if not self.panels[key] then
		for _, t in TABS do
			if t.key == key then
				local source = script.Parent:FindFirstChild(t.module)
				self.panels[key] = source and require(source).new(self.ctx) or placeholder(t)
			end
		end
	end
	return self.panels[key]
end

-- the tab bar only changes when the tab (or the width class) does, not on every refresh
function App:renderTabs()
	local mode = UI.tabsMode(self.root.AbsoluteSize.X, TABS)
	if self.barTab == self.tab and self.barMode == mode then
		return
	end
	self.barTab, self.barMode = self.tab, mode
	for _, child in self.tabBar:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	UI.tabs(self.tabBar, TABS, self.tab, function(key)
		if self.tab ~= key then
			self.tab = key
			self:save("tab", key)
			self.scroll.CanvasPosition = Vector2.zero
			self:render()
		end
	end, { mode = mode })
end

function App:render()
	-- a redraw that was still waiting (for a text box, or for its turn) is not needed any more
	self.renderGen = (self.renderGen or 0) + 1
	self.pending, self.held = false, false
	local scrollY = self.scroll.CanvasPosition.Y
	self:renderTabs()
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
		UI.note(self.content, "Panoul nu s-a putut afișa: " .. UI.escape(tostring(err)), C.danger)
		warn("LostCube:", err)
	end
	task.defer(function()
		if self.scroll.Parent then
			self.scroll.CanvasPosition = Vector2.new(0, scrollY)
		end
	end)
end

-- the text box of the current tab that the user is typing in, if any
function App:typingBox()
	for _, d in self.content:GetDescendants() do
		if d.ClassName == "TextBox" and d:IsFocused() then
			return d
		end
	end
	return nil
end

-- coalesces many changes into one redraw
function App:refresh()
	if self.pending or self.dead then
		return
	end
	self.pending = true
	local gen = self.renderGen
	task.defer(function()
		self:flush(gen)
	end)
end

-- A redraw rebuilds every text box, so it would wipe what the user is typing and take the focus away: it waits until
-- the box is let go, plus one more beat (a click on a button took the focus; the button must still be there to be clicked).
-- It also waits while a drag, a menu, the colour picker or a dialog is open (UI.busy).
function App:flush(gen)
	if self.dead or gen ~= self.renderGen then
		return
	end
	if self:typingBox() or UI.busy() then
		self.held = true
	elseif self.held then
		self.held = false
	else
		self.pending = false
		if self.root.Parent then
			self:render()
		end
		return
	end
	task.delay(0.3, function()
		self:flush(gen)
	end)
end

-- redraw when effects change from anywhere (other windows, Claude, undo)
function App:watch()
	local function hook()
		if self.dead then
			return
		end
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
				-- the folder is recreated now and then: keep exactly one connection (to the live one)
				if self.logConn then
					self.logConn:Disconnect()
				end
				self.logConn = folder:GetAttributeChangedSignal("Log"):Connect(function()
					if self.tab == "Claude" then
						self:refresh()
					end
				end)
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
	self.dead = true -- no more redraws, no more re-hooking
	UI.onCollapse = nil
	UI.onRecentColors = nil
	UI.closePopup()
	UI.release()
	if self.themeConn then
		self.themeConn:Disconnect()
		self.themeConn = nil
	end
	for _, c in self.conns do
		c:Disconnect()
	end
	if self.logConn then
		self.logConn:Disconnect()
		self.logConn = nil
	end
	for _, c in self.watchConns or {} do
		c:Disconnect()
	end
	self.watchConns = nil
	for _, p in self.panels do
		if p.destroy then
			-- one panel failing to clean up must not leave the others running (Heartbeat loops, tasks)
			local ok, err = pcall(p.destroy, p)
			if not ok then
				warn("LostCube:", err)
			end
		end
	end
	self.root:Destroy()
end

return App
