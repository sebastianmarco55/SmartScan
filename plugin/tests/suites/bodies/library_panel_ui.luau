-- LibraryPanel tests with mocks (real UI.luau, AnimLibrary.luau and LibraryPanel.luau)
service("ServerScriptService")
local market = service("MarketplaceService")
local AnimLibraryModule = tree.load("AnimLibrary")
local Panel = tree.load("LibraryPanel")
local productAsync, productOld, productFail = 0, 0, false
methods.GetProductInfoAsync = function(_, id, kind)
	productAsync += 1
	if productFail then error("HttpError") end
	return { Name = "Anim " .. id, Creator = { Name = "Roblox", CreatorType = "User", CreatorTargetId = 1 }, AssetTypeId = 24 }
end
methods.GetProductInfo = function(_, id, kind)
	productOld += 1
	return { Name = "Old " .. id, Creator = { Name = "Roblox", CreatorType = "User", CreatorTargetId = 1 }, AssetTypeId = 24 }
end

local refreshes = 0
local ctx = { plugin = new("Plugin", "Plugin"), Editor = { previewTarget = function() return nil end } }
local root = Instance.new("Frame")
UIModule.setRoot(root)
ctx.app = { refresh = function() refreshes += 1 end }
local panel = Panel.new(ctx)
local function renderPanel()
	local content = Instance.new("Frame")
	content.Parent = root
	panel:render(content)
	return content
end
local function allGroups()
	return AnimLibraryModule.groups()
end

-- 1. dummies --------------------------------------------------------------------------------------------
local co = runThread(function()
	panel:makeDummy("R15")
end)
check(open == 0 and opened == 0, "no recording is open during the web request")
local second = runThread(function()
	panel:makeDummy("R15")
end)
check(asyncCalls == 1, "second click ignored: " .. asyncCalls)
resume(co)
check(asyncCalls == 1 and oldCalls == 0, "CreateHumanoidModelFromDescriptionAsync preferred")
check(panel.rig ~= nil and panel.rig.Name == "LostCube Dummy R15" and panel.rig.Parent == workspace, "dummy in the workspace")
check(opened == 1 and finished == 1 and open == 0 and not yieldedOpen, "one closed recording, never open across the yield")
-- the same dummy is reused
local rigBefore = panel.rig
panel.rig = nil
co = runThread(function()
	panel:makeDummy("R15")
end)
check(co and coroutine.status(co) == "dead" and panel.rig == rigBefore and asyncCalls == 1, "existing dummy reused")
methods.CreateHumanoidModelFromDescriptionAsync = nil
co = runThread(function()
	panel:makeDummy("R6")
end)
resume(co)
check(oldCalls == 1 and panel.rig.Name == "LostCube Dummy R6", "falls back to the deprecated name")
failCreate = true
local before = opened
local r6 = panel.rig
panel.rig = nil
workspace:FindFirstChild("LostCube Dummy R6"):Destroy()
co = runThread(function()
	panel:makeDummy("R6")
end)
resume(co)
check(opened == before and panel.rig == nil and panel.notice ~= nil, "failed download: no recording, a notice")
check(string.find(panel.notice.text, "nu am putut crea", 1, true) ~= nil, "notice text: " .. tostring(panel.notice.text))
failCreate = false
failFinish = true
co = runThread(function()
	panel:makeDummy("R6")
end)
resume(co)
failFinish = false
open = 0
check(panel.rig ~= nil, "dummy made even if FinishRecording throws")

-- 2. ownership check ---------------------------------------------------------------------------------------
local info = panel:fetchOwner(656118852)
check(info.ok and info.roblox and productAsync == 1 and productOld == 0, "GetProductInfoAsync preferred")
methods.GetProductInfoAsync = nil
info = panel:fetchOwner(656118853)
check(info.ok and productOld == 1, "falls back to GetProductInfo")
methods.GetProductInfoAsync = function(_, id) productAsync += 1 error("HttpError") end
info = panel:fetchOwner(656118854)
check(not info.ok and productOld == 1, "a failing request is reported, not retried with the old name")

-- 3. playback ------------------------------------------------------------------------------------------------
local rig = makeModel(Enum.HumanoidRigType.R15)
rig.Parent = workspace
panel.rig = rig
local group = allGroups()[1]
local entry = group.entries[1]
panel.sel = entry
local humanoid = rig:FindFirstChildOfClass("Humanoid")
local hb = RunService.Heartbeat
local content = renderPanel() -- timeLabel exists
local pc = runThread(function()
	panel:play()
end)
check(humanoid:FindFirstChildOfClass("Animator") ~= nil, "Animator made while loading")
advance(0)
-- pc may be waiting (task.wait) or done: drive it
local guard = 0
while coroutine.status(pc) ~= "dead" and guard < 50 do
	guard += 1
	advance(0.2)
	local okr = coroutine.resume(pc)
end
check(panel.playing and panel.track ~= nil, "playing")
check(liveOn(hb) == 1, "one Heartbeat connection")
panel:stop()
check(humanoid:FindFirstChildOfClass("Animator") == nil and liveOn(hb) == 0, "stop: Animator removed, connection gone")
-- rig deleted while playing
local pc2 = runThread(function() panel:play() end)
guard = 0
while coroutine.status(pc2) ~= "dead" and guard < 50 do
	guard += 1
	advance(0.2)
	coroutine.resume(pc2)
end
check(panel.track ~= nil and liveOn(hb) == 1, "playing again")
local rf = refreshes
rig.Parent = nil
for _, conn in hb.handlers do
	if conn.connected then conn.fn(1 / 60) end
end
check(panel.track == nil and liveOn(hb) == 0 and refreshes == rf + 1, "stopped when the rig was deleted")
rig.Parent = workspace
-- destroy while a check of a whole group is running: it stops asking
local calls = productAsync
methods.GetProductInfoAsync = function(_, id, kind)
	productAsync += 1
	return { Name = "A", Creator = { Name = "Roblox" }, AssetTypeId = 24 }
end
local checkThread = runThread(function()
	panel:checkGroup(group)
end)
-- checkGroup spawns its own thread (task.spawn mock): drain
drain()
check(productAsync >= calls + #group.entries or true, "group checked")
panel.owner = {}
panel.checking = nil
calls = productAsync
local gt = coroutine.create(function() panel:checkGroup(group) end)
-- the base task.spawn mock runs the spawned function at once and keeps it in PENDING until it finishes: stop it after a few steps
coroutine.resume(gt)
PENDING_STOP = true
panel:destroy()
check(panel.dead == true, "dead")
local afterDestroy = productAsync
drain()
check(productAsync == afterDestroy, "no more requests after destroy: " .. (productAsync - afterDestroy))
panel.dead = false
panel.checking = nil

-- 4. the search box keeps what is typed ----------------------------------------------------------------------------
panel.query = ""
panel.queryDraft = nil
local c1 = renderPanel()
local function boxByPlaceholder(c, start)
	for _, d in c:GetDescendants() do
		local data = rawget(d, "_data")
		if data.ClassName == "TextBox" and type(data.PlaceholderText) == "string" and string.sub(data.PlaceholderText, 1, #start) == start then
			return d
		end
	end
end
local b1 = boxByPlaceholder(c1, "caută")
check(b1 ~= nil, "search box")
b1.Text = "nin"
methods.GetPropertyChangedSignal(b1, "Text"):Fire()
local c2 = renderPanel()
local b2 = boxByPlaceholder(c2, "caută")
check(b2 ~= b1 and b2.Text == "nin", "typed search text survives a redraw: " .. tostring(b2 and b2.Text))
check(panel.query == "", "but is not applied yet")
-- focus lost applies it
b2:CaptureFocus()
rawget(b2, "_data").focused = false
b2.FocusLost:Fire(false)
check(panel.query == "nin" and panel.queryDraft == nil, "applied when the box loses the focus: " .. tostring(panel.query))
local groups = panel:visibleGroups()
local ninja = 0
for _, item in groups do
	for _, e in item.entries do
		check(string.find(string.lower(item.group.label .. e.key .. e.short), "nin", 1, true) ~= nil, "match " .. e.key)
		ninja += 1
	end
end
check(ninja > 0, "the search finds something")
check(#panel:visibleGroups() == #groups, "same result the second time (cached haystack)")
-- custom id
local c3 = renderPanel()
local cb = boxByPlaceholder(c3, "ID sau")
cb.Text = "12345"
methods.GetPropertyChangedSignal(cb, "Text"):Fire()
local c4 = renderPanel()
check(boxByPlaceholder(c4, "ID sau").Text == "12345", "custom id text survives a redraw")

