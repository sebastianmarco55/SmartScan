-- LostCube UI kit: the controls the panels are made of (dark theme, violet accent).
-- Everything is plain Roblox GUI, so the same panels run in the plugin's dock widget and in a ScreenGui.
local UI = {}

UI.C = {
	bg = Color3.fromRGB(28, 28, 32),
	section = Color3.fromRGB(36, 36, 42),
	header = Color3.fromRGB(44, 44, 52),
	item = Color3.fromRGB(52, 52, 61),
	hover = Color3.fromRGB(64, 64, 75),
	input = Color3.fromRGB(21, 21, 25),
	border = Color3.fromRGB(62, 62, 72),
	text = Color3.fromRGB(234, 234, 242),
	dim = Color3.fromRGB(150, 150, 166),
	accent = Color3.fromRGB(155, 92, 255),
	accentHover = Color3.fromRGB(172, 120, 255),
	accentDark = Color3.fromRGB(74, 50, 125),
	good = Color3.fromRGB(76, 195, 138),
	danger = Color3.fromRGB(229, 72, 77),
	warn = Color3.fromRGB(242, 169, 59),
}
UI.FONT = Enum.Font.BuilderSans
UI.FONT_MED = Enum.Font.BuilderSansMedium
UI.FONT_BOLD = Enum.Font.BuilderSansBold
UI.H = 24 -- row height
UI.LABEL_W = 104

local C = UI.C
local order = 0
local root, overlay
UI.collapsed = {} -- section title -> collapsed (survives re-renders)

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

function UI.corner(r)
	return make("UICorner", { CornerRadius = UDim.new(0, r or 4) })
end

function UI.stroke(color, thickness)
	return make("UIStroke", { Color = color or C.border, Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
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
-- root + overlay (menus and pickers float above everything)
-- ---------------------------------------------------------------------------------------------
function UI.setRoot(frame)
	root = frame
	overlay = make("TextButton", { Name = "Overlay", Parent = frame, Size = UDim2.fromScale(1, 1), Text = "",
		AutoButtonColor = false, BackgroundTransparency = 1, Visible = false, ZIndex = 50 })
	overlay.MouseButton1Click:Connect(function()
		UI.closePopup()
	end)
end

function UI.closePopup()
	if not overlay then
		return
	end
	for _, child in overlay:GetChildren() do
		child:Destroy()
	end
	overlay.Visible = false
end

local function popup(anchor, width, height)
	UI.closePopup()
	overlay.Visible = true
	local rootPos = root.AbsolutePosition
	local x = anchor.AbsolutePosition.X - rootPos.X
	local y = anchor.AbsolutePosition.Y - rootPos.Y + anchor.AbsoluteSize.Y + 2
	local maxY = root.AbsoluteSize.Y - height - 6
	if y > maxY then
		y = math.max(6, anchor.AbsolutePosition.Y - rootPos.Y - height - 2)
	end
	x = math.clamp(x, 4, math.max(4, root.AbsoluteSize.X - width - 4))
	local frame = make("Frame", { Parent = overlay, Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(width, height),
		BackgroundColor3 = C.header, ZIndex = 51 }, { UI.corner(6), UI.stroke(C.accentDark) })
	return frame
end

-- ---------------------------------------------------------------------------------------------
-- basic controls
-- ---------------------------------------------------------------------------------------------
function UI.label(parent, text, opts)
	opts = opts or {}
	return make("TextLabel", { Parent = parent, Text = text, Font = opts.bold and UI.FONT_BOLD or (opts.medium and UI.FONT_MED or UI.FONT),
		TextSize = opts.size or 13, TextColor3 = opts.color or (opts.dim and C.dim or C.text), BackgroundTransparency = 1,
		TextXAlignment = opts.align or Enum.TextXAlignment.Left, TextWrapped = opts.wrap or false, RichText = opts.rich or false,
		Size = opts.wrap and UDim2.new(1, 0, 0, 0) or (opts.width and UDim2.new(0, opts.width, 0, UI.H) or UDim2.new(1, 0, 0, opts.height or UI.H)),
		AutomaticSize = opts.wrap and Enum.AutomaticSize.Y or Enum.AutomaticSize.None, TextTruncate = opts.wrap and Enum.TextTruncate.None
			or Enum.TextTruncate.AtEnd })
end

local STYLES = {
	primary = { bg = C.accent, hover = C.accentHover, text = Color3.new(1, 1, 1) },
	normal = { bg = C.item, hover = C.hover, text = C.text },
	ghost = { bg = C.section, hover = C.item, text = C.dim, transparent = true },
	danger = { bg = Color3.fromRGB(90, 36, 42), hover = C.danger, text = C.text },
	selected = { bg = C.accentDark, hover = Color3.fromRGB(92, 62, 150), text = Color3.new(1, 1, 1) },
}

function UI.button(parent, text, onClick, opts)
	opts = opts or {}
	local style = STYLES[opts.selected and "selected" or (opts.style or "normal")]
	local b = make("TextButton", { Parent = parent, Text = text, Font = opts.bold and UI.FONT_BOLD or UI.FONT_MED,
		TextSize = opts.textSize or 13, TextColor3 = style.text, AutoButtonColor = false, BackgroundColor3 = style.bg,
		BackgroundTransparency = style.transparent and 1 or 0,
		Size = opts.width and UDim2.new(0, opts.width, 0, opts.height or UI.H) or UDim2.new(opts.scale or 1, 0, 0, opts.height or UI.H),
		TextXAlignment = opts.align or Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd },
		{ UI.corner(4), UI.pad(0, 8, 0, 8) })
	if opts.selected then
		UI.stroke(C.accent).Parent = b
	end
	b.MouseEnter:Connect(function()
		b.BackgroundColor3 = style.hover
		b.BackgroundTransparency = 0
	end)
	b.MouseLeave:Connect(function()
		b.BackgroundColor3 = style.bg
		b.BackgroundTransparency = style.transparent and 1 or 0
	end)
	if onClick then
		b.MouseButton1Click:Connect(onClick)
	end
	if opts.tip then
		b:SetAttribute("Tip", opts.tip)
	end
	return b
end

function UI.hstack(parent, opts)
	opts = opts or {}
	local f = make("Frame", { Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, opts.height or UI.H) },
		{ UI.hlist(opts.gap or 4, opts.fill ~= false) })
	return f
end

function UI.vstack(parent, gap)
	return make("Frame", { Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.vlist(gap or 4) })
end

-- a labelled row: returns the area where the controls go (they share the width)
function UI.row(parent, text, opts)
	opts = opts or {}
	local row = make("Frame", { Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H) },
		{ UI.hlist(6, false) })
	UI.label(row, text, { width = opts.labelWidth or UI.LABEL_W, dim = true, size = 12 })
	local area = make("Frame", { Parent = row, BackgroundTransparency = 1,
		Size = UDim2.new(1, -((opts.labelWidth or UI.LABEL_W) + 6), 1, 0) }, { UI.hlist(4, true) })
	return area
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

function UI.number(parent, value, onChange, opts)
	opts = opts or {}
	local box = make("TextBox", { Parent = parent, Text = fmt(value, opts.decimals), Font = UI.FONT, TextSize = 13,
		TextColor3 = C.text, PlaceholderColor3 = C.dim, BackgroundColor3 = C.input, ClearTextOnFocus = false,
		Size = opts.width and UDim2.new(0, opts.width, 0, UI.H) or UDim2.new(1, 0, 0, UI.H) },
		{ UI.corner(4), UI.stroke(C.border), UI.pad(0, 6, 0, 6) })
	local current = value
	local function commit(v)
		if opts.min then
			v = math.max(opts.min, v)
		end
		if opts.max then
			v = math.min(opts.max, v)
		end
		current = v
		box.Text = fmt(v, opts.decimals)
		if onChange then
			onChange(v)
		end
	end
	box.FocusLost:Connect(function()
		local v = tonumber((box.Text:gsub(",", ".")))
		if v and v ~= current then
			commit(v)
		else
			box.Text = fmt(current, opts.decimals)
		end
	end)
	-- mouse wheel nudges the value (Shift = x10)
	box.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseWheel and not box:IsFocused() then
			local step = opts.step or 0.1
			local shift = game:GetService("UserInputService"):IsKeyDown(Enum.KeyCode.LeftShift)
			commit(current + (input.Position.Z > 0 and 1 or -1) * step * (shift and 10 or 1))
		end
	end)
	if opts.tip then
		box:SetAttribute("Tip", opts.tip)
	end
	return box
end

function UI.textbox(parent, value, onChange, opts)
	opts = opts or {}
	local box = make("TextBox", { Parent = parent, Text = value or "", PlaceholderText = opts.placeholder or "",
		Font = UI.FONT, TextSize = 13, TextColor3 = C.text, PlaceholderColor3 = C.dim, BackgroundColor3 = C.input,
		ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
		Size = opts.width and UDim2.new(0, opts.width, 0, UI.H) or UDim2.new(1, 0, 0, UI.H) },
		{ UI.corner(4), UI.stroke(C.border), UI.pad(0, 6, 0, 6) })
	box.FocusLost:Connect(function(enter)
		if onChange and box.Text ~= value then
			onChange(box.Text, enter)
		end
	end)
	return box
end

function UI.toggle(parent, value, onChange, text, opts)
	opts = opts or {}
	return UI.button(parent, (value and "✓ " or "") .. text, function()
		onChange(not value)
	end, { selected = value, width = opts.width, scale = opts.scale, tip = opts.tip })
end

function UI.segmented(parent, items, value, onChange)
	local bar = make("Frame", { Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H) },
		{ UI.hlist(2, true) })
	for _, item in items do
		UI.button(bar, item.label, function()
			onChange(item.value)
		end, { selected = item.value == value, textSize = 12 })
	end
	return bar
end

-- items: { { value =, label =, header = bool } }
function UI.dropdown(parent, items, value, onChange, opts)
	opts = opts or {}
	local current = opts.text
	for _, item in items do
		if not item.header and item.value == value then
			current = current or item.label
		end
	end
	local b
	b = UI.button(parent, (current or opts.placeholder or "-") .. "   ▼", function()
		local rows, height = 0, 0
		for _, item in items do
			rows += 1
			height += item.header and 20 or 22
		end
		local width = math.max(b.AbsoluteSize.X, opts.menuWidth or 170)
		local frame = popup(b, width, math.min(height + 8, 320))
		local scroll = make("ScrollingFrame", { Parent = frame, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
			CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4, ZIndex = 52 },
			{ UI.vlist(0), UI.pad(4, 4, 4, 4) })
		for _, item in items do
			if item.header then
				make("TextLabel", { Parent = scroll, Text = item.label, Font = UI.FONT_BOLD, TextSize = 11, TextColor3 = C.accent,
					BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), TextXAlignment = Enum.TextXAlignment.Left,
					ZIndex = 53 }, { UI.pad(0, 6, 0, 6) })
			else
				local row = make("TextButton", { Parent = scroll, Text = item.label, Font = UI.FONT, TextSize = 13,
					TextColor3 = item.value == value and C.accentHover or C.text, AutoButtonColor = false,
					BackgroundColor3 = C.hover, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22),
					TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 53 }, { UI.corner(3), UI.pad(0, 8, 0, 8) })
				row.MouseEnter:Connect(function()
					row.BackgroundTransparency = 0
				end)
				row.MouseLeave:Connect(function()
					row.BackgroundTransparency = 1
				end)
				row.MouseButton1Click:Connect(function()
					UI.closePopup()
					onChange(item.value)
				end)
			end
		end
	end, { align = Enum.TextXAlignment.Left, width = opts.width, scale = opts.scale, style = opts.style })
	return b
end

local PALETTE = {
	"FFFFFF", "D9D9E6", "8C8CA0", "3C3C48", "141418", "000000",
	"9B5CFF", "6A2EFF", "C9A6FF", "4B1FA0", "FF5CF0", "FF9BE8",
	"5CD9FF", "2E8CFF", "A6F0FF", "1F4BA0", "5CFFB4", "2EC46E",
	"FFE15C", "FFB02E", "FF6A2E", "FF2E2E", "A01F1F", "6E3A1F",
}

function UI.color(parent, color, onChange, opts)
	opts = opts or {}
	local b = make("TextButton", { Parent = parent, Text = "", AutoButtonColor = false, BackgroundColor3 = color,
		Size = opts.width and UDim2.new(0, opts.width, 0, UI.H) or UDim2.new(1, 0, 0, UI.H) },
		{ UI.corner(4), UI.stroke(C.border) })
	make("TextLabel", { Parent = b, Text = "#" .. color:ToHex():upper(), Font = UI.FONT, TextSize = 11, BackgroundTransparency = 1,
		TextColor3 = (color.R * 0.3 + color.G * 0.59 + color.B * 0.11) > 0.55 and Color3.new(0, 0, 0) or Color3.new(1, 1, 1),
		Size = UDim2.fromScale(1, 1) })
	b.MouseButton1Click:Connect(function()
		local frame = popup(b, 190, 186)
		make("Frame", { Parent = frame, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 128), Position = UDim2.fromOffset(0, 0),
			ZIndex = 52 }, { UI.pad(8, 8, 0, 8), make("UIGridLayout", { CellSize = UDim2.fromOffset(25, 25),
				CellPadding = UDim2.fromOffset(4, 4), SortOrder = Enum.SortOrder.LayoutOrder }) })
		local grid = frame:FindFirstChildOfClass("Frame")
		for _, hex in PALETTE do
			local sw = make("TextButton", { Parent = grid, Text = "", AutoButtonColor = false, BackgroundColor3 = Color3.fromHex(hex),
				ZIndex = 53 }, { UI.corner(4), UI.stroke(C.border) })
			sw.MouseButton1Click:Connect(function()
				UI.closePopup()
				onChange(Color3.fromHex(hex))
			end)
		end
		local box = make("TextBox", { Parent = frame, Text = color:ToHex():upper(), PlaceholderText = "hex (ex. 9B5CFF)",
			Font = UI.FONT, TextSize = 13, TextColor3 = C.text, BackgroundColor3 = C.input, ClearTextOnFocus = false,
			Position = UDim2.fromOffset(8, 146), Size = UDim2.new(1, -16, 0, 26), ZIndex = 53 },
			{ UI.corner(4), UI.stroke(C.border), UI.pad(0, 6, 0, 6) })
		box.FocusLost:Connect(function(enter)
			local hex = box.Text:gsub("#", ""):gsub("%s", "")
			local ok, c = pcall(Color3.fromHex, hex)
			if ok and c then
				UI.closePopup()
				onChange(c)
			end
		end)
	end)
	return b
end

-- collapsible section; returns its body (a vertical stack)
function UI.section(parent, title, opts)
	opts = opts or {}
	local key = opts.key or title
	if UI.collapsed[key] == nil then
		UI.collapsed[key] = opts.collapsed or false
	end
	local collapsed = UI.collapsed[key]
	local frame = make("Frame", { Parent = parent, BackgroundColor3 = C.section, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.corner(6), UI.vlist(0) })
	local head = make("TextButton", { Parent = frame, Text = "", AutoButtonColor = false, BackgroundColor3 = C.header,
		BackgroundTransparency = collapsed and 1 or 0, Size = UDim2.new(1, 0, 0, 28) }, { UI.corner(6), UI.pad(0, 8, 0, 8),
		UI.hlist(6, false) })
	local arrow = UI.label(head, collapsed and "►" or "▼", { width = 12, dim = true, size = 12 })
	local t = UI.label(head, title, { medium = true, size = 13, width = 220 })
	t.Size = UDim2.new(1, -18 - (opts.rightWidth or 0), 1, 0)
	if opts.right then
		local right = make("Frame", { Parent = head, BackgroundTransparency = 1, Size = UDim2.new(0, opts.rightWidth or 60, 1, 0) },
			{ UI.hlist(3, false) })
		opts.right(right)
	end
	local body = make("Frame", { Parent = frame, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y, Visible = not collapsed }, { UI.pad(6, 8, 8, 8), UI.vlist(4) })
	head.MouseButton1Click:Connect(function()
		-- applied right here (no redraw of the whole panel); the state survives re-renders in UI.collapsed
		collapsed = not collapsed
		UI.collapsed[key] = collapsed
		arrow.Text = collapsed and "►" or "▼"
		head.BackgroundTransparency = collapsed and 1 or 0
		body.Visible = not collapsed
		if opts.onToggle then
			opts.onToggle(collapsed)
		end
	end)
	return body
end

-- a selectable line in a list (effects, elements, clips)
function UI.item(parent, text, opts)
	opts = opts or {}
	local selected = opts.selected
	local frame = make("TextButton", { Parent = parent, Text = "", AutoButtonColor = false,
		BackgroundColor3 = selected and C.accentDark or C.item, BackgroundTransparency = selected and 0 or 0.35,
		Size = UDim2.new(1, 0, 0, opts.height or 26) }, { UI.corner(4), UI.pad(0, 4, 0, 8), UI.hlist(4, false) })
	if selected then
		UI.stroke(C.accent).Parent = frame
	end
	local actions = opts.actions or {}
	local rightW = #actions * 26
	if opts.icon then
		UI.label(frame, opts.icon, { width = 16, color = selected and Color3.new(1, 1, 1) or C.accent, size = 13 })
	end
	local name = UI.label(frame, text, { medium = selected, size = 13, color = opts.muted and C.dim or C.text })
	name.Size = UDim2.new(1, -(rightW + (opts.icon and 20 or 0) + (opts.note and 64 or 0) + 4), 1, 0)
	if opts.note then
		UI.label(frame, opts.note, { width = 60, dim = true, size = 11, align = Enum.TextXAlignment.Right })
	end
	for _, a in actions do
		local ab = make("TextButton", { Parent = frame, Text = a.text, Font = UI.FONT_MED, TextSize = 12,
			TextColor3 = a.color or C.dim, AutoButtonColor = false, BackgroundColor3 = C.hover, BackgroundTransparency = 1,
			Size = UDim2.fromOffset(22, 20) }, { UI.corner(3) })
		ab.MouseEnter:Connect(function()
			ab.BackgroundTransparency = 0
		end)
		ab.MouseLeave:Connect(function()
			ab.BackgroundTransparency = 1
		end)
		ab.MouseButton1Click:Connect(a.onClick)
	end
	frame.MouseEnter:Connect(function()
		if not selected then
			frame.BackgroundTransparency = 0
		end
	end)
	frame.MouseLeave:Connect(function()
		if not selected then
			frame.BackgroundTransparency = 0.35
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
		ScrollBarImageColor3 = C.hover, ScrollingDirection = Enum.ScrollingDirection.Y,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar })
	local layout = UI.vlist(3)
	layout.Parent = sf
	local function fit()
		sf.Size = UDim2.new(1, 0, 0, math.min(maxHeight, layout.AbsoluteContentSize.Y + 2))
	end
	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fit)
	task.defer(fit)
	return sf
end

function UI.note(parent, text, color)
	return make("Frame", { Parent = parent, BackgroundColor3 = C.input, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.corner(4), UI.pad(6, 8, 6, 8),
		make("TextLabel", { Text = text, Font = UI.FONT, TextSize = 12, TextColor3 = color or C.dim, BackgroundTransparency = 1,
			TextWrapped = true, RichText = true, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y }) })
end

function UI.spacer(parent, h)
	return make("Frame", { Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, h or 4) })
end

return UI
