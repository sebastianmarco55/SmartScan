-- App (the window): redraws are coalesced and wait while the user types in a text box, the tab bar survives a redraw,
-- exactly one Log connection even when the session folder is recreated, destroy disconnects everything and a panel that
-- fails to clean up does not stop the others. UI and App are real; the five panels and the Editor are fakes.
local LC = ...
local T = LC.kit.new("app")
local function check(cond, what)
	T.check(cond, what)
end

local M = LC.run("tests/mocks/datamodel.luau")
M.enableGui()
local new, service, methods, Instance, task = M.new, M.service, M.methods, M.Instance, M.task
local SignalMT, InstMT, ChangeHistoryService = M.gui.SignalMT, M.gui.InstMT, M.ChangeHistoryService
service("UserInputService")
service("Selection")
service("RunService")
service("ScriptEditorService")

local mocks = {}
local tree = LC.modtree.new{ env = LC.env(M.globals()), mocks = mocks }
local UIModule = tree.load("UI")

-- a scheduler we control
local clock, queue = 0, {}
task.delay = function(t, f, ...)
	table.insert(queue, { at = clock + t, f = f, args = { ... } })
end
task.defer = function(f, ...)
	table.insert(queue, { at = clock, f = f, args = { ... } })
end
local function advance(dt)
	clock += dt
	local progressed = true
	while progressed do
		progressed = false
		for i, entry in queue do
			if entry.at <= clock then
				table.remove(queue, i)
				entry.f(table.unpack(entry.args))
				progressed = true
				break
			end
		end
	end
end

-- signals with connections we can count
local allSignals = {}
function SignalMT.Connect(sig, fn)
	local conn = { fn = fn, connected = true }
	function conn.Disconnect(c)
		c.connected = false
	end
	table.insert(sig.handlers, conn)
	return conn
end
function SignalMT.Fire(sig, ...)
	for _, conn in table.clone(sig.handlers) do
		if conn.connected then
			conn.fn(...)
		end
	end
end
local oldNewSignal = methods.GetPropertyChangedSignal
methods.GetAttributeChangedSignal = function(o, name)
	local data = rawget(o, "_data")
	data._signals = data._signals or {}
	local key = "Attr:" .. name
	if not data._signals[key] then
		data._signals[key] = setmetatable({ handlers = {}, name = key }, SignalMT)
		table.insert(allSignals, data._signals[key])
	end
	return data._signals[key]
end
local function live(filter)
	local n = 0
	for _, sig in allSignals do
		if not filter or sig.name == filter then
			for _, conn in sig.handlers do
				if conn.connected then n += 1 end
			end
		end
	end
	return n
end
-- every signal of the services and instances that App touches also counts
local function track(inst)
	local data = rawget(inst, "_data")
	data.lenient = true
	data.tracked = true
	return inst
end
local RS = track(service("ReplicatedStorage"))
local SS = track(service("ServerStorage"))
track(ChangeHistoryService)
-- count connections made on lenient members too
local rawIndexLenient = InstMT.__index
InstMT.__index = function(o, k)
	local v = rawIndexLenient(o, k)
	if getmetatable(v) == SignalMT and not v.tracked and rawget(o, "_data").tracked then
		v.tracked = true
		table.insert(allSignals, v)
	end
	return v
end

-- modules
local UIM = UIModule
local renders = 0
local destroyed = 0
local panelBox
local function mockPanel(name, failDestroy)
	return { new = function(ctx)
		local self = { name = name }
		function self:render(parent)
			renders += 1
			self.renderCount = (self.renderCount or 0) + 1
			panelBox = UIM.textbox(parent, "", nil, { placeholder = name })
			UIM.button(parent, "button " .. name, function() self.clicked = true end)
		end
		function self:destroy()
			destroyed += 1
			if failDestroy then
				error("boom")
			end
		end
		return self
	end }
end
mocks.Editor = { VERSION = "9.9.9" }
mocks.Analyzer = { load = function() return { version = 1 } end }
mocks.AnalysisPanel = mockPanel("Game", true) -- its destroy fails
mocks.VFXPanel = mockPanel("VFX")
mocks.AnimPanel = mockPanel("Anim")
mocks.LibraryPanel = mockPanel("Library")
mocks.ClaudePanel = mockPanel("Claude")
local App = tree.load("App")

-- 1. mount, tab bar kept across refreshes
local container = Instance.new("Frame")
local plugin = new("Plugin", "Plugin")
local app = App.mount(container, { plugin = plugin, Editor = { VERSION = "9.9.9" } })
advance(0)
check(app.tab == "VFX" or app.tab == "Game", "mounted on a tab: " .. app.tab)
app.tab = "VFX"
app:render()
renders = 0
local bar = app.tabBar:GetChildren()
local firstButton
for _, c in bar do
	if c:IsA("GuiObject") then
		firstButton = c
		break
	end
end
app:refresh()
app:refresh()
app:refresh()
advance(0)
check(renders == 1, "three refreshes = one redraw: " .. renders)
local stillThere = false
for _, c in app.tabBar:GetChildren() do
	if c == firstButton then stillThere = true end
end
check(stillThere, "tab bar buttons are kept across redraws")
-- tab switch rebuilds it
app.tab = "Anim"
app:render()
local rebuilt = true
for _, c in app.tabBar:GetChildren() do
	if c == firstButton then rebuilt = false end
end
check(rebuilt, "tab bar rebuilt when the tab changed")
app.tab = "VFX"
app:render()

-- 2. log connection: exactly one, also when the session folder is recreated
local logsBefore = live("Attr:Log")
check(logsBefore == 0, "no session folder yet: no log connection")
local function newSession()
	local f = new("Folder", "LostCubeSession")
	f.Parent = SS
	-- the ChildAdded handlers of ServerStorage
	rawget(SS, "_data")._signals.ChildAdded:Fire(f)
	return f
end
local s1 = newSession()
check(live("Attr:Log") == 1, "one log connection: " .. live("Attr:Log"))
local s2, s3
for i = 1, 4 do
	s1:Destroy()
	s1 = newSession()
end
check(live("Attr:Log") == 1, "still one after the folder was recreated 4 times: " .. live("Attr:Log"))
-- the log change on the Claude tab redraws; on another tab it does not
app.tab = "Claude"
app:render()
renders = 0
rawget(s1, "_data")._signals["Attr:Log"]:Fire()
advance(0)
check(renders == 1, "log change redraws the Claude tab")
app.tab = "VFX"
app:render()
renders = 0
rawget(s1, "_data")._signals["Attr:Log"]:Fire()
advance(0)
check(renders == 0, "log change is ignored on other tabs")

-- 3. typing: the redraw waits for the text box
app:render()
renders = 0
local box = panelBox
box:CaptureFocus()
box.Text = "typed marker"
app:refresh()
advance(0)
advance(0.35)
advance(0.35)
check(renders == 0, "no redraw while the user types: " .. renders)
check(box.Parent ~= nil and box.Text == "typed marker", "the text box (and its text) is still there")
app:refresh()
advance(0)
check(renders == 0, "more refreshes are coalesced while waiting")
rawget(box, "_data").focused = false -- the user clicked a button: focus lost
advance(0.1)
check(renders == 0, "not at once: the click must land first")
advance(0.35)
check(renders == 0, "one more beat")
advance(0.35)
check(renders == 1, "redrawn after the box was let go: " .. renders)
-- a tab switch while a redraw waits: one redraw only
local box2 = panelBox
box2:CaptureFocus()
renders = 0
app:refresh()
advance(0)
advance(0.35)
app.tab = "Library"
app:render()
check(renders == 1, "tab switch redraws at once")
advance(1)
advance(1)
check(renders == 1, "the waiting redraw was cancelled: " .. renders)
-- refresh works again afterwards
app:refresh()
advance(0)
check(renders == 2, "refresh works after a cancelled wait: " .. renders)

-- 4. destroy: nothing stays connected, a panel failing to clean up does not stop the others
app.tab = "VFX"
app:render()
app:panel("Game") -- built: its destroy errors
app:panel("Anim")
-- a hook() that was deferred before destroy must not reconnect afterwards
local effects = track(new("Folder", "LostCube"))
effects.Parent = RS
rawget(RS, "_data")._signals.ChildAdded:Fire(effects)
advance(0)
local root = RS:FindFirstChild("LostCube")
local added = new("Folder", "Effects")
added.Parent = root
rawget(root, "_data")._signals.DescendantAdded:Fire(added) -- defers hook()
destroyed = 0
local rendersBefore = renders
app:destroy()
advance(0)
advance(1)
check(live() == 0, "no connection alive after destroy: " .. live())
check(destroyed >= 3, "every panel was destroyed (one of them failed): " .. destroyed)
check(app.root.Parent == nil, "root removed")
app:refresh()
advance(1)
check(renders == rendersBefore, "no redraw after destroy")
T.finish()
