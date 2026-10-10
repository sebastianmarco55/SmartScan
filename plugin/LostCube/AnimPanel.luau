-- LostCube > Animations tab: preview any KeyframeSequence on a rig in Edit mode, Moon-style easing on
-- keyframes, and effects played on animation markers.
local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")
local Players = game:GetService("Players")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local UI = require(script.Parent.UI)
local C = UI.C

local Panel = {}
Panel.__index = Panel

local STYLES = { "Linear", "Constant", "Cubic", "Bounce", "Elastic" }
local DIRECTIONS = { { value = "In", label = "In" }, { value = "Out", label = "Out" }, { value = "InOut", label = "InOut" } }
local SEARCH = { "Workspace", "ReplicatedStorage", "ServerStorage", "StarterPlayer", "StarterPack", "Lighting" }

function Panel.new(ctx)
	return setmetatable({ ctx = ctx, Editor = ctx.Editor, rig = nil, clip = nil, speed = 1, loop = true,
		picked = {}, style = "Cubic", direction = "Out", clips = nil }, Panel)
end

function Panel:refresh()
	self.ctx.app:refresh()
end

local function record(name, fn)
	local ok, id = pcall(ChangeHistoryService.TryBeginRecording, ChangeHistoryService, "LostCube: " .. name)
	local done, err = pcall(fn)
	if ok and id then
		ChangeHistoryService:FinishRecording(id, done and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel)
	end
	if done then
		pcall(function()
			require(script.Parent.Editor).log(name)
		end)
	end
	return done, err
end

-- ---------------------------------------------------------------------------------------------
-- rig + clips
-- ---------------------------------------------------------------------------------------------
local function animatorOf(rig)
	local owner = rig:FindFirstChildOfClass("Humanoid") or rig:FindFirstChildOfClass("AnimationController")
	if not owner then
		return nil
	end
	local animator = owner:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = owner
	end
	return animator
end

local function rigType(rig)
	local h = rig and rig:FindFirstChildOfClass("Humanoid")
	if h then
		return h.RigType == Enum.HumanoidRigType.R15 and "R15" or "R6"
	end
	return rig and (rig:FindFirstChild("UpperTorso") and "R15" or "R6") or "-"
end

function Panel:findClips()
	local list = {}
	for _, name in SEARCH do
		local ok, service = pcall(game.GetService, game, name)
		if ok and service then
			for _, d in service:GetDescendants() do
				if d:IsA("KeyframeSequence") then
					table.insert(list, d)
				end
			end
		end
	end
	table.sort(list, function(a, b)
		local pa, pb = a.Parent and a.Parent:GetFullName() or "", b.Parent and b.Parent:GetFullName() or ""
		if pa ~= pb then
			return pa < pb
		end
		return a.Name:lower() < b.Name:lower()
	end)
	self.clips = list
	return list
end

function Panel:makeDummy(kind)
	self:stop()
	local done, err = record("dummy " .. kind, function()
		local model
		local desc = Instance.new("HumanoidDescription")
		local light, dark = Color3.fromRGB(214, 216, 226), Color3.fromRGB(40, 40, 48)
		desc.HeadColor, desc.LeftArmColor, desc.RightArmColor = light, light, light
		desc.LeftLegColor, desc.RightLegColor, desc.TorsoColor = dark, dark, dark
		local ok, result = pcall(Players.CreateHumanoidModelFromDescription, Players, desc, Enum.HumanoidRigType[kind])
		if ok and result then
			model = result
		else
			error("nu am putut crea dummy-ul: " .. tostring(result))
		end
		model.Name = "LostCube Dummy " .. kind
		local spot = self.Editor.previewTarget()
		local cf = typeof(spot) == "CFrame" and spot or CFrame.new(0, 0, 0)
		local root = model:FindFirstChild("HumanoidRootPart")
		local drop = kind == "R15" and (model.Humanoid.HipHeight + root.Size.Y / 2) or 3
		model:PivotTo(cf * CFrame.new(0, drop, 0))
		root.Anchored = true
		model.Parent = workspace
		self.rig = model
	end)
	if not done then
		self.error = tostring(err)
	end
	self:refresh()
end

-- ---------------------------------------------------------------------------------------------
-- playback (Edit mode: Animator:StepAnimations)
-- ---------------------------------------------------------------------------------------------
function Panel:resetPose()
	if not self.rig then
		return
	end
	for _, m in self.rig:GetDescendants() do
		if m:IsA("Motor6D") then
			m.Transform = CFrame.new()
		end
	end
end

function Panel:stop()
	if self.conn then
		self.conn:Disconnect()
		self.conn = nil
	end
	for _, c in self.markerConns or {} do
		c:Disconnect()
	end
	self.markerConns = nil
	self.playing = false
	if self.track then
		pcall(function()
			self.track:Stop(0)
			self.track:Destroy()
		end)
		self.track = nil
	end
	self:resetPose()
end

function Panel:load()
	if not (self.rig and self.clip) then
		return nil
	end
	local animator = animatorOf(self.rig)
	if not animator then
		self.error = "rig-ul nu are Humanoid sau AnimationController"
		return nil
	end
	self:stop()
	local anim = Instance.new("Animation")
	anim.AnimationId = KeyframeSequenceProvider:RegisterKeyframeSequence(self.clip) -- picks up the latest edits
	local track = animator:LoadAnimation(anim)
	track.Looped = self.loop
	self.track, self.animator = track, animator
	-- effects on markers
	self.markerConns = {}
	for _, marker in self:markers() do
		local fxName = self.clip:GetAttribute("LC_FX_" .. marker.name)
		if fxName then
			table.insert(self.markerConns, track:GetMarkerReachedSignal(marker.name):Connect(function()
				pcall(self.Editor.preview, fxName, { target = self.rig, speed = self.speed })
			end))
		end
	end
	self.conn = RunService.Heartbeat:Connect(function(dt)
		if self.track then
			self.animator:StepAnimations(dt)
			if self.timeLabel and self.timeLabel.Parent then
				self.timeLabel.Text = string.format("%.2f / %.2f s", self.track.TimePosition, self.track.Length)
			end
		end
	end)
	return track
end

function Panel:play()
	local track = self.track or self:load()
	if not track then
		self:refresh()
		return
	end
	if not track.IsPlaying then
		track:Play(0, 1, self.speed)
	end
	track:AdjustSpeed(self.speed)
	self.playing = true
	self:refresh()
end

function Panel:pause()
	if self.track then
		self.track:AdjustSpeed(0)
	end
	self.playing = false
	self:refresh()
end

function Panel:step(frames)
	local track = self.track or self:load()
	if not track then
		return
	end
	if not track.IsPlaying then
		track:Play(0, 1, 0)
	end
	track:AdjustSpeed(0)
	self.playing = false
	track.TimePosition = math.clamp(track.TimePosition + frames / 60, 0, math.max(track.Length - 1e-3, 0))
	self.animator:StepAnimations(0)
	self:refresh()
end

function Panel:destroy()
	self:stop()
end

-- ---------------------------------------------------------------------------------------------
-- keyframes / markers
-- ---------------------------------------------------------------------------------------------
function Panel:keyframes()
	local list = self.clip and self.clip:GetKeyframes() or {}
	table.sort(list, function(a, b)
		return a.Time < b.Time
	end)
	return list
end

function Panel:markers()
	local out = {}
	for _, kf in self:keyframes() do
		for _, m in kf:GetMarkers() do
			table.insert(out, { name = m.Name, time = kf.Time, marker = m })
		end
	end
	return out
end

local function firstPose(kf)
	for _, d in kf:GetDescendants() do
		if d:IsA("Pose") and d.Weight > 0 then
			return d
		end
	end
	return nil
end

function Panel:applyEasing()
	local picked = {}
	for kf in self.picked do
		if kf.Parent == self.clip then
			table.insert(picked, kf)
		end
	end
	if #picked == 0 then
		self.error = "alege întâi cadrele (click pe ele)"
		self:refresh()
		return
	end
	local style, direction = Enum.PoseEasingStyle[self.style], Enum.PoseEasingDirection[self.direction]
	local done, err = record(string.format("easing %s %s pe %d cadre (%s)", self.style, self.direction, #picked, self.clip.Name), function()
		for _, kf in picked do
			for _, pose in kf:GetDescendants() do
				if pose:IsA("Pose") then
					pose.EasingStyle = style
					pose.EasingDirection = direction
				end
			end
		end
	end)
	self.error = not done and tostring(err) or nil
	self:stop() -- the next play re-registers the clip with the new easing
	self:refresh()
end

function Panel:addMarker(name)
	if not (self.clip and self.track) then
		self.error = "pornește sau pune animația pe un cadru întâi"
		self:refresh()
		return
	end
	local t = self.track.TimePosition
	local done, err = record("marker " .. name .. " pe " .. self.clip.Name, function()
		local target
		for _, kf in self:keyframes() do
			if math.abs(kf.Time - t) < 1 / 120 then
				target = kf
			end
		end
		if not target then
			target = Instance.new("Keyframe")
			target.Name = name
			target.Time = math.floor(t * 60 + 0.5) / 60
			target.Parent = self.clip
		end
		local m = Instance.new("KeyframeMarker")
		m.Name = name
		target:AddMarker(m)
	end)
	self.error = not done and tostring(err) or nil
	self:stop()
	self:refresh()
end

-- ---------------------------------------------------------------------------------------------
-- render
-- ---------------------------------------------------------------------------------------------
function Panel:render(parent)
	if self.rig and not self.rig.Parent then
		self:stop()
		self.rig = nil
	end
	if self.error then
		UI.note(parent, "⚠ " .. self.error, C.warn)
		self.error = nil
	end

	-- rig
	local body = UI.section(parent, "Rig de previzualizare", { key = "anim.rig" })
	UI.label(body, self.rig and (self.rig.Name .. "  (" .. rigType(self.rig) .. ")") or "Niciun rig ales", { medium = true })
	UI.button(UI.hstack(body), "Folosește personajul selectat", function()
		local sel = Selection:Get()[1]
		local model = sel and (sel:IsA("Model") and sel or sel:FindFirstAncestorWhichIsA("Model"))
		if model and (model:FindFirstChildOfClass("Humanoid") or model:FindFirstChildOfClass("AnimationController")) then
			self:stop()
			self.rig = model
		else
			self.error = "selectează un personaj (Model cu Humanoid)"
		end
		self:refresh()
	end)
	local bar = UI.hstack(body)
	UI.button(bar, "+ Dummy R6", function()
		self:makeDummy("R6")
	end)
	UI.button(bar, "+ Dummy R15", function()
		self:makeDummy("R15")
	end)

	-- clips
	local clips = self.clips or self:findClips()
	body = UI.section(parent, "Animații  (" .. #clips .. ")", { key = "anim.clips", right = function(r)
		UI.button(r, "🔁", function()
			self:findClips()
			self:refresh()
		end, { width = 34, height = 22, style = "ghost" })
	end, rightWidth = 38 })
	local list = UI.scrollList(body, self.clip and 200 or 420)
	local lastGroup
	for _, clip in clips do
		if clip.Parent then
			local group = clip.Parent:GetFullName():gsub("^Workspace%.", ""):gsub("^ReplicatedStorage%.", "")
			if group ~= lastGroup then
				UI.label(list, group, { dim = true, size = 11, height = 18 })
				lastGroup = group
			end
			local kfs = clip:GetKeyframes()
			local length = 0
			for _, kf in kfs do
				length = math.max(length, kf.Time)
			end
			UI.item(list, clip.Name, { icon = "►", selected = clip == self.clip, note = string.format("%.2fs", length),
				onClick = function()
					self:stop()
					self.clip = clip
					self.picked = {}
					self:refresh()
				end })
		end
	end
	if #clips == 0 then
		UI.note(body, "Nicio animație (KeyframeSequence) în joc.")
	end
	if not self.clip then
		return
	end
	local clip = self.clip

	-- playback
	body = UI.section(parent, "Redare: " .. clip.Name, { key = "anim.play" })
	if not self.rig then
		UI.note(body, "Alege un rig (selecția sau un dummy) ca să vezi animația.")
	end
	local controls = UI.hstack(body, { height = 28 })
	UI.button(controls, self.playing and "⏸ Pauză" or "▶  Redă", function()
		if self.playing then
			self:pause()
		else
			self:play()
		end
	end, { style = "primary", bold = true, height = 28 })
	UI.button(controls, "◀", function()
		self:step(-1)
	end, { width = 30, height = 28 })
	UI.button(controls, "▶", function()
		self:step(1)
	end, { width = 30, height = 28 })
	UI.button(controls, "⏹", function()
		self:stop()
		self.playing = false
		self:refresh()
	end, { width = 30, height = 28 })
	self.timeLabel = UI.label(body, self.track and string.format("%.2f / %.2f s", self.track.TimePosition, self.track.Length)
		or "-", { dim = true, size = 12 })
	UI.segmented(UI.row(body, "Viteză"), {
		{ value = 0.25, label = "×0.25" }, { value = 0.5, label = "×0.5" }, { value = 1, label = "×1" }, { value = 2, label = "×2" },
	}, self.speed, function(v)
		self.speed = v
		if self.track and self.playing then
			self.track:AdjustSpeed(v)
		end
		self:refresh()
	end)
	UI.toggle(UI.hstack(body), self.loop, function(v)
		self.loop = v
		if self.track then
			self.track.Looped = v
		end
		self:refresh()
	end, "Repetă")

	-- keyframes + easing
	local kfs = self:keyframes()
	body = UI.section(parent, "Cadre și easing (ca în Moon)", { key = "anim.ease" })
	local count = 0
	for _ in self.picked do
		count += 1
	end
	local sel = UI.hstack(body)
	UI.button(sel, "Toate", function()
		for _, kf in kfs do
			self.picked[kf] = true
		end
		self:refresh()
	end)
	UI.button(sel, "Niciunul", function()
		self.picked = {}
		self:refresh()
	end)
	for _, kf in kfs do
		local pose = firstPose(kf)
		local easing = pose and (pose.EasingStyle.Name .. " " .. pose.EasingDirection.Name) or "-"
		local markers = #kf:GetMarkers() > 0 and ("  ◆ " .. kf:GetMarkers()[1].Name) or ""
		UI.item(body, string.format("%.2fs  %s%s", kf.Time, kf.Name, markers), {
			icon = self.picked[kf] and "■" or "□", selected = self.picked[kf] == true, note = easing, height = 24,
			onClick = function()
				self.picked[kf] = not self.picked[kf] or nil
				self:refresh()
			end })
	end
	local grid = UI.hstack(body)
	for i, style in STYLES do
		if i == 4 then
			grid = UI.hstack(body)
		end
		UI.button(grid, style, function()
			self.style = style
			self:refresh()
		end, { selected = self.style == style, textSize = 12 })
	end
	UI.segmented(UI.row(body, "Direcție"), DIRECTIONS, self.direction, function(v)
		self.direction = v
		self:refresh()
	end)
	UI.button(UI.hstack(body, { height = 28 }), string.format("Aplică pe %d cadre", count), function()
		self:applyEasing()
	end, { style = "primary", bold = true, height = 28 })
	UI.label(body, "Easing-ul unui cadru = mișcarea de la el spre următorul.", { dim = true, size = 11, wrap = true })

	-- effects on markers
	body = UI.section(parent, "Efecte pe markere", { key = "anim.fx" })
	local effectItems = { { value = "", label = "(niciun efect)" } }
	for _, fx in self.Editor.effects() do
		table.insert(effectItems, { value = fx.Name, label = fx.Name })
	end
	local markers = self:markers()
	if #markers == 0 then
		UI.label(body, "Animația nu are markere.", { dim = true, size = 12 })
	end
	for _, m in markers do
		UI.dropdown(UI.row(body, string.format("◆ %s (%.2fs)", m.name, m.time), { labelWidth = 130 }), effectItems,
			clip:GetAttribute("LC_FX_" .. m.name) or "", function(v)
				record("efect " .. (v ~= "" and v or "-") .. " pe markerul " .. m.name, function()
					clip:SetAttribute("LC_FX_" .. m.name, v ~= "" and v or nil)
				end)
				self:stop()
				self:refresh()
			end, { menuWidth = 180 })
	end
	local add = UI.hstack(body)
	local box = UI.textbox(add, "", nil, { placeholder = "nume marker (ex. Hit)" })
	UI.button(add, "+ Marker aici", function()
		if box.Text ~= "" then
			self:addMarker(box.Text)
		end
	end, { width = 110 })
	UI.label(body, "În joc: VFX.bindMarkers(track, personaj, { Hit = \"NumeEfect\" })", { dim = true, size = 11, wrap = true })
end

return Panel
