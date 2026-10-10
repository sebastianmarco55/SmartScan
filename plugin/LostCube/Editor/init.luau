--[[ LostCube Editor - creates and edits Roblox effects (LostCube VFX format) in Studio.
Used by the LostCube plugin's panels and by Claude (through Studio):

	local Editor = require(game.ReplicatedStorage.LostCube.Editor)
	local fx = Editor.newEffect("Boom", { duration = 0.6, attach = "GROUND" })
	local s = Editor.addElement(fx, "SPARKLES", { position = Vector3.new(0, 3, 0), bursts = { { 0.1, 40 } } })
	Editor.setProps(s, { color = { Color3.new(1, 1, 1), Color3.fromRGB(158, 92, 255) }, speed = { 18, 30 } })
	Editor.preview(fx)  -- plays it in Studio, in front of the camera (or on the selection)
	Editor.newFromTemplate("Boom 2", "FIRE_EXPLOSION", { color = Color3.fromRGB(80, 160, 255), scale = 1.5 })  -- Editor.TEMPLATES
	Editor.importAsset(123456789, "Free VFX")  -- free Creator Store model -> effect (its scripts are deleted first)
	Editor.importEmitters(fx, workspace.SomeModel)  -- the emitters / trails / lights of a model -> elements of fx

Format (the same the Blender exporter writes; LostCube.VFX plays it in the game):
	Model <effect>  attributes LC_Duration (s), LC_Attach
	  Part Root
	    Attachment <element> > ParticleEmitter / PointLight      (point emitters, lights)
	    Attachment <element>_Top / _Bottom + Trail <element>      (trails)
	    Attachment <element> > Sound                              (sounds: LC_Pitch "min,max", LC_Fade)
	    Attachment <element> > Configuration, LC_Kind = "CAMERA"  (camera: LC_Shake, LC_Freq, LC_ShakeTime, LC_FOV,
	                                                               LC_FovTime, LC_Flash, LC_FlashAlpha, LC_FlashTime, LC_Radius, LC_Studio)
	    Attachment <element>_Start / _End + Beam <element>        (beams: LC_FlashTime, LC_Fade, LC_Jitter)
	  Part <element> > ParticleEmitter                            (shape emitters: the Part is the shape)
	  Part <element>, LC_Mode = Ring | Crack | ...                (3D mesh pieces)
Timeline attributes (seconds) on elements: LC_On "t0,t1", LC_Bursts "t:n;t:n", LC_Keys "t,b,r;..." (lights),
LC_Muted (skipped by the player). Sounds: bursts play them (n overlapping), a window loops them. Camera: bursts are kicks
(shake + FOV punch + flash), a window is a steady rumble. Beams: a window shows them, bursts flash them. VFX.luau's header
has the details.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")

local VFX = require(script:FindFirstChild("VFX") or script.Parent:WaitForChild("VFX"))

local Editor = {}
Editor.VERSION = "2.1.0"

local P = "rbxasset://textures/particles/"
-- the ground crack streak (Textures/ground_crack_trail.png), uploaded as one asset
Editor.GROUND_CRACK_URL = "rbxassetid://105887359860913" -- rotated 90 degrees: Trail maps image height along the length
-- Textures. Only paths that were checked (docs/vfx-sources.md): the particles folder of Roblox's own content (ships with every
-- client, no upload, no ownership) and the image ids Roblox itself publishes in its official VFX tutorials (creator-docs).
-- Keys stay stable (saved effects store the url, not the key); `group` is only used to organise the pickers.
local GROUP_BUILTIN = "Încorporate în Roblox (fără upload)"
local GROUP_DOCS = "Roblox oficial (ID-uri din tutoriale)"
local GROUP_OTHER = "Altele"
local function docs(id)
	return "rbxassetid://" .. id
end
Editor.TEXTURES = {
	{ key = "SPARKLES", label = "Scântei (stea)", url = P .. "sparkles_main.dds", group = GROUP_BUILTIN },
	{ key = "GLOW", label = "Glow (bilă moale)", url = P .. "explosion01_implosion_main.dds", group = GROUP_BUILTIN },
	{ key = "RING", label = "Inel (undă)", url = P .. "explosion01_shockwave_main.dds", group = GROUP_BUILTIN },
	{ key = "CIRCLE", label = "Cerc magic", url = P .. "forcefield_vortex_main.dds", group = GROUP_BUILTIN },
	{ key = "SMOKE", label = "Fum", url = P .. "smoke_main.dds", group = GROUP_BUILTIN },
	{ key = "SMOKE_SOFT", label = "Fum moale", url = P .. "explosion01_smoke_main.dds", group = GROUP_BUILTIN },
	{ key = "FIRE", label = "Foc", url = P .. "fire_main.dds", group = GROUP_BUILTIN },
	{ key = "EXPLOSION", label = "Explozie", url = P .. "explosion01_core_main.dds", group = GROUP_BUILTIN },
	{ key = "SQUARE", label = "Pătrat", url = P .. "SquareParticle.png", group = GROUP_BUILTIN },
	{ key = "FIRE_SPARKS", label = "Jar mărunt (puncte de foc)", url = P .. "fire_sparks_main.dds", group = GROUP_BUILTIN },
	{ key = "FORCEFIELD_GLOW", label = "Aură difuză (forcefield)", url = P .. "forcefield_glow_main.dds", group = GROUP_BUILTIN },
	-- the "starter pack" of textures in Roblox's official tutorials ("Work with particle emitters", "Build It Play It"): each id is
	-- printed under its picture, the same on four pages
	{ key = "STAR4", label = "Stea cu 4 raze", url = docs(5860841663), group = GROUP_DOCS },
	{ key = "STAR_BURST", label = "Stea strălucitoare (cu raze)", url = docs(5860841737), group = GROUP_DOCS },
	{ key = "STAR_SOLID", label = "Stea plină", url = docs(6772783963), group = GROUP_DOCS },
	{ key = "SWIRL", label = "Spirală / vârtej", url = docs(5857851812), group = GROUP_DOCS },
	{ key = "RING_SOFT", label = "Inel moale", url = docs(6711256324), group = GROUP_DOCS },
	{ key = "DISC_SOFT", label = "Disc moale", url = docs(5857892330), group = GROUP_DOCS },
	{ key = "SMOKE_WISP", label = "Fum (nor ușor)", url = docs(5833235272), group = GROUP_DOCS },
	{ key = "ELECTRIC_CRACKLE", label = "Descărcare electrică (rețea)", url = docs(5833323391), group = GROUP_DOCS },
	{ key = "LIGHTNING_LINE", label = "Fulger (linie)", url = docs(5857931724), group = GROUP_DOCS },
	{ key = "SCRATCH", label = "Zgârieturi (tăietură)", url = docs(5857892405), group = GROUP_DOCS },
	-- tutorials "Use particles for explosions", "Custom particle effects" and "Create basic visual effects"
	{ key = "ELECTRIC_SPARK", label = "Scântei electrice", url = docs(6101261905), group = GROUP_DOCS },
	{ key = "SOFT_CIRCLE", label = "Cerc cu margini moi", url = docs(3845808160), group = GROUP_DOCS },
	{ key = "FLARE_BIG", label = "Flare mare (lumină aditivă)", url = docs(8983307836), group = GROUP_DOCS },
	{ key = "DUST_MOTES", label = "Particule de praf", url = docs(14302399641), group = GROUP_DOCS },
	{ key = "CLOUD", label = "Nor mare", url = docs(10714362544), group = GROUP_DOCS },
	-- tutorials "Create waterfalls" and "Create volcanoes" (water, foam, mist and embers)
	{ key = "SPLASH_DENSE", label = "Stropi denși de apă", url = docs(16829556885), group = GROUP_DOCS },
	{ key = "DROPLETS", label = "Picături fine", url = docs(17082061238), group = GROUP_DOCS },
	{ key = "WHITEWATER", label = "Apă spumoasă (plasă)", url = docs(16808075391), group = GROUP_DOCS },
	{ key = "FOAM_RING", label = "Spumă (inel de ondulații)", url = docs(16811365086), group = GROUP_DOCS },
	{ key = "MIST", label = "Ceață / abur", url = docs(16830667309), group = GROUP_DOCS },
	{ key = "EMBERS", label = "Jar (scântei alungite)", url = docs(17581858560), group = GROUP_DOCS },
	{ key = "GROUND_CRACK", label = "Urmă crăpată (pe sol)", url = Editor.GROUND_CRACK_URL, group = GROUP_OTHER },
	{ key = "NONE", label = "Fără (alb)", url = "", group = GROUP_OTHER },
}
local TEXTURE_URL, TEXTURE_KEY = {}, {}
for _, t in Editor.TEXTURES do
	TEXTURE_URL[t.key] = t.url
	if t.url ~= "" then
		TEXTURE_KEY[t.url] = t.key
	end
end

-- Sounds that ship with every Roblox client (content/sounds, checked in the client file manifest of the
-- MaximumADHD/Roblox-Client-Tracker mirror): no upload, no ownership. Any rbxassetid:// sound id works too.
local SND = "rbxasset://sounds/"
Editor.SOUNDS = {
	{ key = "HIT", label = "Bufnitură (aterizare)", url = SND .. "action_jump_land.mp3" },
	{ key = "EXPLOSION", label = "Explozie", url = SND .. "impact_explosion_03.mp3" },
	{ key = "WIND", label = "Vânt (cădere) – pentru whoosh", url = SND .. "action_falling.ogg" },
	{ key = "JUMP", label = "Săritură", url = SND .. "action_jump.mp3" },
	{ key = "SPLASH", label = "Plescăit în apă", url = SND .. "impact_water.mp3" },
	{ key = "SWIM", label = "Înot (stropi)", url = SND .. "action_swim.mp3" },
	{ key = "GET_UP", label = "Ridicare de jos", url = SND .. "action_get_up.mp3" },
	{ key = "STEPS", label = "Pași", url = SND .. "action_footsteps_plastic.mp3" },
	{ key = "OOF", label = "Oof (clasic)", url = SND .. "oof.ogg" },
	{ key = "OUCH", label = "Ouch", url = SND .. "ouch.ogg" },
	{ key = "TICK", label = "Tic scurt (UI)", url = SND .. "volume_slider.ogg" },
}
local SOUND_URL, SOUND_KEY = {}, {}
for _, s in Editor.SOUNDS do
	SOUND_URL[s.key] = s.url
	SOUND_KEY[s.url] = s.key
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
-- More presets (grouped for the pickers). Texture sizes are chosen for the visible part of each image: several of the
-- official textures only fill the middle ~50% of their canvas, so their Size is about twice the wanted look.
do
	local GOLD = Color3.fromRGB(255, 214, 92)
	local ELECTRIC = Color3.fromRGB(140, 215, 255)
	local ICE = Color3.fromRGB(176, 228, 255)
	local WATER = Color3.fromRGB(150, 205, 255)
	local WATER_LIGHT = Color3.fromRGB(232, 245, 255)
	local HEAL = Color3.fromRGB(110, 255, 150)
	local HEAL_LIGHT = Color3.fromRGB(218, 255, 224)
	local TOXIC = Color3.fromRGB(130, 220, 70)
	local TOXIC_DEEP = Color3.fromRGB(58, 120, 44)

	local more = {
		-- electricity ------------------------------------------------------------------------------------------------
		{ key = "ELECTRIC_SPARKS", group = "Electricitate", label = "Scântei electrice", kind = "PARTICLES", props = {
			texture = "ELECTRIC_SPARK", color = { WHITE, ELECTRIC }, size = { 2.4, 1.8, 0.5 }, transparency = { 0, 0.2, 1 },
			LightEmission = 1, lifetime = { 0.2, 0.5 }, speed = { 18, 36 }, spread = { 180, 180 }, Drag = 8,
			rotation = { 0, 360 }, rotSpeed = { -140, 140 }, bursts = { { 0, 14 } } } },
		{ key = "ELECTRIC_ARC", group = "Electricitate", label = "Arcuri electrice (fulgere scurte)", kind = "PARTICLES", props = {
			texture = "LIGHTNING_LINE", color = { WHITE, ELECTRIC }, size = { 7, 8, 6, mid = 0.3 },
			transparency = { 0, 0.1, 1, mid = 0.3 }, LightEmission = 1, ZOffset = 1.5, lifetime = { 0.1, 0.2 }, speed = 0,
			rotation = { 0, 360 }, bursts = { { 0, 3 }, { 0.07, 3 }, { 0.14, 2 } } } },
		-- the bolt is about half of the image tall and sits a bit above its middle: the height of the emitter puts its tip on the floor
		{ key = "LIGHTNING_BOLT", group = "Electricitate", label = "Trăznet vertical", kind = "PARTICLES", props = {
			texture = "LIGHTNING_LINE", Orientation = "FacingCameraWorldUp", color = { WHITE, ELECTRIC }, size = { 36, 36, 34 },
			transparency = { 0, 0.05, 1 }, LightEmission = 1, Brightness = 2, ZOffset = 1, lifetime = { 0.12, 0.2 }, speed = 0,
			rotation = { -6, 6 }, position = Vector3.new(0, 5.4, 0), bursts = { { 0, 1 }, { 0.07, 1 }, { 0.15, 1 } } } },
		{ key = "ELECTRIC_CRACKLE", group = "Electricitate", label = "Descărcări electrice (continuu)", kind = "PARTICLES", props = {
			texture = "ELECTRIC_CRACKLE", color = { WHITE, ELECTRIC }, size = { 3.5, 3, 2 }, transparency = { 0.1, 0.2, 1 },
			LightEmission = 1, lifetime = { 0.08, 0.2 }, Rate = 14, speed = 0, rotation = { 0, 360 }, shape = "Sphere",
			partSize = Vector3.new(3, 4, 3), window = { 0, 1 } } },
		-- water and ice ----------------------------------------------------------------------------------------------
		{ key = "WATER_SPLASH", group = "Apă și gheață", label = "Stropi de apă (splash)", kind = "PARTICLES", props = {
			texture = "SPLASH_DENSE", color = { WATER_LIGHT, WATER }, size = { 2.5, 6, 8, mid = 0.4 },
			transparency = { 0.1, 0.35, 1, mid = 0.4 }, LightEmission = 0.15, LightInfluence = 0.8, lifetime = { 0.45, 0.75 },
			speed = { 4, 9 }, spread = { 30, 30 }, Drag = 4, rotation = { 0, 360 }, rotSpeed = { -50, 50 },
			position = Vector3.new(0, 0.5, 0), bursts = { { 0, 4 } } } },
		{ key = "WATER_DROPLETS", group = "Apă și gheață", label = "Picături de apă", kind = "PARTICLES", props = {
			texture = "DROPLETS", color = { WATER_LIGHT, Color3.fromRGB(190, 225, 255) }, size = { 2.5, 5, 6.5 },
			transparency = { 0.05, 0.2, 1 }, LightEmission = 0.2, LightInfluence = 0.8, lifetime = { 0.7, 1.1 },
			speed = { 10, 18 }, spread = { 35, 35 }, Drag = 0.8, acceleration = Vector3.new(0, -22, 0), rotation = { 0, 360 },
			position = Vector3.new(0, 0.4, 0), bursts = { { 0, 6 } } } },
		{ key = "WATER_RING", group = "Apă și gheață", label = "Ondulații pe apă (inel)", kind = "PARTICLES", props = {
			texture = "FOAM_RING", Orientation = "VelocityPerpendicular", color = { WATER_LIGHT, WATER },
			size = { 1.5, 9, 13, mid = 0.5 }, transparency = { 0.25, 0.4, 1, mid = 0.5 }, LightEmission = 0.1, LightInfluence = 0.8,
			lifetime = 0.8, speed = 0.01, rotation = { 0, 360 }, position = Vector3.new(0, 0.1, 0), bursts = { { 0, 1 } } } },
		{ key = "FROST_MIST", group = "Apă și gheață", label = "Ceață rece (la sol)", kind = "PARTICLES", props = {
			texture = "MIST", color = { Color3.fromRGB(205, 236, 255), Color3.fromRGB(170, 215, 250) }, size = { 4, 7, 9 },
			transparency = { 0.65, 0.72, 1 }, LightEmission = 0.2, LightInfluence = 0.6, lifetime = { 1, 1.6 }, Rate = 16,
			speed = { 1, 3 }, spread = { 180, 180 }, shape = "Disc", partSize = Vector3.new(4, 0.2, 4),
			acceleration = Vector3.new(0, 0.6, 0), rotation = { 0, 360 }, rotSpeed = { -18, 18 },
			position = Vector3.new(0, 0.3, 0), window = { 0, 0.8 } } },
		{ key = "FROST_SPARKLE", group = "Apă și gheață", label = "Cristale care sclipesc", kind = "PARTICLES", props = {
			texture = "STAR4", color = { WHITE, ICE }, size = { 0, 1.8, 0 }, transparency = { 0.1, 0.1, 1 }, LightEmission = 1,
			lifetime = { 0.6, 1.1 }, Rate = 30, speed = { 0.5, 2 }, spread = { 180, 180 }, shape = "Sphere",
			partSize = Vector3.new(3.5, 4.5, 3.5), rotation = { 0, 45 }, rotSpeed = { -80, 80 },
			position = Vector3.new(0, 2.5, 0), window = { 0, 1 } } },
		{ key = "SNOWFALL", group = "Apă și gheață", label = "Fulgi care cad", kind = "PARTICLES", props = {
			texture = "SOFT_CIRCLE", color = WHITE, size = { 0.5, 0.5, 0.4 }, transparency = { 0.15, 0.15, 1, mid = 0.8 },
			LightEmission = 0.4, LightInfluence = 0.5, lifetime = { 1.6, 2.4 }, Rate = 40, speed = { 0, 1 },
			spread = { 180, 180 }, acceleration = Vector3.new(0, -3.5, 0), shape = "Box", partSize = Vector3.new(7, 0.2, 7),
			position = Vector3.new(0, 7, 0), window = { 0, 1 } } },
		{ key = "ICE_SHARDS", group = "Apă și gheață", label = "Cioburi de gheață (3D)", kind = "MESH", props = {
			mode = "Debris", shape = "Wedge", material = "Ice", color = Color3.fromRGB(196, 236, 255),
			colorEnd = Color3.fromRGB(120, 190, 240), size = Vector3.new(0.3, 0.75, 0.3), grow = { 1, 0.4 },
			transparency = { 0.05, 1 }, lifetime = { 1, 1.5 }, speed = { 11, 20 }, spread = { 38, 38 }, direction = "Top",
			spin = 16, jitter = 0.5, position = Vector3.new(0, 0.3, 0), bursts = { { 0, 9 } } } },
		{ key = "ICE_CRACKS", group = "Apă și gheață", label = "Crăpături de gheață (pe sol)", kind = "MESH", props = {
			ground = true, mode = "Crack", shape = "Block", material = "Ice", color = Color3.fromRGB(214, 242, 255),
			colorEnd = Color3.fromRGB(120, 190, 240), size = Vector3.new(0.2, 0.08, 1), transparency = { 0.05, 1 },
			lifetime = { 1.4, 1.9 }, count = 9, radius = { 1.5, 3.6 }, position = Vector3.new(0, 0.03, 0), bursts = { { 0, 1 } } } },
		{ key = "WATER_DROPS3D", group = "Apă și gheață", label = "Picături 3D (cad cu fizică)", kind = "MESH", props = {
			mode = "Debris", shape = "Ball", material = "Glass", color = Color3.fromRGB(170, 220, 255), size = Vector3.new(0.22, 0.22, 0.22),
			grow = { 1, 0.5 }, transparency = { 0.25, 1 }, lifetime = { 0.9, 1.3 }, speed = { 7, 14 }, spread = { 35, 35 },
			direction = "Top", spin = 0, jitter = 0.5, position = Vector3.new(0, 0.4, 0), bursts = { { 0, 14 } } } },
		{ key = "ICE_LIGHT", group = "Lumini", label = "Lumină rece (gheață)", kind = "LIGHT", props = {
			Color = ICE, keys = { { 0, 0, 10 }, { 0.1, 3, 18 }, { 1, 2, 16 }, { 1.6, 0, 10 } }, position = Vector3.new(0, 2, 0) } },
		-- healing and holy light -------------------------------------------------------------------------------------
		{ key = "HEAL_MOTES", group = "Vindecare și lumină", label = "Sclipiri verzi care urcă", kind = "PARTICLES", props = {
			texture = "STAR4", color = { HEAL_LIGHT, HEAL }, size = { 1.6, 1.4, 0 }, transparency = { 0.1, 0.1, 1 },
			LightEmission = 1, lifetime = { 1, 1.6 }, Rate = 22, speed = { 2, 4.5 }, spread = { 10, 10 },
			acceleration = Vector3.new(0, 2, 0), Drag = 0.5, rotation = { 0, 360 }, rotSpeed = { -60, 60 }, shape = "Cylinder",
			partSize = Vector3.new(3, 0.2, 3), ShapeStyle = "Surface", position = Vector3.new(0, 0.2, 0), window = { 0, 0.9 } } },
		{ key = "HEAL_RING", group = "Vindecare și lumină", label = "Inel care urcă (scanare)", kind = "PARTICLES", props = {
			texture = "RING_SOFT", Orientation = "VelocityPerpendicular", color = { HEAL_LIGHT, HEAL },
			size = { 5, 5.5, 4.5 }, transparency = { 1, 0.15, 1, mid = 0.25 }, LightEmission = 1, lifetime = 0.9, speed = 3.2,
			spread = { 0, 0 }, position = Vector3.new(0, 0.1, 0), bursts = { { 0, 1 } } } },
		{ key = "HOLY_FLARE", group = "Vindecare și lumină", label = "Flare sfânt (stea mare)", kind = "PARTICLES", props = {
			texture = "STAR_BURST", color = { Color3.fromRGB(255, 250, 222), GOLD }, size = { 2, 14, 18, mid = 0.35 },
			transparency = { 0.1, 0.25, 1, mid = 0.35 }, LightEmission = 1, Brightness = 1.5, lifetime = 0.7, speed = 0,
			rotation = { 0, 30 }, rotSpeed = 25, ZOffset = 2, bursts = { { 0, 1 } } } },
		{ key = "HOLY_PILLAR", group = "Vindecare și lumină", label = "Coloană de lumină", kind = "MESH", props = {
			mode = "Pulse", shape = "Block", material = "Neon", color = Color3.fromRGB(255, 234, 160),
			colorEnd = Color3.fromRGB(255, 196, 80), size = Vector3.new(1.6, 14, 1.6), grow = { 0.9, 1.3 },
			transparency = { 0.3, 1 }, lifetime = 1, position = Vector3.new(0, 6.3, 0), bursts = { { 0, 1 } } } },
		{ key = "HEAL_LIGHT", group = "Lumini", label = "Lumină verde (vindecare)", kind = "LIGHT", props = {
			Color = HEAL, keys = { { 0, 0, 8 }, { 0.3, 2.5, 16 }, { 1.1, 2.5, 16 }, { 1.6, 0, 10 } }, position = Vector3.new(0, 2, 0) } },
		{ key = "HOLY_LIGHT", group = "Lumini", label = "Lumină sfântă (aurie)", kind = "LIGHT", props = {
			Color = GOLD, keys = { { 0, 0, 10 }, { 0.25, 4, 24 }, { 0.9, 2.5, 20 }, { 1.6, 0, 12 } }, position = Vector3.new(0, 3, 0) } },
		-- darkness and poison ----------------------------------------------------------------------------------------
		{ key = "DARK_SMOKE", group = "Întuneric și otravă", label = "Fum întunecat (energie)", kind = "PARTICLES", props = {
			texture = "SMOKE_SOFT", color = { Color3.fromRGB(55, 22, 86), Color3.fromRGB(14, 8, 22) }, size = { 2, 4, 6 },
			transparency = { 0.25, 0.5, 1 }, LightEmission = 0, LightInfluence = 0.2, lifetime = { 0.9, 1.5 }, Rate = 28,
			speed = { 1, 3 }, spread = { 180, 180 }, Drag = 1.5, acceleration = Vector3.new(0, 2.5, 0), rotation = { 0, 360 },
			rotSpeed = { -35, 35 }, shape = "Sphere", partSize = Vector3.new(2.4, 3, 2.4), position = Vector3.new(0, 2, 0),
			window = { 0, 1 } } },
		{ key = "DARK_WISPS", group = "Întuneric și otravă", label = "Aburi violet (energie)", kind = "PARTICLES", props = {
			texture = "SMOKE_WISP", color = { Color3.fromRGB(190, 110, 255), Color3.fromRGB(60, 20, 120) }, size = { 3.6, 5.2, 6.8 },
			transparency = { 0.35, 0.55, 1 }, LightEmission = 0.8, lifetime = { 0.7, 1.2 }, Rate = 16, speed = { 2, 5 },
			acceleration = Vector3.new(0, 4, 0), rotation = { 0, 360 }, rotSpeed = { -60, 60 }, shape = "Cylinder",
			partSize = Vector3.new(3, 0.2, 3), ShapeStyle = "Surface", position = Vector3.new(0, 0.2, 0), window = { 0, 1 } } },
		{ key = "POISON_BUBBLES", group = "Întuneric și otravă", label = "Bule otrăvitoare", kind = "PARTICLES", props = {
			texture = "RING_SOFT", color = { Color3.fromRGB(150, 255, 90), TOXIC_DEEP }, size = { 1.4, 2, 2.6 },
			transparency = { 0.25, 0.4, 1 }, LightEmission = 0.6, lifetime = { 0.9, 1.5 }, Rate = 14, speed = { 1.5, 3.5 },
			spread = { 20, 20 }, acceleration = Vector3.new(0, 3, 0), Drag = 1, shape = "Disc", partSize = Vector3.new(3, 0.1, 3),
			position = Vector3.new(0, 0.3, 0), window = { 0, 1 } } },
		{ key = "POISON_CLOUD", group = "Întuneric și otravă", label = "Nor toxic", kind = "PARTICLES", props = {
			texture = "SMOKE", color = { TOXIC, TOXIC_DEEP }, size = { 3, 5, 7 }, transparency = { 0.45, 0.6, 1 },
			LightEmission = 0.35, LightInfluence = 0.4, lifetime = { 1.2, 1.8 }, Rate = 10, speed = { 0.5, 2 },
			spread = { 180, 180 }, Drag = 1, acceleration = Vector3.new(0, 0.8, 0), rotation = { 0, 360 }, rotSpeed = { -25, 25 },
			shape = "Disc", partSize = Vector3.new(3.5, 0.2, 3.5), position = Vector3.new(0, 0.4, 0), window = { 0, 1 } } },
		-- combat -----------------------------------------------------------------------------------------------------
		{ key = "HIT_SPARK", group = "Luptă", label = "Scântei de lovitură (dungi)", kind = "PARTICLES", props = {
			texture = "GLOW", Orientation = "VelocityParallel", squash = -2.6, color = { Color3.fromRGB(255, 248, 215), Color3.fromRGB(255, 150, 50) },
			size = { 0.8, 0.6, 0 }, transparency = { 0, 0.1, 1 }, LightEmission = 1, lifetime = { 0.1, 0.25 },
			speed = { 25, 50 }, spread = { 180, 180 }, Drag = 2, bursts = { { 0, 14 } } } },
		{ key = "SLASH_MARK", group = "Luptă", label = "Tăietură (urmă de lamă)", kind = "PARTICLES", props = {
			texture = "SCRATCH", color = { WHITE, Color3.fromRGB(170, 215, 255) }, size = { 4, 10, 11, mid = 0.18 },
			transparency = { 0, 0.1, 1, mid = 0.18 }, LightEmission = 1, Brightness = 1.5, ZOffset = 1.5, lifetime = 0.22,
			speed = 0, rotation = { -20, 20 }, bursts = { { 0, 1 } } } },
		{ key = "SLASH_TRAIL", group = "Luptă", label = "Dâră de sabie (în mână)", kind = "TRAIL", props = {
			texture = "GLOW", color = { WHITE, Color3.fromRGB(160, 215, 255) }, transparency = { 0, 1 }, LightEmission = 1,
			lifetime = 0.22, widthEnd = 0, height = 3.6, window = { 0, 0.5 } } },
		-- movement ---------------------------------------------------------------------------------------------------
		{ key = "SPEED_LINES", group = "Mișcare", label = "Linii de viteză (în spate)", kind = "PARTICLES", props = {
			texture = "GLOW", Orientation = "VelocityParallel", squash = -2.6, color = { WHITE, Color3.fromRGB(190, 225, 255) },
			size = { 0.55, 0.45, 0 }, transparency = { 0.35, 0.45, 1 }, LightEmission = 0.9, lifetime = { 0.15, 0.3 }, Rate = 50,
			speed = { 38, 60 }, spread = { 5, 5 }, EmissionDirection = "Back", shape = "Box", partSize = Vector3.new(3.5, 4.5, 1),
			window = { 0, 1 } } },
		{ key = "AIR_RING", group = "Mișcare", label = "Inel de aer (în spate)", kind = "PARTICLES", props = {
			texture = "RING_SOFT", Orientation = "VelocityPerpendicular", EmissionDirection = "Back",
			color = { WHITE, Color3.fromRGB(200, 230, 255) }, size = { 2, 7, 10, mid = 0.5 }, transparency = { 0.3, 0.45, 1, mid = 0.5 },
			LightEmission = 0.8, lifetime = 0.35, speed = { 7, 10 }, spread = { 0, 0 }, position = Vector3.new(0, 0.2, 0.8),
			bursts = { { 0, 1 } } } },
		{ key = "DASH_WIND", group = "Mișcare", label = "Vânt (fum în spate)", kind = "PARTICLES", props = {
			texture = "SMOKE_WISP", color = { Color3.fromRGB(235, 242, 250), Color3.fromRGB(200, 215, 230) }, size = { 2.5, 5, 7 },
			transparency = { 0.5, 0.65, 1 }, LightEmission = 0.2, LightInfluence = 0.9, lifetime = { 0.3, 0.55 }, Rate = 36,
			speed = { 6, 13 }, spread = { 22, 22 }, EmissionDirection = "Back", shape = "Box", partSize = Vector3.new(2.5, 4, 1),
			rotation = { 0, 360 }, rotSpeed = { -40, 40 }, window = { 0, 0.4 } } },
		{ key = "DASH_TRAIL", group = "Mișcare", label = "Dâră de viteză", kind = "TRAIL", props = {
			texture = "GLOW", color = { WHITE, Color3.fromRGB(190, 225, 255) }, transparency = { 0.25, 1 }, LightEmission = 0.9,
			lifetime = 0.4, widthEnd = 0.05, height = 3.2, window = { 0, 0.5 } } },
		{ key = "LAND_DUST", group = "Mișcare", label = "Praf la aterizare (greu)", kind = "PARTICLES", props = {
			texture = "SMOKE_SOFT", color = Color3.fromRGB(176, 164, 148), size = { 1.6, 3.6, 4.8 }, transparency = { 0.45, 0.65, 1 },
			LightEmission = 0, LightInfluence = 1, lifetime = { 0.5, 0.9 }, speed = { 9, 15 }, spread = { 180, 0 }, Drag = 5,
			rotation = { 0, 360 }, rotSpeed = { -40, 40 }, shape = "Disc", partSize = Vector3.new(2.6, 0.1, 2.6),
			acceleration = Vector3.new(0, 1.2, 0), position = Vector3.new(0, 0.25, 0), bursts = { { 0, 26 } } } },
		{ key = "PORTAL_SWIRL", group = "Mișcare", label = "Vârtej de portal (pe sol)", kind = "PARTICLES", props = {
			texture = "SWIRL", Orientation = "VelocityPerpendicular", color = { Color3.fromRGB(140, 100, 255), Color3.fromRGB(90, 210, 255) },
			size = { 2, 13, 14, mid = 0.15 }, transparency = { 1, 0.1, 1, mid = 0.2 }, LightEmission = 1, Brightness = 1.5,
			lifetime = 1.4, speed = 0.01, rotSpeed = 200, LockedToPart = true, position = Vector3.new(0, 0.1, 0), bursts = { { 0, 1 } } } },
		{ key = "PORTAL_STANDING", group = "Mișcare", label = "Portal vertical (în față)", kind = "PARTICLES", props = {
			texture = "SWIRL", Orientation = "VelocityPerpendicular", EmissionDirection = "Front",
			color = { Color3.fromRGB(140, 100, 255), Color3.fromRGB(90, 210, 255) }, size = { 3, 13, 14, mid = 0.2 },
			transparency = { 1, 0.1, 1, mid = 0.2 }, LightEmission = 1, Brightness = 1.5, lifetime = 1.6, speed = 0.01, rotSpeed = 160,
			LockedToPart = true, position = Vector3.new(0, 4, 0), bursts = { { 0, 1 } } } },
		{ key = "COLUMN_STREAKS", group = "Mișcare", label = "Raze verticale (coloană)", kind = "PARTICLES", props = {
			texture = "GLOW", Orientation = "VelocityParallel", squash = -2.6, color = { WHITE, VIOLET }, size = { 0.7, 0.5, 0 },
			transparency = { 0.1, 0.2, 1 }, LightEmission = 1, lifetime = { 0.3, 0.55 }, Rate = 90, speed = { 22, 38 },
			spread = { 2, 2 }, shape = "Cylinder", partSize = Vector3.new(3.2, 0.2, 3.2), ShapeStyle = "Surface",
			window = { 0, 0.5 } } },
		-- fire, impact, fun ------------------------------------------------------------------------------------------
		{ key = "FIREBALL", group = "Foc, fum și praf", label = "Minge de foc (explozie)", kind = "PARTICLES", props = {
			texture = "EXPLOSION", color = { Color3.fromRGB(255, 236, 170), Color3.fromRGB(255, 128, 30), Color3.fromRGB(70, 24, 12), mid = 0.35 },
			size = { 2, 7, 10, mid = 0.35 }, transparency = { 0.1, 0.35, 1, mid = 0.5 }, LightEmission = 0.85,
			lifetime = { 0.4, 0.7 }, speed = { 3, 9 }, spread = { 180, 180 }, Drag = 3, rotation = { 0, 360 },
			rotSpeed = { -60, 60 }, position = Vector3.new(0, 1, 0), bursts = { { 0, 7 } } } },
		{ key = "EMBERS", group = "Foc, fum și praf", label = "Jar care zboară", kind = "PARTICLES", props = {
			texture = "EMBERS", color = { Color3.fromRGB(255, 190, 80), Color3.fromRGB(255, 70, 15) }, size = { 1.1, 1, 0 },
			transparency = { 0.05, 0.1, 1 }, LightEmission = 1, lifetime = { 0.8, 1.6 }, Rate = 26, speed = { 3, 9 },
			spread = { 25, 25 }, acceleration = Vector3.new(0, 5, 0), Drag = 0.4, rotation = { 0, 360 }, rotSpeed = { -60, 60 },
			shape = "Disc", partSize = Vector3.new(2.2, 0.1, 2.2), position = Vector3.new(0, 0.2, 0), window = { 0, 1 } } },
		{ key = "FIRE_LIGHT", group = "Lumini", label = "Lumină de foc (se stinge)", kind = "LIGHT", props = {
			Color = Color3.fromRGB(255, 150, 60), keys = { { 0, 0, 10 }, { 0.05, 6, 22 }, { 0.25, 3.5, 18 }, { 0.6, 1.5, 14 }, { 1, 0, 10 } },
			position = Vector3.new(0, 2, 0) } },
		{ key = "ELECTRIC_LIGHT", group = "Lumini", label = "Lumină electrică (pâlpâie)", kind = "LIGHT", props = {
			Color = Color3.fromRGB(130, 210, 255), keys = { { 0, 0, 14 }, { 0.03, 8, 20 }, { 0.07, 1, 14 }, { 0.11, 9, 22 },
				{ 0.17, 2, 15 }, { 0.23, 7, 18 }, { 0.4, 0, 12 } }, position = Vector3.new(0, 3, 0) } },
		{ key = "CONFETTI", group = "Sărbătoare", label = "Confetti", kind = "PARTICLES", props = {
			texture = "SQUARE", color = { Color3.fromRGB(255, 92, 170), Color3.fromRGB(255, 225, 90), Color3.fromRGB(90, 200, 255) },
			size = { 0.5, 0.5, 0.45 }, transparency = { 0, 0, 1, mid = 0.8 }, LightEmission = 0.15, LightInfluence = 0.6,
			lifetime = { 1.3, 2.1 }, speed = { 16, 28 }, spread = { 45, 45 }, Drag = 1.8, acceleration = Vector3.new(0, -16, 0),
			rotation = { 0, 360 }, rotSpeed = { -420, 420 }, position = Vector3.new(0, 1, 0), bursts = { { 0, 36 } } } },
		{ key = "COINS_BURST", group = "Sărbătoare", label = "Monede (explozie 3D)", kind = "MESH", props = {
			mode = "Debris", shape = "Cylinder", material = "Neon", color = Color3.fromRGB(255, 205, 50),
			colorEnd = Color3.fromRGB(255, 160, 20), size = Vector3.new(0.12, 0.8, 0.8), grow = { 1, 0.6 }, transparency = { 0, 1 },
			lifetime = { 1.5, 2.1 }, speed = { 13, 23 }, spread = { 32, 32 }, direction = "Top", spin = 14, jitter = 0.2,
			position = Vector3.new(0, 1, 0), bursts = { { 0, 12 } } } },
		-- shields and auras ------------------------------------------------------------------------------------------
		-- 3D pieces stay where they were spawned (they are anchored), so a shield that must follow a character is made of particles
		{ key = "SHIELD_AURA", group = "Scut și aură", label = "Scut: contur luminos (urmărește)", kind = "PARTICLES", props = {
			texture = "RING_SOFT", color = { Color3.fromRGB(190, 235, 255), Color3.fromRGB(100, 200, 255) }, size = 10.5,
			transparency = { { 0, 1 }, { 0.08, 0.35 }, { 0.85, 0.5 }, { 1, 1 } }, LightEmission = 1, ZOffset = 0.5, lifetime = 2,
			speed = 0, LockedToPart = true, bursts = { { 0, 1 } } } },
		{ key = "SHIELD_GLOW", group = "Scut și aură", label = "Scut: strălucire interioară (urmărește)", kind = "PARTICLES", props = {
			texture = "GLOW", color = { Color3.fromRGB(150, 215, 255), Color3.fromRGB(80, 170, 255) }, size = 8.4,
			transparency = { { 0, 1 }, { 0.08, 0.78 }, { 0.85, 0.86 }, { 1, 1 } }, LightEmission = 0.8, lifetime = 2, speed = 0,
			LockedToPart = true, bursts = { { 0, 1 } } } },
		{ key = "SHIELD_BUBBLE", group = "Scut și aură", label = "Bulă de scut (ForceField)", kind = "MESH", props = {
			mode = "Pulse", shape = "Ball", material = "ForceField", color = Color3.fromRGB(100, 200, 255),
			colorEnd = Color3.fromRGB(60, 130, 255), size = Vector3.new(1, 1, 1), grow = { 6.4, 7.2 }, transparency = { 0.35, 1 },
			lifetime = 1.6, position = Vector3.new(0, 3, 0), bursts = { { 0, 1 } } } },
		-- camera (applied on the client to the local camera, within `radius` studs) --------------------------------------
		{ key = "SHAKE_LIGHT", group = "Cameră", label = "Tremur ușor (lovitură)", kind = "CAMERA", props = {
			shake = 0.6, frequency = 18, shakeTime = 0.25, radius = 50, bursts = { { 0, 1 } } } },
		{ key = "SHAKE_HEAVY", group = "Cameră", label = "Tremur puternic (impact greu)", kind = "CAMERA", props = {
			shake = 2.2, frequency = 14, shakeTime = 0.55, radius = 90, bursts = { { 0, 1 } } } },
		{ key = "RUMBLE", group = "Cameră", label = "Cutremur (continuu)", kind = "CAMERA", props = {
			shake = 0.45, frequency = 10, radius = 80, window = { 0, 1 } } },
		{ key = "FOV_PUNCH", group = "Cameră", label = "Zoom-out rapid (FOV)", kind = "CAMERA", props = {
			fov = 8, fovTime = 0.3, radius = 60, bursts = { { 0, 1 } } } },
		{ key = "FOV_ZOOM_IN", group = "Cameră", label = "Zoom-in rapid (FOV)", kind = "CAMERA", props = {
			fov = -6, fovTime = 0.35, radius = 60, bursts = { { 0, 1 } } } },
		{ key = "WHITE_FLASH", group = "Cameră", label = "Flash alb pe ecran", kind = "CAMERA", props = {
			flash = WHITE, flashAlpha = 0.45, flashTime = 0.2, radius = 80, bursts = { { 0, 1 } } } },
		{ key = "IMPACT_CAMERA", group = "Cameră", label = "Impact (tremur + zoom)", kind = "CAMERA", props = {
			shake = 1.2, frequency = 16, shakeTime = 0.3, fov = 5, fovTime = 0.25, radius = 60, bursts = { { 0, 1 } } } },
		-- sounds (built into every Roblox client; pitch = random range per play) ---------------------------------------
		{ key = "SOUND_HIT", group = "Sunet", label = "Lovitură (bufnitură)", kind = "SOUND", props = {
			soundId = "HIT", Volume = 0.8, pitch = { 0.85, 1.05 }, RollOffMaxDistance = 120, bursts = { { 0, 1 } } } },
		{ key = "SOUND_HEAVY", group = "Sunet", label = "Lovitură grea (bufnitură joasă)", kind = "SOUND", props = {
			soundId = "HIT", Volume = 1, pitch = { 0.5, 0.6 }, RollOffMaxDistance = 180, bursts = { { 0, 2 } } } },
		{ key = "SOUND_WHOOSH", group = "Sunet", label = "Whoosh (vânt scurt)", kind = "SOUND", props = {
			soundId = "WIND", Volume = 0.6, pitch = { 1.5, 1.8 }, fade = 0.12, RollOffMaxDistance = 80, window = { 0, 0.3 } } },
		{ key = "SOUND_EXPLOSION", group = "Sunet", label = "Explozie", kind = "SOUND", props = {
			soundId = "EXPLOSION", Volume = 0.9, pitch = { 0.9, 1.1 }, RollOffMaxDistance = 250, bursts = { { 0, 1 } } } },
		{ key = "SOUND_THUNDER", group = "Sunet", label = "Tunet (explozie joasă)", kind = "SOUND", props = {
			soundId = "EXPLOSION", Volume = 1, pitch = { 0.55, 0.7 }, RollOffMaxDistance = 400, bursts = { { 0, 1 } } } },
		{ key = "SOUND_JUMP", group = "Sunet", label = "Săritură", kind = "SOUND", props = {
			soundId = "JUMP", Volume = 0.7, pitch = { 0.95, 1.1 }, RollOffMaxDistance = 80, bursts = { { 0, 1 } } } },
		{ key = "SOUND_SPLASH", group = "Sunet", label = "Plescăit în apă", kind = "SOUND", props = {
			soundId = "SPLASH", Volume = 0.8, pitch = { 0.9, 1.1 }, RollOffMaxDistance = 120, bursts = { { 0, 1 } } } },
		-- the client has no "magic" sound: three quick high ticks read as a sparkle (or paste your own sound id)
		{ key = "SOUND_SPARKLE", group = "Sunet", label = "Sclipire (tic-uri acute)", kind = "SOUND", props = {
			soundId = "TICK", Volume = 0.5, pitch = { 1.6, 2 }, RollOffMaxDistance = 60,
			bursts = { { 0, 1 }, { 0.08, 1 }, { 0.16, 1 } } } },
		-- beams (between two points of the effect: start / finish) ----------------------------------------------------
		{ key = "LIGHTNING_BEAM", group = "Raze (Beam)", label = "Fulger (rază care se schimbă)", kind = "BEAM", props = {
			texture = "NONE", start = Vector3.new(0, 30, 0), finish = Vector3.new(0, 0, 0), width = { 0.6, 0.3 }, Segments = 16,
			color = { WHITE, ELECTRIC }, transparency = 0, LightEmission = 1, Brightness = 3, FaceCamera = true, jitter = 2.5,
			flashTime = 0.09, bursts = { { 0, 1 }, { 0.07, 1 }, { 0.15, 1 } } } },
		{ key = "LASER", group = "Raze (Beam)", label = "Laser", kind = "BEAM", props = {
			texture = "NONE", start = Vector3.new(0, 1.5, 0), finish = Vector3.new(0, 1.5, -20), width = { 0.35, 0.35 }, Segments = 1,
			color = { Color3.fromRGB(255, 235, 235), Color3.fromRGB(255, 50, 60) }, transparency = { 0, 0, 0.2 },
			LightEmission = 1, Brightness = 2, FaceCamera = true, fade = 0.06, window = { 0, 0.6 } } },
		{ key = "ENERGY_BEAM", group = "Raze (Beam)", label = "Rază de energie (curge)", kind = "BEAM", props = {
			texture = "SPARKLES", TextureMode = "Wrap", TextureLength = 2, TextureSpeed = 3, start = Vector3.new(0, 2, 0),
			finish = Vector3.new(0, 2, -18), width = { 1.6, 1.2 }, Segments = 10, color = { WHITE, VIOLET },
			transparency = { 0.1, 0.2, 0.5 }, LightEmission = 1, Brightness = 2, FaceCamera = true, fade = 0.12, window = { 0, 0.8 } } },
		{ key = "ELECTRIC_ARC_BEAM", group = "Raze (Beam)", label = "Arc electric (pâlpâie)", kind = "BEAM", props = {
			texture = "NONE", start = Vector3.new(-2, 2, 0), finish = Vector3.new(2, 2, 0), width = { 0.25, 0.25 }, Segments = 12,
			color = { WHITE, ELECTRIC }, transparency = 0, LightEmission = 1, Brightness = 2.5, FaceCamera = true, jitter = 0.8,
			flashTime = 0.07, bursts = { { 0, 1 }, { 0.06, 1 }, { 0.12, 1 }, { 0.2, 1 }, { 0.3, 1 } } } },
	}
	local GROUPS = {
		SPARKLES = "Magie și energie", RISING = "Magie și energie", MAGIC_CIRCLE = "Magie și energie", STAR_FLASH = "Magie și energie",
		IMPLOSION = "Magie și energie", MOTES = "Magie și energie", MAGIC_TRAIL = "Magie și energie",
		SHOCKWAVE = "Impact", FLASH = "Impact", STREAKS = "Impact", RING3D = "Impact", DOME3D = "Impact",
		SMOKE = "Foc, fum și praf", DUST = "Foc, fum și praf", FIRE = "Foc, fum și praf", PUFF3D = "Foc, fum și praf",
		CRACK3D = "Sol (urme și pietre)", GROOVE3D = "Sol (urme și pietre)", SCAR3D = "Sol (urme și pietre)",
		DEBRIS3D = "Sol (urme și pietre)", GROUND_RIBBON = "Sol (urme și pietre)", GROUND_SCORCH = "Sol (urme și pietre)",
		GROUND_CORE = "Sol (urme și pietre)", FLASH_LIGHT = "Lumini", GLOW_LIGHT = "Lumini",
	}
	for _, p in Editor.PRESETS do
		p.group = p.group or GROUPS[p.key]
	end
	for _, p in more do
		table.insert(Editor.PRESETS, p)
	end
end

local PRESET_BY_KEY = {}
for _, p in Editor.PRESETS do
	PRESET_BY_KEY[p.key] = p
end

-- ---------------------------------------------------------------------------------------------
-- templates: complete multi-element effects (Editor.newFromTemplate builds one in a single undo step)
--   { key, label, category, desc, duration, attach, main = the template's hero colour (what a recolour replaces),
--     elements = { { preset = KEY, props = { overrides of the preset: name, position, bursts, window... } } } }
-- Times are seconds from the start of the effect; `window = false` switches the preset's continuous emission off.
-- ---------------------------------------------------------------------------------------------
Editor.TEMPLATES = {}
do
	local C = Color3.fromRGB
	local V = Vector3.new
	local function el(preset, props)
		return { preset = preset, props = props or {} }
	end
	local HIT = V(0, 0.4, -1.1) -- in front of the chest of a target (attach TORSO)

	local list = {
		{ key = "PUNCH", label = "Lovitură de pumn", category = "Luptă", duration = 0.5, attach = "TORSO", main = C(255, 176, 80),
			desc = "Impact scurt pe trunchiul țintei: flash, stea, scântei, undă, puțin fum, o bufnitură și un tremur scurt al camerei. Pune-l pe un marker de animație.",
			elements = {
				el("FLASH", { name = "Flash", color = { C(255, 242, 214), C(255, 160, 70) }, size = { 2, 6, 7, mid = 0.3 }, lifetime = 0.18,
					position = HIT }),
				el("STAR_FLASH", { name = "Stea impact", color = { WHITE, C(255, 190, 90) }, size = { 1, 11, 3, mid = 0.3 }, lifetime = 0.2,
					position = HIT }),
				el("HIT_SPARK", { name = "Scântei", position = HIT }),
				el("AIR_RING", { name = "Undă impact", EmissionDirection = "Front", color = { WHITE, C(255, 200, 140) },
					size = { 1, 5, 8, mid = 0.5 }, lifetime = 0.28, speed = { 3, 5 }, position = HIT }),
				el("SMOKE", { name = "Fum mic", color = { C(120, 108, 100), C(52, 46, 44) }, size = { 0.8, 2, 3 }, lifetime = { 0.35, 0.6 },
					speed = { 2, 5 }, bursts = { { 0.02, 5 } }, position = HIT }),
				el("FLASH_LIGHT", { name = "Lumină impact", Color = C(255, 170, 80), position = V(0, 0.5, -1.4),
					keys = { { 0, 0, 10 }, { 0.03, 5, 14 }, { 0.2, 0, 8 } } }),
				el("SOUND_HIT", { name = "Sunet lovitură", position = HIT }),
				el("SHAKE_LIGHT", { name = "Tremur cameră" }),
			} },
		{ key = "SLASH", label = "Tăietură de sabie", category = "Luptă", duration = 0.6, attach = "TORSO", main = C(150, 210, 255),
			desc = "Două tăieturi încrucișate pe țintă, cu scântei, o sclipire și un whoosh. Pentru dâra din mâna atacatorului vezi „Dâră de sabie”.",
			elements = {
				el("SLASH_MARK", { name = "Tăietură 1", rotation = { -20, -10 }, position = HIT }),
				el("SLASH_MARK", { name = "Tăietură 2", rotation = { 70, 80 }, size = { 3, 9, 10, mid = 0.18 }, position = HIT,
					bursts = { { 0.08, 1 } } }),
				el("HIT_SPARK", { name = "Scântei 1", position = HIT, bursts = { { 0.02, 10 } } }),
				el("HIT_SPARK", { name = "Scântei 2", position = HIT, bursts = { { 0.1, 8 } } }),
				el("STAR_FLASH", { name = "Sclipire", color = { WHITE, C(150, 210, 255) }, size = { 1, 9, 2, mid = 0.3 }, lifetime = 0.18,
					position = HIT, bursts = { { 0.02, 1 } } }),
				el("FLASH_LIGHT", { name = "Lumină", Color = C(150, 210, 255), position = V(0, 0.5, -1.4),
					keys = { { 0, 0, 10 }, { 0.03, 4, 14 }, { 0.12, 0, 8 }, { 0.14, 4, 14 }, { 0.3, 0, 8 } } }),
				el("SOUND_WHOOSH", { name = "Whoosh", window = { 0, 0.22 }, position = HIT }),
			} },
		{ key = "SWORD_TRAIL", label = "Dâră de sabie", category = "Luptă", duration = 0.7, attach = "RIGHT_HAND", main = C(150, 210, 255),
			desc = "Dâră luminoasă prinsă de mâna dreaptă: se vede cât timp mâna se mișcă (pune-o pe animația loviturii). Mută „Poziție” pe lamă.",
			elements = {
				el("SLASH_TRAIL", { name = "Dâră lamă", height = 4.5, window = { 0, 0.55 } }),
				el("SLASH_TRAIL", { name = "Miez alb", color = WHITE, lifetime = 0.12, height = 4.5, window = { 0, 0.55 } }),
				el("MOTES", { name = "Sclipiri", color = { WHITE, C(150, 210, 255) }, size = { 0, 0.4, 0 }, Rate = 40, speed = { 0.5, 2 },
					lifetime = { 0.3, 0.6 }, shape = "Box", partSize = V(0.6, 4, 0.6), window = { 0, 0.55 } }),
			} },
		{ key = "GROUND_SLAM", label = "Ground Slam", category = "Luptă", duration = 1.1, attach = "GROUND", main = C(255, 150, 60),
			desc = "Lovitură în sol: undă, inel 3D, crăpături, pietre, praf, raze, un dom de energie, o bufnitură grea și camera care tremură.",
			elements = {
				el("SHOCKWAVE", { name = "Undă pe sol", color = { WHITE, C(255, 160, 70) } }),
				el("RING3D", { name = "Inel 3D", color = C(255, 170, 70), colorEnd = C(150, 60, 20) }),
				el("CRACK3D", { name = "Crăpături", count = 9, radius = { 2, 5 } }),
				el("DEBRIS3D", { name = "Pietre", bursts = { { 0, 8 } }, window = { 0, 0.3 } }),
				el("LAND_DUST", { name = "Praf", size = { 2, 4.4, 6 }, bursts = { { 0, 30 } } }),
				el("STREAKS", { name = "Raze", color = { WHITE, C(255, 160, 70) } }),
				el("FLASH", { name = "Flash", color = { C(255, 240, 210), C(255, 150, 60) }, size = { 2, 9, 10, mid = 0.3 },
					position = V(0, 1, 0) }),
				el("DOME3D", { name = "Dom de energie", color = C(255, 150, 50), colorEnd = C(120, 40, 10), grow = { 1.5, 9 },
					transparency = { 0.2, 1 }, lifetime = 0.3 }),
				el("FLASH_LIGHT", { name = "Lumină", Color = C(255, 160, 70), keys = { { 0, 0, 12 }, { 0.04, 6, 18 }, { 0.4, 0, 12 } } }),
				el("SOUND_HEAVY", { name = "Bufnitură grea" }),
				el("SHAKE_HEAVY", { name = "Cameră (tremur + zoom)", fov = 5, fovTime = 0.3 }),
			} },
		{ key = "LIGHTNING", label = "Fulger", category = "Elemente", duration = 1, attach = "GROUND", main = C(125, 210, 255),
			desc = "Trăznet care lovește solul: fulgere în stroboscop (și o rază din cer), arcuri, scântei, undă, fum, lumină electrică, tunet și un flash pe ecran.",
			elements = {
				el("LIGHTNING_BOLT", { name = "Trăznet", bursts = { { 0, 1 }, { 0.07, 1 }, { 0.15, 1 }, { 0.3, 1 } } }),
				el("FLASH", { name = "Flash cer", color = { WHITE, C(140, 215, 255) }, size = { 4, 16, 20, mid = 0.3 }, lifetime = 0.25,
					position = V(0, 3, 0), bursts = { { 0, 1 }, { 0.15, 1 } } }),
				el("ELECTRIC_ARC", { name = "Arcuri", position = V(0, 0.8, 0), bursts = { { 0, 3 }, { 0.07, 3 }, { 0.14, 2 }, { 0.28, 3 } } }),
				el("ELECTRIC_SPARKS", { name = "Scântei", position = V(0, 0.5, 0), bursts = { { 0, 18 } } }),
				el("SHOCKWAVE", { name = "Undă", color = { WHITE, C(140, 215, 255) }, size = { 1, 6, 9, mid = 0.45 }, lifetime = 0.35 }),
				el("SMOKE", { name = "Fum", color = { C(90, 90, 100), C(40, 40, 50) }, size = { 1, 2.6, 4 }, speed = { 1, 3 },
					bursts = { { 0.05, 6 } }, position = V(0, 0.3, 0) }),
				el("CRACK3D", { name = "Urmă arsă", count = 6, radius = { 1, 2.4 } }),
				el("ELECTRIC_LIGHT", { name = "Lumină" }),
				el("LIGHTNING_BEAM", { name = "Rază din cer", bursts = { { 0, 1 }, { 0.07, 1 }, { 0.15, 1 }, { 0.3, 1 } } }),
				el("SOUND_THUNDER", { name = "Tunet" }),
				el("SHAKE_LIGHT", { name = "Cameră (tremur + flash)", shake = 1, flash = WHITE, flashAlpha = 0.4, flashTime = 0.18,
					radius = 80, bursts = { { 0, 1 }, { 0.3, 1 } } }),
			} },
		{ key = "FIRE_EXPLOSION", label = "Explozie de foc", category = "Elemente", duration = 1.3, attach = "GROUND", main = C(255, 140, 40),
			desc = "Minge de foc cu flash, undă, jar, fum negru, pietre, dom de foc, lumină care se stinge, bubuitură și camera care tremură.",
			elements = {
				el("FIREBALL", { name = "Minge de foc", bursts = { { 0, 7 }, { 0.08, 5 } } }),
				el("FLASH", { name = "Flash", color = { C(255, 245, 215), C(255, 160, 60) }, size = { 3, 12, 14, mid = 0.3 },
					position = V(0, 1.5, 0) }),
				el("SHOCKWAVE", { name = "Undă", color = { WHITE, C(255, 150, 60) }, size = { 1, 11, 16, mid = 0.45 } }),
				el("EMBERS", { name = "Jar", window = false, speed = { 8, 20 }, spread = { 70, 70 }, acceleration = V(0, -6, 0),
					position = V(0, 1, 0), bursts = { { 0, 26 } } }),
				el("SMOKE", { name = "Fum negru", color = { C(80, 70, 66), C(26, 24, 24) }, size = { 3, 6, 9 }, transparency = { 0.3, 0.5, 1 },
					lifetime = { 1.1, 1.7 }, speed = { 2, 6 }, acceleration = V(0, 2.5, 0), LightEmission = 0, position = V(0, 1.5, 0),
					bursts = { { 0.1, 9 } } }),
				el("DEBRIS3D", { name = "Pietre", bursts = { { 0, 10 } }, window = { 0, 0.2 } }),
				el("DOME3D", { name = "Dom de foc", color = C(255, 150, 50), colorEnd = C(140, 50, 10), grow = { 1.5, 10 },
					transparency = { 0.25, 1 }, lifetime = 0.35 }),
				el("FIRE_LIGHT", { name = "Lumină" }),
				el("SOUND_EXPLOSION", { name = "Bubuitură" }),
				el("SHAKE_HEAVY", { name = "Cameră (tremur + flash)", flash = C(255, 190, 120), flashAlpha = 0.35, flashTime = 0.25 }),
			} },
		{ key = "HEAL", label = "Vindecare", category = "Suport", duration = 1.8, attach = "GROUND_FOLLOW", main = C(110, 255, 150),
			desc = "Cerc pe sol, inele care urcă, sclipiri verzi și o lumină blândă. Urmărește personajul.",
			elements = {
				el("MAGIC_CIRCLE", { name = "Cerc", color = C(110, 255, 150), size = { 3, 5.5, 5.8, mid = 0.25 }, lifetime = 1.2 }),
				el("HEAL_RING", { LockedToPart = true, name = "Inel care urcă", bursts = { { 0.1, 1 }, { 0.5, 1 }, { 0.9, 1 } } }),
				el("HEAL_MOTES", { LockedToPart = true, name = "Sclipiri", window = { 0, 1.4 } }),
				el("FLASH", { LockedToPart = true, name = "Strălucire", color = { C(220, 255, 230), C(110, 255, 150) }, size = { 2, 5, 6, mid = 0.3 },
					transparency = { 0.5, 0.7, 1, mid = 0.3 }, lifetime = 0.5, position = V(0, 1.5, 0), bursts = { { 0.05, 1 } } }),
				el("HEAL_LIGHT", { name = "Lumină" }),
			} },
		{ key = "TELEPORT", label = "Teleport", category = "Mișcare", duration = 1.4, attach = "GROUND", main = C(158, 92, 255),
			desc = "Cerc magic și vârtej, raze care urcă, apoi implozie, flash și explozie de scântei în momentul plecării.",
			elements = {
				el("MAGIC_CIRCLE", { name = "Cerc magic", lifetime = 1.2 }),
				el("PORTAL_SWIRL", { name = "Vârtej", bursts = { { 0.05, 1 } } }),
				el("COLUMN_STREAKS", { name = "Raze", window = { 0.15, 0.8 } }),
				el("IMPLOSION", { name = "Implozie", position = V(0, 2, 0), bursts = { { 0.6, 1 } } }),
				el("FLASH", { name = "Flash", size = { 2, 9, 10, mid = 0.3 }, position = V(0, 2.5, 0), bursts = { { 0.75, 1 } } }),
				el("STAR_FLASH", { name = "Stea", position = V(0, 2.5, 0), bursts = { { 0.75, 1 } } }),
				el("SHOCKWAVE", { name = "Undă", bursts = { { 0.75, 1 } } }),
				el("SPARKLES", { name = "Scântei", position = V(0, 2.5, 0), bursts = { { 0.75, 26 } } }),
				el("FLASH_LIGHT", { name = "Lumină", position = V(0, 2, 0),
					keys = { { 0, 0, 8 }, { 0.3, 3, 14 }, { 0.7, 4, 16 }, { 0.78, 8, 20 }, { 1.1, 0, 10 } } }),
				el("FOV_PUNCH", { name = "Zoom la plecare", bursts = { { 0.75, 1 } } }),
			} },
		{ key = "DASH", label = "Dash", category = "Mișcare", duration = 0.6, attach = "ROOT", main = C(190, 230, 255),
			desc = "Linii de viteză și vânt în spate, un inel de aer la start, dâră și praf la picioare. Pune-l pe personaj, în direcția mișcării.",
			elements = {
				el("SPEED_LINES", { name = "Linii de viteză", window = { 0, 0.45 } }),
				el("AIR_RING", { name = "Inel de aer" }),
				el("DASH_WIND", { name = "Vânt" }),
				el("DASH_TRAIL", { name = "Dâră" }),
				el("LAND_DUST", { name = "Praf la picioare", size = { 1, 2.4, 3.2 }, position = V(0, -2.9, 0), bursts = { { 0, 14 } } }),
				el("SOUND_WHOOSH", { name = "Whoosh" }),
			} },
		{ key = "POWER_AURA", label = "Aură de putere (loop)", category = "Suport", duration = 3, attach = "GROUND_FOLLOW", main = C(255, 190, 60),
			desc = "Aură continuă de 3 s: raze, flăcări, scântei și un puls pe sol în fiecare secundă. În joc o repeți din cod (VFX.play la fiecare ~2,8 s); aici, cu 🔁 Repetă.",
			elements = {
				el("COLUMN_STREAKS", { name = "Raze aură", Rate = 55, speed = { 5, 10 }, lifetime = { 0.4, 0.8 }, partSize = V(3.6, 0.2, 3.6),
					size = { 0.6, 0.5, 0 }, color = { WHITE, C(255, 190, 60) }, LockedToPart = true, window = { 0, 3 } }),
				el("FIRE", { name = "Flăcări", color = { C(255, 190, 70), C(255, 90, 20) }, size = { 1.8, 1.4, 0.5 }, transparency = { 0.35, 0.4, 1 },
					lifetime = { 0.5, 0.9 }, speed = { 3, 6 }, acceleration = V(0, 7, 0), shape = "Cylinder", partSize = V(3, 0.2, 3),
					ShapeStyle = "Surface", LockedToPart = true, window = { 0, 3 } }),
				el("RISING", { name = "Scântei", color = { WHITE, C(255, 190, 60) }, partSize = V(3.6, 0.3, 3.6), LockedToPart = true,
					window = { 0, 3 } }),
				el("SHOCKWAVE", { name = "Puls pe sol", color = { WHITE, C(255, 190, 60) }, size = { 2, 9, 11, mid = 0.45 }, lifetime = 0.9,
					bursts = { { 0, 1 }, { 1, 1 }, { 2, 1 } } }),
				el("GLOW_LIGHT", { name = "Lumină", Color = C(255, 190, 60), Brightness = 2, Range = 14, position = V(0, 3, 0) }),
			} },
		{ key = "SHIELD", label = "Scut", category = "Suport", duration = 2.2, attach = "ROOT", main = C(90, 190, 255),
			desc = "Bulă de energie în jurul personajului (conturul și strălucirea urmăresc personajul), cu o apariție bruscă, scântei și o undă pe sol.",
			elements = {
				el("SHIELD_AURA", { name = "Contur scut", lifetime = 2.2 }),
				el("SHIELD_GLOW", { name = "Strălucire scut", lifetime = 2.2 }),
				el("SHIELD_BUBBLE", { name = "Bulă la activare", position = V(0, 0, 0), grow = { 5, 7.6 }, lifetime = 0.5 }),
				el("SPARKLES", { name = "Scântei", color = { WHITE, C(100, 200, 255) }, position = V(0, 0, 0), speed = { 8, 16 },
					bursts = { { 0, 24 } } }),
				el("SHOCKWAVE", { name = "Undă pe sol", color = { WHITE, C(100, 200, 255) }, position = V(0, -2.9, 0), size = { 1, 7, 10, mid = 0.45 } }),
				el("GLOW_LIGHT", { name = "Lumină", Color = C(90, 190, 255), position = V(0, 0, 0),
					keys = { { 0, 0, 8 }, { 0.2, 3, 18 }, { 1.8, 2, 16 }, { 2.2, 0, 10 } } }),
			} },
		{ key = "FREEZE", label = "Înghețare", category = "Elemente", duration = 2, attach = "GROUND", main = C(140, 215, 255),
			desc = "Crăpături și cioburi de gheață, ceață rece, cristale care sclipesc și fulgi care cad.",
			elements = {
				el("ICE_CRACKS", { name = "Crăpături de gheață" }),
				el("ICE_SHARDS", { name = "Cioburi", bursts = { { 0, 10 }, { 0.1, 7 } } }),
				el("FROST_MIST", { name = "Ceață rece", window = { 0, 1 } }),
				el("FROST_SPARKLE", { name = "Cristale", window = { 0, 1.6 } }),
				el("SNOWFALL", { name = "Fulgi", window = { 0, 1.6 } }),
				el("SHOCKWAVE", { name = "Undă", color = { WHITE, C(140, 215, 255) }, size = { 1, 8, 12, mid = 0.45 }, lifetime = 0.45 }),
				el("FLASH", { name = "Flash", color = { WHITE, C(140, 215, 255) }, size = { 2, 8, 9, mid = 0.3 }, position = V(0, 1.5, 0) }),
				el("ICE_LIGHT", { name = "Lumină" }),
			} },
		{ key = "POISON", label = "Otrăvire", category = "Elemente", duration = 2.2, attach = "GROUND_FOLLOW", main = C(120, 230, 70),
			desc = "Nor toxic și bule care urcă din sol, aburi, picături care cad și o lumină verzuie.",
			elements = {
				el("POISON_CLOUD", { LockedToPart = true, name = "Nor toxic", window = { 0, 1.8 } }),
				el("POISON_BUBBLES", { LockedToPart = true, name = "Bule", window = { 0, 2 } }),
				el("DARK_WISPS", { LockedToPart = true, name = "Aburi", color = { C(150, 240, 90), C(40, 90, 30) }, window = { 0, 1.8 } }),
				el("WATER_DROPS3D", { name = "Picături toxice", color = C(140, 230, 80), bursts = { { 0.1, 8 }, { 0.7, 6 } } }),
				el("SHOCKWAVE", { name = "Undă toxică", color = { C(190, 255, 130), C(90, 190, 60) }, size = { 1, 7, 10, mid = 0.45 }, lifetime = 0.5 }),
				el("GLOW_LIGHT", { name = "Lumină", Color = C(120, 230, 70), Brightness = 1.5, Range = 12, position = V(0, 2, 0),
					keys = { { 0, 0, 8 }, { 0.3, 2, 14 }, { 1.9, 2, 14 }, { 2.2, 0, 8 } } }),
			} },
		{ key = "LEVEL_UP", label = "Level Up", category = "Evenimente", duration = 2.2, attach = "GROUND_FOLLOW", main = C(255, 215, 90),
			desc = "Coloană de lumină aurie, cerc magic, raze și sclipiri care urcă, un flare mare și scântei.",
			elements = {
				el("HOLY_PILLAR", { name = "Coloană de lumină" }),
				el("MAGIC_CIRCLE", { name = "Cerc magic", color = C(255, 215, 90), size = { 3, 6.5, 6.8, mid = 0.25 }, lifetime = 1.4 }),
				el("COLUMN_STREAKS", { LockedToPart = true, name = "Raze", color = { WHITE, C(255, 215, 90) }, window = { 0.1, 1 } }),
				el("HEAL_MOTES", { LockedToPart = true, name = "Sclipiri aurii", color = { C(255, 250, 222), C(255, 214, 92) }, window = { 0.1, 1.8 } }),
				el("HOLY_FLARE", { LockedToPart = true, name = "Flare", position = V(0, 3, 0), bursts = { { 0.15, 1 } } }),
				el("RING3D", { name = "Inel 3D", color = C(255, 214, 92), colorEnd = C(255, 160, 40), radius = { 1, 8 }, lifetime = 0.6 }),
				el("SPARKLES", { LockedToPart = true, name = "Scântei", color = { WHITE, C(255, 214, 92) }, position = V(0, 2.5, 0), bursts = { { 0.2, 30 } } }),
				el("HOLY_LIGHT", { name = "Lumină" }),
			} },
		{ key = "LANDING", label = "Aterizare", category = "Mișcare", duration = 0.7, attach = "GROUND", main = C(190, 180, 160),
			desc = "Praf, o undă mică, crăpături fine, pietricele și bile de fum la aterizare.",
			elements = {
				el("LAND_DUST", { name = "Praf" }),
				el("SHOCKWAVE", { name = "Undă mică", color = { C(235, 230, 220), C(190, 180, 160) }, size = { 1, 6, 9, mid = 0.45 },
					transparency = { 0.4, 0.55, 1, mid = 0.45 }, lifetime = 0.35 }),
				el("CRACK3D", { name = "Crăpături mici", count = 6, radius = { 1, 2.2 } }),
				el("DEBRIS3D", { name = "Pietricele", size = V(0.2, 0.18, 0.2), speed = { 5, 10 }, bursts = { { 0, 5 } }, window = { 0, 0.1 } }),
				el("PUFF3D", { name = "Bile de praf", bursts = { { 0, 6 } } }),
				el("SOUND_HIT", { name = "Bufnitură", pitch = { 0.7, 0.8 } }),
				el("SHAKE_LIGHT", { name = "Tremur mic", shake = 0.35, radius = 30 }),
			} },
		{ key = "WATER_SPLASH", label = "Splash de apă", category = "Elemente", duration = 1.2, attach = "GROUND", main = C(120, 190, 255),
			desc = "Ondulații, stropi denși, picături fine și picături 3D care cad cu fizică, plus puțină ceață.",
			elements = {
				el("WATER_RING", { name = "Ondulații", bursts = { { 0, 1 }, { 0.2, 1 } } }),
				el("WATER_SPLASH", { name = "Stropi", bursts = { { 0, 4 }, { 0.08, 3 } } }),
				el("WATER_DROPLETS", { name = "Picături", bursts = { { 0, 6 }, { 0.1, 5 } } }),
				el("WATER_DROPS3D", { name = "Picături 3D" }),
				el("FROST_MIST", { name = "Ceață de stropi", color = { C(235, 246, 255), C(190, 225, 255) }, partSize = V(2.5, 0.2, 2.5),
					lifetime = { 0.6, 1 }, window = { 0, 0.5 } }),
				el("SOUND_SPLASH", { name = "Plescăit" }),
			} },
		{ key = "COINS", label = "Monede (recompensă)", category = "Evenimente", duration = 1.8, attach = "GROUND_FOLLOW", main = C(255, 205, 50),
			desc = "Monede aurii aruncate în sus, cu o stea, scântei și o lumină caldă.",
			elements = {
				el("COINS_BURST", { name = "Monede", bursts = { { 0, 14 }, { 0.25, 10 } } }),
				el("STAR_FLASH", { LockedToPart = true, name = "Stea", color = { WHITE, C(255, 205, 50) }, position = V(0, 3, 0) }),
				el("SPARKLES", { LockedToPart = true, name = "Scântei", color = { WHITE, C(255, 205, 50) }, position = V(0, 3, 0), bursts = { { 0, 24 } } }),
				el("HOLY_LIGHT", { name = "Lumină", Color = C(255, 205, 50), position = V(0, 3, 0),
					keys = { { 0, 0, 10 }, { 0.15, 3, 18 }, { 1.2, 0, 12 } } }),
			} },
		{ key = "CONFETTI", label = "Confetti", category = "Evenimente", duration = 2.2, attach = "GROUND", main = C(255, 92, 170),
			desc = "Trei culori de confetti aruncate în două valuri, cu o stea și scântei de sărbătoare.",
			elements = {
				el("CONFETTI", { name = "Confetti roz", color = C(255, 92, 170), bursts = { { 0, 30 }, { 0.4, 24 } } }),
				el("CONFETTI", { name = "Confetti galben", color = C(255, 225, 90), bursts = { { 0, 30 }, { 0.4, 24 } } }),
				el("CONFETTI", { name = "Confetti albastru", color = C(90, 200, 255), bursts = { { 0, 30 }, { 0.4, 24 } } }),
				el("STAR_FLASH", { name = "Stea", color = { WHITE, C(255, 225, 90) }, position = V(0, 2, 0) }),
				el("SPARKLES", { name = "Scântei", color = { WHITE, C(255, 225, 90) }, position = V(0, 2, 0), bursts = { { 0, 24 } } }),
			} },
		{ key = "DARK_ENERGY", label = "Energie întunecată", category = "Elemente", duration = 2.4, attach = "GROUND_FOLLOW", main = C(150, 70, 225),
			desc = "Fum și aburi violet care urcă, un vârtej negru pe sol, o undă și o lumină slabă.",
			elements = {
				el("DARK_SMOKE", { LockedToPart = true, name = "Fum", window = { 0, 2 } }),
				el("DARK_WISPS", { LockedToPart = true, name = "Aburi", window = { 0, 2 } }),
				el("PORTAL_SWIRL", { name = "Vârtej negru", color = { C(120, 50, 200), C(30, 10, 60) }, bursts = { { 0, 1 }, { 1, 1 } } }),
				el("SHOCKWAVE", { name = "Undă", color = { C(190, 120, 255), C(70, 20, 140) }, size = { 1, 8, 12, mid = 0.45 }, lifetime = 0.5 }),
				el("GLOW_LIGHT", { name = "Lumină", Color = C(150, 70, 225), Brightness = 1.5, Range = 14, position = V(0, 2, 0),
					keys = { { 0, 0, 8 }, { 0.4, 2, 14 }, { 2, 2, 14 }, { 2.4, 0, 8 } } }),
			} },
		{ key = "HOLY_RAY", label = "Rază sfântă", category = "Suport", duration = 1.8, attach = "GROUND", main = C(255, 225, 140),
			desc = "Coloană de lumină, flare mare, sclipiri aurii care urcă și un cerc pe sol.",
			elements = {
				el("HOLY_PILLAR", { name = "Coloană de lumină", lifetime = 1.4, color = C(255, 240, 190) }),
				el("HOLY_FLARE", { name = "Flare", position = V(0, 3, 0), bursts = { { 0.1, 1 } } }),
				el("HEAL_MOTES", { name = "Sclipiri aurii", color = { C(255, 250, 222), C(255, 214, 92) }, window = { 0, 1.4 } }),
				el("MAGIC_CIRCLE", { name = "Cerc", color = C(255, 225, 140), lifetime = 1.4 }),
				el("HOLY_LIGHT", { name = "Lumină" }),
			} },
		{ key = "PORTAL", label = "Portal", category = "Mișcare", duration = 3, attach = "GROUND", main = C(120, 110, 255),
			desc = "Portal vertical care se rotește în fața efectului, cu cerc pe sol, sclipiri și lumină. Durează 3 s; repetă-l din cod sau cu 🔁 Repetă.",
			elements = {
				el("PORTAL_STANDING", { name = "Portal", lifetime = 1.8, bursts = { { 0, 1 }, { 1.2, 1 } } }),
				el("PORTAL_STANDING", { name = "Portal (strat 2)", size = { 2, 10, 11, mid = 0.2 }, rotSpeed = -220, lifetime = 1.8,
					bursts = { { 0.1, 1 }, { 1.3, 1 } } }),
				el("MAGIC_CIRCLE", { name = "Cerc pe sol", color = C(120, 110, 255), lifetime = 1.6, bursts = { { 0, 1 }, { 1.4, 1 } } }),
				el("MOTES", { name = "Sclipiri", window = { 0, 3 }, position = V(0, 4, -0.5) }),
				el("GLOW_LIGHT", { name = "Lumină", Color = C(120, 110, 255), position = V(0, 4, -1), Brightness = 2, Range = 16 }),
			} },
	}

	-- a template that names a missing preset would fail half way through: it is left out (and reported) instead
	for _, tpl in list do
		local ok = true
		for _, item in tpl.elements do
			if not PRESET_BY_KEY[item.preset] then
				ok = false
				warn("LostCube: șablonul " .. tpl.key .. " folosește presetul necunoscut " .. tostring(item.preset))
			end
		end
		if ok then
			table.insert(Editor.TEMPLATES, tpl)
		end
	end
end
local TEMPLATE_BY_KEY = {}
for _, tpl in Editor.TEMPLATES do
	TEMPLATE_BY_KEY[tpl.key] = tpl
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

-- a number, { a, b }, NumberRange or Vector2 -> a, b
local function pairOf(v)
	if type(v) == "number" then
		return v, v
	elseif typeof(v) == "NumberRange" then
		return v.Min, v.Max
	elseif typeof(v) == "Vector2" then
		return v.X, v.Y
	end
	return v[1], v[2] or v[1]
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

-- read-only: the panels call it while drawing (outside any undo recording), so it never creates the session folder
function Editor.history()
	local ok, storage = pcall(function()
		return game:GetService("ServerStorage")
	end)
	local folder = ok and storage and storage:FindFirstChild("LostCubeSession")
	if not folder then
		return {}
	end
	local okList, list = pcall(HttpService.JSONDecode, HttpService, folder:GetAttribute("Log") or "[]")
	return okList and list or {}
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
	elseif inst:IsA("Sound") then
		return "SOUND"
	elseif inst:IsA("Beam") then
		return "BEAM"
	elseif inst:IsA("Configuration") and inst:GetAttribute("LC_Kind") == "CAMERA" then
		return "CAMERA"
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
	elseif element:IsA("Beam") then -- its start
		local a = element.Attachment0
		return a and a.Position or Vector3.zero
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
	elseif element:IsA("Beam") then -- both ends move (the beam keeps its length and direction)
		local a, b = trailAttachments(element)
		local delta = pos - (a and a.Position or Vector3.zero)
		if a then
			a.Position += delta
		end
		if b then
			b.Position += delta
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
local FLIPBOOK = { "FlipbookLayout", "FlipbookMode", "FlipbookFramerate", "FlipbookStartRandom", "FlipbookSizeX", "FlipbookSizeY",
	"FlipbookBlendFrames" }

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
		elseif element:IsA("Beam") then
			local a, b = trailAttachments(element)
			if a then
				a.Name = value .. "_Start"
			end
			if b then
				b.Name = value .. "_End"
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
	elseif key == "height" or (key == "width" and not element:IsA("Beam")) then -- trails: the distance between their attachments
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
	elseif key == "soundId" then -- a key of Editor.SOUNDS, an asset id (number) or a url
		local id = SOUND_URL[value] or ((type(value) == "number" or tostring(value):match("^%d+$")) and ("rbxassetid://" .. value)) or value
		element.SoundId = id
	elseif key == "pitch" then -- random PlaybackSpeed range per play
		local a, b = pairOf(value)
		element:SetAttribute("LC_Pitch", string.format("%s,%s", round(math.max(0.01, tonumber(a) or 1)), round(math.max(0.01, tonumber(b) or 1))))
	elseif key == "fade" then
		element:SetAttribute("LC_Fade", value)
	elseif key == "start" or key == "finish" then -- beam ends, relative to the effect's root
		local a, b = trailAttachments(element)
		local att = key == "start" and a or b
		if att then
			att.Position = vec3(value)
		end
	elseif key == "width" then
		local a, b = pairOf(value)
		element.Width0, element.Width1 = a, b
	elseif key == "curve" then
		local a, b = pairOf(value)
		element.CurveSize0, element.CurveSize1 = a, b
	elseif key == "flashTime" then
		element:SetAttribute("LC_FlashTime", value)
	elseif key == "jitter" then
		element:SetAttribute("LC_Jitter", value ~= 0 and value or nil)
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
		local a, b = pairOf(value)
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

-- camera elements (a Configuration) keep everything in attributes; returns true when the key was handled
local CAMERA_ATTR = { shake = "LC_Shake", frequency = "LC_Freq", shakeTime = "LC_ShakeTime", fov = "LC_FOV", fovTime = "LC_FovTime",
	flashAlpha = "LC_FlashAlpha", flashTime = "LC_FlashTime", radius = "LC_Radius" }

local function setCamera(cfg, key, value)
	if CAMERA_ATTR[key] then
		assert(type(value) == "number", "LostCube: " .. key .. " trebuie să fie un număr")
		cfg:SetAttribute(CAMERA_ATTR[key], (value ~= 0 or (key ~= "shake" and key ~= "fov")) and value or nil)
	elseif key == "flash" then -- Color3 (or hex / RGB triplet), false = no flash
		cfg:SetAttribute("LC_Flash", value and toColor(value) or nil)
	elseif key == "studio" then -- false: not applied to the Studio camera in previews
		cfg:SetAttribute("LC_Studio", if value == false then false else nil)
	else
		return false
	end
	return true
end

local ORDER = { "shape", "partSize", "position", "height" } -- shape first (it moves the emitter)

local function applyProps(element, props)
	local kind = Editor.kindOf(element)
	if kind == "MESH" or kind == "CAMERA" then
		local special = kind == "MESH" and setMesh or setCamera
		for key, value in props do
			if not special(element, key, value) then
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
	elseif kind == "SOUND" then -- positional: under an Attachment of the root
		local att = Instance.new("Attachment")
		att.Name = name
		att.Position = Vector3.new(0, 1, 0)
		att.Parent = root
		local snd = Instance.new("Sound")
		snd.Name = name
		snd.SoundId = SOUND_URL.HIT
		snd.Volume = 0.7
		snd.RollOffMinDistance = 8
		snd.RollOffMaxDistance = 120
		snd:SetAttribute("LC_Pitch", "0.95,1.05")
		snd.Parent = att
		return snd
	elseif kind == "CAMERA" then
		local att = Instance.new("Attachment")
		att.Name = name
		att.Parent = root
		local cfg = Instance.new("Configuration")
		cfg.Name = name
		cfg:SetAttribute("LC_Kind", "CAMERA")
		cfg:SetAttribute("LC_Shake", 0.8)
		cfg:SetAttribute("LC_Freq", 16)
		cfg:SetAttribute("LC_ShakeTime", 0.3)
		cfg:SetAttribute("LC_Radius", 60)
		cfg.Parent = att
		return cfg
	elseif kind == "BEAM" then -- from Attachment0 (start) to Attachment1 (end)
		local a = Instance.new("Attachment")
		a.Name = name .. "_Start"
		a.Position = Vector3.new(0, 1.5, 0)
		a.Parent = root
		local b = Instance.new("Attachment")
		b.Name = name .. "_End"
		b.Position = Vector3.new(0, 1.5, -10)
		b.Parent = root
		local beam = Instance.new("Beam")
		beam.Name = name
		beam.Attachment0, beam.Attachment1 = a, b
		beam.Enabled = false
		beam.FaceCamera = true
		beam.LightEmission = 1
		beam.Width0, beam.Width1 = 0.6, 0.6
		beam.Segments = 10
		beam.Color = ColorSequence.new(WHITE, VIOLET)
		beam.Transparency = NumberSequence.new(0.1)
		beam.Parent = root
		return beam
	end
	error("LostCube: tip necunoscut " .. tostring(kind))
end

-- the timeline an element added empty (no preset) starts with
local EMPTY_TIMELINE = { SOUND = { bursts = { { 0, 1 } } }, CAMERA = { bursts = { { 0, 1 } } }, BEAM = { window = { 0, 0.5 } } }
-- attributes a preset replaces besides the timeline (LC_Studio is the user's choice and stays)
local PRESET_RESET = {
	SOUND = { "LC_Pitch", "LC_Fade" },
	BEAM = { "LC_FlashTime", "LC_Fade", "LC_Jitter" },
	CAMERA = { "LC_Shake", "LC_Freq", "LC_ShakeTime", "LC_FOV", "LC_FovTime", "LC_Flash", "LC_FlashAlpha", "LC_FlashTime", "LC_Radius" },
}
local KIND_NAME = { PARTICLES = "Particule", LIGHT = "Lumină", TRAIL = "Trail", MESH = "Mesh 3D", SOUND = "Sunet", CAMERA = "Cameră",
	BEAM = "Rază" }

--- addElement(effect, presetKey | "PARTICLES" | "LIGHT" | "TRAIL", props?) -> the emitter / light / trail
function Editor.addElement(effect, what, props)
	effect = Editor.effect(effect)
	props = props or {}
	local preset = PRESET_BY_KEY[what]
	local kind = preset and preset.kind or what
	return record("adăugat " .. (preset and preset.label or kind) .. " în " .. effect.Name, function()
		local name = uniqueName(effect, props.name or (preset and preset.label) or KIND_NAME[kind] or tostring(kind))
		local element = create(effect, kind, name)
		if preset then
			applyProps(element, preset.props)
			element:SetAttribute("LC_Preset", preset.key)
		elseif EMPTY_TIMELINE[kind] then
			applyProps(element, EMPTY_TIMELINE[kind])
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
		for _, attr in PRESET_RESET[preset.kind] or {} do
			element:SetAttribute(attr, nil)
		end
		applyProps(element, preset.props)
		element:SetAttribute("LC_Preset", preset.key)
		return element
	end)
end

function Editor.remove(element)
	return record("șters " .. element.Name, function()
		local parent = element.Parent
		if element:IsA("Trail") or element:IsA("Beam") then
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
		local kind = Editor.kindOf(element)
		if kind == "MESH" then
			local copy = element:Clone()
			copy.Name = name
			copy.Parent = effect
			return copy
		elseif kind == "SOUND" or kind == "CAMERA" then -- a copy in its own Attachment, at the same place
			local copy = element:Clone()
			copy.Name = name
			local holder = element.Parent
			if holder and holder:IsA("Attachment") then
				local att = Instance.new("Attachment")
				att.Name = name
				att.CFrame = holder.CFrame
				att.Parent = holder.Parent
				copy.Parent = att
			else
				copy.Parent = holder
			end
			return copy
		elseif kind == "BEAM" then -- a copy with its own two ends (a clone would share the original's attachments)
			local copy = element:Clone()
			copy.Name = name
			local function twin(att, suffix)
				if not att then
					return nil
				end
				local a = Instance.new("Attachment")
				a.Name = name .. suffix
				a.CFrame = att.CFrame
				a.Parent = att.Parent
				return a
			end
			local a, b = trailAttachments(element)
			copy.Attachment0, copy.Attachment1 = twin(a, "_Start"), twin(b, "_End")
			copy.Parent = element.Parent
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
			for _, prop in FLIPBOOK do
				pcall(function()
					copy[prop] = element[prop]
				end)
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

local RETIMED = { SOUND = { "LC_Fade" }, BEAM = { "LC_FlashTime", "LC_Fade" }, CAMERA = { "LC_ShakeTime", "LC_FovTime", "LC_FlashTime" } }

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
			else -- sounds / beams / camera: their fades, flashes and shakes
				for _, attr in RETIMED[Editor.kindOf(e)] or {} do
					local v = e:GetAttribute(attr)
					if type(v) == "number" then
						e:SetAttribute(attr, round(v * k))
					end
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
		-- flipbooks (a texture made of 2x2 / 4x4 / 8x8 frames)
		data.FlipbookLayout = e.FlipbookLayout.Name
		data.FlipbookMode = e.FlipbookMode.Name
		data.FlipbookFramerate = { e.FlipbookFramerate.Min, e.FlipbookFramerate.Max }
		data.FlipbookStartRandom = e.FlipbookStartRandom
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
	elseif kind == "SOUND" then
		local snd = element
		data.soundId = snd.SoundId
		data.sound = SOUND_KEY[snd.SoundId] or "CUSTOM"
		data.Volume = snd.Volume
		data.RollOffMaxDistance = snd.RollOffMaxDistance
		data.RollOffMinDistance = snd.RollOffMinDistance
		local p = parseList(snd:GetAttribute("LC_Pitch"))[1]
		data.pitch = { p and p[1] or snd.PlaybackSpeed, p and (p[2] or p[1]) or snd.PlaybackSpeed }
		data.fade = snd:GetAttribute("LC_Fade") or 0.15
		data.length = snd.TimeLength -- 0 until Studio has loaded it
		data.window = Editor.window(snd)
		data.bursts = Editor.bursts(snd)
	elseif kind == "CAMERA" then
		local c = element
		data.shake = c:GetAttribute("LC_Shake") or 0
		data.frequency = c:GetAttribute("LC_Freq") or 12
		data.shakeTime = c:GetAttribute("LC_ShakeTime") or 0.4
		data.fov = c:GetAttribute("LC_FOV") or 0
		data.fovTime = c:GetAttribute("LC_FovTime") or 0.35
		local flash = c:GetAttribute("LC_Flash")
		data.flash = typeof(flash) == "Color3" and flash or nil
		data.flashAlpha = c:GetAttribute("LC_FlashAlpha") or 0.5
		data.flashTime = c:GetAttribute("LC_FlashTime") or 0.25
		data.radius = c:GetAttribute("LC_Radius") or 60
		data.studio = c:GetAttribute("LC_Studio") ~= false
		data.window = Editor.window(c)
		data.bursts = Editor.bursts(c)
	elseif kind == "BEAM" then
		local beam = element
		local a0, a1 = trailAttachments(beam)
		data.start = a0 and a0.Position or Vector3.zero
		data.finish = a1 and a1.Position or Vector3.zero
		data.width = { beam.Width0, beam.Width1 }
		data.curve = { beam.CurveSize0, beam.CurveSize1 }
		data.texture = TEXTURE_KEY[beam.Texture] or (beam.Texture == "" and "NONE" or "CUSTOM")
		data.textureId = beam.Texture
		data.color = colors3(beam.Color)
		data.transparency = seq3(beam.Transparency)
		for _, prop in { "Segments", "TextureSpeed", "TextureLength", "LightEmission", "LightInfluence", "Brightness", "FaceCamera", "ZOffset" } do
			data[prop] = beam[prop]
		end
		data.TextureMode = beam.TextureMode.Name
		data.flashTime = beam:GetAttribute("LC_FlashTime") or 0.12
		data.fade = beam:GetAttribute("LC_Fade") or 0.08
		data.jitter = beam:GetAttribute("LC_Jitter") or 0
		data.window = Editor.window(beam)
		data.bursts = Editor.bursts(beam)
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
	if VFX.invalidate then -- the player compiles each effect once: a preview must show the latest edit
		VFX.invalidate(effect)
	end
	return VFX.play(effect, target, {
		speed = opts.speed or 1,
		scale = opts.scale or 1,
		parent = opts.parent or workspace.CurrentCamera,
		attach = opts.attach,
		facing = opts.facing,
		quality = opts.quality or 1, -- the whole effect, whatever the graphics level of Studio
		camera = opts.camera,
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
		elseif e:IsA("Beam") then
			tail = math.max(tail, e:GetAttribute("LC_FlashTime") or 0.12, e:GetAttribute("LC_Fade") or 0.08)
		elseif Editor.kindOf(e) == "CAMERA" then
			local shake, fov = e:GetAttribute("LC_Shake") or 0, e:GetAttribute("LC_FOV") or 0
			tail = math.max(tail, shake > 0 and (e:GetAttribute("LC_ShakeTime") or 0.4) or 0,
				fov ~= 0 and (e:GetAttribute("LC_FovTime") or 0.35) or 0, e:GetAttribute("LC_Flash") and (e:GetAttribute("LC_FlashTime") or 0.25) or 0)
		elseif e:IsA("Sound") and e:GetAttribute("LC_On") then -- one-shot sounds may ring on after the effect: not counted
			tail = math.max(tail, e:GetAttribute("LC_Fade") or 0.15)
		end
	end
	return (effect:GetAttribute("LC_Duration") or 1) + tail
end

-- ---------------------------------------------------------------------------------------------
-- new effect from a template (one undo step), recoloured and scaled
-- ---------------------------------------------------------------------------------------------
local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- a name that is valid and free for a new effect (the message says what is wrong)
local function checkNewName(name)
	assert(type(name) == "string", "LostCube: numele efectului trebuie să fie text")
	name = trim(name)
	assert(#name <= 100, "LostCube: numele efectului e prea lung (maxim 100 de caractere)")
	assertFreeName(Editor.folder(false), name)
	return name
end

-- the empty effect model (Root part + attributes); it is parented by the caller when it is finished
local function buildEffectModel(name, duration, attach)
	local model = Instance.new("Model")
	model.Name = name
	local root = invisiblePart("Root", Vector3.new(0.2, 0.2, 0.2), CFrame.new())
	root.Parent = model
	model.PrimaryPart = root
	model:SetAttribute("LC_Duration", duration)
	model:SetAttribute("LC_Attach", attach)
	model:SetAttribute("LC_Tool", "LostCube")
	return model
end

-- recolour: the template's main colour -> the chosen one. Hue moves by the same angle for every colour (the accent
-- colours keep their relation to the main one), saturation follows the ratio; whites, greys and near-blacks stay.
local function shiftColor(c, from, to)
	local h, s, v = c:ToHSV()
	if s < 0.12 or v < 0.16 then
		return c
	end
	local fh, fs, fv = from:ToHSV()
	local th, ts, tv = to:ToHSV()
	local ns = math.clamp(s * (ts / math.max(fs, 0.1)), 0, 1)
	local nv = math.clamp(v * math.clamp((tv / math.max(fv, 0.1)) ^ 0.5, 0.6, 1.1), 0, 1)
	return Color3.fromHSV((h + th - fh) % 1, ns, nv)
end

-- a colour value as the props accept it (Color3, list of Color3 with optional mid, { { t, Color3 } } keypoints, ColorSequence)
local function mapColors(v, fn)
	local kind = typeof(v)
	if kind == "Color3" then
		return fn(v)
	elseif kind == "ColorSequence" then
		local points = {}
		for _, kp in v.Keypoints do
			table.insert(points, ColorSequenceKeypoint.new(kp.Time, fn(kp.Value)))
		end
		return ColorSequence.new(points)
	elseif type(v) == "table" then
		local out = {}
		for key, item in v do
			if typeof(item) == "Color3" then
				out[key] = fn(item)
			elseif type(item) == "table" and typeof(item[2]) == "Color3" then
				out[key] = { item[1], fn(item[2]) }
			else
				out[key] = item
			end
		end
		return out
	end
	return v -- hex strings and RGB triplets are left as they are
end

local COLOR_KEYS = { "color", "Color", "colorEnd", "flash" }

local function recolorProps(props, from, to)
	local fn = function(c)
		return shiftColor(c, from, to)
	end
	for _, key in COLOR_KEYS do
		if props[key] ~= nil then
			props[key] = mapColors(props[key], fn)
		end
	end
end

-- spatial scale of a value: number, Vector3, list of numbers (mid stays), list of { t, value } keypoints
local function mulSpec(v, k)
	if type(v) == "number" then
		return v * k
	elseif typeof(v) == "Vector3" then
		return v * k
	elseif typeof(v) == "NumberRange" then
		return NumberRange.new(v.Min * k, v.Max * k)
	elseif typeof(v) == "NumberSequence" then
		local points = {}
		for _, kp in v.Keypoints do
			table.insert(points, NumberSequenceKeypoint.new(kp.Time, kp.Value * k, kp.Envelope * k))
		end
		return NumberSequence.new(points)
	elseif type(v) == "table" then
		local out = {}
		for key, item in v do
			if type(item) == "number" then
				out[key] = key == "mid" and item or item * k
			elseif type(item) == "table" then
				out[key] = { item[1], (item[2] or 0) * k }
			else
				out[key] = item
			end
		end
		return out
	end
	return v
end

local function scaleProps(kind, props, k)
	local function mul(key)
		if props[key] ~= nil then
			props[key] = mulSpec(props[key], k)
		end
	end
	mul("position")
	mul("partSize")
	if kind == "PARTICLES" then
		mul("size")
		mul("speed")
		mul("acceleration")
	elseif kind == "TRAIL" then
		mul("height")
	elseif kind == "LIGHT" then
		mul("Range")
		if props.keys then
			local keys = {}
			for i, key in props.keys do
				keys[i] = { key[1], key[2], key[3] * k }
			end
			props.keys = keys
		end
	elseif kind == "MESH" then
		mul("size")
		mul("radius")
		mul("speed")
		mul("rise")
	elseif kind == "BEAM" then
		mul("start")
		mul("finish")
		mul("width")
		mul("curve")
		mul("jitter")
	elseif kind == "CAMERA" then
		mul("radius")
	end
end

--- newFromTemplate(name, templateKey, opts?) -> the new effect (Model), in one undo step.
--- opts: color (Color3: replaces the template's main colour in every element), scale (number: sizes, distances and
--- speeds are baked in), attach / duration (override the template's).
function Editor.newFromTemplate(name, templateKey, opts)
	opts = opts or {}
	local tpl = TEMPLATE_BY_KEY[templateKey]
	assert(tpl, "LostCube: nu există șablonul " .. tostring(templateKey))
	name = checkNewName(name)
	local scale = opts.scale == nil and 1 or opts.scale
	assert(type(scale) == "number" and scale >= 0.05 and scale <= 20, "LostCube: scara trebuie să fie între 0.05 și 20")
	assert(opts.color == nil or typeof(opts.color) == "Color3", "LostCube: culoarea trebuie să fie un Color3")
	local duration = opts.duration or tpl.duration
	assert(type(duration) == "number" and duration > 0, "LostCube: durata trebuie să fie un număr > 0")
	return record("efect din șablon " .. tpl.label .. " -> " .. name, function()
		local folder = Editor.folder(true)
		assertFreeName(folder, name)
		local model = buildEffectModel(name, math.max(0.01, duration), opts.attach or tpl.attach)
		model:SetAttribute("LC_Template", tpl.key)
		local ok, err = pcall(function()
			for _, item in tpl.elements do
				local preset = PRESET_BY_KEY[item.preset]
				assert(preset, "LostCube: preset necunoscut " .. tostring(item.preset))
				local props = table.clone(preset.props)
				for key, value in item.props do
					props[key] = value
				end
				local elementName = uniqueName(model, props.name or preset.label)
				props.name = nil
				if opts.color then
					recolorProps(props, tpl.main, opts.color)
				end
				if scale ~= 1 then
					scaleProps(preset.kind, props, scale)
				end
				local element = create(model, preset.kind, elementName)
				applyProps(element, props)
				element:SetAttribute("LC_Preset", preset.key)
			end
		end)
		if not ok then
			model:Destroy()
			error(err, 0)
		end
		model.Parent = folder -- last: the panels never see a half-built effect
		return model
	end)
end

-- ---------------------------------------------------------------------------------------------
-- import: ParticleEmitters / Trails / lights of a free model -> LostCube elements (never scripts)
-- ---------------------------------------------------------------------------------------------
local MAX_IMPORT = 80 -- elements per import (a few "VFX packs" hold hundreds of emitters)
local PARTICLE_COPY = { "Texture", "Color", "Size", "Transparency", "Squash", "Lifetime", "Speed", "SpreadAngle", "Rate",
	"Acceleration", "Drag", "LightEmission", "LightInfluence", "Brightness", "Rotation", "RotSpeed", "Orientation", "ZOffset",
	"LockedToPart", "EmissionDirection", "ShapeStyle", "ShapeInOut", "ShapePartial", "VelocityInheritance", "VelocitySpread",
	"WindAffectsDrag", "FlipbookLayout", "FlipbookMode", "FlipbookFramerate", "FlipbookStartRandom", "FlipbookSizeX",
	"FlipbookSizeY", "FlipbookBlendFrames" }
local TRAIL_COPY = { "Texture", "Color", "Transparency", "LightEmission", "LightInfluence", "Brightness", "Lifetime", "MinLength",
	"MaxLength", "WidthScale", "FaceCamera", "TextureMode", "TextureLength" }

local function copyProps(to, from, list)
	for _, prop in list do
		pcall(function() -- a property this Studio does not know is simply skipped
			to[prop] = from[prop]
		end)
	end
end

-- the frame an emitter / light sits in (its Attachment or Part), nil when it hangs from something without a position
local function holderFrame(inst)
	local parent = inst.Parent
	if parent and parent:IsA("Attachment") then
		local ok, cf = pcall(function()
			return parent.WorldCFrame
		end)
		return ok and cf or nil
	elseif parent and parent:IsA("BasePart") then
		return parent.CFrame
	end
	return nil
end

-- where the imported effect is centred: the pivot of a model / part, else the centre of the parts found inside
local function importOrigin(source)
	if source:IsA("Model") then
		local ok, cf = pcall(source.GetPivot, source)
		if ok and cf then
			return cf
		end
	elseif source:IsA("BasePart") then
		return source.CFrame
	elseif source:IsA("Attachment") then
		local ok, cf = pcall(function()
			return source.WorldCFrame
		end)
		if ok then
			return cf
		end
	end
	local lo, hi
	for _, d in source:GetDescendants() do
		if d:IsA("BasePart") then
			local p = d.Position
			lo = lo and Vector3.new(math.min(lo.X, p.X), math.min(lo.Y, p.Y), math.min(lo.Z, p.Z)) or p
			hi = hi and Vector3.new(math.max(hi.X, p.X), math.max(hi.Y, p.Y), math.max(hi.Z, p.Z)) or p
		end
	end
	return lo and CFrame.new((lo + hi) / 2) or CFrame.new()
end

-- when an imported emitter plays: the attributes many VFX packs use (EmitCount / EmitDelay / EmitDuration) win; else an enabled
-- emitter gets an emission window and a disabled one (made to be Emit()-ed by a script) a burst at t = 0
local function importTimeline(d, windowLength)
	local delay = math.max(0, tonumber(d:GetAttribute("EmitDelay")) or 0)
	local count = tonumber(d:GetAttribute("EmitCount"))
	local length = tonumber(d:GetAttribute("EmitDuration"))
	local window, bursts
	local guessed = false
	if count then
		bursts = { { delay, math.clamp(math.floor(count + 0.5), 1, 300) } }
	end
	if length and length > 0 then
		window = { delay, delay + length }
	end
	if not window and not bursts then
		local rate = d:IsA("ParticleEmitter") and d.Rate or 0
		if d.Enabled and (rate > 0 or d:IsA("Trail")) then
			window = { 0, windowLength }
		else
			bursts = { { 0, rate > 0 and math.clamp(math.floor(rate + 0.5), 1, 60) or 10 } }
			guessed = true
		end
	end
	return window, bursts, guessed
end

local function importParticles(effect, d, origin, windowLength)
	local element = create(effect, "PARTICLES", uniqueName(effect, d.Name ~= "" and d.Name or "Particule"))
	copyProps(element, d, PARTICLE_COPY)
	element.Enabled = false
	local holder = holderFrame(d)
	local rel = holder and origin:ToObjectSpace(holder) or CFrame.new()
	local parent = d.Parent
	if parent and parent:IsA("BasePart") then -- an emitter on a part emits from its shape: the part (size, turn) is kept
		local size = Vector3.new(math.clamp(parent.Size.X, 0.05, 100), math.clamp(parent.Size.Y, 0.05, 100),
			math.clamp(parent.Size.Z, 0.05, 100))
		setPosition(element, rel.Position)
		setShape(element, d.Shape.Name, size)
		element.Parent.CFrame = rootOf(effect).CFrame * rel
	else
		element.Parent.CFrame = rel -- the Attachment under Root: position and turn (EmissionDirection follows it)
	end
	local window, bursts, guessed = importTimeline(d, windowLength)
	if window then
		setTimeline(element, "window", window)
	end
	if bursts then
		setTimeline(element, "bursts", bursts)
	end
	local last = window and window[2] or 0
	for _, b in bursts or {} do
		last = math.max(last, b[1])
	end
	return element, last, guessed
end

local function importTrail(effect, d, origin, windowLength)
	local element = create(effect, "TRAIL", uniqueName(effect, d.Name ~= "" and d.Name or "Trail"))
	copyProps(element, d, TRAIL_COPY)
	element.Enabled = false
	local a, b = trailAttachments(element)
	local function where(att)
		if not att then
			return nil
		end
		local ok, cf = pcall(function()
			return att.WorldCFrame
		end)
		return ok and origin:PointToObjectSpace(cf.Position) or nil
	end
	local p0, p1 = where(d.Attachment0), where(d.Attachment1)
	if p0 and p1 and (p0 - p1).Magnitude > 0.01 then
		a.Position, b.Position = p0, p1
	end
	local window = select(1, importTimeline(d, windowLength))
	window = window or { 0, windowLength }
	setTimeline(element, "window", window)
	return element, window[2]
end

local function importLight(effect, d, origin)
	local element = create(effect, "LIGHT", uniqueName(effect, d.Name ~= "" and d.Name or "Lumină"))
	copyProps(element, d, { "Color", "Brightness", "Range", "Shadows" })
	local holder = holderFrame(d)
	setPosition(element, holder and origin:PointToObjectSpace(holder.Position) or Vector3.zero)
	if not d.Enabled then
		element:SetAttribute("LC_Muted", true)
	end
	return element
end

-- the work of importEmitters without recording: returns { elements, particles, trails, lights, skipped, notes }
local function importInto(effect, source, opts)
	opts = opts or {}
	local origin = opts.origin or importOrigin(source)
	local windowLength = math.max(0.1, opts.window or 2)
	local result = { elements = {}, particles = 0, trails = 0, lights = 0, skipped = 0, notes = {}, unsupported = 0, burstGuess = 0 }
	local last = 0
	local found = source:GetDescendants()
	table.insert(found, 1, source)
	for _, d in found do
		local kind = d:IsA("ParticleEmitter") and "particles" or (d:IsA("Trail") and "trails")
			or ((d:IsA("PointLight") or d:IsA("SpotLight")) and "lights") or nil
		if kind then
			if #result.elements >= MAX_IMPORT then
				result.skipped += 1
			else
				local created
				local ok, element, t, guessed = pcall(function()
					if kind == "particles" then
						return importParticles(effect, d, origin, windowLength)
					elseif kind == "trails" then
						return importTrail(effect, d, origin, windowLength)
					end
					return importLight(effect, d, origin), 0
				end)
				if ok then
					created = element
					table.insert(result.elements, created)
					result[kind] += 1
					last = math.max(last, t or 0)
					if guessed then
						result.burstGuess += 1
					end
				else
					result.skipped += 1
					table.insert(result.notes, "„" .. d.Name .. "” nu a putut fi importat: " .. tostring(element))
				end
			end
		elseif d:IsA("Beam") or d:IsA("Fire") or d:IsA("Smoke") or d:IsA("Sparkles") or d:IsA("Explosion") then
			result.unsupported += 1
		end
	end
	if result.skipped > 0 then
		table.insert(result.notes, result.skipped .. " elemente au fost omise (maxim " .. MAX_IMPORT .. " per import sau erori).")
	end
	if result.unsupported > 0 then
		table.insert(result.notes, result.unsupported .. " obiecte Beam / Fire / Smoke / Sparkles / Explosion nu se pot importa.")
	end
	if result.burstGuess > 0 then
		table.insert(result.notes, result.burstGuess .. " emițătoare dezactivate au primit un burst la t = 0 (în original le pornea un script).")
	end
	if last + 0.05 > (effect:GetAttribute("LC_Duration") or 1) then
		effect:SetAttribute("LC_Duration", round(last + 0.05, 2))
	end
	return result
end

--- importEmitters(effect, source, opts?) -> { elements, particles, trails, lights, skipped, notes }
--- Copies every ParticleEmitter / Trail / PointLight (and SpotLight, as a point light) found under `source` (a model, part,
--- folder or the emitter itself) into LostCube elements of `effect`, keeping their relative positions. Scripts are never
--- touched. opts: window (s, emission window of enabled emitters, default 2), origin (CFrame that becomes the effect's root).
function Editor.importEmitters(effect, source, opts)
	effect = Editor.effect(effect)
	assert(typeof(source) == "Instance", "LostCube: sursa trebuie să fie un obiect din scenă (model, part, folder)")
	assert(source ~= effect and not source:IsDescendantOf(effect), "LostCube: sursa e chiar efectul")
	return record("importat emitoare din " .. source.Name .. " în " .. effect.Name, function()
		return importInto(effect, source, opts)
	end)
end

-- ---------------------------------------------------------------------------------------------
-- import a free model from the Creator Store by asset id (scripts are deleted before anything else)
-- ---------------------------------------------------------------------------------------------
local SUSPECT = {
	{ "require%s*%(%s*%d+", "require(ID)" }, { "loadstring", "loadstring" }, { "getfenv", "getfenv" }, { "setfenv", "setfenv" },
	{ "HttpService", "HttpService" }, { "MarketplaceService", "MarketplaceService" },
}

-- deletes every Script / LocalScript / ModuleScript; reads each one's text first (inert) to flag backdoor-like code
local function stripScripts(roots)
	local out = { total = 0, byClass = {}, suspicious = 0, examples = {} }
	local all = {}
	for _, root in roots do
		table.insert(all, root)
		for _, d in root:GetDescendants() do
			table.insert(all, d)
		end
	end
	for _, d in all do
		if d:IsA("LuaSourceContainer") then
			out.total += 1
			out.byClass[d.ClassName] = (out.byClass[d.ClassName] or 0) + 1
			local ok, text = pcall(function()
				return (d :: any).Source
			end)
			if ok and type(text) == "string" then
				local flags = {}
				for _, pattern in SUSPECT do
					if string.find(text, pattern[1]) then
						table.insert(flags, pattern[2])
					end
				end
				if #flags > 0 then
					out.suspicious += 1
					if #out.examples < 5 then
						table.insert(out.examples, d.Name .. " (" .. table.concat(flags, ", ") .. ")")
					end
				end
			end
			d:Destroy()
		end
	end
	return out
end

local function loadAssetRoots(id)
	local okObjects, objects = pcall(function()
		return game:GetObjects("rbxassetid://" .. id)
	end)
	if okObjects and type(objects) == "table" and #objects > 0 then
		local holder = Instance.new("Model")
		holder.Name = "LostCubeImport"
		for _, obj in objects do
			obj.Parent = holder
		end
		return holder, "GetObjects"
	end
	local okLoad, loaded = pcall(function()
		return game:GetService("InsertService"):LoadAsset(id)
	end)
	if okLoad and typeof(loaded) == "Instance" then
		return loaded, "InsertService"
	end
	return nil, tostring(okObjects and "asset gol" or objects) .. " | " .. tostring(okLoad and "asset gol" or loaded)
end

local function findAnalyzer()
	-- the plugin's Analyzer is a sibling; installed in a game, script.Parent.Parent is ReplicatedStorage, where an
	-- "Analyzer" would be one of the game's own modules (requiring it runs the game's code)
	for _, place in { script, script.Parent } do
		local module = place and place:FindFirstChild("Analyzer")
		if module and module:IsA("ModuleScript") then
			return module
		end
	end
	return nil
end

local ANALYZER_LEVEL = { high = "mare", medium = "medie", low = "mică" }

-- Analyzer.scanInstance(root) -> issues (another module of the plugin; optional): findings as plain lines
local function analyzerLines(root)
	local module = findAnalyzer()
	if not module then
		return nil
	end
	local ok, issues = pcall(function()
		return require(module).scanInstance(root)
	end)
	if not ok or type(issues) ~= "table" then
		return nil
	end
	local lines = {}
	for i, issue in issues do
		if i > 8 then
			table.insert(lines, "… și încă " .. (#issues - 8) .. " observații")
			break
		end
		if type(issue) == "table" then
			-- Analyzer issues: { severity = "high" | "medium" | "low", kind, path?, line?, message }
			local text = issue.message or issue.msg or issue.text or issue.title or issue.description or issue.what
			local level = issue.severity or issue.level
			level = ANALYZER_LEVEL[level] or level
			table.insert(lines, (level and ("[" .. tostring(level) .. "] ") or "") .. tostring(text or issue.kind or "observație")
				.. (type(issue.path) == "string" and issue.path ~= "" and (" (" .. issue.path .. ")") or ""))
		else
			table.insert(lines, tostring(issue))
		end
	end
	return lines
end

--- importAsset(assetId, effectName) -> (Model?, report)
--- Loads a Creator Store model, DELETES every script in it, copies its emitters / trails / lights into a new effect and
--- destroys the loaded model. report = { ok, assetId, error?, scriptsRemoved, scriptsByClass, suspicious, particles, trails,
--- lights, skipped, notes, analyzer?, lines } where `lines` is the report as plain Romanian text lines (one per line).
function Editor.importAsset(assetId, effectName)
	local id = tonumber(assetId)
	local report = { ok = false, assetId = id, scriptsRemoved = 0, scriptsByClass = {}, suspicious = 0, particles = 0, trails = 0,
		lights = 0, skipped = 0, notes = {}, lines = {} }
	local function fail(text)
		report.error = text
		table.insert(report.lines, 1, "✗ " .. text)
		return nil, report
	end
	if not id or id <= 0 or id % 1 ~= 0 or id > 2 ^ 53 then
		return fail("ID invalid: scrie doar numărul din adresa asset-ului (create.roblox.com/store/asset/NUMĂR).")
	end
	if effectName == nil or trim(tostring(effectName)) == "" then
		effectName = "Import " .. id
		local folder, n = Editor.folder(false), 1
		while folder and folder:FindFirstChild(effectName) do
			n += 1
			effectName = "Import " .. id .. " " .. n
		end
	end
	local okName, name = pcall(checkNewName, effectName)
	if not okName then
		return fail((tostring(name):gsub("^.-:%d+: ", "")))
	end

	local holder, how = loadAssetRoots(id)
	if not holder then
		return fail("Nu am putut încărca asset-ul " .. id .. " (nu e model, e privat sau fără acces). " .. tostring(how))
	end
	local effect
	local ok, err = pcall(function()
		-- 1) optional analysis while the scripts are still there (it only reads their text: the loaded copy is not
		-- parented anywhere, so none of them can run), otherwise it would always report nothing
		report.analyzer = analyzerLines(holder)
		-- 2) scripts out: free models often carry backdoors, and nothing below needs a script
		local removed = stripScripts({ holder })
		report.scriptsRemoved, report.scriptsByClass, report.suspicious = removed.total, removed.byClass, removed.suspicious
		report.suspiciousExamples = removed.examples
		-- 3) the emitters
		local count = 0
		for _, d in holder:GetDescendants() do
			if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("PointLight") or d:IsA("SpotLight") then
				count += 1
			end
		end
		if count == 0 then
			error("Asset-ul " .. id .. " nu conține niciun ParticleEmitter, Trail sau PointLight de importat.", 0)
		end
		effect = record("import VFX " .. id .. " -> " .. name, function()
			local folder = Editor.folder(true)
			assertFreeName(folder, name)
			local model = buildEffectModel(name, 1, "GROUND")
			model:SetAttribute("LC_Source", "rbxassetid://" .. id)
			local done, result = pcall(importInto, model, holder, {})
			if not done then
				model:Destroy()
				error(result, 0)
			end
			report.particles, report.trails, report.lights, report.skipped = result.particles, result.trails, result.lights, result.skipped
			report.notes = result.notes
			model.Parent = folder
			return model
		end)
	end)
	holder:Destroy() -- whatever happened, the loaded copy never stays in the place
	local lines = report.lines
	if report.scriptsRemoved > 0 then
		local parts = {}
		for className, n in report.scriptsByClass do
			table.insert(parts, n .. " " .. className)
		end
		table.sort(parts)
		table.insert(lines, "Scripturi șterse: " .. report.scriptsRemoved .. " (" .. table.concat(parts, ", ") .. ")")
		if report.suspicious > 0 then
			table.insert(lines, "⚠ " .. report.suspicious .. " din ele aveau cod care merită privit cu neîncredere ("
				.. table.concat(report.suspiciousExamples or {}, "; ") .. "): nu folosi modelul original în joc.")
		end
	else
		table.insert(lines, "Scripturi șterse: 0 (modelul nu conținea scripturi)")
	end
	if not ok then
		local text = (tostring(err):gsub("^.-:%d+: ", ""))
		report.error = text
		table.insert(lines, 1, "✗ " .. text)
		return nil, report
	end
	report.ok = true
	table.insert(lines, 1, "✓ Efectul „" .. name .. "” a fost creat din asset-ul " .. id)
	table.insert(lines, "Importate: " .. report.particles .. " particule, " .. report.trails .. " trail-uri, " .. report.lights .. " lumini")
	for _, note in report.notes do
		table.insert(lines, "• " .. note)
	end
	if report.analyzer then
		table.insert(lines, #report.analyzer > 0 and "Analizor:" or "Analizor: nimic de semnalat")
		for _, line in report.analyzer do
			table.insert(lines, "• " .. line)
		end
	end
	table.insert(lines, "Verifică efectul în previzualizare: texturile și timpii vin din modelul original.")
	return effect, report
end

Editor.VFX = VFX
return Editor
