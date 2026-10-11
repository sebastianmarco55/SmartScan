-- LostCube UI kit 2.1: the controls every panel is made of, in the style of Studio's own panels (theme colours from
-- Studio, Builder Sans, 4 px grid, flat sections, real switches, Studio glyphs, no emoji). Design rules and the
-- component catalogue: plugin/docs/design.md.
-- Everything is plain Roblox GUI, so the same panels run in the plugin's dock widget and in a ScreenGui.
local Theme = require(script.Parent.Theme)
local Icons = require(script.Parent.Icons)

local UI = {}
local T = Theme.tokens

-- Colour tokens. Live: the values are replaced in place when Studio changes theme (App then re-renders), so read
-- C.x when you paint, do not copy it into a long-lived upvalue. The last eight names are the 2.0 palette, kept so the
-- panels work before they migrate (section = bg, item = raised, hover = surfaceHover, input = field, dim = textDim,
-- accentDark = accentSoft, good = success, warn = warning).
UI.C = {
	bg = T.bg, header = T.header, surface = T.surface, surfaceHover = T.surfaceHover, surfacePressed = T.surfacePressed,
	raised = T.raised, raisedStrong = T.raisedStrong, field = T.field, fieldBorder = T.fieldBorder, fieldBorderHover = T.fieldBorderHover,
	focus = T.focus, border = T.border, divider = T.divider, button = T.button, buttonHover = T.buttonHover,
	buttonPressed = T.buttonPressed, buttonBorder = T.buttonBorder, buttonText = T.buttonText, text = T.text,
	textDim = T.textDim, textDisabled = T.textDisabled, textBright = T.textBright, accent = T.accent,
	accentHover = T.accentHover, accentPressed = T.accentPressed, accentText = T.accentText, accentSoft = T.accentSoft,
	accentSoftHover = T.accentSoftHover, link = T.link, danger = T.danger, dangerSoft = T.dangerSoft,
	warning = T.warning, warningSoft = T.warningSoft, success = T.success, successSoft = T.successSoft, info = T.info,
	scrollbar = T.scrollbar, tooltip = T.tooltip, switchOff = T.switchOff, knob = T.knob, scrim = T.scrim,
	-- 2.0 names
	section = T.bg, item = T.raised, hover = T.surfaceHover, input = T.field, dim = T.textDim, accentDark = T.accentSoft,
	good = T.success, warn = T.warning,
}
local LEGACY = { section = "bg", item = "raised", hover = "surfaceHover", input = "field", dim = "textDim",
	accentDark = "accentSoft", good = "success", warn = "warning" }
local C = UI.C

local function syncPalette()
	for key in C do
		local token = LEGACY[key] or key
		if T[token] ~= nil then
			C[key] = T[token]
		end
	end
end
Theme.onChanged(syncPalette)

-- 2.0 font enums (code that sets .Font itself); new code uses UI.textStyle(inst, role) / Theme.TYPE
UI.FONT = Enum.Font.BuilderSans
UI.FONT_MED = Enum.Font.BuilderSansMedium
UI.FONT_BOLD = Enum.Font.BuilderSansBold
UI.H = Theme.HEIGHT.compact -- control / row height (24)
UI.H_LARGE = Theme.HEIGHT.regular -- 28: primary actions, list rows
UI.LABEL_W = Theme.LABEL_W -- label column of UI.row (96)
UI.SPACE = Theme.SPACE
UI.RADIUS = Theme.RADIUS
UI.TYPE = Theme.TYPE
UI.Theme = Theme
UI.Icons = Icons

local order = 0
local root, overlay, tipLabel, toastHost, catcher
local tipToken
local popupState = nil -- { modal = bool, onCancel = fn } while something floats in the overlay
local dragging = false
local rootConns = {}
UI.collapsed = {} -- section key -> collapsed (survives re-renders; App saves it)
UI.recentColors = {} -- hex strings, newest first (App saves it)

function UI.make(class, props, children)
	local inst = Instance.new(class)
	local parent = props.Parent
	props.Parent = nil
	if inst:IsA("GuiObject") then
		order += 1
		inst.LayoutOrder = order
		inst.BorderSizePixel = 0
	end
	for k, v in props do
		inst[k] = v
	end
	for _, child in children or {} do
		child.Parent = inst
	end
	inst.Parent = parent
	return inst
end
local make = UI.make

-- paints from tokens now and after every theme change: UI.skin(inst, { BackgroundColor3 = "surface" })
UI.skin = Theme.bind
local skin = Theme.bind

-- font + size of a role of UI.TYPE ("caps", "meta", "body", "control", "emphasis", "title", "code") on an instance or
-- on a props table for UI.make; weight overrides ("Regular" / "Medium" / "Bold")
UI.textStyle = Theme.text
local textStyle = Theme.text

-- the token whose colour this is (so a colour passed by a panel still follows the theme), or nil
local function tokenOf(color)
	if color == nil then
		return nil
	end
	for name, value in T do
		if value == color then
			return name
		end
	end
	return nil
end

-- sets prop from a colour or a token name; colours that are tokens stay bound to the theme
local function paintWith(inst, prop, color, default, map)
	map = map or {}
	local token = type(color) == "string" and color or tokenOf(color)
	if token then
		map[prop] = token
	elseif color ~= nil then
		inst[prop] = color
	else
		map[prop] = default
	end
	return map
end

-- ---------------------------------------------------------------------------------------------
-- layout helpers (unchanged signatures)
-- ---------------------------------------------------------------------------------------------
function UI.corner(r)
	return make("UICorner", { CornerRadius = UDim.new(0, r or Theme.RADIUS.control) })
end

-- a 1 px border; color may be a Color3 or a token name ("border" by default), bound to the theme
function UI.stroke(color, thickness)
	local s = make("UIStroke", { Thickness = thickness or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
	local map = paintWith(s, "Color", color, "border")
	if next(map) then
		skin(s, map)
	end
	return s
end

function UI.pad(t, r, b, l)
	return make("UIPadding", { PaddingTop = UDim.new(0, t), PaddingRight = UDim.new(0, r or t),
		PaddingBottom = UDim.new(0, b or t), PaddingLeft = UDim.new(0, l or r or t) })
end

function UI.vlist(gap)
	return make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, gap or 4) })
end

function UI.hlist(gap, fill)
	return make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, gap or 4),
		FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center,
		HorizontalFlex = fill and Enum.UIFlexAlignment.Fill or Enum.UIFlexAlignment.None })
end

-- ---------------------------------------------------------------------------------------------
-- motion: short Quad Out tweens (instant where TweenService is missing, e.g. in tests)
-- ---------------------------------------------------------------------------------------------
local tweenService = nil
local function getTweenService()
	if tweenService == nil then
		local ok, s = pcall(function()
			return game:GetService("TweenService")
		end)
		tweenService = ok and s or false
	end
	return tweenService or nil
end

function UI.animate(inst, props, duration)
	local ts = getTweenService()
	if ts then
		local ok = pcall(function()
			ts:Create(inst, TweenInfo.new(duration or Theme.MOTION.base, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				props):Play()
		end)
		if ok then
			return
		end
	end
	for k, v in props do
		inst[k] = v
	end
end
local animate = UI.animate

-- re-binds the colours of a component for a state and tweens to them
local function restyle(inst, map, duration)
	Theme.bind(inst, map)
	local target = {}
	for prop, token in map do
		target[prop] = T[token]
	end
	animate(inst, target, duration or Theme.MOTION.fast)
end

-- ---------------------------------------------------------------------------------------------
-- icons
-- ---------------------------------------------------------------------------------------------
-- an ImageLabel with a Studio glyph (Icons.GLYPHS), a class icon (opts.class = true) or a drawn glyph.
-- opts: size (16), color (Color3 or token, default "textDim"), rotation, position, anchor
function UI.icon(parent, name, opts)
	opts = opts or {}
	local size = opts.size or Theme.ICON
	local icon = opts.class and Icons.class(name) or Icons.get(name)
	if not icon and Icons.drawable(name) then
		local glyph = Icons.draw(parent, name, size, C.textDim)
		glyph.Position = opts.position or glyph.Position
		return glyph
	end
	icon = icon or Icons.get("placeholder")
	local img = make("ImageLabel", { Name = "Icon", Parent = parent, BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size), ScaleType = Enum.ScaleType.Fit, Rotation = opts.rotation or 0 })
	Icons.apply(img, icon)
	if opts.position then
		img.Position = opts.position
	end
	if opts.anchor then
		img.AnchorPoint = opts.anchor
	end
	if icon.tint then
		local map = paintWith(img, "ImageColor3", opts.color, "textDim")
		if next(map) then
			skin(img, map)
		end
	end
	return img
end

-- ---------------------------------------------------------------------------------------------
-- root, overlay (menus, pickers, dialogs float above everything), tooltip, toasts, drag catcher
-- ---------------------------------------------------------------------------------------------
local UserInputService = nil
pcall(function()
	UserInputService = game:GetService("UserInputService")
end)

local function isEscape(input)
	return input.KeyCode == Enum.KeyCode.Escape
end

local function cancelPopup()
	local state = popupState
	UI.closePopup()
	if state and state.onCancel then
		state.onCancel()
	end
end

-- frees what setRoot connected (App:destroy)
function UI.release()
	for _, c in rootConns do
		pcall(function()
			c:Disconnect()
		end)
	end
	rootConns = {}
	Theme.unwatch()
end

function UI.setRoot(frame)
	UI.release()
	root = frame
	popupState = nil
	Theme.watch()
	overlay = make("TextButton", { Name = "Overlay", Parent = frame, Size = UDim2.fromScale(1, 1), Text = "",
		AutoButtonColor = false, BackgroundTransparency = 1, Visible = false, ZIndex = 50 })
	overlay.MouseButton1Click:Connect(cancelPopup)
	overlay.InputBegan:Connect(function(input)
		if isEscape(input) then
			cancelPopup()
		end
	end)
	toastHost = make("Frame", { Name = "Toasts", Parent = frame, AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -Theme.PAD), Size = UDim2.new(1, -Theme.PAD * 2, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, ZIndex = 45 },
		{ make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8),
			VerticalAlignment = Enum.VerticalAlignment.Bottom }),
		make("UISizeConstraint", { MaxSize = Vector2.new(360, math.huge) }) })
	tipLabel = make("TextLabel", textStyle({ Name = "Tooltip", Parent = frame, Visible = false, ZIndex = 60, Text = "",
		TextWrapped = true, AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.fromOffset(0, 0) }, "meta"),
		{ UI.corner(Theme.RADIUS.control), UI.stroke("border"), UI.pad(4, 8, 4, 8),
		make("UISizeConstraint", { MaxSize = Vector2.new(260, math.huge) }) })
	skin(tipLabel, { BackgroundColor3 = "tooltip", TextColor3 = "text" })
	catcher = make("TextButton", { Name = "DragCatcher", Parent = frame, Size = UDim2.fromScale(1, 1), Text = "",
		AutoButtonColor = false, BackgroundTransparency = 1, Visible = false, ZIndex = 80 })
	if UserInputService then
		pcall(function()
			table.insert(rootConns, UserInputService.InputBegan:Connect(function(input)
				if overlay and overlay.Visible and isEscape(input) then
					cancelPopup()
				end
			end))
		end)
	end
end

local function raise(inst, z)
	for _, child in inst:GetChildren() do
		if child:IsA("GuiObject") then
			child.ZIndex = z
		end
		raise(child, z + 1)
	end
end

-- a hint next to a control after hovering it for a moment (opts.tip of buttons, fields, icon buttons)
function UI.tip(target, text)
	target.MouseEnter:Connect(function()
		local token = {}
		tipToken = token
		task.delay(0.45, function()
			if tipToken ~= token or not tipLabel or not root or not target.Parent then
				return
			end
			local rootPos, rootSize = root.AbsolutePosition, root.AbsoluteSize
			tipLabel.Text = text
			local x = target.AbsolutePosition.X - rootPos.X
			local y = target.AbsolutePosition.Y - rootPos.Y + target.AbsoluteSize.Y + 4
			if y > rootSize.Y - 28 then
				y = target.AbsolutePosition.Y - rootPos.Y - 28
			end
			tipLabel.Position = UDim2.fromOffset(math.max(8, x), y)
			tipLabel.Visible = true
			task.defer(function() -- keep it inside the window once its width is known
				local w = tipLabel.AbsoluteSize.X
				tipLabel.Position = UDim2.fromOffset(math.clamp(x, 8, math.max(8, rootSize.X - w - 8)), y)
			end)
		end)
	end)
	target.MouseLeave:Connect(function()
		tipToken = nil
		if tipLabel then
			tipLabel.Visible = false
		end
	end)
end

function UI.closePopup()
	tipToken = nil
	popupState = nil
	if tipLabel then
		tipLabel.Visible = false
	end
	if not overlay then
		return
	end
	for _, child in overlay:GetChildren() do
		child:Destroy()
	end
	overlay.Visible = false
end

-- a floating surface under (or above) anchor, always inside the window; returns frame, width, height
local function popup(anchor, width, height, state)
	UI.closePopup()
	popupState = state or { modal = false }
	overlay.Visible = true
	local margin = Theme.SPACE.sm
	local rootPos, rootSize = root.AbsolutePosition, root.AbsoluteSize
	width = math.max(80, math.min(width, rootSize.X - margin * 2))
	height = math.max(24, math.min(height, rootSize.Y - margin * 2))
	local ax, ay = anchor.AbsolutePosition.X - rootPos.X, anchor.AbsolutePosition.Y - rootPos.Y
	local y = ay + anchor.AbsoluteSize.Y + 4
	if y + height > rootSize.Y - margin then
		local above = ay - height - 4
		y = above >= margin and above or math.max(margin, rootSize.Y - margin - height)
	end
	local x = math.clamp(ax, margin, math.max(margin, rootSize.X - width - margin))
	local frame = make("Frame", { Name = "Popup", Parent = overlay, Active = true, Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(width, height), ZIndex = 51 }, { UI.corner(Theme.RADIUS.surface), UI.stroke("border") })
	skin(frame, { BackgroundColor3 = "surface" })
	return frame, width, height
end

-- a raw floating surface for custom content (closes on outside click / Escape)
function UI.popover(anchor, width, height)
	return popup(anchor, width, height)
end

-- drag: shows the full-window catcher, calls onMove(position) on every mouse move and onEnd(position) on release
local function beginDrag(onMove, onEnd)
	if not catcher then
		return
	end
	catcher.Visible = true
	dragging = true
	local conns = {}
	local finished = false
	local function finish(position)
		if finished then
			return
		end
		finished = true
		dragging = false
		catcher.Visible = false
		for _, c in conns do
			c:Disconnect()
		end
		onEnd(position)
	end
	table.insert(conns, catcher.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			onMove(input.Position)
		end
	end))
	table.insert(conns, catcher.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			finish(input.Position)
		end
	end))
	table.insert(conns, catcher.MouseButton1Up:Connect(function()
		finish(nil)
	end))
end
UI.beginDrag = beginDrag

-- true while the user is in the middle of something a redraw would break: a drag, an open menu / picker / dialog
-- (App holds its redraws until then, like it does while a text box is focused)
function UI.busy()
	return dragging or (overlay ~= nil and overlay.Visible == true)
end

local function pressed(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
end

-- ---------------------------------------------------------------------------------------------
-- text
-- ---------------------------------------------------------------------------------------------
-- the width of a line of text in a role of UI.TYPE (TextService:GetTextSize; an estimate where it is missing)
local textService = nil
function UI.textWidth(text, role)
	local spec = Theme.TYPE[role or "body"] or Theme.TYPE.body
	if textService == nil then
		local ok, service = pcall(function()
			return game:GetService("TextService")
		end)
		textService = ok and service or false
	end
	if textService then
		local ok, width = pcall(function()
			return textService:GetTextSize(text, spec.size, Theme.enumFont(spec.weight), Vector2.new(10000, 1000)).X
		end)
		if ok and type(width) == "number" then
			return math.ceil(width)
		end
	end
	return math.ceil((utf8.len(text) or #text) * spec.size * 0.52)
end

local function escape(s)
	return (string.gsub(tostring(s), "[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end
UI.escape = escape

-- opts: role (UI.TYPE key), size, bold / medium, dim, color (Color3 or token), wrap, rich, width, height, align
function UI.label(parent, text, opts)
	opts = opts or {}
	local role = opts.role or ((opts.size and opts.size <= 11) and "meta" or "body")
	local props = { Parent = parent, Text = text, BackgroundTransparency = 1,
		TextXAlignment = opts.align or Enum.TextXAlignment.Left, TextWrapped = opts.wrap or false, RichText = opts.rich or false,
		Size = opts.wrap and UDim2.new(1, 0, 0, 0) or (opts.width and UDim2.new(0, opts.width, 0, opts.height or UI.H)
			or UDim2.new(1, 0, 0, opts.height or UI.H)),
		AutomaticSize = opts.wrap and Enum.AutomaticSize.Y or Enum.AutomaticSize.None,
		TextTruncate = opts.wrap and Enum.TextTruncate.None or Enum.TextTruncate.AtEnd }
	textStyle(props, role, opts.bold and "Bold" or (opts.medium and "Medium" or nil))
	if opts.size then
		props.TextSize = opts.size
	end
	local l = make("TextLabel", props)
	local map = paintWith(l, "TextColor3", opts.color, opts.dim and "textDim" or "text")
	if next(map) then
		skin(l, map)
	end
	return l
end

-- ---------------------------------------------------------------------------------------------
-- buttons
-- ---------------------------------------------------------------------------------------------
-- token names per state; bg = nil: transparent until hovered
local BUTTON = {
	primary = { bg = "accent", hover = "accentHover", press = "accentPressed", text = "accentText" },
	normal = { bg = "button", hover = "buttonHover", press = "buttonPressed", text = "buttonText", border = "buttonBorder" },
	ghost = { hover = "surfaceHover", press = "surfacePressed", text = "textDim", hoverText = "text" },
	danger = { bg = "button", hover = "dangerSoft", press = "dangerSoft", text = "danger", border = "buttonBorder" },
	destructive = { bg = "danger", hover = "danger", press = "danger", text = "accentText" },
	selected = { bg = "accentSoft", hover = "accentSoftHover", press = "accentSoft", text = "text", border = "accent" },
	link = { hover = "surfaceHover", press = "surfacePressed", text = "accent" },
}
BUTTON.secondary = BUTTON.normal
UI.BUTTON_STYLES = BUTTON

-- opts: style (primary / normal / ghost / danger / destructive), selected, icon (glyph name), width, scale, height,
-- autoWidth, align, textSize, tip, disabled. bold is accepted and ignored (buttons are Medium).
function UI.button(parent, text, onClick, opts)
	opts = opts or {}
	local style = BUTTON[opts.selected and "selected" or (opts.style or "normal")] or BUTTON.normal
	local disabled = opts.disabled == true
	local height = opts.height or UI.H
	local hasIcon = opts.icon ~= nil and text ~= ""
	local props = { Parent = parent, Text = text, AutoButtonColor = false, TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = opts.align or (hasIcon and Enum.TextXAlignment.Left or Enum.TextXAlignment.Center),
		BackgroundTransparency = style.bg and 0 or 1,
		Size = opts.width and UDim2.new(0, opts.width, 0, height) or UDim2.new(opts.autoWidth and 0 or (opts.scale or 1), 0, 0, height),
		AutomaticSize = opts.autoWidth and Enum.AutomaticSize.X or Enum.AutomaticSize.None }
	textStyle(props, "control")
	if opts.textSize then
		props.TextSize = opts.textSize
	end
	local padLeft = hasIcon and 28 or (text == "" and 0 or 8)
	local b = make("TextButton", props, { UI.corner(Theme.RADIUS.control), UI.pad(0, text == "" and 0 or 8, 0, padLeft) })
	local textToken = disabled and "textDisabled" or style.text
	skin(b, { BackgroundColor3 = style.bg or style.hover, TextColor3 = textToken })
	if style.border then
		UI.stroke(style.border).Parent = b
	end
	local img
	if opts.icon then
		img = UI.icon(b, opts.icon, { color = textToken, anchor = Vector2.new(0, 0.5),
			position = text == "" and UDim2.new(0.5, -8, 0.5, 0) or UDim2.new(0, -21, 0.5, 0) })
	end
	b:SetAttribute("Disabled", disabled or nil)
	if not disabled then
		local function state(name)
			local bg = name == "press" and style.press or (name == "hover" and style.hover or style.bg)
			b.BackgroundTransparency = bg and 0 or 1
			local textColor = (name ~= "idle" and style.hoverText) or style.text
			restyle(b, { BackgroundColor3 = bg or style.hover, TextColor3 = textColor })
			if img and img:IsA("ImageLabel") then
				restyle(img, { ImageColor3 = textColor })
			end
		end
		b.MouseEnter:Connect(function()
			state("hover")
		end)
		b.MouseLeave:Connect(function()
			state("idle")
		end)
		b.MouseButton1Down:Connect(function()
			state("press")
		end)
		b.MouseButton1Up:Connect(function()
			state("hover")
		end)
		if onClick then
			b.MouseButton1Click:Connect(onClick)
		end
	end
	if opts.tip then
		UI.tip(b, opts.tip)
	end
	return b
end

-- a square button with one glyph. opts: size (24), iconSize (16), tip, active (pressed-in state, accent glyph),
-- danger (hover in the danger colour), color (glyph colour at rest, default textDim), disabled, name
function UI.iconButton(parent, icon, onClick, opts)
	opts = opts or {}
	local size = opts.size or UI.H
	local b = make("TextButton", { Name = opts.name or ("IconButton_" .. tostring(icon)), Parent = parent, Text = "",
		AutoButtonColor = false, BackgroundTransparency = opts.active and 0 or 1, Size = UDim2.fromOffset(size, size) },
		{ UI.corner(Theme.RADIUS.control) })
	local rest = opts.disabled and "textDisabled" or (opts.active and "accent"
		or ((type(opts.color) == "string" and opts.color) or tokenOf(opts.color) or "textDim"))
	skin(b, { BackgroundColor3 = opts.active and "accentSoft" or "surfaceHover" })
	local img = UI.icon(b, icon, { size = opts.iconSize or Theme.ICON, color = rest, anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.5) })
	local function glyph(token)
		if img:IsA("ImageLabel") then
			restyle(img, { ImageColor3 = token })
		end
	end
	b:SetAttribute("Active", opts.active or nil)
	if not opts.disabled then
		b.MouseEnter:Connect(function()
			b.BackgroundTransparency = 0
			glyph(opts.danger and "danger" or (opts.active and "accent" or "text"))
		end)
		b.MouseLeave:Connect(function()
			b.BackgroundTransparency = opts.active and 0 or 1
			glyph(rest)
		end)
		b.MouseButton1Down:Connect(function()
			restyle(b, { BackgroundColor3 = "surfacePressed" })
		end)
		b.MouseButton1Up:Connect(function()
			restyle(b, { BackgroundColor3 = opts.active and "accentSoft" or "surfaceHover" })
		end)
		if onClick then
			b.MouseButton1Click:Connect(onClick)
		end
	end
	if opts.tip then
		UI.tip(b, opts.tip)
	end
	return b
end

-- ---------------------------------------------------------------------------------------------
-- stacks and rows (unchanged signatures)
-- ---------------------------------------------------------------------------------------------
function UI.hstack(parent, opts)
	opts = opts or {}
	return make("Frame", { Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, opts.height or UI.H) },
		{ UI.hlist(opts.gap or Theme.SPACE.sm, opts.fill ~= false) })
end

function UI.vstack(parent, gap)
	return make("Frame", { Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.vlist(gap or Theme.SPACE.xs) })
end

-- a labelled row: returns the area where the controls go (they share the width)
function UI.row(parent, text, opts)
	opts = opts or {}
	local labelWidth = opts.labelWidth or UI.LABEL_W
	local row = make("Frame", { Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, opts.height or UI.H) },
		{ UI.hlist(Theme.SPACE.sm, false) })
	UI.label(row, text, { width = labelWidth, dim = true, height = opts.height })
	local area = make("Frame", { Parent = row, BackgroundTransparency = 1,
		Size = UDim2.new(1, -(labelWidth + Theme.SPACE.sm), 1, 0) }, { UI.hlist(Theme.SPACE.xs, true) })
	return area
end

function UI.divider(parent, opts)
	opts = opts or {}
	local d = make("Frame", { Name = "Divider", Parent = parent, Size = opts.vertical and UDim2.new(0, 1, 1, 0)
		or UDim2.new(1, -(opts.inset or 0) * 2, 0, 1) })
	skin(d, { BackgroundColor3 = "divider" })
	return d
end

function UI.spacer(parent, h)
	return make("Frame", { Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, h or 4) })
end

-- ---------------------------------------------------------------------------------------------
-- fields
-- ---------------------------------------------------------------------------------------------
local CTRL_KEYS = { Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl }
local SHIFT_KEYS = { Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift }

local function modifierDown(input, modifier, keys)
	local ok, down = pcall(input.IsModifierKeyDown, input, modifier)
	if ok and down then
		return true
	end
	if UserInputService then
		for _, key in keys do
			local okKey, isDown = pcall(function()
				return UserInputService:IsKeyDown(key)
			end)
			if okKey and isDown then
				return true
			end
		end
	end
	return false
end

local function fmt(v, decimals)
	if decimals == 0 then
		return tostring(math.floor(v + 0.5))
	end
	local s = string.format("%." .. (decimals or 2) .. "f", v)
	s = s:gsub("0+$", ""):gsub("%.$", "")
	return s == "-0" and "0" or s
end
UI.fmt = fmt

-- the look shared by text boxes: field background, 1 px border that lights up on hover and focus
local function fieldBox(parent, props, opts)
	props.Parent = parent
	props.ClearTextOnFocus = false
	props.Size = props.Size or (opts.width and UDim2.new(0, opts.width, 0, opts.height or UI.H)
		or UDim2.new(opts.scale or 1, 0, 0, opts.height or UI.H))
	textStyle(props, opts.mono and "code" or "body")
	local border = UI.stroke("fieldBorder")
	local box = make("TextBox", props, { UI.corner(Theme.RADIUS.control), border,
		UI.pad(0, opts.padRight or 8, 0, opts.padLeft or 8) })
	skin(box, { BackgroundColor3 = "field", TextColor3 = "text", PlaceholderColor3 = "textDisabled" })
	box.MouseEnter:Connect(function()
		if not box:IsFocused() then
			restyle(border, { Color = "fieldBorderHover" })
		end
	end)
	box.MouseLeave:Connect(function()
		if not box:IsFocused() then
			restyle(border, { Color = "fieldBorder" })
		end
	end)
	box.Focused:Connect(function()
		restyle(border, { Color = "focus" })
	end)
	box.FocusLost:Connect(function()
		restyle(border, { Color = "fieldBorder" })
	end)
	return box, border
end

-- the number field behind UI.number and UI.scrub; returns the box and a controller
local function numberField(parent, value, onChange, opts)
	local box = fieldBox(parent, { Text = fmt(value, opts.decimals), TextXAlignment = Enum.TextXAlignment.Left },
		{ width = opts.width, padRight = opts.unit and 28 or 8 })
	if opts.unit then
		UI.label(box, opts.unit, { role = "meta", dim = true, width = 24, align = Enum.TextXAlignment.Right }).Position =
			UDim2.new(1, 0, 0, 0)
	end
	local field = { current = value, committed = value }
	local function clamp(v)
		if opts.min then
			v = math.max(opts.min, v)
		end
		if opts.max then
			v = math.min(opts.max, v)
		end
		return v
	end
	field.clamp = clamp
	function field.show(v)
		field.current = clamp(v)
		box.Text = fmt(field.current, opts.decimals)
	end
	function field.commit(v)
		v = clamp(v)
		field.current = v
		field.committed = v
		box.Text = fmt(v, opts.decimals)
		if onChange then
			onChange(v)
		end
	end
	box.FocusLost:Connect(function()
		local v = tonumber((box.Text:gsub(",", ".")))
		if v and v ~= field.current then
			field.commit(v)
		else
			box.Text = fmt(field.current, opts.decimals)
		end
	end)
	-- Ctrl + mouse wheel nudges the value (Shift = x10). A plain wheel only scrolls the panel. The new value is applied
	-- once the wheel stops (one Ctrl+Z per gesture and no redraw on every notch).
	local wheelGen = 0
	box.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseWheel or box:IsFocused()
			or not modifierDown(input, Enum.ModifierKey.Ctrl, CTRL_KEYS) then
			return
		end
		local step = (opts.step or 0.1) * (modifierDown(input, Enum.ModifierKey.Shift, SHIFT_KEYS) and 10 or 1)
		field.show(field.current + (input.Position.Z > 0 and 1 or -1) * step)
		wheelGen += 1
		local gen = wheelGen
		task.delay(0.35, function()
			if gen == wheelGen and field.current ~= field.committed then -- e.g. not when it was already at min / max
				field.commit(field.current)
			end
		end)
	end)
	return box, field
end

-- opts: min, max, step (0.1), decimals, width, unit ("s", "°", "studs"), tip
function UI.number(parent, value, onChange, opts)
	opts = opts or {}
	local box = numberField(parent, value, onChange, opts)
	UI.tip(box, (opts.tip and (opts.tip .. "  ·  ") or "") .. "Ctrl + rotiță: ±" .. fmt(opts.step or 0.1, 3)
		.. " (Shift ×10)")
	return box
end

-- a number field with a label you drag left / right to change the value (Shift = fine, step / 10); one onChange on
-- release (one Ctrl+Z). opts: min, max, step, decimals, unit, labelWidth, tip, onInput(v) while dragging.
-- Returns the row and the number box.
function UI.scrub(parent, label, value, onChange, opts)
	opts = opts or {}
	local labelWidth = opts.labelWidth or UI.LABEL_W
	local row = make("Frame", { Name = "Scrub", Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H) },
		{ UI.hlist(Theme.SPACE.sm, false) })
	local handleProps = { Name = "ScrubHandle", Parent = row, Text = label, AutoButtonColor = false, BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(0, labelWidth, 1, 0) }
	textStyle(handleProps, "body")
	local handle = make("TextButton", handleProps)
	skin(handle, { TextColor3 = "textDim" })
	local holder = make("Frame", { Parent = row, BackgroundTransparency = 1, Size = UDim2.new(1, -(labelWidth + Theme.SPACE.sm), 1, 0) },
		{ UI.hlist(0, true) })
	local box, field = numberField(holder, value, onChange, opts)
	local step = opts.step or 0.1
	UI.tip(handle, (opts.tip and (opts.tip .. "  ·  ") or "") .. "Trage stânga-dreapta: ±" .. fmt(step, 3)
		.. " pe pixel (Shift: fin)")
	UI.tip(box, "Ctrl + rotiță: ±" .. fmt(step, 3) .. " (Shift ×10)")
	local dragging = false
	handle.MouseEnter:Connect(function()
		restyle(handle, { TextColor3 = "text" })
	end)
	handle.MouseLeave:Connect(function()
		if not dragging then
			restyle(handle, { TextColor3 = "textDim" })
		end
	end)
	handle.InputBegan:Connect(function(input)
		if not pressed(input) then
			return
		end
		dragging = true
		local startX, startValue = input.Position.X, field.current
		restyle(handle, { TextColor3 = "accent" })
		beginDrag(function(position)
			local fine = modifierDown(input, Enum.ModifierKey.Shift, SHIFT_KEYS)
			local unit = fine and step / 10 or step
			local v = startValue + (position.X - startX) * unit
			v = math.floor(v / unit + 0.5) * unit
			field.show(v)
			if opts.onInput then
				opts.onInput(field.current)
			end
		end, function()
			dragging = false
			restyle(handle, { TextColor3 = "textDim" })
			if field.current ~= field.committed then
				field.commit(field.current)
			end
		end)
	end)
	return row, box
end

-- a horizontal slider with its value on the right. onChange(v) once on release (one Ctrl+Z); opts.onInput(v) while
-- dragging. opts: min (0), max (1), step (0.01), decimals (2), unit, field (an editable number field instead of the value
-- label), valueWidth (44), scale
function UI.slider(parent, value, onChange, opts)
	opts = opts or {}
	local min, max = opts.min or 0, opts.max or 1
	local step = opts.step or 0.01
	local decimals = opts.decimals or 2
	local valueW = opts.valueWidth or (opts.field and 56 or 44)
	local frame = make("Frame", { Name = "Slider", Parent = parent, BackgroundTransparency = 1,
		Size = UDim2.new(opts.scale or 1, 0, 0, UI.H) })
	local hit = make("TextButton", { Name = "Hit", Parent = frame, Text = "", AutoButtonColor = false, BackgroundTransparency = 1,
		Size = UDim2.new(1, -(valueW + Theme.SPACE.sm), 1, 0) })
	local track = make("Frame", { Name = "Track", Parent = hit, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 6, 0.5, 0),
		Size = UDim2.new(1, -12, 0, 4) }, { UI.corner(2) })
	skin(track, { BackgroundColor3 = "switchOff" })
	local fill = make("Frame", { Name = "Fill", Parent = track, Size = UDim2.fromScale(0, 1) }, { UI.corner(2) })
	skin(fill, { BackgroundColor3 = "accent" })
	local knob = make("Frame", { Name = "Knob", Parent = track, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(12, 12) },
		{ UI.corner(6), UI.stroke("border") })
	skin(knob, { BackgroundColor3 = "knob" })
	local current, committed = value, value
	local readout, field = nil, nil
	local function show(v)
		current = math.clamp(v, min, max)
		local f = max > min and (current - min) / (max - min) or 0
		fill.Size = UDim2.fromScale(f, 1)
		knob.Position = UDim2.fromScale(f, 0.5)
		if readout then
			readout.Text = fmt(current, decimals) .. (opts.unit and (" " .. opts.unit) or "")
		elseif field then
			field.show(current)
		end
	end
	if opts.field then
		local holder = make("Frame", { Parent = frame, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, valueW, 1, 0) })
		local _, f = numberField(holder, value, function(v)
			show(v)
			committed = current
			onChange(current)
		end, { min = min, max = max, step = step, decimals = decimals, unit = opts.unit })
		field = f
	else
		readout = UI.label(frame, "", { role = "meta", dim = true, width = valueW, align = Enum.TextXAlignment.Right })
		readout.AnchorPoint = Vector2.new(1, 0)
		readout.Position = UDim2.fromScale(1, 0)
	end
	show(value)
	local function at(position)
		if not position then
			return
		end
		local p, size = track.AbsolutePosition, track.AbsoluteSize
		local f = math.clamp((position.X - p.X) / math.max(1, size.X), 0, 1)
		local v = min + math.floor(f * (max - min) / step + 0.5) * step
		show(v)
		if opts.onInput then
			opts.onInput(current)
		end
	end
	hit.InputBegan:Connect(function(input)
		if not pressed(input) then
			return
		end
		at(input.Position)
		beginDrag(at, function()
			if current ~= committed then
				committed = current
				onChange(current)
			end
		end)
	end)
	hit.MouseEnter:Connect(function()
		restyle(fill, { BackgroundColor3 = "accentHover" })
	end)
	hit.MouseLeave:Connect(function()
		restyle(fill, { BackgroundColor3 = "accent" })
	end)
	if opts.tip then
		UI.tip(hit, opts.tip)
	end
	return frame
end

-- opts: placeholder, width, scale, mono
function UI.textbox(parent, value, onChange, opts)
	opts = opts or {}
	local box = fieldBox(parent, { Text = value or "", PlaceholderText = opts.placeholder or "",
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd }, opts)
	box.FocusLost:Connect(function(enter)
		if onChange and box.Text ~= value then
			onChange(box.Text, enter)
		end
	end)
	return box
end

-- a search field: glyph, text, clear button. onChange(text) after a short pause (opts.delay, 0.15 s), at once on
-- Enter and on clear. opts: placeholder ("Caută"), width. Returns the frame and the TextBox.
function UI.search(parent, value, onChange, opts)
	opts = opts or {}
	local frame = make("Frame", { Name = "Search", Parent = parent,
		Size = opts.width and UDim2.new(0, opts.width, 0, UI.H) or UDim2.new(1, 0, 0, UI.H) }, { UI.corner(Theme.RADIUS.control) })
	skin(frame, { BackgroundColor3 = "field" })
	local border = UI.stroke("fieldBorder")
	border.Parent = frame
	UI.icon(frame, "search", { size = 14, anchor = Vector2.new(0, 0.5), position = UDim2.new(0, 8, 0.5, 0) })
	local props = { Parent = frame, Text = value or "", PlaceholderText = opts.placeholder or "Caută", ClearTextOnFocus = false,
		BackgroundTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(28, 0), Size = UDim2.new(1, -52, 1, 0) }
	textStyle(props, "body")
	local box = make("TextBox", props)
	skin(box, { TextColor3 = "text", PlaceholderColor3 = "textDisabled" })
	local sent = value or ""
	local function send(text)
		if text ~= sent then
			sent = text
			onChange(text)
		end
	end
	local clear = UI.iconButton(frame, "close", function()
		box.Text = ""
		send("")
		box:CaptureFocus()
	end, { size = 20, iconSize = 14, tip = "Golește" })
	clear.AnchorPoint = Vector2.new(1, 0.5)
	clear.Position = UDim2.new(1, -2, 0.5, 0)
	clear.Visible = (value or "") ~= ""
	local gen = 0
	box:GetPropertyChangedSignal("Text"):Connect(function()
		clear.Visible = box.Text ~= ""
		gen += 1
		local mine = gen
		task.delay(opts.delay or 0.15, function()
			if mine == gen then
				send(box.Text)
			end
		end)
	end)
	box.FocusLost:Connect(function()
		send(box.Text)
		restyle(border, { Color = "fieldBorder" })
	end)
	box.Focused:Connect(function()
		restyle(border, { Color = "focus" })
	end)
	return frame, box
end

-- ---------------------------------------------------------------------------------------------
-- switch, toggle, segmented
-- ---------------------------------------------------------------------------------------------
local SWITCH_W, SWITCH_H, KNOB = 28, 16, 12

local function drawSwitch(parent, value)
	local track = make("Frame", { Name = "Switch", Parent = parent, Size = UDim2.fromOffset(SWITCH_W, SWITCH_H) },
		{ UI.corner(SWITCH_H // 2) })
	skin(track, { BackgroundColor3 = value and "accent" or "switchOff" })
	local knob = make("Frame", { Name = "Knob", Parent = track, AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, value and (SWITCH_W - KNOB - 2) or 2, 0.5, 0), Size = UDim2.fromOffset(KNOB, KNOB) },
		{ UI.corner(KNOB // 2) })
	skin(knob, { BackgroundColor3 = "knob" })
	local function set(on, instant)
		local position = UDim2.new(0, on and (SWITCH_W - KNOB - 2) or 2, 0.5, 0)
		if instant then
			knob.Position = position
			skin(track, { BackgroundColor3 = on and "accent" or "switchOff" })
		else
			animate(knob, { Position = position }, Theme.MOTION.base)
			restyle(track, { BackgroundColor3 = on and "accent" or "switchOff" }, Theme.MOTION.base)
		end
	end
	return track, set
end

-- a switch on its own (28 x 16). onChange(newValue). opts: disabled, tip. The "Checked" attribute holds the state.
function UI.switch(parent, value, onChange, opts)
	opts = opts or {}
	local b = make("TextButton", { Name = "SwitchButton", Parent = parent, Text = "", AutoButtonColor = false,
		BackgroundTransparency = 1, Size = UDim2.fromOffset(SWITCH_W, UI.H) })
	local track, set = drawSwitch(b, value == true)
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.fromScale(0, 0.5)
	local state = value == true
	b:SetAttribute("Checked", state)
	if not opts.disabled then
		b.MouseButton1Click:Connect(function()
			state = not state
			b:SetAttribute("Checked", state)
			set(state)
			onChange(state)
		end)
	end
	if opts.tip then
		UI.tip(b, opts.tip)
	end
	return b
end

-- a switch with its label; the whole row is clickable. onChange(not value). Returns the TextButton (attribute
-- "Checked" = state). opts: width, scale, tip, disabled
function UI.toggle(parent, value, onChange, text, opts)
	opts = opts or {}
	local props = { Name = "Toggle", Parent = parent, Text = text, AutoButtonColor = false, BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
		Size = opts.width and UDim2.new(0, opts.width, 0, UI.H) or UDim2.new(opts.scale or 1, 0, 0, UI.H) }
	textStyle(props, "body")
	local b = make("TextButton", props, { UI.pad(0, 0, 0, SWITCH_W + 8) })
	skin(b, { TextColor3 = opts.disabled and "textDisabled" or "text" })
	local track, set = drawSwitch(b, value == true)
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, -(SWITCH_W + 8), 0.5, 0)
	b:SetAttribute("Checked", value == true)
	if not opts.disabled then
		b.MouseEnter:Connect(function()
			if not value then
				restyle(track, { BackgroundColor3 = "textDisabled" })
			end
		end)
		b.MouseLeave:Connect(function()
			if not value then
				restyle(track, { BackgroundColor3 = "switchOff" })
			end
		end)
		b.MouseButton1Click:Connect(function()
			set(not value)
			b:SetAttribute("Checked", not value)
			onChange(not value)
		end)
	end
	if opts.tip then
		UI.tip(b, opts.tip)
	end
	return b
end

-- items: { { value =, label =, tip = } }. One bordered control; the chosen segment is raised.
function UI.segmented(parent, items, value, onChange)
	local bar = make("Frame", { Name = "Segmented", Parent = parent, Size = UDim2.new(1, 0, 0, UI.H) },
		{ UI.corner(Theme.RADIUS.control), UI.stroke("fieldBorder"), UI.pad(2, 2, 2, 2), UI.hlist(2, true) })
	skin(bar, { BackgroundColor3 = "field" })
	for _, item in items do
		local on = item.value == value
		local props = { Parent = bar, Text = item.label, AutoButtonColor = false, BackgroundTransparency = on and 0 or 1,
			TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 1, 0) }
		textStyle(props, "control", on and "Medium" or "Regular")
		local seg = make("TextButton", props, { UI.corner(3), UI.pad(0, 4, 0, 4) })
		skin(seg, { BackgroundColor3 = "raisedStrong", TextColor3 = on and "text" or "textDim" })
		seg:SetAttribute("Checked", on)
		if not on then
			seg.MouseEnter:Connect(function()
				restyle(seg, { TextColor3 = "text" })
			end)
			seg.MouseLeave:Connect(function()
				restyle(seg, { TextColor3 = "textDim" })
			end)
		end
		seg.MouseButton1Click:Connect(function()
			onChange(item.value)
		end)
		if item.tip then
			UI.tip(seg, item.tip)
		end
	end
	return bar
end

-- ---------------------------------------------------------------------------------------------
-- menus and dropdowns
-- ---------------------------------------------------------------------------------------------
local ROW_H = 24

local function menuHeight(items)
	local h = 0
	for _, item in items do
		h += item.separator and 9 or ROW_H
	end
	return h
end

-- rows of a menu into `list`. items: { label, value, icon, classIcon, hint, header, separator, danger, disabled,
-- onClick }. opts.value = the chosen value (check mark); opts.checks = leave room for the check column
local function menuRows(list, items, opts, onPick)
	for _, item in items do
		if item.separator then
			local holder = make("Frame", { Parent = list, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 9) })
			UI.divider(holder).Position = UDim2.fromOffset(0, 4)
		elseif item.header then
			local l = UI.label(list, "<uc>" .. escape(item.label) .. "</uc>", { role = "caps", dim = true, rich = true,
				height = ROW_H })
			UI.pad(0, 8, 0, 8).Parent = l
		else
			local chosen = opts.checks and item.value ~= nil and item.value == opts.value
			local props = { Parent = list, Text = item.label or "", AutoButtonColor = false, BackgroundTransparency = 1,
				TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, 0, 0, ROW_H) }
			textStyle(props, "body", chosen and "Medium" or nil)
			local left = 8 + (opts.checks and 20 or 0) + ((item.icon or item.classIcon) and 22 or 0)
			local entry = make("TextButton", props, { UI.corner(Theme.RADIUS.control), UI.pad(0, item.hint and 56 or 8, 0, left) })
			local color = item.disabled and "textDisabled" or (item.danger and "danger" or "text")
			skin(entry, { BackgroundColor3 = "surfaceHover", TextColor3 = color })
			if chosen then
				UI.icon(entry, "check", { size = 14, color = "accent", anchor = Vector2.new(0, 0.5),
					position = UDim2.new(0, -left + 8, 0.5, 0) })
				entry:SetAttribute("Checked", true)
			end
			if item.icon or item.classIcon then
				UI.icon(entry, item.classIcon or item.icon, { class = item.classIcon ~= nil, color = color,
					anchor = Vector2.new(0, 0.5), position = UDim2.new(0, -22, 0.5, 0) })
			end
			if item.hint then
				local hint = UI.label(entry, item.hint, { role = "meta", dim = true, width = 48, align = Enum.TextXAlignment.Right,
					height = ROW_H })
				hint.Position = UDim2.new(1, 0, 0, 0)
			end
			if not item.disabled then
				entry.MouseEnter:Connect(function()
					entry.BackgroundTransparency = 0
				end)
				entry.MouseLeave:Connect(function()
					entry.BackgroundTransparency = 1
				end)
				entry.MouseButton1Click:Connect(function()
					UI.closePopup()
					onPick(item)
				end)
			end
		end
	end
end

-- a scrolling list inside a popup, with a filter box once there are many rows
local function menuPopup(anchor, items, opts, onPick)
	local count = 0
	for _, item in items do
		if not item.header and not item.separator then
			count += 1
		end
	end
	local searchable = count > 14
	local top = searchable and 32 or 0
	local frame = popup(anchor, math.max(anchor.AbsoluteSize.X, opts.menuWidth or 180), menuHeight(items) + 8 + top,
		{ modal = false, onCancel = opts.onClose })
	local list = make("ScrollingFrame", { Parent = frame, Position = UDim2.fromOffset(0, top), Size = UDim2.new(1, 0, 1, -top),
		BackgroundTransparency = 1, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.Y, VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar },
		{ UI.vlist(0), UI.pad(4, 4, 4, 4) })
	skin(list, { ScrollBarImageColor3 = "scrollbar" })
	menuRows(list, items, opts, onPick)
	if searchable then
		local holder = make("Frame", { Parent = frame, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, top) },
			{ UI.pad(6, 6, 2, 6) })
		local _, box = UI.search(holder, "", function(text)
			for _, child in list:GetChildren() do
				if child:IsA("GuiObject") then
					child:Destroy()
				end
			end
			local query = string.lower(text)
			local shown = {}
			for _, item in items do
				if not item.header and not item.separator and (query == ""
					or string.find(string.lower(item.label or ""), query, 1, true)) then
					table.insert(shown, item)
				end
			end
			menuRows(list, query == "" and items or shown, opts, onPick)
			raise(frame, 52)
		end, { placeholder = "Filtrează", delay = 0.1 })
		task.defer(function()
			if box.Parent then
				box:CaptureFocus()
			end
		end)
	end
	raise(frame, 52)
	return frame
end

-- a menu of actions under anchor. items: { label, icon, hint, danger, disabled, onClick } / { separator = true } /
-- { header = true, label }. opts: width
function UI.menu(anchor, items, opts)
	opts = opts or {}
	return menuPopup(anchor, items, { menuWidth = opts.width or 180 }, function(item)
		if item.onClick then
			item.onClick()
		end
	end)
end

-- items: { { value =, label =, icon = / classIcon =, hint =, header = bool, separator = bool } }.
-- opts: text (fixed label: an action menu), placeholder, style ("primary" for an action menu), width, scale, menuWidth,
-- tip. The chosen item has a check mark; more than 14 items get a filter box.
function UI.dropdown(parent, items, value, onChange, opts)
	opts = opts or {}
	local current, currentItem = opts.text, nil
	for _, item in items do
		if not item.header and not item.separator and item.value == value then
			currentItem = item
			current = current or item.label
		end
	end
	local action = opts.style == "primary" or opts.style == "normal" or opts.style == "ghost"
	local showIcon = not opts.text and currentItem and (currentItem.icon or currentItem.classIcon)
	local height = opts.height or UI.H
	local props = { Name = "Dropdown", Parent = parent, Text = current or opts.placeholder or "Alege", AutoButtonColor = false,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
		Size = opts.width and UDim2.new(0, opts.width, 0, height) or UDim2.new(opts.scale or 1, 0, 0, height) }
	textStyle(props, action and "control" or "body")
	local b = make("TextButton", props, { UI.corner(Theme.RADIUS.control), UI.pad(0, 26, 0, showIcon and 30 or 8) })
	local style = action and BUTTON[opts.style] or nil
	local textToken = style and style.text or (current and "text" or "textDisabled")
	skin(b, { BackgroundColor3 = style and (style.bg or style.hover) or "field", TextColor3 = textToken })
	b.BackgroundTransparency = (style and not style.bg) and 1 or 0
	local border = nil
	if not style or style.border then
		border = UI.stroke(style and style.border or "fieldBorder")
		border.Parent = b
	end
	if showIcon then
		UI.icon(b, currentItem.classIcon or currentItem.icon, { class = currentItem.classIcon ~= nil, anchor = Vector2.new(0, 0.5),
			position = UDim2.new(0, -22, 0.5, 0) })
	end
	local chevron = UI.icon(b, "chevronDown", { size = 12, color = style and style.text or "textDim",
		anchor = Vector2.new(1, 0.5), position = UDim2.new(1, 18, 0.5, 0) })
	b.MouseEnter:Connect(function()
		if style then
			if style.hover then
				b.BackgroundTransparency = 0
				restyle(b, { BackgroundColor3 = style.hover, TextColor3 = style.hoverText or style.text })
			end
		elseif border then
			restyle(border, { Color = "fieldBorderHover" })
		end
	end)
	b.MouseLeave:Connect(function()
		if style then
			b.BackgroundTransparency = style.bg and 0 or 1
			restyle(b, { BackgroundColor3 = style.bg or style.hover, TextColor3 = style.text })
		elseif border then
			restyle(border, { Color = "fieldBorder" })
		end
	end)
	local function rest()
		if border and not style and b.Parent then
			restyle(border, { Color = "fieldBorder" })
		end
	end
	b.MouseButton1Click:Connect(function()
		menuPopup(b, items, { menuWidth = opts.menuWidth, value = value, checks = not opts.text, onClose = rest }, function(item)
			rest()
			onChange(item.value)
		end)
		if border and not style then
			restyle(border, { Color = "focus" })
		end
	end)
	if opts.tip then
		UI.tip(b, opts.tip)
	end
	b:SetAttribute("Value", type(value) == "string" and value or nil)
	return b, chevron
end

-- ---------------------------------------------------------------------------------------------
-- colour: a swatch field that opens the picker
-- ---------------------------------------------------------------------------------------------
local function hexOf(c)
	local ok, hex = pcall(function()
		return c:ToHex()
	end)
	return ok and string.upper(tostring(hex)) or "FFFFFF"
end

-- HSV in plain math (Color3.fromHSV / ToHSV are not in every environment the panels run in)
local function toHSV(c)
	local r, g, b = c.R, c.G, c.B
	local max, min = math.max(r, g, b), math.min(r, g, b)
	local d = max - min
	local h = 0
	if d > 0 then
		if max == r then
			h = ((g - b) / d) % 6
		elseif max == g then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h /= 6
	end
	return h, max > 0 and d / max or 0, max
end

local function fromHSV(h, s, v)
	local i = math.floor(h * 6) % 6
	local f = h * 6 - math.floor(h * 6)
	local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	local rgb = ({ { v, t, p }, { q, v, p }, { p, v, t }, { p, q, v }, { t, p, v }, { v, p, q } })[i + 1]
	return Color3.new(rgb[1], rgb[2], rgb[3])
end
UI.toHSV, UI.fromHSV = toHSV, fromHSV

local function rememberColor(c)
	local hex = hexOf(c)
	local i = table.find(UI.recentColors, hex)
	if i then
		table.remove(UI.recentColors, i)
	end
	table.insert(UI.recentColors, 1, hex)
	while #UI.recentColors > 8 do
		table.remove(UI.recentColors)
	end
	if UI.onRecentColors then
		UI.onRecentColors(UI.recentColors)
	end
end

local function gradient(parent, props)
	local ok = pcall(function()
		local g = Instance.new("UIGradient")
		for k, v in props do
			g[k] = v
		end
		g.Parent = parent
	end)
	return ok
end

-- the picker: saturation / value square, hue strip, hex field, recent colours. onChange(color) when a choice is made
-- (end of a drag, Enter in the hex field, a recent swatch: one Ctrl+Z each); opts.onInput(color) while dragging.
function UI.colorPicker(anchor, color, onChange, opts)
	opts = opts or {}
	local h, s, v = toHSV(color)
	local W = 216
	local frame = popup(anchor, W + 16, 236)
	local square = make("Frame", { Name = "SV", Parent = frame, Active = true, Position = UDim2.fromOffset(8, 8),
		Size = UDim2.fromOffset(W, 128), BackgroundColor3 = fromHSV(h, 1, 1) }, { UI.corner(3) })
	local white = make("Frame", { Parent = square, Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1) },
		{ UI.corner(3) })
	local black = make("Frame", { Parent = square, Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0) },
		{ UI.corner(3) })
	pcall(function()
		gradient(white, { Transparency = NumberSequence.new(0, 1) })
		gradient(black, { Rotation = 90, Transparency = NumberSequence.new(1, 0) })
	end)
	local cursor = make("Frame", { Name = "Cursor", Parent = square, AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1,
		Size = UDim2.fromOffset(10, 10) }, { UI.corner(5), make("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2 }) })
	local hue = make("Frame", { Name = "Hue", Parent = frame, Active = true, Position = UDim2.fromOffset(8, 144),
		Size = UDim2.fromOffset(W, 10), BackgroundColor3 = Color3.new(1, 1, 1) }, { UI.corner(3) })
	pcall(function()
		local keys = {}
		for i = 0, 6 do
			table.insert(keys, ColorSequenceKeypoint.new(i / 6, fromHSV((i / 6) % 1, 1, 1)))
		end
		gradient(hue, { Color = ColorSequence.new(keys) })
	end)
	local hueKnob = make("Frame", { Name = "HueKnob", Parent = hue, AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(4, 14), BackgroundColor3 = Color3.new(1, 1, 1) }, { UI.corner(2), UI.stroke("border") })
	local row = make("Frame", { Parent = frame, BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 162),
		Size = UDim2.fromOffset(W, UI.H) }, { UI.hlist(Theme.SPACE.sm, false) })
	local preview = make("Frame", { Name = "Preview", Parent = row, Size = UDim2.fromOffset(UI.H, UI.H), BackgroundColor3 = color },
		{ UI.corner(Theme.RADIUS.control), UI.stroke("border") })
	local hexBox = fieldBox(row, { Text = "#" .. hexOf(color), TextXAlignment = Enum.TextXAlignment.Left },
		{ width = W - UI.H - Theme.SPACE.sm })
	local function current()
		return fromHSV(h, s, v)
	end
	local function show()
		local c = current()
		square.BackgroundColor3 = fromHSV(h, 1, 1)
		cursor.Position = UDim2.fromScale(s, 1 - v)
		hueKnob.Position = UDim2.fromScale(h, 0.5)
		preview.BackgroundColor3 = c
		hexBox.Text = "#" .. hexOf(c)
	end
	local function choose()
		local c = current()
		rememberColor(c)
		onChange(c)
	end
	local function dragOn(target, apply)
		target.InputBegan:Connect(function(input)
			if not pressed(input) then
				return
			end
			local function at(position)
				if not position then
					return
				end
				local p, size = target.AbsolutePosition, target.AbsoluteSize
				apply(math.clamp((position.X - p.X) / math.max(1, size.X), 0, 1),
					math.clamp((position.Y - p.Y) / math.max(1, size.Y), 0, 1))
				show()
				if opts.onInput then
					opts.onInput(current())
				end
			end
			at(input.Position)
			beginDrag(at, function()
				choose()
			end)
		end)
	end
	dragOn(square, function(x, y)
		s, v = x, 1 - y
	end)
	dragOn(hue, function(x)
		h = math.min(x, 0.999)
	end)
	hexBox.FocusLost:Connect(function()
		local hex = hexBox.Text:gsub("#", ""):gsub("%s", "")
		local ok, c = pcall(Color3.fromHex, hex)
		if ok and c then
			h, s, v = toHSV(c)
			show()
			choose()
		else
			show()
		end
	end)
	if #UI.recentColors > 0 then
		UI.label(frame, "<uc>Recente</uc>", { role = "caps", dim = true, rich = true, height = 16 }).Position =
			UDim2.fromOffset(8, 194)
		local swatches = make("Frame", { Parent = frame, BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 212),
			Size = UDim2.fromOffset(W, 16) }, { UI.hlist(6, false) })
		for _, hex in UI.recentColors do
			local ok, c = pcall(Color3.fromHex, hex)
			if ok and c then
				local sw = make("TextButton", { Parent = swatches, Text = "", AutoButtonColor = false, BackgroundColor3 = c,
					Size = UDim2.fromOffset(20, 16) }, { UI.corner(3), UI.stroke("border") })
				UI.tip(sw, "#" .. hex)
				sw.MouseButton1Click:Connect(function()
					h, s, v = toHSV(c)
					show()
					choose()
				end)
			end
		end
	else
		frame.Size = UDim2.fromOffset(frame.Size.X.Offset, 194)
	end
	show()
	raise(frame, 52)
	return frame
end

-- a colour field: swatch + hex; a click opens UI.colorPicker. opts: width, scale, onInput, tip
function UI.color(parent, color, onChange, opts)
	opts = opts or {}
	local props = { Name = "Color", Parent = parent, Text = "#" .. hexOf(color), AutoButtonColor = false,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
		Size = opts.width and UDim2.new(0, opts.width, 0, UI.H) or UDim2.new(opts.scale or 1, 0, 0, UI.H) }
	textStyle(props, "body")
	local border = UI.stroke("fieldBorder")
	local b = make("TextButton", props, { UI.corner(Theme.RADIUS.control), border, UI.pad(0, 8, 0, 28) })
	skin(b, { BackgroundColor3 = "field", TextColor3 = "text" })
	make("Frame", { Name = "Swatch", Parent = b, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, -22, 0.5, 0),
		Size = UDim2.fromOffset(14, 14), BackgroundColor3 = color }, { UI.corner(3), UI.stroke("border") })
	b.MouseEnter:Connect(function()
		restyle(border, { Color = "fieldBorderHover" })
	end)
	b.MouseLeave:Connect(function()
		restyle(border, { Color = "fieldBorder" })
	end)
	b.MouseButton1Click:Connect(function()
		UI.colorPicker(b, color, onChange, opts)
	end)
	if opts.tip then
		UI.tip(b, opts.tip)
	end
	return b
end

-- ---------------------------------------------------------------------------------------------
-- structure: section, header, tabs
-- ---------------------------------------------------------------------------------------------
-- a flat collapsible group: chevron + small dim uppercase title, the body, a divider under it. Returns the body (a
-- vertical stack). opts: key (UI.collapsed key, default the title), collapsed (first time), collapsible (false = a
-- plain group header), right(frame) + rightWidth (controls on the right of the header), badge (text after the title),
-- onToggle(collapsed)
function UI.section(parent, title, opts)
	opts = opts or {}
	local key = opts.key or title
	local collapsible = opts.collapsible ~= false
	if UI.collapsed[key] == nil then
		UI.collapsed[key] = opts.collapsed or false
	end
	local collapsed = collapsible and UI.collapsed[key] or false
	local frame = make("Frame", { Name = "Section", Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.vlist(0) })
	local head = make("TextButton", { Name = "Header", Parent = frame, Text = "", AutoButtonColor = false,
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H_LARGE) })
	local left = collapsible and 16 or 0
	local arrow = nil
	if collapsible then
		arrow = UI.icon(head, "chevronRight", { size = 12, rotation = collapsed and 0 or 90, anchor = Vector2.new(0, 0.5),
			position = UDim2.new(0, 0, 0.5, 0) })
	end
	local rightWidth = opts.right and (opts.rightWidth or 60) or 0
	local t = UI.label(head, "<uc>" .. escape(title) .. "</uc>", { role = "caps", dim = true, rich = true, height = UI.H_LARGE })
	t.Position = UDim2.fromOffset(left, 0)
	t.Size = UDim2.new(1, -(left + rightWidth + 4), 1, 0)
	if opts.badge ~= nil then
		local badge = UI.badge(head, tostring(opts.badge))
		badge.AnchorPoint = Vector2.new(1, 0.5)
		badge.Position = UDim2.new(1, -(rightWidth + 4), 0.5, 0)
	end
	if opts.right then
		local right = make("Frame", { Name = "Right", Parent = head, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, rightWidth, 1, 0) },
			{ make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4),
				FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right,
				VerticalAlignment = Enum.VerticalAlignment.Center }) })
		opts.right(right)
	end
	local body = make("Frame", { Name = "Body", Parent = frame, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y, Visible = not collapsed }, { UI.pad(0, 0, Theme.PAD, 0), UI.vlist(Theme.SPACE.xs) })
	UI.divider(frame)
	head:SetAttribute("Collapsed", collapsed)
	head.MouseEnter:Connect(function()
		restyle(t, { TextColor3 = "text" })
	end)
	head.MouseLeave:Connect(function()
		restyle(t, { TextColor3 = "textDim" })
	end)
	if collapsible then
		head.MouseButton1Click:Connect(function()
			-- applied right here (no redraw of the whole panel); the state survives re-renders in UI.collapsed
			collapsed = not collapsed
			UI.collapsed[key] = collapsed
			head:SetAttribute("Collapsed", collapsed)
			if arrow and arrow:IsA("ImageLabel") then
				animate(arrow, { Rotation = collapsed and 0 or 90 }, Theme.MOTION.base)
			end
			body.Visible = not collapsed
			if UI.onCollapse then
				UI.onCollapse()
			end
			if opts.onToggle then
				opts.onToggle(collapsed)
			end
		end)
	end
	return body
end

-- a panel title with an optional subtitle and icon buttons on the right.
-- opts: subtitle, actions = { { icon, tip, onClick, active, danger } }
function UI.header(parent, title, opts)
	opts = opts or {}
	local actions = opts.actions or {}
	local rightWidth = #actions * (UI.H + 4)
	local frame = make("Frame", { Name = "PanelHeader", Parent = parent, BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, opts.subtitle and 40 or 32) })
	local textCol = make("Frame", { Parent = frame, BackgroundTransparency = 1, Size = UDim2.new(1, -rightWidth, 1, 0) },
		{ make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center }) })
	UI.label(textCol, title, { role = "title", color = "textBright", height = 20 })
	if opts.subtitle then
		UI.label(textCol, opts.subtitle, { role = "meta", dim = true, height = 16 })
	end
	if #actions > 0 then
		local right = make("Frame", { Parent = frame, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, rightWidth, 1, 0) },
			{ make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4),
				FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right,
				VerticalAlignment = Enum.VerticalAlignment.Center }) })
		for _, a in actions do
			UI.iconButton(right, a.icon, a.onClick, { tip = a.tip, active = a.active, danger = a.danger })
		end
	end
	return frame
end

-- how many labels the tab bar can show at this width: "full" (all), "compact" (only the open tab), "icons"
local TAB_ICON_W, TAB_GAP = 32, 2
local function tabWidth(item)
	return 10 + Theme.ICON + 6 + UI.textWidth(item.label, "control") + 10
end

function UI.tabsMode(width, items)
	local full, compactWidest = 0, 0
	for _, item in items do
		full += tabWidth(item) + TAB_GAP
		compactWidest = math.max(compactWidest, tabWidth(item))
	end
	local room = width - Theme.SPACE.sm * 2
	if full <= room then
		return "full"
	elseif compactWidest + (#items - 1) * (TAB_ICON_W + TAB_GAP) <= room then
		return "compact"
	end
	return "icons"
end

-- the tab bar: items { key, label, icon, tip }. Icon + short label; when the window is narrow only the open tab keeps
-- its label ("compact") or none do ("icons"); labels that are hidden become tooltips. The open tab: text colour, accent
-- glyph and a 2 px accent line at the bottom. opts: mode ("full" / "compact" / "icons"; default from opts.width)
function UI.tabs(parent, items, value, onChange, opts)
	opts = opts or {}
	local mode = opts.mode or UI.tabsMode(opts.width or 360, items)
	local nav = make("Frame", { Name = "Tabs", Parent = parent, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) },
		{ UI.pad(0, Theme.SPACE.sm, 0, Theme.SPACE.sm), make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, TAB_GAP), FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center }) })
	nav:SetAttribute("Mode", mode)
	for _, item in items do
		local on = item.key == value
		local showLabel = mode == "full" or (mode == "compact" and on)
		local tab = make("TextButton", { Name = "Tab_" .. tostring(item.key), Parent = nav, Text = "", AutoButtonColor = false,
			BackgroundTransparency = 1, Size = UDim2.new(0, showLabel and tabWidth(item) or TAB_ICON_W, 1, 0) },
			{ UI.corner(Theme.RADIUS.control) })
		skin(tab, { BackgroundColor3 = "surfaceHover" })
		tab:SetAttribute("Selected", on)
		local content = make("Frame", { Parent = tab, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) },
			{ make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6),
				FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center }) })
		local glyph = UI.icon(content, item.icon, { color = on and "accent" or "textDim" })
		local label = nil
		if showLabel then
			label = UI.label(content, item.label, { role = "control", color = on and "text" or "textDim", height = 20,
				width = UI.textWidth(item.label, "control") + 2 })
			label.TextTruncate = Enum.TextTruncate.None
		end
		if on then
			local line = make("Frame", { Name = "Indicator", Parent = tab, AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.new(0.5, 0, 1, 0), Size = UDim2.new(1, -8, 0, 2) }, { UI.corner(1) })
			skin(line, { BackgroundColor3 = "accent" })
		else
			tab.MouseEnter:Connect(function()
				if glyph:IsA("ImageLabel") then
					restyle(glyph, { ImageColor3 = "text" })
				end
				if label then
					restyle(label, { TextColor3 = "text" })
				end
			end)
			tab.MouseLeave:Connect(function()
				if glyph:IsA("ImageLabel") then
					restyle(glyph, { ImageColor3 = "textDim" })
				end
				if label then
					restyle(label, { TextColor3 = "textDim" })
				end
			end)
		end
		if not showLabel or item.tip then
			UI.tip(tab, item.tip or item.label)
		end
		tab.MouseButton1Click:Connect(function()
			onChange(item.key)
		end)
	end
	return nav
end

-- ---------------------------------------------------------------------------------------------
-- lists
-- ---------------------------------------------------------------------------------------------
-- a selectable line in a list (effects, elements, clips, issues). opts: selected, onClick, muted, height (28),
-- classIcon (a class name: StudioService icon), icon (a glyph name; a 2.0 text glyph still works), note (dim text on
-- the right), noteWidth, actions = { { icon = glyph / text = 2.0 glyph, tip, color, danger, onClick } }
function UI.item(parent, text, opts)
	opts = opts or {}
	local selected = opts.selected
	local height = opts.height or UI.H_LARGE
	local frame = make("TextButton", { Name = "Item", Parent = parent, Text = "", AutoButtonColor = false,
		BackgroundTransparency = selected and 0 or 1, Size = UDim2.new(1, 0, 0, height) }, { UI.corner(Theme.RADIUS.control) })
	skin(frame, { BackgroundColor3 = selected and "accentSoft" or "surfaceHover" })
	frame:SetAttribute("Selected", selected == true)
	if selected then
		local bar = make("Frame", { Name = "Indicator", Parent = frame, AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.new(0, 2, 1, -8) }, { UI.corner(1) })
		skin(bar, { BackgroundColor3 = "accent" })
	end
	local content = make("Frame", { Parent = frame, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) },
		{ UI.pad(0, 4, 0, 8), UI.hlist(Theme.SPACE.sm, false) })
	local actions = opts.actions or {}
	local rightW = #actions * 24
	local iconW = 0
	local textToken = opts.muted and "textDim" or "text"
	if opts.classIcon then
		local img = UI.icon(content, opts.classIcon, { class = true })
		img.ImageTransparency = opts.muted and 0.5 or 0
		iconW = Theme.ICON + Theme.SPACE.sm
	elseif opts.icon and Icons.has(opts.icon) then
		UI.icon(content, opts.icon, { color = selected and "accent" or "textDim" })
		iconW = Theme.ICON + Theme.SPACE.sm
	elseif opts.icon then -- a 2.0 text glyph
		UI.label(content, opts.icon, { width = 16, color = selected and "accent" or "textDim" })
		iconW = Theme.ICON + Theme.SPACE.sm
	end
	local noteW = opts.note and (opts.noteWidth or 64) or 0
	local name = UI.label(content, text, { role = "body", medium = selected, color = textToken, height = height })
	name.Size = UDim2.new(1, -(rightW + iconW + (noteW > 0 and noteW + Theme.SPACE.sm or 0) + 4), 1, 0)
	if opts.note then
		UI.label(content, opts.note, { role = "meta", dim = true, width = noteW, align = Enum.TextXAlignment.Right, height = height })
	end
	if #actions > 0 then
		local holder = make("Frame", { Parent = content, BackgroundTransparency = 1, Size = UDim2.new(0, rightW, 1, 0) },
			{ UI.hlist(0, false) })
		for _, a in actions do
			if a.icon and Icons.has(a.icon) then
				UI.iconButton(holder, a.icon, a.onClick, { tip = a.tip, danger = a.danger or tokenOf(a.color) == "danger",
					active = a.active, color = a.color, size = 24 })
			else -- a 2.0 text action
				local ab = make("TextButton", textStyle({ Parent = holder, Text = a.text or "", AutoButtonColor = false,
					BackgroundTransparency = 1, Size = UDim2.fromOffset(24, 24) }, "control"), { UI.corner(Theme.RADIUS.control) })
				local map = paintWith(ab, "TextColor3", a.color, "textDim")
				map.BackgroundColor3 = "surfaceHover"
				skin(ab, map)
				ab.MouseEnter:Connect(function()
					ab.BackgroundTransparency = 0
				end)
				ab.MouseLeave:Connect(function()
					ab.BackgroundTransparency = 1
				end)
				ab.MouseButton1Click:Connect(a.onClick)
				if a.tip then
					UI.tip(ab, a.tip)
				end
			end
		end
	end
	frame.MouseEnter:Connect(function()
		if not selected then
			frame.BackgroundTransparency = 0
		end
	end)
	frame.MouseLeave:Connect(function()
		if not selected then
			frame.BackgroundTransparency = 1
		end
	end)
	if opts.onClick then
		frame.MouseButton1Click:Connect(opts.onClick)
	end
	return frame
end

-- a list that scrolls on its own once it gets taller than maxHeight
function UI.scrollList(parent, maxHeight)
	local sf = make("ScrollingFrame", { Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30),
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.Y, VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar })
	skin(sf, { ScrollBarImageColor3 = "scrollbar" })
	local layout = UI.vlist(2)
	layout.Parent = sf
	local function fit()
		sf.Size = UDim2.new(1, 0, 0, math.min(maxHeight, layout.AbsoluteContentSize.Y + 2))
	end
	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fit)
	task.defer(fit)
	return sf
end

-- ---------------------------------------------------------------------------------------------
-- feedback: note, badge, chip, progress, empty state, toast, confirm
-- ---------------------------------------------------------------------------------------------
local KIND_TOKEN = { info = "accent", success = "success", warning = "warning", danger = "danger", error = "danger" }
local KIND_ICON = { info = "infoColor", success = "successColor", warning = "warningColor", danger = "errorColor",
	error = "errorColor" }

local function kindOf(color)
	local token = tokenOf(color)
	if token == "warning" then
		return "warning"
	elseif token == "danger" then
		return "danger"
	elseif token == "success" then
		return "success"
	elseif token == "accent" or token == "accentHover" or token == "info" then
		return "info"
	end
	return nil
end

-- a quiet callout for a state that lasts (one-off results go to UI.toast). Rich text. color: C.warning / C.danger /
-- C.success / C.accent (or a kind name) -> a coloured bar on the left; nil -> neutral.
function UI.note(parent, text, color)
	local kind = KIND_TOKEN[color] and color or kindOf(color)
	local frame = make("Frame", { Name = "Note", Parent = parent, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y },
		{ UI.corner(Theme.RADIUS.control) })
	skin(frame, { BackgroundColor3 = "raised" })
	if kind then -- the bar takes the height of the note (scale only, so it does not feed the automatic size)
		local bar = make("Frame", { Name = "Bar", Parent = frame, Size = UDim2.new(0, 2, 1, 0) })
		skin(bar, { BackgroundColor3 = KIND_TOKEN[kind] })
	end
	local inner = make("Frame", { Parent = frame, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.pad(8, 10, 8, kind and 12 or 10) })
	local props = { Parent = inner, Text = text, BackgroundTransparency = 1, TextWrapped = true, RichText = true,
		TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }
	textStyle(props, "body")
	local l = make("TextLabel", props)
	skin(l, { TextColor3 = kind and "text" or "textDim" })
	return frame
end

-- a small count / status pill. kind: "neutral" (default), "accent", "success", "warning", "danger"
function UI.badge(parent, text, kind)
	kind = kind or "neutral"
	local props = { Name = "Badge", Parent = parent, Text = text, AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 16) }
	textStyle(props, "meta", "Medium")
	local b = make("TextLabel", props, { UI.corner(8), UI.pad(0, 6, 0, 6) })
	if kind == "accent" then
		skin(b, { BackgroundColor3 = "accent", TextColor3 = "accentText" })
	elseif KIND_TOKEN[kind] then
		skin(b, { BackgroundColor3 = KIND_TOKEN[kind] .. "Soft", TextColor3 = KIND_TOKEN[kind] })
	else
		skin(b, { BackgroundColor3 = "raised", TextColor3 = "textDim" })
	end
	return b
end

-- a pill you can select (filters) or remove. opts: selected, onClick, icon, onRemove, tip
function UI.chip(parent, text, opts)
	opts = opts or {}
	local selected = opts.selected
	local props = { Name = "Chip", Parent = parent, Text = text, AutoButtonColor = false, AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, UI.H) }
	textStyle(props, "control", selected and "Medium" or "Regular")
	local b = make("TextButton", props, { UI.corner(UI.H // 2),
		UI.pad(0, opts.onRemove and 26 or 10, 0, opts.icon and 28 or 10), UI.stroke(selected and "accent" or "border") })
	skin(b, { BackgroundColor3 = selected and "accentSoft" or "raised", TextColor3 = selected and "text" or "textDim" })
	b:SetAttribute("Selected", selected == true)
	if opts.icon then
		UI.icon(b, opts.icon, { size = 14, color = selected and "accent" or "textDim", anchor = Vector2.new(0, 0.5),
			position = UDim2.new(0, -20, 0.5, 0) })
	end
	if opts.onRemove then
		local x = UI.iconButton(b, "close", opts.onRemove, { size = 18, iconSize = 12, tip = "Scoate" })
		x.AnchorPoint = Vector2.new(0, 0.5)
		x.Position = UDim2.new(1, 4, 0.5, 0)
	end
	if not selected then
		b.MouseEnter:Connect(function()
			restyle(b, { TextColor3 = "text" })
		end)
		b.MouseLeave:Connect(function()
			restyle(b, { TextColor3 = "textDim" })
		end)
	end
	if opts.onClick then
		b.MouseButton1Click:Connect(opts.onClick)
	end
	if opts.tip then
		UI.tip(b, opts.tip)
	end
	return b
end

-- a thin progress bar. Returns the track and set(fraction). opts: height (4), color (token, default "accent")
function UI.progress(parent, fraction, opts)
	opts = opts or {}
	local track = make("Frame", { Name = "Progress", Parent = parent, Size = UDim2.new(1, 0, 0, opts.height or 4) },
		{ UI.corner(2) })
	skin(track, { BackgroundColor3 = "raised" })
	local fill = make("Frame", { Name = "Fill", Parent = track, Size = UDim2.new(math.clamp(fraction or 0, 0, 1), 0, 1, 0) },
		{ UI.corner(2) })
	skin(fill, { BackgroundColor3 = opts.color or "accent" })
	local function set(f)
		animate(fill, { Size = UDim2.new(math.clamp(f or 0, 0, 1), 0, 1, 0) }, Theme.MOTION.slow)
	end
	return track, set
end

-- an empty state: one short sentence and at most one primary action. opts: icon (glyph), title
function UI.empty(parent, text, actionText, onAction, opts)
	opts = opts or {}
	local frame = make("Frame", { Name = "Empty", Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.pad(Theme.SPACE.xl, Theme.PAD, Theme.SPACE.xl, Theme.PAD),
		make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, Theme.SPACE.sm),
			HorizontalAlignment = Enum.HorizontalAlignment.Center }) })
	if opts.icon then
		UI.icon(frame, opts.icon, { size = 24, color = "textDisabled" })
	end
	if opts.title then
		UI.label(frame, opts.title, { role = "emphasis", align = Enum.TextXAlignment.Center, height = 20 })
	end
	UI.label(frame, text, { dim = true, wrap = true, align = Enum.TextXAlignment.Center })
	if actionText and onAction then
		UI.spacer(frame, 2)
		UI.button(frame, actionText, onAction, { style = "primary", autoWidth = true, height = UI.H_LARGE })
	end
	return frame
end

-- a message at the bottom of the window that goes away by itself. kind: "info" (default) / "success" / "warning" /
-- "error". opts: duration (seconds; 4, errors 6; 0 = until closed), action = { text, onClick }.
-- Returns { dismiss = fn, frame = Frame } (nil before UI.setRoot).
local toasts = {}
function UI.toast(text, kind, opts)
	opts = opts or {}
	kind = KIND_ICON[kind or "info"] and (kind or "info") or "info"
	if not toastHost then
		return nil
	end
	local frame = make("Frame", { Name = "Toast", Parent = toastHost, Active = true, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.corner(Theme.RADIUS.surface), UI.stroke("border"), UI.pad(8, 4, 8, 10) })
	skin(frame, { BackgroundColor3 = "surface" })
	frame:SetAttribute("Kind", kind)
	local actionW = opts.action and (UI.textWidth(opts.action.text, "control") + 20) or 0
	UI.icon(frame, KIND_ICON[kind], { anchor = Vector2.new(0, 0.5), position = UDim2.new(0, 0, 0.5, 0) })
	local props = { Parent = frame, Text = text, BackgroundTransparency = 1, TextWrapped = true, RichText = true,
		TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(24, 0),
		Size = UDim2.new(1, -(24 + actionW + 28), 0, 0), AutomaticSize = Enum.AutomaticSize.Y }
	textStyle(props, "body")
	local message = make("TextLabel", props, { make("UISizeConstraint", { MinSize = Vector2.new(0, 20) }) })
	skin(message, { TextColor3 = "text" })
	local handle
	local function dismiss()
		local i = table.find(toasts, handle)
		if i then
			table.remove(toasts, i)
		end
		frame:Destroy()
	end
	handle = { dismiss = dismiss, frame = frame }
	if opts.action then
		local b = UI.button(frame, opts.action.text, function()
			dismiss()
			opts.action.onClick()
		end, { style = "link", width = actionW })
		b.AnchorPoint = Vector2.new(1, 0.5)
		b.Position = UDim2.new(1, -28, 0.5, 0)
	end
	local close = UI.iconButton(frame, "close", dismiss, { size = 20, iconSize = 12, tip = "Închide" })
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.new(1, 0, 0.5, 0)
	raise(frame, 47)
	table.insert(toasts, handle)
	while #toasts > 3 do
		toasts[1].dismiss()
	end
	local duration = opts.duration or (kind == "error" and 6 or 4)
	if duration > 0 then
		task.delay(duration, function()
			if frame.Parent then
				dismiss()
			end
		end)
	end
	return handle
end

-- a small modal: title, one or two sentences, Cancel + the action. Escape or a click outside cancels.
-- opts: cancelText ("Anulează"), danger (the action destroys something: red button), onCancel
function UI.confirm(title, text, confirmText, onConfirm, opts)
	opts = opts or {}
	if not overlay then
		return nil
	end
	UI.closePopup()
	popupState = { modal = true, onCancel = opts.onCancel }
	overlay.Visible = true
	local scrim = make("Frame", { Name = "Scrim", Parent = overlay, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 0.5,
		ZIndex = 51 })
	skin(scrim, { BackgroundColor3 = "scrim" })
	local width = math.min(320, math.max(200, root.AbsoluteSize.X - Theme.SPACE.xl * 2))
	local dialog = make("Frame", { Name = "Dialog", Parent = overlay, Active = true, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(width, 0), AutomaticSize = Enum.AutomaticSize.Y, ZIndex = 52 },
		{ UI.corner(Theme.RADIUS.surface), UI.stroke("border"), UI.pad(Theme.SPACE.lg, Theme.SPACE.lg, Theme.SPACE.lg, Theme.SPACE.lg), UI.vlist(Theme.SPACE.sm) })
	skin(dialog, { BackgroundColor3 = "surface" })
	UI.label(dialog, title, { role = "emphasis", color = "textBright", height = 20 })
	if text and text ~= "" then
		UI.label(dialog, text, { dim = true, wrap = true })
	end
	UI.spacer(dialog, 4)
	local buttons = make("Frame", { Parent = dialog, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H_LARGE) },
		{ make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, Theme.SPACE.sm),
			FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Center }) })
	UI.button(buttons, opts.cancelText or "Anulează", cancelPopup, { autoWidth = true, height = UI.H_LARGE })
	UI.button(buttons, confirmText, function()
		UI.closePopup()
		onConfirm()
	end, { style = opts.danger and "destructive" or "primary", autoWidth = true, height = UI.H_LARGE })
	raise(dialog, 53)
	return dialog
end

return UI
