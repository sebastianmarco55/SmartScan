-- LostCube > Library tab: free animations OWNED BY ROBLOX (default character animations, Roblox's catalog packs and
-- emotes). They play in any experience because Roblox owns them (see AnimLibrary for the data and where it comes from).
--   * browse / search / filter, preview on a rig in Edit mode (Animator:StepAnimations, like the Animations tab)
--   * add the animations to the game as Animation instances (ReplicatedStorage.LostCube.Animations.<Pack>.<state>)
--   * make a pack the default animation set of every character (a server Script that edits the Animate script)
--   * copy a Luau snippet that plays the animation
local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local MarketplaceService = game:GetService("MarketplaceService")

local UI = require(script.Parent.UI)
local AnimLibrary = require(script.Parent.AnimLibrary)

local Panel = {}
Panel.__index = Panel

local KINDS = {
	{ value = "all", label = "Toate" },
	{ value = "pack", label = "Pachete" },
	{ value = "emote", label = "Emote" },
}
local RIGS = { "R15", "R6" }
local SPEEDS = {
	{ value = 0.5, label = "0.5×" },
	{ value = 1, label = "1×" },
	{ value = 2, label = "2×" },
}
local VERIFIED = {
	api = "API Roblox",
	["2-sources"] = "2+ surse independente",
	custom = "neverificat",
}

local MAX_ROWS = 120 -- rows drawn in the list at once (a broad search stays fast)
local LOAD_TIMEOUT = 8 -- seconds to wait for an animation asset to arrive
local ANIMATION_TYPE, EMOTE_TYPE = 24, 61 -- AssetTypeId

function Panel.new(ctx)
	return setmetatable({
		ctx = ctx, Editor = ctx.Editor, query = "", kind = "all", rigFilter = "all", openGroup = nil, sel = nil,
		rig = nil, speed = 1, loop = true, gen = 0, owner = {}, codeMode = "play", listY = 0, dummyKind = "R15",
	}, Panel)
end

function Panel:refresh()
	if not self.dead then
		self.ctx.app:refresh()
	end
end

-- fn must not yield: the recording stays open meanwhile (and every edit of the user lands in it)
local function record(name, fn)
	local ok, id = pcall(ChangeHistoryService.TryBeginRecording, ChangeHistoryService, "LostCube: " .. name)
	local done, err = pcall(fn)
	if ok and id then
		pcall(ChangeHistoryService.FinishRecording, ChangeHistoryService, id,
			done and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel)
	end
	if done then
		pcall(function()
			require(script.Parent.Editor).log(name)
		end)
	end
	return done, err
end

-- error text without the "Plugin_123.LostCube.LibraryPanel:45:" prefix, kept short
local function friendly(err)
	local text = tostring(err):gsub("^[%w_%.%-%s]*:%d+:%s*", "")
	if #text > 180 then
		text = text:sub(1, 177) .. "..."
	end
	return text
end

-- the outcome of an action: a toast (kind "success" / "warning" / "error" / "info"); the last one stays in self.notice.
-- opts: the toast's options (action, duration)
function Panel:notify(text, kind, opts)
	self.notice = { text = text, kind = kind or "warning" }
	UI.toast(text, kind or "warning", opts)
end

function Panel:clearNotice()
	self.notice = nil
end

-- the child called `name`, created as a Folder when missing (an existing one is reused whatever its class)
local function ensureFolder(parent, name)
	local folder = parent:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = parent
	end
	return folder
end

-- a toast action that selects an instance in the Explorer
local function showAction(target)
	return { text = "Arată", onClick = function()
		if target and target.Parent then
			pcall(Selection.Set, Selection, { target })
		end
	end }
end

-- ---------------------------------------------------------------------------------------------
-- rig
-- ---------------------------------------------------------------------------------------------
-- the Animator of the rig; made when missing (the second value is true then: Panel:stop takes it away again)
local function animatorOf(rig)
	local owner = rig:FindFirstChildOfClass("Humanoid") or rig:FindFirstChildOfClass("AnimationController")
	if not owner then
		return nil
	end
	local animator = owner:FindFirstChildOfClass("Animator")
	if animator then
		return animator, false
	end
	animator = Instance.new("Animator")
	animator.Parent = owner
	return animator, true
end

local function rigType(rig)
	local h = rig and rig:FindFirstChildOfClass("Humanoid")
	if h then
		return h.RigType == Enum.HumanoidRigType.R15 and "R15" or "R6"
	end
	return rig and (rig:FindFirstChild("UpperTorso") and "R15" or "R6") or "-"
end

local function selectedRig()
	local sel = Selection:Get()[1]
	local model = sel and (sel:IsA("Model") and sel or sel:FindFirstAncestorWhichIsA("Model"))
	if model and (model:FindFirstChildOfClass("Humanoid") or model:FindFirstChildOfClass("AnimationController")) then
		return model
	end
	return nil
end

function Panel:useSelection()
	local model = selectedRig()
	if model then
		self:stop()
		self.rig = model
		return true
	end
	return false
end

function Panel:makeDummy(kind)
	self:stop()
	self:clearNotice()
	local name = "LostCube Dummy " .. kind
	local existing = workspace:FindFirstChild(name) -- the Animations tab makes the same dummies: share them
	if existing and existing:IsA("Model") and existing:FindFirstChildOfClass("Humanoid") then
		self.rig = existing
		self:refresh()
		return
	end
	if self.making then
		return -- one is already on its way
	end
	-- The model is built first: it waits for the web (it yields), and a recording kept open across a yield would
	-- swallow whatever the user edits meanwhile. Only putting it into the place is recorded.
	self.making = true
	local built, model = pcall(function()
		local desc = Instance.new("HumanoidDescription")
		local light, dark = Color3.fromRGB(214, 216, 226), Color3.fromRGB(40, 40, 48)
		desc.HeadColor, desc.LeftArmColor, desc.RightArmColor = light, light, light
		desc.LeftLegColor, desc.RightLegColor, desc.TorsoColor = dark, dark, dark
		-- CreateHumanoidModelFromDescriptionAsync replaces the deprecated name
		local okMethod, method = pcall(function()
			return Players.CreateHumanoidModelFromDescriptionAsync
		end)
		local ok, result
		if okMethod and method then
			ok, result = pcall(method, Players, desc, Enum.HumanoidRigType[kind])
		else
			ok, result = pcall(Players.CreateHumanoidModelFromDescription, Players, desc, Enum.HumanoidRigType[kind])
		end
		desc:Destroy()
		if not (ok and result) then
			error("Nu am putut crea dummy-ul: " .. friendly(result), 0)
		end
		result.Name = name
		local okSpot, spot = pcall(self.Editor.previewTarget)
		local cf = okSpot and typeof(spot) == "CFrame" and spot or CFrame.new(0, 0, 0)
		local root = result:FindFirstChild("HumanoidRootPart")
		local drop = kind == "R15" and (result.Humanoid.HipHeight + root.Size.Y / 2) or 3
		result:PivotTo(cf * CFrame.new(0, drop, 0))
		root.Anchored = true
		return result
	end)
	self.making = false
	if built and self.dead then
		model:Destroy()
		return
	end
	local done, err = built, model
	if built then
		done, err = record("dummy " .. kind, function()
			model.Parent = workspace -- only this goes into the undo step
		end)
		if done then
			self.rig = model
		else
			model:Destroy()
		end
	end
	if not done then
		self:notify(friendly(err), "error")
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

-- the time read-out and the timeline follow the track (every frame while playing)
function Panel:showTime()
	local track = self.track
	local time, length = 0, 0
	if track then
		time, length = track.TimePosition, track.Length
	end
	if self.timeLabel and self.timeLabel.Parent then
		self.timeLabel.Text = self.loading and "Se încarcă…" or string.format("%.2f / %.2f s", time, length)
	end
	if self.timeSet then
		self.timeSet(length > 0 and time / length or 0)
	end
end

function Panel:stop()
	self.gen += 1 -- cancels a load that is still waiting
	if self.conn then
		self.conn:Disconnect()
		self.conn = nil
	end
	local track = self.track
	self.track, self.animator = nil, nil
	if track then
		pcall(function()
			track:Stop(0)
			track:Destroy()
		end)
	end
	if self.seq then
		pcall(self.seq.Destroy, self.seq)
		self.seq = nil
	end
	if self.ownAnimator then -- the rig did not have one: leave it as it was
		pcall(self.ownAnimator.Destroy, self.ownAnimator)
		self.ownAnimator = nil
	end
	self.playing, self.loading = false, false
	self:resetPose()
	self:showTime()
end

-- loads `entry` on the animator and waits until the clip arrives (Length stays 0 until then); returns the track or nil, reason
function Panel:loadTrack(animator, entry, gen)
	local url = AnimLibrary.url(entry.id)
	local function attempt(animationId)
		local anim = Instance.new("Animation")
		anim.AnimationId = animationId
		local ok, track = pcall(animator.LoadAnimation, animator, anim)
		if not (ok and track) then
			return nil, friendly(track)
		end
		local t0 = os.clock()
		while track.Length == 0 and os.clock() - t0 < LOAD_TIMEOUT and self.gen == gen do
			task.wait(0.1)
		end
		if self.gen ~= gen or track.Length == 0 then
			pcall(track.Destroy, track)
			return nil, self.gen ~= gen and "anulat" or "nu a sosit în " .. LOAD_TIMEOUT .. " s"
		end
		return track
	end
	local track, why = attempt(url)
	if track or self.gen ~= gen then
		return track, why
	end
	-- fall back to fetching the KeyframeSequence ourselves: it also tells why an asset cannot be used
	local ok, seq = pcall(KeyframeSequenceProvider.GetKeyframeSequenceAsync, KeyframeSequenceProvider, url)
	if not (ok and seq) then
		return nil, friendly(seq)
	end
	local okReg, hash = pcall(KeyframeSequenceProvider.RegisterKeyframeSequence, KeyframeSequenceProvider, seq)
	if not (okReg and hash) then
		pcall(seq.Destroy, seq)
		return nil, friendly(hash)
	end
	if self.gen ~= gen then
		pcall(seq.Destroy, seq)
		return nil, "anulat"
	end
	self.seq = seq
	return attempt(hash)
end

function Panel:play()
	local entry = self.sel
	if not entry then
		return
	end
	self:clearNotice()
	if not self.rig and not self:useSelection() then
		self:notify("Alege un rig: selectează un personaj sau creează un dummy.", "warning")
		self:refresh()
		return
	end
	local rig = self.rig
	self:stop() -- (also takes away an Animator this panel made for the previous preview)
	local animator, created = animatorOf(rig)
	if not animator then
		self:notify("Rig-ul nu are Humanoid sau AnimationController.", "error")
		self:refresh()
		return
	end
	self.ownAnimator = created and animator or nil
	local gen = self.gen
	self.loading = true
	if rigType(rig) ~= entry.rig and entry.rig ~= "Both" then
		self:notify(string.format("Animația e pentru %s, iar rig-ul e %s: de obicei nu se mișcă pe alt tip de rig.",
			entry.rig, rigType(rig)), "warning")
	end
	self:refresh()
	task.spawn(function()
		local track, why = self:loadTrack(animator, entry, gen)
		if self.gen ~= gen then
			if track then
				pcall(track.Destroy, track)
			end
			return
		end
		self.loading = false
		if not track then
			self:stop() -- (the Animator made for the attempt goes away too)
			self:notify(string.format("Nu am putut încărca animația %s (%s). Verifică conexiunea, proprietarul și dacă rig-ul "
				.. "(%s) se potrivește cu animația (%s).", tostring(entry.id), tostring(why or "?"), rigType(rig), entry.rig), "error")
			self:refresh()
			return
		end
		track.Looped = self.loop
		track:Play(0, 1, self.speed)
		self.track, self.animator, self.playing = track, animator, true
		track.Stopped:Connect(function()
			if self.track == track then -- a clip that ended on its own (not Looped)
				self.playing = false
				self:refresh()
			end
		end)
		self.conn = RunService.Heartbeat:Connect(function(dt)
			if self.track and self.animator then
				if self.timeLabel and not self.timeLabel.Parent then
					self:stop() -- the tab was left: do not keep animating the rig behind another tab
					return
				end
				-- the rig was deleted (undo) or the animator no longer works: stop instead of failing on every frame
				if not (self.rig and self.rig.Parent) or not pcall(self.animator.StepAnimations, self.animator, dt) then
					self:stop()
					self:refresh()
					return
				end
				self:showTime()
			end
		end)
		self:refresh()
	end)
end

function Panel:togglePlay()
	if self.playing then
		if self.track then
			self.track:AdjustSpeed(0)
		end
		self.playing = false
		self:refresh()
	elseif self.track and self.track.IsPlaying then -- paused: continue
		self.track:AdjustSpeed(self.speed)
		self.playing = true
		self:refresh()
	else
		self:play()
	end
end

-- pauses the loaded track at `t` seconds; `final` = false while the timeline is dragged (no redraw then)
function Panel:seek(t, final)
	local track = self.track
	if not (track and self.animator) then
		return
	end
	if not track.IsPlaying then
		track:Play(0, 1, 0)
	end
	track:AdjustSpeed(0)
	self.playing = false
	track.TimePosition = math.clamp(t, 0, math.max(track.Length - 1e-3, 0))
	pcall(self.animator.StepAnimations, self.animator, 0)
	self:showTime()
	if final ~= false then
		self:refresh()
	end
end

function Panel:step(frames)
	if self.track then
		self:seek(self.track.TimePosition + frames / 60)
	end
end

-- ---------------------------------------------------------------------------------------------
-- library: selection, search
-- ---------------------------------------------------------------------------------------------
function Panel:select(entry, play)
	self:clearNotice()
	local running = self.playing or self.loading
	self:stop()
	self.sel = entry
	if entry.kind ~= "custom" then
		self.openGroup = entry.group
	end
	if play or running then
		self:play()
	else
		self:refresh()
	end
end

local function selGroup(entry)
	local group = AnimLibrary.group(entry.group)
	if group then
		return group
	end
	return { key = "custom", label = "ID personalizat", folder = "Custom", kind = "custom", rig = "Both", entries = { entry },
		source = "introdus de tine", verified = "custom" }
end

function Panel:setCustom(text)
	local id = tonumber(tostring(text):match("%d+") or "")
	if not id or id <= 0 then
		self:notify("Scrie un ID de animație: doar cifre sau rbxassetid://123.", "error")
		self:refresh()
		return
	end
	self:select({ key = "custom." .. id, label = "ID " .. id, short = "ID " .. id, id = id, pack = "custom", packLabel = "Personalizat",
		group = "custom", state = "custom", variant = 1, name = "anim" .. id, rig = "Both", kind = "custom", looped = true,
		verified = "custom" })
end

local haystacks = setmetatable({}, { __mode = "k" }) -- entry -> the text a search looks in (made once)
local function haystack(entry, group)
	local text = haystacks[entry]
	if not text then
		text = (group.label .. " " .. entry.key .. " " .. entry.short .. " " .. entry.state .. " " .. entry.rig .. " " .. entry.id
			.. " " .. (group.kind == "pack" and "pachet" or "emote")):lower()
		haystacks[entry] = text
	end
	return text
end

-- groups that pass the kind / rig filters and the search; returns { { group, entries } }, searching
function Panel:visibleGroups()
	local tokens = {}
	for token in self.query:lower():gmatch("%S+") do
		table.insert(tokens, token)
	end
	local out = {}
	for _, group in AnimLibrary.groups() do
		if (self.kind == "all" or self.kind == group.kind) and (self.rigFilter == "all" or group.rig == self.rigFilter) then
			local matched = {}
			for _, entry in group.entries do
				local text = #tokens > 0 and haystack(entry, group)
				local ok = true
				for _, token in tokens do
					if not text:find(token, 1, true) then
						ok = false
						break
					end
				end
				if ok then
					table.insert(matched, entry)
				end
			end
			if #matched > 0 then
				table.insert(out, { group = group, entries = matched })
			end
		end
	end
	return out, #tokens > 0
end

-- keeps the list where it was across the redraw that follows every click
function Panel:keepScroll(list)
	local function track()
		list:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
			self.listY = list.CanvasPosition.Y
		end)
	end
	if self.listY > 0 then
		local y = self.listY
		task.delay(0.05, function()
			if list.Parent then
				list.CanvasPosition = Vector2.new(0, y)
				track()
			end
		end)
	else
		track()
	end
end

-- ---------------------------------------------------------------------------------------------
-- ownership check (live, MarketplaceService)
-- ---------------------------------------------------------------------------------------------
function Panel:fetchOwner(id)
	local cached = self.owner[id]
	if cached then
		return cached
	end
	-- GetProductInfoAsync replaces the deprecated GetProductInfo
	local okMethod, method = pcall(function()
		return MarketplaceService.GetProductInfoAsync
	end)
	local ok, info
	if okMethod and method then
		ok, info = pcall(method, MarketplaceService, id, Enum.InfoType.Asset)
	else
		ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, id, Enum.InfoType.Asset)
	end
	local result
	if ok and type(info) == "table" then
		local creator = info.Creator or {}
		result = { ok = true, name = info.Name, creator = creator.Name or "?", assetType = info.AssetTypeId,
			roblox = creator.Name == "Roblox" or (creator.CreatorType == "User" and creator.CreatorTargetId == 1) }
	else
		result = { ok = false, err = friendly(info) }
	end
	self.owner[id] = result
	return result
end

function Panel:checkOwner(entry)
	self:clearNotice()
	self.owner[entry.id] = nil
	self.checking = "ID " .. entry.id
	self:refresh()
	task.spawn(function()
		self:fetchOwner(entry.id)
		self.checking = nil
		self:refresh()
	end)
end

function Panel:checkGroup(group)
	if self.checking then
		return
	end
	self:clearNotice()
	task.spawn(function()
		local total, good, other, failed = #group.entries, 0, {}, 0
		for i, entry in group.entries do
			if self.dead then
				return -- the plugin was unloaded: no more requests
			end
			self.checking = string.format("%d/%d", i, total)
			self:refresh()
			self.owner[entry.id] = nil
			local info = self:fetchOwner(entry.id)
			if not info.ok then
				failed += 1
			elseif info.roblox and info.assetType == ANIMATION_TYPE then
				good += 1
			else
				table.insert(other, entry.short)
			end
			task.wait(0.1)
		end
		self.checking = nil
		if good == total then
			self:notify(string.format("%s: toate cele %d animații sunt ale Roblox.", group.label, total), "success")
		else
			self:notify(string.format("%s: %d din %d sunt animații Roblox. Neverificate: %d. Altceva: %s.", group.label, good, total,
				failed, #other > 0 and table.concat(other, ", ") or "niciuna"), "warning", { duration = 8 })
		end
		self:refresh()
	end)
end

-- the ownership of an entry as a status: { kind = "success" / "warning" / "danger" / "neutral", label, glyph, detail }
-- (detail: one sentence on what it means, nil when there is nothing to add)
function Panel:ownerStatus(entry)
	if self.checking then
		return { kind = "neutral", label = "Se verifică…", glyph = "refresh" }
	end
	local info = self.owner[entry.id]
	if not info then
		return { kind = "neutral", label = "Neverificat", glyph = "help",
			tip = "Apasă Verifică: Roblox spune cine deține animația" }
	end
	if not info.ok then
		return { kind = "warning", label = "Neverificat", glyph = "info", detail = "Nu am putut verifica: " .. info.err .. "." }
	end
	local what = (info.name and ("„" .. info.name .. "”, ") or "") .. "creator " .. info.creator
	if not info.roblox then
		return { kind = "danger", label = "Alt creator", glyph = "close",
			detail = what .. ". Merge în joc doar dacă e al creatorului jocului." }
	elseif info.assetType == EMOTE_TYPE then
		return { kind = "warning", label = "Emote din catalog", glyph = "info",
			detail = what .. ": emote din catalog (tip 61), nu animație. Poate să nu meargă ca AnimationId." }
	elseif info.assetType ~= ANIMATION_TYPE then
		return { kind = "warning", label = "Nu e animație", glyph = "info", detail = what .. ", tip asset " .. tostring(info.assetType) .. "." }
	end
	return { kind = "success", label = "Roblox", glyph = "check", tip = what .. ": animație Roblox, merge în orice joc" }
end

-- ---------------------------------------------------------------------------------------------
-- into the game
-- ---------------------------------------------------------------------------------------------
function Panel:addToGame(group, entries, what)
	self:clearNotice()
	local count, target = 0, nil
	local done, err = record("animații din bibliotecă: " .. what, function()
		local root = ensureFolder(ReplicatedStorage, "LostCube")
		local folder = ensureFolder(ensureFolder(root, "Animations"), group.folder)
		for _, entry in entries do
			local inst = folder:FindFirstChild(entry.name)
			if inst and not inst:IsA("Animation") then
				inst:Destroy()
				inst = nil
			end
			if not inst then
				inst = Instance.new("Animation")
				inst.Name = entry.name
				inst.Parent = folder
			end
			inst.AnimationId = AnimLibrary.url(entry.id)
			inst:SetAttribute("LC_Pack", group.key)
			count += 1
			target = #entries == 1 and inst or folder
		end
	end)
	if done then
		self:notify(string.format("%d %s în ReplicatedStorage › LostCube › Animations › %s. Ctrl+Z %s.", count,
			count == 1 and "animație adăugată" or "animații adăugate", group.folder, count == 1 and "o scoate" or "le scoate"),
			"success", { action = showAction(target) })
	else
		self:notify(friendly(err), "error")
	end
	self:refresh()
end

-- make a pack the default animation set of every character
function Panel:installDefault(group)
	self:clearNotice()
	local name = AnimLibrary.SCRIPT_NAME
	local source = AnimLibrary.packScript(group.pack)
	local done, err = record("animații implicite: " .. group.label, function()
		local existing = ServerScriptService:FindFirstChild(name)
		if existing and not existing:IsA("Script") then
			error("în ServerScriptService există deja un obiect „" .. name .. "” care nu e Script")
		end
		if existing then
			existing.Source = source
		else
			local created = Instance.new("Script")
			created.Name = name
			created.Source = source -- needs the plugin's script-injection permission; fails before anything is parented
			created.Parent = ServerScriptService
		end
	end)
	if done then
		self:notify(string.format("Personajele noi folosesc „%s”. Scriptul %s e în ServerScriptService.", group.label, name),
			"success", { action = showAction(ServerScriptService:FindFirstChild(name)) })
	else
		self.codeMode = "pack"
		UI.collapsed["lib.code"] = false
		self:notify(string.format("Studio nu a permis scrierea scriptului (%s). Acceptă „Script Injection” pentru LostCube "
			.. "(Plugins › Manage Plugins) sau copiază codul din secțiunea Cod.", friendly(err)), "error", { duration = 12 })
	end
	self:refresh()
end

function Panel:removeDefault()
	self:clearNotice()
	local existing = ServerScriptService:FindFirstChild(AnimLibrary.SCRIPT_NAME)
	if existing then
		local done, err = record("scriptul de animații implicite scos", function()
			existing:Destroy()
		end)
		if done then
			self:notify("Scriptul " .. AnimLibrary.SCRIPT_NAME .. " a fost șters: personajele folosesc iar animațiile standard. "
				.. "Ctrl+Z îl readuce.", "success")
		else
			self:notify(friendly(err), "error")
		end
	end
	self:refresh()
end

-- ---------------------------------------------------------------------------------------------
-- local components (the same as in AnimPanel: rows with badges, split button, rig line, timeline)
-- ---------------------------------------------------------------------------------------------
local PILL = { neutral = { "raised", "textDim" }, accent = { "accentSoft", "accent" }, success = { "successSoft", "success" },
	warning = { "warningSoft", "warning" }, danger = { "dangerSoft", "danger" } }

-- a small pill with an optional glyph: badges in rows (marker count, loop, rig type)
local function pill(parent, text, kind, glyph, tip)
	local colors = PILL[kind or "neutral"] or PILL.neutral
	local frame = UI.make("Frame", { Name = "Badge", Parent = parent, AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 16) }, { UI.corner(8), UI.pad(0, text == "" and 3 or 6, 0, glyph and 3 or 6), UI.hlist(2, false) })
	UI.skin(frame, { BackgroundColor3 = colors[1] })
	if glyph then
		UI.icon(frame, glyph, { size = 12, color = colors[2] })
	end
	if text ~= "" then
		local label = UI.make("TextLabel", UI.textStyle({ Parent = frame, Text = text, BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 16) }, "meta", "Medium"))
		UI.skin(label, { TextColor3 = colors[2] })
	end
	if tip then
		UI.tip(frame, tip)
	end
	return frame
end

local function pillWidth(item)
	return (item.text ~= "" and UI.textWidth(item.text, "meta") + 14 or 6) + (item.glyph and 14 or 0)
end

-- A list row in the look of UI.item with room on the right for badges, a meta text and icon buttons.
-- opts: selected, onClick, height (24), indent, classIcon / icon (glyph) / lead(row) -> instance (16 px column), muted,
-- prefix + prefixWidth (dim text before the name), pills = { { text, kind, glyph, tip } }, meta + metaWidth (dim text on
-- the right), actions = { { icon, tip, onClick, danger, disabled } }, tip
local function listRow(parent, text, opts)
	opts = opts or {}
	local selected = opts.selected == true
	local height = opts.height or UI.H
	local row = UI.make("TextButton", { Name = "Item", Parent = parent, Text = "", AutoButtonColor = false,
		BackgroundTransparency = selected and 0 or 1, Size = UDim2.new(1, 0, 0, height) }, { UI.corner(UI.RADIUS.control) })
	UI.skin(row, { BackgroundColor3 = selected and "accentSoft" or "surfaceHover" })
	row:SetAttribute("Selected", selected)
	if selected then
		local bar = UI.make("Frame", { Name = "Indicator", Parent = row, AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.new(0, 2, 1, -8) }, { UI.corner(1) })
		UI.skin(bar, { BackgroundColor3 = "accent" })
	end
	local x = 8 + (opts.indent or 0)
	if opts.lead or opts.classIcon or opts.icon then
		local lead = opts.lead and opts.lead(row) or UI.icon(row, opts.classIcon or opts.icon, { class = opts.classIcon ~= nil,
			color = selected and "accent" or "textDim" })
		lead.AnchorPoint = Vector2.new(0, 0.5)
		lead.Position = UDim2.new(0, x + (16 - lead.Size.X.Offset) / 2, 0.5, 0)
		if opts.muted and lead:IsA("ImageLabel") then
			lead.ImageTransparency = 0.5
		end
		x += 16 + 8
	end
	if opts.prefix then
		local w = opts.prefixWidth or 40
		UI.label(row, opts.prefix, { role = "meta", dim = true, width = w, height = height }).Position = UDim2.fromOffset(x, 0)
		x += w + 4
	end
	-- the right side: pills, then the meta text, then the actions
	local pills, actions = opts.pills or {}, opts.actions or {}
	local metaW = opts.meta and (opts.metaWidth or 48) or 0
	local rightW, count = 0, 0
	for _, item in pills do
		rightW += pillWidth(item)
		count += 1
	end
	if opts.meta then
		rightW += metaW
		count += 1
	end
	rightW += #actions * UI.H
	count += #actions
	rightW += math.max(0, count - 1) * 6
	if count > 0 then
		local right = UI.make("Frame", { Name = "Right", Parent = row, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -(#actions > 0 and 2 or 8), 0, 0), Size = UDim2.new(0, rightW, 1, 0) },
			{ UI.make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6),
				FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right,
				VerticalAlignment = Enum.VerticalAlignment.Center }) })
		for _, item in pills do
			pill(right, item.text, item.kind, item.glyph, item.tip)
		end
		if opts.meta then
			UI.label(right, opts.meta, { role = "meta", dim = true, width = metaW, height = height, align = Enum.TextXAlignment.Right })
		end
		for _, a in actions do
			UI.iconButton(right, a.icon, a.onClick, { tip = a.tip, danger = a.danger, disabled = a.disabled, active = a.active })
		end
	end
	local name = UI.label(row, text, { role = "body", medium = selected, color = opts.muted and "textDim" or "text", height = height })
	name.Position = UDim2.fromOffset(x, 0)
	name.Size = UDim2.new(1, -(x + rightW + (#actions > 0 and 6 or 12)), 1, 0)
	if opts.onClick then
		row.MouseEnter:Connect(function()
			if not selected then
				row.BackgroundTransparency = 0
			end
		end)
		row.MouseLeave:Connect(function()
			if not selected then
				row.BackgroundTransparency = 1
			end
		end)
		row.MouseButton1Click:Connect(opts.onClick)
	end
	if opts.tip then
		UI.tip(row, opts.tip)
	end
	return row
end

-- one short dim line with an info glyph; the longer explanation is its tooltip
local function helpLine(parent, text, tip)
	local row = UI.make("Frame", { Name = "Help", Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18) })
	UI.icon(row, "info", { size = 14, anchor = Vector2.new(0, 0.5), position = UDim2.new(0, 0, 0.5, 0) })
	local label = UI.label(row, text, { role = "meta", dim = true, height = 18 })
	label.Position = UDim2.fromOffset(20, 0)
	label.Size = UDim2.new(1, -20, 1, 0)
	UI.tip(row, tip)
	return row
end

-- one button with a menu next to it: [ text | v ]. onClick = the main action, onMenu(anchor) opens the choices
local function splitButton(parent, text, onClick, onMenu, opts)
	opts = opts or {}
	local width = opts.width or (UI.textWidth(text, "control") + 16 + UI.H + 2)
	local frame = UI.make("Frame", { Name = "SplitButton", Parent = parent, Size = UDim2.new(0, width, 0, UI.H) },
		{ UI.corner(UI.RADIUS.control), UI.stroke("buttonBorder") })
	UI.skin(frame, { BackgroundColor3 = "button" })
	local function half(name, props)
		props.Name, props.Parent, props.AutoButtonColor, props.BackgroundTransparency = name, frame, false, 1
		local b = UI.make("TextButton", props, { UI.corner(UI.RADIUS.control) })
		UI.skin(b, { BackgroundColor3 = "buttonHover", TextColor3 = "buttonText" })
		b.MouseEnter:Connect(function()
			b.BackgroundTransparency = 0
		end)
		b.MouseLeave:Connect(function()
			b.BackgroundTransparency = 1
		end)
		return b
	end
	local main = half("Main", UI.textStyle({ Text = text, TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, -(UI.H + 1), 1, 0) }, "control"))
	main.MouseButton1Click:Connect(onClick)
	local line = UI.make("Frame", { Name = "Divider", Parent = frame, AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -UI.H, 0.5, 0), Size = UDim2.new(0, 1, 1, -8) })
	UI.skin(line, { BackgroundColor3 = "buttonBorder" })
	local more = half("Menu", { Text = "", AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, UI.H, 1, 0) })
	UI.icon(more, "chevronDown", { size = 12, color = "buttonText", anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.5) })
	more.MouseButton1Click:Connect(function()
		onMenu(frame)
	end)
	if opts.tip then
		UI.tip(main, opts.tip)
	end
	if opts.menuTip then
		UI.tip(more, opts.menuTip)
	end
	return frame
end

-- the rig in use: class icon, name, rig type; the locate button selects it in the Explorer
local function rigLine(parent, rig)
	local row = UI.make("Frame", { Name = "Rig", Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H_LARGE) })
	local hasHumanoid = rig and rig:FindFirstChildOfClass("Humanoid") ~= nil
	local glyph = UI.icon(row, rig and (hasHumanoid and "Humanoid" or "AnimationController") or "Humanoid", { class = true,
		anchor = Vector2.new(0, 0.5), position = UDim2.new(0, 0, 0.5, 0) })
	if not rig then
		glyph.ImageTransparency = 0.5
		UI.label(row, "Niciun rig ales", { dim = true, height = UI.H_LARGE }).Position = UDim2.fromOffset(24, 0)
		return row
	end
	local kind = rigType(rig)
	local right = UI.make("Frame", { Parent = row, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 72, 1, 0) },
		{ UI.make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6),
			FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Center }) })
	pill(right, kind, "neutral", nil, kind == "R15" and "Rig R15 (15 părți)" or "Rig R6 (6 părți)")
	UI.iconButton(right, "locate", function()
		if rig.Parent then
			pcall(Selection.Set, Selection, { rig })
		end
	end, { tip = "Selectează rig-ul în Explorer" })
	local name = UI.label(row, rig.Name, { medium = true, height = UI.H_LARGE })
	name.Position = UDim2.fromOffset(24, 0)
	name.Size = UDim2.new(1, -(24 + 72 + 8), 1, 0)
	return row
end

-- A timeline: the part already played, a knob at the current time, ticks at the keyframes, small diamonds at the
-- markers. Click or drag to seek: onSeek(time, final) (final = false while dragging). Returns the frame and
-- set(fraction) for the per-frame update.
local function timeline(parent, length, fraction, ticks, marks, onSeek)
	local frame = UI.make("TextButton", { Name = "Timeline", Parent = parent, Text = "", AutoButtonColor = false,
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20) })
	local rail = UI.make("Frame", { Name = "Rail", Parent = frame, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 6, 0.5, 2),
		Size = UDim2.new(1, -12, 0, 4) }, { UI.corner(2) })
	UI.skin(rail, { BackgroundColor3 = "switchOff" })
	local played = UI.make("Frame", { Name = "Fill", Parent = rail, Size = UDim2.fromScale(0, 1) }, { UI.corner(2) })
	UI.skin(played, { BackgroundColor3 = "accent" })
	if length > 0 then
		for _, t in ticks do
			local tick = UI.make("Frame", { Name = "Tick", Parent = rail, AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(math.clamp(t / length, 0, 1), 0.5), Size = UDim2.fromOffset(1, 8) })
			UI.skin(tick, { BackgroundColor3 = "textDisabled" })
		end
		for _, t in marks do
			local mark = UI.make("Frame", { Name = "Marker", Parent = rail, AnchorPoint = Vector2.new(0.5, 0.5), Rotation = 45,
				Position = UDim2.new(math.clamp(t / length, 0, 1), 0, 0, -6), Size = UDim2.fromOffset(5, 5) })
			UI.skin(mark, { BackgroundColor3 = "text" })
		end
	end
	local handle = UI.make("Frame", { Name = "Knob", Parent = rail, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(10, 10),
		ZIndex = 2 }, { UI.corner(5), UI.stroke("border") })
	UI.skin(handle, { BackgroundColor3 = "knob" })
	local function set(f)
		f = math.clamp(f or 0, 0, 1)
		played.Size = UDim2.fromScale(f, 1)
		handle.Position = UDim2.fromScale(f, 0.5)
	end
	set(fraction)
	local function at(position)
		local p, size = rail.AbsolutePosition, rail.AbsoluteSize
		return math.clamp((position.X - p.X) / math.max(1, size.X), 0, 1) * length
	end
	frame.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 or length <= 0 then
			return
		end
		local last = at(input.Position)
		set(last / length)
		onSeek(last, false)
		UI.beginDrag(function(position)
			last = at(position)
			set(last / length)
			onSeek(last, false)
		end, function(position)
			if position then
				last = at(position)
			end
			onSeek(last, true)
		end)
	end)
	UI.tip(frame, "Click sau trage ca să mergi la un moment")
	return frame, set
end

-- a read-only, selectable code box (click inside, Ctrl+A, Ctrl+C)
local function codeBox(parent, text)
	local list = UI.scrollList(parent, 220)
	UI.pad(1, 1, 1, 1).Parent = list -- (the border is drawn outside the box: keep it inside the scrolling frame)
	local props = { Parent = list, Text = text, ClearTextOnFocus = false, TextEditable = false, MultiLine = true, TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Size = UDim2.new(1, -6, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }
	UI.textStyle(props, "code")
	local box = UI.make("TextBox", props, { UI.corner(UI.RADIUS.control), UI.stroke("fieldBorder"), UI.pad(6, 8, 6, 8) })
	UI.skin(box, { BackgroundColor3 = "field", TextColor3 = "text" })
	return box
end

-- right-aligned holder for a few controls at the end of a row
local function rightSlot(parent, width)
	return UI.make("Frame", { Name = "Right", Parent = parent, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, width, 1, 0) },
		{ UI.make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2),
			FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Center }) })
end

-- ---------------------------------------------------------------------------------------------
-- render
-- ---------------------------------------------------------------------------------------------
function Panel:renderRig(parent)
	local body = UI.section(parent, "Rig", { key = "lib.rig" })
	rigLine(body, self.rig)
	local bar = UI.make("Frame", { Parent = body, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H) },
		{ UI.hlist(8, false) })
	local splitW = UI.textWidth("Dummy R15", "control") + 16 + UI.H + 2
	UI.button(bar, "Folosește selecția", function()
		self:clearNotice()
		if not self:useSelection() then
			self:notify("Selectează un personaj: un Model cu Humanoid sau AnimationController.", "warning")
		end
		self:refresh()
	end, { tip = "Personajul selectat în Explorer" }).Size = UDim2.new(1, -(splitW + 8), 0, UI.H)
	splitButton(bar, "Dummy " .. self.dummyKind, function()
		self:makeDummy(self.dummyKind)
	end, function(anchor)
		UI.menu(anchor, {
			{ header = true, label = "Dummy nou" },
			{ label = "R15", hint = "15 părți", onClick = function()
				self.dummyKind = "R15"
				self:makeDummy("R15")
			end },
			{ label = "R6", hint = "6 părți", onClick = function()
				self.dummyKind = "R6"
				self:makeDummy("R6")
			end },
		}, { width = 160 })
	end, { width = splitW, tip = "Pune un dummy " .. self.dummyKind .. " în fața camerei (sau îl folosește pe cel existent)",
		menuTip = "Alege R15 sau R6" })
end

-- the rows of the list; refill = rebuilt in place (the search changed while the user types)
function Panel:fillList(list, refill)
	if refill then
		for _, child in list:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end
	local groups, searching = self:visibleGroups()
	local shown, hidden = 0, 0
	for _, item in groups do
		local group = item.group
		local open = searching or self.openGroup == group.key
		listRow(list, group.label, { height = UI.H_LARGE, icon = open and "caretDown" or "caretRight",
			pills = { { text = group.rig, tip = "Pentru rig " .. group.rig },
				{ text = tostring(#item.entries), tip = #item.entries == 1 and "1 animație" or (#item.entries .. " animații") } },
			tip = group.kind == "pack" and "Pachet de animații" or "Emote",
			onClick = not searching and function()
				self.openGroup = not open and group.key or nil
				self:refresh()
			end or nil })
		if open then
			for _, entry in item.entries do
				if shown >= MAX_ROWS then
					hidden += 1
				else
					shown += 1
					listRow(list, entry.short, { indent = 24, selected = self.sel ~= nil and self.sel.key == entry.key,
						tip = "ID " .. tostring(entry.id) .. (entry.looped and " · în buclă" or " · o singură dată"),
						onClick = function()
							self:select(entry)
						end,
						actions = { { icon = "play", tip = "Redă pe rig", onClick = function()
							self:select(entry, true)
						end } } })
				end
			end
		end
	end
	if #groups == 0 then
		UI.empty(list, "Nicio animație nu se potrivește.", nil, nil, { icon = "search" })
	elseif hidden > 0 then
		UI.label(list, string.format("Încă %d animații. Scrie mai mult în căutare.", hidden), { role = "meta", dim = true,
			align = Enum.TextXAlignment.Center })
	end
end

function Panel:renderList(parent)
	local body = UI.section(parent, "Bibliotecă", { key = "lib.list", badge = #AnimLibrary.all() })
	local list
	local _, searchBox = UI.search(body, self.query, function(text)
		self.query = text
		self.queryDraft = nil
		self.listY = 0
		if list and list.Parent then
			self:fillList(list, true)
		end
	end, { placeholder = "Caută: ninja, walk, wave, 656118852" })
	if self.queryDraft then -- typed, not applied yet: a redraw must not wipe it
		searchBox.Text = self.queryDraft
	end
	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		self.queryDraft = searchBox.Text ~= self.query and searchBox.Text or nil
	end)
	local chips = UI.make("Frame", { Name = "Filters", Parent = body, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H) },
		{ UI.hlist(4, false) })
	for _, k in KINDS do
		UI.chip(chips, k.label, { selected = self.kind == k.value, onClick = function()
			self.kind = k.value
			self.listY = 0
			self:refresh()
		end })
	end
	UI.make("Frame", { Parent = chips, BackgroundTransparency = 1, Size = UDim2.fromOffset(4, UI.H) })
	for _, rig in RIGS do
		local on = self.rigFilter == rig
		UI.chip(chips, rig, { selected = on, tip = on and "Arată toate rig-urile" or ("Doar " .. rig), onClick = function()
			self.rigFilter = on and "all" or rig
			self.listY = 0
			self:refresh()
		end })
	end
	list = UI.scrollList(body, 320)
	self:fillList(list)
	self:keepScroll(list)
	if not self.sel then
		helpLine(body, "Animații Roblox: merg gratis în orice joc.", "O animație se redă într-un joc doar dacă e a creatorului "
			.. "jocului sau a Roblox. Alege una ca s-o vezi pe rig.")
	end
end

-- play / pause, frame steps, stop, the time and the timeline; speed and loop (the same bar as in the Animations tab)
function Panel:renderPlayback(body)
	local bar = UI.make("Frame", { Name = "Transport", Parent = body, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H_LARGE) })
	local buttons = UI.make("Frame", { Parent = bar, BackgroundTransparency = 1, Size = UDim2.new(0, 140, 1, 0) }, { UI.hlist(2, false) })
	local ready = self.track ~= nil and not self.loading
	UI.iconButton(buttons, "toStart", function()
		self:seek(0)
	end, { tip = "La început", disabled = not ready })
	UI.iconButton(buttons, "chevronLeft", function()
		self:step(-1)
	end, { tip = "Un cadru înapoi (1/60 s)", disabled = not ready, name = "IconButton_stepBack" })
	UI.button(buttons, "", function()
		if not self.loading then
			self:togglePlay()
		end
	end, { style = "primary", icon = self.playing and "pause" or "play", width = 32, height = UI.H, disabled = self.loading,
		tip = self.loading and "Se încarcă…" or (self.playing and "Pauză" or "Redă pe rig") }).Name = "PlayButton"
	UI.iconButton(buttons, "chevronRight", function()
		self:step(1)
	end, { tip = "Un cadru înainte (1/60 s)", disabled = not ready, name = "IconButton_stepForward" })
	UI.iconButton(buttons, "stop", function()
		self:clearNotice()
		self:stop()
		self:refresh()
	end, { tip = "Oprește și readu poza" })
	local time = self.track and self.track.TimePosition or 0
	local total = self.track and self.track.Length or 0
	self.timeLabel = UI.label(bar, self.loading and "Se încarcă…" or (self.track and string.format("%.2f / %.2f s", time, total)
		or "0.00 s"), { role = "code",
		dim = true, width = 110, height = UI.H_LARGE, align = Enum.TextXAlignment.Right })
	self.timeLabel.AnchorPoint = Vector2.new(1, 0)
	self.timeLabel.Position = UDim2.fromScale(1, 0)
	local _, set = timeline(body, total, total > 0 and time / total or 0, {}, {}, function(t, final)
		self:seek(t, final)
	end)
	self.timeSet = set
	local options = UI.make("Frame", { Parent = body, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H) },
		{ UI.hlist(12, false) })
	UI.segmented(options, SPEEDS, self.speed, function(v)
		self.speed = v
		if self.track and self.playing then
			self.track:AdjustSpeed(v)
		end
		self:refresh()
	end).Size = UDim2.new(1, -92, 0, UI.H)
	UI.toggle(options, self.loop, function(v)
		self.loop = v
		if self.track then
			self.track.Looped = v
		end
		self:refresh()
	end, "Buclă", { width = 80, tip = "Repetă animația" })
end

function Panel:renderSelection(parent)
	local entry = self.sel
	local group = selGroup(entry)
	local body = UI.section(parent, "Animația aleasă", { key = "lib.sel" })

	-- name, pack, rig, loop
	local title = UI.make("Frame", { Name = "Title", Parent = body, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H_LARGE) })
	UI.icon(title, "Animation", { class = true, anchor = Vector2.new(0, 0.5), position = UDim2.new(0, 0, 0.5, 0) })
	local pills = UI.make("Frame", { Parent = title, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 120, 1, 0) },
		{ UI.make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4),
			FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Center }) })
	if entry.rig ~= "Both" then
		pill(pills, entry.rig, "neutral", nil, "Pentru rig " .. entry.rig)
	end
	pill(pills, entry.looped and "Buclă" or "O dată", "neutral", entry.looped and "refresh" or nil,
		entry.looped and "Se repetă singură" or "Se redă o singură dată")
	local name = UI.label(title, entry.short, { role = "emphasis", color = "textBright", height = UI.H_LARGE })
	name.Position = UDim2.fromOffset(24, 0)
	name.Size = UDim2.new(1, -(24 + 128), 1, 0)
	if group.kind ~= "custom" then
		UI.pad(0, 0, 0, 24).Parent = UI.label(body, group.label, { role = "meta", dim = true, height = 14 })
	end

	-- ownership
	local status = self:ownerStatus(entry)
	local owner = UI.make("Frame", { Name = "Owner", Parent = body, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H) })
	UI.label(owner, "Proprietar", { dim = true, width = UI.LABEL_W })
	local badgeHolder = UI.make("Frame", { Parent = owner, BackgroundTransparency = 1, Position = UDim2.fromOffset(UI.LABEL_W + 8, 0),
		Size = UDim2.new(1, -(UI.LABEL_W + 8 + 56), 1, 0) }, { UI.hlist(4, false) })
	pill(badgeHolder, status.label, status.kind, status.glyph, status.tip or status.detail)
	local right = rightSlot(owner, 52)
	UI.iconButton(right, "refresh", function()
		if not self.checking then
			self:checkOwner(entry)
		end
	end, { tip = "Verifică proprietarul (întreabă Roblox)", disabled = self.checking ~= nil })
	UI.iconButton(right, "more", function()
		local anchor = owner
		UI.menu(anchor, {
			{ label = "Verifică tot grupul", hint = tostring(#group.entries), disabled = group.kind == "custom" or #group.entries < 2
				or self.checking ~= nil, onClick = function()
				self:checkGroup(group)
			end },
		}, { width = 200 })
	end, { tip = "Mai multe" })
	if status.detail then
		UI.label(body, status.detail, { role = "meta", color = status.kind == "danger" and "danger" or "warning", wrap = true })
	end
	local idRow = UI.row(body, "ID")
	UI.label(idRow, AnimLibrary.url(entry.id), { role = "code", dim = true })
	UI.tip(idRow, string.format("Sursă: %s · verificat: %s", group.source or "-", VERIFIED[entry.verified] or tostring(entry.verified)))

	-- preview
	UI.spacer(body, 4)
	self:renderPlayback(body)

	-- into the game
	UI.spacer(body, 4)
	local add = UI.make("Frame", { Parent = body, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H_LARGE) },
		{ UI.hlist(4, false) })
	UI.button(add, "Adaugă în joc", function()
		self:addToGame(group, { entry }, entry.label)
	end, { style = "primary", height = UI.H_LARGE,
		tip = "Un Animation în ReplicatedStorage › LostCube › Animations › " .. group.folder .. ". Un singur Ctrl+Z." }).Size =
		UDim2.new(1, -(UI.H_LARGE + 4), 0, UI.H_LARGE)
	UI.iconButton(add, "more", function()
		UI.menu(add, {
			{ label = "Adaugă tot grupul", hint = tostring(#group.entries), disabled = #group.entries < 2, onClick = function()
				self:addToGame(group, group.entries, group.label)
			end },
		}, { width = 200 })
	end, { size = UI.H_LARGE, tip = "Mai multe" })
	if group.kind == "pack" then
		local exists = ServerScriptService:FindFirstChild(AnimLibrary.SCRIPT_NAME) ~= nil
		local row = UI.make("Frame", { Parent = body, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H) },
			{ UI.hlist(4, false) })
		UI.button(row, "Folosește ca implicite", function()
			self:installDefault(group)
		end, { tip = string.format("Scrie scriptul %s în ServerScriptService: personajele %s noi folosesc „%s” (Studio poate cere "
			.. "permisiunea de a scrie scripturi)", AnimLibrary.SCRIPT_NAME, group.rig, group.label) }).Size =
			UDim2.new(1, exists and -(UI.H_LARGE + 4) or 0, 0, UI.H)
		if exists then
			local trash = UI.iconButton(row, "trash", function()
				self:removeDefault()
			end, { danger = true, tip = "Șterge scriptul " .. AnimLibrary.SCRIPT_NAME .. ": revin animațiile standard" })
			trash.Size = UDim2.fromOffset(UI.H_LARGE, UI.H)
		end
	end
end

function Panel:renderCode(parent)
	local entry = self.sel
	local group = selGroup(entry)
	local body = UI.section(parent, "Cod", { key = "lib.code", collapsed = true })
	local mode = (self.codeMode == "pack" and group.kind == "pack") and "pack" or "play"
	if group.kind == "pack" then
		UI.segmented(body, { { value = "play", label = "Redă animația" }, { value = "pack", label = "Script implicite" } },
			mode, function(v)
				self.codeMode = v
				self:refresh()
			end)
	end
	local box = codeBox(body, mode == "pack" and AnimLibrary.packScript(group.pack) or AnimLibrary.snippet(entry))
	local bar = UI.make("Frame", { Parent = body, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H) })
	UI.button(bar, "Selectează tot", function()
		pcall(function()
			box:CaptureFocus()
			box.SelectionStart = 1
			box.CursorPosition = #box.Text + 1
		end)
	end, { style = "ghost", icon = "copy", autoWidth = true, tip = "Apoi Ctrl+C. Dacă nu merge: click în casetă, Ctrl+A, Ctrl+C" })
end

function Panel:render(parent)
	if self.rig and not self.rig.Parent then
		self:stop()
		self.rig = nil
	end
	self.timeLabel, self.timeSet = nil, nil
	self:renderRig(parent)
	self:renderList(parent)
	if self.sel then
		self:renderSelection(parent)
		self:renderCode(parent)
	end

	local body = UI.section(parent, "ID personalizat", { key = "lib.custom", collapsed = true })
	local row = UI.hstack(body)
	local box = UI.textbox(row, "", nil, { placeholder = "ID sau rbxassetid://…" })
	box.Text = self.customDraft or "" -- what was typed survives a redraw
	box:GetPropertyChangedSignal("Text"):Connect(function()
		self.customDraft = box.Text
	end)
	UI.tip(box, "Încearcă orice animație (și vezi cine o deține) înainte s-o folosești")
	UI.button(row, "Alege", function()
		self.customDraft = nil
		self:setCustom(box.Text)
	end, { width = 64 })

	local about = UI.section(parent, "Despre bibliotecă", { key = "lib.about", collapsed = true })
	UI.label(about, "O animație se poate reda într-un joc doar dacă e a creatorului jocului sau a Roblox. Cele de aici sunt "
		.. "făcute de Roblox (animațiile implicite, pachetele din catalog și emote-urile din Animate), deci merg gratis în orice "
		.. "joc. ID-urile sunt confirmate din cel puțin două surse; Verifică întreabă Roblox live.", { dim = true, wrap = true })
	UI.label(about, "Atacuri și mișcări proprii se generează în tab-ul Animații.", { dim = true, wrap = true })
end

function Panel:destroy()
	self.dead = true -- the ownership check loop and a dummy on its way stop
	self:stop()
end

return Panel
