-- LostCube theme: semantic colour tokens read from the Studio theme (Light and Dark), live re-skin when Studio switches
-- theme, the type scale (FontFace per role) and the spacing / radius / motion constants. Every colour the UI paints comes
-- from Theme.tokens (UI.C is the same set plus the 2.0 names); nothing is hard-coded in the components.
--
--   Theme.tokens.text                      a Color3, always the current theme (the table is updated in place)
--   Theme.bind(inst, { TextColor3 = "text" })  paints now and re-paints on a theme change (weak registry, cheap)
--   Theme.onChanged(fn) -> { Disconnect }  called after the tokens changed (App re-renders the panels)
--   Theme.face("Medium") -> Font            Builder Sans FontFace (nil outside Roblox: use Theme.enumFont)
--   Theme.force("Light" | "Dark" | nil)    previews / tests: the built-in palette instead of Studio's
local Theme = {}

-- ---------------------------------------------------------------------------------------------
-- scale (4 px grid)
-- ---------------------------------------------------------------------------------------------
Theme.SPACE = { xxs = 2, xs = 4, sm = 8, md = 12, lg = 16, xl = 24 }
Theme.RADIUS = { control = 4, surface = 6, pill = 999 }
Theme.HEIGHT = { compact = 24, regular = 28, header = 40, tabs = 32, row = 28 }
Theme.PAD = 12 -- panel padding
Theme.LABEL_W = 96 -- label column of UI.row / UI.scrub
Theme.ICON = 16 -- glyph size
Theme.MOTION = { fast = 0.08, base = 0.12, slow = 0.15 } -- seconds, Quad Out

-- the type scale: 11 meta / section labels, 12 body and controls, 13 emphasis, 15 panel title
Theme.TYPE = {
	caps = { size = 11, weight = "Bold" }, -- uppercase section labels (dim)
	meta = { size = 11, weight = "Regular" }, -- hints, counts, versions, notes on the right of a row
	body = { size = 12, weight = "Regular" }, -- text, field values, labels of a row
	control = { size = 12, weight = "Medium" }, -- buttons, tabs, menu items
	emphasis = { size = 13, weight = "Medium" }, -- list names, empty-state titles
	title = { size = 15, weight = "Bold" }, -- panel title (UI.header)
	code = { size = 12, weight = "Regular", mono = true },
}
Theme.FAMILY = "rbxasset://fonts/families/BuilderSans.json" -- Studio content: fonts/families/BuilderSans.json
Theme.MONO_FAMILY = "rbxasset://fonts/families/BuilderMono.json" -- Studio content: fonts/families/BuilderMono.json

-- ---------------------------------------------------------------------------------------------
-- tokens: where each one comes from in the Studio theme, plus the built-in palettes (outside Studio, in tests, and as
-- the fallback of a colour the theme cannot give)
-- ---------------------------------------------------------------------------------------------
local Color = Enum.StudioStyleGuideColor
local Mod = Enum.StudioStyleGuideModifier
local SOURCE = {
	bg = { Color.MainBackground },
	header = { Color.Titlebar },
	surface = { Color.Dropdown }, -- floating: menus, popups, toasts, dialogs
	surfaceHover = { Color.Item, Mod.Hover },
	surfacePressed = { Color.Item, Mod.Pressed },
	field = { Color.InputFieldBackground },
	fieldBorder = { Color.InputFieldBorder },
	fieldBorderHover = { Color.InputFieldBorder, Mod.Hover },
	focus = { Color.InputFieldBorder, Mod.Selected },
	border = { Color.Border },
	divider = { Color.Separator },
	button = { Color.Button },
	buttonHover = { Color.Button, Mod.Hover },
	buttonPressed = { Color.Button, Mod.Pressed },
	buttonBorder = { Color.ButtonBorder },
	buttonText = { Color.ButtonText },
	text = { Color.MainText },
	textDim = { Color.SubText },
	textDisabled = { Color.DimmedText },
	textBright = { Color.BrightText },
	accent = { Color.MainButton },
	accentHover = { Color.MainButton, Mod.Hover },
	accentPressed = { Color.MainButton, Mod.Pressed },
	accentText = { Color.DialogMainButtonText },
	link = { Color.LinkText },
	danger = { Color.ErrorText },
	warning = { Color.WarningText },
	scrollbar = { Color.ScrollBar },
	tooltip = { Color.Tooltip },
}

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

-- approximations of Studio's own Dark / Light themes
local PALETTES = {
	Dark = {
		bg = rgb(46, 46, 46), header = rgb(53, 53, 53), surface = rgb(53, 53, 53), surfaceHover = rgb(66, 66, 66),
		surfacePressed = rgb(41, 41, 41), field = rgb(37, 37, 37), fieldBorder = rgb(26, 26, 26),
		fieldBorderHover = rgb(66, 66, 66), focus = rgb(53, 181, 255), border = rgb(34, 34, 34), divider = rgb(34, 34, 34),
		button = rgb(60, 60, 60), buttonHover = rgb(70, 70, 70), buttonPressed = rgb(41, 41, 41), buttonBorder = rgb(34, 34, 34),
		buttonText = rgb(204, 204, 204), text = rgb(204, 204, 204), textDim = rgb(170, 170, 170),
		textDisabled = rgb(102, 102, 102), textBright = rgb(229, 229, 229), accent = rgb(0, 162, 255),
		accentHover = rgb(50, 181, 255), accentPressed = rgb(0, 116, 189), accentText = rgb(255, 255, 255),
		link = rgb(53, 181, 255), danger = rgb(255, 92, 92), warning = rgb(245, 166, 35), scrollbar = rgb(85, 85, 85),
		tooltip = rgb(66, 66, 66), success = rgb(84, 196, 128),
	},
	Light = {
		bg = rgb(255, 255, 255), header = rgb(242, 242, 242), surface = rgb(255, 255, 255), surfaceHover = rgb(232, 232, 232),
		surfacePressed = rgb(219, 219, 219), field = rgb(255, 255, 255), fieldBorder = rgb(182, 182, 182),
		fieldBorderHover = rgb(128, 128, 128), focus = rgb(0, 162, 255), border = rgb(208, 208, 208),
		divider = rgb(227, 227, 227), button = rgb(255, 255, 255), buttonHover = rgb(232, 232, 232),
		buttonPressed = rgb(219, 219, 219), buttonBorder = rgb(182, 182, 182), buttonText = rgb(34, 34, 34),
		text = rgb(34, 34, 34), textDim = rgb(102, 102, 102), textDisabled = rgb(160, 160, 160), textBright = rgb(0, 0, 0),
		accent = rgb(0, 162, 255), accentHover = rgb(50, 181, 255), accentPressed = rgb(0, 116, 189),
		accentText = rgb(255, 255, 255), link = rgb(0, 116, 189), danger = rgb(208, 36, 36), warning = rgb(196, 110, 0),
		scrollbar = rgb(190, 190, 190), tooltip = rgb(255, 255, 255), success = rgb(26, 140, 72),
	},
}

Theme.tokens = {} -- filled by refresh(); the same table forever (components may keep a reference to it)
Theme.dark = true
Theme.name = "Dark"
local tokens = Theme.tokens
local forced = nil -- "Dark" / "Light": ignore Studio (previews, tests)

-- a Color3 (test and preview mocks use tables / userdata with numeric R, G, B)
local function isColor(c)
	if typeof(c) == "Color3" then
		return true
	end
	local ok, numeric = pcall(function()
		return type(c.R) == "number" and type(c.G) == "number" and type(c.B) == "number"
	end)
	return ok and numeric
end

local function mix(a, b, t)
	local ok, c = pcall(function()
		return Color3.new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
	end)
	return ok and c or a
end
Theme.mix = mix

local function isDarkColor(c)
	local ok, dark = pcall(function()
		return 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B < 0.5
	end)
	return not ok or dark == true
end

local function studio()
	local ok, s = pcall(function()
		return settings().Studio
	end)
	if ok and s ~= nil then
		return s
	end
	return nil
end

-- the colour of a token from the Studio theme, or nil
local function fromStudio(theme, source)
	local ok, c = pcall(function()
		if source[2] then
			return theme:GetColor(source[1], source[2])
		end
		return theme:GetColor(source[1])
	end)
	if ok and isColor(c) then
		return c
	end
	return nil
end

-- tokens computed from others: tints of the accent, quiet fills, the switch
local function derive(t, dark)
	t.raised = mix(t.bg, t.text, dark and 0.06 or 0.04) -- quiet fill: notes, chips, progress tracks
	t.raisedStrong = mix(t.field, t.text, dark and 0.16 or 0.1) -- the chosen segment of UI.segmented
	t.accentSoft = mix(t.bg, t.accent, dark and 0.24 or 0.12) -- selected row
	t.accentSoftHover = mix(t.bg, t.accent, dark and 0.32 or 0.18)
	t.dangerSoft = mix(t.bg, t.danger, dark and 0.2 or 0.1)
	t.warningSoft = mix(t.bg, t.warning, dark and 0.18 or 0.1)
	t.successSoft = mix(t.bg, t.success, dark and 0.18 or 0.1)
	t.switchOff = mix(t.bg, t.text, dark and 0.3 or 0.32)
	t.knob = Color3.new(1, 1, 1)
	t.scrim = Color3.new(0, 0, 0)
	t.info = t.accent
end

local listeners = {}
local bound = setmetatable({}, { __mode = "k" }) -- instance -> { Property = token }

local function paint(inst, map)
	for prop, token in map do
		local c = tokens[token]
		if c ~= nil then
			inst[prop] = c
		end
	end
end

-- re-reads the theme; returns true when a token changed
function Theme.refresh()
	local studioTheme = nil
	if not forced then
		local s = studio()
		if s then
			local ok, theme = pcall(function()
				return s.Theme
			end)
			if ok then
				studioTheme = theme
			end
		end
	end
	-- which built-in palette backs this theme: forced, or by the brightness of the Studio background
	local bg = studioTheme and fromStudio(studioTheme, SOURCE.bg)
	local name = forced or ((bg == nil or isDarkColor(bg)) and "Dark" or "Light")
	local palette = PALETTES[name]
	local fresh = {}
	for token, source in SOURCE do
		fresh[token] = (studioTheme and fromStudio(studioTheme, source)) or palette[token]
	end
	fresh.success = palette.success -- Studio has no "success" colour
	local dark = name == "Dark"
	derive(fresh, dark)
	local changed = Theme.name ~= name
	for token, c in fresh do
		if tokens[token] ~= c then
			changed = true
		end
		tokens[token] = c
	end
	Theme.dark, Theme.name = dark, name
	return changed
end

-- after a theme change: re-paint what registered, then tell the listeners (App re-renders the panels)
function Theme.apply()
	for inst, map in bound do
		if inst.Parent ~= nil then
			pcall(paint, inst, map)
		end
	end
	for _, fn in table.clone(listeners) do
		local ok, err = pcall(fn, tokens)
		if not ok then
			warn("LostCube theme:", err)
		end
	end
end

-- paints `inst` from tokens now and again after every theme change. map: { Property = "token" }; calling it again
-- replaces the map (a component that changes state re-binds with its new colours).
function Theme.bind(inst, map)
	bound[inst] = map
	paint(inst, map)
	return inst
end

function Theme.unbind(inst)
	bound[inst] = nil
end

function Theme.onChanged(fn)
	table.insert(listeners, fn)
	return { Disconnect = function()
		local i = table.find(listeners, fn)
		if i then
			table.remove(listeners, i)
		end
	end }
end

-- follow Studio's theme: settings().Studio.ThemeChanged (nothing to follow outside Studio)
local watchConn = nil
function Theme.watch()
	if watchConn then
		return
	end
	local s = studio()
	if not s then
		return
	end
	local ok, conn = pcall(function()
		return s.ThemeChanged:Connect(function()
			if Theme.refresh() then
				Theme.apply()
			end
		end)
	end)
	if ok then
		watchConn = conn
	end
end

function Theme.unwatch()
	if watchConn then
		pcall(function()
			watchConn:Disconnect()
		end)
		watchConn = nil
	end
end

-- "Dark" / "Light": the built-in palette (previews, tests); nil: follow Studio again
function Theme.force(mode)
	forced = mode
	Theme.refresh()
	Theme.apply()
end

-- ---------------------------------------------------------------------------------------------
-- typography
-- ---------------------------------------------------------------------------------------------
local WEIGHTS = { Regular = Enum.FontWeight.Regular, Medium = Enum.FontWeight.Medium, Bold = Enum.FontWeight.Bold }
local ENUM_FONTS = { Regular = Enum.Font.BuilderSans, Medium = Enum.Font.BuilderSansMedium, Bold = Enum.Font.BuilderSansBold }
local faces = {}

-- Builder Sans as a FontFace (Font.new); nil when the Font datatype is missing (outside Roblox)
function Theme.face(weight, mono)
	weight = WEIGHTS[weight] and weight or "Regular"
	local key = (mono and "mono:" or "") .. weight
	if faces[key] == nil then
		local ok, f = pcall(function()
			return Font.new(mono and Theme.MONO_FAMILY or Theme.FAMILY, WEIGHTS[weight])
		end)
		faces[key] = ok and f or false
	end
	return faces[key] or nil
end

-- the closest Enum.Font, for code that still sets .Font
function Theme.enumFont(weight, mono)
	if mono then
		return Enum.Font.Code
	end
	return ENUM_FONTS[weight] or Enum.Font.BuilderSans
end

-- sets the font and size of a text instance (or of a props table for UI.make) for a role of Theme.TYPE;
-- weight overrides the role's weight ("Regular" / "Medium" / "Bold")
function Theme.text(target, role, weight)
	local spec = Theme.TYPE[role] or Theme.TYPE.body
	weight = weight or spec.weight
	local face = Theme.face(weight, spec.mono)
	if face then
		target.FontFace = face
	else
		target.Font = Theme.enumFont(weight, spec.mono)
	end
	target.TextSize = spec.size
	return target
end

Theme.refresh()

return Theme
