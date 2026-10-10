-- Shared setup of the panel suites that need the DataModel mock with GUI (anim_panel, library_panel_ui): a task scheduler
-- we control (advance), signals whose live connections can be counted, the services the panels touch, CFrame, ChangeHistory
-- recordings, the Humanoid-from-description / animation / marker methods, a real UI module. It is joined with the body of
-- the suite into one chunk (LC.loadJoined), so the body sees these locals.
local LC, T, M = ...
local function check(cond, what)
	T.check(cond, what)
end
M.enableGui()
local new, service, methods, Instance, V3, Enum = M.new, M.service, M.methods, M.Instance, M.V3, M.Enum
local task, workspace, game = M.task, M.workspace, M.game
local SignalMT, InstMT, ChangeHistoryService = M.gui.SignalMT, M.gui.InstMT, M.ChangeHistoryService
local drain = M.gui.drain
service("UserInputService")
local env = LC.env(M.globals())
local mocks = {}
local tree = LC.modtree.new{ env = env, mocks = mocks }
local UIModule = tree.load("UI")

-- scheduler + signals we can count --------------------------------------------------------------
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
local function liveOn(sig)
	local n = 0
	for _, conn in sig.handlers do
		if conn.connected then n += 1 end
	end
	return n
end

-- datatypes the panel needs
local CFrameMT = { __type = "CFrame" }
CFrameMT.__mul = function(a, b)
	return a
end
env.CFrame = { new = function()
	return setmetatable({}, CFrameMT)
end }
local ChangeHistoryServiceInst = ChangeHistoryService

-- services
local RunService = service("RunService", { lenient = true })
service("Selection")
local Players = service("Players")
service("KeyframeSequenceProvider")
service("ReplicatedStorage")
service("ServerStorage")
service("StarterPlayer")
service("StarterPack")
service("Lighting")
local open, opened, finished, yieldedOpen, failFinish = 0, 0, 0, false, false
local lastOp
methods.TryBeginRecording = function()
	open += 1
	opened += 1
	return "rec" .. opened
end
methods.FinishRecording = function(_, id, op)
	if failFinish then
		error("FinishRecording failed")
	end
	open -= 1
	finished += 1
	lastOp = op
end
methods.RegisterKeyframeSequence = function()
	return "rbxassetid://1"
end

-- dummies from the web
local asyncCalls, oldCalls, failCreate = 0, 0, false
local function makeModel(rigType)
	local root = new("Part", "HumanoidRootPart", { Size = V3(2, 2, 1), Anchored = false })
	local humanoid = new("Humanoid", "Humanoid", { HipHeight = 2, RigType = rigType })
	return new("Model", "Model", {}, { root, humanoid, new("Part", "Head", {}) })
end
local function createImpl(kind)
	if coroutine.isyieldable() then
		if open > 0 then yieldedOpen = true end
		coroutine.yield() -- the web request
		if open > 0 then yieldedOpen = true end
	end
	if failCreate then
		error("HttpError")
	end
	return makeModel(kind)
end
methods.CreateHumanoidModelFromDescriptionAsync = function(_, desc, rigType)
	asyncCalls += 1
	return createImpl(rigType)
end
methods.CreateHumanoidModelFromDescription = function(_, desc, rigType)
	oldCalls += 1
	return createImpl(rigType)
end
local function runThread(f)
	local co = coroutine.create(f)
	local ok, err = coroutine.resume(co)
	assert(ok, err)
	return co
end
local function resume(co)
	local ok, err = coroutine.resume(co)
	assert(ok, err)
end

-- animation mocks
local stepFails, steps = false, 0
methods.LoadAnimation = function(animator, anim)
	local track = { Looped = true, TimePosition = 0.5, Length = 1.2, IsPlaying = false, speed = 1, destroyed = false,
		Stopped = setmetatable({ handlers = {} }, SignalMT) }
	function track:Play(...) self.IsPlaying = true end
	function track:Stop() self.IsPlaying = false end
	function track:Destroy() self.destroyed = true end
	function track:AdjustSpeed(s) self.speed = s end
	function track:GetMarkerReachedSignal(name)
		return setmetatable({ handlers = {} }, SignalMT)
	end
	return track
end
methods.StepAnimations = function(animator, dt)
	if stepFails then error("StepAnimations failed") end
	steps += 1
end
methods.GetKeyframes = function(o)
	local out = {}
	for _, c in rawget(o, "_data")._children do
		if c.ClassName == "Keyframe" then table.insert(out, c) end
	end
	return out
end
methods.GetMarkers = function(o)
	local out = {}
	for _, c in rawget(o, "_data")._children do
		if c.ClassName == "KeyframeMarker" then table.insert(out, c) end
	end
	return out
end
local fullNameCalls = 0
local origFullName = methods.GetFullName
methods.GetFullName = function(o)
	fullNameCalls += 1
	return origFullName(o)
end
methods.PivotTo = function() end
methods.Destroy = (function(old)
	return function(o)
		rawget(o, "_data").destroyed = true
		old(o)
	end
end)(methods.Destroy)

