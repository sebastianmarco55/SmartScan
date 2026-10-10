-- AnimLibrary: the data (every pack / emote entry is well formed, keys and ids are sane), the generated "default
-- animations" Script of every pack (it compiles and, run on a fake character, rewrites the Animate script with exactly
-- the pack's ids; wrong rig type: untouched; a spare third idle is removed) and the snippets.
local LC = ...
local t = LC.kit.new("anim_library")
local eq, has, check = t.eq, t.has, t.check

local tree = LC.modtree.new{}
local Lib = tree.load("AnimLibrary")

-- ---------------------------------------------------------------- data
t.section("data", function()
	check(#Lib.PACKS >= 17, "at least 17 packs, got " .. #Lib.PACKS)
	local packKeys = {}
	for _, pack in Lib.PACKS do
		check(type(pack.key) == "string" and pack.key ~= "", "pack key")
		check(not packKeys[pack.key], "duplicate pack key " .. tostring(pack.key))
		packKeys[pack.key] = true
		check(type(pack.label) == "string" and pack.label ~= "", pack.key .. ": label")
		check(pack.rig == "R15" or pack.rig == "R6", pack.key .. ": rig " .. tostring(pack.rig))
		check(type(pack.anims) == "table", pack.key .. ": anims")
		check(pack.anims.idle ~= nil and pack.anims.walk ~= nil, pack.key .. ": idle and walk exist")
		for state, value in pack.anims do
			check(Lib.ANIMATE[state] ~= nil, pack.key .. ": unknown state " .. tostring(state))
			local ids = type(value) == "table" and value or { value }
			if type(value) == "table" then
				check(#value <= #Lib.ANIMATE[state].names, pack.key .. "." .. state .. ": more variants than the Animate script has")
			end
			for _, id in ids do
				check(type(id) == "number" and id > 0 and id == math.floor(id), pack.key .. "." .. state .. ": id " .. tostring(id))
			end
		end
	end

	local keys, count = {}, 0
	for _, group in Lib.groups() do
		check(#group.entries > 0, group.key .. ": has entries")
		check(group.kind == "pack" or group.kind == "emote", group.key .. ": kind")
		for _, e in group.entries do
			count += 1
			check(type(e.key) == "string" and not keys[e.key], "unique entry key " .. tostring(e.key))
			keys[e.key] = true
			check(type(e.id) == "number" and e.id > 0, e.key .. ": id")
			check(e.label and e.short and e.state and e.rig and e.pack and e.name, e.key .. ": fields")
			check(Lib.find(e.key) == e, e.key .. ": find returns the same entry")
			check(Lib.url(e.id) == "rbxassetid://" .. e.id, e.key .. ": url")
			check(e.rig == group.rig, e.key .. ": entry rig = group rig")
			if e.kind == "pack" then -- jump and the tool actions play once, every other state loops
				local oneShot = e.state == "jump" or e.state == "toolslash" or e.state == "toollunge"
				eq(e.key .. ": looped flag", e.looped, not oneShot)
			end
		end
	end
	eq("all() lists every entry of every group", #Lib.all(), count)
	check(Lib.find("ninja.walk") ~= nil and Lib.find("ninja.walk").id == 656121766, "ninja walk id")
	check(Lib.find("no.such.key") == nil, "find: unknown key")
	check(Lib.group("ninja") ~= nil and Lib.group("nope") == nil, "group lookup")
	check(#Lib.EMOTES >= 39, "39 emotes, got " .. #Lib.EMOTES)
	for _, state in Lib.STATES do
		check(Lib.STATE_LABELS[state] ~= nil, "label of state " .. state)
		check(Lib.ANIMATE[state] ~= nil, "Animate mapping of state " .. state)
	end
end)

-- ---------------------------------------------------------------- snippets
t.section("snippets", function()
	for _, e in Lib.all() do
		local snippet = Lib.snippet(e)
		has(e.key .. ": snippet has the asset id", snippet, "rbxassetid://" .. e.id)
		has(e.key .. ": snippet looped flag", snippet, "track.Looped = " .. tostring(e.looped ~= false))
		check(loadstring(snippet) ~= nil, e.key .. ": snippet is valid Luau")
	end
end)

-- ---------------------------------------------------------------- generated packs, run on a fake character
-- a minimal Instance mock: just what the generated Script touches
local Inst = {}
Inst.__index = function(self, k)
	local m = rawget(Inst, k)
	if m then
		return m
	end
	return self._props[k]
end
local function new(class, name)
	local o = setmetatable({}, Inst)
	rawset(o, "_props", { ClassName = class, Name = name or class })
	rawset(o, "_kids", {})
	rawset(o, "_parent", false)
	return o
end
Inst.__newindex = function(self, k, v)
	if k == "Parent" then
		if self._parent then
			for i, c in self._parent._kids do
				if c == self then
					table.remove(self._parent._kids, i)
					break
				end
			end
		end
		rawset(self, "_parent", v or false)
		if v then
			table.insert(v._kids, self)
		end
	else
		self._props[k] = v
	end
end
function Inst.FindFirstChild(self, name)
	for _, c in self._kids do
		if c._props.Name == name then
			return c
		end
	end
	return nil
end
function Inst.IsA(self, class)
	return self._props.ClassName == class
end
function Inst.Destroy(self)
	self.Parent = nil
end
function Inst.GetChildren(self)
	return table.clone(self._kids)
end
function Inst.FindFirstChildOfClass(self, class)
	for _, c in self._kids do
		if c._props.ClassName == class then
			return c
		end
	end
	return nil
end
function Inst.WaitForChild(self, name)
	return Inst.FindFirstChild(self, name)
end

local stopped = 0
local function character(rigName, defaults)
	local char = new("Model", "Character")
	local hum = new("Humanoid", "Humanoid")
	hum.RigType = { Name = rigName }
	hum.Parent = char
	local animator = new("Animator", "Animator")
	animator.Parent = hum
	function animator.GetPlayingAnimationTracks()
		return { { Stop = function() stopped += 1 end } }
	end
	local animate = new("LocalScript", "Animate")
	animate.Parent = char
	for folderName, anims in defaults do
		local f = new("StringValue", folderName)
		f.Parent = animate
		for name, id in anims do
			local a = new("Animation", name)
			a.AnimationId = "rbxassetid://" .. id
			a.Parent = f
			if folderName == "idle" then
				local w = new("NumberValue", "Weight")
				w.Value = 5
				w.Parent = a
			end
		end
	end
	-- a spare third idle that a two-idle pack must remove
	local extra = new("Animation", "Animation3")
	extra.AnimationId = "rbxassetid://1"
	extra.Parent = animate:FindFirstChild("idle")
	return char, animate
end

local function run(pack, rigName)
	local player = { Character = nil }
	local callbacks = {}
	player.CharacterAdded = { Connect = function(_, f) table.insert(callbacks, f) end }
	player.CharacterAppearanceLoaded = { Connect = function(_, f) table.insert(callbacks, f) end }
	local players = {
		PlayerAdded = { Connect = function() end },
		GetPlayers = function() return { player } end,
	}
	local old = {
		idle = { Animation1 = 507766388, Animation2 = 507766666 }, walk = { WalkAnim = 1 }, run = { RunAnim = 2 },
		jump = { JumpAnim = 3 }, fall = { FallAnim = 4 }, climb = { ClimbAnim = 5 }, swim = { Swim = 6 },
		swimidle = { SwimIdle = 7 },
	}
	local char, animate = character(rigName, old)
	player.Character = char
	local fn, err = loadstring(Lib.packScript(pack), "@pack:" .. pack.key)
	if not fn then
		t.fail(pack.key .. ": the generated script does not compile: " .. tostring(err))
		return animate
	end
	setfenv(fn, LC.env{
		game = { GetService = function() return players end },
		Instance = { new = function(class) return new(class) end },
		task = { spawn = function(f, ...) return f(...) end },
	})
	fn()
	for _, f in callbacks do -- CharacterAdded + AppearanceLoaded: applying twice must be harmless
		f(char)
	end
	return animate
end

t.section("generated pack scripts", function()
	for _, pack in Lib.PACKS do
		has(pack.key .. ": script names the pack", Lib.packScript(pack), pack.label)
		stopped = 0
		local animate = run(pack, pack.rig)
		for _, item in Lib.statesOf(pack) do
			local info = Lib.ANIMATE[item.state]
			local folder = animate:FindFirstChild(info.folder)
			local anim = folder and folder:FindFirstChild(info.names[item.variant])
			eq(pack.key .. ": " .. item.name .. " applied", anim and anim.AnimationId, "rbxassetid://" .. item.id)
		end
		-- idle: exactly the pack's variants (the spare Animation3 of a 2-idle pack is gone)
		local idle = animate:FindFirstChild("idle")
		local variants = type(pack.anims.idle) == "table" and #pack.anims.idle or 1
		for i, name in Lib.ANIMATE.idle.names do
			eq(pack.key .. ": idle " .. name .. (i <= variants and " kept" or " removed"), idle:FindFirstChild(name) ~= nil, i <= variants)
		end
		local weight = idle:FindFirstChild("Animation1"):FindFirstChild("Weight")
		eq(pack.key .. ": main idle plays most often", weight and weight.Value, 9)
		eq(pack.key .. ": the playing tracks are stopped once", stopped, 1)

		-- a character of the other rig type is left alone
		stopped = 0
		local other = pack.rig == "R15" and "R6" or "R15"
		local untouched = run(pack, other)
		eq(pack.key .. ": " .. other .. " character untouched (walk)", untouched:FindFirstChild("walk"):FindFirstChild("WalkAnim").AnimationId, "rbxassetid://1")
		eq(pack.key .. ": " .. other .. " character untouched (tracks)", stopped, 0)
	end
end)

t.finish()
