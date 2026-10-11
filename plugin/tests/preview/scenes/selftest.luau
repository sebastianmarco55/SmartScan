-- Renderer self-test (python3 plugin/tests/preview/render.py --tab Selftest): one screen with the Roblox GUI features render.py
-- must reproduce, built with plain Instance.new (no plugin code). Compare it with what Roblox does for each labelled block.
local LC, P, ARGS, common = ...
local env = LC.env()
P.install(env)
local Instance, UDim2, UDim, Color3, Vector2, Enum, Font = env.Instance, env.UDim2, env.UDim, env.Color3, env.Vector2, env.Enum, env.Font
local root = P.newRoot(ARGS.width, ARGS.height)
local order = 0

local function make(class, props, children)
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
	for _, c in children or {} do
		c.Parent = inst
	end
	inst.Parent = parent
	return inst
end
local function rgb(r, g, b) return Color3.fromRGB(r, g, b) end
local function list(gap, dir) return make("UIListLayout", { Padding = UDim.new(0, gap or 4), SortOrder = Enum.SortOrder.LayoutOrder,
	FillDirection = dir or Enum.FillDirection.Vertical }) end
local function pad(t, r, b, l) return make("UIPadding", { PaddingTop = UDim.new(0, t), PaddingRight = UDim.new(0, r or t),
	PaddingBottom = UDim.new(0, b or t), PaddingLeft = UDim.new(0, l or r or t) }) end
local function corner(r) return make("UICorner", { CornerRadius = UDim.new(0, r) }) end
local function stroke(color, thick, mode, transp) return make("UIStroke", { Color = color, Thickness = thick,
	ApplyStrokeMode = mode or Enum.ApplyStrokeMode.Border, Transparency = transp or 0 }) end
local TEXT = rgb(230, 230, 240)
local function label(parent, text, props)
	local p = { Parent = parent, Text = text, TextSize = 12, TextColor3 = TEXT, BackgroundTransparency = 1,
		FontFace = Font.fromName("BuilderSans"), Size = UDim2.new(1, 0, 0, 16), TextXAlignment = Enum.TextXAlignment.Left }
	for k, v in props or {} do p[k] = v end
	return make("TextLabel", p)
end
local function box(parent, color, size, props)
	local p = { Parent = parent, BackgroundColor3 = color, Size = size }
	for k, v in props or {} do p[k] = v end
	return make("Frame", p)
end
local function title(parent, text) return label(parent, text, { TextSize = 11, TextColor3 = rgb(150, 150, 170), Size = UDim2.new(1, 0, 0, 14),
	FontFace = Font.fromName("BuilderSans", Enum.FontWeight.Bold) }) end

local bg = make("Frame", { Parent = root, Size = UDim2.fromScale(1, 1), BackgroundColor3 = rgb(36, 36, 42) })
local scroll = make("ScrollingFrame", { Parent = bg, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 6, ScrollBarImageColor3 = rgb(90, 90, 110),
	VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar })
local body = make("Frame", { Parent = scroll, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y },
	{ pad(8, 8, 8, 8), list(8) })
local A, B, Cc, D, E = rgb(155, 92, 255), rgb(0, 162, 255), rgb(76, 195, 138), rgb(242, 169, 59), rgb(229, 72, 77)

-- 1. anchor / position / rotation
title(body, "1  AnchorPoint, Position scale + offset, Rotation (a cross of 4 boxes, a rotated one)")
local area = box(body, rgb(52, 52, 61), UDim2.new(1, 0, 0, 90))
box(area, A, UDim2.fromOffset(30, 30), { Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5) })
box(area, B, UDim2.fromOffset(20, 20), { Position = UDim2.new(1, -4, 1, -4), AnchorPoint = Vector2.new(1, 1) })
box(area, Cc, UDim2.fromOffset(20, 20), { Position = UDim2.fromOffset(4, 4) })
box(area, D, UDim2.fromOffset(40, 16), { Position = UDim2.fromScale(0.75, 0.3), AnchorPoint = Vector2.new(0.5, 0.5), Rotation = 30 })

-- 2. lists
title(body, "2  UIListLayout: vertical gap 6 | horizontal Fill (3 equal) | SpaceBetween | right aligned | Wraps")
local v = box(body, rgb(52, 52, 61), UDim2.new(1, 0, 0, 0), { AutomaticSize = Enum.AutomaticSize.Y }); list(6).Parent = v; pad(6).Parent = v
for i = 1, 2 do box(v, A, UDim2.new(1, 0, 0, 14)) end
local row = box(body, rgb(52, 52, 61), UDim2.new(1, 0, 0, 26), {})
make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), HorizontalFlex = Enum.UIFlexAlignment.Fill,
	VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }).Parent = row
for _, c in { A, B, Cc } do box(row, c, UDim2.new(1, 0, 0, 20)) end
local row2 = box(body, rgb(52, 52, 61), UDim2.new(1, 0, 0, 26), {})
make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalFlex = Enum.UIFlexAlignment.SpaceBetween,
	VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }).Parent = row2
for _, c in { A, B, Cc } do box(row2, c, UDim2.fromOffset(50, 20)) end
local row3 = box(body, rgb(52, 52, 61), UDim2.new(1, 0, 0, 26), {})
make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = UDim.new(0, 4),
	VerticalAlignment = Enum.VerticalAlignment.Bottom, SortOrder = Enum.SortOrder.LayoutOrder }).Parent = row3
for _, c in { A, B } do box(row3, c, UDim2.fromOffset(40, 14)) end
local row4 = box(body, rgb(52, 52, 61), UDim2.new(1, 0, 0, 0), { AutomaticSize = Enum.AutomaticSize.Y })
make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Wraps = true, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }).Parent = row4
for i = 1, 9 do box(row4, i % 2 == 0 and A or B, UDim2.fromOffset(60, 14)) end
local row5 = box(body, rgb(52, 52, 61), UDim2.new(1, 0, 0, 24), {})
make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }).Parent = row5
box(row5, A, UDim2.fromOffset(40, 20)); local grow = box(row5, B, UDim2.fromOffset(40, 20)); make("UIFlexItem", { FlexMode = Enum.UIFlexMode.Grow }).Parent = grow
box(row5, Cc, UDim2.fromOffset(40, 20))

-- 3. grid
title(body, "3  UIGridLayout 40x28, padding 4")
local grid = box(body, rgb(52, 52, 61), UDim2.new(1, 0, 0, 70), {})
make("UIGridLayout", { CellSize = UDim2.fromOffset(40, 28), CellPadding = UDim2.fromOffset(4, 4), SortOrder = Enum.SortOrder.LayoutOrder }).Parent = grid
for i = 1, 14 do box(grid, i % 3 == 0 and Cc or A, UDim2.fromOffset(5, 5)) end

-- 4. auto size
title(body, "4  AutomaticSize.Y + UIPadding 6 + wrapped text; AutomaticSize.XY tooltip-like label")
local note = box(body, rgb(21, 21, 25), UDim2.new(1, 0, 0, 0), { AutomaticSize = Enum.AutomaticSize.Y }); corner(4).Parent = note; pad(6, 8).Parent = note
label(note, "Un text mai lung care trebuie să treacă pe mai multe rânduri, iar cutia din jurul lui crește odată cu el.",
	{ TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
local tip = label(body, "tooltip", { AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(0, 0, 0, 0), BackgroundTransparency = 0,
	BackgroundColor3 = rgb(21, 21, 25), TextXAlignment = Enum.TextXAlignment.Center }); corner(4).Parent = tip; pad(3, 6).Parent = tip; stroke(A, 1).Parent = tip

-- 5. zindex
title(body, "5  ZIndex: the first (green) is drawn above the second (violet) although later")
local z = box(body, rgb(52, 52, 61), UDim2.new(1, 0, 0, 44))
box(z, Cc, UDim2.fromOffset(60, 30), { Position = UDim2.fromOffset(10, 6), ZIndex = 3 })
box(z, A, UDim2.fromOffset(60, 30), { Position = UDim2.fromOffset(40, 12), ZIndex = 1 })

-- 6. corner / stroke
title(body, "6  UICorner (4, 12, pill), UIStroke Border 2px, 50% transparent stroke, text stroke")
local cs = box(body, rgb(52, 52, 61), UDim2.new(1, 0, 0, 40), {})
make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = cs
pad(0, 8).Parent = cs
local b1 = box(cs, A, UDim2.fromOffset(50, 26)); corner(4).Parent = b1
local b2 = box(cs, B, UDim2.fromOffset(50, 26)); corner(12).Parent = b2; stroke(rgb(255, 255, 255), 2).Parent = b2
local b3 = box(cs, Cc, UDim2.fromOffset(50, 26)); make("UICorner", { CornerRadius = UDim.new(1, 0) }).Parent = b3; stroke(rgb(255, 255, 255), 3, nil, 0.5).Parent = b3
local b4 = label(cs, "Strok", { Size = UDim2.fromOffset(50, 26), TextSize = 16, TextXAlignment = Enum.TextXAlignment.Center })
stroke(rgb(0, 0, 0), 1.5, Enum.ApplyStrokeMode.Contextual).Parent = b4

-- 7. gradient
title(body, "7  UIGradient (left violet -> right blue, with transparency fade)")
local g = box(body, rgb(255, 255, 255), UDim2.new(1, 0, 0, 24)); corner(4).Parent = g
make("UIGradient", { Color = env.ColorSequence.new(A, B), Transparency = env.NumberSequence.new({ env.NumberSequenceKeypoint.new(0, 0),
	env.NumberSequenceKeypoint.new(1, 0.7) }) }).Parent = g

-- 8. text
title(body, "8  Text: left / center / right, truncation, wrap, RichText, bold weight, line height 1.4, mono")
label(body, "left aligned"); label(body, "center aligned", { TextXAlignment = Enum.TextXAlignment.Center }); label(body, "right aligned", { TextXAlignment = Enum.TextXAlignment.Right })
label(body, "A very long line that does not fit and is cut with an ellipsis at the end of the available width", { TextTruncate = Enum.TextTruncate.AtEnd })
label(body, "<b>bold</b> <i>italic</i> <u>under</u> <s>strike</s> <font color=\"#9B5CFF\">violet</font> <font size=\"16\">big</font> <uc>caps</uc>",
	{ RichText = true })
label(body, "Wrapped with line height 1.4: the second and third lines are spaced by 1.4 x the text size on this text label here.",
	{ TextWrapped = true, LineHeight = 1.4, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
label(body, "local x = 1 -- mono", { FontFace = Font.fromName("BuilderMono") })
label(body, "Emoji 🧠 ✨ ▼ ► ✓ ⚠ ◆ and the weights:", {})
local weights = box(body, Color3.new(0, 0, 0), UDim2.new(1, 0, 0, 16), { BackgroundTransparency = 1 })
make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }).Parent = weights
for _, w in { "Regular", "Medium", "Bold", "ExtraBold" } do
	label(weights, w, { Size = UDim2.fromOffset(70, 16), FontFace = Font.fromName("BuilderSans", Enum.FontWeight[w]) })
end
local scaled = label(body, "TextScaled", { TextScaled = true, Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 0, BackgroundColor3 = rgb(52, 52, 61) })
make("UITextSizeConstraint", { MaxTextSize = 22 }).Parent = scaled

-- 9. images
title(body, "9  ImageLabel: class icons from the ClassImages sprite sheet, tinted, ScaleType Fit, unknown asset")
local icons = box(body, rgb(52, 52, 61), UDim2.new(1, 0, 0, 32), {})
make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = icons
pad(0, 8).Parent = icons
local StudioService = P.StudioService
for _, class in { "Part", "ParticleEmitter", "Model", "Script", "Beam", "Sound" } do
	local icon = StudioService:GetClassIcon(class)
	make("ImageLabel", { Parent = icons, BackgroundTransparency = 1, Size = UDim2.fromOffset(16, 16), Image = icon.Image,
		ImageRectOffset = icon.ImageRectOffset, ImageRectSize = icon.ImageRectSize })
end
local big = StudioService:GetClassIcon("ParticleEmitter")
make("ImageLabel", { Parent = icons, BackgroundTransparency = 1, Size = UDim2.fromOffset(28, 28), Image = big.Image, ImageRectOffset = big.ImageRectOffset,
	ImageRectSize = big.ImageRectSize })
make("ImageLabel", { Parent = icons, BackgroundTransparency = 1, Size = UDim2.fromOffset(28, 28), Image = big.Image, ImageRectOffset = big.ImageRectOffset,
	ImageRectSize = big.ImageRectSize, ImageColor3 = rgb(0, 162, 255) })
make("ImageLabel", { Parent = icons, BackgroundTransparency = 0.6, BackgroundColor3 = A, Size = UDim2.fromOffset(40, 24), Image = "rbxasset://textures/sparkle.png",
	ScaleType = Enum.ScaleType.Fit })
make("ImageLabel", { Parent = icons, BackgroundTransparency = 1, Size = UDim2.fromOffset(40, 24), Image = "rbxassetid://123456789" })

-- 10. scrolling frame, canvas group, constraints
title(body, "10  ScrollingFrame (fixed canvas 120 high in a 60 frame, scrolled 20), CanvasGroup 50%, SizeConstraint max 100, AspectRatio 2")
local sf = make("ScrollingFrame", { Parent = body, Size = UDim2.new(1, 0, 0, 60), BackgroundColor3 = rgb(21, 21, 25), CanvasSize = UDim2.fromOffset(0, 120),
	ScrollBarThickness = 5, ScrollBarImageColor3 = A, CanvasPosition = Vector2.new(0, 20), VerticalScrollBarInset = Enum.ScrollBarInset.Always })
make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2) }).Parent = sf
for i = 1, 8 do label(sf, "row " .. i, { Size = UDim2.new(1, 0, 0, 20) }) end
local cg = make("CanvasGroup", { Parent = body, Size = UDim2.new(1, 0, 0, 24), BackgroundColor3 = A, GroupTransparency = 0.5 })
label(cg, "CanvasGroup half transparent", { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center })
local sc = box(body, B, UDim2.new(1, 0, 0, 20)); make("UISizeConstraint", { MaxSize = Vector2.new(100, math.huge) }).Parent = sc
local ar = box(body, Cc, UDim2.new(0, 80, 0, 0)); make("UIAspectRatioConstraint", { AspectRatio = 2 }).Parent = ar

return { root = root, app = nil, noDrive = true }
