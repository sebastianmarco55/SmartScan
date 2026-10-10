--[[ LostCube Analyzer - the plugin gets to know the game it is in.
The first time LostCube opens in a place it scans the whole game (yielding, so Studio never freezes, even on places
with 100k+ instances and thousands of scripts) and remembers the result IN the place, in
ServerStorage.LostCubeAnalysis (saved with the place, never replicated to players):
	Report   StringValue  the report as JSON (a very big one continues in Report2, Report3...)
	Context  StringValue  the same as compact Markdown for an LLM (Claude reads it through Studio MCP)
	AI       StringValue  Claude's analysis (Markdown), attributes Model and At
	attributes Version, At (os.time), Chunks

	local Analyzer = require(script.Parent.Analyzer)
	local report = Analyzer.load() or Analyzer.run(function(fraction, label) print(fraction, label) end)
	print(Analyzer.context(report))                              -- Markdown, most important first (~15000 chars)
	local findings = Analyzer.scanInstance(workspace.FreeModel)  -- backdoors, obfuscation, hidden purchases...
Analyzer.load() decodes the stored JSON once and hands out the same table until the stored analysis changes (a new
analysis, Ctrl+Z, the folder deleted...): treat it as READ-ONLY, or table.clone it first. Analyzer.context(loadedReport)
is kept too. Analyzer.isStale never walks the game itself; it counts in the background (see there).

A finding / issue: { severity = "high" | "medium" | "low", kind = "security.require", path = "Workspace.X.Script",
line = 12?, message = "..." }. Everything is a heuristic over names, properties and source text (nothing is run).
User-facing text is Romanian.
]]
local HttpService = game:GetService("HttpService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Analyzer = {}
Analyzer.VERSION = 1
Analyzer.FOLDER = "LostCubeAnalysis"
Analyzer.running = false -- true while Analyzer.run is scanning

Analyzer.SEVERITY_LABEL = { high = "mare", medium = "medie", low = "mică" }
-- issue kind prefix ("security" in "security.require") -> label
Analyzer.KIND_LABEL = {
	security = "securitate", remote = "remote-uri", data = "date", market = "monetizare", rules = "reguli Roblox",
	perf = "performanță", anim = "animații", code = "cod", ui = "interfață", structure = "structură",
	deprecated = "cod învechit",
}

local STALE_AFTER = 7 * 24 * 3600 -- a report older than this is stale
local FRAME_BUDGET = 0.012 -- seconds of work per frame before yielding
local CHUNK = 100000 -- characters per StringValue
local MAX_PER_KIND = 25 -- issues of one kind kept in the report (the rest is summed up)
local RANK = { high = 1, medium = 2, low = 3 }
local KIND_ORDER = { security = 1, remote = 2, data = 3, market = 4, rules = 5, perf = 6, anim = 7, code = 8, ui = 9,
	structure = 10, deprecated = 11 }

-- where a game's content lives (everything else is Studio / engine internals)
local SERVICES = { "Workspace", "ReplicatedFirst", "ReplicatedStorage", "ServerScriptService", "ServerStorage", "StarterGui",
	"StarterPack", "StarterPlayer", "Lighting", "SoundService", "Teams", "Chat", "TextChatService", "MaterialService",
	"LocalizationService", "TestService" }

-- ---------------------------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------------------------
local function set(list)
	local t = {}
	for _, v in list do
		t[v] = true
	end
	return t
end

local function wordSet(text)
	return set(string.split(text, " "))
end

local function round(x, decimals)
	if type(x) ~= "number" then
		return x
	end
	if x ~= x or x == math.huge or x == -math.huge then
		return 0
	end
	local m = 10 ^ (decimals or 0)
	return math.floor(x * m + 0.5) / m
end

local function int(x)
	return tostring(math.floor((tonumber(x) or 0) + 0.5))
end

local function bump(t, key, n)
	t[key] = (t[key] or 0) + (n or 1)
end

local function count(map)
	local n = 0
	for _ in map do
		n += 1
	end
	return n
end

-- { key = number } -> { { [kName] = key, [vName] = number } }, biggest first, at most n
local function top(map, n, kName, vName)
	local list = {}
	for k, v in map do
		table.insert(list, { k, v })
	end
	table.sort(list, function(a, b)
		if a[2] ~= b[2] then
			return a[2] > b[2]
		end
		return tostring(a[1]) < tostring(b[1])
	end)
	local out = {}
	for i = 1, math.min(n, #list) do
		out[i] = { [kName] = list[i][1], [vName] = list[i][2] }
	end
	return out
end

local function sortedKeys(map, n)
	local list = {}
	for k in map do
		table.insert(list, tostring(k))
	end
	table.sort(list)
	if n and #list > n then
		list = table.move(list, 1, n, 1, {})
	end
	return list
end

-- a property that may not exist / may not be readable from a plugin
local function prop(inst, key)
	local ok, v = pcall(function()
		return inst[key]
	end)
	if ok then
		return v
	end
	return nil
end

local function enumName(v)
	return typeof(v) == "EnumItem" and v.Name or nil
end

local function hexOf(c)
	return typeof(c) == "Color3" and c:ToHex():upper() or nil
end

local function fullName(inst)
	local ok, name = pcall(inst.GetFullName, inst)
	return ok and name or tostring(inst)
end

-- full name -> instance of the last scan (weak), so the panel can jump to what a finding points at
local paths = setmetatable({}, { __mode = "v" })
local function pathOf(inst)
	local p = fullName(inst)
	paths[p] = inst
	return p
end

local function findService(name)
	local ok, service = pcall(game.FindService, game, name)
	if ok and service then
		return service
	end
	return nil
end

local function children(inst)
	local ok, list = pcall(inst.GetChildren, inst)
	return ok and list or {}
end

-- yields once this frame's work budget is used up, so the scan never freezes Studio
local lastYield = os.clock()
local function breathe()
	if os.clock() - lastYield > FRAME_BUDGET and coroutine.isyieldable() then
		task.wait()
		lastYield = os.clock()
	end
end

-- top-level children the scan leaves out: the camera (LostCube previews live there) and LostCube's own folders
-- (ReplicatedStorage.LostCube, ServerStorage.LostCubeSession / LostCubeAnalysis, "LostCube Dummy" rigs)
local function skipTop(child)
	if child:IsA("Camera") then
		return true
	end
	return string.sub(child.Name, 1, 8) == "LostCube"
end

-- "KillBrick" / "M1Attack" / "HTTPService" -> { "kill", "brick" } / { "m1", "attack" } / { "http", "service" }
local function tokens(name)
	local s = string.gsub(name, "(%l)(%u)", "%1 %2")
	s = string.gsub(s, "(%u)(%u%l)", "%1 %2")
	s = string.gsub(s, "(%d)(%a)", "%1 %2")
	local out = {}
	for w in string.gmatch(string.lower(s), "[%a%d]+") do
		table.insert(out, w)
	end
	return out
end

local function matchWord(words, token)
	if words[token] then
		return true
	end
	-- plurals: "pets" -> "pet", "enemies" stays (listed)
	return #token > 3 and string.sub(token, -1) == "s" and words[string.sub(token, 1, -2)] == true
end

-- ---------------------------------------------------------------------------------------------
-- source text helpers (positions are kept: comments become spaces, so line numbers stay right)
-- ---------------------------------------------------------------------------------------------
local function blank(s)
	return (string.gsub(s, "[^\n]", " "))
end

local SPACES = {}
for i = 1, 200 do
	SPACES[i] = string.rep(" ", i)
end

local function stripComments(src)
	local at = string.find(src, "--", 1, true)
	if not at then
		return src
	end
	if string.find(src, "--[", 1, true) then -- a long comment starts with "--[" (plain find: most scripts have none)
		src = string.gsub(src, "(%-%-%[(=*)%[.-%]%2%])", blank)
		at = string.find(src, "--", 1, true)
	end
	-- a line comment (up to the newline) becomes as many spaces; the rest of the text is copied as it is
	local out, n, pos = {}, 0, 1
	while at do
		local stop = string.find(src, "\n", at, true) or (#src + 1)
		out[n + 1] = string.sub(src, pos, at - 1)
		out[n + 2] = SPACES[stop - at] or string.rep(" ", stop - at)
		n += 2
		pos = stop
		at = string.find(src, "--", pos, true)
	end
	out[n + 1] = string.sub(src, pos)
	return table.concat(out)
end

-- line start offsets (+ the longest line, a sign of obfuscated / minified code)
local function lineIndex(src)
	local starts = { 1 }
	local longest, longestLine = 0, 1
	local pos = 1
	while true do
		local nl = string.find(src, "\n", pos, true)
		local len = (nl or (#src + 1)) - pos
		if len > longest then
			longest, longestLine = len, #starts
		end
		if not nl then
			break
		end
		pos = nl + 1
		starts[#starts + 1] = pos
	end
	return starts, longest, longestLine
end

local function lineOf(starts, pos)
	if not pos then
		return nil
	end
	local lo, hi = 1, #starts
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		if starts[mid] <= pos then
			lo = mid
		else
			hi = mid - 1
		end
	end
	return lo
end

local function lineText(text, starts, i)
	local nextStart = starts[i + 1]
	return string.sub(text, starts[i], nextStart and nextStart - 2 or #text)
end

-- the block that starts on line `first`, by indentation: it ends at the next line indented the same or less
local function blockText(text, starts, first, maxLines)
	local head = lineText(text, starts, first)
	local indent = #string.match(head, "^[ \t]*")
	local out = { head }
	for i = first + 1, math.min(#starts, first + maxLines) do
		local l = lineText(text, starts, i)
		local lead = string.match(l, "^[ \t]*")
		if string.find(l, "%S") and #lead <= indent then
			local rest = string.sub(l, #lead + 1)
			if string.find(rest, "^end") or string.find(rest, "^[%)}]") then
				table.insert(out, l)
			end
			break
		end
		table.insert(out, l)
	end
	return table.concat(out, "\n")
end

-- The plain text a pattern starts with (after an optional leading %f[%w_] and one-character class): "wait%s*%(" ->
-- "wait", "Knit%.CreateService" -> "Knit.CreateService", "[Hh]umanoid" -> "umanoid" (lead = 1 character before it).
-- Looking for that text first (a plain find) and trying the pattern only there gives exactly the same matches much
-- faster: a pattern would be tried at every single character of the script.
local startCache = {}
local function startsWith(pattern)
	local info = startCache[pattern]
	if info == nil then
		info = false
		local body = pattern
		if string.sub(body, 1, 7) == "%f[%w_]" then
			body = string.sub(body, 8)
		end
		local lead = 0
		local close = string.find(body, "]", 2, true)
		if string.sub(body, 1, 1) == "[" and close and close > 2 and string.sub(body, 2, 2) ~= "^"
			and string.sub(body, close - 1, close - 1) ~= "%" and not string.find(string.sub(body, close + 1, close + 1), "[%*%?%-%+]") then
			lead, body = 1, string.sub(body, close + 1) -- the class matches one character, right before the text
		end
		local chars, i = {}, 1
		while i <= #body do
			local ch, step = string.sub(body, i, i), 1
			if ch == "%" then
				ch, step = string.sub(body, i + 1, i + 1), 2
				if ch == "" or string.find(ch, "%w") then -- %s, %a, %f, %1…: a class, not text
					break
				end
			elseif string.find(ch, "[%^%$%(%)%.%[%]%*%+%-%?]") then
				break
			end
			local quantifier = string.sub(body, i + step, i + step) -- it makes the character optional / repeated
			if quantifier == "*" or quantifier == "?" or quantifier == "-" then
				break
			end
			table.insert(chars, ch)
			if quantifier == "+" then
				break
			end
			i += step
		end
		if #chars >= 3 then
			info = { lit = table.concat(chars), anchored = "^" .. pattern, lead = lead }
		end
		startCache[pattern] = info
	end
	return info
end

-- string.find(code, pattern, init) for patterns with at most one capture
local function findPattern(code, pattern, init)
	local info = startsWith(pattern)
	if not info then
		local p, e, capture = string.find(code, pattern, init)
		return p, e, capture
	end
	init = init or 1
	local lead = info.lead
	while true do
		local at = string.find(code, info.lit, init + lead, true)
		if not at then
			return nil
		end
		local p, e, capture = string.find(code, info.anchored, at - lead)
		if p then
			return p, e, capture
		end
		init = at - lead + 1
	end
end

-- string.gmatch(code, pattern) for patterns with one capture (the whole match when there is none)
local function gmatchPattern(code, pattern)
	local info = startsWith(pattern)
	if not info then
		return string.gmatch(code, pattern)
	end
	local init = 1
	return function()
		local p, e, capture = findPattern(code, pattern, init)
		if not p then
			return nil
		end
		init = math.max(e, p) + 1
		return capture or string.sub(code, p, e)
	end
end

-- how many times a pattern matches (and where first); member = skip "x.wait(" / "x:wait(" (task.wait is fine)
local function countMatches(code, pattern, member)
	local n, first, init = 0, nil, 1
	while true do
		local p, e = findPattern(code, pattern, init)
		if not p then
			break
		end
		init = math.max(e, p) + 1
		local prev = p > 1 and string.byte(code, p - 1) or 0
		if not (member and (prev == 46 or prev == 58)) then -- "." or ":"
			n += 1
			first = first or p
		end
	end
	return n, first
end

-- ---------------------------------------------------------------------------------------------
-- what the scan looks for
-- ---------------------------------------------------------------------------------------------
local DEPRECATED = {
	{ key = "wait", anchor = "wait", patterns = { "%f[%w_]wait%s*%(" }, member = true, label = "wait()", fix = "task.wait()" },
	{ key = "spawn", anchor = "spawn", patterns = { "%f[%w_]spawn%s*%(" }, member = true, label = "spawn()", fix = "task.spawn()" },
	{ key = "delay", anchor = "delay", patterns = { "%f[%w_]delay%s*%(" }, member = true, label = "delay()", fix = "task.delay()" },
	{ key = "connect", anchor = ":connect", patterns = { ":connect%s*%(" }, label = ":connect()", fix = ":Connect()" },
	-- (only Instance methods: custom classes often name their own :clone() / :destroy() in lower case)
	{ key = "lowercase", anchor = ":", patterns = { ":findFirstChild%s*%(", ":waitForChild%s*%(", ":getChildren%s*%(",
		":children%s*%(", ":isA%s*%(", ":findFirstChildOfClass%s*%(" },
		label = "metode cu literă mică (:findFirstChild, :getChildren…)", fix = "variantele cu majusculă" },
	{ key = "remove", anchor = ":Remove", patterns = { ":Remove%s*%(%s*%)" }, label = ":Remove()", fix = ":Destroy()" },
	{ key = "instanceParent", anchor = "Instance.new", patterns = { "Instance%.new%s*%(%s*[\"'][%w_]+[\"']%s*," },
		label = "Instance.new(clasă, părinte)", fix = "setează Parent ultimul (e mult mai rapid)" },
	{ key = "loadAnimation", anchor = "LoadAnimation", patterns = { "[Hh]umanoid%s*:%s*LoadAnimation%s*%(" },
		label = "Humanoid:LoadAnimation()", fix = "Animator:LoadAnimation()" },
	{ key = "primaryPartCFrame", anchor = "SetPrimaryPartCFrame", patterns = { "SetPrimaryPartCFrame%s*%(" },
		label = ":SetPrimaryPartCFrame()", fix = ":PivotTo()" },
	{ key = "oldRaycast", anchor = "FindPart", patterns = { "FindPartOnRay%w*%s*%(", "FindPartsInRegion3%w*%s*%(" },
		label = "FindPartOnRay / FindPartsInRegion3", fix = "workspace:Raycast() / GetPartBoundsInBox()" },
	{ key = "bodyMovers", anchor = "Body", patterns = { "[\"']BodyVelocity[\"']", "[\"']BodyGyro[\"']", "[\"']BodyPosition[\"']",
		"[\"']BodyAngularVelocity[\"']", "[\"']BodyForce[\"']", "[\"']BodyThrust[\"']" },
		label = "BodyVelocity / BodyGyro / BodyPosition…", fix = "LinearVelocity / AlignOrientation / AlignPosition" },
	{ key = "tick", anchor = "tick", patterns = { "%f[%w_]tick%s*%(%s*%)" }, member = true, label = "tick()",
		fix = "os.clock() / workspace:GetServerTimeNow()" },
	{ key = "ypcall", anchor = "ypcall", patterns = { "%f[%w_]ypcall%s*%(" }, member = true, label = "ypcall()", fix = "pcall()" },
	{ key = "tableGetn", anchor = "table.", patterns = { "table%.getn%s*%(", "table%.foreachi?%s*%(" },
		label = "table.getn / table.foreach", fix = "# și for … in" },
}

-- frameworks / libraries: by the name of a ModuleScript / Folder, or by code
local FRAMEWORKS = {
	{ name = "Knit", modules = { "Knit", "KnitServer", "KnitClient" }, code = { "Knit%.CreateService", "Knit%.CreateController" } },
	{ name = "ProfileService", modules = { "ProfileService" }, code = { "GetProfileStore%s*%(" } },
	{ name = "ProfileStore", modules = { "ProfileStore" }, code = { "ProfileStore%.New%s*%(" } },
	{ name = "DataStore2", modules = { "DataStore2" }, code = { "DataStore2%s*%(" } },
	{ name = "ReplicaService", modules = { "ReplicaService", "ReplicaController" } },
	{ name = "Roact", modules = { "Roact" }, code = { "Roact%.createElement" } },
	{ name = "React (react-lua)", modules = { "React", "ReactRoblox" }, code = { "ReactRoblox%.createRoot" } },
	{ name = "Fusion", modules = { "Fusion" }, code = { "Fusion%.New", "Fusion%.Computed" } },
	{ name = "Rodux", modules = { "Rodux" } },
	{ name = "Promise", modules = { "Promise" } },
	{ name = "Signal", modules = { "Signal", "GoodSignal", "FastSignal" } },
	{ name = "Janitor / Maid / Trove", modules = { "Janitor", "Maid", "Trove" } },
	{ name = "Cmdr", modules = { "Cmdr", "CmdrClient" } },
	{ name = "Matter (ECS)", modules = { "Matter" } },
	{ name = "BridgeNet / ByteNet / Zap (rețea)", modules = { "BridgeNet", "BridgeNet2", "ByteNet", "Zap", "Warp" } },
	{ name = "TopbarPlus", modules = { "TopbarPlus" }, code = { "Icon%.new%s*%(" } },
	{ name = "ZonePlus", modules = { "ZonePlus" }, code = { "Zone%.new%s*%(" } },
	{ name = "FastCast", modules = { "FastCastRedux", "FastCast" }, code = { "FastCast%.new%s*%(" } },
	{ name = "RaycastHitbox", modules = { "RaycastHitboxV4", "RaycastHitbox" } },
	{ name = "ClientCast", modules = { "ClientCast" } },
	{ name = "Adonis (admin)", modules = { "Adonis_Loader", "Adonis" } },
	{ name = "HD Admin", modules = { "HDAdmin", "HD Admin" } },
	{ name = "Kohl's Admin", modules = { "Kohl's Admin Infinite", "Kohls Admin Infinite" } },
	{ name = "LostCube VFX", modules = {}, code = { "LostCube%.VFX", "VFX%.play%s*%(" } },
}
local FRAMEWORK_BY_NAME = {}
for _, fw in FRAMEWORKS do
	for _, m in fw.modules do
		FRAMEWORK_BY_NAME[m] = fw.name
	end
end

local EXPLOIT_APIS = { "getgenv", "getrenv", "getrawmetatable", "hookfunction", "hookmetamethod", "setreadonly",
	"getconnections", "firetouchinterest", "fireclickdetector", "getnamecallmethod", "checkcaller", "newcclosure", "setclipboard" }
local EXPLOIT_PATTERN = {}
for _, name in EXPLOIT_APIS do
	EXPLOIT_PATTERN[name] = "%f[%w_]" .. name .. "%f[^%w_]"
end
local REMOTE_HANDLERS = { "OnServerEvent%s*:%s*Connect%s*%(", "OnServerInvoke%s*=%f[^=]" }
local ENDLESS_LOOPS = { "%f[%w_]while%s+true%s+do%f[^%w_]", "%f[%w_]while%s+1%s+do%f[^%w_]" }
local PASTE_HOSTS = { "pastebin.com", "raw.githubusercontent.com", "gist.githubusercontent.com", "hastebin.com", "paste.ee",
	"rentry.co", "rentry.org", "controlc.com", "ghostbin.com", "glot.io", "githack.com", "pastefy.app", "paste.gg" }
local TRUSTED_HOSTS = { "roblox.com", "rbxcdn.com", "robloxlabs.com", "gameanalytics.com" }
local SHOP_WORDS = { "shop", "store", "buy", "purchase", "donat", "gamepass", "pass", "product", "vip", "premium", "market",
	"magazin", "cumpar", "robux", "coin", "gem", "cash", "skip", "boost", "currency", "sale", "receipt", "monet", "dev" }
local ADMIN_WORDS = { "adonis", "hd admin", "hdadmin", "kohl", "admin", "loader" }
local VALIDATION = { "typeof", "type(", "tonumber", "assert", "IsA", "math.clamp", "if ", "if(", "validate", "Validate",
	"check", "Check", "sanit", "Sanit" }
local YIELDS = { "wait", "Wait", "yield", "Yield", "Async", "Heartbeat", "Stepped", "PreRender", "PreSimulation",
	"PostSimulation", "Invoke", "break", "return", "sleep", "Sleep" }
local VIRUS_NAMES = set({ "vaccine", "spread", "infected", "infection", "virus", "antivirus", "virusremover", "antilag",
	"antilagscript", "lagremover", "lagfix", "fixlag", "removelag", "nolag", "snapreducer", "worm", "4dbeing",
	"propergrammerneededinphilosiphallocations" })
local SERVICE_NAMES = set({ "Workspace", "Players", "Lighting", "ReplicatedStorage", "ReplicatedFirst", "ServerScriptService",
	"ServerStorage", "StarterGui", "StarterPack", "StarterPlayer", "SoundService", "Chat", "Teams", "HttpService",
	"RunService", "MarketplaceService", "InsertService", "Debris", "CoreGui" })
-- a script directly inside one of these is hidden on purpose (or at least never meant to be there)
local ODD_PARENTS = set({ "Decal", "Texture", "Sound", "Weld", "WeldConstraint", "Motor6D", "Attachment", "SpecialMesh",
	"BlockMesh", "CylinderMesh", "Animation", "Fire", "Smoke", "Sparkles", "ParticleEmitter", "PointLight", "SpotLight",
	"SurfaceLight", "Beam", "Trail", "Explosion", "SurfaceAppearance", "Shirt", "Pants", "ShirtGraphic", "BodyColors",
	"CharacterMesh", "Sky", "Atmosphere", "BloomEffect", "ColorCorrectionEffect", "BlurEffect", "SunRaysEffect", "Highlight",
	"Camera", "Lighting", "SoundService", "Teams", "MaterialService", "LocalizationService" })
local KNOWN_SERVICES = set({ "Players", "ReplicatedStorage", "ReplicatedFirst", "ServerStorage", "ServerScriptService",
	"Workspace", "Lighting", "StarterGui", "StarterPack", "StarterPlayer", "SoundService", "Teams", "Debris", "Chat" })
local FLAGS = {
	tween = { "TweenService" }, collection = { "CollectionService" }, keyboard = { "KeyCode.", "InputBegan" },
	mobile = { "ContextActionService", "TouchEnabled", "TouchTap", "TouchStarted" }, filter = { "FilterStringAsync", "FilterString" },
	damage = { "TakeDamage" }, hitbox = { "Hitbox", "hitbox", "GetPartBoundsInBox", "GetPartsInPart", "GetPartBoundsInRadius" },
	raycast = { ":Raycast(" }, leaderstats = { "leaderstats" }, messaging = { "MessagingService" },
	teleport = { "TeleportService" }, badge = { "BadgeService" }, globals = { "_G.", "_G[" }, ragdoll = { "Ragdoll", "ragdoll" },
	cameraShake = { "Shake", "shake" }, physicsGroups = { "PhysicsService" },
}

local GENRES = {
	{ key = "combat", label = "Luptă / fighting", words = "combat fight fighting fighter punch kick combo hitbox damage attack "
		.. "block parry dodge stun ragdoll skill ability abilities m1 m2 sword katana blade weapon moveset knockback blood "
		.. "battleground battlegrounds slash fist arena pvp lupta atac sabie lovitura" },
	{ key = "simulator", label = "Simulator", words = "simulator sim rebirth pet egg hatch hatching multiplier clicker click "
		.. "tap coin gem sell backpack capacity boost upgrade strength training lift aura index" },
	{ key = "tycoon", label = "Tycoon", words = "tycoon dropper conveyor collector upgrader claim plot factory ore mine owner "
		.. "cashregister purchasebutton" },
	{ key = "obby", label = "Obby / parkour", words = "obby obbies checkpoint stage killbrick killpart lava spinner parkour "
		.. "finish win skip obstacle truss" },
	{ key = "rpg", label = "RPG / aventură", words = "quest npc dialog dialogue level xp exp experience inventory item loot mob "
		.. "enemy enemies boss bosses dungeon class stats mana equipment armor armour misiune nivel inamic" },
	{ key = "horror", label = "Horror", words = "horror monster jumpscare scare scary ghost flashlight entity chase hide hiding "
		.. "closet creepy sanity killer survivor fear haunted" },
	{ key = "racing", label = "Curse / vehicule", words = "race racing racer car vehicle kart drift lap speedometer nitro "
		.. "chassis garage track boat plane masina cursa" },
	{ key = "shooter", label = "Shooter / FPS", words = "gun shoot shooting shooter bullet ammo reload rifle pistol fps recoil "
		.. "aim scope sniper grenade fastcast magazine headshot muzzle tracer arma" },
	{ key = "roleplay", label = "Roleplay / social", words = "roleplay rp house job bank phone outfit emote police hospital "
		.. "school city town furniture apartment casa oras" },
	{ key = "towerdefense", label = "Tower defense", words = "td wave path waypoint placement unit tower defense defence spawner" },
}
for _, g in GENRES do
	g.set = wordSet(g.words)
end

local UI_CATEGORIES = {
	{ key = "shop", label = "magazin", words = "shop store magazin market buy robux gamepass purchase" },
	{ key = "inventory", label = "inventar", words = "inventory inventar backpack bag items hotbar" },
	{ key = "hud", label = "HUD / viață", words = "health hp hud stamina energy mana bar" },
	{ key = "menu", label = "meniu / încărcare", words = "menu mainmenu title intro loading loadingscreen" },
	{ key = "settings", label = "setări", words = "settings setari options config" },
	{ key = "currency", label = "monede", words = "coin cash money gem currency bani" },
	{ key = "quest", label = "misiuni", words = "quest mission misiune objective task" },
	{ key = "dialog", label = "dialog", words = "dialog dialogue npc speech" },
	{ key = "pets", label = "pets", words = "pet egg hatch" },
	{ key = "trade", label = "trade", words = "trade trading" },
	{ key = "rewards", label = "recompense / coduri", words = "daily reward spin codes code gift chest" },
	{ key = "leaderboard", label = "clasament", words = "leaderboard ranking" },
	{ key = "rebirth", label = "rebirth", words = "rebirth prestige" },
}
for _, c in UI_CATEGORIES do
	c.set = wordSet(c.words)
end

local NAME_WEIGHT = { Script = 2, LocalScript = 2, ModuleScript = 2, Tool = 3, RemoteEvent = 2, RemoteFunction = 2,
	UnreliableRemoteEvent = 2, BindableEvent = 1, BindableFunction = 1, ScreenGui = 2, Folder = 1, Model = 1, Configuration = 1,
	Frame = 1, TextButton = 1, ImageButton = 1, Animation = 2, KeyframeSequence = 2, Sound = 1, ProximityPrompt = 1, Team = 1 }
local SCRIPT_CLASSES = set({ "Script", "LocalScript", "ModuleScript" })
local VFX_CLASSES = set({ "ParticleEmitter", "Beam", "Trail", "Explosion", "Fire", "Smoke", "Sparkles", "Highlight" })
local BODY_MOVERS = { "BodyVelocity", "BodyGyro", "BodyPosition", "BodyAngularVelocity", "BodyForce", "BodyThrust" }

local function hostIn(host, list)
	for _, h in list do
		if host == h or string.sub(host, -(#h + 1)) == "." .. h then
			return true
		end
	end
	return false
end

local function pathHas(path, list)
	local lower = string.lower(path or "")
	for _, w in list do
		if string.find(lower, w, 1, true) then
			return true
		end
	end
	return false
end

local function isDigit(byte)
	return byte ~= nil and byte >= 48 and byte <= 57
end

-- string.gmatch(code, "()https?://([%w%.%-]+)") (position, host), but looking for "://" first: the pattern would be
-- tried at every character, and "rbxassetid://" makes "://" common while real URLs are rare
local function eachUrl(code)
	local from, lastEnd = 1, 0
	return function()
		while true do
			local q = string.find(code, "://", from, true)
			if not q then
				return nil
			end
			from = q + 1
			local start = (q >= 6 and string.sub(code, q - 5, q - 1) == "https" and q - 5)
				or (q >= 5 and string.sub(code, q - 4, q - 1) == "http" and q - 4) or nil
			if start and start > lastEnd then -- not inside the previous match
				local _, stop = string.find(code, "^[%w%.%-]+", q + 3)
				if stop then
					lastEnd, from = stop, stop + 1
					return start, string.sub(code, q + 3, stop)
				end
			end
		end
	end
end

local BLOB = string.rep("[%w%+/=]", 160) -- 160 base64 / hex characters in a row

-- ---------------------------------------------------------------------------------------------
-- one script: security signatures, risky / deprecated code and (with `facts`) statistics for the report
-- meta = { path, name, class, server, client, workspace }; returns the number of lines
-- ---------------------------------------------------------------------------------------------
local function scanSource(meta, src, out, facts)
	local code = stripComments(src)
	local starts, longest, longestLine = lineIndex(src)
	-- `pos` is a character position; extra values (e.g. the end returned by string.find) are ignored
	local function addAt(severity, kind, message, line)
		table.insert(out, { severity = severity, kind = kind, path = meta.path, line = line, message = message })
	end
	local function add(severity, kind, message, pos)
		addAt(severity, kind, message, lineOf(starts, pos))
	end
	local function has(text)
		return string.find(code, text, 1, true) ~= nil
	end

	-- backdoors / viruses ---------------------------------------------------------------------
	local loadsCode = false
	if has("require") then
		local pos, _, id = findPattern(code, "require%s*%(%s*(%d%d%d%d%d+)%s*%)")
		if pos then
			local admin = pathHas(meta.path, ADMIN_WORDS)
			add(admin and "medium" or "high", "security.require", "require(" .. id .. ") încarcă un modul de pe site — "
				.. (admin and "pare loader-ul unui sistem de admin; verifică ID-ul" or "semnătura clasică de backdoor din free models"), pos)
			loadsCode = true
		else
			pos = findPattern(code, "require%s*%(%s*0[xX]%x") or findPattern(code, "require%s*%(%s*tonumber%s*%(")
				or findPattern(code, "require%s*%(%s*%d+%s*[%+%-%*/%%%^]") or findPattern(code, "require%s*%(%s*[\"']%d")
			if pos then
				add("high", "security.require", "require() cu un ID ascuns (hex, calcul sau text) — aproape sigur un backdoor", pos)
				loadsCode = true
			end
		end
		local mainModule = findPattern(code, "require%s*%([^%)\n]-MainModule")
		if mainModule then
			add("medium", "security.require", "require(…MainModule) — încarcă un modul public; verifică de unde vine", mainModule)
		end
	end
	local p = findPattern(code, "%f[%w_]loadstring%s*%(")
	if p then
		loadsCode = true
		local remote = has("HttpGet") or has("GetAsync") or has("RequestAsync")
		add("high", "security.loadstring", "loadstring() rulează cod din text" .. (remote and " descărcat de pe internet" or "")
			.. " — folosit de backdoor-uri și de cod ofuscat", p)
	end
	p = findPattern(code, "%f[%w_]getfenv%s*%(") or findPattern(code, "%f[%w_]setfenv%s*%(")
	if p then
		add(loadsCode and "high" or "medium", "security.fenv",
			"getfenv/setfenv — des folosite ca să ascundă cod (și opresc optimizările Luau)", p)
	end
	for _, name in EXPLOIT_APIS do
		p = findPattern(code, EXPLOIT_PATTERN[name])
		if p then
			add("high", "security.exploit", name .. " e o funcție de executor (exploit) — codul ăsta nu e scris pentru joc", p)
			break
		end
	end
	p = findPattern(code, ":HttpGet%s*%(") or findPattern(code, ":HttpGetAsync%s*%(") or findPattern(code, ":GetObjects%s*%(")
	if p then
		add("high", "security.exploit", "game:HttpGet / GetObjects merg doar în executoare de exploit-uri — cod suspect", p)
	end

	-- obfuscation
	local obfuscated = false
	if has("\\") then
		-- escapes like \x41 and \065 (obfuscated code has hundreds); only the backslashes are visited
		local hexes, decimals, at = 0, 0, string.find(code, "\\", 1, true)
		while at do
			local nextByte = string.byte(code, at + 1) -- 120 = x, 88 = X
			if (nextByte == 120 or nextByte == 88) and string.find(code, "^%x%x", at + 2) then
				hexes += 1
				at += 4
			elseif isDigit(nextByte) then
				decimals += 1
				at += isDigit(string.byte(code, at + 2)) and (isDigit(string.byte(code, at + 3)) and 4 or 3) or 2
			else
				at += 1
			end
			at = string.find(code, "\\", at, true)
		end
		if hexes >= 24 or decimals >= 40 then
			obfuscated = true
			add("high", "security.obfuscated", int(hexes + decimals)
				.. " caractere ascunse prin coduri escape (\\x.. / \\ddd) — cod ofuscat", (string.find(code, "\\[xX%d]")))
		end
	end
	if not obfuscated and has(".char") then
		for args in gmatchPattern(code, "%.char%s*%(([%d%s,]+)%)") do
			local _, commas = string.gsub(args, ",", "")
			if commas >= 15 then
				obfuscated = true
				add("high", "security.obfuscated", "string.char cu " .. int(commas + 1) .. " coduri — text ascuns (cod ofuscat)",
					findPattern(code, "%.char%s*%("))
				break
			end
		end
	end
	if not obfuscated and has("reverse") and findPattern(code, "[%.:]reverse%s*%(") and (has("require") or has("getfenv") or loadsCode) then
		add("medium", "security.obfuscated", "string.reverse lângă require/getfenv — truc des folosit ca să ascundă ID-uri",
			findPattern(code, "[%.:]reverse%s*%("))
	end
	if longest > 2000 then
		addAt("medium", "security.longLine", "o linie de " .. int(longest) .. " caractere — cod ofuscat sau minificat", longestLine)
	elseif longest > 300 then
		local blob -- a run cannot cross a line: only the lines that are long enough are searched
		for i = 1, #starts do
			local from = starts[i]
			local to = starts[i + 1] and starts[i + 1] - 2 or #code
			if to - from >= 159 then
				local found = string.find(string.sub(code, from, to), BLOB)
				if found then
					blob = from + found - 1
					break
				end
			end
		end
		if blob then
			add("medium", "security.blob", "un șir codificat foarte lung (base64 / hex) — poate ascunde cod", blob)
		end
	end

	-- HTTP: where does the script talk to?
	if has("://") then
		local seen = {}
		local posting = has("PostAsync") or has("RequestAsync")
		for pos, host in eachUrl(code) do
			host = string.lower(host :: string)
			if not seen[host] then
				seen[host] = true
				if facts then
					bump(facts.hosts, host)
				end
				if hostIn(host, PASTE_HOSTS) then
					add((loadsCode or has("GetAsync")) and "high" or "medium", "security.http",
						"descarcă de pe " .. host .. " — de acolo vin de obicei backdoor-urile", pos)
				elseif string.find(host, "discord", 1, true) and has("webhook") then
					add("medium", "security.http", "trimite date la un webhook Discord (" .. host .. ")", pos)
				elseif posting and not hostIn(host, TRUSTED_HOSTS) then
					add("medium", "security.http", "trimite date către " .. host .. " (HttpService) — verifică ce pleacă din joc", pos)
				end
			end
		end
	end

	-- purchases where nobody expects them (classic free-model scam)
	p = findPattern(code, "Prompt%a*Purchase%s*%(")
	if p then
		if facts then
			facts.market.prompts += countMatches(code, "Prompt%a*Purchase%s*%(")
		end
		if not pathHas(meta.path, SHOP_WORDS) then
			local sneaky = meta.workspace or has("PlayerAdded") or has("CharacterAdded") or has("Touched")
			add(sneaky and "high" or "medium", "security.purchase", "cere jucătorului o cumpărare dintr-un script care nu pare de magazin"
				.. (sneaky and " (la intrare / atingere)" or "") .. " — escrocherie tipică din free models; verifică ID-ul", p)
		end
	end
	p = findPattern(code, ":LoadAsset%s*%(")
	if p then
		add("medium", "security.insert", "InsertService:LoadAsset încarcă modele în timpul jocului — verifică ce ID-uri se încarcă", p)
	end

	-- remotes: what does the server do with what clients send?
	if has("OnServerEvent") or has("OnServerInvoke") then
		for _, pattern in REMOTE_HANDLERS do
			local init = 1
			while true do
				local p1, e1 = findPattern(code, pattern, init)
				if not p1 then
					break
				end
				init = e1 + 1
				if facts then
					facts.remoteHandlers += 1
				end
				local params = string.match(code, "^%s*function%s*%(([^%)]*)%)", e1 + 1)
				if params then -- an inline handler (a named function is not followed)
					local names = {}
					for piece in string.gmatch(params .. ",", "([^,]*),") do
						local name = string.match(piece, "^%s*([%a_][%w_]*)")
						if name then
							table.insert(names, name)
						end
					end
					local block = blockText(code, starts, lineOf(starts, p1), 250)
					local runsCode = string.find(block, "%f[%w_]loadstring%s*%(") ~= nil
					for i = 2, #names do
						if string.find(block, "require%s*%(%s*" .. names[i] .. "%f[^%w_]") then
							runsCode = true
						end
					end
					if runsCode then
						add("high", "remote.runsCode",
							"un remote rulează cod sau module trimise de client (loadstring/require) — oricine poate controla serverul", p1)
					elseif #names >= 2 then
						local validated = false
						for _, token in VALIDATION do
							if string.find(block, token, 1, true) then
								validated = true
								break
							end
						end
						if not validated then
							add("low", "remote.unvalidated",
								"handler de remote fără nicio verificare a datelor primite de la client (typeof / tonumber / if)", p1)
							if facts then
								facts.unvalidated += 1
							end
						end
						for i = 2, #names do
							if string.find(block, "%.Value%s*[%+%-]?=%f[^=][^\n]-%f[%w_]" .. names[i] .. "%f[^%w_]") then
								add("medium", "remote.trust", "setează o valoare (bani, statistici…) direct din ce trimite clientul („"
									.. names[i] .. "”) — un exploiter trimite orice număr", p1)
								break
							end
						end
					end
				end
			end
		end
	end
	if meta.server and has(":InvokeClient") then
		add("medium", "remote.invokeClient", "InvokeClient: serverul așteaptă răspunsul clientului — un exploiter îl poate bloca la nesfârșit",
			(string.find(code, ":InvokeClient", 1, true)))
	end

	-- loops that never yield freeze the server / the client
	if has("while") then
		for _, pattern in ENDLESS_LOOPS do
			local init = 1
			while true do
				local p1, e1 = findPattern(code, pattern, init)
				if not p1 then
					break
				end
				init = e1 + 1
				local block = blockText(code, starts, lineOf(starts, p1), 400)
				local yields = false
				for _, token in YIELDS do
					if string.find(block, token, 1, true) then
						yields = true
						break
					end
				end
				if not yields then
					add("medium", "perf.busyLoop", "while true do fără wait() — blochează firul (serverul / clientul îngheață)", p1)
					if facts then
						facts.busyLoops += 1
					end
				end
			end
		end
	end

	-- common mistakes
	if meta.server and findPattern(code, "%.LocalPlayer%f[^%w_]") then
		add("medium", "code.localPlayerServer", "LocalPlayer într-un Script de server — acolo e mereu nil",
			(string.find(code, ".LocalPlayer", 1, true)))
	end
	if (has(":GetAsync") or has(":SetAsync") or has(":UpdateAsync")) and has("DataStore") and not has("pcall")
		and not has("Promise") then
		add("medium", "data.noPcall", "DataStore fără pcall — o eroare de rețea oprește scriptul și se pot pierde date",
			(string.find(code, ":%a+Async%s*%(")))
		if facts then
			facts.datastore.noPcall += 1
		end
	end
	if meta.client and has("leaderstats") and findPattern(code, "%.Value%s*[%+%-]?=%f[^=]") then
		add("low", "code.clientStats", "LocalScript care schimbă leaderstats — schimbarea nu ajunge pe server (nu se vede, nu se salvează)",
			(string.find(code, "leaderstats", 1, true)))
	end
	if meta.client and has("ProcessReceipt") then
		add("medium", "market.clientReceipt", "ProcessReceipt într-un LocalScript — merge doar pe server, cumpărăturile nu se livrează",
			(string.find(code, "ProcessReceipt", 1, true)))
	end

	-- deprecated APIs (one finding per kind and script; Analyzer.run sums them up for the whole game)
	for _, d in DEPRECATED do
		if has(d.anchor) then
			local n, first = 0, nil
			for _, pattern in d.patterns do
				local c, f = countMatches(code, pattern, d.member)
				n += c
				if f and (not first or f < first) then
					first = f
				end
			end
			if n > 0 then
				add("low", "deprecated." .. d.key, d.label .. " ×" .. n .. " → " .. d.fix, first)
				if facts then
					local agg = facts.deprecated[d.key]
					if not agg then
						agg = { key = d.key, label = d.label, fix = d.fix, count = 0, scripts = 0, path = meta.path,
							line = lineOf(starts, first) }
						facts.deprecated[d.key] = agg
					end
					agg.count += n
					agg.scripts += 1
				end
			end
		end
	end

	-- statistics for the report ---------------------------------------------------------------
	if facts then
		if has("GetService") then
			for name in gmatchPattern(code, "GetService%s*%(%s*[\"']([%w_]+)[\"']") do
				bump(facts.services, name)
			end
		end
		if has("game.") then
			for name in gmatchPattern(code, "%f[%w_]game%.(%u[%w_]*)") do
				if KNOWN_SERVICES[name] then
					bump(facts.services, name)
				end
			end
		end
		for _, fw in FRAMEWORKS do
			if fw.code and not facts.frameworks[fw.name] then
				for _, pattern in fw.code do
					if findPattern(code, pattern) then
						facts.frameworks[fw.name] = meta.path
						break
					end
				end
			end
		end
		local ds = facts.datastore
		if has("GetDataStore") or has("GetOrderedDataStore") then
			ds.used = true
			ds.scripts += 1
		end
		if has("GetOrderedDataStore") then
			ds.ordered = true
		end
		if has("Async") then
			ds.set += countMatches(code, ":SetAsync%s*%(")
			ds.update += countMatches(code, ":UpdateAsync%s*%(")
		end
		if has("BindToClose") then
			ds.bindToClose = true
		end
		if has("PlayerRemoving") then
			ds.playerRemoving = true
		end
		local m = facts.market
		if has("GamePass") then
			for id in gmatchPattern(code, "UserOwnsGamePassAsync%s*%([^,%)]+,%s*(%d+)") do
				m.gamepasses[id] = true
			end
			for id in gmatchPattern(code, "PromptGamePassPurchase%s*%([^,%)]+,%s*(%d+)") do
				m.gamepasses[id] = true
			end
		end
		if has("PromptProductPurchase") then
			m.productPrompts += 1
			for id in gmatchPattern(code, "PromptProductPurchase%s*%([^,%)]+,%s*(%d+)") do
				m.products[id] = true
			end
		end
		if has("ProcessReceipt") then
			local n = countMatches(code, "ProcessReceipt%s*=%f[^=]")
			m.receipts += n
			if n > 0 and #m.receiptPaths < 5 then
				table.insert(m.receiptPaths, meta.path)
			end
		end
		if has("Connect") then
			facts.runService += countMatches(code, "Heartbeat%s*:%s*Connect") + countMatches(code, "Stepped%s*:%s*Connect")
				+ countMatches(code, "PreRender%s*:%s*Connect") + countMatches(code, "PreSimulation%s*:%s*Connect")
				+ countMatches(code, "PostSimulation%s*:%s*Connect")
			facts.renderStepped += countMatches(code, "RenderStepped%s*:%s*Connect")
			facts.touched += countMatches(code, "Touched%s*:%s*Connect")
			facts.clientEvents += countMatches(code, "OnClientEvent%s*:%s*Connect")
		end
		if has("BindToRenderStep") then
			facts.runService += countMatches(code, "BindToRenderStep%s*%(")
		end
		if has("AnimationId") then
			facts.animIds += countMatches(code, "AnimationId%s*=%s*[\"'][^\"'\n]-%d%d%d%d")
		end
		for flag, list in FLAGS do
			for _, token in list do
				if has(token) then
					bump(facts.flags, flag)
					break
				end
			end
		end
	end
	return #starts
end

-- where a script sits and how it is named (works without reading the source)
local function checkPlacement(s, meta, out)
	local function add(severity, kind, message)
		table.insert(out, { severity = severity, kind = kind, path = meta.path, message = message })
	end
	local name = s.Name
	if VIRUS_NAMES[string.gsub(string.lower(name), "[^%w]", "")] then
		add(meta.workspace and "high" or "medium", "security.virusName", "script numit „" .. name .. "” — nume tipic de virus din free models")
	end
	if string.match(name, "^%s*$") or name ~= string.match(name, "^%s*(.-)%s*$") or string.find(name, "\226\128[\139-\143]")
		or string.find(name, "\239\187\191") then
		add("medium", "security.hiddenName", "script cu nume gol sau cu spații / caractere invizibile — un truc ca să nu fie observat")
	end
	if SERVICE_NAMES[name] then
		add("medium", "security.fakeName", "script numit ca un serviciu („" .. name .. "”) — se ascunde în Explorer")
	end
	local parent = s.Parent
	if parent then
		local pc = parent.ClassName
		if ODD_PARENTS[pc] or parent:IsA("ValueBase") then
			add("medium", "security.oddPlace", "script ascuns într-un " .. pc .. " — loc neobișnuit, tipic pentru viruși")
		elseif meta.workspace and parent:IsA("BasePart") then
			add("low", "structure.scriptInPart", "script într-o piesă din Workspace (verifică dacă vine dintr-un free model)")
		end
	end
end

local function metaOf(s)
	local class = s.ClassName
	local runContext = enumName(prop(s, "RunContext")) or "Legacy"
	local client = class == "LocalScript" or (class == "Script" and runContext == "Client")
	local inWorkspace = false
	pcall(function()
		inWorkspace = s:IsDescendantOf(workspace)
	end)
	return { path = pathOf(s), name = s.Name, class = class, client = client, server = class == "Script" and not client,
		workspace = inWorkspace }
end

local function sortFindings(list)
	local function group(kind)
		return KIND_ORDER[string.match(kind or "", "^[^%.]+") or ""] or 50
	end
	table.sort(list, function(a, b)
		local ra, rb = RANK[a.severity] or 4, RANK[b.severity] or 4
		if ra ~= rb then
			return ra < rb
		end
		local ga, gb = group(a.kind), group(b.kind)
		if ga ~= gb then
			return ga < gb
		end
		if (a.path or "") ~= (b.path or "") then
			return (a.path or "") < (b.path or "")
		end
		return (a.line or 0) < (b.line or 0)
	end)
	return list
end

-- security / quality scan of any subtree (e.g. a free model before it goes into the game). Yields on big trees.
function Analyzer.scanInstance(root)
	local out = {}
	if typeof(root) ~= "Instance" then
		return out
	end
	local list = { root }
	local ok, descendants = pcall(root.GetDescendants, root)
	if ok then
		table.move(descendants, 1, #descendants, 2, list)
	end
	for _, inst in list do
		if SCRIPT_CLASSES[inst.ClassName] then
			local meta = metaOf(inst)
			pcall(checkPlacement, inst, meta, out)
			local okSource, src = pcall(function()
				return inst.Source
			end)
			if okSource and type(src) == "string" and src ~= "" then
				pcall(scanSource, meta, src, out, nil)
			end
			breathe()
		end
	end
	return sortFindings(out)
end

-- ---------------------------------------------------------------------------------------------
-- the scan: every instance once (counts, parts, VFX, animations, UI...), then every script
-- ---------------------------------------------------------------------------------------------
local function newState()
	local S = {
		total = 0, errors = 0, services = {}, classes = {}, names = {}, nameCount = 0, scripts = {}, structure = {},
		kinds = {}, frameworks = {}, findings = {},
		part = { count = 0, workspace = 0, unanchored = 0, loose = 0, meshes = 0, meshIds = {}, uniqueMeshes = 0, precise = 0,
			unions = 0, invisibleColliders = 0, area = 0, colors = {}, materials = {}, humanoidModels = {} },
		vfx = { counts = {}, textures = {}, colors = {}, examples = {}, rate = 0, heavy = 0 },
		lights = { count = 0, shadows = 0 },
		sounds = { count = 0, looped = 0, playing = 0, ids = {}, music = {}, musicCount = 0, groups = 0 },
		decals = { count = 0, ids = {} },
		anim = { count = 0, ids = {}, list = {}, kfsCount = 0, kfs = {}, rigs = {}, saves = 0, controllers = 0, animators = 0 },
		humanoids = { count = 0, workspace = 0, r6 = 0, r15 = 0 },
		ui = { screenGuis = 0, guiNames = {}, names = {}, nameCount = 0, guiObjects = 0, fixed = 0, fixedExamples = {},
			aspect = 0, textBoxes = 0, billboards = 0, surfaceGuis = 0 },
		remotes = { list = {}, counts = {} },
		misc = { tools = 0, toolNames = {}, seats = 0, vehicleSeats = 0, spawns = 0, prompts = 0, clickDetectors = 0,
			constraints = 0, packages = 0, teams = 0 },
	}
	S.code = { counts = {}, lines = 0, bytes = 0, largest = {}, services = {}, hosts = {}, deprecated = {},
		frameworks = S.frameworks, flags = {}, disabled = 0, clientRunContext = 0, unreadable = 0, scriptsInParts = 0,
		datastore = { used = false, scripts = 0, ordered = false, set = 0, update = 0, bindToClose = false,
			playerRemoving = false, noPcall = 0 },
		market = { gamepasses = {}, products = {}, prompts = 0, productPrompts = 0, receipts = 0, receiptPaths = {} },
		runService = 0, renderStepped = 0, touched = 0, clientEvents = 0, remoteHandlers = 0, unvalidated = 0, busyLoops = 0,
		animIds = 0 }
	return S
end

-- what a class is, asked once per class name (IsA on every instance would be slow on huge places)
local function kindOf(S, inst, class)
	local kind = S.kinds[class]
	if not kind then
		kind = { part = class ~= "Terrain" and inst:IsA("BasePart"), gui = inst:IsA("GuiObject"),
			constraint = inst:IsA("Constraint") }
		S.kinds[class] = kind
	end
	return kind
end

local function addName(S, name, weight)
	local key = string.lower(name)
	local cur = S.names[key]
	if cur then
		if weight > cur.weight then
			cur.weight = weight
		end
	elseif S.nameCount < 30000 then
		S.nameCount += 1
		S.names[key] = { name = name, weight = weight }
	end
end

local function addUiName(S, name)
	local U = S.ui
	local key = string.lower(name)
	if not U.names[key] and U.nameCount < 5000 then
		U.nameCount += 1
		U.names[key] = name
	end
end

local function vfxColor(V, c)
	if typeof(c) == "Color3" then
		bump(V.colors, c:ToHex():upper())
	end
end

local function vfxSequence(V, seq)
	if typeof(seq) == "ColorSequence" then
		local kps = seq.Keypoints
		vfxColor(V, kps[1].Value)
		if #kps > 1 and kps[#kps].Value ~= kps[1].Value then
			vfxColor(V, kps[#kps].Value)
		end
	end
end

local function vfxTexture(V, id)
	if type(id) == "string" and id ~= "" then
		bump(V.textures, id)
	end
end

local function vfxExample(S, e)
	local list = S.vfx.examples
	if #list < 12 then
		table.insert(list, { class = e.ClassName, name = e.Name, path = pathOf(e) })
	end
end

local function rigOfKeyframe(kf)
	for _, pose in kf:GetDescendants() do
		local n = pose.Name
		if n == "UpperTorso" or n == "LowerTorso" or n == "LeftUpperArm" or n == "RightUpperArm" then
			return "R15"
		elseif n == "Torso" or n == "Left Arm" or n == "Right Arm" or n == "Left Leg" then
			return "R6"
		end
	end
	return nil
end

local function visitRemote(S, r)
	local R = S.remotes
	bump(R.counts, r.ClassName)
	if #R.list < 200 then
		table.insert(R.list, { name = r.Name, class = r.ClassName, path = pathOf(r) })
	end
end

local function visitLight(S, l)
	S.lights.count += 1
	if l.Shadows then
		S.lights.shadows += 1
	end
end

local function visitDecal(S, d)
	S.decals.count += 1
	local texture = d.Texture
	if texture ~= "" then
		S.decals.ids[texture] = true
	end
end

local function visitScript(S, s)
	table.insert(S.scripts, s)
end

local VISIT = {
	Script = visitScript, LocalScript = visitScript, ModuleScript = visitScript,
	RemoteEvent = visitRemote, RemoteFunction = visitRemote, UnreliableRemoteEvent = visitRemote,
	BindableEvent = visitRemote, BindableFunction = visitRemote,
	PointLight = visitLight, SpotLight = visitLight, SurfaceLight = visitLight,
	Decal = visitDecal, Texture = visitDecal,
}

function VISIT.Humanoid(S, h, inWorkspace)
	local H = S.humanoids
	H.count += 1
	if inWorkspace then
		H.workspace += 1
		if h.RigType == Enum.HumanoidRigType.R15 then
			H.r15 += 1
		else
			H.r6 += 1
		end
	end
end

function VISIT.ParticleEmitter(S, e)
	local V = S.vfx
	if e.Enabled then
		local rate = e.Rate
		V.rate += rate
		if rate * e.Lifetime.Max > 400 then -- particles alive at once
			V.heavy += 1
		end
	end
	vfxTexture(V, e.Texture)
	vfxSequence(V, e.Color)
	vfxExample(S, e)
end

function VISIT.Beam(S, b)
	vfxTexture(S.vfx, b.Texture)
	vfxSequence(S.vfx, b.Color)
	vfxExample(S, b)
end
VISIT.Trail = VISIT.Beam

function VISIT.Fire(S, f)
	vfxColor(S.vfx, f.Color)
	vfxExample(S, f)
end

function VISIT.Smoke(S, f)
	vfxColor(S.vfx, f.Color)
end

function VISIT.Sparkles(S, f)
	vfxColor(S.vfx, f.SparkleColor)
end

function VISIT.Sound(S, s)
	local A = S.sounds
	A.count += 1
	local soundId = s.SoundId
	if soundId ~= "" then
		A.ids[soundId] = true
	end
	if s.Playing then
		A.playing += 1
	end
	if s.Looped then
		A.looped += 1
		local lower = string.lower(s.Name)
		for _, w in { "music", "song", "theme", "bgm", "ambien", "muzic", "soundtrack", "track", "melod" } do
			if string.find(lower, w, 1, true) then
				A.musicCount += 1
				if #A.music < 8 then
					table.insert(A.music, s.Name)
				end
				break
			end
		end
	end
end

function VISIT.SoundGroup(S)
	S.sounds.groups += 1
end

function VISIT.Animation(S, a)
	local A = S.anim
	A.count += 1
	local id = string.match(a.AnimationId, "%d+")
	if id then
		A.ids[id] = true
	end
	if #A.list < 80 then
		table.insert(A.list, { name = a.Name, id = id or "", path = pathOf(a) })
	end
end

function VISIT.KeyframeSequence(S, k)
	local A = S.anim
	A.kfsCount += 1
	local saved = k:FindFirstAncestor("RBX_ANIMSAVES") ~= nil
	if saved then
		A.saves += 1
	end
	local length, frames, markers, rig = 0, 0, {}, nil
	for _, kf in k:GetChildren() do
		if kf:IsA("Keyframe") then
			frames += 1
			length = math.max(length, kf.Time)
			if kf.Name ~= "Keyframe" and #markers < 8 and not table.find(markers, kf.Name) then
				table.insert(markers, kf.Name)
			end
			for _, m in kf:GetChildren() do
				if m:IsA("KeyframeMarker") and #markers < 8 and not table.find(markers, m.Name) then
					table.insert(markers, m.Name)
				end
			end
			rig = rig or rigOfKeyframe(kf)
		end
	end
	rig = rig or "custom"
	bump(A.rigs, rig)
	if #A.kfs < 40 then
		table.insert(A.kfs, { name = k.Name, path = pathOf(k), length = round(length, 2), keyframes = frames, markers = markers,
			rig = rig, saved = saved })
	end
end

function VISIT.AnimationController(S)
	S.anim.controllers += 1
end

function VISIT.Animator(S)
	S.anim.animators += 1
end

function VISIT.ScreenGui(S, g)
	S.ui.screenGuis += 1
	if #S.ui.guiNames < 40 then
		table.insert(S.ui.guiNames, g.Name)
	end
	addUiName(S, g.Name)
end

function VISIT.BillboardGui(S)
	S.ui.billboards += 1
end

function VISIT.SurfaceGui(S)
	S.ui.surfaceGuis += 1
end

function VISIT.UIAspectRatioConstraint(S)
	S.ui.aspect += 1
end

function VISIT.Tool(S, t)
	S.misc.tools += 1
	if #S.misc.toolNames < 30 then
		table.insert(S.misc.toolNames, t.Name)
	end
end

function VISIT.Seat(S)
	S.misc.seats += 1
end

function VISIT.VehicleSeat(S)
	S.misc.vehicleSeats += 1
end

function VISIT.SpawnLocation(S)
	S.misc.spawns += 1
end

function VISIT.ProximityPrompt(S)
	S.misc.prompts += 1
end

function VISIT.ClickDetector(S)
	S.misc.clickDetectors += 1
end

function VISIT.PackageLink(S)
	S.misc.packages += 1
end

function VISIT.Team(S)
	S.misc.teams += 1
end

function VISIT.Folder(S, f)
	if f.Name == "_Index" and f.Parent and f.Parent.Name == "Packages" and not S.frameworks["Wally (Packages._Index)"] then
		S.frameworks["Wally (Packages._Index)"] = pathOf(f)
	end
end

local function visitPart(S, p, inWorkspace)
	local P = S.part
	P.count += 1
	if not inWorkspace then -- templates in storage are not simulated or seen
		return
	end
	P.workspace += 1
	if not p.Anchored then
		P.unanchored += 1
		local model = p:FindFirstAncestorOfClass("Model")
		local character = false -- characters are meant to move (asked once per model: a model can have thousands of parts)
		if model then
			character = P.humanoidModels[model]
			if character == nil then
				character = model:FindFirstChildOfClass("Humanoid") ~= nil
				P.humanoidModels[model] = character
			end
		end
		if not character then
			P.loose += 1
		end
	end
	local class = p.ClassName
	if class == "MeshPart" then
		P.meshes += 1
		local id = p.MeshId
		if id ~= "" and not P.meshIds[id] then
			P.meshIds[id] = true
			P.uniqueMeshes += 1
		end
		if p.CanCollide and p.CollisionFidelity == Enum.CollisionFidelity.PreciseConvexDecomposition then
			P.precise += 1
		end
	elseif class == "UnionOperation" then
		P.unions += 1
	end
	if p.Transparency >= 0.95 then
		if p.CanCollide then
			P.invisibleColliders += 1
		end
		return
	end
	-- the look of the map: colors and materials weighted by surface (huge baseplates capped)
	local size, pos = p.Size, p.Position
	local area = math.min(2 * (size.X * size.Y + size.Y * size.Z + size.X * size.Z), 50000)
	P.area += area
	local c = p.Color
	local key = math.floor(c.R * 15 + 0.5) * 256 + math.floor(c.G * 15 + 0.5) * 16 + math.floor(c.B * 15 + 0.5)
	local bucket = P.colors[key]
	if not bucket then
		bucket = { area = 0, best = 0, hex = "" }
		P.colors[key] = bucket
	end
	bucket.area += area
	if area > bucket.best then
		bucket.best = area
		bucket.hex = c:ToHex():upper()
	end
	bump(P.materials, p.Material.Name, area)
	if math.abs(pos.X) < 50000 and math.abs(pos.Y) < 50000 and math.abs(pos.Z) < 50000 then
		local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
		if not P.minX then
			P.minX, P.minY, P.minZ = pos.X - hx, pos.Y - hy, pos.Z - hz
			P.maxX, P.maxY, P.maxZ = pos.X + hx, pos.Y + hy, pos.Z + hz
		else
			P.minX, P.minY, P.minZ = math.min(P.minX, pos.X - hx), math.min(P.minY, pos.Y - hy), math.min(P.minZ, pos.Z - hz)
			P.maxX, P.maxY, P.maxZ = math.max(P.maxX, pos.X + hx), math.max(P.maxY, pos.Y + hy), math.max(P.maxZ, pos.Z + hz)
		end
	end
end

local function visitGui(S, g, class, service)
	local U = S.ui
	U.guiObjects += 1
	if class == "TextBox" then
		U.textBoxes += 1
	end
	if service == "StarterGui" then
		addUiName(S, g.Name)
		local parent = g.Parent
		if parent and parent:IsA("ScreenGui") then -- a top-level menu: does it fit on a phone?
			local size = g.Size
			if size.X.Scale == 0 and size.Y.Scale == 0 and (size.X.Offset >= 300 or size.Y.Offset >= 250) then
				U.fixed += 1
				if #U.fixedExamples < 5 then
					table.insert(U.fixedExamples, pathOf(g))
				end
			end
		end
	end
end

local function visit(S, inst, inWorkspace, service)
	local class = inst.ClassName
	S.total += 1
	bump(S.classes, class)
	local handler = VISIT[class]
	if handler then
		handler(S, inst, inWorkspace, service)
	end
	if VFX_CLASSES[class] then
		bump(S.vfx.counts, class)
	end
	local weight = NAME_WEIGHT[class]
	local kind = kindOf(S, inst, class)
	if kind.part then
		visitPart(S, inst, inWorkspace)
		weight = weight or 1
	elseif kind.gui then
		visitGui(S, inst, class, service)
	elseif kind.constraint then
		S.misc.constraints += 1
	end
	if weight then
		addName(S, inst.Name, weight)
	end
	local fw = FRAMEWORK_BY_NAME[inst.Name]
	if fw and (class == "ModuleScript" or class == "Folder") and not S.frameworks[fw] then
		S.frameworks[fw] = pathOf(inst)
	end
end

local function readScript(S, s)
	local meta = metaOf(s)
	local C = S.code
	bump(C.counts, meta.class)
	if meta.class == "Script" and meta.client then
		C.clientRunContext += 1
	end
	if meta.class ~= "ModuleScript" and prop(s, "Enabled") == false then
		C.disabled += 1
	end
	pcall(checkPlacement, s, meta, S.findings)
	local ok, src = pcall(function()
		return s.Source
	end)
	if not ok or type(src) ~= "string" then
		C.unreadable += 1
		return
	end
	if src == "" then
		return
	end
	local lines = scanSource(meta, src, S.findings, C)
	C.lines += lines
	C.bytes += #src
	table.insert(C.largest, { path = meta.path, lines = lines, class = meta.class })
end

-- ---------------------------------------------------------------------------------------------
-- from the collected state to the report
-- ---------------------------------------------------------------------------------------------
-- MarketplaceService:GetProductInfoAsync; the deprecated GetProductInfo in a Studio that does not have it yet
local function productInfo(assetId)
	local market = game:GetService("MarketplaceService")
	local okMethod, method = pcall(function()
		return market.GetProductInfoAsync
	end)
	if okMethod and method then
		return method(market, assetId)
	end
	return market:GetProductInfo(assetId)
end

local function placeInfo()
	local info = { name = prop(game, "Name") or "?", placeId = prop(game, "PlaceId") or 0, gameId = prop(game, "GameId") or 0,
		creatorType = enumName(prop(game, "CreatorType")), creatorId = prop(game, "CreatorId"), placeVersion = prop(game, "PlaceVersion") }
	if type(info.placeId) == "number" and info.placeId > 0 then
		local ok, product = pcall(productInfo, info.placeId) -- yields (web request)
		if ok and type(product) == "table" then
			info.title = type(product.Name) == "string" and product.Name or nil
			local description = type(product.Description) == "string" and product.Description or nil
			if description and #description > 300 then -- cut at a whole character: half of one is invalid UTF-8 (JSON report, request to Claude)
				description = string.gsub(string.sub(description, 1, 300), "[\192-\255][\128-\191]*$", "")
			end
			info.description = description
			info.creator = type(product.Creator) == "table" and product.Creator.Name or nil
		end
	end
	return info
end

local function childNames(inst, n)
	local out = {}
	for _, child in children(inst) do
		if #out >= n then
			break
		end
		table.insert(out, child.Name)
	end
	return out
end

local function avatarInfo(S, animations)
	local H = S.humanoids
	local a = { rigs = { r6 = H.r6, r15 = H.r15 }, npcs = H.workspace }
	local sp = findService("StarterPlayer")
	if sp then
		a.walkSpeed = round(prop(sp, "CharacterWalkSpeed"), 2)
		a.useJumpPower = prop(sp, "CharacterUseJumpPower")
		a.jumpPower = round(prop(sp, "CharacterJumpPower"), 2)
		a.jumpHeight = round(prop(sp, "CharacterJumpHeight"), 2)
		a.maxSlope = round(prop(sp, "CharacterMaxSlopeAngle"), 1)
		a.cameraMode = enumName(prop(sp, "CameraMode"))
		a.maxZoom = round(prop(sp, "CameraMaxZoomDistance"), 1)
		a.loadAppearance = prop(sp, "LoadCharacterAppearance")
		a.autoJump = prop(sp, "AutoJumpEnabled")
		a.mouseLock = prop(sp, "EnableMouseLockOption")
		-- Game Settings > Avatar (R6 / R15 / PlayerChoice); not readable in every Studio version
		local avatarType = enumName(prop(sp, "GameSettingsAvatar"))
		if avatarType then
			a.rigType, a.rigSource = avatarType, "setările jocului"
		end
		local character = sp:FindFirstChild("StarterCharacter")
		if character then
			a.starterCharacter = true
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local rig = humanoid and enumName(prop(humanoid, "RigType"))
			a.starterCharacterRig = rig
			if rig then
				a.rigType, a.rigSource = rig, "StarterCharacter"
			end
			a.customAnimate = character:FindFirstChild("Animate") ~= nil
		end
		local characterScripts = sp:FindFirstChild("StarterCharacterScripts")
		if characterScripts then
			a.customAnimate = a.customAnimate or characterScripts:FindFirstChild("Animate") ~= nil
			a.customHealth = characterScripts:FindFirstChild("Health") ~= nil
			a.characterScripts = childNames(characterScripts, 15)
		end
		local playerScripts = sp:FindFirstChild("StarterPlayerScripts")
		if playerScripts then
			a.playerScripts = childNames(playerScripts, 15)
			a.customPlayerModule = playerScripts:FindFirstChild("PlayerModule") ~= nil
		end
	end
	if not a.rigType then -- guessed from the rigs and the animations in the game
		local rigs = animations.rigs or {}
		local r15, r6 = H.r15 + (rigs.R15 or 0), H.r6 + (rigs.R6 or 0)
		if r15 + r6 > 0 then
			a.rigType = r15 >= r6 and "R15" or "R6"
			a.rigSource = "dedus din rig-uri / animații"
		end
	end
	local players = findService("Players")
	if players then
		a.characterAutoLoads = prop(players, "CharacterAutoLoads")
		a.respawnTime = round(prop(players, "RespawnTime"), 1)
		a.maxPlayers = prop(players, "MaxPlayers")
	end
	return a
end

local function codeInfo(S)
	local C = S.code
	table.sort(C.largest, function(a, b)
		return a.lines > b.lines
	end)
	local largest = table.move(C.largest, 1, math.min(12, #C.largest), 1, {})
	local deprecated = {}
	for _, d in C.deprecated do
		table.insert(deprecated, d)
	end
	table.sort(deprecated, function(a, b)
		return a.count > b.count
	end)
	local frameworks = {}
	for name, path in S.frameworks do
		table.insert(frameworks, { name = name, path = path })
	end
	table.sort(frameworks, function(a, b)
		return a.name < b.name
	end)
	local remotes = {}
	for _, r in S.remotes.list do
		if #remotes >= 150 then
			break
		end
		table.insert(remotes, r)
	end
	local M = C.market
	return {
		scripts = C.counts.Script or 0, localScripts = C.counts.LocalScript or 0, modules = C.counts.ModuleScript or 0,
		clientRunContext = C.clientRunContext, disabled = C.disabled, unreadable = C.unreadable, lines = C.lines,
		bytes = C.bytes, largest = largest, services = top(C.services, 25, "name", "count"), remotes = remotes,
		remoteCounts = S.remotes.counts, frameworks = frameworks, deprecated = deprecated, datastore = C.datastore,
		marketplace = { gamepasses = sortedKeys(M.gamepasses, 30), products = sortedKeys(M.products, 30), prompts = M.prompts,
			productPrompts = M.productPrompts, processReceipt = M.receipts, receiptPaths = M.receiptPaths },
		runService = C.runService, renderStepped = C.renderStepped, touched = C.touched, clientEvents = C.clientEvents,
		remoteHandlers = C.remoteHandlers, unvalidated = C.unvalidated, busyLoops = C.busyLoops, animIds = C.animIds,
		flags = C.flags, hosts = sortedKeys(C.hosts, 30),
	}
end

local function performanceInfo(S, code)
	local P = S.part
	local bodyMovers = 0
	for _, class in BODY_MOVERS do
		bodyMovers += S.classes[class] or 0
	end
	local terrainCells = 0
	pcall(function()
		terrainCells = workspace.Terrain:CountCells()
	end)
	return {
		parts = P.count, workspaceParts = P.workspace, unanchored = P.unanchored, loose = P.loose, meshParts = P.meshes,
		uniqueMeshes = P.uniqueMeshes, preciseCollision = P.precise, unions = P.unions, invisibleColliders = P.invisibleColliders,
		emitters = S.vfx.counts.ParticleEmitter or 0, particleRate = round(S.vfx.rate), heavyEmitters = S.vfx.heavy,
		lights = S.lights.count, shadowLights = S.lights.shadows, sounds = S.sounds.count, decals = S.decals.count,
		uniqueTextures = count(S.decals.ids), humanoids = S.humanoids.workspace, constraints = S.misc.constraints,
		bodyMovers = bodyMovers, runService = code.runService, renderStepped = code.renderStepped, touched = code.touched,
		busyLoops = code.busyLoops, streamingEnabled = prop(workspace, "StreamingEnabled"),
		gravity = round(prop(workspace, "Gravity"), 1), terrainCells = terrainCells,
	}
end

local function vfxInfo(S)
	local V = S.vfx
	local lostCube = 0
	local rs = findService("ReplicatedStorage")
	local effects = rs and rs:FindFirstChild("LostCube") and rs.LostCube:FindFirstChild("Effects")
	if effects then
		lostCube = #effects:GetChildren()
	end
	local total = 0
	for _, n in V.counts do
		total += n
	end
	local colors = {}
	for _, c in top(V.colors, 10, "hex", "count") do
		table.insert(colors, c.hex)
	end
	return { counts = V.counts, total = total, textures = top(V.textures, 10, "id", "count"), colors = colors,
		examples = V.examples, lostCubeEffects = lostCube }
end

local function animationInfo(S)
	local A = S.anim
	return { count = A.count, uniqueIds = count(A.ids), list = A.list, kfsCount = A.kfsCount, kfs = A.kfs, rigs = A.rigs,
		saves = A.saves, controllers = A.controllers, animators = A.animators, codeIds = S.code.animIds }
end

local POST_EFFECTS = { BloomEffect = true, BlurEffect = true, ColorCorrectionEffect = true, SunRaysEffect = true,
	DepthOfFieldEffect = true }

local function styleInfo(S)
	local st = { lighting = {}, effects = {} }
	local L = findService("Lighting")
	if L then
		local l = st.lighting
		l.technology = enumName(prop(L, "Technology"))
		l.clockTime = round(prop(L, "ClockTime"), 1)
		l.brightness = round(prop(L, "Brightness"), 2)
		l.ambient = hexOf(prop(L, "Ambient"))
		l.outdoorAmbient = hexOf(prop(L, "OutdoorAmbient"))
		l.globalShadows = prop(L, "GlobalShadows")
		l.fogEnd = round(prop(L, "FogEnd"))
		l.fogColor = hexOf(prop(L, "FogColor"))
		l.exposure = round(prop(L, "ExposureCompensation"), 2)
		l.envDiffuse = round(prop(L, "EnvironmentDiffuseScale"), 2)
		l.envSpecular = round(prop(L, "EnvironmentSpecularScale"), 2)
		for _, child in children(L) do
			local class = child.ClassName
			if class == "Atmosphere" then
				st.atmosphere = { density = round(prop(child, "Density"), 2), haze = round(prop(child, "Haze"), 2),
					glare = round(prop(child, "Glare"), 2), color = hexOf(prop(child, "Color")), decay = hexOf(prop(child, "Decay")) }
			elseif class == "Sky" then
				local back = prop(child, "SkyboxBk")
				st.sky = { custom = type(back) == "string" and back ~= "" and not string.find(back, "textures/sky/", 1, true) }
			elseif POST_EFFECTS[class] then
				local text = string.gsub(class, "Effect$", "")
				if class == "ColorCorrectionEffect" then
					text = string.format("ColorCorrection (luminozitate %s, contrast %s, saturație %s, nuanță #%s)",
						tostring(round(prop(child, "Brightness"), 2)), tostring(round(prop(child, "Contrast"), 2)),
						tostring(round(prop(child, "Saturation"), 2)), hexOf(prop(child, "TintColor")) or "?")
				elseif class == "BloomEffect" then
					text = string.format("Bloom (intensitate %s, prag %s)", tostring(round(prop(child, "Intensity"), 2)),
						tostring(round(prop(child, "Threshold"), 2)))
				elseif class == "BlurEffect" then
					text = "Blur (mărime " .. tostring(round(prop(child, "Size"), 1)) .. ")"
				elseif class == "SunRaysEffect" then
					text = "SunRays (intensitate " .. tostring(round(prop(child, "Intensity"), 2)) .. ")"
				end
				if prop(child, "Enabled") == false then
					text ..= " [oprit]"
				end
				table.insert(st.effects, text)
			end
		end
	end
	local P = S.part
	local buckets = {}
	for _, b in P.colors do
		table.insert(buckets, b)
	end
	table.sort(buckets, function(a, b)
		return a.area > b.area
	end)
	st.colors = {}
	for i = 1, math.min(8, #buckets) do
		st.colors[i] = { hex = buckets[i].hex, share = round(buckets[i].area / math.max(1, P.area) * 100, 1) }
	end
	st.materials = {}
	for i, m in top(P.materials, 8, "material", "area") do
		st.materials[i] = { name = tostring(m.material), share = round(m.area / math.max(1, P.area) * 100, 1) }
	end
	if P.minX then
		st.bounds = { x = round(P.maxX - P.minX), y = round(P.maxY - P.minY), z = round(P.maxZ - P.minZ),
			center = { x = round((P.maxX + P.minX) / 2), y = round((P.maxY + P.minY) / 2), z = round((P.maxZ + P.minZ) / 2) } }
	end
	st.terrain = { cells = 0, clouds = false }
	pcall(function()
		st.terrain.cells = workspace.Terrain:CountCells()
		st.terrain.clouds = workspace.Terrain:FindFirstChildOfClass("Clouds") ~= nil
	end)
	st.spawns = S.misc.spawns
	return st
end

local function uiInfo(S)
	local U = S.ui
	local names = {}
	for _, original in U.names do
		table.insert(names, original)
	end
	table.sort(names)
	local found = {}
	for _, original in names do
		breathe()
		local toks = tokens(original)
		for _, cat in UI_CATEGORIES do
			for _, t in toks do
				if matchWord(cat.set, t) then
					found[cat.key] = found[cat.key] or {}
					if #found[cat.key] < 5 then
						table.insert(found[cat.key], original)
					end
					break
				end
			end
		end
	end
	local categories = {}
	for _, cat in UI_CATEGORIES do
		if found[cat.key] then
			table.insert(categories, { key = cat.key, label = cat.label, names = found[cat.key] })
		end
	end
	return { screenGuis = U.screenGuis, names = U.guiNames, categories = categories, guiObjects = U.guiObjects,
		fixedSize = U.fixed, fixedExamples = U.fixedExamples, aspectConstraints = U.aspect, textBoxes = U.textBoxes,
		billboards = U.billboards, surfaceGuis = U.surfaceGuis }
end

local function audioInfo(S)
	local A = S.sounds
	return { sounds = A.count, looped = A.looped, playing = A.playing, uniqueIds = count(A.ids), groups = A.groups,
		music = A.musicCount > 0, musicNames = A.music }
end

-- the genre, from names (scripts, tools, remotes, GUIs, folders, parts...) and a few signals from code and objects
local function guessGenre(S, report)
	local scores, evidence = {}, {}
	local function give(key, points, why, weight)
		scores[key] = (scores[key] or 0) + points
		evidence[key] = evidence[key] or {}
		table.insert(evidence[key], { why, weight or points })
	end
	for _, entry in S.names do
		breathe()
		local toks = tokens(entry.name)
		for _, g in GENRES do
			for _, t in toks do
				if matchWord(g.set, t) then
					give(g.key, entry.weight, entry.name)
					break
				end
			end
		end
	end
	local code, misc, flags = report.code, S.misc, report.code.flags or {}
	local frameworks = {}
	for _, fw in code.frameworks do
		frameworks[fw.name] = true
	end
	if misc.tools > 0 then
		give("combat", math.min(misc.tools, 5), string.format("%d Tool", misc.tools))
	end
	if (flags.damage or 0) > 0 then
		give("combat", 3 + math.min(flags.damage, 5), "TakeDamage în cod", 6)
		give("shooter", 1, "TakeDamage în cod")
	end
	if (flags.hitbox or 0) > 0 then
		give("combat", 4, "hitbox-uri în cod", 6)
	end
	if (flags.ragdoll or 0) > 0 then
		give("combat", 2, "ragdoll")
	end
	if frameworks.FastCast then
		give("shooter", 8, "FastCast", 8)
	end
	if frameworks.RaycastHitbox or frameworks.ClientCast then
		give("combat", 6, "RaycastHitbox / ClientCast", 8)
	end
	if misc.vehicleSeats > 0 then
		give("racing", 2 * math.min(misc.vehicleSeats, 5), misc.vehicleSeats .. " VehicleSeat")
	end
	if misc.spawns >= 6 then
		give("obby", 5, misc.spawns .. " SpawnLocation (checkpoint-uri?)")
	end
	if misc.prompts >= 8 then
		give("roleplay", 2, misc.prompts .. " ProximityPrompt")
		give("horror", 1, misc.prompts .. " ProximityPrompt")
	end
	if misc.teams >= 2 then
		give("roleplay", 1, misc.teams .. " echipe")
		give("shooter", 1, misc.teams .. " echipe")
	end
	local lighting = report.style.lighting or {}
	if type(lighting.clockTime) == "number" and (lighting.clockTime < 5.5 or lighting.clockTime > 19.5) then
		give("horror", 2, "noapte (ClockTime " .. lighting.clockTime .. ")")
	end
	if type(lighting.fogEnd) == "number" and lighting.fogEnd < 300 then
		give("horror", 2, "ceață deasă")
	end

	local list, total = {}, 0
	for _, g in GENRES do
		local s = scores[g.key] or 0
		total += s
		if s > 0 then
			table.insert(list, { key = g.key, label = g.label, score = s })
		end
	end
	table.sort(list, function(a, b)
		return a.score > b.score
	end)
	local best = list[1]
	if not best or best.score < 3 then
		return { key = "unknown", label = "neclar (prea puține indicii)", confidence = 0, level = "mică", evidence = {},
			scores = list }
	end
	local confidence = math.clamp(best.score / math.max(1, total) * 1.4, 0, 1) * math.clamp(best.score / 20, 0.25, 1)
	local ev = evidence[best.key] or {}
	table.sort(ev, function(a, b)
		if a[2] ~= b[2] then
			return a[2] > b[2]
		end
		return a[1] < b[1]
	end)
	local names = {}
	for i = 1, math.min(10, #ev) do
		names[i] = ev[i][1]
	end
	local second = list[2]
	return {
		key = best.key, label = best.label, confidence = round(confidence, 2),
		level = confidence >= 0.6 and "mare" or (confidence >= 0.35 and "medie" or "mică"), evidence = names,
		secondary = second and second.score >= best.score * 0.6 and { key = second.key, label = second.label } or nil,
		scores = table.move(list, 1, math.min(5, #list), 1, {}),
	}
end

local function buildIssues(S, report)
	local issues, perKind, overflow = {}, {}, {}
	local scriptsInParts = 0
	for _, f in S.findings do
		local kind = f.kind or ""
		if string.sub(kind, 1, 11) == "deprecated." then
			continue -- summed up below
		elseif kind == "structure.scriptInPart" then
			scriptsInParts += 1
			continue
		end
		perKind[kind] = (perKind[kind] or 0) + 1
		if perKind[kind] <= MAX_PER_KIND then
			table.insert(issues, f)
		else
			local o = overflow[kind] or { n = 0, severity = f.severity }
			o.n += 1
			overflow[kind] = o
		end
	end
	for kind, o in overflow do
		table.insert(issues, { severity = o.severity, kind = kind,
			message = "… și încă " .. o.n .. " cazuri de același tip (" .. kind .. ")" })
	end
	local function add(severity, kind, message, path, line)
		table.insert(issues, { severity = severity, kind = kind, message = message, path = path, line = line })
	end
	local code, perf, avatar, anim, ui = report.code, report.performance, report.avatar, report.animations, report.ui
	local flags = code.flags or {}
	local frameworks = {}
	for _, fw in code.frameworks do
		frameworks[fw.name] = true
	end
	local ds = code.datastore

	-- data and money
	local savesData = ds.used or frameworks.ProfileService or frameworks.ProfileStore or frameworks.DataStore2
	if (flags.leaderstats or 0) > 0 and not savesData then
		add("high", "data.noSave", "Jocul are leaderstats, dar nu folosește DataStore — progresul jucătorilor se pierde la ieșire")
	end
	if ds.used and not ds.bindToClose then
		add("medium", "data.bindToClose", "DataStore fără game:BindToClose — datele se pot pierde când serverul se închide")
	end
	local market = code.marketplace
	if (market.productPrompts > 0 or #market.products > 0) and market.processReceipt == 0 then
		add("high", "market.noReceipt", "Se vând Developer Products, dar nu există MarketplaceService.ProcessReceipt — "
			.. "jucătorii plătesc și nu primesc nimic")
	elseif market.processReceipt > 1 then
		add("medium", "market.multiReceipt", "ProcessReceipt e setat în " .. market.processReceipt
			.. " locuri — doar ultimul contează, restul produselor nu se livrează", market.receiptPaths[1])
	end

	-- configuration
	local sss = findService("ServerScriptService")
	if sss and prop(sss, "LoadStringEnabled") == true then
		local used = (perKind["security.loadstring"] or 0) > 0
		add(used and "high" or "medium", "security.loadstringEnabled",
			"ServerScriptService.LoadStringEnabled e activat — permite rularea de cod din text pe server"
				.. (used and " (și există scripturi cu loadstring)" or ""))
	end
	if ui.textBoxes > 0 and #code.remotes > 0 and (flags.filter or 0) == 0 then
		add("low", "rules.filter", "Există TextBox-uri și remote-uri, dar nicio filtrare (TextService:FilterStringAsync) — "
			.. "dacă textul scris de jucători ajunge la alții (nume, mesaje, semne), trebuie filtrat (regulile Roblox)")
	end
	if code.unvalidated >= 3 then
		add("medium", "remote.unvalidated", code.unvalidated .. " handler-e de remote nu verifică deloc datele primite — "
			.. "un exploiter poate trimite orice")
	end

	-- performance
	if perf.streamingEnabled == false and perf.workspaceParts > 15000 then
		add("medium", "perf.streaming", perf.workspaceParts .. " piese în Workspace fără StreamingEnabled — "
			.. "telefoanele încarcă toată harta")
	end
	if perf.loose > 300 then
		add("medium", "perf.unanchored", perf.loose .. " piese neancorate în Workspace (fizică pe server la fiecare frame) — "
			.. "ancorează ce nu trebuie să cadă")
	end
	if perf.particleRate > 3000 or perf.heavyEmitters > 15 then
		add("medium", "perf.particles", string.format("Particule: %s/s în total, %d emițătoare foarte dense — FPS mic pe telefon",
			int(perf.particleRate), perf.heavyEmitters))
	end
	if perf.shadowLights > 25 then
		add("medium", "perf.shadows", perf.shadowLights .. " lumini cu umbre — fiecare costă; lasă umbre doar la cele importante")
	end
	if perf.humanoids > 80 then
		add("medium", "perf.humanoids", perf.humanoids .. " Humanoid-uri în Workspace — NPC-urile cu Humanoid sunt scumpe")
	end
	if perf.preciseCollision > 150 then
		add("low", "perf.collision", perf.preciseCollision .. " MeshPart-uri cu coliziune PreciseConvexDecomposition — "
			.. "folosește Box / Hull unde se poate")
	end
	if perf.unions > 400 then
		add("low", "perf.unions", perf.unions .. " Union-uri — înlocuiește-le cu MeshPart-uri unde se poate")
	end
	if perf.runService > 40 then
		add("low", "perf.runService", perf.runService .. " conexiuni la Heartbeat / Stepped / RenderStepped — "
			.. "adună-le într-un singur loop")
	end
	if perf.touched > 150 then
		add("low", "perf.touched", perf.touched .. " handler-e Touched — folosește CollectionService + un singur script")
	end
	if perf.bodyMovers > 0 then
		add("low", "deprecated.bodyMoverInstances", perf.bodyMovers .. " BodyVelocity / BodyGyro / BodyPosition în joc → "
			.. "LinearVelocity / AlignOrientation / AlignPosition")
	end
	if scriptsInParts >= 10 then
		add("low", "structure.scriptInPart", scriptsInParts .. " scripturi stau în piese din Workspace — "
			.. "folosește CollectionService și un singur script (și verifică free model-urile)")
	end

	-- animations
	local rigs = anim.rigs or {}
	if avatar.rigType == "R15" and (rigs.R6 or 0) > 0 then
		add("medium", "anim.rig", rigs.R6 .. " animații (KeyframeSequence) sunt făcute pentru R6, dar jocul folosește R15")
	elseif avatar.rigType == "R6" and (rigs.R15 or 0) > 0 then
		add("medium", "anim.rig", rigs.R15 .. " animații (KeyframeSequence) sunt făcute pentru R15, dar jocul folosește R6")
	end

	-- interface
	if ui.fixedSize >= 3 then
		add("low", "ui.fixedSize", ui.fixedSize .. " meniuri au mărime fixă în pixeli (Offset) — ies din ecran pe telefon; "
			.. "folosește Scale + UIAspectRatioConstraint", ui.fixedExamples[1])
	end

	-- deprecated APIs for the whole game
	for _, d in code.deprecated do
		add("low", "deprecated." .. d.key, string.format("%s ×%d în %d scripturi → %s", d.label, d.count, d.scripts, d.fix),
			d.path, d.line)
	end
	return sortFindings(issues)
end

local GENRE_TIPS = {
	combat = { "Jocul pare de luptă: efecte de lovitură (impact, scântei, undă pe sol) la fiecare atac — fă-le în tab-ul VFX "
		.. "și leagă-le de markerii animațiilor.", "Animații de atac / combo, blocare și dodge cu easing (tab-ul Animații); "
		.. "lovitura se simte mai bine cu un mic hit-stop și camera shake." },
	simulator = { "Efecte la colectare (monede care zboară spre jucător), la hatch de ouă și la rebirth — sunt momentele care "
		.. "țin jucătorii.", "Multiplicatorii, pets și rebirth-urile se calculează doar pe server; salvează-le cu ProfileStore / DataStore." },
	tycoon = { "Efecte la cumpărarea unui buton (piesele apar cu tween + particule) și la încasarea banilor.",
		"Salvează ce butoane s-au cumpărat (DataStore) ca tycoon-ul să se refacă la revenire." },
	obby = { "Efect + sunet la checkpoint și la moarte, plus o urmă (Trail) ca recompensă.",
		"Salvează etapa în DataStore și oferă „Skip stage” ca Developer Product." },
	rpg = { "Efecte pentru level up, quest terminat și loot (culori pe rarități).",
		"Animații pentru NPC-uri (idle, vorbit) și pentru fiecare abilitate." },
	horror = { "Lighting: Future + Atmosphere densă, ClockTime de noapte, ColorCorrection rece; sunete 3D ambientale.",
		"Animații pentru monstru (alergare, jumpscare) și efecte subtile (praf, ceață, scântei de la lumini)." },
	racing = { "Particule de drift și fum la roți, Trail pe vehicul la boost, scântei la coliziuni.",
		"FOV-ul camerei crește cu viteza (TweenService) — senzație de viteză mult mai bună." },
	shooter = { "Muzzle flash, trasoare (Beam) și impact pe suprafețe, cu decal-uri de gloanțe.",
		"Validează împușcăturile pe server (raycast de verificare, cadență), nu doar pe client." },
	roleplay = { "Emote-uri și animații pentru interacțiuni; efecte discrete pentru ProximityPrompt-uri.",
		"UI clar pentru joburi / case și salvarea lor în DataStore." },
	towerdefense = { "Efecte la plasarea turnurilor, la upgrade și pentru fiecare tip de atac; inamici cu animații de mers și moarte.",
		"Mișcă inamicii pe server cu poziții calculate (fără Humanoid) — mult mai performant." },
}

local function buildSuggestions(S, report)
	local out = {}
	local function add(text)
		if #out < 14 then
			table.insert(out, text)
		end
	end
	local genre, code, perf, vfx, anim, style, audio =
		report.genre, report.code, report.performance, report.vfx, report.animations, report.style, report.audio
	local flags = code.flags or {}
	for _, tip in GENRE_TIPS[genre.key] or {} do
		add(tip)
	end
	if genre.key == "combat" and (flags.hitbox or 0) == 0 then
		add("Hitbox pe server (workspace:GetPartBoundsInBox) cu verificare de distanță și cooldown la fiecare remote de atac.")
	end
	local effects = vfx.total or 0
	if effects < 8 then
		add("Jocul are foarte puține efecte vizuale (" .. effects .. ") — LostCube le face rapid în tab-ul VFX, "
			.. "iar Claude le poate crea din descriere.")
	end
	if (anim.count or 0) + (anim.kfsCount or 0) < 4 then
		add("Aproape nicio animație proprie — previzualizează și ajustează-le cu easing în tab-ul Animații.")
	end
	local tech = style.lighting and style.lighting.technology
	if tech and tech ~= "Future" and tech ~= "ShadowMap" then
		add("Lighting.Technology = " .. tech .. "; Future (sau ShadowMap) dă umbre și lumini moderne.")
	end
	if not style.atmosphere then
		add("Adaugă un Atmosphere în Lighting (Density ~0.3, Haze 1–2) pentru adâncime și culoare.")
	end
	if #(style.effects or {}) == 0 then
		add("Un ColorCorrection ușor (Contrast 0.1, Saturation 0.1) și un Bloom fin schimbă mult aspectul.")
	end
	local waits = 0
	for _, d in code.deprecated do
		if d.key == "wait" or d.key == "spawn" or d.key == "delay" then
			waits += d.count
		end
	end
	if waits > 0 then
		add("Înlocuiește wait() / spawn() / delay() cu task.wait() / task.spawn() / task.delay() (" .. waits .. " locuri).")
	end
	if (flags.keyboard or 0) > 0 and (flags.mobile or 0) == 0 then
		add("Jocul citește tastatura, dar nu are controale pentru telefon — ContextActionService:BindAction cu butoane pe ecran.")
	end
	if not audio.music then
		add("N-am găsit muzică de fundal — un Sound cu Looped în SoundService schimbă mult atmosfera.")
	end
	local scripts = code.scripts + code.localScripts + code.modules
	if scripts > 20 and code.modules < scripts * 0.15 then
		add("Puține ModuleScript-uri: mută logica comună în module (mai ușor de întreținut, și Claude o găsește mai ușor).")
	end
	local biggest = code.largest[1]
	if biggest and biggest.lines > 1500 then
		add("Scriptul " .. biggest.path .. " are " .. biggest.lines .. " linii — împarte-l în module.")
	end
	if code.unvalidated > 0 then
		add("Verifică pe server tot ce vine prin remote-uri (typeof, limite, cooldown) — " .. code.unvalidated
			.. " handler-e acceptă orice.")
	end
	if perf.streamingEnabled == false and perf.workspaceParts > 5000 then
		add("Activează Workspace.StreamingEnabled — harta se încarcă pe bucăți, mai rapid pe telefon.")
	end
	return out
end

-- ---------------------------------------------------------------------------------------------
-- storage (ServerStorage.LostCubeAnalysis)
-- ---------------------------------------------------------------------------------------------
local function storage()
	local ok, service = pcall(function()
		return game:GetService("ServerStorage")
	end)
	return ok and service or nil
end

local function folder(create)
	local service = storage()
	if not service then
		return nil
	end
	local f = service:FindFirstChild(Analyzer.FOLDER)
	if not f and create then
		f = Instance.new("Folder")
		f.Name = Analyzer.FOLDER
		f.Parent = service
	end
	return f
end

local function setString(parent, name, value)
	local v = parent:FindFirstChild(name)
	if v and not v:IsA("StringValue") then
		v:Destroy()
		v = nil
	end
	if not v then
		v = Instance.new("StringValue")
		v.Name = name
		v.Parent = parent
	end
	v.Value = value
	return v
end

-- one undo step per write (Ctrl+Z removes the saved analysis instead of being mixed into the user's own edit)
local function record(name, fn)
	local okBegin, id = pcall(ChangeHistoryService.TryBeginRecording, ChangeHistoryService, "LostCube: " .. name)
	local ok, err = pcall(fn)
	if okBegin and id then
		pcall(ChangeHistoryService.FinishRecording, ChangeHistoryService, id,
			ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel)
	end
	if not ok then
		error(err, 0)
	end
end

-- anything -> what HttpService:JSONEncode accepts (Roblox types become strings / plain tables)
local function plain(v, depth)
	depth = depth or 0
	local t = typeof(v)
	if t == "number" then
		return (v ~= v or v == math.huge or v == -math.huge) and 0 or v
	elseif t == "string" or t == "boolean" or t == "nil" then
		return v
	elseif t == "Color3" then
		return v:ToHex():upper()
	elseif t == "Vector3" then
		return { x = round(v.X, 2), y = round(v.Y, 2), z = round(v.Z, 2) }
	elseif t == "Vector2" then
		return { x = round(v.X, 2), y = round(v.Y, 2) }
	elseif t == "CFrame" then
		return plain(v.Position, depth)
	elseif t == "EnumItem" then
		return v.Name
	elseif t == "Instance" then
		return fullName(v)
	elseif t == "BrickColor" then
		return v.Name
	elseif t == "NumberRange" then
		return { min = v.Min, max = v.Max }
	elseif t == "table" then
		if depth > 20 then
			return false
		end
		local n, entries = #v, 0
		for _ in v do
			entries += 1
		end
		if entries == n then -- an array
			local out = table.create(n)
			for i = 1, n do
				local x = plain(v[i], depth + 1)
				out[i] = if x == nil then false else x
			end
			return out
		end
		local out = {}
		for k, x in v do
			out[type(k) == "string" and k or tostring(k)] = plain(x, depth + 1)
		end
		return out
	end
	return tostring(v)
end

-- cut points that never split a UTF-8 character
local function chunks(text, size)
	local out, pos = {}, 1
	while pos <= #text do
		local stop = math.min(#text, pos + size - 1)
		while stop < #text and stop > pos do
			local nextByte = string.byte(text, stop + 1)
			if nextByte < 0x80 or nextByte >= 0xC0 then
				break
			end
			stop -= 1
		end
		table.insert(out, string.sub(text, pos, stop))
		pos = stop + 1
	end
	if #out == 0 then
		out[1] = ""
	end
	return out
end

local function readAI(f)
	local v = f and f:FindFirstChild("AI")
	if v and v:IsA("StringValue") and v.Value ~= "" then
		return { text = v.Value, model = v:GetAttribute("Model") or "", at = v:GetAttribute("At") or 0 }
	end
	return nil
end

function Analyzer.save(report)
	assert(type(report) == "table", "LostCube: raport invalid")
	local copy = table.clone(report)
	copy.ai, copy.saveError = nil, nil -- Claude's analysis has its own StringValue
	local json = HttpService:JSONEncode(plain(copy))
	local context = Analyzer.context(report)
	record("analiza jocului", function()
		local f = folder(true)
		assert(f, "LostCube: ServerStorage nu e disponibil")
		local parts = chunks(json, CHUNK)
		for i, part in parts do
			setString(f, i == 1 and "Report" or ("Report" .. i), part)
		end
		for _, child in f:GetChildren() do
			local k = tonumber(string.match(child.Name, "^Report(%d+)$"))
			if k and k > #parts then
				child:Destroy()
			end
		end
		setString(f, "Context", context)
		f:SetAttribute("Version", Analyzer.VERSION)
		f:SetAttribute("At", report.at or os.time())
		f:SetAttribute("Chunks", #parts)
		if type(report.ai) == "table" and type(report.ai.text) == "string" then
			local v = setString(f, "AI", report.ai.text)
			v:SetAttribute("Model", report.ai.model or "")
			v:SetAttribute("At", report.ai.at or os.time())
		end
	end)
end

-- The decoded report of the last load(): decoding the JSON of a big game takes a good while and the panels ask on every
-- redraw. The stored text is compared on every call instead of listening for changes, so whatever changes it (a new
-- analysis, Ctrl+Z, the folder deleted or replaced, someone editing the StringValue) is noticed, with no connections.
-- { folder =, parts = { the Report chunks }, report = table | false (unreadable), ai = what report.ai was made from }
local loaded
local published = setmetatable({}, { __mode = "k" }) -- the tables load() handed out (safe keys of the context cache)
local contexts = setmetatable({}, { __mode = "k" }) -- report -> { [maxChars] = Markdown }

local function sameAI(a, b)
	if a == nil or b == nil then
		return a == b
	end
	return a.text == b.text and a.model == b.model and a.at == b.at
end

-- Analyzer.load() hands out the same table until the stored analysis changes: treat it as READ-ONLY (copy it with
-- table.clone, or build a new table, before changing anything). Analyzer itself never changes a table it handed out.
function Analyzer.load()
	local f = folder(false)
	if not f then
		loaded = nil
		return nil
	end
	local first = f:FindFirstChild("Report")
	if not first or not first:IsA("StringValue") or first.Value == "" then
		loaded = nil
		return nil
	end
	local parts = { first.Value }
	for i = 2, tonumber(f:GetAttribute("Chunks")) or 1 do
		local v = f:FindFirstChild("Report" .. i)
		if not v or not v:IsA("StringValue") then
			loaded = nil
			return nil
		end
		table.insert(parts, v.Value)
	end
	local ai = readAI(f)
	local cache = loaded
	if cache and cache.folder == f and #cache.parts == #parts then
		local same = true
		for i, part in parts do
			if cache.parts[i] ~= part then
				same = false
				break
			end
		end
		if same then
			if not cache.report then
				return nil
			end
			if not (cache.report.ai == cache.ai and sameAI(cache.ai, ai)) then -- Claude's analysis changed: a new table
				local report = table.clone(cache.report)
				report.ai = ai
				cache.report, cache.ai = report, ai
			end
			published[cache.report] = true
			return cache.report
		end
	end
	local ok, report = pcall(HttpService.JSONDecode, HttpService, table.concat(parts))
	if not ok or type(report) ~= "table" then
		loaded = { folder = f, parts = parts, report = false }
		return nil
	end
	report.ai = ai
	loaded = { folder = f, parts = parts, report = report, ai = ai }
	published[report] = true
	return report
end

-- Claude's analysis of the game (Markdown), saved next to the report: Analyzer.load().ai = { text, model, at }
function Analyzer.setAI(text, model)
	assert(type(text) == "string", "LostCube: textul analizei trebuie să fie text")
	record("analiza Claude", function()
		local f = folder(true)
		assert(f, "LostCube: ServerStorage nu e disponibil")
		local v = setString(f, "AI", text)
		v:SetAttribute("Model", tostring(model or ""))
		v:SetAttribute("At", os.time())
	end)
end

-- the instance a finding points at ("Workspace.Map.Script"); names may contain dots, so every split is tried
function Analyzer.resolve(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local cached = paths[path]
	if cached and cached.Parent and fullName(cached) == path then
		return cached
	end
	local function walk(node, rest, depth)
		if depth > 64 then
			return nil
		end
		local candidates = {}
		for _, child in children(node) do
			local name = child.Name
			if rest == name then
				return child
			elseif #rest > #name and string.sub(rest, 1, #name + 1) == name .. "." then
				table.insert(candidates, child)
			end
		end
		table.sort(candidates, function(a, b)
			return #a.Name > #b.Name
		end)
		for _, child in candidates do
			local found = walk(child, string.sub(rest, #child.Name + 2), depth + 1)
			if found then
				return found
			end
		end
		return nil
	end
	return walk(game, path, 0)
end

-- Instance / script counts of the game right now. Counting walks every instance, so it never runs inside a redraw (the
-- panel asks on every one): isStale() uses the last numbers and asks for fresh ones in the background, at most once
-- every COUNT_EVERY seconds, yielding like the scan does.
local COUNT_EVERY = 180
local countCache -- { t = os.time(), instances =, scripts = } (numbers are nil when counting failed)
local counting = false
local countWaiters = {} -- functions to call (once) when a background count finishes

local function countGame()
	local instances, scripts = 0, 0
	for _, name in SERVICES do
		local service = findService(name)
		for _, child in service and children(service) or {} do
			if not skipTop(child) then
				local ok, descendants = pcall(child.GetDescendants, child)
				if ok then
					instances += #descendants + 1
					if SCRIPT_CLASSES[child.ClassName] then
						scripts += 1
					end
					for i, d in descendants do
						if SCRIPT_CLASSES[d.ClassName] then
							scripts += 1
						end
						if i % 5000 == 0 then
							breathe()
						end
					end
				end
				breathe()
			end
		end
	end
	return instances, scripts
end

local function requestCounts(onReady)
	if onReady then
		countWaiters[onReady] = true
	end
	if counting or Analyzer.running then
		return
	end
	counting = true
	task.defer(function() -- after the current redraw, not inside it
		local startedAt = os.time()
		lastYield = os.clock()
		local ok, instances, scripts = pcall(countGame)
		counting = false
		if countCache and countCache.t >= startedAt then
			-- a scan finished meanwhile: its numbers are newer
		elseif ok then
			countCache = { t = os.time(), instances = instances, scripts = scripts }
		elseif countCache then
			countCache.t = os.time() -- counting failed: keep the last numbers, try again later
		else
			countCache = { t = os.time() }
		end
		local waiters = countWaiters
		countWaiters = {}
		for fn in waiters do
			pcall(fn)
		end
	end)
end

-- Older than 7 days, made by another version of the analyzer, or the game changed a lot since. The "changed a lot" part
-- needs the instance counts: when they are not known yet (or old) they are counted in the background and the answer
-- meanwhile only looks at the age; `onReady` (optional) is called once the new counts are there (ask again then).
function Analyzer.isStale(report, onReady)
	if type(report) ~= "table" or report.version ~= Analyzer.VERSION then
		return true
	end
	if os.time() - (tonumber(report.at) or 0) > STALE_AFTER then
		return true
	end
	local now = countCache
	if not now or os.time() - now.t >= COUNT_EVERY then
		requestCounts(onReady)
	end
	if not (now and now.instances and now.scripts) then
		return false
	end
	local totals = report.totals or {}
	local function changed(current, before, relative, absolute)
		before = tonumber(before) or 0
		local diff = math.abs(current - before)
		return diff >= absolute and diff > before * relative
	end
	return changed(now.instances, totals.instances, 0.25, 500) or changed(now.scripts, totals.scripts, 0.15, 5)
end

-- ---------------------------------------------------------------------------------------------
-- the scan
-- ---------------------------------------------------------------------------------------------
local function scan(onProgress)
	local started = os.clock()
	lastYield = os.clock()
	local lastProgress = 0
	local function progress(fraction, label, force)
		if onProgress and (force or os.clock() - lastProgress > 0.05) then
			lastProgress = os.clock()
			pcall(onProgress, math.clamp(fraction, 0, 1), label)
		end
	end
	local S = newState()

	-- 1. gather (whole subtrees of each service's children; the skipped ones never enter the list)
	progress(0, "Adun instanțele jocului…", true)
	local list, ranges = {}, {}
	for si, name in SERVICES do
		local service = findService(name)
		if service then
			local entry = { service = name, count = 0, children = {} }
			local from = #list + 1
			for _, child in children(service) do
				if not skipTop(child) then
					local ok, descendants = pcall(child.GetDescendants, child)
					descendants = ok and descendants or {}
					list[#list + 1] = child
					table.move(descendants, 1, #descendants, #list + 1, list)
					table.insert(entry.children, { name = child.Name, class = child.ClassName, count = #descendants + 1 })
					entry.count += #descendants + 1
					breathe()
				end
			end
			if #list >= from then
				table.insert(ranges, { name = name, from = from, to = #list })
			end
			table.sort(entry.children, function(a, b)
				return a.count > b.count
			end)
			if #entry.children > 15 then
				entry.more = #entry.children - 15
				entry.children = table.move(entry.children, 1, 15, 1, {})
			end
			if entry.count > 0 then
				table.insert(S.structure, entry)
				S.services[name] = entry.count
			end
		end
		progress(0.08 * si / #SERVICES, "Adun instanțele: " .. name, false)
	end

	-- 2. every instance once
	local total = math.max(1, #list)
	for _, range in ranges do
		local inWorkspace = range.name == "Workspace"
		for i = range.from, range.to do
			if not pcall(visit, S, list[i], inWorkspace, range.name) then
				S.errors += 1
			end
			if i % 50 == 0 then
				breathe()
				progress(0.08 + 0.47 * i / total, string.format("%s: %d / %d instanțe", range.name, i, total))
			end
		end
	end
	list = nil

	-- 3. every script: reads the source (security, quality, code statistics)
	local scripts = S.scripts
	for i, s in scripts do
		if not pcall(readScript, S, s) then
			S.errors += 1
		end
		breathe()
		progress(0.55 + 0.37 * i / math.max(1, #scripts), string.format("Citesc scripturile: %d / %d", i, #scripts))
	end

	-- 4. the report
	progress(0.92, "Stil vizual, avatar, gen…", true)
	local code = codeInfo(S)
	local animations = animationInfo(S)
	local report = {
		version = Analyzer.VERSION,
		at = os.time(),
		place = placeInfo(),
		totals = { instances = S.total, scripts = #scripts, parts = S.part.count, lines = S.code.lines,
			remotes = (S.remotes.counts.RemoteEvent or 0) + (S.remotes.counts.RemoteFunction or 0)
				+ (S.remotes.counts.UnreliableRemoteEvent or 0), errors = S.errors },
		services = top(S.services, 20, "name", "count"),
		classes = top(S.classes, 30, "name", "count"),
		structure = S.structure,
		code = code,
		performance = performanceInfo(S, code),
		vfx = vfxInfo(S),
		animations = animations,
		avatar = avatarInfo(S, animations),
		style = styleInfo(S),
		ui = uiInfo(S),
		audio = audioInfo(S),
		misc = { tools = S.misc.tools, toolNames = S.misc.toolNames, seats = S.misc.seats, vehicleSeats = S.misc.vehicleSeats,
			spawns = S.misc.spawns, prompts = S.misc.prompts, clickDetectors = S.misc.clickDetectors, teams = S.misc.teams,
			packages = S.misc.packages },
	}
	report.genre = guessGenre(S, report)
	report.issues = buildIssues(S, report)
	local security = { high = 0, medium = 0, low = 0 }
	for _, issue in report.issues do
		if string.sub(issue.kind or "", 1, 9) == "security." or string.sub(issue.kind or "", 1, 7) == "remote." then
			bump(security, issue.severity)
		end
	end
	report.security = { counts = security, loadStringEnabled = prop(findService("ServerScriptService") or game, "LoadStringEnabled"),
		httpEnabled = prop(HttpService, "HttpEnabled"), hosts = code.hosts }
	report.suggestions = buildSuggestions(S, report)
	report.duration = round(os.clock() - started, 1)

	-- 5. remembered in the place
	progress(0.97, "Salvez analiza în joc…", true)
	local ok, err = pcall(Analyzer.save, report)
	if not ok then
		report.saveError = tostring(err)
		warn("LostCube: analiza nu s-a putut salva:", err)
	end
	report.ai = readAI(folder(false))
	countCache = { t = os.time(), instances = report.totals.instances, scripts = report.totals.scripts }
	progress(1, "Gata", true)
	return report
end

-- full scan of the game; yields (call it from task.spawn). Saves the report in the place and returns it.
function Analyzer.run(onProgress)
	Analyzer.running = true
	local ok, result = pcall(scan, onProgress)
	Analyzer.running = false
	if not ok then
		error(result, 0)
	end
	return result
end

-- ---------------------------------------------------------------------------------------------
-- Markdown for an LLM: the most important first, cut at a line when it gets too long
-- ---------------------------------------------------------------------------------------------
local SEVERITY_TAG = { high = "MARE", medium = "MEDIE", low = "MICĂ" }

local function yesNo(v)
	return v and "da" or "nu"
end

local function join(list, n, fn)
	local out = {}
	list = list or {}
	for i, v in list do
		if n and i > n then
			table.insert(out, "…+" .. (#list - n))
			break
		end
		table.insert(out, fn and fn(v) or tostring(v))
	end
	return table.concat(out, ", ")
end

local function where(path, line)
	if not path then
		return ""
	end
	return " — `" .. path .. (line and (":" .. int(line)) or "") .. "`"
end

local function buildContext(report, maxChars)
	local r = report
	local place, totals, genre, avatar = r.place or {}, r.totals or {}, r.genre or {}, r.avatar or {}
	local code, perf, vfx, anim = r.code or {}, r.performance or {}, r.vfx or {}, r.animations or {}
	local style, ui, audio, security = r.style or {}, r.ui or {}, r.audio or {}, r.security or {}
	local sections, lines = {}, nil
	local function begin(title)
		lines = { title }
		table.insert(sections, lines)
	end
	local function line(text)
		table.insert(lines, text)
	end

	-- overview
	begin("# Joc Roblox: " .. tostring(place.title or place.name or "?"))
	line(string.format("- PlaceId %s · GameId %s%s · analizat %s de LostCube (raport v%s, %s s)", tostring(place.placeId or 0),
		tostring(place.gameId or 0), place.creatorType and (" · creator " .. place.creatorType .. " "
			.. tostring(place.creator or place.creatorId or "")) or "", os.date("%d.%m.%Y %H:%M", tonumber(r.at) or 0),
		tostring(r.version), tostring(r.duration or "?")))
	if type(place.description) == "string" and place.description ~= "" then
		line("- Descriere: " .. string.gsub(place.description, "%s+", " "))
	end
	if genre.label then
		line(string.format("- Gen probabil: **%s** (încredere %s%%)%s%s", genre.label, int((genre.confidence or 0) * 100),
			genre.secondary and ("; secundar: " .. tostring(genre.secondary.label)) or "",
			#(genre.evidence or {}) > 0 and (". Indicii: " .. join(genre.evidence, 10)) or ""))
	end
	line(string.format("- Mărime: %s instanțe · %s scripturi (%s linii) · %s piese · %s remote-uri", int(totals.instances),
		int(totals.scripts), int(totals.lines), int(totals.parts), int(totals.remotes)))
	line(string.format("- Avatar: %s%s · WalkSpeed %s · %s · StarterCharacter: %s · Animate propriu: %s · rig-uri în Workspace: "
		.. "%s R15 / %s R6", tostring(avatar.rigType or "necunoscut"), avatar.rigSource and (" (" .. avatar.rigSource .. ")") or "",
		tostring(avatar.walkSpeed or "?"), avatar.useJumpPower == false and ("JumpHeight " .. tostring(avatar.jumpHeight))
			or ("JumpPower " .. tostring(avatar.jumpPower or "?")), yesNo(avatar.starterCharacter), yesNo(avatar.customAnimate),
		int(avatar.rigs and avatar.rigs.r15), int(avatar.rigs and avatar.rigs.r6)))
	local frameworkNames = join(code.frameworks, 12, function(fw)
		return fw.name
	end)
	line("- Framework-uri / biblioteci: " .. (frameworkNames ~= "" and frameworkNames or "niciunul detectat"))

	-- issues
	local issues = r.issues or {}
	if #issues > 0 then
		begin("## Probleme (cele mai importante primele)")
		for i, issue in issues do
			if i > 25 then
				line("- …și încă " .. (#issues - 25) .. " (lista completă: ServerStorage.LostCubeAnalysis.Report, câmpul issues)")
				break
			end
			line(string.format("- **%s** %s%s", SEVERITY_TAG[issue.severity] or tostring(issue.severity), tostring(issue.message),
				where(issue.path, issue.line)))
		end
	end

	-- structure: where things are, so tools can go straight to them
	begin("## Structura jocului (nume [clasă, instanțe])")
	for _, s in r.structure or {} do
		line(string.format("- **%s** (%s): %s%s", tostring(s.service), int(s.count), join(s.children, 12, function(c)
			return string.format("%s [%s, %s]", tostring(c.name), tostring(c.class), int(c.count))
		end), (s.more or 0) > 0 and (", …+" .. int(s.more)) or ""))
	end

	-- code
	begin("## Cod")
	line(string.format("- %s Script · %s LocalScript · %s ModuleScript · %s linii%s", int(code.scripts), int(code.localScripts),
		int(code.modules), int(code.lines), (code.disabled or 0) > 0 and (" · " .. int(code.disabled) .. " dezactivate") or ""))
	if #(code.services or {}) > 0 then
		line("- Servicii folosite: " .. join(code.services, 18, function(s)
			return s.name .. " ×" .. int(s.count)
		end))
	end
	local ds = code.datastore or {}
	line(string.format("- Date: DataStore %s%s · BindToClose %s · PlayerRemoving %s", yesNo(ds.used),
		ds.used and string.format(" (%s scripturi, SetAsync ×%s, UpdateAsync ×%s%s)", int(ds.scripts), int(ds.set),
			int(ds.update), ds.ordered and ", OrderedDataStore" or "") or "", yesNo(ds.bindToClose), yesNo(ds.playerRemoving)))
	local market = code.marketplace or {}
	line(string.format("- Monetizare: %s gamepass-uri%s · %s developer products · %s prompt-uri de cumpărare · ProcessReceipt ×%s",
		int(#(market.gamepasses or {})), #(market.gamepasses or {}) > 0 and (" (" .. join(market.gamepasses, 6) .. ")") or "",
		int(#(market.products or {})), int(market.prompts), int(market.processReceipt)))
	line(string.format("- Bucle: %s conexiuni Heartbeat/Stepped (%s RenderStepped) · %s Touched · %s handler-e de remote "
		.. "(%s fără validare) · %s while-true fără wait", int(code.runService), int(code.renderStepped), int(code.touched),
		int(code.remoteHandlers), int(code.unvalidated), int(code.busyLoops)))
	local flagList = {}
	for flag, n in code.flags or {} do
		table.insert(flagList, flag .. " " .. int(n))
	end
	table.sort(flagList)
	if #flagList > 0 then
		line("- Semnale (scripturi care folosesc): " .. table.concat(flagList, ", "))
	end
	if #(code.largest or {}) > 0 then
		line("- Cele mai mari scripturi: " .. join(code.largest, 8, function(s)
			return string.format("`%s` (%s linii)", tostring(s.path), int(s.lines))
		end))
	end
	local remotes = {}
	for _, rem in code.remotes or {} do
		if rem.class ~= "BindableEvent" and rem.class ~= "BindableFunction" then
			table.insert(remotes, rem)
		end
	end
	if #remotes > 0 then
		line("- Remote-uri: " .. join(remotes, 40, function(rem)
			return string.format("`%s` (%s)", tostring(rem.path), tostring(rem.class))
		end))
	end
	if #(code.deprecated or {}) > 0 then
		line("- API-uri învechite: " .. join(code.deprecated, 10, function(d)
			return string.format("%s ×%s → %s", tostring(d.label), int(d.count), tostring(d.fix))
		end))
	end

	-- security
	begin("## Securitate")
	local counts = security.counts or {}
	line(string.format("- Probleme de securitate: %s mari, %s medii, %s mici · LoadStringEnabled %s · HttpEnabled %s",
		int(counts.high), int(counts.medium), int(counts.low), yesNo(security.loadStringEnabled), yesNo(security.httpEnabled)))
	if #(security.hosts or {}) > 0 then
		line("- Adrese web din cod: " .. join(security.hosts, 15))
	end

	-- performance
	begin("## Performanță")
	line(string.format("- %s piese (%s în Workspace, %s neancorate libere) · %s MeshPart (%s unice, %s coliziune precisă) · "
		.. "%s Union", int(perf.parts), int(perf.workspaceParts), int(perf.loose), int(perf.meshParts), int(perf.uniqueMeshes),
		int(perf.preciseCollision), int(perf.unions)))
	line(string.format("- %s ParticleEmitter (%s particule/s, %s foarte dense) · %s lumini (%s cu umbre) · %s sunete · "
		.. "%s Decal/Texture (%s unice)", int(perf.emitters), int(perf.particleRate), int(perf.heavyEmitters), int(perf.lights),
		int(perf.shadowLights), int(perf.sounds), int(perf.decals), int(perf.uniqueTextures)))
	line(string.format("- %s Humanoid în Workspace · %s constraints · StreamingEnabled %s · teren: %s celule", int(perf.humanoids),
		int(perf.constraints), yesNo(perf.streamingEnabled), int(perf.terrainCells)))

	-- existing VFX and animations
	begin("## VFX și animații existente")
	local vfxCounts = {}
	for class, n in vfx.counts or {} do
		table.insert(vfxCounts, class .. " " .. int(n))
	end
	table.sort(vfxCounts)
	line("- Efecte: " .. (#vfxCounts > 0 and table.concat(vfxCounts, ", ") or "niciunul") .. " · efecte LostCube: "
		.. int(vfx.lostCubeEffects))
	if #(vfx.textures or {}) > 0 then
		line("- Texturi folosite: " .. join(vfx.textures, 8, function(t)
			return tostring(t.id) .. " ×" .. int(t.count)
		end))
	end
	if #(vfx.colors or {}) > 0 then
		line("- Culori VFX: " .. join(vfx.colors, 10, function(c)
			return "#" .. tostring(c)
		end))
	end
	if #(vfx.examples or {}) > 0 then
		line("- Exemple: " .. join(vfx.examples, 8, function(e)
			return string.format("`%s` (%s)", tostring(e.path), tostring(e.class))
		end))
	end
	local rigCounts = {}
	for rig, n in anim.rigs or {} do
		table.insert(rigCounts, rig .. " " .. int(n))
	end
	table.sort(rigCounts)
	line(string.format("- Animații: %s Animation (%s ID-uri unice, %s ID-uri setate în cod) · %s KeyframeSequence (%s în "
		.. "RBX_ANIMSAVES; %s) · %s AnimationController · %s Animator", int(anim.count), int(anim.uniqueIds), int(anim.codeIds),
		int(anim.kfsCount), int(anim.saves), #rigCounts > 0 and table.concat(rigCounts, ", ") or "-", int(anim.controllers),
		int(anim.animators)))
	if #(anim.list or {}) > 0 then
		line("- Animation: " .. join(anim.list, 25, function(a)
			return string.format("%s (%s)", tostring(a.name), a.id ~= "" and tostring(a.id) or "fără ID")
		end))
	end
	if #(anim.kfs or {}) > 0 then
		line("- KeyframeSequence: " .. join(anim.kfs, 15, function(k)
			return string.format("`%s` (%s s, %s, %s chei%s)", tostring(k.path), tostring(k.length), tostring(k.rig),
				int(k.keyframes), #(k.markers or {}) > 0 and (", markeri: " .. table.concat(k.markers, "/")) or "")
		end))
	end

	-- visual style
	begin("## Stil vizual")
	local l = style.lighting or {}
	line(string.format("- Lighting: %s · ClockTime %s · Brightness %s · Ambient #%s · OutdoorAmbient #%s · umbre %s · FogEnd %s · "
		.. "Exposure %s", tostring(l.technology or "?"), tostring(l.clockTime), tostring(l.brightness), tostring(l.ambient),
		tostring(l.outdoorAmbient), yesNo(l.globalShadows), tostring(l.fogEnd), tostring(l.exposure)))
	local atmosphere = style.atmosphere
	line("- Atmosphere: " .. (atmosphere and string.format("Density %s, Haze %s, culoare #%s", tostring(atmosphere.density),
		tostring(atmosphere.haze), tostring(atmosphere.color)) or "nu") .. " · Sky: " .. (style.sky and (style.sky.custom
		and "personalizat" or "implicit") or "nu") .. " · post-efecte: " .. (#(style.effects or {}) > 0
		and table.concat(style.effects, "; ") or "niciunul"))
	if #(style.colors or {}) > 0 then
		line("- Culori dominante (după suprafață): " .. join(style.colors, 8, function(c)
			return "#" .. tostring(c.hex) .. " " .. tostring(c.share) .. "%"
		end))
	end
	if #(style.materials or {}) > 0 then
		line("- Materiale: " .. join(style.materials, 8, function(m)
			return tostring(m.name) .. " " .. tostring(m.share) .. "%"
		end))
	end
	local b = style.bounds
	local terrain = style.terrain or {}
	line(string.format("- Harta: %s · teren %s%s · %s SpawnLocation", b and string.format("%s × %s × %s studs", int(b.x), int(b.y),
		int(b.z)) or "?", (terrain.cells or 0) > 0 and "da" or "nu", terrain.clouds and " (cu nori)" or "", int(style.spawns)))

	-- UI and audio
	begin("## UI și audio")
	line(string.format("- %s ScreenGui (%s) · %s elemente GUI · %s BillboardGui · %s SurfaceGui · %s TextBox · "
		.. "%s meniuri cu mărime fixă", int(ui.screenGuis), join(ui.names, 15), int(ui.guiObjects), int(ui.billboards),
		int(ui.surfaceGuis), int(ui.textBoxes), int(ui.fixedSize)))
	if #(ui.categories or {}) > 0 then
		line("- Ce are UI-ul: " .. join(ui.categories, nil, function(c)
			return c.label .. " (" .. table.concat(c.names or {}, ", ") .. ")"
		end))
	end
	line(string.format("- Audio: %s sunete (%s unice, %s în buclă) · muzică: %s%s · %s SoundGroup", int(audio.sounds),
		int(audio.uniqueIds), int(audio.looped), yesNo(audio.music), #(audio.musicNames or {}) > 0
			and (" (" .. table.concat(audio.musicNames, ", ") .. ")") or "", int(audio.groups)))

	-- suggestions
	if #(r.suggestions or {}) > 0 then
		begin("## Sugestii")
		for _, s in r.suggestions do
			line("- " .. tostring(s))
		end
	end
	begin("---")
	line("Raport complet (JSON): `ServerStorage.LostCubeAnalysis.Report` · efecte LostCube: `ReplicatedStorage.LostCube.Editor`")

	-- assemble within the limit
	local out, used = {}, 0
	for _, section in sections do
		local text = table.concat(section, "\n")
		if used + #text + 2 <= maxChars then
			table.insert(out, text)
			used += #text + 2
		else
			local room = maxChars - used - 80
			if room > 200 then
				local cut = string.sub(text, 1, room)
				cut = string.match(cut, "^(.*)\n") or string.gsub(cut, "[\192-\255][\128-\191]*$", "")
				table.insert(out, cut)
			end
			table.insert(out, "_(context trunchiat la " .. maxChars .. " caractere — restul e în raportul JSON)_")
			break
		end
	end
	return table.concat(out, "\n\n")
end

-- The Markdown of a report. The text of a report that load() handed out is kept (the Claude tab asks on every redraw);
-- any other table is converted every time, because its owner may have changed it since.
function Analyzer.context(report, maxChars)
	if report == nil then
		report = Analyzer.load()
	end
	maxChars = maxChars or 15000
	if type(report) ~= "table" then
		return "# Joc Roblox\n\n_LostCube nu a analizat încă jocul (Analyzer.run())._"
	end
	if not published[report] then
		return buildContext(report, maxChars)
	end
	local texts = contexts[report]
	if not texts then
		texts = {}
		contexts[report] = texts
	end
	local text = texts[maxChars]
	if not text then
		text = buildContext(report, maxChars)
		texts[maxChars] = text
	end
	return text
end

-- the internals, for tests
Analyzer._internal = { tokens = tokens, stripComments = stripComments, lineIndex = lineIndex, lineOf = lineOf,
	blockText = blockText, scanSource = scanSource, plain = plain, chunks = chunks, sortFindings = sortFindings,
	GENRES = GENRES, matchWord = matchWord }

return Analyzer
