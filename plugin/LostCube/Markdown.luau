-- LostCube Markdown: shows Claude's answers (Markdown) as Roblox GUI in the LostCube design system. Headings (#, ##, ###),
-- bullet / numbered / task lists (nested by indentation), **bold**, *italic*, ~~strike~~, `inline code`, links, quotes,
-- tables, horizontal rules and fenced code blocks (a code surface in Builder Mono with a "Selectează" action, selectable so
-- the code can be copied with Ctrl+C). Colours come from the theme tokens (read at render time), text from the type scale.
--
--	Markdown.render(parent, text, { maxWidth = 600, gap = 8 }) -> Frame (auto height)
--	Markdown.code(parent, code, lang?) -> Frame          a code surface on its own (tool cards use it)
--
-- Markdown.parse (blocks) and Markdown.inline (RichText) are pure functions, unit tested outside Studio.
local UI = require(script.Parent.UI)
local C = UI.C

local Markdown = {}

Markdown.MONO_FAMILY = "rbxasset://fonts/families/BuilderMono.json" -- Studio content (Theme.MONO_FAMILY)
local GAP = 8 -- between blocks
local LINE_HEIGHT = 1.15 -- body text of an answer: a little air between the lines
-- heading level -> type role, weight, colour token (h1 15 Bold, h2 13 Bold, h3 12 Bold)
local HEADING = {
	{ role = "title", weight = "Bold", color = "textBright" },
	{ role = "emphasis", weight = "Bold", color = "textBright" },
	{ role = "body", weight = "Bold", color = "text" },
}

-- ---------------------------------------------------------------------------------------------
-- inline: Markdown -> RichText
-- ---------------------------------------------------------------------------------------------
function Markdown.escape(s: string): string
	return (string.gsub(s, "&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end
local escape = Markdown.escape

-- "#RRGGBB" of a theme token now (rich text needs the colour as text); fallback when the token is missing
local function hexOf(token: string, fallback: string): string
	local color = C[token]
	if color ~= nil then
		local ok, hex = pcall(function()
			return color:ToHex()
		end)
		if ok and type(hex) == "string" and #hex == 6 then
			return "#" .. string.upper(hex)
		end
	end
	return fallback
end

-- the colours inline markup uses, from the current theme
function Markdown.inlineColors(): { [string]: string }
	return { code = hexOf("textBright", "#E5E5E5"), link = hexOf("link", "#35B5FF"), dim = hexOf("textDim", "#AAAAAA") }
end

-- every tag closed, in the right order (RichText shows the raw text when the markup is broken)
local function balanced(s: string): boolean
	local stack = {}
	for slash, tag in string.gmatch(s, "<(/?)(%a+)[^>]*>") do
		if slash == "" then
			table.insert(stack, tag)
		elseif stack[#stack] == tag then
			table.remove(stack)
		else
			return false
		end
	end
	return #stack == 0
end

local function emphasis(s: string): string
	s = string.gsub(s, "~~(%S.-)~~", "<s>%1</s>")
	s = string.gsub(s, "%*%*(%S.-)%*%*", "<b>%1</b>")
	-- __bold__ / _italic_ only at word edges, so snake_case and LC_Duration stay as they are
	s = string.gsub(s, "%f[%w_]__([^_%s][^_]-)__%f[^%w_]", "<b>%1</b>")
	s = string.gsub(s, "%*([^%s%*][^%*]-)%*", function(inner)
		if string.match(inner, "%s$") then
			return nil
		end
		return "<i>" .. inner .. "</i>"
	end)
	s = string.gsub(s, "%f[%w_]_([^_%s][^_]-)_%f[^%w_]", function(inner)
		if string.match(inner, "%s$") then
			return nil
		end
		return "<i>" .. inner .. "</i>"
	end)
	return s
end

-- one line / paragraph of Markdown -> RichText (text escaped, tags always balanced). colors: Markdown.inlineColors()
-- (read from the theme when omitted)
function Markdown.inline(text: string, colors: { [string]: string }?): string
	local palette = colors or Markdown.inlineColors()
	text = string.gsub(text or "", "[\1\2]", "")
	local saved = {}
	local function keep(rich)
		table.insert(saved, rich)
		return "\1" .. #saved .. "\2"
	end
	-- code spans first: nothing inside them is formatted
	text = string.gsub(text, "(`+)(.-)%1", function(_, inner)
		if string.match(inner, "^ .* $") then
			inner = string.sub(inner, 2, -2)
		end
		return keep('<font family="' .. Markdown.MONO_FAMILY .. '" color="' .. palette.code .. '">' .. escape(inner) .. "</font>")
	end)
	-- links: not clickable in Studio, so the address is shown after the text
	text = string.gsub(text, "%[([^%]]+)%]%(([^%)%s]+)%)", function(label, url)
		if label == url then
			return keep('<font color="' .. palette.link .. '"><u>' .. escape(url) .. "</u></font>")
		end
		return keep('<font color="' .. palette.link .. '"><u>' .. escape(label) .. '</u></font> <font color="' .. palette.dim
			.. '">(' .. escape(url) .. ")</font>")
	end)
	local plain = escape(text)
	local rich = emphasis(plain)
	if not balanced(rich) then
		rich = plain
	end
	return (string.gsub(rich, "\1(%d+)\2", function(i)
		return saved[tonumber(i)] or ""
	end))
end

-- ---------------------------------------------------------------------------------------------
-- blocks
-- ---------------------------------------------------------------------------------------------
local function indentOf(spaces: string): number
	local n = 0
	for ch in string.gmatch(spaces, ".") do
		n += ch == "\t" and 4 or 1
	end
	return n
end

local function splitRow(line: string): { string }
	local s = string.gsub(line, "^%s*|", ""):gsub("|%s*$", "")
	s = string.gsub(s, "\\|", "\1")
	local cells = {}
	for cell in string.gmatch(s .. "|", "([^|]*)|") do
		cell = string.gsub(cell, "\1", "|")
		table.insert(cells, (string.gsub(cell, "^%s+", ""):gsub("%s+$", "")))
	end
	return cells
end

local function isRule(line: string): boolean
	local t = string.gsub(line, "%s", "")
	return #t >= 3 and (string.match(t, "^%-+$") or string.match(t, "^%*+$") or string.match(t, "^_+$")) ~= nil
end

--[[ Markdown.parse(text) -> blocks:
	{ type = "heading", level = 1..3, text }      { type = "paragraph", text }      { type = "rule" }
	{ type = "list", ordered, items = { { text, level, number?, task? } } }       { type = "quote", text }
	{ type = "code", lang?, code }                 { type = "table", rows = { { cells, header } } } ]]
function Markdown.parse(text: string): { any }
	text = string.gsub(text or "", "\r\n?", "\n")
	local lines = {}
	for line in string.gmatch(text .. "\n", "(.-)\n") do
		table.insert(lines, line)
	end
	local blocks = {}
	local para = nil
	local list = nil -- the list block new items join (a blank line between items keeps the list going)
	local lastItem = nil -- the item continuation lines join (cleared by a blank line)
	local function flush()
		if para then
			table.insert(blocks, { type = "paragraph", text = table.concat(para, "\n") })
			para = nil
		end
	end
	local function endList()
		list, lastItem = nil, nil
	end
	local i = 1
	while i <= #lines do
		local line = lines[i]
		local fenceIndent, fence, lang = string.match(line, "^(%s*)(```+)%s*([^`%s]*)")
		if not fence then
			fenceIndent, fence, lang = string.match(line, "^(%s*)(~~~+)%s*(%S*)")
		end
		local blank = string.match(line, "^%s*$") ~= nil
		local hashes, heading = string.match(line, "^%s*(#+)%s+(.-)%s*$")
		local quote = string.match(line, "^%s*>%s?(.*)$")
		local bulletIndent, bulletText = string.match(line, "^(%s*)[%-%*%+]%s+(.*)$")
		local numIndent, number, numText = string.match(line, "^(%s*)(%d+)[%.%)]%s+(.*)$")
		if fence then
			flush()
			endList()
			local code = {}
			local closing = "^%s*" .. string.gsub(string.sub(fence, 1, 1), "%p", "%%%0") .. "+%s*$"
			local cut = indentOf(fenceIndent or "")
			i += 1
			while i <= #lines and not string.match(lines[i], closing) do
				local l = lines[i]
				if cut > 0 then -- code fenced inside a list item: drop the item's indentation
					local lead = string.match(l, "^%s*")
					l = string.sub(l, math.min(#lead, cut) + 1)
				end
				table.insert(code, l)
				i += 1
			end
			while #code > 0 and string.match(code[#code], "^%s*$") do
				table.remove(code)
			end
			table.insert(blocks, { type = "code", lang = lang ~= "" and lang or nil, code = table.concat(code, "\n") })
		elseif blank then
			flush()
			lastItem = nil
		elseif hashes and #hashes <= 6 then
			flush()
			endList()
			heading = string.gsub(heading, "%s+#+$", "")
			table.insert(blocks, { type = "heading", level = math.min(#hashes, 3), text = heading })
		elseif isRule(line) then
			flush()
			endList()
			table.insert(blocks, { type = "rule" })
		elseif bulletText or numText then
			flush()
			local ordered = numText ~= nil
			local indent = indentOf(ordered and numIndent or bulletIndent)
			local body = ordered and numText or bulletText
			if not list or list.ordered ~= ordered and indent == 0 then
				list = { type = "list", ordered = ordered, items = {}, indents = { indent } }
				table.insert(blocks, list)
			end
			local stack = list.indents
			while #stack > 1 and indent < stack[#stack] do
				table.remove(stack)
			end
			if indent > stack[#stack] then
				table.insert(stack, indent)
			end
			local item = { text = body, level = math.min(#stack - 1, 4), number = ordered and tonumber(number) or nil,
				ordered = ordered }
			local mark, rest = string.match(body, "^%[([ xX])%]%s+(.*)$")
			if mark then
				item.task = mark ~= " "
				item.text = rest
			end
			table.insert(list.items, item)
			lastItem = item
		elseif lastItem and string.match(line, "^%s+%S") then
			-- an indented line right under an item belongs to it
			lastItem.text ..= "\n" .. (string.gsub(line, "^%s+", ""))
		elseif quote then
			flush()
			endList()
			local prev = blocks[#blocks]
			if prev and prev.type == "quote" and prev.open then
				prev.text ..= "\n" .. quote
			else
				table.insert(blocks, { type = "quote", text = quote, open = true })
			end
		elseif string.match(line, "^%s*|.*|%s*$") then
			flush()
			endList()
			local prev = blocks[#blocks]
			if not (prev and prev.type == "table" and prev.open) then
				prev = { type = "table", rows = {}, open = true }
				table.insert(blocks, prev)
			end
			if string.match(line, "^[%s|:%-]+$") and string.find(line, "-", 1, true) then
				if prev.rows[1] then -- the |---|---| line: the row above is the header
					prev.rows[#prev.rows].header = true
				end
			else
				table.insert(prev.rows, { cells = splitRow(line) })
			end
		else
			endList()
			para = para or {}
			table.insert(para, (string.gsub(line, "^%s+", "")))
		end
		-- quotes and tables continue only on the very next line
		local last = blocks[#blocks]
		if last and last.open and not ((last.type == "quote" and quote and not fence)
			or (last.type == "table" and string.match(line, "^%s*|.*|%s*$") and not fence)) then
			last.open = nil
		end
		i += 1
	end
	flush()
	for _, b in blocks do
		b.open = nil
		b.indents = nil
	end
	return blocks
end

-- ---------------------------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------------------------
local function autoFrame(parent: Instance, name: string, children: { Instance }?)
	return UI.make("Frame", { Name = name, Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, children)
end

-- a wrapped rich text label. opts: role (type scale, "body"), weight, color (token, "text"), lineHeight
local function textLabel(parent: Instance, rich: string, opts: { [string]: any }?)
	local o: { [string]: any } = opts or {}
	local props = { Parent = parent, Text = rich, RichText = true, TextWrapped = true, LineHeight = o.lineHeight or LINE_HEIGHT,
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top }
	UI.textStyle(props, o.role or "body", o.weight)
	local label = UI.make("TextLabel", props)
	UI.skin(label, { TextColor3 = o.color or "text" })
	return label
end

-- children side by side, aligned on their first line
local function row(parent: Instance, name: string, gap: number, leftPad: number?)
	return autoFrame(parent, name, {
		UI.make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Top, Padding = UDim.new(0, gap) }),
		UI.pad(0, 0, 0, leftPad or 0),
	})
end

-- the name shown on a code block for the usual fence tags
local LANGUAGES = { lua = "Luau", luau = "Luau", json = "JSON", txt = "Text", text = "Text", md = "Markdown",
	markdown = "Markdown", sh = "Shell", bash = "Shell", js = "JavaScript", ts = "TypeScript", py = "Python", python = "Python" }

-- a code surface: language + "Selectează" on top, the code below in Builder Mono, read-only but selectable (Ctrl+C).
-- Returns the frame and the TextBox.
function Markdown.code(parent: Instance, code: string, lang: string?)
	local frame = UI.make("Frame", { Name = "Code", Parent = parent, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.corner(UI.RADIUS.control), UI.stroke("border"), UI.vlist(0) })
	UI.skin(frame, { BackgroundColor3 = "field" })
	local head = UI.make("Frame", { Name = "CodeHeader", Parent = frame, BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, UI.H) }, { UI.pad(0, 2, 0, 10) })
	local name = UI.label(head, LANGUAGES[string.lower(lang or "")] or lang or "Cod", { role = "meta", dim = true })
	name.Size = UDim2.new(1, -96, 1, 0)
	UI.divider(frame)
	local holder = autoFrame(frame, "CodeBody", { UI.pad(8, 10, 8, 10) })
	local props = { Parent = holder, Text = (string.gsub(code or "", "\t", "    ")), ClearTextOnFocus = false,
		TextEditable = false, MultiLine = true, TextWrapped = true, RichText = false, BackgroundTransparency = 1,
		LineHeight = 1.1, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }
	UI.textStyle(props, "code")
	local box = UI.make("TextBox", props)
	UI.skin(box, { TextColor3 = "text" })
	local select = UI.button(head, "Selectează", function()
		pcall(function()
			box:CaptureFocus()
			box.CursorPosition = #box.Text + 1
			box.SelectionStart = 1
		end)
	end, { style = "ghost", autoWidth = true, height = 20, tip = "Selectează codul, apoi Ctrl+C" })
	select.AnchorPoint = Vector2.new(1, 0.5)
	select.Position = UDim2.new(1, 0, 0.5, 0)
	return frame, box
end

-- a task list box: empty, or filled with the accent and a check when done
local function checkbox(parent: Instance, done: boolean)
	local holder = UI.make("Frame", { Name = "Check", Parent = parent, BackgroundTransparency = 1,
		Size = UDim2.fromOffset(14, 14) })
	local box = UI.make("Frame", { Parent = holder, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(12, 12), BackgroundTransparency = done and 0 or 1 },
		{ UI.corner(3), UI.stroke(done and "accent" or "textDisabled") })
	UI.skin(box, { BackgroundColor3 = "accent" })
	if done then
		local check = UI.Icons.draw(box, "check", 12, C.accentText, 1.5)
		for _, line in check:GetChildren() do
			UI.skin(line, { BackgroundColor3 = "accentText" })
		end
	end
	return holder
end

local function listBlock(parent: Instance, block, colors)
	local frame = autoFrame(parent, "List", { UI.vlist(4) })
	for _, item in block.items do
		local markerW = item.task ~= nil and 14 or (item.ordered and 18 or 10)
		local line = row(frame, "Item", 6, item.level * 16)
		if item.task ~= nil then
			checkbox(line, item.task)
		else
			local marker = item.ordered and (tostring(item.number or 1) .. ".") or (item.level == 0 and "•" or "◦")
			local m = textLabel(line, marker, { color = "textDim", weight = item.ordered and "Medium" or nil })
			m.RichText = false
			m.Size = UDim2.new(0, markerW, 0, 0)
			m.TextXAlignment = item.ordered and Enum.TextXAlignment.Right or Enum.TextXAlignment.Left
		end
		local label = textLabel(line, Markdown.inline(item.text, colors), { color = item.task and "textDim" or "text" })
		label.Size = UDim2.new(1, -(markerW + 6), 0, 0)
	end
	return frame
end

local function quoteBlock(parent: Instance, block, colors)
	local frame = row(parent, "Quote", 10)
	local bar = UI.make("Frame", { Name = "Bar", Parent = frame, Size = UDim2.new(0, 2, 1, 0) }, { UI.corner(1) })
	UI.skin(bar, { BackgroundColor3 = "textDisabled" })
	local label = textLabel(frame, Markdown.inline(block.text, colors), { color = "textDim" })
	label.Size = UDim2.new(1, -12, 0, 0)
	return frame
end

-- a real grid: one column per cell, widths after the longest text of each column, a divider between rows
local function tableBlock(parent: Instance, block, colors)
	local columns = 0
	for _, r in block.rows do
		columns = math.max(columns, #r.cells)
	end
	if columns == 0 then
		return nil
	end
	local weights, total = {}, 0
	for c = 1, columns do
		local longest = 0
		for _, r in block.rows do
			local cell = r.cells[c] or ""
			longest = math.max(longest, utf8.len(cell) or #cell)
		end
		weights[c] = math.clamp(longest, 10, 32) -- a short column still fits a word
		total += weights[c]
	end
	local frame = UI.make("Frame", { Name = "Table", Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.corner(UI.RADIUS.control), UI.stroke("border"), UI.vlist(0) })
	for i, r in block.rows do
		if i > 1 then
			UI.divider(frame)
		end
		local line = row(frame, r.header and "TableHeader" or "TableRow", 0)
		for c = 1, columns do
			local cell = textLabel(line, Markdown.inline(r.cells[c] or "", colors), { weight = r.header and "Bold" or nil,
				color = r.header and "textBright" or "text" })
			cell.Size = UDim2.new(weights[c] / total, 0, 0, 0)
			UI.pad(6, 8, 6, 8).Parent = cell
		end
	end
	return frame
end

local function renderBlock(parent: Instance, block, first: boolean, colors)
	if block.type == "heading" then
		if not first then
			UI.make("Frame", { Name = "Space", Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 2) })
		end
		local style = HEADING[block.level] or HEADING[3]
		textLabel(parent, Markdown.inline(block.text, colors), { role = style.role, weight = style.weight, color = style.color,
			lineHeight = 1.1 })
	elseif block.type == "paragraph" then
		textLabel(parent, Markdown.inline(block.text, colors))
	elseif block.type == "list" then
		listBlock(parent, block, colors)
	elseif block.type == "code" then
		Markdown.code(parent, block.code, block.lang)
	elseif block.type == "quote" then
		quoteBlock(parent, block, colors)
	elseif block.type == "table" then
		tableBlock(parent, block, colors)
	elseif block.type == "rule" then
		UI.divider(parent)
	end
end

local function plainOf(block): string
	if block.items then
		local lines = {}
		for _, item in block.items do
			table.insert(lines, "• " .. item.text)
		end
		return table.concat(lines, "\n")
	elseif block.rows then
		local lines = {}
		for _, r in block.rows do
			table.insert(lines, table.concat(r.cells, "  |  "))
		end
		return table.concat(lines, "\n")
	end
	return block.text or block.code or ""
end

-- renders Markdown into parent; returns the Frame (full width, auto height). opts.maxWidth caps the width, opts.gap is the
-- space between blocks (8).
function Markdown.render(parent: Instance, text: string, opts: { [string]: any }?): Frame
	local o: { [string]: any } = opts or {}
	local frame = UI.make("Frame", { Name = "Markdown", Parent = parent, BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, { UI.vlist(o.gap or GAP) })
	if o.maxWidth then
		UI.make("UISizeConstraint", { Parent = frame, MaxSize = Vector2.new(o.maxWidth, math.huge) })
	end
	local ok, blocks = pcall(Markdown.parse, text or "")
	if not ok then
		blocks = { { type = "paragraph", text = text or "" } }
	end
	local colors = Markdown.inlineColors()
	for i, block in blocks do
		local done, err = pcall(renderBlock, frame, block, i == 1, colors)
		if not done then -- never lose the answer because of one odd block
			warn("LostCube Markdown:", err)
			textLabel(frame, escape(plainOf(block)))
		end
	end
	return frame
end

return Markdown
