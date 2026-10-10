-- LostCube > animation library (data): free animations that are OWNED BY ROBLOX, so they play in any experience
-- (an animation asset only plays in a game if the game's creator or Roblox owns it).
--   PACKS   - character animation packs: the defaults (R15 / R6 / classic) and Roblox's catalog packs
--   EMOTES  - wave / point / cheer / laugh / dances of the default Animate scripts
-- Every id was cross-checked in at least two independent sources (see plugin/docs/animation-sources.md; the
-- Roblox web APIs were not reachable while collecting, so no entry is marked "api"). Anything uncertain is NOT here.
local AnimLibrary = {}

local DOCS = "Roblox Creator Docs (animation/using) + liste comunitare"
local STUDIO = "Animate implicit (copie rbxmx) + BTRoblox + Avatar Settings (Roblox)"
local CLIENT = "Scripturile Animate din clientul Roblox (4 copii)"
local CLASSIC = "humanoidClassicAnimate + R15 Migrator (Roblox)"
local R6SRC = "Animate R6: Roblox/gear + client Roblox + copie rbxmx"

-- the states of a pack, in display order
AnimLibrary.STATES = { "idle", "walk", "run", "jump", "fall", "climb", "swim", "swimidle", "sit", "toolnone", "toolslash", "toollunge" }

AnimLibrary.STATE_LABELS = {
	idle = "Repaus (idle)",
	walk = "Mers (walk)",
	run = "Alergare (run)",
	jump = "Săritură (jump)",
	fall = "Cădere (fall)",
	climb = "Cățărare (climb)",
	swim = "Înot (swim)",
	swimidle = "Înot pe loc (swimidle)",
	sit = "Așezat (sit)",
	toolnone = "Unealtă ținută (toolnone)",
	toolslash = "Unealtă, lovitură (toolslash)",
	toollunge = "Unealtă, împunsătură (toollunge)",
}

-- state -> where the default `Animate` LocalScript keeps it: character.Animate.<folder>.<names[variant]>
-- (the idle folder holds Animation1 / Animation2 / Animation3, each with a `Weight` NumberValue)
AnimLibrary.ANIMATE = {
	idle = { folder = "idle", names = { "Animation1", "Animation2", "Animation3" } },
	walk = { folder = "walk", names = { "WalkAnim" } },
	run = { folder = "run", names = { "RunAnim" } },
	jump = { folder = "jump", names = { "JumpAnim" } },
	fall = { folder = "fall", names = { "FallAnim" } },
	climb = { folder = "climb", names = { "ClimbAnim" } },
	swim = { folder = "swim", names = { "Swim" } },
	swimidle = { folder = "swimidle", names = { "SwimIdle" } },
	sit = { folder = "sit", names = { "SitAnim" } },
	toolnone = { folder = "toolnone", names = { "ToolNoneAnim" } },
	toolslash = { folder = "toolslash", names = { "ToolSlashAnim" } },
	toollunge = { folder = "toollunge", names = { "ToolLungeAnim" } },
}

-- states that do not loop on their own
local ONE_SHOT = { jump = true, toolslash = true, toollunge = true }

-- ---------------------------------------------------------------------------------------------
-- packs. anims: idle = { main, second, third? } (the first one plays most often), the others are one id each.
-- ---------------------------------------------------------------------------------------------
AnimLibrary.DEFAULT_R15 = {
	key = "default_r15", label = "Implicit R15 (Studio)", folder = "Default_R15", rig = "R15", source = STUDIO,
	verified = "2-sources",
	anims = {
		idle = { 507766388, 507766666 }, walk = 913402848, run = 913376220, jump = 507765000, fall = 507767968,
		climb = 507765644, swim = 913384386, swimidle = 913389285, sit = 2506281703, toolnone = 507768375,
		toolslash = 522635514, toollunge = 522638767,
	},
}

AnimLibrary.DEFAULT_R6 = {
	key = "default_r6", label = "Implicit R6 (Studio)", folder = "Default_R6", rig = "R6", source = R6SRC,
	verified = "2-sources",
	anims = {
		idle = { 180435571, 180435792 }, walk = 180426354, run = 180426354, jump = 125750702, fall = 180436148,
		climb = 180436334, sit = 178130996, toolnone = 182393478, toolslash = 129967390, toollunge = 129967478,
	},
}

AnimLibrary.PACKS = {
	AnimLibrary.DEFAULT_R15,
	AnimLibrary.DEFAULT_R6,
	{
		key = "classic_r15", label = "Clasic pe R15 (stil R6)", folder = "Classic_R15", rig = "R15", source = CLASSIC,
		verified = "2-sources",
		anims = {
			idle = { 12521158637, 12521162526 }, walk = 12518152696, run = 12518152696, jump = 12520880485,
			fall = 12520972571, climb = 12520982150, sit = 12520993168, toolnone = 12520996634, toolslash = 12520999032,
			toollunge = 12521002003,
		},
	},
	{
		key = "legacy_r15", label = "R15 vechi (original)", folder = "Legacy_R15", rig = "R15", source = CLIENT,
		verified = "2-sources",
		anims = {
			idle = { 507766388, 507766951, 507766666 }, walk = 507777826, run = 507767714, jump = 507765000,
			fall = 507767968, climb = 507765644, swim = 507784897, swimidle = 507785072, sit = 2506281703,
			toolnone = 507768375, toolslash = 522635514, toollunge = 522638767,
		},
	},
	{
		key = "astronaut", label = "Astronaut", rig = "R15", bundle = 34, source = DOCS, verified = "2-sources",
		anims = { idle = { 891621366, 891633237, 1047759695 }, walk = 891667138, run = 891636393, jump = 891627522,
			fall = 891617961, climb = 891609353, swim = 891639666, swimidle = 891663592 },
	},
	{
		key = "bubbly", label = "Bubbly", rig = "R15", bundle = 39, source = DOCS, verified = "2-sources",
		anims = { idle = { 910004836, 910009958, 1018536639 }, walk = 910034870, run = 910025107, jump = 910016857,
			fall = 910001910, climb = 909997997, swim = 910028158, swimidle = 910030921 },
	},
	{
		key = "cartoony", label = "Cartoony", rig = "R15", bundle = 56, source = DOCS, verified = "2-sources",
		anims = { idle = { 742637544, 742638445, 885477856 }, walk = 742640026, run = 742638842, jump = 742637942,
			fall = 742637151, climb = 742636889, swim = 742639220, swimidle = 742639812 },
	},
	{
		key = "elder", label = "Elder", rig = "R15", bundle = 48, source = DOCS, verified = "2-sources",
		anims = { idle = { 845397899, 845400520, 901160519 }, walk = 845403856, run = 845386501, jump = 845398858,
			fall = 845396048, climb = 845392038, swim = 845401742, swimidle = 845403127 },
	},
	{
		key = "knight", label = "Knight", rig = "R15", bundle = 68, source = DOCS, verified = "2-sources",
		anims = { idle = { 657595757, 657568135, 885499184 }, walk = 657552124, run = 657564596, jump = 658409194,
			fall = 657600338, climb = 658360781, swim = 657560551, swimidle = 657557095 },
	},
	{
		key = "levitation", label = "Levitation", rig = "R15", bundle = 79, source = DOCS, verified = "2-sources",
		anims = { idle = { 616006778, 616008087, 886862142 }, walk = 616013216, run = 616010382, jump = 616008936,
			fall = 616005863, climb = 616003713, swim = 616011509, swimidle = 616012453 },
	},
	{
		key = "mage", label = "Mage", rig = "R15", bundle = 63, source = DOCS, verified = "2-sources",
		anims = { idle = { 707742142, 707855907, 885508740 }, walk = 707897309, run = 707861613, jump = 707853694,
			fall = 707829716, climb = 707826056, swim = 707876443, swimidle = 707894699 },
	},
	{
		key = "ninja", label = "Ninja", rig = "R15", bundle = 75, source = DOCS, verified = "2-sources",
		anims = { idle = { 656117400, 656118341, 886742569 }, walk = 656121766, run = 656118852, jump = 656117878,
			fall = 656115606, climb = 656114359, swim = 656119721, swimidle = 656121397 },
	},
	{
		key = "pirate", label = "Pirate", rig = "R15", bundle = 55, source = DOCS, verified = "2-sources",
		anims = { idle = { 750781874, 750782770, 885515365 }, walk = 750785693, run = 750783738, jump = 750782230,
			fall = 750780242, climb = 750779899, swim = 750784579, swimidle = 750785176 },
	},
	{
		key = "robot", label = "Robot", rig = "R15", bundle = 82, source = DOCS, verified = "2-sources",
		anims = { idle = { 616088211, 616089559, 885531463 }, walk = 616095330, run = 616091570, jump = 616090535,
			fall = 616087089, climb = 616086039, swim = 616092998, swimidle = 616094091 },
	},
	{
		key = "rthro", label = "Rthro", rig = "R15", bundle = 356, source = DOCS, verified = "2-sources",
		anims = { idle = { 2510196951, 2510197257, 3711062489 }, walk = 2510202577, run = 2510198475, jump = 2510197830,
			fall = 2510195892, climb = 2510192778, swim = 2510199791, swimidle = 2510201162 },
	},
	{
		key = "stylish", label = "Stylish", rig = "R15", bundle = 83, source = DOCS, verified = "2-sources",
		anims = { idle = { 616136790, 616138447, 886888594 }, walk = 616146177, run = 616140816, jump = 616139451,
			fall = 616134815, climb = 616133594, swim = 616143378, swimidle = 616144772 },
	},
	{
		key = "superhero", label = "Superhero", rig = "R15", bundle = 81, source = DOCS, verified = "2-sources",
		anims = { idle = { 616111295, 616113536, 885535855 }, walk = 616122287, run = 616117076, jump = 616115533,
			fall = 616108001, climb = 616104706, swim = 616119360, swimidle = 616120861 },
	},
	{
		key = "toy", label = "Toy", rig = "R15", bundle = 43, source = DOCS, verified = "2-sources",
		anims = { idle = { 782841498, 782845736, 980952228 }, walk = 782843345, run = 782842708, jump = 782847020,
			fall = 782846423, climb = 782843869, swim = 782844582, swimidle = 782845186 },
	},
	{
		key = "vampire", label = "Vampire", rig = "R15", bundle = 33, source = DOCS, verified = "2-sources",
		anims = { idle = { 1083445855, 1083450166, 1088037547 }, walk = 1083473930, run = 1083462077, jump = 1083455352,
			fall = 1083443587, climb = 1083439238, swim = 1083464683, swimidle = 1083467779 },
	},
	{
		key = "werewolf", label = "Werewolf", rig = "R15", bundle = 32, source = DOCS, verified = "2-sources",
		anims = { idle = { 1083195517, 1083214717, 1099492820 }, walk = 1083178339, run = 1083216690, jump = 1083218792,
			fall = 1083189019, climb = 1083182000, swim = 1083222527, swimidle = 1083225406 },
	},
	{
		key = "zombie", label = "Zombie", rig = "R15", bundle = 80, source = DOCS, verified = "2-sources",
		anims = { idle = { 616158929, 616160636, 885545458 }, walk = 616168032, run = 616163682, jump = 616161997,
			fall = 616157476, climb = 616156119, swim = 616165109, swimidle = 616166655 },
	},
}

-- ---------------------------------------------------------------------------------------------
-- emotes: the ones the default Animate scripts play (/e wave, /e dance, ...). One set per rig flavour.
-- ---------------------------------------------------------------------------------------------
AnimLibrary.EMOTE_GROUPS = {
	{ key = "emote_r15", label = "Emote R15 (Studio)", folder = "Emote_R15", rig = "R15", source = STUDIO, verified = "2-sources" },
	{ key = "emote_r6", label = "Emote R6 (Studio)", folder = "Emote_R6", rig = "R6", source = R6SRC, verified = "2-sources" },
	{ key = "emote_classic", label = "Emote clasice pe R15", folder = "Emote_Classic_R15", rig = "R15", source = CLASSIC,
		verified = "2-sources" },
}

-- group, name, label, id, looped. Dances come in three variants (A/B/C) that the Animate script picks at random.
local EMOTE_DATA = {
	{ "emote_r15", "wave", "Salut (wave)", 507770239, false },
	{ "emote_r15", "point", "Arată cu degetul (point)", 507770453, false },
	{ "emote_r15", "cheer", "Bucurie (cheer)", 507770677, false },
	{ "emote_r15", "laugh", "Râs (laugh)", 507770818, false },
	{ "emote_r15", "dance1a", "Dans 1 · A", 507771019, true },
	{ "emote_r15", "dance1b", "Dans 1 · B", 507771955, true },
	{ "emote_r15", "dance1c", "Dans 1 · C", 507772104, true },
	{ "emote_r15", "dance2a", "Dans 2 · A", 507776043, true },
	{ "emote_r15", "dance2b", "Dans 2 · B", 507776720, true },
	{ "emote_r15", "dance2c", "Dans 2 · C", 507776879, true },
	{ "emote_r15", "dance3a", "Dans 3 · A", 507777268, true },
	{ "emote_r15", "dance3b", "Dans 3 · B", 507777451, true },
	{ "emote_r15", "dance3c", "Dans 3 · C", 507777623, true },

	{ "emote_r6", "wave", "Salut (wave)", 128777973, false },
	{ "emote_r6", "point", "Arată cu degetul (point)", 128853357, false },
	{ "emote_r6", "cheer", "Bucurie (cheer)", 129423030, false },
	{ "emote_r6", "laugh", "Râs (laugh)", 129423131, false },
	{ "emote_r6", "dance1a", "Dans 1 · A", 182435998, true },
	{ "emote_r6", "dance1b", "Dans 1 · B", 182491037, true },
	{ "emote_r6", "dance1c", "Dans 1 · C", 182491065, true },
	{ "emote_r6", "dance2a", "Dans 2 · A", 182436842, true },
	{ "emote_r6", "dance2b", "Dans 2 · B", 182491248, true },
	{ "emote_r6", "dance2c", "Dans 2 · C", 182491277, true },
	{ "emote_r6", "dance3a", "Dans 3 · A", 182436935, true },
	{ "emote_r6", "dance3b", "Dans 3 · B", 182491368, true },
	{ "emote_r6", "dance3c", "Dans 3 · C", 182491423, true },

	{ "emote_classic", "wave", "Salut (wave)", 12521004586, false },
	{ "emote_classic", "point", "Arată cu degetul (point)", 12521007694, false },
	{ "emote_classic", "cheer", "Bucurie (cheer)", 12521021991, false },
	{ "emote_classic", "laugh", "Râs (laugh)", 12521018724, false },
	{ "emote_classic", "dance1a", "Dans 1 · A", 12521009666, true },
	{ "emote_classic", "dance1b", "Dans 1 · B", 12521151637, true },
	{ "emote_classic", "dance1c", "Dans 1 · C", 12521015053, true },
	{ "emote_classic", "dance2a", "Dans 2 · A", 12521169800, true },
	{ "emote_classic", "dance2b", "Dans 2 · B", 12521173533, true },
	{ "emote_classic", "dance2c", "Dans 2 · C", 12521027874, true },
	{ "emote_classic", "dance3a", "Dans 3 · A", 12521178362, true },
	{ "emote_classic", "dance3b", "Dans 3 · B", 12521181508, true },
	{ "emote_classic", "dance3c", "Dans 3 · C", 12521184133, true },
}

local function emoteGroup(key)
	for _, g in AnimLibrary.EMOTE_GROUPS do
		if g.key == key then
			return g
		end
	end
	return nil
end

AnimLibrary.EMOTES = {}
for _, row in EMOTE_DATA do
	local group = emoteGroup(row[1])
	table.insert(AnimLibrary.EMOTES, {
		key = row[1] .. "." .. row[2], name = row[2], label = row[3], id = row[4], looped = row[5], rig = group.rig,
		group = group.key, verified = group.verified,
	})
end

-- ---------------------------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------------------------
function AnimLibrary.url(id)
	return "rbxassetid://" .. tostring(id)
end

-- the animations of a pack in display order: { { name = "idle1", state = "idle", variant = 1, id = ... }, ... }
function AnimLibrary.statesOf(pack)
	local out = {}
	for _, state in AnimLibrary.STATES do
		local value = pack.anims[state]
		if type(value) == "table" then
			for variant, id in value do
				table.insert(out, { name = state .. variant, state = state, variant = variant, id = id })
			end
		elseif value then
			table.insert(out, { name = state, state = state, variant = 1, id = value })
		end
	end
	return out
end

local cachedGroups

-- every group (packs first, then emote sets) with its entries:
--   { key, label, folder, rig, kind = "pack" | "emote", source, verified, pack = <PACKS entry> | nil, entries = { entry } }
--   entry = { key, label, short, id, pack (group key), packLabel, state, variant, rig, kind, looped, verified, group, name }
-- The result is built once and shared: do not modify it.
function AnimLibrary.groups()
	if cachedGroups then
		return cachedGroups
	end
	local groups = {}
	for _, pack in AnimLibrary.PACKS do
		local group = { key = pack.key, label = pack.label, folder = pack.folder or pack.label, rig = pack.rig, kind = "pack",
			source = pack.source, verified = pack.verified, bundle = pack.bundle, pack = pack, entries = {} }
		for _, item in AnimLibrary.statesOf(pack) do
			local stateLabel = AnimLibrary.STATE_LABELS[item.state] or item.state
			local variants = type(pack.anims[item.state]) == "table" and #pack.anims[item.state] or 1
			local short = variants > 1 and (stateLabel .. " " .. item.variant) or stateLabel
			table.insert(group.entries, {
				key = pack.key .. "." .. item.name, label = pack.label .. " · " .. short, short = short, id = item.id,
				pack = pack.key, packLabel = pack.label, group = pack.key, state = item.state, variant = item.variant,
				name = item.name, rig = pack.rig, kind = "pack", looped = not ONE_SHOT[item.state], verified = pack.verified,
			})
		end
		table.insert(groups, group)
	end
	for _, eg in AnimLibrary.EMOTE_GROUPS do
		local group = { key = eg.key, label = eg.label, folder = eg.folder, rig = eg.rig, kind = "emote", source = eg.source,
			verified = eg.verified, entries = {} }
		for _, e in AnimLibrary.EMOTES do
			if e.group == eg.key then
				table.insert(group.entries, {
					key = e.key, label = eg.label .. " · " .. e.label, short = e.label, id = e.id, pack = eg.key,
					packLabel = eg.label, group = eg.key, state = e.name, variant = 1, name = e.name, rig = e.rig,
					kind = "emote", looped = e.looped, verified = e.verified,
				})
			end
		end
		table.insert(groups, group)
	end
	cachedGroups = groups
	return groups
end

local cachedAll

-- flat list of every animation: { key, label, id, pack, state, rig, ... } (same entries as in groups())
function AnimLibrary.all()
	if cachedAll then
		return cachedAll
	end
	local list = {}
	for _, group in AnimLibrary.groups() do
		for _, entry in group.entries do
			table.insert(list, entry)
		end
	end
	cachedAll = list
	return list
end

function AnimLibrary.find(key)
	for _, entry in AnimLibrary.all() do
		if entry.key == key then
			return entry
		end
	end
	return nil
end

function AnimLibrary.group(key)
	for _, group in AnimLibrary.groups() do
		if group.key == key then
			return group
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------------------------
-- generated code (shown to / written for the user, so the comments inside it are in Romanian)
-- ---------------------------------------------------------------------------------------------
AnimLibrary.SCRIPT_NAME = "LostCubeAnimationPack"

-- A server Script that makes a pack the default animations of every character: on CharacterAdded it waits for the
-- character's `Animate` LocalScript and rewrites the AnimationId of its Animation children (the documented way:
-- Animate.<folder>.<child>, e.g. Animate.walk.WalkAnim - see AnimLibrary.ANIMATE). `pack` is an entry of PACKS.
function AnimLibrary.packScript(pack)
	local lines = {}
	local function add(text)
		table.insert(lines, text)
	end
	add("-- Generat de LostCube (tab-ul Bibliotecă): animațiile implicite ale personajelor = „" .. pack.label .. "”.")
	add("-- Toate id-urile sunt animații deținute de Roblox, deci merg în orice joc.")
	add("-- Șterge acest Script ca să revii la animațiile standard.")
	add("local Players = game:GetService(\"Players\")")
	add("")
	add("local RIG = \"" .. pack.rig .. "\" -- pachetul se aplică doar personajelor de acest tip")
	add("")
	add("-- dosarul din scriptul Animate -> { numele Animation-ului = id }")
	add("local PACK = {")
	for _, state in AnimLibrary.STATES do
		local value = pack.anims[state]
		local info = AnimLibrary.ANIMATE[state]
		if value then
			local parts = {}
			if type(value) == "table" then
				for i, id in value do
					table.insert(parts, info.names[i] .. " = " .. id)
				end
			else
				table.insert(parts, info.names[1] .. " = " .. value)
			end
			add("\t" .. info.folder .. " = { " .. table.concat(parts, ", ") .. " },")
		end
	end
	add("}")
	add("")
	add("-- cât de des se joacă fiecare idle (primul cel mai des)")
	add("local IDLE_WEIGHTS = { Animation1 = 9, Animation2 = 1, Animation3 = 1 }")
	add("")
	add("local function child(parent, name, class)")
	add("\tlocal found = parent:FindFirstChild(name)")
	add("\tif found and found:IsA(class) then")
	add("\t\treturn found")
	add("\tend")
	add("\tif found then")
	add("\t\tfound:Destroy()")
	add("\tend")
	add("\tfound = Instance.new(class)")
	add("\tfound.Name = name")
	add("\tfound.Parent = parent")
	add("\treturn found")
	add("end")
	add("")
	add("local function isApplied(animate)")
	add("\tfor folderName, anims in PACK do")
	add("\t\tlocal folder = animate:FindFirstChild(folderName)")
	add("\t\tif not folder then")
	add("\t\t\treturn false")
	add("\t\tend")
	add("\t\tfor animName, id in anims do")
	add("\t\t\tlocal anim = folder:FindFirstChild(animName)")
	add("\t\t\tif not (anim and anim:IsA(\"Animation\") and anim.AnimationId == \"rbxassetid://\" .. id) then")
	add("\t\t\t\treturn false")
	add("\t\t\tend")
	add("\t\tend")
	add("\tend")
	add("\treturn true")
	add("end")
	add("")
	add("local function apply(character)")
	add("\tlocal humanoid = character:WaitForChild(\"Humanoid\", 15)")
	add("\tlocal animate = character:WaitForChild(\"Animate\", 15)")
	add("\tif not humanoid or not animate or humanoid.RigType.Name ~= RIG or isApplied(animate) then")
	add("\t\treturn")
	add("\tend")
	add("")
	add("\t-- oprește animațiile care rulează, ca în documentația Roblox")
	add("\tlocal animator = humanoid:FindFirstChildOfClass(\"Animator\")")
	add("\tif animator then")
	add("\t\tfor _, track in animator:GetPlayingAnimationTracks() do")
	add("\t\t\ttrack:Stop(0)")
	add("\t\tend")
	add("\tend")
	add("")
	add("\tfor folderName, anims in PACK do")
	add("\t\tlocal folder = child(animate, folderName, \"StringValue\")")
	add("\t\tfor animName, id in anims do")
	add("\t\t\tlocal anim = child(folder, animName, \"Animation\")")
	add("\t\t\tanim.AnimationId = \"rbxassetid://\" .. id")
	add("\t\t\tif folderName == \"idle\" then")
	add("\t\t\t\tchild(anim, \"Weight\", \"NumberValue\").Value = IDLE_WEIGHTS[animName] or 1")
	add("\t\t\tend")
	add("\t\tend")
	add("\t\tif folderName == \"idle\" then")
	add("\t\t\tfor _, extra in folder:GetChildren() do -- variantele idle care nu sunt în pachet")
	add("\t\t\t\tif extra:IsA(\"Animation\") and not anims[extra.Name] then")
	add("\t\t\t\t\textra:Destroy()")
	add("\t\t\t\tend")
	add("\t\t\tend")
	add("\t\tend")
	add("\tend")
	add("end")
	add("")
	add("local function onPlayer(player)")
	add("\tif player.Character then")
	add("\t\ttask.spawn(apply, player.Character)")
	add("\tend")
	add("\tplayer.CharacterAdded:Connect(function(character)")
	add("\t\tapply(character)")
	add("\tend)")
	add("\tplayer.CharacterAppearanceLoaded:Connect(function(character)")
	add("\t\tapply(character)")
	add("\tend)")
	add("end")
	add("")
	add("Players.PlayerAdded:Connect(onPlayer)")
	add("for _, player in Players:GetPlayers() do")
	add("\ttask.spawn(onPlayer, player)")
	add("end")
	add("")
	return table.concat(lines, "\n")
end

-- the snippet that plays an entry on a character (`character` is any Model with a Humanoid)
function AnimLibrary.snippet(entry)
	local lines = {
		"-- " .. entry.label .. " (animație deținută de Roblox: merge în orice joc)",
		"local anim = Instance.new(\"Animation\")",
		"anim.AnimationId = \"" .. AnimLibrary.url(entry.id) .. "\"",
		"",
		"local humanoid = character:WaitForChild(\"Humanoid\")",
		"local track = humanoid:WaitForChild(\"Animator\"):LoadAnimation(anim)",
		"track.Looped = " .. tostring(entry.looped ~= false),
		"track:Play()",
		"-- track:Stop()",
	}
	return table.concat(lines, "\n")
end

return AnimLibrary
