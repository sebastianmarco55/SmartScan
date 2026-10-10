--[[ LostCube Editor - creates and edits Roblox effects (LostCube VFX format) in Studio.
Used by the LostCube plugin's panels and by Claude (through Studio):

	local Editor = require(game.ReplicatedStorage.LostCube.Editor)
	local fx = Editor.newEffect("Boom", { duration = 0.6, attach = "GROUND" })
	local s = Editor.addElement(fx, "SPARKLES", { position = Vector3.new(0, 3, 0), bursts = { { 0.1, 40 } } })
	Editor.setProps(s, { color = { Color3.new(1, 1, 1), Color3.fromRGB(158, 92, 255) }, speed = { 18, 30 } })
	Editor.preview(fx)  -- plays it in Studio, in front of the camera (or on the selection)

Format (the same the Blender exporter writes; LostCube.VFX plays it in the game):
	Model <effect>  attributes LC_Duration (s), LC_Attach
	  Part Root
	    Attachment <element> > ParticleEmitter / PointLight      (point emitters, lights)
	    Attachment <element>_Top / _Bottom + Trail <element>      (trails)
	  Part <element> > ParticleEmitter                            (shape emitters: the Part is the shape)
Timeline attributes (seconds) on elements: LC_On "t0,t1", LC_Bursts "t:n;t:n", LC_Keys "t,b,r;..." (lights),
LC_Muted (skipped by the player).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")

local VFX = require(script:FindFirstChild("VFX") or script.Parent:WaitForChild("VFX"))

local Editor = {}
Editor.VERSION = "1.6.0"

local P = "rbxasset://textures/particles/"
-- the ground crack streak (Textures/ground_crack_trail.png), uploaded as one asset
Editor.GROUND_CRACK_URL = "rbxassetid://105887359860913" -- rotated 90 degrees: Trail maps image height along the length
Editor.TEXTURES = {
	{ key = "SPARKLES", label = "Scântei (stea)", url = P .. "sparkles_main.dds" },
	{ key = "GLOW", label = "Glow (bilă moale)", url = P .. "explosion01_implosion_main.dds" },
	{ key = "RING", label = "Inel (undă)", url = P .. "explosion01_shockwave_main.dds" },
	{ key = "CIRCLE", label = "Cerc magic", url = P .. "forcefield_vortex_main.dds" },
	{ key = "SMOKE", label = "Fum", url = P .. "smoke_main.dds" },
	{ key = "SMOKE_SOFT", label = "Fum moale", url = P .. "explosion01_smoke_main.dds" },
	{ key = "FIRE", label = "Foc", url = P .. "fire_main.dds" },
	{ key = "EXPLOSION", label = "Explozie", url = P .. "explosion01_core_main.dds" },
	{ key = "SQUARE", label = "Pătrat", url = P .. "SquareParticle.png" },
	{ key = "GROUND_CRACK", label = "Urmă crăpată (pe sol)", url = Editor.GROUND_CRACK_URL },
	{ key = "NONE", label = "Fără (alb)", url = "" },
}
local TEXTURE_URL, TEXTURE_KEY = {}, {}
for _, t in Editor.TEXTURES do
	TEXTURE_URL[t.key] = t.url
	if t.url ~= "" then
		TEXTURE_KEY[t.url] = t.key
	end
end

Editor.ATTACH = {
	{ key = "GROUND", label = "Pe sol (rămâne pe loc)" },
	{ key = "GROUND_FOLLOW", label = "Pe sol (urmărește)" },
	{ key = "ROOT", label = "HumanoidRootPart" },
	{ key = "TORSO", label = "Trunchi" },
	{ key = "HEAD", label = "Cap" },
	{ key = "RIGHT_HAND", label = "Mâna dreaptă" },
	{ key = "LEFT_HAND", label = "Mâna stângă" },
	{ key = "RIGHT_FOOT", label = "Talpa dreaptă" },
	{ key = "LEFT_FOOT", label = "Talpa stângă" },
	{ key = "WORLD", label = "Lume (CFrame dat)" },
}

-- ---------------------------------------------------------------------------------------------
-- presets (times in seconds)
-- ---------------------------------------------------------------------------------------------
local WHITE = Color3.new(1, 1, 1)
local VIOLET = Color3.fromRGB(158, 92, 255)
local CYAN = Color3.fromRGB(102, 217, 255)

Editor.PRESETS = {
	{ key = "SPARKLES", label = "Scântei (explozie)", kind = "PARTICLES", props = {
		texture = "SPARKLES", color = { WHITE, VIOLET, CYAN }, size = { 0.5, 0.35, 0 }, transparency = { 0, 0.1, 1 },
		LightEmission = 1, lifetime = { 0.35, 0.7 }, speed = { 14, 26 }, spread = { 180, 180 }, Drag = 4,
		rotation = { 0, 360 }, rotSpeed = { -200, 200 }, bursts = { { 0, 30 } } } },
	{ key = "RISING", label = "Scântei care urcă", kind = "PARTICLES", props = {
		texture = "SPARKLES", color = { CYAN, VIOLET }, size = { 0.35, 0.3, 0 }, transparency = { 0.2, 0, 1 },
		LightEmission = 1, lifetime = { 0.45, 0.9 }, Rate = 60, speed = { 4, 9 }, shape = "Cylinder",
		partSize = Vector3.new(3.2, 0.3, 3.2), ShapeStyle = "Surface", acceleration = Vector3.new(0, 6, 0),
		rotation = { 0, 360 }, window = { 0, 0.33 } } },
	{ key = "MAGIC_CIRCLE", label = "Cerc magic (pe sol)", kind = "PARTICLES", props = {
		texture = "CIRCLE", Orientation = "VelocityPerpendicular", color = VIOLET, size = { 3, 6.5, 6.8, mid = 0.25 },
		transparency = { 1, 0.05, 1, mid = 0.25 }, LightEmission = 1, Brightness = 2, lifetime = 0.8, speed = 0.01,
		rotSpeed = 140, LockedToPart = true, position = Vector3.new(0, 0.08, 0), bursts = { { 0, 1 } } } },
	{ key = "SHOCKWAVE", label = "Undă pe sol", kind = "PARTICLES", props = {
		texture = "RING", Orientation = "VelocityPerpendicular", color = { WHITE, VIOLET }, size = { 1, 9, 13, mid = 0.45 },
		transparency = { 0, 0.35, 1, mid = 0.45 }, LightEmission = 1, lifetime = 0.4, speed = 0.01,
		position = Vector3.new(0, 0.12, 0), bursts = { { 0, 1 } } } },
	{ key = "FLASH", label = "Flash", kind = "PARTICLES", props = {
		texture = "GLOW", color = { Color3.fromRGB(235, 217, 255), VIOLET }, size = { 2, 7, 8, mid = 0.3 },
		transparency = { 0.2, 0.45, 1, mid = 0.3 }, LightEmission = 1, Brightness = 1.2, lifetime = 0.22, speed = 0,
		ZOffset = 2, bursts = { { 0, 1 } } } },
	{ key = "STAR_FLASH", label = "Stea (sclipire)", kind = "PARTICLES", props = {
		texture = "SPARKLES", color = { WHITE, CYAN }, size = { 1, 12, 3, mid = 0.35 }, transparency = { 0.1, 0.2, 1, mid = 0.35 },
		LightEmission = 1, Brightness = 1.6, lifetime = 0.25, speed = 0, rotation = { 0, 45 }, rotSpeed = 90,
		ZOffset = 2.5, bursts = { { 0, 1 } } } },
	{ key = "IMPLOSION", label = "Implozie (energie strânsă)", kind = "PARTICLES", props = {
		texture = "GLOW", color = { CYAN, WHITE }, size = { 10, 4, 0, mid = 0.6 }, transparency = { 1, 0.2, 0, mid = 0.6 },
		LightEmission = 1, lifetime = 0.25, speed = 0, bursts = { { 0, 1 } } } },
	{ key = "STREAKS", label = "Raze în sus", kind = "PARTICLES", props = {
		texture = "GLOW", Orientation = "VelocityParallel", squash = -2.6, color = { WHITE, VIOLET },
		size = { 0.9, 0.7, 0 }, transparency = { 0, 0.1, 1 }, LightEmission = 1, lifetime = { 0.2, 0.4 },
		speed = { 45, 80 }, spread = { 14, 14 }, Drag = 2, bursts = { { 0, 16 } } } },
	{ key = "SMOKE", label = "Fum", kind = "PARTICLES", props = {
		texture = "SMOKE", color = { Color3.fromRGB(64, 31, 102), Color3.fromRGB(20, 13, 31) }, size = { 1.5, 3.5, 5 },
		transparency = { 0.45, 0.6, 1 }, LightEmission = 0.15, LightInfluence = 0.3, lifetime = { 0.6, 1 },
		speed = { 2, 6 }, spread = { 180, 180 }, Drag = 3, rotation = { 0, 360 }, rotSpeed = { -40, 40 },
		bursts = { { 0, 12 } } } },
	{ key = "DUST", label = "Praf pe sol", kind = "PARTICLES", props = {
		texture = "SMOKE", color = Color3.fromRGB(173, 173, 184), size = { 1, 2.6, 3.4 }, transparency = { 0.5, 0.7, 1 },
		LightEmission = 0, LightInfluence = 1, lifetime = { 0.5, 0.9 }, speed = { 6, 12 }, spread = { 180, 0 },
		Drag = 4, rotation = { 0, 360 }, shape = "Disc", partSize = Vector3.new(2, 0.1, 2),
		acceleration = Vector3.new(0, 1, 0), position = Vector3.new(0, 0.2, 0), bursts = { { 0, 16 } } } },
	{ key = "FIRE", label = "Foc", kind = "PARTICLES", props = {
		texture = "FIRE", color = { Color3.fromRGB(255, 179, 77), Color3.fromRGB(255, 64, 13) }, size = { 2, 1.6, 0.6 },
		transparency = { 0.2, 0.3, 1 }, LightEmission = 0.8, lifetime = { 0.4, 0.7 }, Rate = 40, speed = { 3, 6 },
		spread = { 15, 15 }, acceleration = Vector3.new(0, 6, 0), rotation = { 0, 360 }, rotSpeed = { -60, 60 },
		window = { 0, 1 } } },
	{ key = "MOTES", label = "Praf magic (plutește)", kind = "PARTICLES", props = {
		texture = "SPARKLES", color = { VIOLET, CYAN }, size = { 0, 0.3, 0 }, transparency = { 0, 0, 1 },
		LightEmission = 1, lifetime = { 0.8, 1.4 }, Rate = 25, speed = { 0.5, 1.5 }, spread = { 180, 180 },
		shape = "Sphere", partSize = Vector3.new(4, 4, 4), acceleration = Vector3.new(0, 1.5, 0),
		rotSpeed = { -90, 90 }, window = { 0, 1 } } },
	{ key = "FLASH_LIGHT", label = "Lumină flash", kind = "LIGHT", props = {
		Color = VIOLET, keys = { { 0, 0, 16 }, { 0.033, 6, 18 }, { 0.27, 0, 12 } }, position = Vector3.new(0, 2, 0) } },
	{ key = "GLOW_LIGHT", label = "Lumină constantă", kind = "LIGHT", props = {
		Color = VIOLET, Brightness = 2, Range = 12, position = Vector3.new(0, 2, 0) } },
	{ key = "RING3D", label = "Inel 3D (undă pe sol)", kind = "MESH", props = {
		ground = true, mode = "Ring", shape = "Block", material = "Neon", color = VIOLET, colorEnd = Color3.fromRGB(90, 40, 200),
		size = Vector3.new(1, 0.12, 0.35), grow = { 1, 0.3 }, transparency = { 0.05, 1 }, lifetime = 0.45, count = 22,
		radius = { 0.8, 9 }, position = Vector3.new(0, 0.08, 0), bursts = { { 0, 1 } } } },
	{ key = "CRACK3D", label = "Crăpături în sol", kind = "MESH", props = {
		ground = true, mode = "Crack", shape = "Block", material = "Slate", color = Color3.fromRGB(28, 26, 34), size = Vector3.new(0.16, 0.06, 1),
		transparency = { 0, 1 }, lifetime = { 0.9, 1.2 }, count = 7, radius = { 1.6, 3.2 }, position = Vector3.new(0, 0.03, 0),
		bursts = { { 0, 1 } } } },
	{ key = "DOME3D", label = "Dom de energie", kind = "MESH", props = {
		mode = "Pulse", shape = "Ball", material = "ForceField", color = VIOLET, size = Vector3.new(1, 1, 1), grow = { 1.5, 8 },
		transparency = { 0, 1 }, lifetime = 0.4, position = Vector3.new(0, 1, 0), bursts = { { 0, 1 } } } },
	{ key = "PUFF3D", label = "Bile de fum 3D", kind = "MESH", props = {
		mode = "Puff", shape = "Ball", material = "SmoothPlastic", color = Color3.fromRGB(226, 226, 234),
		colorEnd = Color3.fromRGB(180, 178, 192), size = Vector3.new(1, 1, 1), grow = { 0.5, 2.2 }, transparency = { 0.15, 1 },
		lifetime = { 0.45, 0.8 }, speed = { 3, 7 }, spread = { 50, 40 }, direction = "Back", rise = 1.2, jitter = 0.3,
		position = Vector3.new(0, 0.3, 0), bursts = { { 0, 6 } } } },
	{ key = "GROOVE3D", label = "Șanț luminos (urmă)", kind = "MESH", props = {
		ground = true, mode = "Trail", shape = "Block", material = "Neon", color = VIOLET, colorEnd = Color3.fromRGB(60, 20, 140),
		size = Vector3.new(0.32, 0.06, 0.9), grow = { 1, 0.55 }, transparency = { 0.1, 1 }, lifetime = 1.3, Rate = 45,
		position = Vector3.new(0, 0.02, 0), window = { 0, 0.4 } } },
	{ key = "SCAR3D", label = "Zgârietură în sol", kind = "MESH", props = {
		ground = true, mode = "Trail", shape = "Block", material = "Slate", color = Color3.fromRGB(34, 32, 42), size = Vector3.new(0.6, 0.04, 1),
		grow = { 1, 1 }, transparency = { 0.15, 1 }, lifetime = 2, Rate = 45, position = Vector3.new(0, 0.015, 0),
		window = { 0, 0.4 } } },
	{ key = "DEBRIS3D", label = "Pietre (debris)", kind = "MESH", props = {
		mode = "Debris", shape = "Block", material = "Slate", color = Color3.fromRGB(92, 88, 104), size = Vector3.new(0.3, 0.26, 0.3),
		grow = { 1, 0.5 }, transparency = { 0, 1 }, lifetime = { 0.9, 1.4 }, speed = { 9, 17 }, spread = { 35, 40 },
		direction = "Back", spin = 18, jitter = 0.45, Rate = 22, position = Vector3.new(0, 0.2, 0), bursts = { { 0, 6 } },
		window = { 0, 0.35 } } },
	{ key = "MAGIC_TRAIL", label = "Dâră magică", kind = "TRAIL", props = {
		texture = "GLOW", color = { WHITE, VIOLET }, transparency = { 0, 1 }, LightEmission = 1, lifetime = 0.25,
		widthEnd = 0.15, height = 3, window = { 0, 1 } } },
	-- ground ribbons: the crack streak, one piece, lying on the floor, stretched over the path (layer several)
	{ key = "GROUND_RIBBON", label = "Urmă pe sol: fisură luminoasă", kind = "TRAIL", props = {
		texture = "GROUND_CRACK", TextureMode = "Stretch", ground = true, height = 1.9, widthHead = 1, widthEnd = 1, MinLength = 0.03,
		color = { { 0, Color3.new(1, 1, 1) }, { 0.02, Color3.fromRGB(225, 185, 255) }, { 0.08, Color3.fromRGB(160, 100, 250) },
			{ 0.5, Color3.fromRGB(112, 62, 212) }, { 0.8, Color3.fromRGB(78, 44, 160) } },
		transparency = { { 0, 0.05 }, { 0.08, 0.12 }, { 0.5, 0.3 }, { 0.56, 0.36 }, { 0.8, 1 }, { 1, 1 } },
		LightEmission = 1, Brightness = 2, lifetime = 6, window = { 0, 0.45 } } },
	{ key = "GROUND_SCORCH", label = "Urmă pe sol: arsură întunecată", kind = "TRAIL", props = {
		texture = "GROUND_CRACK", TextureMode = "Stretch", ground = true, height = 2.4, widthHead = 1, widthEnd = 1, MinLength = 0.03,
		color = Color3.fromRGB(14, 8, 24), transparency = { { 0, 0.5 }, { 0.08, 0.5 }, { 0.5, 0.6 }, { 0.84, 1 }, { 1, 1 } },
		LightEmission = 0, LightInfluence = 0.2, lifetime = 6.5, window = { 0, 0.45 } } },
	{ key = "GROUND_CORE", label = "Urmă pe sol: miez alb-fierbinte", kind = "TRAIL", props = {
		texture = "GROUND_CRACK", TextureMode = "Stretch", ground = true, height = 0.7, widthHead = 1, widthEnd = 1, MinLength = 0.03,
		color = { { 0, Color3.new(1, 1, 1) }, { 0.1, Color3.fromRGB(240, 226, 255) }, { 0.5, Color3.fromRGB(205, 168, 255) }, { 1, Color3.fromRGB(170, 130, 250) } },
		transparency = { { 0, 0 }, { 0.1, 0.1 }, { 0.5, 0.4 }, { 0.88, 1 }, { 1, 1 } }, LightEmission = 1,
		Brightness = 2.5, lifetime = 3.2, window = { 0, 0.45 } } },
}
local PRESET_BY_KEY = {}
for _, p in Editor.PRESETS do
	PRESET_BY_KEY[p.key] = p
end

-- ---------------------------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------------------------
local function round(x, d)
	local m = 10 ^ (d or 4)
	return math.floor(x * m + 0.5) / m
end

local function vec3(v)
	if typeof(v) == "Vector3" then
		return v
	end
	return Vector3.new(v[1] or v.X or 0, v[2] or v.Y or 0, v[3] or v.Z or 0)
end

local function numberSequence(v)
	if typeof(v) == "NumberSequence" then
		return v
	elseif type(v) == "number" then
		return NumberSequence.new(v)
	elseif type(v[1]) == "table" then -- keypoints: { { time, value }, ... } (the ends are filled in if missing)
		local points = {}
		if v[1][1] > 0 then
			table.insert(points, NumberSequenceKeypoint.new(0, v[1][2]))
		end
		for _, kp in v do
			table.insert(points, NumberSequenceKeypoint.new(kp[1], kp[2]))
		end
		if v[#v][1] < 1 then
			table.insert(points, NumberSequenceKeypoint.new(1, v[#v][2]))
		end
		return NumberSequence.new(points)
	elseif #v == 2 then
		return NumberSequence.new({ NumberSequenceKeypoint.new(0, v[1]), NumberSequenceKeypoint.new(1, v[2]) })
	end
	local mid = math.clamp(v.mid or 0.5, 0.01, 0.99)
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, v[1]), NumberSequenceKeypoint.new(mid, v[2]), NumberSequenceKeypoint.new(1, v[3]),
	})
end

local function toColor(c)
	if typeof(c) == "Color3" then
		return c
	elseif type(c) == "string" then
		return Color3.fromHex(c)
	end
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function colorSequence(v)
	if typeof(v) == "ColorSequence" then
		return v
	elseif type(v) == "table" and type(v[1]) == "table" then -- keypoints: { { time, Color3 }, ... } (ends filled in)
		local points = {}
		if v[1][1] > 0 then
			table.insert(points, ColorSequenceKeypoint.new(0, toColor(v[1][2])))
		end
		for _, kp in v do
			table.insert(points, ColorSequenceKeypoint.new(kp[1], toColor(kp[2])))
		end
		if v[#v][1] < 1 then
			table.insert(points, ColorSequenceKeypoint.new(1, toColor(v[#v][2])))
		end
		return ColorSequence.new(points)
	elseif typeof(v) == "Color3" or type(v) == "string" or (type(v) == "table" and type(v[1]) == "number") then
		return ColorSequence.new(toColor(v))
	elseif #v == 1 then
		return ColorSequence.new(toColor(v[1]))
	elseif #v == 2 then
		return ColorSequence.new(toColor(v[1]), toColor(v[2]))
	end
	local mid = math.clamp(v.mid or 0.5, 0.01, 0.99)
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, toColor(v[1])), ColorSequenceKeypoint.new(mid, toColor(v[2])),
		ColorSequenceKeypoint.new(1, toColor(v[3])),
	})
end

local function numberRange(v)
	if typeof(v) == "NumberRange" then
		return v
	elseif type(v) == "number" then
		return NumberRange.new(v)
	end
	return NumberRange.new(math.min(v[1], v[2]), math.max(v[1], v[2]))
end

local function enumItem(enumType, v)
	if typeof(v) == "EnumItem" then
		return v
	end
	return enumType[v]
end

local function parseList(s)
	local out = {}
	if type(s) ~= "string" then
		return out
	end
	for item in string.gmatch(s, "[^;]+") do
		local values = {}
		for x in string.gmatch(item, "[^,:]+") do
			table.insert(values, tonumber(x) or 0)
		end
		table.insert(out, values)
	end
	return out
end

-- ---------------------------------------------------------------------------------------------
-- undo + activity log (the plugin's Claude tab shows the log)
-- ---------------------------------------------------------------------------------------------
local function session()
	local ok, storage = pcall(function()
		return game:GetService("ServerStorage")
	end)
	if not ok then
		return nil
	end
	local folder = storage:FindFirstChild("LostCubeSession")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "LostCubeSession"
		folder.Archivable = false
		folder.Parent = storage
	end
	return folder
end

function Editor.log(text)
	local folder = session()
	if not folder then
		return
	end
	local ok, list = pcall(HttpService.JSONDecode, HttpService, folder:GetAttribute("Log") or "[]")
	list = ok and list or {}
	table.insert(list, { t = os.date("%H:%M:%S"), a = text })
	while #list > 40 do
		table.remove(list, 1)
	end
	folder:SetAttribute("Log", HttpService:JSONEncode(list))
end

function Editor.history()
	local folder = session()
	if not folder then
		return {}
	end
	local ok, list = pcall(HttpService.JSONDecode, HttpService, folder:GetAttribute("Log") or "[]")
	return ok and list or {}
end

local function record(name, fn, ...)
	local okBegin, id = pcall(ChangeHistoryService.TryBeginRecording, ChangeHistoryService, "LostCube: " .. name)
	local results = table.pack(pcall(fn, ...))
	if results[1] then
		Editor.log(name)
		local folder = Editor.folder(false)
		if folder then -- tells the plugin's panels to refresh
			folder:SetAttribute("LC_Rev", (folder:GetAttribute("LC_Rev") or 0) + 1)
		end
	end
	if okBegin and id then
		-- a failed step is rolled back, a good one becomes one Ctrl+Z
		local op = results[1] and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
		pcall(ChangeHistoryService.FinishRecording, ChangeHistoryService, id, op)
	end
	if not results[1] then
		error(results[2], 2)
	end
	return table.unpack(results, 2, results.n)
end

-- ---------------------------------------------------------------------------------------------
-- effects
-- ---------------------------------------------------------------------------------------------
function Editor.folder(create)
	local root = ReplicatedStorage:FindFirstChild("LostCube")
	if not root then
		if create == false then
			return nil
		end
		root = Instance.new("Folder")
		root.Name = "LostCube"
		root.Parent = ReplicatedStorage
	end
	local effects = root:FindFirstChild("Effects")
	if not effects and create ~= false then
		effects = Instance.new("Folder")
		effects.Name = "Effects"
		effects.Parent = root
	end
	return effects
end

function Editor.effects()
	local folder = Editor.folder(false)
	local list = {}
	for _, m in (folder and folder:GetChildren() or {}) do
		if m:IsA("Model") then
			table.insert(list, m)
		end
	end
	table.sort(list, function(a, b)
		return a.Name:lower() < b.Name:lower()
	end)
	return list
end

function Editor.effect(nameOrModel)
	if typeof(nameOrModel) == "Instance" then
		return nameOrModel
	end
	local folder = Editor.folder(false)
	local found = folder and folder:FindFirstChild(nameOrModel)
	assert(found, "LostCube: nu există efectul " .. tostring(nameOrModel))
	return found
end

local function rootOf(effect)
	return effect.PrimaryPart or effect:FindFirstChild("Root")
end

local function invisiblePart(name, size, cf)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.Transparency = 1
	return p
end

function Editor.newEffect(name, opts)
	opts = opts or {}
	return record("efect nou " .. name, function()
		local folder = Editor.folder(true)
		local old = folder:FindFirstChild(name)
		if old then
			assert(opts.replace, "LostCube: efectul " .. name .. " există deja (replace = true ca să-l refaci)")
			old:Destroy()
		end
		local model = Instance.new("Model")
		model.Name = name
		local root = invisiblePart("Root", Vector3.new(0.2, 0.2, 0.2), CFrame.new())
		root.Parent = model
		model.PrimaryPart = root
		model:SetAttribute("LC_Duration", opts.duration or 1)
		model:SetAttribute("LC_Attach", opts.attach or "GROUND")
		model:SetAttribute("LC_Tool", "LostCube")
		model.Parent = folder
		return model
	end)
end

local function assertFreeName(folder, name, except)
	assert(type(name) == "string" and name ~= "", "LostCube: numele efectului nu poate fi gol")
	local other = folder and folder:FindFirstChild(name)
	assert(not other or other == except, "LostCube: există deja un efect numit " .. name)
end

function Editor.renameEffect(effect, name)
	effect = Editor.effect(effect)
	assertFreeName(effect.Parent, name, effect)
	return record("redenumit " .. effect.Name .. " -> " .. name, function()
		effect.Name = name
	end)
end

function Editor.setEffect(effect, opts)
	effect = Editor.effect(effect)
	return record("setări efect " .. effect.Name, function()
		if opts.duration then
			effect:SetAttribute("LC_Duration", math.max(0.01, opts.duration))
		end
		if opts.attach then
			effect:SetAttribute("LC_Attach", opts.attach)
		end
		if opts.name then
			assertFreeName(effect.Parent, opts.name, effect)
			effect.Name = opts.name
		end
	end)
end

function Editor.duplicateEffect(effect, name)
	effect = Editor.effect(effect)
	return record("duplicat " .. effect.Name, function()
		local copy = effect:Clone()
		local base = name or (effect.Name .. " copie")
		local free, i = base, 2
		while effect.Parent:FindFirstChild(free) do -- duplicating twice must not give two effects with one name
			free = base .. " " .. i
			i += 1
		end
		copy.Name = free
		copy.Parent = effect.Parent
		return copy
	end)
end

function Editor.removeEffect(effect)
	effect = Editor.effect(effect)
	return record("șters efect " .. effect.Name, function()
		effect:Destroy()
	end)
end

-- ---------------------------------------------------------------------------------------------
-- elements
-- ---------------------------------------------------------------------------------------------
function Editor.kindOf(inst)
	if inst:IsA("BasePart") and inst:GetAttribute("LC_Mode") then
		return "MESH"
	elseif inst:IsA("ParticleEmitter") then
		return "PARTICLES"
	elseif inst:IsA("PointLight") or inst:IsA("SpotLight") then
		return "LIGHT"
	elseif inst:IsA("Trail") then
		return "TRAIL"
	end
	return nil
end

function Editor.elements(effect)
	effect = Editor.effect(effect)
	local list = {}
	for _, d in effect:GetDescendants() do
		if Editor.kindOf(d) then
			table.insert(list, d)
		end
	end
	table.sort(list, function(a, b)
		return a.Name:lower() < b.Name:lower()
	end)
	return list
end

function Editor.effectOf(element)
	return element:FindFirstAncestorWhichIsA("Model")
end

local function uniqueName(effect, base)
	local taken = {}
	for _, e in Editor.elements(effect) do
		taken[e.Name] = true
	end
	if not taken[base] then
		return base
	end
	local i = 2
	while taken[base .. " " .. i] do
		i += 1
	end
	return base .. " " .. i
end

local function trailAttachments(trail)
	return trail.Attachment0, trail.Attachment1
end

function Editor.position(element)
	local parent = element.Parent
	if element:IsA("BasePart") then -- 3D mesh element: the part itself
		local root = rootOf(Editor.effectOf(element))
		return root.CFrame:PointToObjectSpace(element.Position)
	elseif element:IsA("Trail") then
		local a, b = trailAttachments(element)
		return (a and b) and (a.Position + b.Position) / 2 or Vector3.zero
	elseif parent and parent:IsA("Attachment") then
		return parent.Position
	elseif parent and parent:IsA("BasePart") then
		local root = rootOf(Editor.effectOf(element))
		return root.CFrame:PointToObjectSpace(parent.Position)
	end
	return Vector3.zero
end

local function setPosition(element, pos)
	local parent = element.Parent
	if element:IsA("BasePart") then
		local root = rootOf(Editor.effectOf(element))
		local rot = element.CFrame - element.CFrame.Position
		element.CFrame = CFrame.new(root.CFrame:PointToWorldSpace(pos)) * rot
	elseif element:IsA("Trail") then
		local a, b = trailAttachments(element)
		local h = (a and b) and (a.Position - b.Position).Magnitude or 3
		if a then
			a.Position = pos + Vector3.new(0, h / 2, 0)
		end
		if b then
			b.Position = pos - Vector3.new(0, h / 2, 0)
		end
	elseif parent:IsA("Attachment") then
		parent.Position = pos
	elseif parent:IsA("BasePart") then
		local root = rootOf(Editor.effectOf(element))
		local rot = parent.CFrame - parent.CFrame.Position
		parent.CFrame = CFrame.new(root.CFrame:PointToWorldSpace(pos)) * rot
	end
end

local SHAPES = { Point = true, Box = true, Sphere = true, Cylinder = true, Disc = true }

function Editor.shapeOf(emitter)
	if emitter.Parent and emitter.Parent:IsA("BasePart") then
		return emitter.Shape.Name
	end
	return "Point"
end

local function setShape(emitter, shape, partSize)
	assert(SHAPES[shape], "LostCube: formă necunoscută " .. tostring(shape))
	local effect = Editor.effectOf(emitter)
	local root = rootOf(effect)
	local pos = Editor.position(emitter)
	local old = emitter.Parent
	if shape == "Point" then
		if old:IsA("Attachment") then
			return
		end
		local att = Instance.new("Attachment")
		att.Name = emitter.Name
		att.Position = pos
		att.Parent = root
		emitter.Parent = att
		old:Destroy()
		return
	end
	emitter.Shape = Enum.ParticleEmitterShape[shape]
	if old:IsA("BasePart") then
		if partSize then
			old.Size = partSize
		end
		return
	end
	local part = invisiblePart(emitter.Name, partSize or Vector3.new(3, 0.3, 3), root.CFrame * CFrame.new(pos))
	part.Parent = effect
	emitter.Parent = part
	old:Destroy()
end

local function setTimeline(element, key, value)
	if key == "window" then
		if value and value[2] > value[1] then
			element:SetAttribute("LC_On", string.format("%s,%s", round(value[1]), round(value[2])))
		else
			element:SetAttribute("LC_On", nil)
		end
	elseif key == "bursts" then
		local parts = {}
		table.sort(value, function(a, b)
			return a[1] < b[1]
		end)
		for _, b in value do
			table.insert(parts, string.format("%s:%d", round(b[1]), b[2]))
		end
		element:SetAttribute("LC_Bursts", #parts > 0 and table.concat(parts, ";") or nil)
	elseif key == "keys" then
		local parts = {}
		table.sort(value, function(a, b)
			return a[1] < b[1]
		end)
		for _, k in value do
			table.insert(parts, string.format("%s,%s,%s", round(k[1]), round(k[2], 3), round(k[3], 3)))
		end
		element:SetAttribute("LC_Keys", #parts > 0 and table.concat(parts, ";") or nil)
		if value[1] then
			element.Brightness = value[1][2]
			element.Range = value[1][3]
		end
	end
end

local function setOne(element, key, value)
	if key == "name" then
		local parent = element.Parent
		if element:IsA("Trail") then
			local a, b = trailAttachments(element)
			if a then
				a.Name = value .. "_Top"
			end
			if b then
				b.Name = value .. "_Bottom"
			end
		elseif parent and not parent:IsA("Model") and parent.Name == element.Name then
			parent.Name = value
		end
		element.Name = value
	elseif key == "position" then
		setPosition(element, vec3(value))
	elseif key == "shape" then
		setShape(element, typeof(value) == "EnumItem" and value.Name or value)
	elseif key == "partSize" then
		if element.Parent:IsA("BasePart") then
			element.Parent.Size = vec3(value)
		end
	elseif key == "texture" then
		element.Texture = TEXTURE_URL[value] or value
	elseif key == "color" then
		if element:IsA("PointLight") or element:IsA("SpotLight") then
			element.Color = toColor(type(value) == "table" and type(value[1]) ~= "number" and value[1] or value)
		else
			element.Color = colorSequence(value)
		end
	elseif key == "size" then
		element.Size = numberSequence(value)
	elseif key == "transparency" then
		element.Transparency = numberSequence(value)
	elseif key == "squash" then
		element.Squash = numberSequence(value)
	elseif key == "lifetime" then
		if element:IsA("Trail") then
			element.Lifetime = type(value) == "table" and value[1] or value
		else
			element.Lifetime = numberRange(value)
		end
	elseif key == "speed" then
		element.Speed = numberRange(value)
	elseif key == "rotation" then
		element.Rotation = numberRange(value)
	elseif key == "rotSpeed" then
		element.RotSpeed = numberRange(value)
	elseif key == "spread" then
		element.SpreadAngle = typeof(value) == "Vector2" and value or Vector2.new(value[1], value[2])
	elseif key == "acceleration" then
		element.Acceleration = vec3(value)
	elseif key == "window" or key == "bursts" or key == "keys" then
		setTimeline(element, key, value)
	elseif key == "height" or key == "width" then
		local a, b = trailAttachments(element)
		local center = Editor.position(element)
		if a then
			a.Position = center + Vector3.new(0, value / 2, 0)
		end
		if b then
			b.Position = center - Vector3.new(0, value / 2, 0)
		end
	elseif key == "ground" then -- a ribbon lying on the floor, following the path of the effect
		element:SetAttribute("LC_Ground", value and true or nil)
		element.FaceCamera = not value
	elseif key == "widthEnd" or key == "widthHead" then
		-- width along the trail: head (the newest end, at the foot) -> full width at 30% -> tail
		local k = element.WidthScale.Keypoints
		local head, tail = k[1].Value, k[#k].Value
		if key == "widthEnd" then tail = value else head = value end
		element.WidthScale = head >= 0.999 and NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, tail) })
			or NumberSequence.new({ NumberSequenceKeypoint.new(0, head), NumberSequenceKeypoint.new(0.3, 1), NumberSequenceKeypoint.new(1, tail) })
	elseif key == "lift" then
		element:SetAttribute("LC_Lift", value ~= 0 and value or nil)
	elseif key == "flow" then
		element:SetAttribute("LC_Flow", value and value > 0 and value or nil)
	elseif key == "muted" then
		element:SetAttribute("LC_Muted", value and true or nil)
	elseif key == "preset" then
		-- handled by applyPreset
	else
		local ok, current = pcall(function()
			return element[key]
		end)
		assert(ok, "LostCube: " .. element.ClassName .. " nu are proprietatea " .. tostring(key))
		local kind = typeof(current)
		if kind == "EnumItem" then
			value = enumItem(current.EnumType, value)
		elseif kind == "NumberSequence" then
			value = numberSequence(value)
		elseif kind == "ColorSequence" then
			value = colorSequence(value)
		elseif kind == "NumberRange" then
			value = numberRange(value)
		elseif kind == "Vector3" then
			value = vec3(value)
		elseif kind == "Color3" then
			value = toColor(value)
		end
		element[key] = value
	end
end

local MESH_ATTR = { mode = "LC_Mode", rate = "LC_Rate", Rate = "LC_Rate", direction = "LC_Dir", EmissionDirection = "LC_Dir",
	rise = "LC_Rise", spin = "LC_Spin", count = "LC_Count", jitter = "LC_Jitter", ground = "LC_Ground" }
local MESH_PAIR = { grow = "LC_Grow", transparency = "LC_Alpha", alpha = "LC_Alpha", lifetime = "LC_Life",
	speed = "LC_Speed", spread = "LC_Spread", radius = "LC_Radius" }

-- 3D mesh elements keep their behaviour in attributes; returns true when the key was handled
local function setMesh(part, key, value)
	if MESH_ATTR[key] then
		part:SetAttribute(MESH_ATTR[key], typeof(value) == "EnumItem" and value.Name or value)
	elseif MESH_PAIR[key] then
		local a, b
		if type(value) == "number" then
			a, b = value, value
		elseif typeof(value) == "NumberRange" then
			a, b = value.Min, value.Max
		elseif typeof(value) == "Vector2" then
			a, b = value.X, value.Y
		else
			a, b = value[1], value[2] or value[1]
		end
		part:SetAttribute(MESH_PAIR[key], string.format("%s,%s", round(a), round(b)))
	elseif key == "shape" then
		part.Shape = enumItem(Enum.PartType, value)
	elseif key == "material" then
		part.Material = enumItem(Enum.Material, value)
	elseif key == "color" then
		part.Color = toColor(type(value) == "table" and type(value[1]) ~= "number" and value[1] or value)
	elseif key == "colorEnd" then
		part:SetAttribute("LC_ColorEnd", value and toColor(value) or nil)
	elseif key == "size" or key == "partSize" then
		part.Size = vec3(value)
	else
		return false
	end
	return true
end

local ORDER = { "shape", "partSize", "position", "height" } -- shape first (it moves the emitter)

local function applyProps(element, props)
	if Editor.kindOf(element) == "MESH" then
		for key, value in props do
			if not setMesh(element, key, value) then
				setOne(element, key, value)
			end
		end
		return
	end
	for _, key in ORDER do
		if props[key] ~= nil then
			if key == "shape" then
				setShape(element, typeof(props.shape) == "EnumItem" and props.shape.Name or props.shape, props.partSize and vec3(props.partSize))
			else
				setOne(element, key, props[key])
			end
		end
	end
	for key, value in props do
		if not table.find(ORDER, key) then
			setOne(element, key, value)
		end
	end
end

local function create(effect, kind, name)
	local root = rootOf(effect)
	if kind == "MESH" then
		local p = invisiblePart(name, Vector3.new(1, 0.2, 1), root.CFrame)
		p.Material = Enum.Material.Neon
		p.Color = VIOLET
		p:SetAttribute("LC_Mode", "Pulse")
		p:SetAttribute("LC_Life", "0.5,0.5")
		p:SetAttribute("LC_Grow", "1,3")
		p:SetAttribute("LC_Alpha", "0.2,1")
		p.Parent = effect
		return p
	elseif kind == "PARTICLES" then
		local att = Instance.new("Attachment")
		att.Name = name
		att.Parent = root
		local e = Instance.new("ParticleEmitter")
		e.Name = name
		e.Enabled = false
		e.Texture = TEXTURE_URL.SPARKLES
		e.Rate = 20
		e.Lifetime = NumberRange.new(0.5, 0.8)
		e.Speed = NumberRange.new(5, 8)
		e.LightEmission = 1
		e.Parent = att
		return e
	elseif kind == "LIGHT" then
		local att = Instance.new("Attachment")
		att.Name = name
		att.Position = Vector3.new(0, 2, 0)
		att.Parent = root
		local l = Instance.new("PointLight")
		l.Name = name
		l.Color = VIOLET
		l.Brightness = 2
		l.Range = 12
		l.Parent = att
		return l
	elseif kind == "TRAIL" then
		local a = Instance.new("Attachment")
		a.Name = name .. "_Top"
		a.Position = Vector3.new(0, 1.5, 0)
		a.Parent = root
		local b = Instance.new("Attachment")
		b.Name = name .. "_Bottom"
		b.Position = Vector3.new(0, -1.5, 0)
		b.Parent = root
		local t = Instance.new("Trail")
		t.Name = name
		t.Attachment0, t.Attachment1 = a, b
		t.Enabled = false
		t.FaceCamera = true
		t.LightEmission = 1
		t.Lifetime = 0.25
		t.Parent = root
		return t
	end
	error("LostCube: tip necunoscut " .. tostring(kind))
end

--- addElement(effect, presetKey | "PARTICLES" | "LIGHT" | "TRAIL", props?) -> the emitter / light / trail
function Editor.addElement(effect, what, props)
	effect = Editor.effect(effect)
	props = props or {}
	local preset = PRESET_BY_KEY[what]
	local kind = preset and preset.kind or what
	return record("adăugat " .. (preset and preset.label or kind) .. " în " .. effect.Name, function()
		local name = uniqueName(effect, props.name or (preset and preset.label)
			or ({ PARTICLES = "Particule", LIGHT = "Lumină", TRAIL = "Trail", MESH = "Mesh 3D" })[kind])
		local element = create(effect, kind, name)
		if preset then
			applyProps(element, preset.props)
			element:SetAttribute("LC_Preset", preset.key)
		end
		local rest = table.clone(props)
		rest.name = nil
		applyProps(element, rest)
		return element
	end)
end

function Editor.setProps(element, props)
	return record("modificat " .. element.Name, function()
		applyProps(element, props)
		return element
	end)
end

function Editor.applyPreset(element, key)
	local preset = PRESET_BY_KEY[key]
	assert(preset and preset.kind == Editor.kindOf(element), "LostCube: preset nepotrivit " .. tostring(key))
	return record("preset " .. preset.label .. " pe " .. element.Name, function()
		element:SetAttribute("LC_On", nil)
		element:SetAttribute("LC_Bursts", nil)
		element:SetAttribute("LC_Keys", nil)
		applyProps(element, preset.props)
		element:SetAttribute("LC_Preset", preset.key)
		return element
	end)
end

function Editor.remove(element)
	return record("șters " .. element.Name, function()
		local parent = element.Parent
		if element:IsA("Trail") then
			local a, b = trailAttachments(element)
			if a then
				a:Destroy()
			end
			if b then
				b:Destroy()
			end
			element:Destroy()
		elseif parent and (parent:IsA("Attachment") or (parent:IsA("BasePart") and parent.Name ~= "Root")) then
			element:Destroy()
			if #parent:GetChildren() == 0 then
				parent:Destroy()
			end
		else
			element:Destroy()
		end
	end)
end

function Editor.duplicate(element)
	return record("duplicat " .. element.Name, function()
		local effect = Editor.effectOf(element)
		local name = uniqueName(effect, element.Name)
		if Editor.kindOf(element) == "MESH" then
			local copy = element:Clone()
			copy.Name = name
			copy.Parent = effect
			return copy
		end
		local data = Editor.read(element)
		local copy = create(effect, Editor.kindOf(element), name)
		for _, prop in { "Texture", "Color", "Transparency", "LightEmission", "LightInfluence", "Brightness", "Enabled" } do
			pcall(function()
				copy[prop] = element[prop]
			end)
		end
		if copy:IsA("ParticleEmitter") then
			for _, prop in { "Size", "Squash", "Lifetime", "Rate", "Speed", "SpreadAngle", "Acceleration", "Drag", "Rotation",
				"RotSpeed", "Orientation", "ZOffset", "LockedToPart", "EmissionDirection", "ShapeStyle", "ShapeInOut" } do
				copy[prop] = element[prop]
			end
			setShape(copy, data.shape, data.partSize)
		elseif copy:IsA("PointLight") then
			copy.Range, copy.Shadows = element.Range, element.Shadows
		elseif copy:IsA("Trail") then
			copy.Lifetime, copy.WidthScale = element.Lifetime, element.WidthScale
			for _, prop in { "FaceCamera", "MinLength", "MaxLength", "TextureMode", "TextureLength" } do
				copy[prop] = element[prop]
			end
			setOne(copy, "height", data.height)
		end
		setPosition(copy, data.position)
		for attr, value in element:GetAttributes() do -- timeline, preset, muted, ground / lift / flow
			copy:SetAttribute(attr, value)
		end
		return copy
	end)
end

-- timeline shortcuts
function Editor.bursts(element)
	local out = {}
	for _, b in parseList(element:GetAttribute("LC_Bursts")) do
		table.insert(out, { b[1] or 0, b[2] or 1 })
	end
	return out
end

function Editor.addBurst(element, t, n)
	local list = Editor.bursts(element)
	table.insert(list, { t, n })
	return Editor.setProps(element, { bursts = list })
end

function Editor.window(element)
	local w = parseList(element:GetAttribute("LC_On"))[1]
	return w and { w[1], w[2] } or nil
end

function Editor.lightKeys(element)
	return parseList(element:GetAttribute("LC_Keys"))
end

--- stretches (k > 1) or squeezes (k < 1) the whole effect in time: duration, emission windows, bursts,
--- light keys and lifetimes; speeds stay, so particles travel further when it is slower
function Editor.retime(effect, k)
	assert(type(k) == "number" and k > 0, "LostCube: factorul de timp trebuie să fie un număr > 0")
	effect = Editor.effect(effect)
	return record(string.format("timp x%.2f pe %s", k, effect.Name), function()
		effect:SetAttribute("LC_Duration", round((effect:GetAttribute("LC_Duration") or 1) * k))
		for _, e in Editor.elements(effect) do
			local w = Editor.window(e)
			if w then
				setTimeline(e, "window", { w[1] * k, w[2] * k })
			end
			local b = Editor.bursts(e)
			if #b > 0 then
				for _, x in b do
					x[1] *= k
				end
				setTimeline(e, "bursts", b)
			end
			if e:IsA("ParticleEmitter") then
				e.Lifetime = NumberRange.new(e.Lifetime.Min * k, e.Lifetime.Max * k)
			elseif e:IsA("Trail") then
				e.Lifetime *= k
			elseif e:IsA("PointLight") then
				local keys = Editor.lightKeys(e)
				if #keys > 0 then
					for _, key in keys do
						key[1] *= k
					end
					setTimeline(e, "keys", keys)
				end
			elseif Editor.kindOf(e) == "MESH" then
				local life = parseList(e:GetAttribute("LC_Life"))[1]
				if life then
					e:SetAttribute("LC_Life", string.format("%s,%s", round(life[1] * k), round((life[2] or life[1]) * k)))
				end
			end
		end
	end)
end

-- ---------------------------------------------------------------------------------------------
-- reading (simple values for the panels)
-- ---------------------------------------------------------------------------------------------
local function seq3(seq)
	local k = seq.Keypoints
	if #k <= 2 then
		local a, b = k[1].Value, k[#k].Value
		return { a, (a + b) / 2, b, mid = 0.5 }
	end
	local m = k[math.ceil(#k / 2)]
	return { k[1].Value, m.Value, k[#k].Value, mid = m.Time }
end

local function colors3(seq)
	local k = seq.Keypoints
	if #k == 2 and k[1].Value == k[2].Value then
		return { k[1].Value }
	elseif #k == 2 then
		return { k[1].Value, k[2].Value }
	end
	local m = k[math.ceil(#k / 2)]
	return { k[1].Value, m.Value, k[#k].Value, mid = m.Time }
end

function Editor.read(element)
	local kind = Editor.kindOf(element)
	local data = { kind = kind, name = element.Name, position = Editor.position(element),
		muted = element:GetAttribute("LC_Muted") == true, preset = element:GetAttribute("LC_Preset") }
	if kind == "PARTICLES" then
		local e = element
		data.texture = TEXTURE_KEY[e.Texture] or (e.Texture == "" and "NONE" or "CUSTOM")
		data.textureId = e.Texture
		data.color = colors3(e.Color)
		data.size = seq3(e.Size)
		data.transparency = seq3(e.Transparency)
		data.squash = e.Squash.Keypoints[1].Value
		data.lifetime = { e.Lifetime.Min, e.Lifetime.Max }
		data.speed = { e.Speed.Min, e.Speed.Max }
		data.rotation = { e.Rotation.Min, e.Rotation.Max }
		data.rotSpeed = { e.RotSpeed.Min, e.RotSpeed.Max }
		data.spread = { e.SpreadAngle.X, e.SpreadAngle.Y }
		data.acceleration = e.Acceleration
		data.shape = Editor.shapeOf(e)
		data.partSize = e.Parent:IsA("BasePart") and e.Parent.Size or nil
		for _, prop in { "Rate", "Drag", "LightEmission", "LightInfluence", "Brightness", "ZOffset", "LockedToPart" } do
			data[prop] = e[prop]
		end
		for _, prop in { "Orientation", "EmissionDirection", "ShapeStyle", "ShapeInOut" } do
			data[prop] = e[prop].Name
		end
		data.window = Editor.window(e)
		data.bursts = Editor.bursts(e)
	elseif kind == "MESH" then
		local p = element
		local function pairOf(attr, a, b)
			local v = parseList(p:GetAttribute(attr))[1]
			return { v and v[1] or a, v and (v[2] or v[1]) or b }
		end
		data.mode = p:GetAttribute("LC_Mode")
		data.shape = p.Shape.Name
		data.material = p.Material.Name
		data.color = p.Color
		data.colorEnd = p:GetAttribute("LC_ColorEnd")
		data.size = p.Size
		data.grow = pairOf("LC_Grow", 1, 1)
		data.transparency = pairOf("LC_Alpha", 0, 1)
		data.lifetime = pairOf("LC_Life", 0.5, 0.5)
		data.speed = pairOf("LC_Speed", 0, 0)
		data.spread = pairOf("LC_Spread", 0, 0)
		data.radius = pairOf("LC_Radius", 1, 6)
		data.Rate = p:GetAttribute("LC_Rate") or 0
		data.direction = p:GetAttribute("LC_Dir") or "Top"
		data.rise = p:GetAttribute("LC_Rise") or 0
		data.spin = p:GetAttribute("LC_Spin") or 0
		data.count = p:GetAttribute("LC_Count") or 16
		data.jitter = p:GetAttribute("LC_Jitter") or 0
		data.ground = p:GetAttribute("LC_Ground") == true
		data.window = Editor.window(p)
		data.bursts = Editor.bursts(p)
	elseif kind == "LIGHT" then
		data.Color, data.Brightness, data.Range, data.Shadows = element.Color, element.Brightness, element.Range, element.Shadows
		data.keys = Editor.lightKeys(element)
	elseif kind == "TRAIL" then
		local t = element
		data.texture = TEXTURE_KEY[t.Texture] or (t.Texture == "" and "NONE" or "CUSTOM")
		data.textureId = t.Texture
		data.color = colors3(t.Color)
		data.transparency = seq3(t.Transparency)
		data.lifetime = t.Lifetime
		data.LightEmission = t.LightEmission
		data.Brightness = t.Brightness
		data.widthEnd = t.WidthScale.Keypoints[#t.WidthScale.Keypoints].Value
		data.widthHead = t.WidthScale.Keypoints[1].Value
		data.ground = t:GetAttribute("LC_Ground") == true
		data.lift = t:GetAttribute("LC_Lift") or 0
		data.flow = t:GetAttribute("LC_Flow") or 0
		local a, b = trailAttachments(t)
		data.height = (a and b) and (a.Position - b.Position).Magnitude or 3
		data.window = Editor.window(t)
	end
	return data
end

function Editor.describe()
	local out = {}
	for _, fx in Editor.effects() do
		local els = {}
		for _, e in Editor.elements(fx) do
			table.insert(els, { name = e.Name, kind = Editor.kindOf(e), preset = e:GetAttribute("LC_Preset") })
		end
		table.insert(out, { name = fx.Name, duration = fx:GetAttribute("LC_Duration"), attach = fx:GetAttribute("LC_Attach"),
			elements = els })
	end
	return out
end

-- ---------------------------------------------------------------------------------------------
-- preview in Studio
-- ---------------------------------------------------------------------------------------------
-- where to show it: the selection (a part / a character), else on the floor in front of the camera
function Editor.previewTarget()
	local sel = Selection:Get()[1]
	-- only things in the world: an element picked with "Select in Explorer" lives in ReplicatedStorage (near the origin)
	if sel and sel:IsDescendantOf(workspace) and not sel:IsDescendantOf(workspace.CurrentCamera) then
		if sel:IsA("Model") and sel:FindFirstChildOfClass("Humanoid") then
			return sel
		elseif sel:IsA("BasePart") then
			return CFrame.new(sel.Position - Vector3.new(0, sel.Size.Y / 2, 0))
		elseif sel:IsA("Model") then
			return CFrame.new(sel:GetPivot().Position)
		end
	end
	local cam = workspace.CurrentCamera
	local look = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
	look = look.Magnitude > 1e-3 and look.Unit or Vector3.new(0, 0, -1)
	local spot = cam.CFrame.Position + cam.CFrame.LookVector * 16
	local params = RaycastParams.new()
	local hit = workspace:Raycast(spot + Vector3.new(0, 30, 0), Vector3.new(0, -200, 0), params)
	local y = hit and hit.Position.Y or (spot.Y - 3)
	local pos = Vector3.new(spot.X, y, spot.Z)
	return CFrame.lookAt(pos, pos - look)
end

function Editor.preview(effect, opts)
	effect = Editor.effect(effect)
	opts = opts or {}
	local target = opts.target or Editor.previewTarget()
	return VFX.play(effect, target, {
		speed = opts.speed or 1,
		scale = opts.scale or 1,
		parent = opts.parent or workspace.CurrentCamera,
		attach = opts.attach,
		facing = opts.facing,
	})
end

-- total length of one play (duration + the longest particle life), seconds
function Editor.length(effect)
	effect = Editor.effect(effect)
	local tail = 0
	for _, e in Editor.elements(effect) do
		if e:IsA("ParticleEmitter") then
			tail = math.max(tail, e.Lifetime.Max)
		elseif e:IsA("Trail") then
			tail = math.max(tail, e.Lifetime)
		elseif Editor.kindOf(e) == "MESH" then
			local life = parseList(e:GetAttribute("LC_Life"))[1]
			tail = math.max(tail, life and (life[2] or life[1]) or 0.5)
		end
	end
	return (effect:GetAttribute("LC_Duration") or 1) + tail
end

Editor.VFX = VFX
return Editor
