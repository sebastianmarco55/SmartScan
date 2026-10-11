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
check(string.find(panel.notice.text, "Nu am putut crea dummy-ul", 1, true) ~= nil and panel.notice.kind == "error",
	"notice text: " .. tostring(panel.notice.text))
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
local b1 = boxByPlaceholder(c1, "Caută")
check(b1 ~= nil, "search box")
b1.Text = "nin"
methods.GetPropertyChangedSignal(b1, "Text"):Fire()
local c2 = renderPanel()
local b2 = boxByPlaceholder(c2, "Caută")
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


-- 5. the 2.1 look: filters as chips, packs as rows with badges, the detail with the owner status, toasts -----------------
local function allTexts(c)
	local out = {}
	for _, d in c:GetDescendants() do
		local t = rawget(d, "_data").Text
		if type(t) == "string" and t ~= "" then table.insert(out, t) end
	end
	return out
end
local function byName(c, name)
	local out = {}
	for _, d in c:GetDescendants() do
		if rawget(d, "_data").Name == name then table.insert(out, d) end
	end
	return out
end
local function click(c, text)
	for _, d in c:GetDescendants() do
		local data = rawget(d, "_data")
		if data.ClassName == "TextButton" and data.Text == text and data._signals and data._signals.MouseButton1Click then
			data._signals.MouseButton1Click:Fire()
			return true
		end
	end
	return false
end
local function symbolIn(text)
	for _, cp in utf8.codes(text) do
		if (cp >= 0x2190 and cp <= 0x21FF) or (cp >= 0x2300 and cp <= 0x23FF) or cp >= 0x25A0 or cp == 0x2713 or cp == 0x2717 then
			return utf8.char(cp)
		end
	end
	return nil
end
panel:stop()
panel.query, panel.queryDraft, panel.kind, panel.rigFilter = "", nil, "all", "all"
local ninja = AnimLibraryModule.group("ninja")
panel.sel = ninja.entries[3]
panel.openGroup = "ninja"
panel.owner[panel.sel.id] = { ok = true, name = "Ninja", creator = "Roblox", roblox = true, assetType = 24 }
for _, key in { "lib.rig", "lib.list", "lib.sel", "lib.code", "lib.custom", "lib.about" } do
	UIModule.collapsed[key] = false
end
local view = renderPanel()
local texts = allTexts(view)
local offenders = {}
for _, t in texts do
	if symbolIn(t) then table.insert(offenders, t) end
end
check(#offenders == 0, "no emoji / symbol glyphs: " .. table.concat(offenders, " | "))
local joined = table.concat(texts, "\n")
for _, old in { "▶", "⏸", "⏹", "✓", "✗", "⚠", "▼", "►", "+ Animația aleasă", "+ Dummy", "(%d pachete" } do
	check(not string.find(joined, old, 1, true), "old label gone: " .. old)
end
-- filters are chips: one kind selected, no rig chip selected (all rigs)
local chips = byName(view, "Chip")
local selectedChips = {}
for _, c in chips do
	if c:GetAttribute("Selected") then table.insert(selectedChips, c.Text) end
end
check(#chips == 5 and #selectedChips == 1 and selectedChips[1] == "Toate", "chips: " .. #chips .. ", selected " .. table.concat(selectedChips, ","))
check(click(view, "R6") and panel.rigFilter == "R6", "rig chip filters")
view = renderPanel()
check(click(view, "R6") and panel.rigFilter == "all", "the selected rig chip again: all rigs")
check(click(view, "Emote") and panel.kind == "emote", "kind chip")
panel.kind = "all"
view = renderPanel()
-- the open pack: its rows Selected / not, a play button on each state, badges with the rig and the count
local selectedRows, playButtons = 0, #byName(view, "IconButton_play")
for _, item in byName(view, "Item") do
	if item:GetAttribute("Selected") then selectedRows += 1 end
end
check(selectedRows == 1, "one selected row: " .. selectedRows)
check(playButtons == #ninja.entries, "a play button per state: " .. playButtons)
check(string.find(joined, tostring(#ninja.entries), 1, true) ~= nil, "pack count badge")
-- owner status is a pill, with a refresh button; the code section and the transport are there
check(string.find(joined, "Roblox", 1, true) ~= nil and #byName(view, "IconButton_refresh") >= 1, "owner pill + check button")
check(#byName(view, "PlayButton") == 1 and #byName(view, "Timeline") == 1, "transport + timeline")
local stepBack = byName(view, "IconButton_stepBack")
local stepSignals = stepBack[1] and rawget(stepBack[1], "_data")._signals
check(#stepBack == 1 and not (stepSignals and stepSignals.MouseButton1Click), "step buttons disabled until a track is loaded")
-- add to game: a success toast with an action, the notice remembered
check(click(view, "Adaugă în joc"), "add button")
check(panel.notice and panel.notice.kind == "success" and string.find(panel.notice.text, "1 animație adăugată", 1, true) ~= nil,
	"added: " .. tostring(panel.notice and panel.notice.text))
local anim = game:GetService("ReplicatedStorage"):FindFirstChild("LostCube")
check(anim and anim:FindFirstChild("Animations") and anim.Animations:FindFirstChild(ninja.folder)
	and anim.Animations[ninja.folder]:FindFirstChild(panel.sel.name) ~= nil, "Animation instance created")
local toastFound = false
for _, d in root:GetDescendants() do
	if rawget(d, "_data").Name == "Toast" and d:GetAttribute("Kind") == "success" then toastFound = true end
end
check(toastFound, "a success toast in the window")
-- the search rebuilds only the list (no full redraw while typing)
view = renderPanel()
local rf3 = refreshes
local searchBox = boxByPlaceholder(view, "Caută")
searchBox.Text = "ninja run"
methods.GetPropertyChangedSignal(searchBox, "Text"):Fire()
advance(0.2) -- the search's pause
check(panel.query == "ninja run" and refreshes == rf3, "applied after the pause, without a redraw: " .. panel.query)
local rowsNow = {}
for _, item in byName(view, "Item") do
	if rawget(item, "_data").Parent ~= nil then
		for _, l in item:GetDescendants() do
			local t = rawget(l, "_data").Text
			if type(t) == "string" and t ~= "" then table.insert(rowsNow, t) end
		end
	end
end
check(string.find(table.concat(rowsNow, ","), "Alergare", 1, true) ~= nil and not string.find(table.concat(rowsNow, ","), "Repaus", 1, true),
	"the list shows only the match: " .. table.concat(rowsNow, ","))
panel.query = "zzzz"
view = renderPanel()
check(#byName(view, "Empty") == 1, "no match: an empty state")
panel.query = ""
-- seek / step on a loaded track (the timeline drags through seek)
local fakeTrack = { TimePosition = 0, Length = 2, IsPlaying = false, speed = 1 }
function fakeTrack:Play() self.IsPlaying = true end
function fakeTrack:AdjustSpeed(s) self.speed = s end
function fakeTrack:Stop() self.IsPlaying = false end
function fakeTrack:Destroy() end
panel.track, panel.animator = fakeTrack, { StepAnimations = function() end }
panel.playing = true
panel:seek(1.5)
check(fakeTrack.TimePosition == 1.5 and fakeTrack.speed == 0 and not panel.playing, "seek pauses at the time")
panel:step(-30)
check(math.abs(fakeTrack.TimePosition - 1) < 1e-6, "step back half a second: " .. fakeTrack.TimePosition)
panel:seek(9)
check(fakeTrack.TimePosition < 2, "seek clamps to the length")
panel.track, panel.animator, panel.playing = nil, nil, false
