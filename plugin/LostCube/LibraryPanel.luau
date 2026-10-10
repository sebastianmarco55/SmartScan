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
local C = UI.C

local Panel = {}
Panel.__index = Panel

local KINDS = {
	{ value = "pack", label = "Pachete" },
	{ value = "emote", label = "Emote" },
	{ value = "all", label = "Toate" },
}
local RIGS = {
	{ value = "all", label = "Toate" },
	{ value = "R15", label = "R15" },
	{ value = "R6", label = "R6" },
}
local SPEEDS = {
	{ value = 0.5, label = "×0.5" },
	{ value = 1, label = "×1" },
	{ value = 2, label = "×2" },
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
		rig = nil, speed = 1, loop = true, gen = 0, owner = {}, codeMode = "play", listY = 0,
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

function Panel:notify(text, color)
	self.notice = { text = text, color = color or C.warn }
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
			error("nu am putut crea dummy-ul: " .. friendly(result), 0)
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
		self:notify("⚠ " .. friendly(err))
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
		self:notify("Alege un rig: selectează un personaj (Model cu Humanoid) sau creează un dummy mai jos.")
		self:refresh()
		return
	end
	local rig = self.rig
	self:stop() -- (also takes away an Animator this panel made for the previous preview)
	local animator, created = animatorOf(rig)
	if not animator then
		self:notify("⚠ Rig-ul nu are Humanoid sau AnimationController.")
		self:refresh()
		return
	end
	self.ownAnimator = created and animator or nil
	local gen = self.gen
	self.loading = true
	if rigType(rig) ~= entry.rig and entry.rig ~= "Both" then
		self:notify(string.format("Atenție: animația e pentru %s, iar rig-ul e %s. De obicei nu se mișcă pe un rig diferit.",
			entry.rig, rigType(rig)))
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
			self:notify(string.format("⚠ Nu am putut încărca animația %s (%s). Verifică conexiunea, că ID-ul e deținut de Roblox "
				.. "(butonul „Verifică proprietarul”) și că rig-ul (%s) se potrivește cu animația (%s).", tostring(entry.id),
				tostring(why or "?"), rigType(rig), entry.rig))
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
				if self.timeLabel and self.timeLabel.Parent then
					self.timeLabel.Text = string.format("%.2f / %.2f s", self.track.TimePosition, self.track.Length)
				end
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
		self:notify("⚠ Scrie un ID de animație (doar cifre, sau rbxassetid://123).")
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
			self.checking = string.format("%s %d/%d", group.label, i, total)
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
			self:notify(string.format("✓ %s: toate cele %d animații sunt deținute de Roblox (verificat live).", group.label, total), C.good)
		else
			self:notify(string.format("%s: %d din %d verificate OK; nu au putut fi verificate: %d; altceva decât animație Roblox: %s",
				group.label, good, total, failed, #other > 0 and table.concat(other, ", ") or "-"), C.warn)
		end
		self:refresh()
	end)
end

-- text + color of the ownership line for an entry
function Panel:ownerLine(entry)
	local info = self.owner[entry.id]
	if not info then
		return "Proprietar: neverificat live (apasă „Verifică proprietarul”)", C.dim
	end
	if not info.ok then
		return "⚠ Nu am putut verifica: " .. info.err, C.warn
	end
	local label = (info.name and ("„" .. info.name .. "” · ") or "") .. "creator " .. info.creator
	if not info.roblox then
		return "✗ " .. label .. ". Nu e al Roblox: merge în joc doar dacă e al creatorului jocului.", C.danger
	elseif info.assetType == EMOTE_TYPE then
		return "⚠ " .. label .. ", dar e un emote din catalog (tip 61), nu o animație: poate să nu meargă ca AnimationId.", C.warn
	elseif info.assetType ~= ANIMATION_TYPE then
		return "⚠ " .. label .. " · tip asset " .. tostring(info.assetType) .. " (nu e animație).", C.warn
	end
	return "✓ " .. label .. " · animație deținută de Roblox, merge în orice joc.", C.good
end

-- ---------------------------------------------------------------------------------------------
-- into the game
-- ---------------------------------------------------------------------------------------------
function Panel:addToGame(group, entries, what)
	self:clearNotice()
	local count = 0
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
		end
	end)
	if done then
		self:notify(string.format("✓ %d animații în ReplicatedStorage › LostCube › Animations › %s (un singur Ctrl+Z le scoate).",
			count, group.folder), C.good)
	else
		self:notify("⚠ " .. friendly(err))
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
		self:notify(string.format("✓ Script „%s” în ServerScriptService: personajele noi folosesc pachetul „%s”. Șterge-l ca să "
			.. "revii la cele standard.", name, group.label), C.good)
	else
		self.codeMode = "pack"
		self:notify(string.format("⚠ Studio nu a lăsat pluginul să scrie codul scriptului (%s). Acceptă permisiunea „Script "
			.. "Injection” pentru LostCube (Plugins → Manage Plugins) și încearcă din nou, sau creează tu un Script în "
			.. "ServerScriptService și lipește codul din secțiunea „Cod” (l-am pus acolo).", friendly(err)))
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
			self:notify("✓ Scriptul „" .. AnimLibrary.SCRIPT_NAME .. "” a fost șters: personajele folosesc iar animațiile standard.",
				C.good)
		else
			self:notify("⚠ " .. friendly(err))
		end
	end
	self:refresh()
end

-- ---------------------------------------------------------------------------------------------
-- render
-- ---------------------------------------------------------------------------------------------
-- a read-only, selectable code box (click inside, Ctrl+A, Ctrl+C)
local function codeBox(parent, text)
	local list = UI.scrollList(parent, 220)
	return UI.make("TextBox", { Parent = list, Text = text, Font = Enum.Font.Code, TextSize = 12, TextColor3 = C.text,
		BackgroundColor3 = C.input, ClearTextOnFocus = false, TextEditable = false, MultiLine = true, TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Size = UDim2.new(1, -6, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.corner(4), UI.stroke(C.border), UI.pad(4, 6, 4, 6) })
end

function Panel:renderRig(parent)
	local body = UI.section(parent, "Rig de previzualizare", { key = "lib.rig" })
	UI.label(body, self.rig and (self.rig.Name .. "  (" .. rigType(self.rig) .. ")") or "Niciun rig ales", { medium = true })
	UI.button(UI.hstack(body), "Folosește personajul selectat", function()
		self:clearNotice()
		if not self:useSelection() then
			self:notify("Selectează un personaj (Model cu Humanoid sau AnimationController).")
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
end

function Panel:renderList(parent)
	local groups, searching = self:visibleGroups()
	local packs, emotes = 0, 0
	for _, g in AnimLibrary.groups() do
		if g.kind == "pack" then
			packs += 1
		else
			emotes += #g.entries
		end
	end
	local body = UI.section(parent, string.format("Bibliotecă  (%d pachete · %d emote)", packs, emotes), { key = "lib.list" })

	local bar = UI.hstack(body)
	local searchBox = UI.textbox(bar, self.query, function(text)
		self.query = text
		self.queryDraft = nil
		self.listY = 0
		self:refresh()
	end, { placeholder = "caută: ninja, walk, wave, 656118852…" })
	if self.queryDraft then -- typed, not applied yet: a redraw must not wipe it (it is applied when the box loses focus)
		searchBox.Text = self.queryDraft
	end
	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		self.queryDraft = searchBox.Text
	end)
	if self.query ~= "" then
		UI.button(bar, "✕", function()
			self.query = ""
			self.queryDraft = nil
			self.listY = 0
			self:refresh()
		end, { width = 26 })
	end
	UI.segmented(UI.row(body, "Tip"), KINDS, self.kind, function(v)
		self.kind = v
		self.listY = 0
		self:refresh()
	end)
	UI.segmented(UI.row(body, "Rig"), RIGS, self.rigFilter, function(v)
		self.rigFilter = v
		self.listY = 0
		self:refresh()
	end)

	local list = UI.scrollList(body, 320)
	local shown, hidden = 0, 0
	for _, item in groups do
		local group = item.group
		local open = searching or self.openGroup == group.key
		if searching then
			UI.label(list, group.label .. "  ·  " .. group.rig, { dim = true, size = 11, height = 18 })
		else
			UI.item(list, group.label, { icon = open and "▼" or "►", selected = open, note = #group.entries .. " · " .. group.rig,
				onClick = function()
					self.openGroup = not open and group.key or nil
					self:refresh()
				end })
		end
		if open then
			for _, entry in item.entries do
				if shown >= MAX_ROWS then
					hidden += 1
				else
					shown += 1
					UI.item(list, entry.short, { icon = "•", height = 24, selected = self.sel ~= nil and self.sel.key == entry.key,
						note = tostring(entry.id), onClick = function()
							self:select(entry)
						end, actions = { { text = "▶", color = C.accent, onClick = function()
							self:select(entry, true)
						end } } })
				end
			end
		end
	end
	if #groups == 0 then
		UI.note(list, "Nicio animație nu se potrivește cu căutarea / filtrele.")
	elseif hidden > 0 then
		UI.note(list, string.format("… încă %d animații; scrie mai mult în căutare ca să le restrângi.", hidden))
	end
	self:keepScroll(list)
	if not self.sel then
		UI.label(body, "Alege o animație și apasă ▶ ca s-o vezi pe rig. Sunt animații Roblox: gratis în orice joc.",
			{ dim = true, size = 11, wrap = true })
	end
end

function Panel:renderSelection(parent)
	local entry = self.sel
	local group = selGroup(entry)
	local body = UI.section(parent, "Animația aleasă", { key = "lib.sel" })
	UI.label(body, entry.label, { medium = true })
	UI.label(body, string.format("%s  ·  %s  ·  %s", AnimLibrary.url(entry.id), entry.rig, entry.looped and "în buclă" or "o singură dată"),
		{ dim = true, size = 11 })
	UI.label(body, string.format("Sursă: %s  ·  verificat: %s", group.source or "-", VERIFIED[entry.verified] or tostring(entry.verified)),
		{ dim = true, size = 11, wrap = true })
	local text, color = self:ownerLine(entry)
	UI.label(body, text, { color = color, size = 12, wrap = true })

	-- playback
	local controls = UI.hstack(body, { height = 28 })
	UI.button(controls, self.loading and "Se încarcă…" or (self.playing and "⏸ Pauză" or "▶  Redă"), function()
		if not self.loading then
			self:togglePlay()
		end
	end, { style = "primary", bold = true, height = 28 })
	UI.button(controls, "⏹", function()
		self:clearNotice()
		self:stop()
		self:refresh()
	end, { width = 30, height = 28 })
	self.timeLabel = UI.label(body, self.track and string.format("%.2f / %.2f s", self.track.TimePosition, self.track.Length) or "-",
		{ dim = true, size = 12 })
	UI.segmented(UI.row(body, "Viteză"), SPEEDS, self.speed, function(v)
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

	-- ownership
	local check = UI.hstack(body)
	UI.button(check, self.checking and ("Se verifică " .. self.checking .. "…") or "Verifică proprietarul", function()
		if not self.checking then
			self:checkOwner(entry)
		end
	end, { tip = "Întreabă Roblox cine deține animația (MarketplaceService:GetProductInfo)" })
	if group.kind ~= "custom" and #group.entries > 1 then
		UI.button(check, "Verifică tot grupul", function()
			self:checkGroup(group)
		end, { tip = "Verifică live fiecare animație din „" .. group.label .. "”" })
	end

	-- into the game
	body = UI.section(parent, "Adaugă în joc", { key = "lib.add" })
	local add = UI.hstack(body)
	UI.button(add, "+ Animația aleasă", function()
		self:addToGame(group, { entry }, entry.label)
	end)
	if #group.entries > 1 then
		UI.button(add, "+ Tot grupul (" .. #group.entries .. ")", function()
			self:addToGame(group, group.entries, group.label)
		end)
	end
	UI.label(body, "Creează obiecte Animation în ReplicatedStorage › LostCube › Animations › " .. group.folder
		.. ". Un singur Ctrl+Z.", { dim = true, size = 11, wrap = true })

	-- default animations of the characters
	if group.kind == "pack" then
		body = UI.section(parent, "Animații implicite ale personajelor", { key = "lib.default" })
		local exists = ServerScriptService:FindFirstChild(AnimLibrary.SCRIPT_NAME) ~= nil
		local row = UI.hstack(body, { height = 28 })
		UI.button(row, "Folosește „" .. group.label .. "” ca animații implicite", function()
			self:installDefault(group)
		end, { style = "primary", bold = true, height = 28 })
		if exists then
			UI.button(row, "Elimină", function()
				self:removeDefault()
			end, { width = 70, height = 28, style = "danger" })
		end
		UI.label(body, string.format("Scrie un Script „%s” în ServerScriptService: când apare un personaj %s, înlocuiește animațiile "
			.. "din scriptul lui Animate (walk/WalkAnim, run/RunAnim, jump/JumpAnim, fall/FallAnim, climb/ClimbAnim, swim/Swim, "
			.. "swimidle/SwimIdle, idle/Animation1-3). Studio poate cere permisiunea de a scrie scripturi.",
			AnimLibrary.SCRIPT_NAME, group.rig), { dim = true, size = 11, wrap = true })
	end

	-- code
	body = UI.section(parent, "Cod", { key = "lib.code" })
	local mode = (self.codeMode == "pack" and group.kind == "pack") and "pack" or "play"
	if group.kind == "pack" then
		UI.segmented(body, { { value = "play", label = "Redă animația" }, { value = "pack", label = "Script animații implicite" } },
			mode, function(v)
				self.codeMode = v
				self:refresh()
			end)
	end
	local box = codeBox(body, mode == "pack" and AnimLibrary.packScript(group.pack) or AnimLibrary.snippet(entry))
	UI.button(UI.hstack(body), "Selectează tot", function()
		pcall(function()
			box:CaptureFocus()
			box.SelectionStart = 1
			box.CursorPosition = #box.Text + 1
		end)
	end, { tip = "Apoi Ctrl+C. Dacă nu merge: click în casetă, Ctrl+A, Ctrl+C" })
	UI.label(body, "Click în casetă, Ctrl+A, Ctrl+C. Animațiile Roblox merg în orice joc; atacuri personalizate faci în tab-ul Animații.",
		{ dim = true, size = 11, wrap = true })
end

function Panel:render(parent)
	if self.rig and not self.rig.Parent then
		self:stop()
		self.rig = nil
	end
	if self.notice then
		UI.note(parent, self.notice.text, self.notice.color)
	end

	local about = UI.section(parent, "Despre bibliotecă", { key = "lib.about", collapsed = true })
	UI.label(about, "O animație se poate reda într-un joc doar dacă aparține creatorului jocului sau Roblox. Cele de aici sunt "
		.. "făcute de Roblox (animațiile implicite, pachetele din catalog și emote-urile din Animate), deci merg gratis în orice joc. "
		.. "ID-urile au fost confirmate din cel puțin două surse; „Verifică proprietarul” întreabă Roblox live.",
		{ dim = true, size = 12, wrap = true })
	UI.label(about, "Atacuri și mișcări personalizate se generează în tab-ul Animații.", { dim = true, size = 12, wrap = true })

	self:renderRig(parent)
	self:renderList(parent)
	if self.sel then
		self:renderSelection(parent)
	end

	local body = UI.section(parent, "ID personalizat", { key = "lib.custom", collapsed = true })
	local row = UI.hstack(body)
	local box = UI.textbox(row, "", nil, { placeholder = "ID sau rbxassetid://…" })
	box.Text = self.customDraft or "" -- what was typed survives a redraw
	box:GetPropertyChangedSignal("Text"):Connect(function()
		self.customDraft = box.Text
	end)
	UI.button(row, "Alege", function()
		self.customDraft = nil
		self:setCustom(box.Text)
	end, { width = 60 })
	UI.label(body, "Încearcă orice animație (și vezi cine o deține) înainte s-o folosești.", { dim = true, size = 11, wrap = true })
end

function Panel:destroy()
	self.dead = true -- the ownership check loop and a dummy on its way stop
	self:stop()
end

return Panel
