-- modules ---------------------------------------------------------------------------------------
local AnimGenMock = {
	CATEGORIES = { "Combo" },
	LIST = { { key = "k1", category = "Combo", label = "Punch", markers = {}, length = 1, hint = "h", looped = false } },
	measure = function() return {} end, generate = function() return nil end, save = function() return nil end,
}
mocks.AnimGen = AnimGenMock
local Panel = tree.load("AnimPanel")

local refreshes = 0
local ctx = { plugin = new("Plugin", "Plugin"), Editor = { previewTarget = function() return nil end, effects = function() return {} end,
	log = function() end } }
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

-- 1. dummy: Async name used, nothing recorded while the web request runs ------------------------------
local co = runThread(function()
	panel:makeDummy("R15")
end)
check(open == 0 and opened == 0, "no recording is open during the web request")
check(panel.making == true, "a dummy is on its way")
local second = runThread(function()
	panel:makeDummy("R6") -- a second click meanwhile
end)
check(asyncCalls == 1, "second click ignored: " .. asyncCalls)
resume(co)
check(asyncCalls == 1 and oldCalls == 0, "CreateHumanoidModelFromDescriptionAsync preferred")
check(panel.rig ~= nil and panel.rig.Name == "LostCube Dummy R15" and panel.rig.Parent == workspace, "dummy in the workspace")
check(opened == 1 and finished == 1 and open == 0, "one closed recording for the insertion")
check(not yieldedOpen, "never yielded while a recording was open")
check(lastOp == Enum.FinishRecordingOperation.Commit, "committed")
check(panel.making == false, "flag reset")
local firstRig = panel.rig

-- 2. old name when the new one is missing
methods.CreateHumanoidModelFromDescriptionAsync = nil
co = runThread(function()
	panel:makeDummy("R6")
end)
resume(co)
check(oldCalls == 1 and panel.rig.Name == "LostCube Dummy R6", "falls back to CreateHumanoidModelFromDescription")
check(open == 0 and not yieldedOpen, "recording closed, no yield inside")

-- 3. the web fails: no recording, a message, no rig change
failCreate = true
local before = opened
local rigBefore = panel.rig
co = runThread(function()
	panel:makeDummy("R6")
end)
resume(co)
check(opened == before, "a failed download opens no recording")
check(panel.rig == rigBefore and panel.error ~= nil and string.find(panel.error, "Nu am putut crea dummy-ul", 1, true), "error shown: " .. tostring(panel.error))
local function toastsOf(kind)
	local out = {}
	for _, d in root:GetDescendants() do
		local data = rawget(d, "_data")
		if data.Name == "Toast" and d:GetAttribute("Kind") == kind and data.Parent ~= nil then
			table.insert(out, d)
		end
	end
	return out
end
local function textsUnder(inst)
	local out = {}
	for _, d in inst:GetDescendants() do
		local t = rawget(d, "_data").Text
		if type(t) == "string" then table.insert(out, t) end
	end
	return table.concat(out, "\n")
end
local errorToasts = toastsOf("error")
check(#errorToasts >= 1 and string.find(textsUnder(errorToasts[#errorToasts]), "Nu am putut crea dummy-ul", 1, true) ~= nil,
	"the failure is a toast, not a note in the panel")
failCreate = false
panel.error = nil

-- 4. FinishRecording failing does not break the panel
failFinish = true
co = runThread(function()
	panel:makeDummy("R6")
end)
resume(co)
failFinish = false
open = 0
check(panel.rig ~= nil and panel.rig ~= rigBefore and panel.error == nil, "dummy made even if FinishRecording throws")

-- 5. destroyed while the dummy is on its way: the model is dropped
local beforeCount = #workspace:GetChildren()
panel.dead = false
co = runThread(function()
	panel:makeDummy("R15")
end)
panel.dead = true
resume(co)
check(#workspace:GetChildren() == beforeCount, "no dummy added to the place after destroy")
panel.dead = false

-- 6. playback: Animator made for the preview goes away again --------------------------------------------
local rig = makeModel(Enum.HumanoidRigType.R15)
rig.Parent = workspace
local clip = new("KeyframeSequence", "Punch")
clip.Parent = workspace
new("Keyframe", "Start", { Time = 0 }).Parent = clip
new("Keyframe", "Hit", { Time = 0.6 }, { new("KeyframeMarker", "Hit") }).Parent = clip
panel.rig, panel.clip = rig, clip
local humanoid = rig:FindFirstChildOfClass("Humanoid")
check(humanoid:FindFirstChildOfClass("Animator") == nil, "the rig has no Animator")
local hb = RunService.Heartbeat
panel:play()
check(panel.playing and panel.track ~= nil, "playing")
check(humanoid:FindFirstChildOfClass("Animator") ~= nil, "Animator made for the preview")
check(liveOn(hb) == 1, "one Heartbeat connection")
advance(0)
local beforeSteps = steps
for _, conn in hb.handlers do
	if conn.connected then conn.fn(1 / 60) end
end
check(steps == beforeSteps + 1, "animation stepped")
-- play again (e.g. new clip): the Animator is made again, not leaked, one connection only
panel:stop()
check(humanoid:FindFirstChildOfClass("Animator") == nil, "Animator removed on stop")
check(liveOn(hb) == 0, "Heartbeat disconnected on stop")
panel:play()
panel:stop()
panel:play()
check(liveOn(hb) == 1, "still one connection after replays")
check(#humanoid:GetChildren() == 1, "exactly one Animator under the Humanoid: " .. #humanoid:GetChildren())
-- a rig that has its own Animator keeps it
panel:stop()
local own = Instance.new("Animator")
own.Parent = humanoid
panel:play()
panel:stop()
check(humanoid:FindFirstChildOfClass("Animator") == own, "the rig's own Animator is left alone")
own:Destroy()

-- 7. Heartbeat failures stop the preview instead of failing every frame
panel:play()
stepFails = true
local refreshesBefore = refreshes
for _, conn in hb.handlers do
	if conn.connected then conn.fn(1 / 60) end
end
stepFails = false
check(panel.track == nil and liveOn(hb) == 0, "preview stopped after a failing step")
check(refreshes == refreshesBefore + 1, "panel redrawn once")
-- the rig is deleted while playing
panel:play()
rig.Parent = nil
for _, conn in hb.handlers do
	if conn.connected then conn.fn(1 / 60) end
end
check(panel.track == nil and liveOn(hb) == 0, "preview stopped when the rig is gone")
rig.Parent = workspace

-- 8. destroy cleans everything
panel:play()
check(liveOn(hb) == 1 and panel.track ~= nil, "playing again")
panel:destroy()
check(liveOn(hb) == 0 and panel.track == nil, "destroy: connection and track gone")
check(humanoid:FindFirstChildOfClass("Animator") == nil, "destroy: Animator removed")
local rf = refreshes
panel:refresh()
check(refreshes == rf, "no refresh after destroy")
panel.dead = false

-- 9. marker text survives a redraw ------------------------------------------------------------------------
panel.clip = clip
panel.genTemp = nil
local content = renderPanel()
local function markerBox(c)
	local last
	for _, d in c:GetDescendants() do
		if rawget(d, "_data").ClassName == "TextBox" and rawget(d, "_data").PlaceholderText ~= nil then
			last = d
		end
	end
	return last
end
local function findBoxByPlaceholder(c, text)
	for _, d in c:GetDescendants() do
		local data = rawget(d, "_data")
		if data.ClassName == "TextBox" and data.PlaceholderText == text then
			return d
		end
	end
end
local box = findBoxByPlaceholder(content, "Nume marker, ex. Hit")
check(box ~= nil, "marker box found")
box.Text = "Impact"
methods.GetPropertyChangedSignal(box, "Text"):Fire()
local content2 = renderPanel()
local box2 = findBoxByPlaceholder(content2, "Nume marker, ex. Hit")
check(box2 ~= nil and box2 ~= box and box2.Text == "Impact", "typed marker name kept across a redraw: " .. tostring(box2 and box2.Text))
-- the button uses it and clears it
panel.track = nil
local clicked = false
for _, d in content2:GetDescendants() do
	local data = rawget(d, "_data")
	if data.ClassName == "TextButton" and data.Text == "Adaugă" and data._signals and data._signals.MouseButton1Click then
		data._signals.MouseButton1Click:Fire()
		clicked = true
	end
end
check(clicked and panel.markerDraft == nil, "draft cleared when used")
panel.error = nil

-- 10. the clip list: sorted like before, GetFullName once per clip ----------------------------------------------
local RS = game:GetService("ReplicatedStorage")
local names = { "walk", "Run", "attack", "Zed", "idle", "Hit2", "hit1" }
for i, n in names do
	local folderName = ({ "Anims", "Boss", "Anims", "Boss", "Anims", "Boss", "Anims" })[i]
	local f = RS:FindFirstChild(folderName) or new("Folder", folderName)
	f.Parent = RS
	new("KeyframeSequence", n, {}, { new("Keyframe", "k", { Time = i / 2 }) }).Parent = f
end
fullNameCalls = 0
local list = panel:findClips()
local order = {}
for _, c in list do
	table.insert(order, c.Parent.Name .. "/" .. c.Name)
end
-- reference: the old comparator
local ref = table.clone(list)
table.sort(ref, function(a, b)
	local pa, pb = a.Parent and a.Parent:GetFullName() or "", b.Parent and b.Parent:GetFullName() or ""
	if pa ~= pb then return pa < pb end
	return a.Name:lower() < b.Name:lower()
end)
local same = #ref == #list
for i = 1, #list do
	if ref[i] ~= list[i] then same = false end
end
check(same, "same order as the old comparator: " .. table.concat(order, ", "))
check(panel.clipInfo[list[1]] ~= nil and panel.clipInfo[list[1]].group == list[1].Parent:GetFullName():gsub("^ReplicatedStorage%.", ""), "group cached")
local nClips = #list
-- GetFullName: once per clip while sorting + a handful above (the old comparator needed 2 per comparison)
fullNameCalls = 0
panel:findClips()
check(fullNameCalls <= nClips + 2, "GetFullName calls: " .. fullNameCalls .. " for " .. nClips .. " clips")
-- render with the list: no GetKeyframes per clip on redraw
local gk = 0
local origGK = methods.GetKeyframes
methods.GetKeyframes = function(o)
	gk += 1
	return origGK(o)
end
panel.clip = nil
renderPanel()
check(gk == 0, "redraw does not read the keyframes of every clip: " .. gk)
panel.clip = list[1]
gk = 0
renderPanel()
check(gk <= 4, "only the chosen clip is read on redraw: " .. gk)
methods.GetKeyframes = origGK

-- 11. the first list of the clips is made in the background ---------------------------------------------------------
local syncList = panel:findClips()
local syncOrder = table.clone(syncList)
panel.clips, panel.clipInfo = nil, nil
local descCalls = 0
local origDesc2 = methods.GetDescendants
methods.GetDescendants = function(o)
	descCalls += 1
	return origDesc2(o)
end
local rf2 = refreshes
local scanContent = renderPanel()
check(panel.scanning == true and panel.clips == nil, "the scan runs in the background")
local scanTexts = {}
for _, d in scanContent:GetDescendants() do
	local t = rawget(d, "_data").Text
	if type(t) == "string" then table.insert(scanTexts, t) end
end
check(string.find(table.concat(scanTexts, "\n"), "Caut animațiile", 1, true) ~= nil, "a note says it is searching")
drain()
check(panel.scanning == false and panel.clips ~= nil, "scan finished")
check(refreshes > rf2, "redrawn when the list is ready")
local sameList = #panel.clips == #syncOrder
for i = 1, #syncOrder do
	if panel.clips[i] ~= syncOrder[i] then sameList = false end
end
check(sameList, "same list, same order as the synchronous scan: " .. #panel.clips .. " vs " .. #syncOrder)
check(descCalls > 1, "walked part by part: " .. descCalls)
methods.GetDescendants = origDesc2
-- destroyed during the scan: it stops
panel.clips, panel.clipInfo = nil, nil
renderPanel()
check(panel.scanning == true, "scanning again")
panel:destroy()
drain()
check(panel.scanning == false and panel.clips == nil, "destroy stops the scan")
panel.dead = false


-- 12. the 2.1 look: no emoji, the transport bar, seek, the timeline, keyframe checkboxes, the easing curve ------------------
local function allTexts(c)
	local out = {}
	for _, d in c:GetDescendants() do
		local t = rawget(d, "_data").Text
		if type(t) == "string" and t ~= "" then table.insert(out, t) end
	end
	return out
end
local function symbolIn(text)
	for _, cp in utf8.codes(text) do
		if cp >= 0x2190 and cp <= 0x21FF or cp >= 0x2300 and cp <= 0x23FF or cp >= 0x25A0 or cp == 0x2713 or cp == 0x2717 then
			if cp ~= 0x2026 and cp ~= 0x203A and cp ~= 0x201E and cp ~= 0x201D then return utf8.char(cp) end
		end
	end
	return nil
end
local function byName(c, name)
	local out = {}
	for _, d in c:GetDescendants() do
		if rawget(d, "_data").Name == name then table.insert(out, d) end
	end
	return out
end
local eased = new("KeyframeSequence", "Eased")
eased.Parent = RS
local function kfWithPose(name, t, markers)
	local kids = { new("Pose", "HumanoidRootPart", { EasingStyle = Enum.PoseEasingStyle.Linear,
		EasingDirection = Enum.PoseEasingDirection.In, Weight = 1 }) }
	for _, m in markers or {} do table.insert(kids, new("KeyframeMarker", m)) end
	local kf = new("Keyframe", name, { Time = t }, kids)
	kf.Parent = eased
	return kf
end
local k1, k2, k3 = kfWithPose("A", 0), kfWithPose("B", 0.5, { "Hit" }), kfWithPose("C", 1)
panel:stop()
panel.clips, panel.clipInfo = nil, nil
panel:findClips()
panel.rig, panel.clip, panel.genTemp = rig, eased, nil
panel.picked = { [k2] = true }
for _, key in { "anim.rig", "anim.gen", "anim.clips", "anim.play", "anim.ease", "anim.fx" } do
	UIModule.collapsed[key] = false
end
local view = renderPanel()
local offenders = {}
for _, t in allTexts(view) do
	if symbolIn(t) then table.insert(offenders, t) end
end
check(#offenders == 0, "no emoji / symbol glyphs in the panel: " .. table.concat(offenders, " | "))
local joined = table.concat(allTexts(view), "\n")
for _, old in { "▶", "⏸", "⏹", "🔁", "◆", "■", "□", "💾", "⇄", "+ Dummy", "(gratis, ale tale)" } do
	check(not string.find(joined, old, 1, true), "old label gone: " .. old)
end
-- section counts are badges, not part of the titles
for _, t in allTexts(view) do
	if string.find(t, "<uc>", 1, true) then
		check(not string.find(t, "%(%d"), "count not in the title: " .. t)
	end
end
-- transport: icon buttons with tips, the play button, the time read-out, the timeline with keyframe ticks and markers
for _, glyph in { "toStart", "stepBack", "stepForward", "stop" } do
	check(#byName(view, "IconButton_" .. glyph) == 1, "transport button " .. glyph)
end
check(#byName(view, "PlayButton") == 1, "play button")
local timelines = byName(view, "Timeline")
check(#timelines == 1, "one timeline")
check(#byName(timelines[1], "Tick") == 3 and #byName(timelines[1], "Marker") == 1, "ticks at the 3 keyframes, 1 marker: "
	.. #byName(timelines[1], "Tick") .. " / " .. #byName(timelines[1], "Marker"))
check(string.find(joined, "0.00 / 1.00 s", 1, true) ~= nil, "time read-out before playing")
-- keyframe rows: a checkbox each, checked for the picked one; rows Selected
local boxes = byName(view, "Checkbox")
local checked = 0
for _, b in boxes do
	if b:GetAttribute("Checked") then checked += 1 end
end
check(#boxes == 3 and checked == 1, "checkboxes: " .. #boxes .. " / checked " .. checked)
check(string.find(joined, "1 din 3 alese", 1, true) ~= nil and string.find(joined, "Aplică pe 1 cadru", 1, true) ~= nil,
	"selection count and apply label")
-- the easing preview: a curve drawn from line segments
local curves = byName(view, "Curve")
check(#curves == 1 and #byName(curves[1], "Line") == 36, "curve of 36 segments: " .. (#curves > 0 and #byName(curves[1], "Line") or 0))
-- seek: the track pauses at the time, the read-out follows
panel:seek(0.3)
check(panel.track ~= nil and panel.track.TimePosition == 0.3 and panel.track.speed == 0 and not panel.playing, "seek pauses at 0.3 s")
view = renderPanel()
check(string.find(table.concat(allTexts(view), "\n"), "0.30 / 1.20 s", 1, true) ~= nil, "time read-out after seek")
panel:step(6)
check(math.abs(panel.track.TimePosition - 0.4) < 1e-6, "a step of 6 frames = 0.1 s: " .. panel.track.TimePosition)
panel:seek(-5)
check(panel.track.TimePosition == 0, "seek clamps at 0")
-- the curve maths
local Eased = Panel.eased
for _, style in { "Linear", "Cubic", "Bounce", "Elastic" } do
	for _, dir in { "In", "Out", "InOut" } do
		check(math.abs(Eased(style, dir, 0)) < 1e-6 and math.abs(Eased(style, dir, 1) - 1) < 1e-6, style .. " " .. dir .. " goes 0 -> 1")
	end
end
check(math.abs(Eased("Cubic", "Out", 0.5) - 0.875) < 1e-6 and math.abs(Eased("Cubic", "In", 0.5) - 0.125) < 1e-6, "cubic in / out")
check(math.abs(Eased("Linear", "InOut", 0.25) - 0.25) < 1e-6 and math.abs(Eased("Cubic", "InOut", 0.5) - 0.5) < 1e-6, "in-out symmetric")
local over, under = 0, 1
for i = 0, 100 do
	over = math.max(over, Eased("Elastic", "Out", i / 100))
	under = math.min(under, Eased("Bounce", "Out", i / 100))
end
check(over > 1.1 and under >= -1e-6, "elastic overshoots, bounce stays in range: " .. over .. " / " .. under)
local constant = Panel.curvePoints("Constant", "Out", 36)
check(#constant == 3 and constant[2][1] == 1 and constant[2][2] == 0, "constant: holds, then jumps")
-- applying easing: CubicV2 for Cubic (the legacy one runs reversed), one recording, a toast
panel.style, panel.direction = "Cubic", "Out"
local recBefore = opened
panel:applyEasing()
local pose = k2:FindFirstChildOfClass("Pose")
check(opened == recBefore + 1, "one undo recording")
check(pose.EasingStyle.Name == "CubicV2" and pose.EasingDirection.Name == "Out", "Cubic applied as CubicV2: " .. tostring(pose.EasingStyle))
check(k1:FindFirstChildOfClass("Pose").EasingStyle.Name == "Linear", "only the picked keyframe changed")
check(#toastsOf("success") >= 1, "a success toast")
view = renderPanel()
check(string.find(table.concat(allTexts(view), "\n"), "Cubic Out", 1, true) ~= nil, "row shows Cubic Out (not CubicV2)")
-- nothing picked: the apply button is disabled, applying explains
panel.picked = {}
panel.error = nil
panel:applyEasing()
check(panel.error ~= nil and string.find(panel.error, "cadrele", 1, true) ~= nil, "nothing picked: " .. tostring(panel.error))
-- the clip search filters the list in place
panel.clipQuery = "hit"
view = renderPanel()
local names = {}
for _, item in byName(view, "Item") do
	for _, l in item:GetDescendants() do
		local t = rawget(l, "_data").Text
		if type(t) == "string" and t ~= "" and not string.find(t, " s$") then table.insert(names, t) end
	end
end
local listed = table.concat(names, ",")
check(string.find(listed, "Hit2", 1, true) and string.find(listed, "hit1", 1, true) and not string.find(listed, "walk", 1, true),
	"search keeps the matching clips: " .. listed)
panel.clipQuery = ""
-- no clip in the game: an empty state with one action that opens the generator
panel:stop()
panel.clip = nil
panel.clips, panel.clipInfo, panel.scanning = {}, {}, false
UIModule.collapsed["anim.gen"] = true
view = renderPanel()
joined = table.concat(allTexts(view), "\n")
check(#byName(view, "Empty") == 1 and string.find(joined, "Nicio animație (KeyframeSequence) în joc.", 1, true) ~= nil, "empty state")
local opened2 = false
for _, d in view:GetDescendants() do
	local data = rawget(d, "_data")
	if data.ClassName == "TextButton" and data.Text == "Generează una" and data._signals and data._signals.MouseButton1Click then
		data._signals.MouseButton1Click:Fire()
		opened2 = true
	end
end
check(opened2 and UIModule.collapsed["anim.gen"] == false, "the empty-state action opens the generator")
