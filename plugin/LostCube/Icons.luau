-- LostCube icons: Studio's own glyphs (content/studio_svg_textures, shipped with every Studio) and class icons from
-- StudioService:GetClassIcon. No emoji anywhere in the interface.
--
-- Every path below was checked against rbxManifest.txt of MaximumADHD/Roblox-Client-Tracker (branch `roblox`, commit
-- 41ab074bc29dd2a51a5bb17bc3498e0465842794, Studio 0.742.0.7421053), where they appear as
-- content\studio_svg_textures\<path> (the repo mirrors them under studio-svg-textures/). The same list is kept in
-- plugin/tests/suites/data/studio_icons.luau; the `ui` test suite fails on a path that is not in it.
--
-- Monochrome glyphs use the Dark variant (a light grey #E0E0E0 / #F0F0F0 shape) and are tinted with ImageColor3 from a
-- theme token, so one image works in both themes. Coloured glyphs (alerts) take the variant of the current theme and
-- are not tinted.
--
--   Icons.get(name)           -> { Image, ImageRectOffset, ImageRectSize, tint }   (nil for an unknown name)
--   Icons.class(className)    -> the same shape, never nil (StudioService, then a verified file, then a placeholder)
--   Icons.apply(image, icon)  sets Image / ImageRectOffset / ImageRectSize on an ImageLabel / ImageButton
--   Icons.has(name)           a glyph name (true) or something else, e.g. an old emoji label (false)
--   Icons.draw(parent, name, size, color)  a few glyphs drawn from frames (no image needed): chevron, plus, close,
--                                           check, minus, dot, cube (the LostCube mark)
local Theme = require(script.Parent.Theme)

local Icons = {}

Icons.BASE = "rbxasset://studio_svg_textures/"

-- name -> path under studio_svg_textures (Dark variant, tinted)
Icons.GLYPHS = {
	-- navigation
	chevronRight = "Shared/Ribbon/Dark/Standard/RibbonChevronRightSmall.png",
	chevronDown = "Shared/Navigation/Dark/Standard/DropdownArrow.png",
	chevronLeft = "Shared/Navigation/Dark/Standard/Back.png",
	caretRight = "Shared/Navigation/Dark/Standard/ArrowRight.png",
	caretDown = "Shared/Navigation/Dark/Standard/ArrowDown.png",
	collapseAll = "Shared/Navigation/Dark/Standard/Collapse.png",
	expandAll = "Shared/Navigation/Dark/Standard/Expand.png",
	more = "Shared/Navigation/Dark/Standard/More.png",
	moreVertical = "Shared/Ribbon/Dark/Standard/RibbonMoreSmall.png",
	close = "Shared/Navigation/Dark/Standard/CloseWidget.png",
	-- actions
	plus = "Shared/Navigation/Dark/Standard/AddNoBorder.png",
	search = "Lua/DeveloperFramework/Dark/Standard/Search.png",
	clear = "Lua/FindReplaceAll/Dark/Standard/ClearInput.png",
	copy = "Shared/Clipboard/Dark/Standard/Copy.png",
	duplicate = "Shared/Clipboard/Dark/Standard/Duplicate.png",
	paste = "Shared/Clipboard/Dark/Standard/Paste.png",
	undo = "Shared/Clipboard/Dark/Standard/Undo.png",
	redo = "Shared/Clipboard/Dark/Standard/Redo.png",
	refresh = "Lua/FileSync/Dark/Standard/Refresh.png",
	trash = "Shared/Ribbon/Dark/Standard/RibbonDeleteSmall.png",
	check = "Lua/Tutorials/Dark/Standard/Checkmark.png",
	filter = "Shared/Utility/Dark/Standard/Filter.png",
	history = "Shared/Utility/Dark/Standard/Recent.png",
	open = "Lua/FileSync/Dark/Standard/Open.png",
	import = "Lua/AssetManager/Dark/Standard/Import.png",
	locate = "Shared/Navigation/Dark/Standard/ZoomTo.png",
	grid = "Lua/MaterialPicker/Dark/Standard/Grid.png",
	list = "Lua/MaterialPicker/Dark/Standard/List.png",
	-- media
	play = "Lua/AnimationEditor/Dark/Standard/Preview.png",
	pause = "Shared/Ribbon/Dark/Standard/RibbonPauseSmall.png",
	stop = "Shared/Ribbon/Dark/Standard/RibbonStopInactiveSmall.png",
	toStart = "Lua/AnimationEditor/Dark/Standard/MoveToTheBeginning.png",
	toEnd = "Lua/AnimationEditor/Dark/Standard/MoveToTheEnd.png",
	-- state
	eye = "Lua/AvatarSettings/Dark/Standard/eye-fill-dark.png",
	eyeOff = "Lua/AvatarSettings/Dark/Standard/eye-slash-fill-dark.png",
	info = "Lua/FileSync/Dark/Standard/Info.png",
	help = "Shared/Navigation/Dark/Large/Help.png",
	gear = "Shared/Navigation/Dark/Standard/Settings.png",
	bookmark = "Shared/Utility/Dark/Standard/Bookmark.png",
	script = "Shared/InsertableObjects/Dark/Standard/Script.png",
	runScript = "Shared/WidgetIcons/Dark/Standard/RunScript.png",
	explorer = "Shared/WidgetIcons/Dark/Standard/Explorer.png",
	output = "Shared/WidgetIcons/Dark/Standard/Output.png",
	placeholder = "Shared/Placeholder/Dark/Standard/Placeholder.png",
	-- the tabs
	game = "Shared/WidgetIcons/Dark/Standard/ScriptAnalysis.png",
	effects = "Shared/InsertableObjects/Dark/Standard/SunRaysEffect.png",
	animation = "Shared/WidgetIcons/Dark/Standard/AnimationEditor.png",
	library = "Shared/WidgetIcons/Dark/Standard/Toolbox.png",
	build = "Shared/InsertableObjects/Dark/Standard/Part.png",
	chat = "Shared/WidgetIcons/Dark/Standard/Annotations.png",
	environment = "Shared/InsertableObjects/Dark/Standard/Lighting.png",
	gameui = "Shared/InsertableObjects/Dark/Standard/ScreenGui.png",
	systems = "Shared/InsertableObjects/Dark/Standard/ServerScriptService.png",
}

-- name -> path with %s = "Dark" / "Light" (coloured: the theme's own variant, not tinted)
Icons.COLORED = {
	infoColor = "Shared/Alerts/%s/Standard/Information.png",
	successColor = "Shared/Alerts/%s/Standard/Success.png",
	warningColor = "Shared/Alerts/%s/Standard/Warning.png",
	errorColor = "Shared/Alerts/%s/Standard/Error.png",
}

-- class icons when StudioService cannot be asked (tests, a ScreenGui): Shared/InsertableObjects/<theme>/Standard/<file>
Icons.CLASSES = {
	ParticleEmitter = "ParticleEmitter", PointLight = "PointLight", SpotLight = "SpotLight", SurfaceLight = "SurfaceLight",
	Trail = "Trail", Beam = "Beam", Sound = "Sound", SoundGroup = "SoundGroup", Part = "Part", MeshPart = "MeshPart",
	WedgePart = "WedgePart", UnionOperation = "UnionOperation", SpecialMesh = "SpecialMesh", Model = "Model",
	Folder = "Folder", Script = "Script", LocalScript = "LocalScript", ModuleScript = "ModuleScript",
	Animation = "Animation", KeyframeSequence = "Animation", Keyframe = "Animation", Attachment = "Attachment",
	Humanoid = "Humanoid", Animator = "Animator", AnimationController = "AnimationController", Bone = "Bone",
	Motor6D = "Motor6D", Fire = "Fire", Smoke = "Smoke", Sparkles = "Sparkles", Explosion = "Explosion",
	Highlight = "Highlight", Camera = "Camera", Decal = "Decal", Texture = "Texture", RemoteEvent = "RemoteEvent",
	RemoteFunction = "RemoteFunction", BindableEvent = "BindableEvent", Tool = "Tool", ScreenGui = "ScreenGui",
	Configuration = "Configuration", StringValue = "Value", NumberValue = "Value", IntValue = "Value",
	BoolValue = "BoolValue", Workspace = "Workspace", ReplicatedStorage = "ReplicatedStorage",
	ServerStorage = "ServerStorage", ServerScriptService = "ServerScriptService", Lighting = "Lighting",
	StarterPlayer = "StarterPlayer",
}

-- the toolbar button / plugin actions (32 px, the variant of the current theme)
Icons.TOOLBAR = "Shared/InsertableObjects/%s/Standard/Part@2x.png"

local ZERO = Vector2.zero

-- a Vector2 from GetClassIcon (Roblox: typeof "Vector2"; mocks: anything with numeric X / Y), else (0, 0)
local function vector(v)
	if typeof(v) == "Vector2" then
		return v
	end
	local ok, numeric = pcall(function()
		return type(v.X) == "number" and type(v.Y) == "number"
	end)
	return (ok and numeric) and v or ZERO
end

local function entry(path, tint)
	return { Image = Icons.BASE .. path, ImageRectOffset = ZERO, ImageRectSize = ZERO, tint = tint }
end

function Icons.has(name)
	return type(name) == "string" and (Icons.GLYPHS[name] ~= nil or Icons.COLORED[name] ~= nil)
end

function Icons.get(name)
	local glyph = Icons.GLYPHS[name]
	if glyph then
		return entry(glyph, true)
	end
	local colored = Icons.COLORED[name]
	if colored then
		return entry(string.format(colored, Theme.name), false)
	end
	return nil
end

function Icons.toolbar()
	return Icons.BASE .. string.format(Icons.TOOLBAR, Theme.name)
end

-- StudioService:GetClassIcon returns a dictionary { Image, ImageRectOffset, ImageRectSize } (PluginSecurity)
local studioService = nil
local classCache = {}
local cacheTheme = nil

local function getStudioService()
	if studioService == nil then
		local ok, s = pcall(function()
			return game:GetService("StudioService")
		end)
		studioService = ok and s or false
	end
	return studioService or nil
end

function Icons.class(className)
	if cacheTheme ~= Theme.name then -- the icons of the other theme are other images
		classCache, cacheTheme = {}, Theme.name
	end
	local cached = classCache[className]
	if cached then
		return cached
	end
	local icon = nil
	local service = getStudioService()
	if service then
		local ok, info = pcall(function()
			return service:GetClassIcon(className)
		end)
		if ok and type(info) == "table" and type(info.Image) == "string" and info.Image ~= "" then
			icon = { Image = info.Image, ImageRectOffset = vector(info.ImageRectOffset), ImageRectSize = vector(info.ImageRectSize),
				tint = false }
		end
	end
	if not icon then
		local file = Icons.CLASSES[className]
		if file then
			icon = entry(string.format("Shared/InsertableObjects/%s/Standard/%s.png", Theme.name, file), false)
		else
			icon = entry(Icons.GLYPHS.placeholder, true)
		end
	end
	classCache[className] = icon
	return icon
end

function Icons.apply(image, icon)
	image.Image = icon.Image
	image.ImageRectOffset = icon.ImageRectOffset
	image.ImageRectSize = icon.ImageRectSize
	return image
end

-- ---------------------------------------------------------------------------------------------
-- glyphs drawn from frames: for places where an image cannot be used, and the LostCube mark
-- ---------------------------------------------------------------------------------------------
local function line(holder, x1, y1, x2, y2, width, color)
	local dx, dy = x2 - x1, y2 - y1
	local length = math.sqrt(dx * dx + dy * dy)
	local bar = Instance.new("Frame")
	bar.Name = "Line"
	bar.BorderSizePixel = 0
	bar.BackgroundColor3 = color
	bar.AnchorPoint = Vector2.new(0.5, 0.5)
	bar.Position = UDim2.fromOffset((x1 + x2) / 2, (y1 + y2) / 2)
	bar.Size = UDim2.fromOffset(length + width * 0.5, width)
	bar.Rotation = math.deg(math.atan2(dy, dx))
	bar.Parent = holder
	return bar
end

-- shapes on a 16-unit grid (scaled to `size`)
local SHAPES = {
	chevron = { { 6, 4, 10, 8 }, { 10, 8, 6, 12 } },
	plus = { { 8, 3, 8, 13 }, { 3, 8, 13, 8 } },
	minus = { { 3, 8, 13, 8 } },
	close = { { 4, 4, 12, 12 }, { 12, 4, 4, 12 } },
	check = { { 3.5, 8.5, 6.5, 11.5 }, { 6.5, 11.5, 12.5, 4.5 } },
	-- a wireframe cube: front face, back face, the four edges between them
	cube = { { 2, 6, 11, 6 }, { 11, 6, 11, 15 }, { 11, 15, 2, 15 }, { 2, 15, 2, 6 },
		{ 5, 2, 14, 2 }, { 14, 2, 14, 11 }, { 2, 6, 5, 2 }, { 11, 6, 14, 2 }, { 11, 15, 14, 11 } },
}

function Icons.drawable(name)
	return SHAPES[name] ~= nil
end

-- a transparent Frame of size x size holding the shape; lines are `width` px (default 1.5 at 16 px)
function Icons.draw(parent, name, size, color, width)
	size = size or 16
	local holder = Instance.new("Frame")
	holder.Name = "Glyph"
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Size = UDim2.fromOffset(size, size)
	local k = size / 16
	local w = (width or 1.5) * math.max(1, k * 0.75)
	if name == "dot" then
		local dot = Instance.new("Frame")
		dot.BorderSizePixel = 0
		dot.BackgroundColor3 = color
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.fromScale(0.5, 0.5)
		dot.Size = UDim2.fromOffset(math.floor(6 * k), math.floor(6 * k))
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(1, 0)
		round.Parent = dot
		dot.Parent = holder
	else
		for _, seg in SHAPES[name] or {} do
			line(holder, seg[1] * k, seg[2] * k, seg[3] * k, seg[4] * k, w, color)
		end
	end
	holder.Parent = parent
	return holder
end

return Icons
