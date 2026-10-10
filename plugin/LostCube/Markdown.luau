-- LostCube Markdown: shows Claude's answers (Markdown) as Roblox GUI. Headings (#, ##, ###), bullet / numbered /
-- task lists (nested by indentation), **bold**, *italic*, ~~strike~~, `inline code`, links, quotes, tables,
-- horizontal rules and fenced code blocks (monospace, darker, selectable so the code can be copied with Ctrl+C).
--
--	Markdown.render(parent, text, { maxWidth = 600 }) -> Frame (auto height)
--
-- Markdown.parse (blocks) and Markdown.inline (RichText) are pure functions, unit tested outside Studio.
local UI = require(script.Parent.UI)
local C = UI.C

local Markdown = {}

local CODE_BG = Color3.fromRGB(16, 16, 20)
local CODE_TEXT = Color3.fromRGB(214, 220, 236)
local INLINE_CODE = "#D7B8FF"
local LINK_DIM = "#9696A6"
local HEADING_SIZE = { 18, 16, 14 }
local LINE = 17 -- height of one line of 13 px text (list markers line up with it)

-- ---------------------------------------------------------------------------------------------
-- inline: Markdown -> RichText
-- ---------------------------------------------------------------------------------------------
function Markdown.escape(s: string): string
	return (string.gsub(s, "&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end
local escape = Markdown.escape

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

-- one line / paragraph of Markdown -> RichText (text escaped, tags always balanced)
function Markdown.inline(text: string): string
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
		return keep('<font face="RobotoMono" color="' .. INLINE_CODE .. '">' .. escape(inner) .. "</font>")
	end)
	-- links: not clickable in Studio, so the address is shown after the text
	text = string.gsub(text, "%[([^%]]+)%]%(([^%)%s]+)%)", function(label, url)
		if label == url then
			return keep("<u>" .. escape(url) .. "</u>")
		end
		return keep("<u>" .. escape(label) .. '</u> <font color="' .. LINK_DIM .. '">(' .. escape(url) .. ")</font>")
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
local function textLabel(parent: Instance, rich: string, opts: { [string]: any }?)
	opts = opts or {}
	return UI.make("TextLabel", { Parent = parent, Text = rich, RichText = true, TextWrapped = true,
		Font = opts.font or UI.FONT, TextSize = opts.size or 13, TextColor3 = opts.color or C.text, LineHeight = 1.1,
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top })
end

local function autoFrame(parent: Instance, props: { [string]: any }?, children: { Instance }?)
	local p = props or {}
	p.Parent = parent
	p.Size = p.Size or UDim2.new(1, 0, 0, 0)
	p.AutomaticSize = Enum.AutomaticSize.Y
	if p.BackgroundColor3 == nil then
		p.BackgroundTransparency = 1
	end
	return UI.make("Frame", p, children)
end

local function codeBlock(parent: Instance, block)
	local frame = autoFrame(parent, { BackgroundColor3 = CODE_BG }, { UI.corner(4), UI.stroke(C.border), UI.pad(4, 8, 6, 8),
		UI.vlist(2) })
	local head = UI.make("Frame", { Parent = frame, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18) })
	UI.make("TextLabel", { Parent = head, Text = block.lang or "cod", Font = UI.FONT_MED, TextSize = 11, TextColor3 = C.dim,
		BackgroundTransparency = 1, Size = UDim2.new(1, -110, 1, 0), TextXAlignment = Enum.TextXAlignment.Left })
	local selectAll = UI.make("TextButton", { Parent = head, Text = "Selectează tot", Font = UI.FONT_MED, TextSize = 11,
		TextColor3 = C.accentHover, AutoButtonColor = false, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 104, 1, 0), TextXAlignment = Enum.TextXAlignment.Right })
	-- read-only but selectable: the code is copied with Ctrl+C
	local box = UI.make("TextBox", { Parent = frame, Text = (string.gsub(block.code, "\t", "    ")), Font = Enum.Font.Code,
		TextSize = 12, TextColor3 = CODE_TEXT, BackgroundTransparency = 1, ClearTextOnFocus = false, TextEditable = false,
		MultiLine = true, TextWrapped = true, RichText = false, TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
	selectAll.MouseButton1Click:Connect(function()
		pcall(function()
			box:CaptureFocus()
			box.CursorPosition = #box.Text + 1
			box.SelectionStart = 1
		end)
	end)
	UI.tip(selectAll, "Selectează codul, apoi Ctrl+C")
	return frame
end

local function listBlock(parent: Instance, block)
	local frame = autoFrame(parent, nil, { UI.vlist(3) })
	for _, item in block.items do
		local marker
		if item.task ~= nil then
			marker = item.task and "☑" or "☐"
		elseif item.ordered then
			marker = tostring(item.number or 1) .. "."
		else
			marker = item.level == 0 and "•" or "◦"
		end
		local markerW = item.ordered and 22 or 12
		local row = autoFrame(frame, nil, {
			UI.make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Top, Padding = UDim.new(0, 5) }),
			UI.pad(0, 0, 0, item.level * 14),
		})
		UI.make("TextLabel", { Parent = row, Text = marker, Font = item.ordered and UI.FONT_MED or UI.FONT_BOLD, TextSize = 13,
			TextColor3 = item.task and C.good or C.accent, BackgroundTransparency = 1, Size = UDim2.new(0, markerW, 0, LINE),
			TextXAlignment = item.ordered and Enum.TextXAlignment.Right or Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top })
		local label = textLabel(row, Markdown.inline(item.text))
		label.Size = UDim2.new(1, -(markerW + 5), 0, 0)
	end
	return frame
end

local function quoteBlock(parent: Instance, block)
	local frame = autoFrame(parent, { BackgroundColor3 = C.input }, { UI.corner(4), UI.stroke(C.accentDark), UI.pad(5, 8, 5, 10) })
	textLabel(frame, "<i>" .. Markdown.inline(block.text) .. "</i>", { color = C.dim })
	return frame
end

local function tableBlock(parent: Instance, block)
	local frame = autoFrame(parent, { BackgroundColor3 = C.input }, { UI.corner(4), UI.pad(5, 8, 5, 8), UI.vlist(3) })
	for _, row in block.rows do
		local cells = {}
		for _, cell in row.cells do
			table.insert(cells, Markdown.inline(cell))
		end
		local rich = table.concat(cells, '  <font color="#55556A">│</font>  ')
		textLabel(frame, row.header and ("<b>" .. rich .. "</b>") or rich, { size = 12 })
		if row.header then
			UI.make("Frame", { Parent = frame, BackgroundColor3 = C.border, Size = UDim2.new(1, 0, 0, 1) })
		end
	end
	return frame
end

local function renderBlock(parent: Instance, block, first: boolean)
	if block.type == "heading" then
		if not first then
			UI.make("Frame", { Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 2) })
		end
		textLabel(parent, Markdown.inline(block.text), { font = UI.FONT_BOLD, size = HEADING_SIZE[block.level],
			color = block.level == 2 and C.accentHover or C.text })
	elseif block.type == "paragraph" then
		textLabel(parent, Markdown.inline(block.text))
	elseif block.type == "list" then
		listBlock(parent, block)
	elseif block.type == "code" then
		codeBlock(parent, block)
	elseif block.type == "quote" then
		quoteBlock(parent, block)
	elseif block.type == "table" then
		tableBlock(parent, block)
	elseif block.type == "rule" then
		UI.make("Frame", { Parent = parent, BackgroundColor3 = C.border, Size = UDim2.new(1, 0, 0, 1) })
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
		for _, row in block.rows do
			table.insert(lines, table.concat(row.cells, "  |  "))
		end
		return table.concat(lines, "\n")
	end
	return block.text or block.code or ""
end

-- renders Markdown into parent; returns the Frame (full width, auto height). opts.maxWidth caps the width.
function Markdown.render(parent: Instance, text: string, opts: { maxWidth: number? }?): Frame
	local o: { [string]: any } = opts or {}
	local frame = UI.make("Frame", { Name = "Markdown", Parent = parent, BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, { UI.vlist(o.gap or 6) })
	if o.maxWidth then
		UI.make("UISizeConstraint", { Parent = frame, MaxSize = Vector2.new(o.maxWidth, math.huge) })
	end
	local ok, blocks = pcall(Markdown.parse, text or "")
	if not ok then
		blocks = { { type = "paragraph", text = text or "" } }
	end
	for i, block in blocks do
		local done, err = pcall(renderBlock, frame, block, i == 1)
		if not done then -- never lose the answer because of one odd block
			warn("LostCube Markdown:", err)
			textLabel(frame, escape(plainOf(block)))
		end
	end
	return frame
end

return Markdown
