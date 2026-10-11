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
	local code = Editor.exportEffect(fx)  -- "LC1:..." text to copy and send; Editor.importEffect(code, "Name") rebuilds it exactly
	Editor.exportAll() / Editor.importMany(code)  -- a whole library in one code
	Editor.recolorEffect(fx, Color3.fromRGB(80, 160, 255))  -- the whole effect to another colour (whites and greys stay)
	local color, why = Editor.matchPalette(fx, Editor.paletteOf(Analyzer.load()))  -- a colour that reads well on the map
	Editor.makeVariants(fx, { count = 3 })  -- copies in other colours (teams, rarities); Editor.scaleEffect(fx, 1.5) for size

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
			desc = "Aură continuă de 3 s: raze, flăcări, scântei și un puls pe sol în fiecare secundă. În joc o repeți din cod (VFX.play la fiecare ~2,8 s); aici, cu butonul de buclă.",
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
			desc = "Portal vertical care se rotește în fața efectului, cu cerc pe sol, sclipiri și lumină. Durează 3 s; repetă-l din cod sau cu butonul de buclă.",
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

-- ---------------------------------------------------------------------------------------------
-- share codes: "LC1:" + base64( crc32 + flag + compact JSON, LZ-compressed when that is smaller ). Pure Luau on purpose: the JSON
-- of HttpService has no stable key order (two exports of one effect would differ) and tests must not depend on it.
--   bytes   4 = CRC-32 of the JSON (a code cut or mangled while copying is refused), 1 = 0 (JSON as it is) or 1 (LZSS), then the data
--   JSON    { g = Editor.VERSION, fx = effect } for one effect, { g = ..., lib = { effect, ... } } for a library. Short keys, a
--           property equal to a fresh instance's is left out, numbers keep 6 digits (the engine stores 32-bit floats), Color3 is
--           "RRGGBB" when it is an 8-bit colour. The layout is described at encodeElement / decodeElement below.
--   limits  Editor.SHARE_LIMITS (sizes, elements, effects); every value read from a code is type-checked and clamped, resource
--           urls must be rbxassetid:// or Roblox's own content, and nothing in a code can create a script.
--   version the number after "LC". A field added later is simply ignored by older readers; a change in the meaning of existing
--           fields becomes LC2, and an older plugin then refuses the code with a message asking for an update.
-- ---------------------------------------------------------------------------------------------
Editor.CODE_VERSION = 1
Editor.CODE_PREFIX = "LC1:"
Editor.SHARE_LIMITS = {
	codeChars = 300000, -- characters of the code of one effect
	libraryChars = 2500000, -- ... of a whole library
	jsonBytes = 3000000, -- after decompression (a "zip bomb" cannot grow past it)
	elements = 150, -- elements per effect
	effects = 100, -- effects per library
	nameChars = 100,
	keypoints = 20, -- per sequence
	attributes = 40, -- per instance
	variants = 12,
}
local LIMITS = Editor.SHARE_LIMITS
-- the CFrame of an Attachment / Part relative to the Root part of the effect
local function frameIn(root, inst)
	local ok, cf = pcall(function()
		if inst:IsA("Attachment") then
			if inst.Parent == root then
				return inst.CFrame
			end
			return root.CFrame:ToObjectSpace(inst.WorldCFrame)
		elseif inst:IsA("BasePart") then
			return root.CFrame:ToObjectSpace(inst.CFrame)
		end
		return CFrame.new()
	end)
	return ok and cf or CFrame.new()
end

local function freeName(folder, base)
	base = string.sub(base, 1, LIMITS.nameChars - 8)
	if not folder or not folder:FindFirstChild(base) then
		return base
	end
	local i = 2
	while folder:FindFirstChild(base .. " " .. i) do
		i += 1
	end
	return base .. " " .. i
end

-- the machinery of the codes lives in this block (locals are scoped: the file stays under the 200 locals limit)
do
	-- compact JSON (sorted keys) -------------------------------------------------------------------------------
	local JSON_ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
	local JSON_UNESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

	local function jsonEscape(c)
		return JSON_ESCAPES[c] or string.format("\\u%04x", string.byte(c))
	end

	local function jsonEncode(value)
		local parts, n = {}, 0
		local function put(s)
			n += 1
			parts[n] = s
		end
		local function enc(v, depth)
			local kind = type(v)
			if depth > 24 then
				error("json: prea adânc", 0)
			elseif kind == "string" then
				put('"' .. string.gsub(v, '[%c"\\]', jsonEscape) .. '"')
			elseif kind == "number" then
				if v ~= v or v == math.huge or v == -math.huge then
					error("json: număr invalid", 0)
				end
				put(v == 0 and "0" or string.format("%.12g", v))
			elseif kind == "boolean" then
				put(v and "true" or "false")
			elseif kind == "table" then
				if next(v) == nil or v[1] ~= nil then
					put("[")
					for i = 1, #v do
						if i > 1 then
							put(",")
						end
						enc(v[i], depth + 1)
					end
					put("]")
				else
					local keys = {}
					for k in v do
						assert(type(k) == "string", "json: cheie care nu e text")
						table.insert(keys, k)
					end
					table.sort(keys)
					put("{")
					for i, k in keys do
						if i > 1 then
							put(",")
						end
						put('"' .. string.gsub(k, '[%c"\\]', jsonEscape) .. '":')
						enc(v[k], depth + 1)
					end
					put("}")
				end
			else
				error("json: tip neașteptat " .. kind, 0)
			end
		end
		enc(value, 0)
		return table.concat(parts)
	end

	-- strict reader: no null, depth and size limits; errors are plain strings
	local function jsonDecode(text)
		local pos, len, nodes = 1, #text, 0
		local function fail(why)
			error(string.format("json: %s (poziția %d)", why, pos), 0)
		end
		local function skip()
			pos = string.find(text, "[^ \t\r\n]", pos) or (len + 1)
		end
		local function readString()
			local i, buf, n = pos + 1, {}, 0
			while true do
				local j = string.find(text, '["\\]', i)
				if not j then
					fail("șir neterminat")
				end
				if j > i then
					n += 1
					buf[n] = string.sub(text, i, j - 1)
				end
				if string.byte(text, j) == 34 then
					pos = j + 1
					return table.concat(buf)
				end
				local c = string.sub(text, j + 1, j + 1)
				local plain = JSON_UNESCAPES[c]
				if plain then
					n += 1
					buf[n] = plain
					i = j + 2
				elseif c == "u" then
					local hex = string.match(text, "^%x%x%x%x", j + 2)
					if not hex then
						fail("secvență \\u greșită")
					end
					local cp = tonumber(hex, 16) :: number
					i = j + 6
					if cp >= 0xD800 and cp <= 0xDBFF then
						local low = string.match(text, "^\\u(%x%x%x%x)", i)
						local lv = low and tonumber(low, 16)
						if not lv or lv < 0xDC00 or lv > 0xDFFF then
							fail("surogat nepereche")
						end
						cp = 0x10000 + (cp - 0xD800) * 0x400 + (lv - 0xDC00)
						i += 6
					elseif cp >= 0xDC00 and cp <= 0xDFFF then
						fail("surogat nepereche")
					end
					n += 1
					buf[n] = utf8.char(cp)
				else
					fail("secvență de escape necunoscută")
				end
			end
		end
		local readValue
		readValue = function(depth)
			nodes += 1
			if nodes > 600000 then
				fail("prea multe valori")
			end
			if depth > 24 then
				fail("prea adânc")
			end
			skip()
			local c = string.byte(text, pos)
			if c == 34 then
				return readString()
			elseif c == 123 then -- {
				pos += 1
				local out = {}
				skip()
				if string.byte(text, pos) == 125 then
					pos += 1
					return out
				end
				while true do
					skip()
					if string.byte(text, pos) ~= 34 then
						fail("cheie așteptată")
					end
					local key = readString()
					skip()
					if string.byte(text, pos) ~= 58 then
						fail("':' așteptat")
					end
					pos += 1
					out[key] = readValue(depth + 1)
					skip()
					local d = string.byte(text, pos)
					pos += 1
					if d == 125 then
						return out
					elseif d ~= 44 then
						pos -= 1
						fail("',' sau '}' așteptat")
					end
				end
			elseif c == 91 then -- [
				pos += 1
				local out, n = {}, 0
				skip()
				if string.byte(text, pos) == 93 then
					pos += 1
					return out
				end
				while true do
					n += 1
					out[n] = readValue(depth + 1)
					skip()
					local d = string.byte(text, pos)
					pos += 1
					if d == 93 then
						return out
					elseif d ~= 44 then
						pos -= 1
						fail("',' sau ']' așteptat")
					end
				end
			elseif c == 116 and string.sub(text, pos, pos + 3) == "true" then
				pos += 4
				return true
			elseif c == 102 and string.sub(text, pos, pos + 4) == "false" then
				pos += 5
				return false
			elseif c and (c == 45 or (c >= 48 and c <= 57)) then
				local s = string.match(text, "^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
				local v = s and tonumber(s)
				if not v or v ~= v or v == math.huge or v == -math.huge then
					fail("număr greșit")
				end
				pos += #(s :: string)
				return v
			end
			fail("valoare neașteptată")
			return nil
		end
		local value = readValue(0)
		skip()
		if pos <= len then
			fail("text în plus")
		end
		return value
	end

	-- CRC-32 (detects a code that was cut or mangled while copying) ---------------------------------------------------
	local crcTable
	local function crc32(s)
		if not crcTable then
			crcTable = {}
			for i = 0, 255 do
				local c = i
				for _ = 1, 8 do
					if bit32.band(c, 1) == 1 then
						c = bit32.bxor(bit32.rshift(c, 1), 0xEDB88320)
					else
						c = bit32.rshift(c, 1)
					end
				end
				crcTable[i] = c
			end
		end
		local c = 0xFFFFFFFF
		for i = 1, #s do
			c = bit32.bxor(crcTable[bit32.band(bit32.bxor(c, string.byte(s, i)), 0xFF)], bit32.rshift(c, 8))
		end
		return bit32.bxor(c, 0xFFFFFFFF)
	end

	-- base64 (standard alphabet, no padding written; "=" and the URL-safe "-_" are accepted when reading) ----------------
	local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local B64_CHAR, B64_VALUE = {}, {}
	for i = 1, 64 do
		local ch = string.sub(B64, i, i)
		B64_CHAR[i - 1] = ch
		B64_VALUE[string.byte(ch)] = i - 1
	end
	B64_VALUE[string.byte("-")] = 62
	B64_VALUE[string.byte("_")] = 63

	local function base64Encode(s)
		local out, n = {}, 0
		local last = #s - #s % 3
		for i = 1, last, 3 do
			local a, b, c = string.byte(s, i, i + 2)
			local v = a * 65536 + b * 256 + c
			n += 1
			out[n] = B64_CHAR[bit32.rshift(v, 18)] .. B64_CHAR[bit32.band(bit32.rshift(v, 12), 63)]
				.. B64_CHAR[bit32.band(bit32.rshift(v, 6), 63)] .. B64_CHAR[bit32.band(v, 63)]
		end
		local rest = #s - last
		if rest == 1 then
			local v = string.byte(s, last + 1) * 65536
			n += 1
			out[n] = B64_CHAR[bit32.rshift(v, 18)] .. B64_CHAR[bit32.band(bit32.rshift(v, 12), 63)]
		elseif rest == 2 then
			local a, b = string.byte(s, last + 1, last + 2)
			local v = a * 65536 + b * 256
			n += 1
			out[n] = B64_CHAR[bit32.rshift(v, 18)] .. B64_CHAR[bit32.band(bit32.rshift(v, 12), 63)]
				.. B64_CHAR[bit32.band(bit32.rshift(v, 6), 63)]
		end
		return table.concat(out)
	end

	-- -> bytes, or nil when the text is not base64
	local function base64Decode(text: string): string?
		text = string.gsub(text, "=+$", "")
		local len = #text
		if len % 4 == 1 or string.find(text, "[^%w%+/_%-]") then
			return nil
		end
		local out, n = {}, 0
		local last = len - len % 4
		for i = 1, last, 4 do
			local a, b, c, d = string.byte(text, i, i + 3)
			local v = B64_VALUE[a] * 262144 + B64_VALUE[b] * 4096 + B64_VALUE[c] * 64 + B64_VALUE[d]
			n += 1
			out[n] = string.char(bit32.rshift(v, 16), bit32.band(bit32.rshift(v, 8), 255), bit32.band(v, 255))
		end
		local rest = len - last
		if rest == 2 then
			local a, b = string.byte(text, last + 1, last + 2)
			local v = B64_VALUE[a] * 4096 + B64_VALUE[b] * 64
			n += 1
			out[n] = string.char(bit32.rshift(v, 10))
		elseif rest == 3 then
			local a, b, c = string.byte(text, last + 1, last + 3)
			local v = B64_VALUE[a] * 262144 + B64_VALUE[b] * 4096 + B64_VALUE[c] * 64
			n += 1
			out[n] = string.char(bit32.rshift(v, 16), bit32.band(bit32.rshift(v, 8), 255))
		end
		return table.concat(out)
	end

	-- LZSS (4 KB window, matches of 3..18 bytes): a flag byte (bit set = literal) then up to 8 items; JSON with its repeated keys
	-- shrinks to about a third ---------------------------------------------------------------------------------------------
	local function lzCompress(s)
		local n = #s
		local bytes = table.create(n)
		for i = 1, n, 4000 do
			local chunk = { string.byte(s, i, math.min(n, i + 3999)) }
			table.move(chunk, 1, #chunk, i, bytes)
		end
		local head, prev = {}, table.create(n)
		local out, outN = {}, 0
		local group, groupN, flags = {}, 0, 0
		local function flush()
			if groupN == 0 then
				return
			end
			outN += 1
			out[outN] = string.char(flags) .. table.concat(group, "", 1, groupN)
			groupN, flags = 0, 0
			table.clear(group)
		end
		local function insert(p)
			if p + 2 <= n then
				local key = bytes[p] * 65536 + bytes[p + 1] * 256 + bytes[p + 2]
				prev[p] = head[key]
				head[key] = p
			end
		end
		local i = 1
		while i <= n do
			local bestLen, bestPos = 0, 0
			if i + 2 <= n then
				local candidate = head[bytes[i] * 65536 + bytes[i + 1] * 256 + bytes[i + 2]]
				local tries = 0
				local maxLen = math.min(18, n - i + 1)
				while candidate and i - candidate <= 4095 and tries < 40 do
					local l = 0
					while l < maxLen and bytes[candidate + l] == bytes[i + l] do
						l += 1
					end
					if l > bestLen then
						bestLen, bestPos = l, candidate
						if l == maxLen then
							break
						end
					end
					candidate = prev[candidate]
					tries += 1
				end
			end
			groupN += 1
			if bestLen >= 3 then
				local v = (i - bestPos) * 16 + (bestLen - 3)
				group[groupN] = string.char(bit32.rshift(v, 8), bit32.band(v, 255))
				for p = i, i + bestLen - 1 do
					insert(p)
				end
				i += bestLen
			else
				flags += bit32.lshift(1, groupN - 1)
				group[groupN] = string.char(bytes[i])
				insert(i)
				i += 1
			end
			if groupN == 8 then
				flush()
			end
		end
		flush()
		return table.concat(out)
	end

	-- -> text, or nil + reason when the data is damaged or would grow past `limit` bytes. Memory stays small however much the
	-- data grows: only the last 4 KB (what a match can point to) and the finished chunks are kept.
	local function lzDecompress(s, limit)
		local out, outN, flushed = {}, 0, 0
		local parts = {}
		local len, i = #s, 1
		while i <= len do
			local flags = string.byte(s, i)
			i += 1
			for bitIndex = 0, 7 do
				if i > len then
					break
				end
				if bit32.band(bit32.rshift(flags, bitIndex), 1) == 1 then
					outN += 1
					out[outN] = string.byte(s, i)
					i += 1
				else
					if i + 1 > len then
						return nil, "date tăiate"
					end
					local hi, lo = string.byte(s, i, i + 1)
					i += 2
					local v = hi * 256 + lo
					local offset, count = bit32.rshift(v, 4), bit32.band(v, 15) + 3
					if offset == 0 or offset > flushed + outN then
						return nil, "referință greșită"
					end
					for _ = 1, count do
						outN += 1
						out[outN] = out[outN - offset]
					end
				end
			end
			if flushed + outN > limit then
				return nil, "date prea mari"
			end
			if outN >= 65536 then -- keep the last 4 KB, turn the rest into text
				local keep = outN - 4096
				for a = 1, keep, 4000 do
					table.insert(parts, string.char(table.unpack(out, a, math.min(keep, a + 3999))))
				end
				table.move(out, keep + 1, outN, 1)
				for k = 4097, outN do
					out[k] = nil
				end
				flushed += keep
				outN = 4096
			end
		end
		for a = 1, outN, 4000 do
			table.insert(parts, string.char(table.unpack(out, a, math.min(outN, a + 3999))))
		end
		return table.concat(parts)
	end

	-- the codec of values: Roblox datatypes <-> numbers / strings / short arrays ----------------------------------------------
	--   number, bool, string       as they are (numbers keep 6 significant digits: the engine stores 32-bit floats)
	--   Color3                     "RRGGBB" (8-bit colours) or { r, g, b }
	--   ColorSequence              { color } (one colour) or { t, color, t, color, ... }
	--   NumberSequence             n (one value) or { t, v, t, v, ... } or { "e", t, v, envelope, ... }
	--   NumberRange / Vector2 / 3  n or { min, max } / { x, y } / { x, y, z }
	--   CFrame (relative to Root)  { x, y, z } or { x, y, z, rx, ry, rz } (degrees)
	--   enums                      their name
	local function fl(x)
		if x ~= x or x == math.huge or x == -math.huge then
			return 0
		end
		local r = tonumber(string.format("%.6g", x)) :: number
		return r == 0 and 0 or r
	end

	local function fl12(x)
		if x ~= x or x == math.huge or x == -math.huge then
			return 0
		end
		local r = tonumber(string.format("%.12g", x)) :: number
		return r == 0 and 0 or r
	end

	local URL_SHORT = { { "rbxassetid://", "#" }, { "rbxasset://textures/particles/", "~p/" }, { "rbxasset://textures/", "~t/" },
		{ "rbxasset://sounds/", "~s/" } }

	local function encUrl(url)
		for _, pair in URL_SHORT do
			if string.sub(url, 1, #pair[1]) == pair[1] then
				return pair[2] .. string.sub(url, #pair[1] + 1)
			end
		end
		return url
	end

	local function encColor(c)
		local r, g, b = c.R * 255, c.G * 255, c.B * 255
		local ri, gi, bi = math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5)
		if math.abs(r - ri) < 0.02 and math.abs(g - gi) < 0.02 and math.abs(b - bi) < 0.02 and ri >= 0 and ri <= 255 and gi >= 0
			and gi <= 255 and bi >= 0 and bi <= 255 then
			return string.format("%02X%02X%02X", ri, gi, bi)
		end
		return { fl(c.R), fl(c.G), fl(c.B) }
	end

	local function encColorSeq(cs)
		local k = cs.Keypoints
		if #k == 2 and jsonEncode(encColor(k[1].Value)) == jsonEncode(encColor(k[2].Value)) then
			return { encColor(k[1].Value) }
		end
		local out = {}
		for _, kp in k do
			table.insert(out, fl(kp.Time))
			table.insert(out, encColor(kp.Value))
		end
		return out
	end

	local function encNumberSeq(ns)
		local k = ns.Keypoints
		local envelope = false
		for _, kp in k do
			if kp.Envelope ~= 0 then
				envelope = true
			end
		end
		if #k == 2 and not envelope and fl(k[1].Value) == fl(k[2].Value) then
			return fl(k[1].Value)
		end
		local out = envelope and { "e" } or {}
		for _, kp in k do
			table.insert(out, fl(kp.Time))
			table.insert(out, fl(kp.Value))
			if envelope then
				table.insert(out, fl(kp.Envelope))
			end
		end
		return out
	end

	local function encRange(nr)
		if fl(nr.Min) == fl(nr.Max) then
			return fl(nr.Min)
		end
		return { fl(nr.Min), fl(nr.Max) }
	end

	local function degrees3(x)
		local r = tonumber(string.format("%.3f", x)) :: number
		return r == 0 and 0 or r
	end

	local function encFrame(cf)
		local at = cf.Position
		local out = { fl(at.X), fl(at.Y), fl(at.Z) }
		local ok, rx, ry, rz = pcall(function()
			return cf:ToOrientation()
		end)
		if ok and type(rx) == "number" then
			local a, b, c = degrees3(math.deg(rx)), degrees3(math.deg(ry)), degrees3(math.deg(rz))
			if a ~= 0 or b ~= 0 or c ~= 0 then
				out[4], out[5], out[6] = a, b, c
			end
		end
		return out
	end

	local function encodeValue(kind, v)
		if kind == "n" or kind == "i" then
			return fl(v)
		elseif kind == "b" or kind == "s" then
			return v
		elseif kind == "url" then
			return encUrl(v)
		elseif kind == "c" then
			return encColor(v)
		elseif kind == "cs" then
			return encColorSeq(v)
		elseif kind == "ns" then
			return encNumberSeq(v)
		elseif kind == "nr" then
			return encRange(v)
		elseif kind == "v2" then
			return { fl(v.X), fl(v.Y) }
		elseif kind == "v3" then
			return { fl(v.X), fl(v.Y), fl(v.Z) }
		end
		return v.Name -- enums
	end

	-- decoding: every value is checked, out-of-range numbers are brought into range (and counted) -------------------------
	local where = "" -- what is being read, for the error messages
	local clamped = 0 -- values that had to be brought into range during this read

	local function fail(why)
		error("LostCube: cod invalid" .. (where ~= "" and (" (" .. where .. ")") or "") .. ": " .. why, 0)
	end

	local function validText(s, max, what)
		if type(s) ~= "string" then
			fail(what .. " trebuie să fie text")
		end
		if #s > max then
			fail(what .. " e prea lung (maxim " .. max .. " caractere)")
		end
		if utf8.len(s) == nil or string.find(s, "%c") then
			fail(what .. " conține caractere nepermise")
		end
		return s
	end

	-- at most n characters (the text of an error message may come from a hostile code)
	local function shortenText(s, n)
		s = tostring(s)
		local length = utf8.len(s)
		if length and length <= n then
			return s
		end
		local ok, cut = pcall(utf8.offset, s, n + 1)
		if length and ok and cut then
			return string.sub(s, 1, cut - 1) .. "…"
		end
		return string.sub(s, 1, n) .. "…"
	end

	local function decNum(v, lo, hi, int)
		if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
			fail("număr invalid")
		end
		local x = v
		if lo and x < lo then
			x = lo
			clamped += 1
		elseif hi and x > hi then
			x = hi
			clamped += 1
		end
		if int then
			x = math.floor(x + 0.5)
		end
		return x
	end

	local function decUrl(v)
		validText(v, 200, "adresa resursei")
		local url = v
		for _, pair in URL_SHORT do
			if string.sub(v, 1, #pair[2]) == pair[2] then
				url = pair[1] .. string.sub(v, #pair[2] + 1)
				break
			end
		end
		if url == "" or string.match(url, "^rbxassetid://%d+$") or string.match(url, "^https?://www%.roblox%.com/asset/%?id=%d+$")
			or (string.match(url, "^rbxasset://[%w_%./%-]+$") and not string.find(url, "..", 1, true)) then
			return url
		end
		fail("adresa „" .. shortenText(url, 40) .. "” nu e permisă (doar rbxassetid://… sau resurse Roblox)")
		return ""
	end

	local function decColor(v: any): Color3
		if type(v) == "string" then
			local r, g, b = string.match(v, "^(%x%x)(%x%x)(%x%x)$")
			if not r then
				fail("culoare invalidă")
			end
			return Color3.fromRGB(tonumber(r, 16) :: number, tonumber(g, 16) :: number, tonumber(b, 16) :: number)
		elseif type(v) == "table" and #v == 3 then
			return Color3.new(decNum(v[1], 0, 1), decNum(v[2], 0, 1), decNum(v[3], 0, 1))
		end
		fail("culoare invalidă")
		return WHITE
	end

	local function decColorSeq(v)
		if type(v) ~= "table" then
			fail("secvență de culori invalidă")
		end
		if #v == 1 then
			return ColorSequence.new(decColor(v[1]))
		end
		if #v < 4 or #v % 2 == 1 or #v > LIMITS.keypoints * 2 then
			fail("secvență de culori invalidă")
		end
		local points, last = {}, -1
		for i = 1, #v, 2 do
			local t = v[i]
			if type(t) ~= "number" or t < 0 or t > 1 or t <= last then
				fail("timpii secvenței de culori sunt greșiți")
			end
			last = t
			table.insert(points, ColorSequenceKeypoint.new(t, decColor(v[i + 1])))
		end
		if points[1].Time ~= 0 or points[#points].Time ~= 1 then
			fail("secvența de culori trebuie să înceapă la 0 și să se termine la 1")
		end
		return ColorSequence.new(points)
	end

	local function decNumberSeq(v, lo, hi)
		if type(v) == "number" then
			return NumberSequence.new(decNum(v, lo, hi))
		elseif type(v) ~= "table" then
			fail("secvență de numere invalidă")
		end
		local envelope = v[1] == "e"
		local stride, first = envelope and 3 or 2, envelope and 2 or 1
		local count = (#v - first + 1) / stride
		if count % 1 ~= 0 or count < 2 or count > LIMITS.keypoints then
			fail("secvență de numere invalidă")
		end
		local points, last = {}, -1
		for i = 0, count - 1 do
			local at = first + i * stride
			local t = v[at]
			if type(t) ~= "number" or t < 0 or t > 1 or t <= last then
				fail("timpii secvenței de numere sunt greșiți")
			end
			last = t
			local e = envelope and math.max(0, decNum(v[at + 2], 0, hi)) or 0
			table.insert(points, NumberSequenceKeypoint.new(t, decNum(v[at + 1], lo, hi), e))
		end
		if points[1].Time ~= 0 or points[#points].Time ~= 1 then
			fail("secvența de numere trebuie să înceapă la 0 și să se termine la 1")
		end
		return NumberSequence.new(points)
	end

	local function decRange(v, lo, hi)
		if type(v) == "number" then
			local x = decNum(v, lo, hi)
			return NumberRange.new(x, x)
		elseif type(v) == "table" and #v == 2 then
			local a, b = decNum(v[1], lo, hi), decNum(v[2], lo, hi)
			return NumberRange.new(math.min(a, b), math.max(a, b))
		end
		fail("interval invalid")
		return NumberRange.new(0)
	end

	local function decVector(v, size, lo, hi)
		if type(v) ~= "table" or #v ~= size then
			fail("vector invalid")
		end
		local x, y = decNum(v[1], lo, hi), decNum(v[2], lo, hi)
		if size == 2 then
			return Vector2.new(x, y)
		end
		return Vector3.new(x, y, decNum(v[3], lo, hi))
	end

	local FRAME_RANGE = 5000

	local function decFrame(v)
		if type(v) ~= "table" or (#v ~= 3 and #v ~= 6) then
			fail("poziție invalidă")
		end
		local cf = CFrame.new(Vector3.new(decNum(v[1], -FRAME_RANGE, FRAME_RANGE), decNum(v[2], -FRAME_RANGE, FRAME_RANGE),
			decNum(v[3], -FRAME_RANGE, FRAME_RANGE)))
		if #v == 6 then
			local rx, ry, rz = decNum(v[4], -360, 360), decNum(v[5], -360, 360), decNum(v[6], -360, 360)
			local ok, turned = pcall(function()
				return cf * CFrame.fromOrientation(math.rad(rx), math.rad(ry), math.rad(rz))
			end)
			if ok then
				cf = turned
			end
		end
		return cf
	end

	local function decEnum(enumName, v)
		if type(v) ~= "string" then
			fail("valoare de enum invalidă")
		end
		local ok, item = pcall(function()
			return (Enum :: any)[enumName][v]
		end)
		if not ok or typeof(item) ~= "EnumItem" then
			fail("„" .. shortenText(v, 30) .. "” nu e o valoare cunoscută pentru " .. enumName)
		end
		return item
	end

	local function decodeValue(kind, v, lo, hi)
		if kind == "n" then
			return decNum(v, lo, hi)
		elseif kind == "i" then
			return decNum(v, lo, hi, true)
		elseif kind == "b" then
			if type(v) ~= "boolean" then
				fail("valoarea trebuie să fie da / nu")
			end
			return v
		elseif kind == "url" then
			return decUrl(v)
		elseif kind == "c" then
			return decColor(v)
		elseif kind == "cs" then
			return decColorSeq(v)
		elseif kind == "ns" then
			return decNumberSeq(v, lo, hi)
		elseif kind == "nr" then
			return decRange(v, lo, hi)
		elseif kind == "v2" then
			return decVector(v, 2, lo, hi)
		elseif kind == "v3" then
			return decVector(v, 3, lo, hi)
		end
		return decEnum(string.sub(kind, 3), v)
	end

	-- the properties written for each class: { key in the code, Roblox property, kind, min, max } ----------------------------
	-- A property equal to a fresh instance's is left out of the code; on import everything not in the code is set to the fresh
	-- instance's value, so the code does not depend on the defaults of this version of the Editor.
	local EMITTER_PROPS = {
		{ "tx", "Texture", "url" }, { "co", "Color", "cs" }, { "sz", "Size", "ns", 0, 2000 }, { "tr", "Transparency", "ns", 0, 1 },
		{ "sq", "Squash", "ns", -100, 100 }, { "lf", "Lifetime", "nr", 0, 60 }, { "rt", "Rate", "n", 0, 2000 },
		{ "sp", "Speed", "nr", -2000, 2000 }, { "sa", "SpreadAngle", "v2", 0, 180 }, { "ac", "Acceleration", "v3", -2000, 2000 },
		{ "dr", "Drag", "n", 0, 1000 }, { "le", "LightEmission", "n", 0, 1 }, { "li", "LightInfluence", "n", 0, 1 },
		{ "br", "Brightness", "n", 0, 100 }, { "ro", "Rotation", "nr", -3600, 3600 }, { "rs", "RotSpeed", "nr", -3600, 3600 },
		{ "or", "Orientation", "e:ParticleOrientation" }, { "zo", "ZOffset", "n", -100, 100 }, { "lp", "LockedToPart", "b" },
		{ "ed", "EmissionDirection", "e:NormalId" }, { "ss", "ShapeStyle", "e:ParticleEmitterShapeStyle" },
		{ "si", "ShapeInOut", "e:ParticleEmitterShapeInOut" }, { "sh", "Shape", "e:ParticleEmitterShape" },
		{ "sr", "ShapePartial", "n", 0, 1 }, { "vi", "VelocityInheritance", "n", 0, 1 }, { "vs", "VelocitySpread", "n", -360, 360 },
		{ "wd", "WindAffectsDrag", "b" }, { "ts", "TimeScale", "n", 0, 10 }, { "fl", "FlipbookLayout", "e:ParticleFlipbookLayout" },
		{ "fm", "FlipbookMode", "e:ParticleFlipbookMode" }, { "ff", "FlipbookFramerate", "nr", 0, 120 },
		{ "fr", "FlipbookStartRandom", "b" }, { "fx", "FlipbookSizeX", "i", 0, 64 }, { "fy", "FlipbookSizeY", "i", 0, 64 },
		{ "fb", "FlipbookBlendFrames", "b" }, { "en", "Enabled", "b" },
	}
	local TRAIL_PROPS = {
		{ "tx", "Texture", "url" }, { "co", "Color", "cs" }, { "tr", "Transparency", "ns", 0, 1 }, { "ws", "WidthScale", "ns", 0, 100 },
		{ "lf", "Lifetime", "n", 0, 60 }, { "mn", "MinLength", "n", 0, 1000 }, { "mx", "MaxLength", "n", 0, 100000 },
		{ "le", "LightEmission", "n", 0, 1 }, { "li", "LightInfluence", "n", 0, 1 }, { "br", "Brightness", "n", 0, 100 },
		{ "fc", "FaceCamera", "b" }, { "tm", "TextureMode", "e:TextureMode" }, { "tl", "TextureLength", "n", 0.01, 1000 },
		{ "en", "Enabled", "b" },
	}
	local BEAM_PROPS = {
		{ "tx", "Texture", "url" }, { "co", "Color", "cs" }, { "tr", "Transparency", "ns", 0, 1 }, { "w0", "Width0", "n", 0, 1000 },
		{ "w1", "Width1", "n", 0, 1000 }, { "c0", "CurveSize0", "n", -1000, 1000 }, { "c1", "CurveSize1", "n", -1000, 1000 },
		{ "sg", "Segments", "i", 1, 300 }, { "ts", "TextureSpeed", "n", -100, 100 }, { "tl", "TextureLength", "n", 0.01, 1000 },
		{ "tm", "TextureMode", "e:TextureMode" }, { "le", "LightEmission", "n", 0, 1 }, { "li", "LightInfluence", "n", 0, 1 },
		{ "br", "Brightness", "n", 0, 100 }, { "fc", "FaceCamera", "b" }, { "zo", "ZOffset", "n", -100, 100 }, { "en", "Enabled", "b" },
	}
	local LIGHT_PROPS = {
		{ "co", "Color", "c" }, { "br", "Brightness", "n", 0, 1000 }, { "rg", "Range", "n", 0, 120 }, { "sd", "Shadows", "b" },
		{ "en", "Enabled", "b" }, { "an", "Angle", "n", 0, 180 }, { "fa", "Face", "e:NormalId" },
	}
	local PART_PROPS = {
		{ "sh", "Shape", "e:PartType" }, { "ma", "Material", "e:Material" }, { "co", "Color", "c" }, { "sz", "Size", "v3", 0.001, 2048 },
		{ "tr", "Transparency", "n", 0, 1 }, { "rf", "Reflectance", "n", 0, 1 }, { "an", "Anchored", "b" }, { "cc", "CanCollide", "b" },
		{ "cq", "CanQuery", "b" }, { "ct", "CanTouch", "b" }, { "cs", "CastShadow", "b" }, { "ms", "Massless", "b" },
	}
	local SOUND_PROPS = {
		{ "id", "SoundId", "url" }, { "vo", "Volume", "n", 0, 10 }, { "ps", "PlaybackSpeed", "n", 0.01, 20 }, { "lp", "Looped", "b" },
		{ "rm", "RollOffMode", "e:RollOffMode" }, { "r0", "RollOffMinDistance", "n", 0, 10000 },
		{ "r1", "RollOffMaxDistance", "n", 0, 10000 }, { "es", "EmitterSize", "n", 0, 1000 },
	}
	-- letter of each kind of element in a code, and its property list
	local KIND_CODE = { PARTICLES = "P", LIGHT = "L", TRAIL = "T", MESH = "M", SOUND = "S", CAMERA = "C", BEAM = "B" }
	local CODE_KIND = {}
	for kind, code in KIND_CODE do
		CODE_KIND[code] = kind
	end
	local KIND_PROPS = { PARTICLES = EMITTER_PROPS, TRAIL = TRAIL_PROPS, BEAM = BEAM_PROPS, LIGHT = LIGHT_PROPS, MESH = PART_PROPS,
		SOUND = SOUND_PROPS }
	-- fresh instances to compare with / copy defaults from (one per class, destroyed when the operation ends)
	local function newRefs()
		return {}
	end

	local function refOf(refs, class)
		local ref = refs[class]
		if not ref then
			ref = Instance.new(class)
			refs[class] = ref
		end
		return ref
	end

	local function dropRefs(refs)
		for _, ref in refs do
			pcall(function()
				ref:Destroy()
			end)
		end
	end

	local function encodeProps(inst, list, refs, always)
		local ref = refOf(refs, inst.ClassName)
		local out
		for _, entry in list do
			local key, prop, kind = entry[1], entry[2], entry[3]
			local okValue, value = pcall(function()
				return (inst :: any)[prop]
			end)
			if okValue and value ~= nil then
				local enc = encodeValue(kind, value)
				local okRef, default = pcall(function()
					return (ref :: any)[prop]
				end)
				if not okRef or default == nil or (always and always[key]) or jsonEncode(enc) ~= jsonEncode(encodeValue(kind, default)) then
					out = out or {}
					out[key] = enc
				end
			end
		end
		return out
	end

	local function decodeProps(raw, list)
		local out = {}
		if raw == nil then
			return out
		elseif type(raw) ~= "table" then
			fail("proprietățile trebuie să fie un obiect")
		end
		for _, entry in list do
			local v = raw[entry[1]]
			if v ~= nil then
				local saved = where
				where = saved .. "." .. entry[2]
				out[entry[2]] = decodeValue(entry[3], v, entry[4], entry[5])
				where = saved
			end
		end
		return out
	end

	-- Roblox properties that exist in this Studio (an older or newer one may lack some): set one by one, ignoring the unknown ones
	local function assignProps(inst, list, values, refs)
		local ref = refOf(refs, inst.ClassName)
		for _, entry in list do
			local prop = entry[2]
			local value = values[prop]
			if value == nil then
				local okRef, default = pcall(function()
					return (ref :: any)[prop]
				end)
				if okRef then
					value = default -- (false is a value too: no `and / or` here)
				end
			end
			if value ~= nil then
				pcall(function()
					(inst :: any)[prop] = value
				end)
			end
		end
	end

	-- LC_* attributes: written without the prefix ("Bursts"), a Color3 as { "c", colour } --------------------------------------
	local ATTR_NUMBER = { Duration = { 0.01, 3600 }, Rate = { 0, 2000 }, Count = { 0, 500 }, Rise = { -1000, 1000 },
		Spin = { -3600, 3600 }, Jitter = { 0, 1000 }, Shake = { 0, 50 }, Freq = { 0, 200 }, ShakeTime = { 0, 30 }, FOV = { -120, 120 },
		FovTime = { 0, 30 }, FlashAlpha = { 0, 1 }, FlashTime = { 0, 30 }, Radius = { 0, 5000 }, Fade = { 0, 30 }, Lift = { -100, 100 },
		Flow = { 0, 100 } }
	-- "t,t;t,t" lists (LC_Radius is one on a 3D piece and a plain number on a camera): name -> { most items, fewest fields, most fields, { { min, max } of each field } }
	local ATTR_LIST = {
		On = { 50, 1, 2, { { 0, 3600 }, { 0, 3600 } } }, Bursts = { 300, 1, 2, { { 0, 3600 }, { 0, 2000 } } },
		Keys = { 150, 3, 3, { { 0, 3600 }, { 0, 1000 }, { 0, 200 } } }, Life = { 1, 1, 2, { { 0, 600 }, { 0, 600 } } },
		Grow = { 1, 1, 2, { { 0, 1000 }, { 0, 1000 } } }, Alpha = { 1, 1, 2, { { 0, 1 }, { 0, 1 } } },
		Speed = { 1, 1, 2, { { -2000, 2000 }, { -2000, 2000 } } }, Spread = { 1, 1, 2, { { 0, 360 }, { 0, 360 } } },
		Radius = { 1, 1, 2, { { 0, 5000 }, { 0, 5000 } } }, Pitch = { 1, 1, 2, { { 0, 20 }, { 0, 20 } } },
	}
	local ATTR_FLAGS = { Muted = true, Ground = true, Studio = true }
	local ATTR_WORDS = { Mode = { Ring = true, Crack = true, Pulse = true, Puff = true, Trail = true, Debris = true },
		Kind = { CAMERA = true } }

	local function encodeAttrs(inst)
		local out
		for name, v in inst:GetAttributes() do
			if string.sub(name, 1, 3) == "LC_" and #name > 3 and #name <= 33 and string.match(name, "^[%w_]+$") then
				local kind, enc = type(v), nil
				if kind == "number" then
					enc = fl12(v)
				elseif kind == "string" then
					enc = #v <= 8000 and v or nil
				elseif kind == "boolean" then
					enc = v
				elseif typeof(v) == "Color3" then
					enc = { "c", encColor(v) }
				end
				if enc ~= nil then
					out = out or {}
					out[string.sub(name, 4)] = enc
				end
			end
		end
		return out
	end

	local function checkAttrList(name, s)
		local rule = ATTR_LIST[name]
		if #s > 8000 or string.find(s, "[^%d%.eE%+%-,:;]") then
			fail("atributul LC_" .. name .. " are un format necunoscut")
		end
		local items = 0
		for item in string.gmatch(s, "[^;]+") do
			items += 1
			if items > rule[1] then
				fail("atributul LC_" .. name .. " are prea multe valori")
			end
			local fields = 0
			for x in string.gmatch(item, "[^,:]+") do
				fields += 1
				local v = tonumber(x)
				local range = rule[4][math.min(fields, #rule[4])]
				if not v or v ~= v or v < range[1] or v > range[2] then
					fail("atributul LC_" .. name .. " are valori în afara limitelor")
				end
			end
			if fields < rule[2] or fields > rule[3] then
				fail("atributul LC_" .. name .. " are un format necunoscut")
			end
		end
	end

	local ATTACH_SET = {}
	for _, a in Editor.ATTACH do
		ATTACH_SET[a.key] = true
	end

	local function decodeAttrs(raw)
		local out = {}
		if raw == nil then
			return out
		elseif type(raw) ~= "table" then
			fail("atributele trebuie să fie un obiect")
		end
		local count = 0
		for key, v in raw do
			count += 1
			if count > LIMITS.attributes then
				fail("prea multe atribute")
			end
			if type(key) ~= "string" or #key > 30 or not string.match(key, "^[%w_]+$") then
				fail("nume de atribut invalid")
			end
			local full = "LC_" .. key
			if (ATTR_NUMBER[key] and not ATTR_LIST[key] and type(v) ~= "number") or (ATTR_FLAGS[key] and type(v) ~= "boolean") then
				fail("atributul " .. full .. " are o valoare de alt tip decât cel așteptat")
			end
			if type(v) == "number" then
				local range = ATTR_NUMBER[key]
				out[full] = range and decNum(v, range[1], range[2]) or decNum(v, -1000000, 1000000)
			elseif type(v) == "boolean" then
				out[full] = v
			elseif type(v) == "string" then
				validText(v, ATTR_LIST[key] and 8000 or 400, "atributul " .. full)
				if ATTR_LIST[key] then
					checkAttrList(key, v)
				elseif ATTR_WORDS[key] and not ATTR_WORDS[key][v] then
					fail("valoarea „" .. shortenText(v, 20) .. "” nu e permisă pentru " .. full)
				elseif key == "Attach" and not ATTACH_SET[v] then
					fail("punct de atașare necunoscut „" .. shortenText(v, 20) .. "”")
				end
				out[full] = v
			elseif type(v) == "table" and v[1] == "c" and #v == 2 then
				out[full] = decColor(v[2])
			else
				fail("atributul " .. full .. " are o valoare neașteptată")
			end
		end
		return out
	end

	-- elements and effects <-> tables ------------------------------------------------------------------------------------------
	-- code of an effect:  { n = name, a = { attributes }, e = { element, ... } }
	-- code of an element: { k = kind letter, n = name, f = frame, g = second frame (trail / beam), hs = size of the Part an emitter
	--                       sits on, hn = name of its mount, c = "S" for a SpotLight, p = { properties }, a = { attributes } }
	-- Only what LostCube itself builds is written (see the header of this file): scripts, and anything else a model may hold, never.

	local function encodeElement(root, d, kind, refs, covered)
		local out = { k = KIND_CODE[kind], n = d.Name }
		local mount = d.Parent
		covered[d] = true
		covered[mount] = true
		local always
		if kind == "TRAIL" or kind == "BEAM" then
			for _, att in { d.Attachment0 or false, d.Attachment1 or false } do
				if att then
					covered[att] = true
				end
			end
			out.f = encFrame(d.Attachment0 and frameIn(root, d.Attachment0) or CFrame.new())
			out.g = encFrame(d.Attachment1 and frameIn(root, d.Attachment1) or CFrame.new())
		elseif kind == "MESH" then
			out.f = encFrame(frameIn(root, d))
		else
			local onPart = kind == "PARTICLES" and mount:IsA("BasePart") and mount ~= root
			local framed = onPart or mount:IsA("Attachment")
			out.f = encFrame(framed and frameIn(root, mount) or CFrame.new())
			if onPart then
				out.hs = encodeValue("v3", mount.Size)
				always = { sh = true } -- the shape of the emitter matters when it sits on a Part
			end
			if framed and mount.Name ~= d.Name then
				out.hn = mount.Name
			end
		end
		if kind == "LIGHT" and d:IsA("SpotLight") then
			out.c = "S"
		end
		local list = KIND_PROPS[kind]
		if list then
			out.p = encodeProps(d, list, refs, always)
		end
		out.a = encodeAttrs(d)
		return out
	end

	local function encodeEffect(effect, refs)
		local root = rootOf(effect)
		assert(root, "LostCube: efectul " .. effect.Name .. " nu are piesa Root")
		local out = { n = effect.Name, a = encodeAttrs(effect) }
		local list, covered = {}, { [root] = true }
		local all = effect:GetDescendants()
		for _, d in all do
			local kind = Editor.kindOf(d)
			if kind then
				table.insert(list, encodeElement(root, d, kind, refs, covered))
			end
		end
		local ignored = 0 -- scripts, folders, parts that are not elements...: they are not part of a code
		for _, d in all do
			if not covered[d] then
				ignored += 1
			end
		end
		assert(#list <= LIMITS.elements, string.format("LostCube: efectul %s are %d elemente; un cod poate avea cel mult %d",
			effect.Name, #list, LIMITS.elements))
		out.e = #list > 0 and list or nil
		return out, ignored
	end

	local function decodeElement(raw)
		if type(raw) ~= "table" then
			fail("element invalid")
		end
		local kind = CODE_KIND[raw.k]
		if not kind then
			fail("tip de element necunoscut „" .. shortenText(raw.k, 10) .. "”")
		end
		local name = validText(raw.n, LIMITS.nameChars, "numele elementului")
		if name == "" then
			fail("element fără nume")
		end
		where = "elementul „" .. shortenText(name, 30) .. "”"
		local spec = { kind = kind, name = name, props = {}, attrs = {} }
		spec.frame = decFrame(raw.f == nil and { 0, 0, 0 } or raw.f)
		if kind == "TRAIL" or kind == "BEAM" then
			spec.frame1 = decFrame(raw.g == nil and { 0, 0, 0 } or raw.g)
		end
		if raw.hs ~= nil then
			if kind ~= "PARTICLES" then
				fail("doar particulele stau pe o piesă 3D")
			end
			spec.partSize = decVector(raw.hs, 3, 0.05, 2048)
		end
		if raw.hn ~= nil then
			spec.holderName = validText(raw.hn, LIMITS.nameChars, "numele suportului")
		end
		if raw.c ~= nil then
			if kind ~= "LIGHT" or raw.c ~= "S" then
				fail("tip de lumină necunoscut")
			end
			spec.light = "SpotLight"
		end
		local list = KIND_PROPS[kind]
		if list then
			spec.props = decodeProps(raw.p, list)
		end
		spec.attrs = decodeAttrs(raw.a)
		if kind == "MESH" and type(spec.attrs.LC_Mode) ~= "string" then
			fail("piesa 3D nu are LC_Mode")
		end
		if kind == "CAMERA" then
			spec.attrs.LC_Kind = "CAMERA"
		end
		return spec
	end

	local function decodeEffect(raw)
		where = ""
		if type(raw) ~= "table" then
			fail("efect invalid")
		end
		local name = validText(raw.n, LIMITS.nameChars, "numele efectului")
		where = "efectul „" .. shortenText(name, 30) .. "”"
		local attrs = decodeAttrs(raw.a)
		if type(attrs.LC_Duration) ~= "number" then
			attrs.LC_Duration = 1
		end
		if type(attrs.LC_Attach) ~= "string" then
			attrs.LC_Attach = "GROUND"
		end
		attrs.LC_Tool = "LostCube"
		local elements = {}
		local list = raw.e
		if list ~= nil then
			if type(list) ~= "table" or (list[1] == nil and next(list) ~= nil) then
				fail("lista de elemente e invalidă")
			end
			if #list > LIMITS.elements then
				fail(string.format("are %d elemente; maximul e %d", #list, LIMITS.elements))
			end
			for i = 1, #list do
				elements[i] = decodeElement(list[i])
				where = "efectul „" .. shortenText(name, 30) .. "”"
			end
		end
		where = ""
		return { name = name, attrs = attrs, elements = elements }
	end

	local function buildElement(model, spec, refs)
		local root = rootOf(model)
		local kind = spec.kind
		local element = create(model, kind, uniqueName(model, spec.name))
		if kind == "LIGHT" and spec.light == "SpotLight" then
			local mount, elementName = element.Parent, element.Name
			element:Destroy()
			local spot = Instance.new("SpotLight")
			spot.Name = elementName
			spot.Parent = mount
			element = spot
		end
		-- where it sits
		if kind == "TRAIL" or kind == "BEAM" then
			element.Attachment0.CFrame, element.Attachment1.CFrame = spec.frame, spec.frame1
		elseif kind == "MESH" then
			element.CFrame = root.CFrame * spec.frame
		elseif spec.partSize then
			local shape = spec.props.Shape and spec.props.Shape.Name or "Box"
			setShape(element, SHAPES[shape] and shape ~= "Point" and shape or "Box", spec.partSize)
			element.Parent.CFrame = root.CFrame * spec.frame
			element.Parent.Size = spec.partSize
		else
			element.Parent.CFrame = spec.frame
		end
		if spec.holderName and kind ~= "MESH" and kind ~= "TRAIL" and kind ~= "BEAM" then
			element.Parent.Name = spec.holderName
		end
		-- what it is: every property of its class is set (a value left out of the code is the fresh instance's), then the attributes
		local list = KIND_PROPS[kind]
		if list then
			assignProps(element, list, spec.props, refs)
		end
		for name in element:GetAttributes() do
			element:SetAttribute(name, nil)
		end
		for name, value in spec.attrs do
			element:SetAttribute(name, value)
		end
		return element
	end

	-- the effect built off the tree (nothing sees a half-built one); the caller parents it
	local function buildModel(spec, name, refs)
		local model = buildEffectModel(name, spec.attrs.LC_Duration, spec.attrs.LC_Attach)
		local ok, err = pcall(function()
			for attr, value in spec.attrs do
				model:SetAttribute(attr, value)
			end
			for _, element in spec.elements do
				buildElement(model, element, refs)
			end
		end)
		if not ok then
			model:Destroy()
			error(err, 0)
		end
		return model
	end

	-- the code itself -------------------------------------------------------------------------------------------------------------
	local function packPayload(payload, limit, what)
		local json = jsonEncode(payload)
		assert(#json <= LIMITS.jsonBytes, string.format("LostCube: %s e prea mare pentru un cod de partajare", what))
		local body, flag = json, 0
		local packed = lzCompress(json)
		if #packed < #json then
			body, flag = packed, 1
		end
		local crc = crc32(json)
		local head = string.char(bit32.rshift(crc, 24), bit32.band(bit32.rshift(crc, 16), 255), bit32.band(bit32.rshift(crc, 8), 255),
			bit32.band(crc, 255), flag)
		local code = Editor.CODE_PREFIX .. base64Encode(head .. body)
		assert(#code <= limit, string.format("LostCube: %s e prea mare pentru un cod de partajare (%d caractere; maximum %d)", what,
			#code, limit))
		return code, { chars = #code, json = #json, compressed = flag == 1 }
	end

	-- -> payload table, number of characters of the code; raises the Romanian errors
	local function unpackCode(code)
		if type(code) ~= "string" then
			error("LostCube: codul trebuie să fie text", 0)
		end
		-- tolerated: invisible characters, line breaks, the code inside a message or between ``` marks
		local text = (string.gsub(code, "\226\128[\139-\141]", ""))
		text = (string.gsub(text, "\239\187\191", ""))
		text = (string.gsub(text, "\194\160", " "))
		local s, e, version = string.find(text, "[Ll][Cc](%d+):")
		if not s then
			if string.match(text, "^%s*$") then
				error("LostCube: codul e gol. Lipește un cod LostCube (începe cu LC1:).", 0)
			end
			error("LostCube: asta nu arată ca un cod LostCube (un cod începe cu LC1:).", 0)
		end
		local number = tonumber(version) :: number
		if number > Editor.CODE_VERSION then
			error(string.format("LostCube: codul e în formatul LC%d, mai nou decât cel pe care îl înțelege această versiune de "
				.. "LostCube (LC%d). Actualizează pluginul și încearcă din nou.", number, Editor.CODE_VERSION), 0)
		elseif number ~= Editor.CODE_VERSION then
			error(string.format("LostCube: formatul LC%d nu mai e acceptat. Cere un cod nou.", number), 0)
		end
		local body
		if string.match(string.sub(text, 1, s - 1), "^%s*$") then -- the whole text is the code (its lines may have been wrapped)
			body = (string.gsub(string.sub(text, e + 1), "%s+", ""))
		else
			body = string.match(text, "^[%w%+/_%-=]+", e + 1) or ""
		end
		if #body > LIMITS.libraryChars then
			error(string.format("LostCube: codul e prea mare (%d caractere; maximum %d).", #body, LIMITS.libraryChars), 0)
		end
		local bytes = base64Decode(body)
		if not bytes or #bytes < 6 then
			error("LostCube: codul e stricat sau incomplet. Copiază-l din nou, întreg.", 0)
		end
		local b1, b2, b3, b4, flag = string.byte(bytes, 1, 5)
		local crc = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
		local data = string.sub(bytes, 6)
		local json = data
		if flag == 1 then
			local plain, why = lzDecompress(data, LIMITS.jsonBytes)
			if not plain then
				error("LostCube: codul e stricat (" .. tostring(why) .. "). Copiază-l din nou, întreg.", 0)
			end
			json = plain
		elseif flag ~= 0 then
			error("LostCube: codul are un format intern necunoscut.", 0)
		end
		if #json > LIMITS.jsonBytes or crc32(json) ~= crc then
			error("LostCube: codul e stricat sau incomplet (suma de control nu se potrivește). Copiază-l din nou, întreg.", 0)
		end
		local ok, payload = pcall(jsonDecode, json)
		if not ok or type(payload) ~= "table" then
			error("LostCube: codul e stricat: conținutul nu poate fi citit.", 0)
		end
		return payload, #body
	end

	-- -> "effect" | "library", the list of raw effects
	local function payloadEffects(payload, chars)
		if type(payload.lib) == "table" then
			if #payload.lib == 0 or #payload.lib > LIMITS.effects then
				error(string.format("LostCube: o bibliotecă are între 1 și %d efecte", LIMITS.effects), 0)
			end
			return "library", payload.lib
		elseif type(payload.fx) == "table" then
			if chars > LIMITS.codeChars then
				error(string.format("LostCube: codul e prea mare (%d caractere; maximum %d).", chars, LIMITS.codeChars), 0)
			end
			return "effect", { payload.fx }
		end
		error("LostCube: codul nu conține niciun efect.", 0)
	end

	local function importNotes(info, wanted)
		if info.clamped > 0 then
			table.insert(info.notes, string.format("%d valori erau în afara limitelor permise și au fost aduse în limite.", info.clamped))
		end
		if wanted and info.renamed then
			table.insert(info.notes, "Numele era ocupat, așa că efectul a primit alt nume.")
		end
	end

	--- exportEffect(effect) -> code, stats
	--- The whole effect as text to copy and send: "LC1:" followed by a checksum and the compressed description of the model
	--- attributes and of every element (kind, name, position and orientation, all properties including colour / size sequences,
	--- timeline, LC_* attributes). stats = { chars, json, compressed, elements, ignored }: `ignored` counts the objects inside the
	--- model that are not part of an effect (scripts, folders, loose parts), which a code never carries. Importing the code
	--- (Editor.importEffect) rebuilds the effect exactly.
	function Editor.exportEffect(effect)
		effect = Editor.effect(effect)
		assert(typeof(effect) == "Instance" and effect:IsA("Model"), "LostCube: un efect e un Model")
		local refs = newRefs()
		local ok, result, ignored = pcall(encodeEffect, effect, refs)
		dropRefs(refs)
		if not ok then
			error(result, 0)
		end
		local code, stats = packPayload({ g = Editor.VERSION, fx = result }, LIMITS.codeChars, "efectul " .. effect.Name)
		stats.elements = result.e and #result.e or 0
		stats.ignored = ignored
		return code, stats
	end

	--- importEffect(code, name?, opts?) -> Model, info
	--- Rebuilds an effect from a code made by exportEffect, in ONE undo step. The whole code is validated first (version,
	--- checksum, sizes, every value; unknown or oversized things are refused with a Romanian message) and nothing is created when
	--- anything is wrong. Scripts are never created. `name` replaces the name inside the code. opts: unique = true (the name is
	--- taken: add a number), replace = true (the name is taken: delete the old effect). info = { elements, renamed, clamped, notes }.
	function Editor.importEffect(code, name, opts)
		opts = opts or {}
		local payload, chars = unpackCode(code)
		local kind, list = payloadEffects(payload, chars)
		if kind == "library" then
			error(string.format("LostCube: codul conține o bibliotecă de %d efecte; importă-l cu Editor.importMany (butonul de import al bibliotecii).",
				#list), 0)
		end
		clamped = 0
		local spec = decodeEffect(list[1])
		local info = { elements = #spec.elements, renamed = false, clamped = clamped, notes = {} }
		local wanted = spec.name
		if name ~= nil then
			wanted = trim(tostring(name))
			assert(wanted ~= "", "LostCube: numele efectului nu poate fi gol")
			assert(#wanted <= LIMITS.nameChars, "LostCube: numele efectului e prea lung (maxim 100 de caractere)")
		end
		local folder = Editor.folder(false)
		if folder and folder:FindFirstChild(wanted) and not opts.replace then
			assert(opts.unique, "LostCube: există deja un efect numit " .. wanted .. " (alege alt nume)")
			wanted = freeName(folder, wanted)
			info.renamed = true
		end
		importNotes(info, true)
		return record("importat efect " .. wanted, function()
			local effects = Editor.folder(true)
			local refs = newRefs()
			local ok, model = pcall(buildModel, spec, wanted, refs)
			dropRefs(refs)
			if not ok then
				error(model, 0)
			end
			local old = effects:FindFirstChild(wanted)
			if old and opts.replace then
				old:Destroy()
			end
			assertFreeName(effects, wanted)
			model.Parent = effects
			return model, info
		end)
	end

	--- exportAll(list?) -> code, stats
	--- A whole library in one code (all the effects of ReplicatedStorage.LostCube.Effects, or the Models / names in `list`).
	function Editor.exportAll(list)
		local effects = {}
		for _, item in (list or Editor.effects()) do
			table.insert(effects, Editor.effect(item))
		end
		assert(#effects > 0, "LostCube: nu există efecte de exportat")
		assert(#effects <= LIMITS.effects, string.format("LostCube: biblioteca are %d efecte; un cod poate avea cel mult %d",
			#effects, LIMITS.effects))
		local refs = newRefs()
		local ignored = 0
		local ok, result = pcall(function()
			local out = {}
			for _, fx in effects do
				local encoded, skipped = encodeEffect(fx, refs)
				table.insert(out, encoded)
				ignored += skipped
			end
			return out
		end)
		dropRefs(refs)
		if not ok then
			error(result, 0)
		end
		local code, stats = packPayload({ g = Editor.VERSION, lib = result }, LIMITS.libraryChars, "biblioteca")
		stats.effects = #result
		stats.ignored = ignored
		return code, stats
	end

	--- importMany(code, opts?) -> { Model }, info
	--- A library code (or a single-effect code) -> all its effects, in ONE undo step. A name already taken gets a number
	--- (opts.replace = true deletes the old effect instead). info = { count, renamed = { names }, clamped, notes }.
	function Editor.importMany(code, opts)
		opts = opts or {}
		local payload, chars = unpackCode(code)
		local _, list = payloadEffects(payload, chars)
		clamped = 0
		local specs = {}
		for i, raw in list do
			specs[i] = decodeEffect(raw)
		end
		local info = { count = #specs, renamed = {}, clamped = clamped, notes = {} }
		importNotes(info, false)
		return record("importat " .. #specs .. " efecte", function()
			local effects = Editor.folder(true)
			local refs = newRefs()
			local made = {}
			local ok, err = pcall(function()
				for _, spec in specs do
					local wanted = spec.name
					if not opts.replace then
						wanted = freeName(effects, wanted)
						if wanted ~= spec.name then
							table.insert(info.renamed, spec.name .. " → " .. wanted)
						end
					end
					local model = buildModel(spec, wanted, refs)
					table.insert(made, model)
					local old = effects:FindFirstChild(wanted)
					if old and opts.replace then
						old:Destroy()
					end
					assertFreeName(effects, wanted)
					model.Parent = effects
				end
			end)
			dropRefs(refs)
			if not ok then
				for _, model in made do
					model:Destroy()
				end
				error(err, 0)
			end
			if #info.renamed > 0 then
				table.insert(info.notes, #info.renamed .. " efecte aveau numele ocupat și au primit alt nume.")
			end
			return made, info
		end)
	end

	--- describeCode(code) -> info | nil, message
	--- Checks a code without creating anything: info = { kind = "effect" | "library", effects = { { name, duration, attach,
	--- elements, kinds } }, chars, generator, clamped }; on a bad code nil and the Romanian message.
	function Editor.describeCode(code)
		local ok, info = pcall(function()
			local payload, chars = unpackCode(code)
			local kind, list = payloadEffects(payload, chars)
			clamped = 0
			local effects = {}
			for i, raw in list do
				local spec = decodeEffect(raw)
				local kinds = {}
				for _, element in spec.elements do
					kinds[element.kind] = (kinds[element.kind] or 0) + 1
				end
				effects[i] = { name = spec.name, duration = spec.attrs.LC_Duration, attach = spec.attrs.LC_Attach,
					elements = #spec.elements, kinds = kinds }
			end
			return { kind = kind, effects = effects, chars = chars, clamped = clamped,
				generator = type(payload.g) == "string" and shortenText(payload.g, 20) or nil }
		end)
		if ok then
			return info
		end
		return nil, tostring(info)
	end

	--- packCode(payload) -> code / unpackCode(code) -> payload
	--- The low level of the codes: a table of strings / numbers / booleans / arrays <-> "LC1:..." text (checksum, compression and
	--- the size limits included). For tools that make or read codes themselves; effects go through exportEffect / importEffect.
	function Editor.packCode(payload)
		return (packPayload(payload, LIMITS.libraryChars, "conținutul"))
	end

	function Editor.unpackCode(code)
		return (unpackCode(code))
	end
end

do
	-- ---------------------------------------------------------------------------------------------
	-- palette: recolour an existing effect, colours that read well on the map, scale, variants
	-- ---------------------------------------------------------------------------------------------
	local TAU = math.pi * 2
	local NEUTRAL_SAT, NEUTRAL_VAL = 0.12, 0.16 -- below these a colour is white / grey / near-black and is never recoloured (as in the templates)

	local function hueDegrees(c)
		return (c:ToHSV()) * 360
	end

	-- 0..180
	local function hueDistance(a, b)
		local d = math.abs(a - b) % 360
		return d > 180 and 360 - d or d
	end

	local function toLinear(x)
		x = math.clamp(x, 0, 1)
		if x <= 0.04045 then
			return x / 12.92
		end
		return ((x + 0.055) / 1.055) ^ 2.4
	end

	-- OKLab (perceptually even: equal distances look equally different) -> L (0..1), a, b
	local function oklab(c)
		local r, g, b = toLinear(c.R), toLinear(c.G), toLinear(c.B)
		local l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ^ (1 / 3)
		local m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ^ (1 / 3)
		local s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ^ (1 / 3)
		return 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s, 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
			0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
	end

	--- colorDistance(a, b) -> number: how different two colours look (OKLab distance: ~0.02 is barely visible, 0.14 clearly
	--- different, 0.4+ very different).
	function Editor.colorDistance(a, b)
		local l1, a1, b1 = oklab(a)
		local l2, a2, b2 = oklab(b)
		return math.sqrt((l1 - l2) ^ 2 + (a1 - a2) ^ 2 + (b1 - b2) ^ 2)
	end

	local COLOR_WORDS = { red = { "roșu", "roșul" }, orange = { "portocaliu", "portocaliul" }, brown = { "maro", "maroul" },
		yellow = { "galben", "galbenul" }, green = { "verde", "verdele" }, turquoise = { "turcoaz", "turcoazul" },
		blue = { "albastru", "albastrul" }, violet = { "violet", "violetul" }, pink = { "roz", "rozul" }, black = { "negru", "negrul" },
		white = { "alb", "albul" }, grey = { "gri", "griul" }, darkGrey = { "gri închis", "griul închis" } }

	local function colorWord(c)
		local h, s, v = c:ToHSV()
		h *= 360
		if v < 0.2 then
			return COLOR_WORDS.black
		elseif s < NEUTRAL_SAT then
			return v > 0.85 and COLOR_WORDS.white or (v > 0.45 and COLOR_WORDS.grey or COLOR_WORDS.darkGrey)
		elseif h < 15 or h >= 345 then
			return COLOR_WORDS.red
		elseif h < 40 then
			return v < 0.6 and COLOR_WORDS.brown or COLOR_WORDS.orange
		elseif h < 70 then
			return COLOR_WORDS.yellow
		elseif h < 160 then
			return COLOR_WORDS.green
		elseif h < 200 then
			return COLOR_WORDS.turquoise
		elseif h < 255 then
			return COLOR_WORDS.blue
		elseif h < 290 then
			return COLOR_WORDS.violet
		end
		return COLOR_WORDS.pink
	end

	--- colorName(color) -> "verde", "albastru", "gri"... (Romanian name of a colour, for labels)
	function Editor.colorName(color)
		return colorWord(color)[1]
	end

	-- a colour given as Color3, "RRGGBB" / "#RRGGBB" or { hex = "RRGGBB" } -> Color3?
	local function asColor(v)
		if typeof(v) == "Color3" then
			return v
		end
		local hex = type(v) == "string" and v or (type(v) == "table" and type(v.hex) == "string" and v.hex) or nil
		if hex then
			hex = string.gsub(hex, "^#", "")
			if string.match(hex, "^%x%x%x%x%x%x$") then
				return Color3.fromHex(hex)
			end
		end
		return nil
	end

	local function targetList(color)
		local out = {}
		if typeof(color) == "Color3" or type(color) == "string" then
			out[1] = asColor(color)
		elseif type(color) == "table" then
			if asColor(color) and type(color.hex) == "string" then
				out[1] = asColor(color)
			else
				for _, item in color do
					if #out >= 4 then
						break
					end
					table.insert(out, asColor(item))
				end
			end
		end
		assert(#out > 0, "LostCube: dă o culoare (Color3 sau hex) sau o listă de culori")
		for _, c in out do
			assert(typeof(c) == "Color3", "LostCube: culoarea trebuie să fie un Color3 sau un hex #RRGGBB")
		end
		return out
	end

	-- every colour of an effect: { inst, prop, attr?, value = Color3 | ColorSequence, weight }
	local function colorSlots(effect)
		local slots = {}
		for _, el in Editor.elements(effect) do
			local kind = Editor.kindOf(el)
			if kind == "PARTICLES" or kind == "TRAIL" or kind == "BEAM" then
				table.insert(slots, { inst = el, prop = "Color", value = el.Color, weight = 1 })
			elseif kind == "LIGHT" then
				table.insert(slots, { inst = el, prop = "Color", value = el.Color, weight = 0.6 })
			elseif kind == "MESH" then
				table.insert(slots, { inst = el, prop = "Color", value = el.Color, weight = 1 })
				local fin = el:GetAttribute("LC_ColorEnd")
				if typeof(fin) == "Color3" then
					table.insert(slots, { inst = el, prop = "LC_ColorEnd", attr = true, value = fin, weight = 0.5 })
				end
			elseif kind == "CAMERA" then
				local flash = el:GetAttribute("LC_Flash")
				if typeof(flash) == "Color3" then
					table.insert(slots, { inst = el, prop = "LC_Flash", attr = true, value = flash, weight = 0.3 })
				end
			end
		end
		return slots
	end

	-- the hue groups of a list of { color, weight }: up to k centres { color, hue (degrees), weight }, the heaviest first. The hue
	-- circle is cut in 24 slices; a group is a peak and the slices next to it (30 degrees each way).
	local function hueGroups(samples, k)
		local bins, total = {}, 0
		for i = 0, 23 do
			bins[i] = 0
		end
		for _, smp in samples do
			local h, s, v = smp.color:ToHSV()
			if s >= NEUTRAL_SAT and v >= NEUTRAL_VAL then
				local w = smp.weight * s * v
				bins[math.floor(h * 24) % 24] += w
				total += w
			end
		end
		local groups = {}
		if total <= 0 then
			return groups
		end
		for _ = 1, k do
			local best, bestScore = nil, 0
			for i = 0, 23 do
				local score = bins[i] + 0.5 * (bins[(i - 1) % 24] + bins[(i + 1) % 24])
				if score > bestScore then
					best, bestScore = i, score
				end
			end
			if not best or bestScore <= 0 or (#groups > 0 and bestScore < total * 0.08) then
				break
			end
			local sx, sy, ss, sv, sw = 0, 0, 0, 0, 0
			for _, smp in samples do
				local h, s, v = smp.color:ToHSV()
				if s >= NEUTRAL_SAT and v >= NEUTRAL_VAL then
					local bin = math.floor(h * 24) % 24
					if math.min((bin - best) % 24, (best - bin) % 24) <= 2 then
						local w = smp.weight * s * v
						sx += math.cos(h * TAU) * w
						sy += math.sin(h * TAU) * w
						ss += s * w
						sv += v * w
						sw += w
					end
				end
			end
			local hue = (math.atan2(sy, sx) / TAU) % 1
			table.insert(groups, { color = Color3.fromHSV(hue, ss / sw, sv / sw), hue = hue * 360, weight = sw / total })
			for d = -2, 2 do
				bins[(best + d) % 24] = 0
			end
		end
		return groups
	end

	local function colorSamples(slots)
		local samples = {}
		for _, slot in slots do
			local v = slot.value
			if typeof(v) == "Color3" then
				table.insert(samples, { color = v, weight = slot.weight })
			else
				local k = v.Keypoints
				for _, kp in k do
					table.insert(samples, { color = kp.Value, weight = slot.weight / #k })
				end
			end
		end
		return samples
	end

	local function colorKey(v)
		local function one(c)
			return string.format("%.5f,%.5f,%.5f", c.R, c.G, c.B)
		end
		if typeof(v) == "Color3" then
			return one(v)
		end
		local out = {}
		for _, kp in v.Keypoints do
			table.insert(out, string.format("%.4f:%s", kp.Time, one(kp.Value)))
		end
		return table.concat(out, ";")
	end

	-- moves the colours of an effect to `targets` (see Editor.recolorEffect); no undo recording
	local function recolorInto(effect, targets, opts)
		local slots = colorSlots(effect)
		local groups
		if opts.from ~= nil then
			groups = {}
			for _, c in targetList(opts.from) do
				table.insert(groups, { color = c, hue = hueDegrees(c), weight = 1 })
			end
		else
			groups = hueGroups(colorSamples(slots), #targets)
		end
		local info = { slots = #slots, changed = 0, to = targets, from = {} }
		for i, g in groups do
			info.from[i] = g.color
		end
		if #groups == 0 then
			info.neutral = true -- only white / grey / black: nothing to recolour
			return info
		end
		local function move(c)
			local h, s, v = c:ToHSV()
			if s < NEUTRAL_SAT or v < NEUTRAL_VAL then
				return c
			end
			local index = 1
			if #groups > 1 and #targets > 1 then -- several targets: each hue group goes to its own target
				local nearest = 361
				for i, g in groups do
					local d = hueDistance(h * 360, g.hue)
					if i <= #targets and d < nearest then
						nearest, index = d, i
					end
				end
			end
			return shiftColor(c, groups[index].color, targets[math.min(index, #targets)])
		end
		for _, slot in slots do
			local moved = mapColors(slot.value, move)
			if colorKey(moved) ~= colorKey(slot.value) then
				if slot.attr then
					slot.inst:SetAttribute(slot.prop, moved)
				else
					(slot.inst :: any)[slot.prop] = moved
				end
				info.changed += 1
			end
		end
		return info
	end

	--- recolorEffect(effect, color | { colors }, opts?) -> effect, info
	--- Moves the whole effect to another colour, like the colour of a template: one main colour is found in the effect and every
	--- colour turns by the same hue angle (accents keep their relation to it), saturation and brightness follow; whites, greys and
	--- near-blacks stay. A list of 2-4 colours sends the effect's hue groups (the heaviest first) to those colours one by one.
	--- Particles, trails, beams, lights, 3D pieces (and their end colour) and camera flashes are recoloured. One undo step.
	--- opts.from (Color3 or a list) names the colour(s) to move instead of finding them. info = { changed, slots, from, to, neutral }.
	function Editor.recolorEffect(effect, color, opts)
		effect = Editor.effect(effect)
		local targets = targetList(color)
		opts = opts or {}
		return record("recolorat " .. effect.Name, function()
			return effect, recolorInto(effect, targets, opts)
		end)
	end

	-- the palette of a map: a list of colours (Color3, "RRGGBB", { hex, share } as the analysis stores them, or { color, share }) ->
	-- { { color, w (weights add up to 1), L, a, b } }
	local function normalizePalette(palette)
		assert(type(palette) == "table" and #palette > 0, "LostCube: paleta hărții e goală")
		local out, total = {}, 0
		for i, item in palette do
			if i > 24 then
				break
			end
			local color = asColor(type(item) == "table" and item.color or item)
			if color then
				local share = type(item) == "table" and (tonumber(item.share) or tonumber(item.weight)) or nil
				local w = share and math.max(share, 0.01) or 1
				local l, a, b = oklab(color)
				table.insert(out, { color = color, w = w, L = l, a = a, b = b, chroma = math.sqrt(a * a + b * b),
					hue = math.deg(math.atan2(b, a)) % 360 })
				total += w
			end
		end
		assert(#out > 0, "LostCube: paleta hărții nu conține nicio culoare validă")
		for _, swatch in out do
			swatch.w /= total
		end
		return out
	end

	--- paletteOf(report) -> palette, mood
	--- The colours of the map from the stored analysis (Analyzer.load()): palette = { { color, share } } (dominant surface
	--- colours and the atmosphere), mood = { night = true / false (nil when the time of day is unknown), clockTime }. For
	--- suggestColors / matchPalette.
	function Editor.paletteOf(report)
		local style = type(report) == "table" and report.style or nil
		assert(type(style) == "table", "LostCube: analiza jocului nu are partea de stil vizual")
		local palette = {}
		for _, c in (style.colors or {}) do
			local color = asColor(c)
			if color then
				table.insert(palette, { color = color, share = tonumber(c.share) or 1 })
			end
		end
		local atmosphere = style.atmosphere
		local fog = atmosphere and asColor(atmosphere.color)
		if fog then
			table.insert(palette, { color = fog, share = 8 })
		end
		assert(#palette > 0, "LostCube: analiza nu conține culorile hărții (rulează din nou analiza jocului)")
		local clock = type(style.lighting) == "table" and tonumber(style.lighting.clockTime) or nil
		local night -- nil = unknown: suggestColors then judges by the brightness of the map
		if clock ~= nil then
			night = clock < 5.5 or clock >= 18.5
		end
		return palette, { night = night, clockTime = clock }
	end

	--- suggestColors(palette, opts?) -> { { color, hex, reason } }
	--- 3-5 effect colours that read well against the map: far from its dominant colours (never a colour that melts into the
	--- ground), with enough contrast in brightness, vivid, and in a classic relation to the main hue of the map (complementary,
	--- split-complementary, triad, or analogous but brighter). The best first; `reason` is a short Romanian sentence.
	--- opts: count (3..5, default 4), night (true: the map is dark, bright colours glow more; see paletteOf).
	function Editor.suggestColors(palette, opts)
		opts = opts or {}
		local pal = normalizePalette(palette)
		local count = math.clamp(math.floor(tonumber(opts.count) or 4), 3, 5)
		-- what the map looks like: mean lightness, mean chroma, the heaviest chromatic hue
		local meanL, meanC, hx, hy, dominant = 0, 0, 0, 0, pal[1]
		for _, swatch in pal do
			meanL += swatch.w * swatch.L
			meanC += swatch.w * swatch.chroma
			hx += math.cos(math.rad(swatch.hue)) * swatch.w * swatch.chroma
			hy += math.sin(math.rad(swatch.hue)) * swatch.w * swatch.chroma
			if swatch.w * (swatch.chroma + 0.02) > dominant.w * (dominant.chroma + 0.02) then
				dominant = swatch
			end
		end
		local chromatic = meanC > 0.035
		local mainHue = math.deg(math.atan2(hy, hx)) % 360
		-- the colour whose name the reasons use: the heaviest of the chromatic ones
		local named = dominant
		for _, swatch in pal do
			if swatch.chroma > 0.04 and swatch.w * swatch.chroma > named.w * named.chroma * 1.0001 then
				named = swatch
			end
		end
		local night = opts.night == true or (opts.night == nil and meanL < 0.35)

		local candidates = {}
		for hue = 0, 345, 15 do
			for _, sv in { { 1, 1 }, { 0.75, 1 }, { 0.5, 1 } } do -- (always bright: effects glow, a dark colour adds little light)
				local color = Color3.fromHSV(hue / 360, sv[1], sv[2])
				local l, a, b = oklab(color)
				local chroma = math.sqrt(a * a + b * b)
				local ok = math.deg(math.atan2(b, a)) % 360
				local sep, closest, closestDominant = 0, 9, 9
				for _, swatch in pal do
					local d = math.sqrt((l - swatch.L) ^ 2 + (a - swatch.a) ^ 2 + (b - swatch.b) ^ 2)
					sep += swatch.w * math.min(d / 0.3, 1)
					closest = math.min(closest, d)
					if swatch.w >= 0.08 then
						closestDominant = math.min(closestDominant, d)
					end
				end
				if closestDominant == 9 then
					closestDominant = closest
				end
				local lum = math.min(math.abs(l - meanL) / 0.35, 1)
				local vivid = math.min(chroma / 0.15, 1)
				local gap = hueDistance(ok, mainHue)
				local comp = math.max(0, 1 - math.abs(gap - 180) / 35)
				local split = math.max(0, 1 - math.abs(gap - 150) / 25)
				local triad = math.max(0, 1 - math.abs(gap - 120) / 20)
				local analog = gap <= 45 and math.max(0, 1 - math.abs(gap - 28) / 28) * (lum >= 0.5 and 1 or 0.3) or 0
				local harmony = chromatic and math.max(comp, 0.8 * split, 0.6 * triad, 0.5 * analog) or 0.5
				local mood = night and 0.1 * math.min(l / 0.9, 1) or 0.1 * vivid
				local score = 0.4 * sep + 0.2 * lum + 0.25 * harmony + 0.1 * vivid + mood
					- math.max(0, 0.14 - closestDominant) * 8
				table.insert(candidates, { color = color, score = score, hue = ok, L = l, comp = comp, split = split, triad = triad,
					gap = gap, closest = closestDominant })
			end
		end
		table.sort(candidates, function(x, y)
			return x.score > y.score
		end)

		local picked = {}
		local function take(strict)
			for _, c in candidates do
				if #picked >= count then
					return
				end
				local fine = c.closest >= 0.14 or not strict
				for _, other in picked do
					if hueDistance(c.hue, other.hue) < 40 then
						fine = false
					end
				end
				if fine and not table.find(picked, c) then
					table.insert(picked, c)
				end
			end
		end
		take(true)
		take(false) -- a map that covers the whole colour wheel: the best of what is left

		local out = {}
		local word = colorWord((chromatic and named or dominant).color)[2]
		for i, c in picked do
			local reason
			if not chromatic then
				reason = string.format("Harta e aproape fără culoare (%s): o culoare vie se vede de departe.", word)
			elseif c.comp >= 0.55 then
				reason = string.format("Complementară cu %s dominant al hărții: iese clar în evidență.", word)
			elseif c.split >= 0.55 then
				reason = string.format("Aproape complementară cu %s al hărții: contrast puternic, dar mai blând.", word)
			elseif c.triad >= 0.5 then
				reason = string.format("În triadă cu %s al hărții: contrast bun și rămâne armonioasă.", word)
			elseif c.gap <= 50 then
				reason = string.format("Analogă cu %s al hărții, dar mai %s: se potrivește cu atmosfera.", word,
					c.L > meanL and "luminoasă" or "intensă")
			else
				reason = "Contrast bun cu paleta hărții."
			end
			if c.L - meanL >= 0.25 and meanL < 0.45 then
				reason ..= " Strălucește pe fundalul întunecat."
			elseif meanL - c.L >= 0.2 and meanL > 0.65 then
				reason ..= " Se vede bine pe fundalul deschis."
			end
			out[i] = { color = c.color, hex = "#" .. string.upper(c.color:ToHex()), reason = reason }
		end
		return out
	end

	--- matchPalette(effect, palette, opts?) -> color, reason, info
	--- Picks the colour from suggestColors(palette) that reads best against the map and recolours the effect to it (one undo
	--- step). opts: pick (2..5: take the second, third... suggestion), night, and the options of recolorEffect.
	function Editor.matchPalette(effect, palette, opts)
		opts = opts or {}
		effect = Editor.effect(effect)
		local pick = math.clamp(math.floor(tonumber(opts.pick) or 1), 1, 5)
		local list = Editor.suggestColors(palette, { count = 5, night = opts.night })
		local chosen = list[math.min(pick, #list)]
		local _, info = Editor.recolorEffect(effect, chosen.color, opts)
		return chosen.color, chosen.reason, info
	end

	-- scale ---------------------------------------------------------------------------------------------------------------------------
	local function scaleFrame(cf, k)
		return (cf - cf.Position) + cf.Position * k
	end

	local function scalePair(inst, attr, k)
		local v = parseList(inst:GetAttribute(attr))[1]
		if v then
			inst:SetAttribute(attr, string.format("%s,%s", round(v[1] * k), round((v[2] or v[1]) * k)))
		end
	end

	local function scaleNumber(inst, attr, k)
		local v = inst:GetAttribute(attr)
		if type(v) == "number" then
			inst:SetAttribute(attr, round(v * k))
		end
	end

	-- sizes, distances and speeds of an effect already built (what scaleProps does to the properties of a template)
	local function scaleInto(effect, k)
		local root = rootOf(effect)
		local function moveHolder(mount)
			if mount:IsA("Attachment") then
				mount.CFrame = scaleFrame(mount.CFrame, k)
			elseif mount:IsA("BasePart") and mount ~= root then
				mount.Size = Vector3.new(math.clamp(mount.Size.X * k, 0.001, 2048), math.clamp(mount.Size.Y * k, 0.001, 2048),
					math.clamp(mount.Size.Z * k, 0.001, 2048))
				mount.CFrame = root.CFrame * scaleFrame(frameIn(root, mount), k)
			end
		end
		for _, el in Editor.elements(effect) do
			local kind = Editor.kindOf(el)
			if kind == "PARTICLES" then
				el.Size = mulSpec(el.Size, k)
				el.Speed = mulSpec(el.Speed, k)
				el.Acceleration = el.Acceleration * k
				moveHolder(el.Parent)
			elseif kind == "LIGHT" then
				el.Range = math.clamp(el.Range * k, 0, 120)
				local keys = parseList(el:GetAttribute("LC_Keys"))
				if #keys > 0 then
					local parts = {}
					for _, key in keys do
						table.insert(parts, string.format("%s,%s,%s", round(key[1]), round(key[2] or 0, 3), round((key[3] or 0) * k, 3)))
					end
					el:SetAttribute("LC_Keys", table.concat(parts, ";"))
				end
				moveHolder(el.Parent)
			elseif kind == "TRAIL" or kind == "BEAM" then
				for _, att in { el.Attachment0, el.Attachment1 } do
					moveHolder(att)
				end
				if kind == "TRAIL" then
					el.MinLength *= k
					el.MaxLength *= k
				else
					el.Width0 *= k
					el.Width1 *= k
					el.CurveSize0 *= k
					el.CurveSize1 *= k
					scaleNumber(el, "LC_Jitter", k)
				end
			elseif kind == "MESH" then
				el.Size = Vector3.new(math.clamp(el.Size.X * k, 0.001, 2048), math.clamp(el.Size.Y * k, 0.001, 2048),
					math.clamp(el.Size.Z * k, 0.001, 2048))
				el.CFrame = root.CFrame * scaleFrame(frameIn(root, el), k)
				scalePair(el, "LC_Radius", k)
				scalePair(el, "LC_Speed", k)
				scaleNumber(el, "LC_Rise", k)
				scaleNumber(el, "LC_Jitter", k)
			elseif kind == "SOUND" then
				moveHolder(el.Parent)
			elseif kind == "CAMERA" then
				moveHolder(el.Parent)
				scaleNumber(el, "LC_Radius", k)
			end
		end
	end

	--- scaleEffect(effect, factor) -> effect
	--- Makes an effect bigger (factor > 1) or smaller: element sizes, distances, speeds, light ranges, beam widths, 3D pieces, camera
	--- radius. factor between 0.05 and 20; one undo step.
	function Editor.scaleEffect(effect, factor)
		assert(type(factor) == "number" and factor >= 0.05 and factor <= 20, "LostCube: scara trebuie să fie între 0.05 și 20")
		effect = Editor.effect(effect)
		return record(string.format("scară x%.2f pe %s", factor, effect.Name), function()
			scaleInto(effect, factor)
			return effect
		end)
	end

	--- makeVariants(effect, opts) -> { Model }
	--- Copies of an effect in other colours (teams, rarities, elements), in ONE undo step. opts:
	---   count    1..12 (default 3)
	---   hueStep  degrees between the main colour of one copy and the next (default 360 / (count + 1): evenly around the wheel)
	---   colors   { Color3 }: exact main colours instead of a hue step (count = #colors)
	---   scale    size factor applied once more per copy (1.25: x1.25, x1.56, ...; default 1 = same size)
	---   names    { string }: the names of the copies (default: "<effect> <colour name>")
	--- Names are always free (a taken one gets a number).
	function Editor.makeVariants(effect, opts)
		opts = opts or {}
		effect = Editor.effect(effect)
		local colors = opts.colors
		local count = colors and #colors or math.floor(tonumber(opts.count) or 3)
		assert(count >= 1 and count <= LIMITS.variants, "LostCube: numărul de variante trebuie să fie între 1 și " .. LIMITS.variants)
		local hueStep = tonumber(opts.hueStep) or 360 / (count + 1)
		local step = tonumber(opts.scale) or 1
		assert(step >= 0.05 and step <= 20 and step ^ count <= 20 and step ^ count >= 0.05,
			"LostCube: scara variantelor trebuie să rămână între 0.05 și 20")
		local targets = {}
		for i = 1, count do
			if colors then
				targets[i] = targetList(colors[i])[1]
			end
		end
		return record("variante pentru " .. effect.Name, function()
			local group = hueGroups(colorSamples(colorSlots(effect)), 1)[1]
			assert(group, "LostCube: efectul " .. effect.Name .. " nu are culori de schimbat (doar alb / gri / negru)")
			local h, s, v = group.color:ToHSV()
			local folder = effect.Parent
			local out = {}
			for i = 1, count do
				local target = targets[i] or Color3.fromHSV((h + i * hueStep / 360) % 1, s, v)
				local copy = effect:Clone()
				local name = opts.names and opts.names[i] and trim(tostring(opts.names[i])) or nil
				if not name or name == "" then
					name = effect.Name .. " " .. colorWord(target)[1]
				end
				copy.Name = freeName(folder, string.sub(name, 1, LIMITS.nameChars - 8))
				recolorInto(copy, { target }, { from = group.color })
				if step ~= 1 then
					scaleInto(copy, step ^ i)
				end
				copy.Parent = folder
				out[i] = copy
			end
			return out
		end)
	end
end

Editor.VFX = VFX
return Editor
