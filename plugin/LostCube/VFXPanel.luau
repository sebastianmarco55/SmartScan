-- LostCube > Effects tab: the effects (search, templates, share codes, Creator Store import), the selected effect (header,
-- transport, a visual timeline with the preview's playhead, colour / scale / variant tools) and its elements with their
-- properties grouped by meaning. Built with the UI kit only (plugin/docs/design.md); re-rendered fully on every refresh.
local Selection = game:GetService("Selection")

local UI = require(script.Parent.UI)
local C = UI.C

local Panel = {}
Panel.__index = Panel

-- ---------------------------------------------------------------------------------------------
-- vocabulary
-- ---------------------------------------------------------------------------------------------
local CLASS = { PARTICLES = "ParticleEmitter", LIGHT = "PointLight", TRAIL = "Trail", MESH = "Part", SOUND = "Sound",
	CAMERA = "Camera", BEAM = "Beam" }
local KIND_LABEL = { PARTICLES = "Particule", LIGHT = "Lumină", TRAIL = "Trail", MESH = "Mesh 3D", SOUND = "Sunet", CAMERA = "Cameră",
	BEAM = "Rază" }
local EMPTY_KINDS = { "PARTICLES", "LIGHT", "TRAIL", "MESH", "SOUND", "CAMERA", "BEAM" }

local ORIENT = {
	{ value = "FacingCamera", label = "Spre cameră" },
	{ value = "FacingCameraWorldUp", label = "Spre cameră, vertical" },
	{ value = "VelocityParallel", label = "Pe direcția mișcării" },
	{ value = "VelocityPerpendicular", label = "Culcat pe sol" },
}
local SHAPES = {
	{ value = "Point", label = "Punct" }, { value = "Box", label = "Cutie" }, { value = "Sphere", label = "Sferă" },
	{ value = "Cylinder", label = "Cilindru" }, { value = "Disc", label = "Disc" },
}
local DIRECTIONS = {
	{ value = "Top", label = "Sus" }, { value = "Bottom", label = "Jos" }, { value = "Front", label = "Față" },
	{ value = "Back", label = "Spate" }, { value = "Left", label = "Stânga" }, { value = "Right", label = "Dreapta" },
}
local FLIPBOOK_LAYOUTS = {
	{ value = "None", label = "Fără" }, { value = "Grid2x2", label = "2 × 2", hint = "4 cadre" },
	{ value = "Grid4x4", label = "4 × 4", hint = "16 cadre" }, { value = "Grid8x8", label = "8 × 8", hint = "64 cadre" },
}
local FLIPBOOK_MODES = {
	{ value = "Loop", label = "Buclă" }, { value = "OneShot", label = "O dată pe viața particulei" },
	{ value = "PingPong", label = "Dus-întors" }, { value = "Random", label = "Cadre la întâmplare" },
}
local TEXTURE_MODES = { { value = "Stretch", label = "Întinsă" }, { value = "Wrap", label = "Repetată" }, { value = "Static", label = "Fixă" } }
local MESH_MODES = {
	{ value = "Ring", label = "Inel care se lărgește" }, { value = "Crack", label = "Crăpături radiale" },
	{ value = "Pulse", label = "Puls" }, { value = "Puff", label = "Fum 3D" },
	{ value = "Trail", label = "Urmă pe sol" }, { value = "Debris", label = "Debris cu fizică" },
}
local PART_SHAPES = { { value = "Block", label = "Cub" }, { value = "Ball", label = "Bilă" },
	{ value = "Cylinder", label = "Cilindru" }, { value = "Wedge", label = "Pană" } }
local MATERIALS = {}
for _, m in { "Neon", "ForceField", "SmoothPlastic", "Glass", "Ice", "Metal", "Slate", "Rock", "Concrete", "Plastic", "Sand" } do
	table.insert(MATERIALS, { value = m, label = m })
end
local SPEEDS = { { value = 0.1, label = "0.1×" }, { value = 0.25, label = "0.25×" }, { value = 0.5, label = "0.5×" },
	{ value = 1, label = "1×" } }
-- the timing group of each kind: { the continuous window switch, its tip, one row of the list of moments, the add tip,
-- the tip of the count field (nil: a moment has no count) }
local TIMING = {
	PARTICLES = { "Emisie continuă", "Emite cu rata din Mișcare între cele două momente", "Burst", "Adaugă burst",
		"Câte particule" },
	MESH = { "Emisie continuă", "Emite piese cu rata de mai sus între cele două momente", "Burst", "Adaugă burst", "Câte piese" },
	TRAIL = { "Activ", "Desenează urma între cele două momente" },
	SOUND = { "Buclă", "Repetă sunetul între cele două momente și îl stinge la final", "Redare", "Adaugă redare",
		"Câte redări suprapuse" },
	CAMERA = { "Cutremur continuu", "Tremură continuu între cele două momente", "Lovitură", "Adaugă lovitură" },
	BEAM = { "Vizibilă continuu", "Raza stă aprinsă între cele două momente", "Flash", "Adaugă flash" },
}
local SCALE_STEPS = { 0.5, 0.8, 1.25, 2 }
local TIME_STEPS = { 0.8, 0.9, 1.15, 1.3 }
local NEUTRAL_SAT, NEUTRAL_VAL = 0.12, 0.16 -- as the Editor: below these a colour is white / grey / black and never recoloured

-- the timeline strip
local LANE_H, AXIS_H, NAME_W = 16, 16, 92

function Panel.new(ctx)
	return setmetatable({ ctx = ctx, Editor = ctx.Editor, effect = nil, element = nil, speed = 1, loop = false,
		creating = false, templating = false, handle = nil, search = "", ioMode = "code", toolMode = "color",
		varCount = 3, varHue = nil, varScale = 1 }, Panel)
end

function Panel:refresh()
	self.ctx.app:refresh()
end

-- ---------------------------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------------------------
-- "ReplicatedStorage.LostCube.Editor:123: LostCube: există deja ..." -> "Există deja ..." (only a leading location: a
-- message may quote another error later on)
local function clean(err)
	local text = tostring(err):gsub("^[%w%._/%-]+:%d+: ", ""):gsub("^LostCube:%s*", "")
	return (text:gsub("^%l", string.upper))
end

-- text written elsewhere (template descriptions, report lines) without emoji or symbol glyphs (design.md: none, anywhere)
local function plain(text)
	local ok, out = pcall(function()
		local kept = {}
		for _, cp in utf8.codes(text) do
			local symbol = (cp >= 0x2190 and cp <= 0x21FF) or (cp >= 0x2300 and cp <= 0x23FF) or (cp >= 0x25A0 and cp <= 0x27BF)
				or (cp >= 0x2B00 and cp <= 0x2BFF) or cp == 0xFE0F or cp >= 0x1F000
			if not symbol then
				table.insert(kept, utf8.char(cp))
			end
		end
		return (table.concat(kept):gsub("  +", " "))
	end)
	return ok and out or text
end

local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- the Editor's report lines start with a mark ("✓ ", "✗ ", "⚠ ", "• "): the panel shows the words only
local MARKS = { "✓ ", "✗ ", "⚠ ", "• " }
local function unmark(line)
	for _, mark in MARKS do
		if string.sub(line, 1, #mark) == mark then
			return string.sub(line, #mark + 1)
		end
	end
	return line
end

-- Romanian counts: "1 element", "7 elemente", "20 de elemente"
local function count(n, one, many)
	if n == 1 then
		return "1 " .. one
	end
	local rest = n % 100
	return n .. ((rest >= 20 or (rest == 0 and n > 0)) and " de " or " ") .. many
end

local function seconds(v)
	return UI.fmt(v, 2) .. " s"
end

-- an effect name that is not taken yet ("Fulger", "Fulger 2", ...)
local function freeName(Editor, base)
	local taken = {}
	for _, fx in Editor.effects() do
		taken[fx.Name] = true
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

-- grouped list items (dropdowns, menus) in the order the groups first appear
local function groupedItems(entries, groupOf, itemOf)
	local order, byGroup = {}, {}
	for _, entry in entries do
		local group = groupOf(entry)
		if not byGroup[group] then
			byGroup[group] = {}
			table.insert(order, group)
		end
		table.insert(byGroup[group], entry)
	end
	local items = {}
	for _, group in order do
		table.insert(items, { header = true, label = group })
		for _, entry in byGroup[group] do
			table.insert(items, itemOf(entry))
		end
	end
	return items
end

-- the asset id out of what people paste: "123", "rbxassetid://123" or a Creator Store address
local function assetIdOf(text)
	text = trim(text)
	return text:match("^(%d+)$") or text:match("rbxassetid://(%d+)") or text:match("/asset/(%d+)") or text:match("/store/asset/(%d+)")
end

-- a fixed-size control inside a row whose items share the width (it would otherwise be squeezed)
local function rigid(inst)
	pcall(function()
		UI.make("UIFlexItem", { Parent = inst, FlexMode = Enum.UIFlexMode.None })
	end)
	return inst
end

-- the width of one of n equal fields followed by an icon button (gaps of 4): table columns line up in every row
local function fieldWidth(n, height)
	return UDim2.new(1 / n, -math.ceil((UI.H + UI.SPACE.xs * n) / n), 0, height or UI.H)
end

local function undo()
	pcall(function()
		game:GetService("ChangeHistoryService"):Undo()
	end)
end
local UNDO = { text = "Anulează", onClick = undo }

local function quote(name)
	return "„" .. UI.escape(name) .. "”"
end

-- HSV in plain math (as the kit: Color3.fromHSV / ToHSV are not in every environment the panels run in)
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

local function hexOf(c)
	local ok, hex = pcall(function()
		return c:ToHex()
	end)
	return "#" .. (ok and string.upper(tostring(hex)) or "FFFFFF")
end

-- the main colour of an effect, found like Editor.recolorEffect finds it: the heaviest hue among its saturated colours
local function mainColor(Editor, fx)
	local samples, bins = {}, {}
	local function add(c, w)
		if typeof(c) ~= "Color3" then
			return
		end
		local h, s, v = toHSV(c)
		if s >= NEUTRAL_SAT and v >= NEUTRAL_VAL then
			local weight = w * s * v
			local bin = math.floor(h * 24) % 24
			bins[bin] = (bins[bin] or 0) + weight
			table.insert(samples, { h = h, s = s, v = v, w = weight, bin = bin })
		end
	end
	for _, e in Editor.elements(fx) do
		local ok, d = pcall(Editor.read, e)
		if ok then
			if d.kind == "PARTICLES" or d.kind == "TRAIL" or d.kind == "BEAM" then
				for _, c in d.color do
					add(c, 1 / #d.color)
				end
			elseif d.kind == "LIGHT" then
				add(d.Color, 0.6)
			elseif d.kind == "MESH" then
				add(d.color, 1)
				add(d.colorEnd, 0.5)
			elseif d.kind == "CAMERA" then
				add(d.flash, 0.3)
			end
		end
	end
	local best, bestScore = nil, 0
	for i = 0, 23 do
		local score = (bins[i] or 0) + 0.5 * ((bins[(i - 1) % 24] or 0) + (bins[(i + 1) % 24] or 0))
		if score > bestScore then
			best, bestScore = i, score
		end
	end
	if not best then
		return nil
	end
	local sx, sy, ss, sv, sw = 0, 0, 0, 0, 0
	for _, smp in samples do
		if math.min((smp.bin - best) % 24, (best - smp.bin) % 24) <= 2 then
			sx += math.cos(smp.h * math.pi * 2) * smp.w
			sy += math.sin(smp.h * math.pi * 2) * smp.w
			ss += smp.s * smp.w
			sv += smp.v * smp.w
			sw += smp.w
		end
	end
	return fromHSV((math.atan2(sy, sx) / (math.pi * 2)) % 1, ss / sw, sv / sw)
end

-- a block indented like the controls of a row (under the label column), growing with its content
local function indented(parent)
	return UI.make("Frame", { Name = "Indented", Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y }, { UI.pad(0, 0, 0, UI.LABEL_W + UI.SPACE.sm), UI.vlist(2) })
end

-- a swatch of a data colour (an effect's colour, a suggestion): not a UI colour, shown as it is
local function swatch(parent, color, tip, onClick)
	local b = UI.make("TextButton", { Name = "Swatch", Parent = parent, Text = "", AutoButtonColor = false, BackgroundColor3 = color,
		Size = UDim2.new(1, 0, 0, UI.H) }, { UI.corner(UI.RADIUS.control), UI.stroke("border") })
	if tip then
		UI.tip(b, tip)
	end
	if onClick then
		b.MouseButton1Click:Connect(onClick)
	end
	return b
end

-- the text of a TextBox as the user types it (live checks), without waiting for the focus to go
local function onTyping(box, fn)
	pcall(function()
		box:GetPropertyChangedSignal("Text"):Connect(function()
			fn(box.Text)
		end)
	end)
end

-- a code to copy: plugins cannot write to the clipboard, so it sits in a read-only box that "Selectează" selects (then Ctrl+C)
local function codeBox(parent, code, meta)
	local box = UI.make("TextBox", { Name = "Code", Parent = parent, Text = code, TextEditable = false, ClearTextOnFocus = false,
		MultiLine = true, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		ClipsDescendants = true, Size = UDim2.new(1, 0, 0, 58) }, { UI.corner(UI.RADIUS.control), UI.stroke("fieldBorder"),
		UI.pad(6, 8, 6, 8) })
	UI.textStyle(box, "code")
	UI.skin(box, { BackgroundColor3 = "field", TextColor3 = "textDim" })
	local row = UI.make("Frame", { Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H) })
	UI.label(row, meta, { role = "meta", dim = true })
	local select = UI.button(row, "Selectează", function()
		local ok = pcall(function()
			box:CaptureFocus()
			box.CursorPosition = #box.Text + 1
			box.SelectionStart = 1
		end)
		UI.toast(ok and "Codul e selectat. Apasă Ctrl+C ca să-l copiezi." or "Dă click în casetă, apoi Ctrl+A și Ctrl+C.")
	end, { autoWidth = true, tip = "Selectează tot codul, apoi Ctrl+C" })
	select.AnchorPoint = Vector2.new(1, 0)
	select.Position = UDim2.fromScale(1, 0)
	return box
end

-- ---------------------------------------------------------------------------------------------
-- actions: every edit goes through the Editor (one undo step each); a failure becomes a toast
-- ---------------------------------------------------------------------------------------------
function Panel:fail(err)
	self.error = clean(err)
	warn("LostCube:", err)
	UI.toast(UI.escape(self.error), "error")
end

function Panel:try(fn, ...)
	local results = table.pack(pcall(fn, ...))
	if results[1] then
		self.error = nil
	else
		self:fail(results[2])
	end
	self:refresh()
	return table.unpack(results, 1, results.n)
end

function Panel:set(element, props)
	self:try(self.Editor.setProps, element, props)
end

-- one primary action per view (design.md): the first control of a render that wants it gets the accent, later ones the
-- normal style
function Panel:primary(wanted)
	if wanted and not self.primaryUsed then
		self.primaryUsed = true
		return "primary"
	end
	return "normal"
end

-- an empty state whose action is primary only when nothing else in this render already is
function Panel:empty(parent, text, actionText, onAction, opts)
	if self:primary(true) == "primary" then
		return UI.empty(parent, text, actionText, onAction, opts)
	end
	local frame = UI.empty(parent, text, nil, nil, opts)
	UI.button(frame, actionText, onAction, { autoWidth = true, height = UI.H_LARGE })
	return frame
end

function Panel:select(fx, element)
	self.effect, self.element = fx, element
	self:refresh()
end

-- ---------------------------------------------------------------------------------------------
-- preview and playhead
-- ---------------------------------------------------------------------------------------------
function Panel:play()
	if not self.effect then
		return
	end
	if self.handle and not self.handle.Done then
		self.handle:Destroy()
	end
	local wasPaused = self.paused
	self.paused = false
	local ok, h = pcall(self.Editor.preview, self.effect, { speed = self.speed })
	if ok then
		self.handle, self.handleFx = h, self.effect
		self.playClock, self.pausedClock = os.clock(), nil
	else
		self:fail(h)
	end
	if wasPaused or not ok then
		self:refresh()
	end
	self:watchPlayhead()
end

-- removes the preview from the scene (a paused one would otherwise stay frozen there) and ends the loop
function Panel:stopPreview()
	self.loop = false
	self.loopId = (self.loopId or 0) + 1
	self.paused = false
	if self.handle and not self.handle.Done then
		self.handle:Destroy()
	end
	self.handle = nil
	self:watchPlayhead()
	self:refresh()
end

function Panel:setLoop(on)
	self.loop = on
	self.loopId = (self.loopId or 0) + 1
	if on then
		local id = self.loopId
		local function running()
			return self.loop and self.loopId == id and self.effect and self.effect.Parent
		end
		task.spawn(function()
			while running() do
				self:play()
				-- wait one play; time spent paused does not count, so Pause works while repeating
				local ok, length = pcall(self.Editor.length, self.effect)
				local left = (ok and length or 1) + 0.35
				while left > 0 and running() do
					local dt = task.wait(0.05)
					if not self.paused then
						left -= dt * self.speed
					end
				end
			end
		end)
	end
	self:refresh()
end

function Panel:togglePause()
	local h = self.handle
	if not h or h.Done then
		if self.paused then -- the preview is gone: the button must not stay on "Continue"
			self.paused = false
			self:refresh()
		end
		return
	end
	if self.paused then
		h:Resume()
		self.paused = false
		if self.pausedClock and self.playClock then
			self.playClock += os.clock() - self.pausedClock
		end
		self.pausedClock = nil
	else
		h:Pause()
		self.paused = true
		self.pausedClock = os.clock()
	end
	self:watchPlayhead()
	self:refresh()
end

-- seconds into the preview of the selected effect, or nil when it is not playing
function Panel:elapsed()
	local h = self.handle
	if not h or h.Done or self.handleFx ~= self.effect then
		return nil
	end
	if type(h.start) == "number" and type(h.speed) == "number" then -- the player's own clock
		return ((h.pausedAt or os.clock()) - h.start) * h.speed
	end
	if not self.playClock then
		return nil
	end
	return ((self.pausedClock or os.clock()) - self.playClock) * self.speed
end

-- moves the playhead and the time read-out of the current render; true while the preview runs
function Panel:updatePlayhead()
	local t = self:elapsed()
	local length = self.playLength or 1
	local head, readout = self.playhead, self.readout
	if head and head.Parent then
		head.Visible = t ~= nil and t <= length
		if t then
			head.Position = UDim2.new(math.clamp(t / length, 0, 1), -1, 0, 0)
		end
	end
	if readout and readout.Parent then
		readout.Text = string.format("%.2f / %.2f s", math.clamp(t or 0, 0, length), length)
	end
	return t ~= nil and not self.paused
end

function Panel:stopPlayhead()
	if self.hb then
		self.hb:Disconnect()
		self.hb = nil
	end
end

-- one Heartbeat connection while the preview runs (none while paused, stopped or done)
function Panel:watchPlayhead()
	if not self:updatePlayhead() then
		self:stopPlayhead()
		return
	end
	if self.hb then
		return
	end
	local ok, conn = pcall(function()
		return game:GetService("RunService").Heartbeat:Connect(function()
			if not self:updatePlayhead() then
				self:stopPlayhead()
			end
		end)
	end)
	if ok then
		self.hb = conn
	end
end

function Panel:destroy()
	self.loop = false
	self.loopId = (self.loopId or 0) + 1
	self:stopPlayhead()
	if self.handle and not self.handle.Done then
		self.handle:Destroy()
	end
	self.handle = nil
end

-- ---------------------------------------------------------------------------------------------
-- render
-- ---------------------------------------------------------------------------------------------
function Panel:render(parent)
	local Editor = self.Editor
	if self.effect and not self.effect.Parent then
		self.effect, self.element = nil, nil
	end
	if self.element and (not self.element.Parent or (self.effect and not self.element:IsDescendantOf(self.effect))) then
		self.element = nil
	end
	self.playhead, self.readout = nil, nil
	self.primaryUsed = false
	local status = require(script.Parent.Installer).status()
	if not status.ok then
		UI.note(parent, status.vfx and "Modulele LostCube din joc sunt mai vechi decât pluginul."
			or "Jocul nu are încă modulele LostCube: <b>VFX</b> redă efectele în joc, <b>Editor</b> e pentru Claude.", C.warning)
		UI.button(UI.hstack(parent, { height = UI.H_LARGE }), "Instalează în joc", function()
			self:try(require(script.Parent.Installer).install)
		end, { style = self:primary(true), height = UI.H_LARGE, icon = "import", autoWidth = true,
			tip = "Copiază modulele în ReplicatedStorage.LostCube" })
	end

	self:renderEffects(parent)
	self:renderIO(parent)
	local fx = self.effect
	if not fx then
		self:watchPlayhead()
		return
	end
	local elements = Editor.elements(fx)
	self:renderEffect(parent, fx, elements)
	self:renderTools(parent, fx)
	self:renderElements(parent, fx, elements)
	if self.element then
		self:renderElement(parent, self.element)
	end
	self:watchPlayhead()
end

-- effects -----------------------------------------------------------------------------------------------------------------
function Panel:renderEffects(parent)
	local Editor = self.Editor
	local effects = Editor.effects()
	local body = UI.section(parent, "Efecte", { key = "vfx.effects", badge = #effects > 0 and #effects or nil })
	local building = self.creating or self.templating
	if #effects == 0 and not building then
		local empty = self:empty(body, "Pornește de la un șablon gata făcut sau de la un efect gol.", "Alege un șablon", function()
			self.templating, self.creating = true, false
			self:refresh()
		end, { icon = "effects", title = "Niciun efect încă" })
		UI.button(empty, "Efect gol", function()
			self.creating, self.templating = true, false
			self:refresh()
		end, { style = "ghost", autoWidth = true })
		return
	end
	local bar = UI.hstack(body, { fill = false })
	UI.button(bar, "Efect nou", function()
		self.creating = not self.creating
		self.templating = false
		self:refresh()
	end, { style = self:primary(not building and not self.effect), icon = "plus", autoWidth = true,
		selected = self.creating, tip = "Un efect gol, la care adaugi elemente" })
	UI.button(bar, "Din șablon", function()
		self.templating = not self.templating
		self.creating = false
		self:refresh()
	end, { icon = "grid", autoWidth = true, selected = self.templating,
		tip = "Efecte gata făcute: lovituri, fulgere, vindecări, teleportări…" })
	if self.creating then
		self:renderCreate(body)
	elseif self.templating then
		self:renderTemplates(body)
	end
	if #effects == 0 then
		return
	end
	-- the filter applies in place: App does not redraw while the search box has the focus
	local rows = {}
	local none
	local function filter(text)
		local query = string.lower(trim(text or ""))
		local visible = 0
		for _, row in rows do
			local match = query == "" or string.find(string.lower(row.fx.Name), query, 1, true) ~= nil
			row.item.Visible = match
			visible += match and 1 or 0
		end
		none.Visible = visible == 0
		none.Text = "Niciun efect nu se potrivește cu „" .. (text or "") .. "”."
	end
	UI.search(body, self.search, function(text)
		self.search = text
		filter(text)
	end, { placeholder = "Caută efecte" })
	local list = UI.scrollList(body, 6 * (UI.H_LARGE + 2))
	none = UI.label(body, "", { dim = true, wrap = true })
	none.Name = "NoMatch"
	for _, fx in effects do
		local item = UI.item(list, fx.Name, {
			icon = "effects", selected = fx == self.effect, note = #Editor.elements(fx) .. " el.", noteWidth = 40,
			onClick = function()
				self:select(fx, nil)
			end,
			actions = {
				{ icon = "duplicate", tip = "Duplică", onClick = function()
					local ok, copy = self:try(Editor.duplicateEffect, fx)
					if ok then
						self.effect, self.element = copy, nil
						UI.toast(quote(copy.Name) .. " e o copie a lui " .. quote(fx.Name) .. ".", "success", { action = UNDO })
					end
				end },
				{ icon = "trash", tip = "Șterge", danger = true, onClick = function()
					self:confirmRemove(fx)
				end },
			},
		})
		table.insert(rows, { fx = fx, item = item })
	end
	filter(self.search)
end

function Panel:confirmRemove(fx)
	local n = #self.Editor.elements(fx)
	UI.confirm("Ștergi efectul „" .. fx.Name .. "”?", (n == 0 and "E gol." or (count(n, "element", "elemente")
		.. (n == 1 and " se șterge" or " se șterg") .. " odată cu el.")) .. " Ctrl+Z îl aduce înapoi.",
		"Șterge", function()
			local name = fx.Name
			if self.effect == fx then
				self.effect, self.element = nil, nil
			end
			local ok = self:try(self.Editor.removeEffect, fx)
			if ok then
				UI.toast("Efectul " .. quote(name) .. " a fost șters.", "info", { action = UNDO })
			end
		end, { danger = true })
end

function Panel:renderCreate(body)
	local Editor = self.Editor
	local row = UI.hstack(body, { gap = 4 })
	local box = UI.textbox(row, "", nil, { placeholder = "Numele efectului, de ex. Foc" })
	local function create()
		local name = trim(box.Text) ~= "" and trim(box.Text) or freeName(Editor, "Efect")
		local ok, fx = pcall(Editor.newEffect, name, { duration = 1 })
		if ok then
			self.creating = false
			self.effect, self.element = fx, nil
			self.error = nil
		else
			self:fail(fx)
		end
		self:refresh()
	end
	box.FocusLost:Connect(function(enter)
		if enter then
			create()
		end
	end)
	rigid(UI.button(row, "Creează", create, { style = self:primary(true), width = 72 }))
	rigid(UI.iconButton(row, "close", function()
		self.creating = false
		self:refresh()
	end, { tip = "Anulează" }))
	task.defer(function()
		if box.Parent then
			box:CaptureFocus()
		end
	end)
	UI.spacer(body, 4)
end

-- new effect from a template ---------------------------------------------------------------------------------------------
function Panel:renderTemplates(body)
	local Editor = self.Editor
	local templates = Editor.TEMPLATES or {}
	local box = UI.vstack(body, 4)
	if #templates == 0 then
		UI.note(box, "Acest Editor nu are șabloane: modulul din joc e o versiune veche.", C.warning)
		return
	end
	local tpl
	for _, t in templates do
		if t.key == self.tplKey then
			tpl = t
		end
	end
	tpl = tpl or templates[1]
	self.tplKey = tpl.key
	UI.spacer(box, 4)
	local items = groupedItems(templates, function(t)
		return t.category
	end, function(t)
		return { value = t.key, label = t.label, hint = seconds(t.duration) }
	end)
	UI.dropdown(UI.row(box, "Șablon"), items, tpl.key, function(key)
		self.tplKey = key
		self.tplName = nil
		self:refresh()
	end, { menuWidth = 240 })
	local attachLabel = tpl.attach
	for _, a in Editor.ATTACH do
		if a.key == tpl.attach then
			attachLabel = a.label
		end
	end
	local about = indented(box)
	UI.label(about, string.format("%s  ·  %s  ·  %s", seconds(tpl.duration), count(#tpl.elements, "element", "elemente"),
		attachLabel), { role = "meta", height = 18 })
	UI.label(about, plain(tpl.desc or ""), { role = "meta", dim = true, wrap = true }).Name = "About"
	UI.spacer(box, 2)

	local colors = UI.row(box, "Culoare")
	UI.color(colors, self.tplColor or tpl.main, function(c)
		self.tplColor = c
		self:refresh()
	end, { tip = "Culoarea principală; restul culorilor se rotesc odată cu ea" })
	if self.tplColor then
		rigid(UI.iconButton(colors, "undo", function()
			self.tplColor = nil
			self:refresh()
		end, { tip = "Culorile originale" }))
	end
	UI.scrub(box, "Scară", self.tplScale or 1, function(v)
		self.tplScale = v
		self:refresh()
	end, { min = 0.25, max = 4, step = 0.05, decimals = 2, unit = "×", tip = "Mărimi, distanțe și viteze" })
	local defaultName = freeName(Editor, tpl.label)
	local nameBox = UI.textbox(UI.row(box, "Nume"), self.tplName or defaultName, function(text)
		self.tplName = text
	end, { placeholder = "Numele efectului" })
	local row = UI.hstack(UI.row(box, ""), { fill = false })
	UI.button(row, "Creează și redă", function()
		local name = trim(nameBox.Text) ~= "" and trim(nameBox.Text) or defaultName
		local scale = self.tplScale or 1
		local ok, fx = pcall(Editor.newFromTemplate, name, tpl.key, { color = self.tplColor, scale = scale ~= 1 and scale or nil })
		if ok then
			self.effect, self.element = fx, nil
			self.templating, self.tplName = false, nil
			self.error = nil
			self:refresh()
			task.defer(function()
				if self.effect == fx and fx.Parent then
					self:play()
				end
			end)
		else
			self:fail(fx)
			self:refresh()
		end
	end, { style = self:primary(true), icon = "play", autoWidth = true })
	UI.button(row, "Anulează", function()
		self.templating = false
		self:refresh()
	end, { style = "ghost", autoWidth = true })
	UI.spacer(box, 4)
	UI.divider(box)
end

-- import and export ---------------------------------------------------------------------------------------------------------
function Panel:renderIO(parent)
	local body = UI.section(parent, "Import și export", { key = "vfx.io", collapsed = true, onToggle = function(collapsed)
		if not collapsed then
			self:refresh()
		end
	end })
	if UI.collapsed and UI.collapsed["vfx.io"] then
		return -- built when opened
	end
	UI.segmented(body, {
		{ value = "code", label = "Cod", tip = "Importă un efect sau o bibliotecă dintr-un cod LC1, exportă biblioteca" },
		{ value = "store", label = "Creator Store", tip = "Un model VFX gratuit: scripturile se șterg, emitoarele devin un efect" },
	}, self.ioMode, function(v)
		self.ioMode = v
		self:refresh()
	end)
	if self.ioMode == "store" then
		self:renderStore(body)
	else
		self:renderCode(body)
	end
end

-- what a pasted code holds, for the line under the field: text, colour token
function Panel:describe(code)
	code = trim(code or "")
	if code == "" then
		return "Un efect sau o bibliotecă întreagă.", "textDim", nil
	end
	local Editor = self.Editor
	if not Editor.describeCode then
		return "Acest Editor nu citește coduri: modulul din joc e o versiune veche.", "warning", nil
	end
	local cache = self.described -- a pasted library is decoded once, not on every redraw
	if cache and cache.code == code then
		return cache.text, cache.token, cache.info
	end
	local text, token, info = self:describeNow(Editor, code)
	self.described = { code = code, text = text, token = token, info = info }
	return text, token, info
end

function Panel:describeNow(Editor, code)
	local info, message = Editor.describeCode(code)
	if not info then
		return clean(message or "Codul nu poate fi citit."), "danger", nil
	end
	local text
	if info.kind == "library" then
		local names = {}
		for i, e in info.effects do
			if i > 3 then
				table.insert(names, "…")
				break
			end
			table.insert(names, e.name)
		end
		text = string.format("Bibliotecă: %s (%s)", count(#info.effects, "efect", "efecte"), table.concat(names, ", "))
	else
		local e = info.effects[1]
		text = string.format("„%s”  ·  %s  ·  %s", tostring(e.name), count(e.elements or 0, "element", "elemente"),
			seconds(tonumber(e.duration) or 1))
	end
	if (info.clamped or 0) > 0 then
		text ..= "  ·  " .. info.clamped .. " valori aduse în limite"
	end
	return text, "success", info
end

function Panel:importCode(code, name)
	local Editor = self.Editor
	code = trim(code or "")
	local _, _, info = self:describe(code)
	if not info then
		local text = self:describe(code)
		self:fail(code == "" and "Lipește mai întâi un cod LC1." or text)
		self:refresh()
		return
	end
	if info.kind == "library" then
		local ok, list, result = self:try(Editor.importMany, code)
		if ok then
			self.pasteCode, self.pasteName = nil, nil
			self.effect, self.element = list[1], nil
			local text = "Am importat " .. count(#list, "efect", "efecte") .. "."
			for _, note in result.notes or {} do
				text ..= " " .. UI.escape(note)
			end
			UI.toast(text, "success", { action = UNDO })
		end
		return
	end
	name = trim(name or "")
	local ok, fx, result = self:try(Editor.importEffect, code, name ~= "" and name or nil, { unique = true })
	if ok then
		self.pasteCode, self.pasteName = nil, nil
		self.effect, self.element = fx, nil
		local text = "Am importat " .. quote(fx.Name) .. "."
		for _, note in result.notes or {} do
			text ..= " " .. UI.escape(note)
		end
		UI.toast(text, "success", { action = UNDO })
	end
end

function Panel:renderCode(body)
	local Editor = self.Editor
	local box = UI.textbox(UI.row(body, "Cod"), self.pasteCode or "", function(text)
		self.pasteCode = text
		self:refresh()
	end, { placeholder = "Lipește aici un cod LC1:…", mono = true })
	box.Name = "PasteCode"
	local text, token = self:describe(self.pasteCode)
	local status = UI.label(indented(body), text, { role = "meta", color = token, wrap = true })
	status.Name = "CodeStatus"
	-- checked as it is pasted (the panel is not redrawn while the box has the focus)
	local gen = 0
	onTyping(box, function(value)
		gen += 1
		local mine = gen
		task.delay(0.2, function()
			if mine == gen and status.Parent then
				local t, k = self:describe(value)
				status.Text = t
				UI.skin(status, { TextColor3 = k })
			end
		end)
	end)
	local nameBox = UI.textbox(UI.row(body, "Nume"), self.pasteName or "", function(value)
		self.pasteName = value
	end, { placeholder = "Numele din cod" })
	local row = UI.hstack(UI.row(body, ""), { fill = false })
	local _, _, valid = self:describe(self.pasteCode)
	UI.button(row, "Importă", function()
		self:importCode(box.Text, nameBox.Text)
	end, { style = self:primary(valid ~= nil), icon = "import", autoWidth = true,
		tip = "Un nume deja folosit primește un număr" })
	UI.button(row, "Exportă biblioteca", function()
		self.libraryOpen = not self.libraryOpen
		self:refresh()
	end, { autoWidth = true, selected = self.libraryOpen, tip = "Toate efectele într-un singur cod" })
	if self.libraryOpen then
		UI.spacer(body, 4)
		if not Editor.exportAll then
			UI.note(body, "Acest Editor nu face coduri: modulul din joc e o versiune veche.", C.warning)
			return
		end
		local rev = self:revision()
		if not (self.libraryCode and self.libraryCode.rev == rev) then
			local ok, code, stats = pcall(Editor.exportAll)
			self.libraryCode = { rev = rev, ok = ok, code = code, stats = stats }
		end
		local lib = self.libraryCode
		if lib.ok then
			codeBox(body, lib.code, string.format("%s  ·  %s caractere", count(lib.stats.effects or 0, "efect", "efecte"),
				lib.stats.chars or #lib.code))
		else
			UI.note(body, UI.escape(clean(lib.code)), C.danger)
		end
	end
end

-- the revision of the effects folder (every Editor edit bumps it): cached codes are made again after a change
function Panel:revision()
	local ok, rev = pcall(function()
		local folder = self.Editor.folder(false)
		return folder and folder:GetAttribute("LC_Rev") or 0
	end)
	return ok and rev or 0
end

-- free VFX from the Creator Store (scripts are deleted by the Editor before anything is copied)
function Panel:renderStore(body)
	local Editor = self.Editor
	if not Editor.importAsset then
		UI.note(body, "Acest Editor nu poate importa: modulul din joc e o versiune veche.", C.warning)
		return
	end
	local idBox = UI.textbox(UI.row(body, "Asset"), self.importId or "", function(text)
		self.importId = text
		self:refresh() -- the import button lights up once there is an id
	end, { placeholder = "ID sau adresa paginii din Creator Store" })
	local nameBox = UI.textbox(UI.row(body, "Nume"), self.importName or "", function(text)
		self.importName = text
	end, { placeholder = "Import <ID>" })
	local row = UI.hstack(UI.row(body, ""), { fill = false })
	UI.button(row, self.importing and "Se importă…" or "Importă", function()
		if self.importing then
			return
		end
		local id = assetIdOf(idBox.Text)
		if not id then
			self:fail("Scrie ID-ul asset-ului: numărul din adresa paginii (…/store/asset/NUMĂR).")
			self:refresh()
			return
		end
		local name = trim(nameBox.Text)
		self.importId, self.importName = idBox.Text, nameBox.Text
		self.importing, self.importReport = true, nil
		self:refresh()
		task.spawn(function()
			-- the download yields: the texts were read above, the boxes of this render are already gone
			local ok, fx, report = pcall(Editor.importAsset, tonumber(id), name ~= "" and name or nil)
			self.importing = false
			if ok and fx then
				self.effect, self.element = fx, nil
				self.importReport = report
				UI.toast("Am importat " .. quote(fx.Name) .. ". Scripturile modelului au fost șterse.", "success", { action = UNDO })
			else
				local text = ok and report and report.error or clean(fx)
				self.importReport = ok and report or { ok = false, lines = { text } }
				self:fail(text)
			end
			self:refresh()
		end)
	end, { style = self:primary(assetIdOf(self.importId or "") ~= nil), icon = "import",
		autoWidth = true, tip = "Descarcă modelul, șterge scripturile și face din emitoare un efect" })
	UI.button(row, "Din selecție", function()
		if not self.effect then
			self:fail("Alege mai întâi un efect (sau creează unul), apoi importă în el.")
			self:refresh()
			return
		end
		local picked = Selection:Get()[1]
		if not picked then
			self:fail("Selectează în Explorer modelul cu particule (inserat din Toolbox).")
			self:refresh()
			return
		end
		local ok, result = self:try(Editor.importEmitters, self.effect, picked)
		if ok then
			local lines = { string.format("Importate în %s: %d particule, %d trail-uri, %d lumini. Scripturile nu se copiază.",
				self.effect.Name, result.particles, result.trails, result.lights) }
			for _, note in result.notes do
				table.insert(lines, note)
			end
			self.importReport = { ok = true, lines = lines }
			UI.toast(UI.escape(lines[1]), "success", { action = UNDO })
		end
	end, { autoWidth = true, tip = "Copiază emitoarele obiectului selectat în efectul ales (fără scripturi)" })
	local report = self.importReport
	if report and report.lines and #report.lines > 0 then
		local lines = {}
		for _, line in report.lines do
			table.insert(lines, UI.escape(plain(unmark(line))))
		end
		UI.note(body, table.concat(lines, "\n"), report.ok and ((report.suspicious or 0) == 0 and C.success or C.warning) or C.danger)
	end
end

-- the selected effect: header, transport, timeline, settings -----------------------------------------------------------------
function Panel:renderEffect(parent, fx, elements)
	local Editor = self.Editor
	local duration = fx:GetAttribute("LC_Duration") or 1
	local okLength, length = pcall(Editor.length, fx)
	length = math.max(0.1, okLength and length or duration)
	self.playLength = length
	local block = UI.vstack(parent, 4)
	block.Name = "Effect"
	UI.spacer(block, 2)
	UI.header(block, fx.Name, {
		subtitle = string.format("%s  ·  %s", #elements == 0 and "Fără elemente" or count(#elements, "element", "elemente"),
			seconds(duration)),
		actions = {
			{ icon = "copy", tip = "Cod de partajare", active = self.toolMode == "share" and UI.collapsed and UI.collapsed["vfx.tools"] == false,
				onClick = function()
					self.toolMode = "share"
					if UI.collapsed then
						UI.collapsed["vfx.tools"] = false
						if UI.onCollapse then -- App remembers the folded sections
							UI.onCollapse()
						end
					end
					self:refresh()
				end },
			{ icon = "locate", tip = "Selectează în Explorer", onClick = function()
				Selection:Set({ fx })
			end },
		},
	})

	-- transport: play / pause / stop / loop, the time, the speed
	local bar = UI.make("Frame", { Name = "Transport", Parent = block, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H) },
		{ UI.hlist(4, false) })
	UI.iconButton(bar, "play", function()
		self:play()
	end, { tip = "Redă: pe selecție (personaj / part) sau pe sol, în fața camerei" })
	UI.iconButton(bar, "pause", function()
		self:togglePause()
	end, { tip = self.paused and "Continuă" or "Pauză", active = self.paused })
	UI.iconButton(bar, "stop", function()
		self:stopPreview()
	end, { tip = "Oprește și scoate previzualizarea din scenă" })
	UI.iconButton(bar, "refresh", function()
		self:setLoop(not self.loop)
	end, { tip = self.loop and "Oprește repetarea" or "Repetă în buclă", active = self.loop, name = "IconButton_loop" })
	local readout = UI.label(bar, string.format("%.2f / %.2f s", 0, length), { role = "meta", dim = true,
		align = Enum.TextXAlignment.Right })
	readout.Name = "Time"
	readout.Size = UDim2.new(1, -(4 * UI.H + 5 * 4 + 64), 0, UI.H)
	self.readout = readout
	UI.dropdown(bar, SPEEDS, self.speed, function(v)
		self.speed = v
		self:refresh()
	end, { width = 64, tip = "Viteza previzualizării" })

	if #elements > 0 then -- an effect without elements: the empty state of Elemente says what to do
		self:renderStrip(block, fx, elements, duration, length)
	end
	UI.spacer(block, 4)
	UI.textbox(UI.row(block, "Nume"), fx.Name, function(text)
		if trim(text) ~= "" then
			self:try(Editor.setEffect, fx, { name = trim(text) })
		end
	end)
	UI.scrub(block, "Durată", duration, function(v)
		self:try(Editor.setEffect, fx, { duration = v })
	end, { min = 0.05, step = 0.05, decimals = 2, unit = "s", tip = "Cât emite efectul; particulele pot trăi și după" })
	local attachItems = {}
	for _, a in Editor.ATTACH do
		table.insert(attachItems, { value = a.key, label = a.label })
	end
	UI.dropdown(UI.row(block, "Prins de"), attachItems, fx:GetAttribute("LC_Attach") or "GROUND", function(v)
		self:try(Editor.setEffect, fx, { attach = v })
	end, { menuWidth = 220, tip = "Unde se pune efectul când e redat pe un personaj" })
	UI.spacer(block, 0) -- with the gaps of the lists: 12 px to the divider, as under a section
	UI.divider(parent)
end

-- what a lane of the timeline draws for one element: { kind = "bar" | "life" | "tick" | "dot", t0, t1, faint }
local function laneMarks(data, duration)
	local marks = {}
	if data.kind == "LIGHT" then
		local keys = data.keys or {}
		if #keys == 0 then -- no keys: the light stays on
			table.insert(marks, { kind = "bar", t0 = 0, t1 = duration, faint = true })
			return marks
		end
		local first, last = math.huge, -math.huge
		for _, k in keys do
			first, last = math.min(first, k[1] or 0), math.max(last, k[1] or 0)
		end
		table.insert(marks, { kind = "bar", t0 = first, t1 = last })
		for _, k in keys do
			table.insert(marks, { kind = "dot", t0 = k[1] or 0 })
		end
		return marks
	end
	-- how long what it emits stays visible (a particle's life, a trail's, a flash, a kick of the camera, a sound)
	local life = 0
	if data.kind == "PARTICLES" or data.kind == "MESH" then
		life = data.lifetime and (data.lifetime[2] or data.lifetime[1]) or 0
	elseif data.kind == "TRAIL" then
		life = data.lifetime or 0
	elseif data.kind == "BEAM" then
		life = data.flashTime or 0
	elseif data.kind == "CAMERA" then
		life = math.max(data.shake > 0 and data.shakeTime or 0, data.fov ~= 0 and data.fovTime or 0, data.flash and data.flashTime or 0)
	elseif data.kind == "SOUND" then
		life = data.length or 0
	end
	local w = data.window
	if w then
		table.insert(marks, { kind = "bar", t0 = w[1], t1 = w[2] })
		if life > 0 then
			table.insert(marks, { kind = "life", t0 = w[2], t1 = w[2] + life })
		end
	end
	for _, b in data.bursts or {} do
		if life > 0 then
			table.insert(marks, { kind = "life", t0 = b[1], t1 = b[1] + life })
		end
		table.insert(marks, { kind = "tick", t0 = b[1] })
	end
	return marks
end
Panel.laneMarks = laneMarks

-- a step for the time axis: about four labels over the length
local function axisStep(length)
	for _, step in { 0.05, 0.1, 0.2, 0.25, 0.5, 1, 2, 5, 10 } do
		if length / step <= 4.5 then
			return step
		end
	end
	return 20
end

-- the timeline of the effect: one lane per element (windows as bars, bursts as ticks, how long their output stays
-- visible as a faint line), the time axis 0..length with the tail after the duration shaded, and the playhead of the
-- preview. Read-only: a click on a lane selects the element. Drawn on each render; the playhead moves on its own.
function Panel:renderStrip(parent, fx, elements, duration, length)
	local Editor = self.Editor
	local n = #elements
	local strip = UI.make("Frame", { Name = "Timeline", Parent = parent, BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, AXIS_H + math.max(1, n) * LANE_H + 2) })
	local function at(t)
		return math.clamp(t / length, 0, 1)
	end
	-- background: tail shading, grid lines, the end of the duration, the axis labels
	local back = UI.make("Frame", { Name = "Grid", Parent = strip, BackgroundTransparency = 1, Position = UDim2.fromOffset(NAME_W, 0),
		Size = UDim2.new(1, -NAME_W, 1, 0) })
	if duration < length then
		local tail = UI.make("Frame", { Name = "Tail", Parent = back, Position = UDim2.new(at(duration), 0, 0, AXIS_H),
			Size = UDim2.new(1 - at(duration), 0, 1, -AXIS_H) })
		UI.skin(tail, { BackgroundColor3 = "raised" })
		UI.tip(tail, "După durată: particulele, urmele și sunetele încă vizibile")
	end
	local step = axisStep(length)
	local t = 0
	while t <= length + 1e-6 do
		local x = at(t)
		local line = UI.make("Frame", { Name = "GridLine", Parent = back, Position = UDim2.new(x, 0, 0, AXIS_H - 3),
			Size = UDim2.new(0, 1, 1, -(AXIS_H - 3)) })
		UI.skin(line, { BackgroundColor3 = "divider" })
		if x < 0.9 or t == 0 then
			local label = UI.label(back, UI.fmt(t, 2), { role = "meta", dim = true, width = 40, height = AXIS_H - 2,
				align = t == 0 and Enum.TextXAlignment.Left or Enum.TextXAlignment.Center })
			label.Position = UDim2.new(x, t == 0 and 0 or -20, 0, 0)
		end
		t = math.floor((t + step) / step + 0.5) * step
	end
	local unit = UI.label(back, "s", { role = "meta", dim = true, width = 16, height = AXIS_H - 2, align = Enum.TextXAlignment.Right })
	unit.AnchorPoint = Vector2.new(1, 0)
	unit.Position = UDim2.fromScale(1, 0)
	local endLine = UI.make("Frame", { Name = "End", Parent = back, Position = UDim2.new(at(duration), 0, 0, AXIS_H - 3),
		Size = UDim2.new(0, 1, 1, -(AXIS_H - 3)) })
	UI.skin(endLine, { BackgroundColor3 = "textDisabled" })

	for i, e in elements do
		local ok, data = pcall(Editor.read, e)
		if not ok then
			continue
		end
		local selected = e == self.element
		local muted = data.muted
		local lane = UI.make("TextButton", { Name = "Lane", Parent = strip, Text = "", AutoButtonColor = false,
			BackgroundTransparency = selected and 0 or 1, Position = UDim2.fromOffset(0, AXIS_H + (i - 1) * LANE_H),
			Size = UDim2.new(1, 0, 0, LANE_H) }, { UI.corner(2) })
		UI.skin(lane, { BackgroundColor3 = selected and "accentSoft" or "surfaceHover" })
		lane:SetAttribute("Selected", selected)
		local name = UI.label(lane, e.Name, { role = "meta", height = LANE_H, width = NAME_W - 10,
			color = muted and "textDisabled" or (selected and "text" or "textDim") })
		name.Position = UDim2.fromOffset(4, 0)
		local track = UI.make("Frame", { Name = "Track", Parent = lane, BackgroundTransparency = 1, Position = UDim2.fromOffset(NAME_W, 0),
			Size = UDim2.new(1, -NAME_W, 1, 0) })
		local token = selected and "accent" or (muted and "textDisabled" or "textDim")
		for _, m in laneMarks(data, duration) do
			local alpha = (m.kind == "life" or m.faint) and 0.55 or 0
			if muted then -- a hidden element stays readable, but quieter
				alpha = 1 - (1 - alpha) * 0.45
			end
			local frame
			if m.kind == "bar" or m.kind == "life" then
				local width = math.max(0, at(m.t1) - at(m.t0))
				local h = m.kind == "bar" and 6 or 2
				frame = UI.make("Frame", { Name = m.kind == "bar" and "Bar" or "Life", Parent = track, AnchorPoint = Vector2.new(0, 0.5),
					Position = UDim2.new(at(m.t0), 0, 0.5, 0), Size = UDim2.new(width, width < 0.01 and 2 or 0, 0, h),
					BackgroundTransparency = alpha }, { UI.corner(h // 2) })
			elseif m.kind == "tick" then
				frame = UI.make("Frame", { Name = "Tick", Parent = track, AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.new(at(m.t0), 0, 0.5, 0), Size = UDim2.fromOffset(2, 10), BackgroundTransparency = alpha }, { UI.corner(1) })
			else
				frame = UI.make("Frame", { Name = "Dot", Parent = track, AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.new(at(m.t0), 0, 0.5, 0), Size = UDim2.fromOffset(6, 6), BackgroundTransparency = alpha }, { UI.corner(3) })
			end
			UI.skin(frame, { BackgroundColor3 = token })
		end
		if not selected then
			lane.MouseEnter:Connect(function()
				lane.BackgroundTransparency = 0
			end)
			lane.MouseLeave:Connect(function()
				lane.BackgroundTransparency = 1
			end)
		end
		lane.MouseButton1Click:Connect(function()
			self:select(fx, e)
		end)
	end
	-- the playhead, above the lanes (moved by the Heartbeat of watchPlayhead)
	local holder = UI.make("Frame", { Name = "Playhead", Parent = strip, BackgroundTransparency = 1, Position = UDim2.fromOffset(NAME_W, 0),
		Size = UDim2.new(1, -NAME_W, 1, 0) })
	local head = UI.make("Frame", { Name = "Head", Parent = holder, Visible = false, Position = UDim2.new(0, -1, 0, 0),
		Size = UDim2.new(0, 2, 1, 0) })
	UI.skin(head, { BackgroundColor3 = "accent" })
	local knob = UI.make("Frame", { Name = "Knob", Parent = head, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 1),
		Size = UDim2.fromOffset(8, 8) }, { UI.corner(4) })
	UI.skin(knob, { BackgroundColor3 = "accent" })
	self.playhead = head
	return strip
end

-- effect tools: colour, scale, variants, share code ---------------------------------------------------------------------------
function Panel:renderTools(parent, fx)
	local body = UI.section(parent, "Unelte", { key = "vfx.tools", collapsed = true, onToggle = function(collapsed)
		if not collapsed then
			self:refresh()
		end
	end })
	if UI.collapsed and UI.collapsed["vfx.tools"] then
		return -- built when opened
	end
	UI.segmented(body, {
		{ value = "color", label = "Culoare", tip = "Recolorează tot efectul, culori potrivite cu harta" },
		{ value = "scale", label = "Scară", tip = "Mărește sau micșorează efectul, întinde timpul" },
		{ value = "variants", label = "Variante", tip = "Copii în alte culori și mărimi" },
		{ value = "share", label = "Partajează", tip = "Codul efectului, de trimis altcuiva" },
	}, self.toolMode, function(v)
		self.toolMode = v
		self:refresh()
	end)
	if self.toolMode == "scale" then
		self:renderScale(body, fx)
	elseif self.toolMode == "variants" then
		self:renderVariants(body, fx)
	elseif self.toolMode == "share" then
		self:renderShare(body, fx)
	else
		self:renderColor(body, fx)
	end
end

function Panel:recolor(fx, color)
	local Editor = self.Editor
	local ok, _, info = self:try(Editor.recolorEffect, fx, color)
	if ok then
		if info and info.neutral then
			UI.toast("Efectul are doar alb, gri și negru: nu e nimic de recolorat.", "warning")
		else
			local name = Editor.colorName and Editor.colorName(color)
			UI.toast("Efectul e acum " .. (name and (name .. " (" .. hexOf(color) .. ")") or hexOf(color)) .. ".", "success",
				{ action = UNDO })
		end
	end
end

function Panel:renderColor(body, fx)
	local Editor = self.Editor
	if not Editor.recolorEffect then
		UI.note(body, "Acest Editor nu recolorează: modulul din joc e o versiune veche.", C.warning)
		return
	end
	local main = mainColor(Editor, fx)
	if main then
		UI.color(UI.row(body, "Culoare"), main, function(c)
			self:recolor(fx, c)
		end, { tip = "Culoarea principală: celelalte se rotesc odată cu ea; albul și griul rămân" })
	else
		UI.label(UI.row(body, "Culoare"), "Doar alb, gri și negru", { dim = true })
	end
	local row = UI.hstack(UI.row(body, ""), { fill = false })
	UI.button(row, "Potrivește cu harta", function()
		self:suggestFor(fx)
	end, { autoWidth = true, tip = "Culori care se văd bine pe culorile hărții (din analiza tab-ului Joc)" })
	local s = self.suggest
	if s and s.fx == fx then
		local area = UI.row(body, "Sugestii")
		for _, item in s.list do
			swatch(area, item.color, item.reason .. "  " .. item.hex, function()
				self:recolor(fx, item.color)
			end)
		end
	end
end

-- colours that read well on the map, from the stored analysis of the Game tab
function Panel:suggestFor(fx)
	local Editor = self.Editor
	local ok, result = pcall(function()
		local report = require(script.Parent.Analyzer).load()
		assert(report, "LostCube: jocul nu e analizat încă. Deschide tab-ul Joc și rulează analiza.")
		local palette, mood = Editor.paletteOf(report)
		return Editor.suggestColors(palette, { count = 5, night = mood and mood.night })
	end)
	if ok then
		self.suggest = { fx = fx, list = result }
	else
		self.suggest = nil
		self:fail(result)
	end
	self:refresh()
end

function Panel:renderScale(body, fx)
	local Editor = self.Editor
	local function steps(label, list, apply, tip)
		local area = UI.row(body, label)
		for _, k in list do
			UI.button(area, "×" .. UI.fmt(k, 2), function()
				apply(k)
			end, { tip = string.format(tip, UI.fmt(k, 2)) })
		end
	end
	if Editor.scaleEffect then
		steps("Mărime", SCALE_STEPS, function(k)
			local ok = self:try(Editor.scaleEffect, fx, k)
			if ok then
				UI.toast(string.format("Mărimi, distanțe și viteze ×%s.", UI.fmt(k, 2)), "success", { action = UNDO })
			end
		end, "Mărimi, distanțe și viteze ×%s")
	end
	steps("Timp", TIME_STEPS, function(k)
		local ok = self:try(Editor.retime, fx, k)
		if ok then
			UI.toast(string.format("Durată, emisii, burst-uri și vieți ×%s.", UI.fmt(k, 2)), "success", { action = UNDO })
		end
	end, "Durată, emisii, burst-uri, chei și vieți ×%s; vitezele rămân")
end

function Panel:renderVariants(body, fx)
	local Editor = self.Editor
	if not Editor.makeVariants then
		UI.note(body, "Acest Editor nu face variante: modulul din joc e o versiune veche.", C.warning)
		return
	end
	local n = self.varCount or 3
	local hueStep = self.varHue or math.floor(360 / (n + 1) + 0.5)
	local scaleStep = self.varScale or 1
	UI.scrub(body, "Câte", n, function(v)
		self.varCount = math.clamp(math.floor(v + 0.5), 1, 12)
		self:refresh()
	end, { min = 1, max = 12, step = 1, decimals = 0, tip = "Câte copii" })
	UI.slider(UI.row(body, "Pas de nuanță"), hueStep, function(v)
		self.varHue = v
		self:refresh()
	end, { min = 0, max = 180, step = 5, decimals = 0, unit = "°", field = true,
		tip = "Cât se rotește culoarea de la o copie la următoarea" })
	UI.scrub(body, "Pas de mărime", scaleStep, function(v)
		self.varScale = v
		self:refresh()
	end, { min = 0.5, max = 2, step = 0.05, decimals = 2, unit = "×", tip = "Fiecare copie e de atâtea ori mai mare decât precedenta" })
	local main = mainColor(Editor, fx)
	if main then
		local h, s, v = toHSV(main)
		local area = UI.row(body, "Culori")
		swatch(area, main, "Originalul " .. hexOf(main))
		for i = 1, n do
			local c = fromHSV((h + i * hueStep / 360) % 1, s, v)
			swatch(area, c, string.format("Varianta %d  %s", i, hexOf(c)))
		end
	end
	local row = UI.hstack(UI.row(body, ""), { fill = false })
	UI.button(row, "Creează variantele", function()
		local ok, list = self:try(Editor.makeVariants, fx, { count = n, hueStep = hueStep, scale = scaleStep })
		if ok then
			local names = {}
			for _, copy in list do
				table.insert(names, quote(copy.Name))
			end
			UI.toast("Am creat " .. count(#list, "variantă", "variante") .. ": " .. table.concat(names, ", ") .. ".", "success",
				{ action = UNDO })
		end
	end, { icon = "duplicate", autoWidth = true })
end

function Panel:renderShare(body, fx)
	local Editor = self.Editor
	if not Editor.exportEffect then
		UI.note(body, "Acest Editor nu face coduri: modulul din joc e o versiune veche.", C.warning)
		return
	end
	local rev = self:revision()
	local cached = self.shareCode
	if not (cached and cached.fx == fx and cached.rev == rev) then
		local ok, code, stats = pcall(Editor.exportEffect, fx)
		cached = { fx = fx, rev = rev, ok = ok, code = code, stats = stats }
		self.shareCode = cached
	end
	if not cached.ok then
		UI.note(body, UI.escape(clean(cached.code)), C.danger)
		return
	end
	local stats = cached.stats or {}
	local meta = string.format("%s caractere  ·  %s", stats.chars or #cached.code, count(stats.elements or 0, "element", "elemente"))
	if (stats.ignored or 0) > 0 then
		meta ..= "  ·  " .. stats.ignored .. " obiecte ignorate"
	end
	codeBox(body, cached.code, meta)
end

-- elements -------------------------------------------------------------------------------------------------------------------
function Panel:addItems(fx)
	local Editor = self.Editor
	local function add(key)
		local ok, element = self:try(Editor.addElement, fx, key)
		if ok then
			self.element = element
		end
	end
	local items = groupedItems(Editor.PRESETS, function(p)
		return p.group or KIND_LABEL[p.kind]
	end, function(p)
		return { value = p.key, label = p.label, classIcon = CLASS[p.kind], onClick = function()
			add(p.key)
		end }
	end)
	table.insert(items, { header = true, label = "Goale" })
	for _, kind in EMPTY_KINDS do
		table.insert(items, { value = kind, label = KIND_LABEL[kind], classIcon = CLASS[kind], onClick = function()
			add(kind)
		end })
	end
	return items
end

function Panel:renderElements(parent, fx, elements)
	local Editor = self.Editor
	local anchor
	local function openMenu()
		if anchor then
			UI.menu(anchor, self:addItems(fx), { width = 248 })
		end
	end
	local body = UI.section(parent, "Elemente", { key = "vfx.elements", badge = #elements > 0 and #elements or nil, right = function(r)
		anchor = UI.iconButton(r, "plus", openMenu, { tip = "Adaugă element" })
	end, rightWidth = 28 })
	if #elements == 0 then
		self:empty(body, "Particule, lumini, urme, raze, sunete sau tremur de cameră.", "Adaugă element", openMenu,
			{ title = "Niciun element" })
		return
	end
	for _, e in elements do
		local muted = e:GetAttribute("LC_Muted") == true
		local kind = Editor.kindOf(e)
		UI.item(body, e.Name, {
			classIcon = CLASS[kind], selected = e == self.element, muted = muted,
			onClick = function()
				self:select(fx, e)
			end,
			actions = {
				{ icon = muted and "eyeOff" or "eye", tip = muted and "Arată" or "Ascunde", onClick = function()
					self:set(e, { muted = not muted })
				end },
				{ icon = "duplicate", tip = "Duplică", onClick = function()
					local ok, copy = self:try(Editor.duplicate, e)
					if ok then
						self.element = copy
					end
				end },
				{ icon = "trash", tip = "Șterge", danger = true, onClick = function()
					local name = e.Name
					if self.element == e then
						self.element = nil
					end
					local ok = self:try(Editor.remove, e)
					if ok then
						UI.toast(quote(name) .. " a fost șters.", "info", { action = UNDO })
					end
				end },
			},
		})
	end
end

-- element properties --------------------------------------------------------------------------------------------------------
-- one number: a row whose label you drag
function Panel:scrub(body, label, value, element, key, opts)
	UI.scrub(body, label, value, function(v)
		self:set(element, { [key] = v })
	end, opts)
end

-- one bounded number: a slider with an editable value
function Panel:slider(body, label, value, element, key, opts)
	local o = table.clone(opts)
	o.field = true
	UI.slider(UI.row(body, label), value, function(v)
		self:set(element, { [key] = v })
	end, o)
end

-- several numbers in one row, each with a small letter you drag (X / Y / Z, min / max)
function Panel:parts(body, label, values, parts, onChange, opts)
	local area = UI.row(body, label)
	-- each letter sits next to its own field, the parts further apart (spacing of the kit's rows, adjusted)
	pcall(function()
		area:FindFirstChildOfClass("UIListLayout").Padding = UDim.new(0, UI.SPACE.md)
	end)
	for i, part in parts do
		local partWidth = opts.partWidths and opts.partWidths[i] or opts.partWidth or 10
		local row = UI.scrub(area, part, values[i], function(v)
			local t = table.clone(values)
			t[i] = v
			onChange(t)
		end, { labelWidth = partWidth, min = opts.min, max = opts.max, step = opts.step, decimals = opts.decimals,
			unit = opts.unit, tip = opts.tips and opts.tips[i] or opts.tip })
		pcall(function()
			row:FindFirstChildOfClass("UIListLayout").Padding = UDim.new(0, UI.SPACE.xs)
			for _, child in row:GetChildren() do
				if child.ClassName == "Frame" then
					child.Size = UDim2.new(1, -(partWidth + UI.SPACE.xs), 1, 0)
				end
			end
		end)
	end
end

-- a random range: min / max
function Panel:range(body, label, values, element, key, opts)
	opts = table.clone(opts)
	opts.partWidth = 24
	self:parts(body, label, { values[1], values[2] }, { "min", "max" }, function(t)
		self:set(element, { [key] = { t[1], t[2] } })
	end, opts)
end

-- from a start value to an end value: "de la … la …"
local SPAN_WIDTHS = { 28, 14 }
function Panel:span(body, label, values, onChange, opts)
	opts = table.clone(opts)
	opts.partWidths = SPAN_WIDTHS
	self:parts(body, label, { values[1], values[2] }, { "de la", "la" }, onChange, opts)
end

function Panel:vector(body, label, v, element, key, opts)
	self:parts(body, label, { v.X, v.Y, v.Z }, { "X", "Y", "Z" }, function(t)
		local cur = (key == "position" and self.Editor.position(element)) or v
		local x = { cur.X, cur.Y, cur.Z }
		for i = 1, 3 do
			if t[i] ~= ({ v.X, v.Y, v.Z })[i] then
				x[i] = t[i]
			end
		end
		self:set(element, { [key] = Vector3.new(x[1], x[2], x[3]) })
	end, opts)
end

-- start / middle / end of a curve over the life of a particle
local CURVE_TIPS = { "La început", "La mijloc", "La sfârșit" }
function Panel:curve(body, label, values, element, key, opts)
	local area = UI.row(body, label)
	for i = 1, 3 do
		local o = table.clone(opts)
		o.tip = CURVE_TIPS[i]
		UI.number(area, values[i], function(v)
			local t = { values[1], values[2], values[3], mid = values.mid }
			t[i] = v
			self:set(element, { [key] = t })
		end, o)
	end
end

function Panel:colorRows(body, data, element)
	local cols = data.color
	local mode = #cols
	UI.segmented(UI.row(body, "Culori"), {
		{ value = 1, label = "Una" }, { value = 2, label = "Două", tip = "De la început la sfârșit" },
		{ value = 3, label = "Trei", tip = "Început, mijloc, sfârșit" },
	}, mode, function(m)
		local a, b, c = cols[1], cols[2] or cols[1], cols[3] or cols[2] or cols[1]
		self:set(element, { color = m == 1 and a or (m == 2 and { a, b } or { a, b, c }) })
	end)
	local area = UI.row(body, "")
	for i = 1, mode do
		UI.color(area, cols[i], function(c)
			local t = { cols[1], cols[2], cols[3], mid = cols.mid }
			t[i] = c
			self:set(element, { color = mode == 1 and c or (mode == 2 and { t[1], t[2] } or t) })
		end, { tip = mode == 1 and "Culoarea" or CURVE_TIPS[mode == 2 and (i == 1 and 1 or 3) or i] })
	end
end

function Panel:textureRows(body, data, element)
	local items = groupedItems(self.Editor.TEXTURES, function(t)
		return t.group or "Altele"
	end, function(t)
		return { value = t.key, label = t.label }
	end)
	table.insert(items, { header = true, label = "Proprii" })
	table.insert(items, { value = "CUSTOM", label = "ID propriu…" })
	UI.dropdown(UI.row(body, "Textură"), items, data.texture, function(v)
		if v == "CUSTOM" then
			self.customTexture = true
			self:refresh()
		else
			self.customTexture = false
			self:set(element, { texture = v })
		end
	end, { menuWidth = 220 })
	if data.texture == "CUSTOM" or self.customTexture then
		UI.textbox(UI.row(body, "ID textură"), data.textureId, function(text)
			local id = text:match("^%d+$") and ("rbxassetid://" .. text) or text
			self:set(element, { texture = id })
		end, { placeholder = "rbxassetid://123456" })
	end
end

function Panel:renderElement(parent, element)
	local Editor = self.Editor
	local data = Editor.read(element)
	local kind = data.kind
	local body = UI.section(parent, element.Name, { key = "vfx.element", badge = KIND_LABEL[kind], right = function(r)
		UI.iconButton(r, "locate", function()
			Selection:Set({ element })
		end, { tip = "Selectează în Explorer" })
	end, rightWidth = 28 })
	UI.textbox(UI.row(body, "Nume"), element.Name, function(text)
		if trim(text) ~= "" then
			self:set(element, { name = trim(text) })
		end
	end)
	local ofKind = {}
	for _, p in Editor.PRESETS do
		if p.kind == kind then
			table.insert(ofKind, p)
		end
	end
	local presetItems = groupedItems(ofKind, function(p)
		return p.group or KIND_LABEL[p.kind]
	end, function(p)
		return { value = p.key, label = p.label }
	end)
	UI.dropdown(UI.row(body, "Preset"), presetItems, data.preset, function(v)
		self:try(Editor.applyPreset, element, v)
	end, { placeholder = "Alege un preset", menuWidth = 220, tip = "Înlocuiește proprietățile cu cele ale presetului" })
	if kind ~= "BEAM" then
		self:vector(body, "Poziție", data.position, element, "position", { step = 0.25, decimals = 2,
			tip = "Față de centrul efectului, în studs" })
	end

	if kind == "PARTICLES" then
		self:renderParticles(parent, element, data)
	elseif kind == "MESH" then
		self:renderMesh(parent, element, data)
	elseif kind == "LIGHT" then
		self:renderLight(parent, element, data)
	elseif kind == "TRAIL" then
		self:renderTrail(parent, element, data)
	elseif kind == "SOUND" then
		self:renderSound(parent, element, data)
	elseif kind == "CAMERA" then
		self:renderCamera(parent, element, data)
	elseif kind == "BEAM" then
		self:renderBeam(parent, element, data)
	end
	if TIMING[kind] then
		self:renderTiming(parent, element, data)
	end
end

function Panel:renderParticles(parent, element, data)
	local body = UI.section(parent, "Aspect", { key = "vfx.look" })
	self:textureRows(body, data, element)
	self:colorRows(body, data, element)
	self:curve(body, "Mărime", data.size, element, "size", { min = 0, step = 0.1, decimals = 2 })
	self:curve(body, "Transparență", data.transparency, element, "transparency", { min = 0, max = 1, step = 0.05, decimals = 2 })
	UI.slider(UI.row(body, "Mijloc la"), data.size.mid or 0.5, function(v)
		local s, tr = data.size, data.transparency
		self:set(element, { size = { s[1], s[2], s[3], mid = v }, transparency = { tr[1], tr[2], tr[3], mid = v } })
	end, { min = 0.01, max = 0.99, step = 0.01, decimals = 2, field = true,
		tip = "Când ajunge particula la valorile din mijloc (0–1 din viața ei)" })
	self:slider(body, "Strălucire", data.LightEmission, element, "LightEmission", { min = 0, max = 1, step = 0.05, decimals = 2,
		tip = "LightEmission: cât se adună cu ce e în spate (1 = strălucește)" })
	self:slider(body, "Influență lumină", data.LightInfluence, element, "LightInfluence", { min = 0, max = 1, step = 0.05,
		decimals = 2, tip = "LightInfluence: cât o întunecă lumina scenei" })
	self:scrub(body, "Luminozitate", data.Brightness, element, "Brightness", { min = 0, step = 0.25, decimals = 2 })
	self:slider(body, "Squash", data.squash, element, "squash", { min = -3, max = 3, step = 0.25, decimals = 2,
		tip = "Turtește (-) sau alungește (+) particula" })
	UI.dropdown(UI.row(body, "Orientare"), ORIENT, data.Orientation, function(v)
		self:set(element, { Orientation = v })
	end, { menuWidth = 200 })
	self:scrub(body, "ZOffset", data.ZOffset, element, "ZOffset", { step = 0.25, decimals = 2, unit = "studs",
		tip = "O aduce în fața (+) sau în spatele (-) celorlalte" })

	body = UI.section(parent, "Mișcare", { key = "vfx.motion" })
	self:range(body, "Viață", data.lifetime, element, "lifetime", { min = 0, step = 0.05, decimals = 2, unit = "s" })
	self:range(body, "Viteză", data.speed, element, "speed", { step = 0.5, decimals = 2, tip = "Studs pe secundă" })
	self:scrub(body, "Rată", data.Rate, element, "Rate", { min = 0, step = 5, decimals = 1, unit = "/s",
		tip = "Particule pe secundă, în timpul emisiei continue" })
	self:parts(body, "Spread", data.spread, { "X", "Y" }, function(t)
		self:set(element, { spread = { t[1], t[2] } })
	end, { min = 0, max = 180, step = 5, decimals = 0, unit = "°" })
	self:vector(body, "Accelerație", data.acceleration, element, "acceleration", { step = 1, decimals = 2 })
	self:scrub(body, "Drag", data.Drag, element, "Drag", { min = 0, step = 0.5, decimals = 2, tip = "Cât de repede încetinește" })
	self:range(body, "Rotație", data.rotation, element, "rotation", { step = 15, decimals = 0, unit = "°" })
	self:range(body, "Rotire", data.rotSpeed, element, "rotSpeed", { step = 15, decimals = 0, tip = "Grade pe secundă" })
	UI.toggle(body, data.LockedToPart, function(v)
		self:set(element, { LockedToPart = v })
	end, "Lipit de efect", { tip = "LockedToPart: particulele se mișcă odată cu efectul" })

	body = UI.section(parent, "Formă", { key = "vfx.shape", collapsed = true })
	UI.dropdown(UI.row(body, "Formă"), SHAPES, data.shape, function(v)
		self:set(element, { shape = v })
	end)
	if data.shape ~= "Point" and data.partSize then
		self:vector(body, "Mărime formă", data.partSize, element, "partSize", { min = 0.05, step = 0.25, decimals = 2 })
		UI.segmented(UI.row(body, "Din"), { { value = "Volume", label = "Volum" }, { value = "Surface", label = "Suprafață" } },
			data.ShapeStyle, function(v)
				self:set(element, { ShapeStyle = v })
			end)
		UI.segmented(UI.row(body, "Sens"), { { value = "Outward", label = "Afară" }, { value = "Inward", label = "Înăuntru" },
			{ value = "InAndOut", label = "Ambele" } }, data.ShapeInOut, function(v)
			self:set(element, { ShapeInOut = v })
		end)
	end
	UI.dropdown(UI.row(body, "Direcție"), DIRECTIONS, data.EmissionDirection, function(v)
		self:set(element, { EmissionDirection = v })
	end)
	if data.FlipbookLayout then
		self:renderFlipbook(parent, element, data)
	end
end

-- flipbooks: a texture made of a grid of frames, played as an animation on each particle
function Panel:renderFlipbook(parent, element, data)
	local body = UI.section(parent, "Flipbook", { key = "vfx.flipbook", collapsed = data.FlipbookLayout == "None" })
	local layouts = FLIPBOOK_LAYOUTS
	if data.FlipbookLayout == "Custom" then -- set outside LostCube (e.g. an imported emitter): shown, kept
		layouts = table.clone(FLIPBOOK_LAYOUTS)
		table.insert(layouts, { value = "Custom", label = "Personalizată", hint = "import" })
	end
	UI.dropdown(UI.row(body, "Cadre"), layouts, data.FlipbookLayout, function(v)
		self:set(element, { FlipbookLayout = v })
	end, { menuWidth = 200, tip = "Textura trebuie să fie o grilă de cadre (2 × 2, 4 × 4 sau 8 × 8), ca o foaie de sprite-uri" })
	if data.FlipbookLayout ~= "None" then
		UI.dropdown(UI.row(body, "Redare"), FLIPBOOK_MODES, data.FlipbookMode, function(v)
			self:set(element, { FlipbookMode = v })
		end, { menuWidth = 210 })
		if data.FlipbookMode ~= "OneShot" then
			self:range(body, "Cadre pe secundă", data.FlipbookFramerate, element, "FlipbookFramerate",
				{ min = 0, step = 1, decimals = 1 })
		end
		UI.toggle(body, data.FlipbookStartRandom, function(v)
			self:set(element, { FlipbookStartRandom = v })
		end, "Primul cadru aleator", { tip = "Fiecare particulă începe de la alt cadru" })
	end
end

function Panel:renderLight(parent, element, data)
	local body = UI.section(parent, "Lumină", { key = "vfx.light" })
	UI.color(UI.row(body, "Culoare"), data.Color, function(c)
		self:set(element, { Color = c })
	end)
	self:scrub(body, "Luminozitate", data.Brightness, element, "Brightness", { min = 0, step = 0.5, decimals = 2 })
	self:slider(body, "Rază", data.Range, element, "Range", { min = 0, max = 60, step = 1, decimals = 1, unit = "studs" })
	UI.toggle(body, data.Shadows, function(v)
		self:set(element, { Shadows = v })
	end, "Umbre")

	-- the keys: brightness and range over time (linear between keys)
	local keys = data.keys
	body = UI.section(parent, "Cronologie", { key = "vfx.timeline", badge = #keys > 0 and #keys or nil, right = function(r)
		UI.iconButton(r, "plus", function()
			local copy = table.clone(keys)
			local last = keys[#keys]
			table.insert(copy, { last and last[1] + 0.1 or 0, data.Brightness, data.Range })
			self:set(element, { keys = copy })
		end, { tip = "Adaugă cheie" })
	end, rightWidth = 28 })
	if #keys == 0 then
		UI.label(body, "Fără chei, lumina stă aprinsă constant.", { dim = true })
		return
	end
	local head = UI.make("Frame", { Name = "Columns", Parent = body, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16) },
		{ UI.hlist(UI.SPACE.xs, false) })
	for _, text in { "Timp", "Luminozitate", "Rază" } do
		UI.label(head, text, { role = "meta", dim = true, height = 16 }).Size = fieldWidth(3, 16)
	end
	for i, k in keys do
		local row = UI.make("Frame", { Name = "Key", Parent = body, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H) },
			{ UI.hlist(UI.SPACE.xs, false) })
		for j = 1, 3 do
			local field = UI.number(row, k[j], function(v)
				local copy = table.clone(keys)
				copy[i] = table.clone(k)
				copy[i][j] = v
				self:set(element, { keys = copy })
			end, { min = 0, step = j == 1 and 0.05 or 0.5, decimals = 2, unit = j == 1 and "s" or nil,
				tip = ({ "Momentul cheii", "Luminozitatea", "Raza, în studs" })[j] })
			field.Size = fieldWidth(3)
		end
		rigid(UI.iconButton(row, "trash", function()
			local copy = table.clone(keys)
			table.remove(copy, i)
			self:set(element, { keys = copy })
		end, { tip = "Șterge cheia", danger = true }))
	end
end

function Panel:renderTrail(parent, element, data)
	local body = UI.section(parent, "Aspect", { key = "vfx.trail" })
	self:textureRows(body, data, element)
	self:colorRows(body, data, element)
	self:span(body, "Transparență", { data.transparency[1], data.transparency[3] }, function(t)
		self:set(element, { transparency = { t[1], t[2] } })
	end, { min = 0, max = 1, step = 0.05, decimals = 2, tips = { "La cap", "La coadă" } })
	self:slider(body, "Strălucire", data.LightEmission, element, "LightEmission", { min = 0, max = 1, step = 0.05, decimals = 2 })

	body = UI.section(parent, "Formă", { key = "vfx.trailShape" })
	self:scrub(body, "Viață", data.lifetime, element, "lifetime", { min = 0.01, step = 0.05, decimals = 2, unit = "s",
		tip = "Cât rămâne un punct al urmei" })
	self:scrub(body, data.ground and "Lățime" or "Înălțime", data.height, element, "height", { min = 0.05, step = 0.25, decimals = 2,
		unit = "studs" })
	self:slider(body, "Lățime la cap", data.widthHead, element, "widthHead", { min = 0, max = 1, step = 0.05, decimals = 2 })
	self:slider(body, "Lățime la coadă", data.widthEnd, element, "widthEnd", { min = 0, max = 1, step = 0.05, decimals = 2 })
	UI.toggle(body, data.ground, function(v)
		self:set(element, { ground = v })
	end, "Pe sol", { tip = "Urmă plată pe sol, care urmează piciorul" })
	if data.ground then
		self:slider(body, "Curgere", data.flow, element, "flow", { min = 0, max = 6, step = 0.1, decimals = 2, unit = "/s",
			tip = "O bandă luminoasă care curge pe urmă (cicluri pe secundă)" })
		self:scrub(body, "Ridicare", data.lift, element, "lift", { min = 0, max = 0.3, step = 0.005, decimals = 3, unit = "studs",
			tip = "Deasupra solului: urme suprapuse fără pâlpâire" })
	end
end

function Panel:renderSound(parent, element, data)
	local Editor = self.Editor
	local body = UI.section(parent, "Sunet", { key = "vfx.sound" })
	local items = { { header = true, label = "Din Roblox, fără upload" } }
	for _, snd in Editor.SOUNDS or {} do
		table.insert(items, { value = snd.key, label = snd.label })
	end
	table.insert(items, { header = true, label = "Proprii" })
	table.insert(items, { value = "CUSTOM", label = "ID propriu…" })
	local row = UI.row(body, "Sunet")
	UI.dropdown(row, items, data.sound, function(v)
		if v == "CUSTOM" then -- shows the id box (like "ID propriu…" for textures)
			self.customSound = true
			self:refresh()
		else
			self.customSound = false
			self:set(element, { soundId = v })
		end
	end, { menuWidth = 230 })
	rigid(UI.iconButton(row, "play", function()
		local ok, err = pcall(function()
			game:GetService("SoundService"):PlayLocalSound(element)
		end)
		if not ok then
			self:fail(err)
		end
	end, { tip = "Ascultă o dată, fără efect" }))
	if data.sound == "CUSTOM" or self.customSound then
		UI.textbox(UI.row(body, "ID sunet"), data.soundId, function(text)
			local id = assetIdOf(text)
			self:set(element, { soundId = id and ("rbxassetid://" .. id) or trim(text) })
		end, { placeholder = "rbxassetid://123456 din Creator Store, Audio" })
	end
	self:slider(body, "Volum", data.Volume, element, "Volume", { min = 0, max = 10, step = 0.1, decimals = 2 })
	self:range(body, "Ton", data.pitch, element, "pitch", { min = 0.05, max = 4, step = 0.05, decimals = 2,
		tip = "Viteza de redare, aleasă la întâmplare la fiecare redare (1 = normal)" })
	self:scrub(body, "Se aude până la", data.RollOffMaxDistance, element, "RollOffMaxDistance", { min = 1, step = 10, decimals = 0,
		unit = "studs", tip = "RollOffMaxDistance: mai departe nu se mai aude" })
	if data.window then
		self:scrub(body, "Stingere", data.fade, element, "fade", { min = 0, step = 0.05, decimals = 2, unit = "s",
			tip = "Cât durează să se stingă bucla" })
	end
	if (data.length or 0) > 0 then
		UI.label(UI.row(body, "Lungime"), seconds(data.length), { dim = true })
	end
end

function Panel:renderCamera(parent, element, data)
	local body = UI.section(parent, "Cameră", { key = "vfx.camera" })
	self:slider(body, "Tremur", data.shake, element, "shake", { min = 0, max = 10, step = 0.1, decimals = 2, unit = "°",
		tip = "Cât de tare se scutură camera (0 = deloc)" })
	if data.shake > 0 then
		self:scrub(body, "Frecvență", data.frequency, element, "frequency", { min = 1, max = 40, step = 1, decimals = 0, unit = "Hz" })
		self:scrub(body, "Durată tremur", data.shakeTime, element, "shakeTime", { min = 0.02, step = 0.05, decimals = 2, unit = "s",
			tip = "La fiecare lovitură; scade spre 0 în timpul ăsta" })
	end
	self:slider(body, "Zoom FOV", data.fov, element, "fov", { min = -40, max = 40, step = 1, decimals = 1, unit = "°",
		tip = "Pozitiv: zoom-out, ca la impact; negativ: zoom-in; 0: fără" })
	if data.fov ~= 0 then
		self:scrub(body, "Durată zoom", data.fovTime, element, "fovTime", { min = 0.02, step = 0.05, decimals = 2, unit = "s" })
	end
	UI.toggle(body, data.flash ~= nil, function(v)
		self:set(element, { flash = v and Color3.new(1, 1, 1) or false })
	end, "Flash pe ecran")
	if data.flash then
		UI.color(UI.row(body, "Culoare flash"), data.flash, function(c)
			self:set(element, { flash = c })
		end)
		self:slider(body, "Intensitate", data.flashAlpha, element, "flashAlpha", { min = 0.05, max = 1, step = 0.05, decimals = 2 })
		self:scrub(body, "Durată flash", data.flashTime, element, "flashTime", { min = 0.02, step = 0.05, decimals = 2, unit = "s" })
	end
	self:scrub(body, "Rază", data.radius, element, "radius", { min = 1, step = 5, decimals = 0, unit = "studs",
		tip = "Mai departe de atât camera nu simte nimic; întreg în primele 30%" })
	UI.toggle(body, data.studio, function(v)
		self:set(element, { studio = v })
	end, "Și în Studio", { tip = "Aplică și în previzualizarea din Studio. În joc: doar pe client, pe camera jucătorilor din apropiere" })
end

function Panel:renderBeam(parent, element, data)
	local body = UI.section(parent, "Formă", { key = "vfx.beam" })
	self:vector(body, "Început", data.start, element, "start", { step = 0.25, decimals = 2 })
	self:vector(body, "Sfârșit", data.finish, element, "finish", { step = 0.25, decimals = 2 })
	self:span(body, "Lățime", data.width, function(t)
		self:set(element, { width = { t[1], t[2] } })
	end, { min = 0, step = 0.1, decimals = 2, tips = { "La început", "La sfârșit" } })
	self:span(body, "Curbură", data.curve, function(t)
		self:set(element, { curve = { t[1], t[2] } })
	end, { step = 0.5, decimals = 2, tips = { "Îndoaie raza lângă început (CurveSize0)", "Îndoaie raza lângă sfârșit (CurveSize1)" } })
	self:scrub(body, "Segmente", data.Segments, element, "Segments", { min = 1, max = 100, step = 1, decimals = 0 })

	body = UI.section(parent, "Aspect", { key = "vfx.beamLook" })
	self:textureRows(body, data, element)
	if data.texture ~= "NONE" then
		UI.segmented(UI.row(body, "Mod textură"), TEXTURE_MODES, data.TextureMode, function(v)
			self:set(element, { TextureMode = v })
		end)
		self:scrub(body, "Lungime textură", data.TextureLength, element, "TextureLength", { min = 0.01, step = 0.5, decimals = 2 })
		self:scrub(body, "Curgere", data.TextureSpeed, element, "TextureSpeed", { step = 0.5, decimals = 2,
			tip = "Cât de repede curge textura de-a lungul razei" })
	end
	self:colorRows(body, data, element)
	self:span(body, "Transparență", { data.transparency[1], data.transparency[3] }, function(t)
		self:set(element, { transparency = { t[1], t[2] } })
	end, { min = 0, max = 1, step = 0.05, decimals = 2, tips = { "La început", "La sfârșit" } })
	self:slider(body, "Strălucire", data.LightEmission, element, "LightEmission", { min = 0, max = 1, step = 0.05, decimals = 2 })
	self:scrub(body, "Luminozitate", data.Brightness, element, "Brightness", { min = 0, step = 0.25, decimals = 2 })
	UI.toggle(body, data.FaceCamera, function(v)
		self:set(element, { FaceCamera = v })
	end, "Spre cameră", { tip = "Raza e întoarsă mereu spre cameră" })

	body = UI.section(parent, "Apariție", { key = "vfx.beamTiming" })
	self:scrub(body, "Flash", data.flashTime, element, "flashTime", { min = 0.02, step = 0.02, decimals = 2, unit = "s",
		tip = "Cât stă aprinsă la fiecare flash din cronologie" })
	self:scrub(body, "Apare și dispare", data.fade, element, "fade", { min = 0, step = 0.02, decimals = 2, unit = "s" })
	self:scrub(body, "Variație", data.jitter, element, "jitter", { min = 0, step = 0.25, decimals = 2, unit = "studs",
		tip = "Capătul și curbura se mută la întâmplare la fiecare flash, ca la fulger" })
end

function Panel:renderMesh(parent, element, data)
	local body = UI.section(parent, "Formă", { key = "vfx.mesh" })
	UI.dropdown(UI.row(body, "Mod"), MESH_MODES, data.mode, function(v)
		self:set(element, { mode = v })
	end, { menuWidth = 200, tip = "Piesele sunt 3D reale (Part): lumină, umbră și perspectivă adevărate" })
	UI.dropdown(UI.row(body, "Piesă"), PART_SHAPES, data.shape, function(v)
		self:set(element, { shape = v })
	end)
	UI.dropdown(UI.row(body, "Material"), MATERIALS, data.material, function(v)
		self:set(element, { material = v })
	end, { menuWidth = 160 })
	if data.mode == "Ring" or data.mode == "Crack" then
		self:scrub(body, "Segmente", data.count, element, "count", { min = 1, max = 64, step = 1, decimals = 0 })
		if data.mode == "Ring" then
			self:span(body, "Rază", data.radius, function(t)
				self:set(element, { radius = { t[1], t[2] } })
			end, { min = 0, step = 0.5, decimals = 2, unit = "studs" })
		else
			self:range(body, "Lungime", data.radius, element, "radius", { min = 0, step = 0.5, decimals = 2 })
		end
	end
	UI.toggle(body, data.ground, function(v)
		self:set(element, { ground = v })
	end, "Pe sol", { tip = "Găsește podeaua de sub efect și stă pe ea" })

	body = UI.section(parent, "Aspect", { key = "vfx.meshLook" })
	local colors = UI.row(body, "Culori")
	UI.color(colors, data.color, function(c)
		self:set(element, { color = c })
	end, { tip = "La început" })
	UI.color(colors, data.colorEnd or data.color, function(c)
		self:set(element, { colorEnd = c })
	end, { tip = "La final" })
	self:vector(body, "Mărime", data.size, element, "size", { min = 0.02, step = 0.1, decimals = 2 })
	self:span(body, "Creștere", data.grow, function(t)
		self:set(element, { grow = { t[1], t[2] } })
	end, { min = 0, step = 0.1, decimals = 2, tip = "De câte ori crește piesa în viața ei" })
	self:span(body, "Transparență", data.transparency, function(t)
		self:set(element, { transparency = { t[1], t[2] } })
	end, { min = 0, max = 1, step = 0.05, decimals = 2 })
	self:slider(body, "Variație", data.jitter, element, "jitter", { min = 0, max = 1, step = 0.05, decimals = 2,
		tip = "Cât diferă mărimea de la o piesă la alta" })

	body = UI.section(parent, "Mișcare", { key = "vfx.meshMotion" })
	self:range(body, "Viață", data.lifetime, element, "lifetime", { min = 0.02, step = 0.05, decimals = 2, unit = "s" })
	self:scrub(body, "Rată", data.Rate, element, "rate", { min = 0, step = 5, decimals = 1, unit = "/s",
		tip = "Piese pe secundă, în timpul emisiei continue" })
	if data.mode == "Puff" or data.mode == "Debris" then
		self:range(body, "Viteză", data.speed, element, "speed", { min = 0, step = 1, decimals = 1 })
		self:parts(body, "Spread", data.spread, { "X", "Y" }, function(t)
			self:set(element, { spread = { t[1], t[2] } })
		end, { min = 0, max = 180, step = 5, decimals = 0, unit = "°" })
		UI.dropdown(UI.row(body, "Direcție"), DIRECTIONS, data.direction, function(v)
			self:set(element, { direction = v })
		end)
	end
	if data.mode == "Puff" then
		self:scrub(body, "Urcare", data.rise, element, "rise", { step = 0.25, decimals = 2, unit = "studs" })
	end
	if data.mode == "Debris" then
		self:scrub(body, "Rotire", data.spin, element, "spin", { min = 0, step = 2, decimals = 0 })
	end
end

-- the timing of an element: a continuous window (switch + from / to) and the list of moments (bursts, plays, kicks, flashes)
function Panel:renderTiming(parent, element, data)
	local text = TIMING[data.kind]
	local bursts = data.bursts
	local counted = text[5] ~= nil
	local body = UI.section(parent, "Cronologie", { key = "vfx.timeline", badge = bursts and #bursts > 0 and #bursts or nil,
		right = text[3] and bursts and function(r)
			UI.iconButton(r, "plus", function()
				local copy = table.clone(bursts)
				local last = bursts[#bursts]
				table.insert(copy, { last and last[1] + 0.1 or 0, last and last[2] or ((counted and data.kind ~= "SOUND") and 20 or 1) })
				self:set(element, { bursts = copy })
			end, { tip = text[4] })
		end or nil, rightWidth = 28 })
	local w = data.window
	local duration = self.effect and self.effect:GetAttribute("LC_Duration") or 1
	UI.toggle(body, w ~= nil, function(on)
		self:set(element, { window = on and { 0, math.max(0.05, duration) } or false })
	end, text[1], { tip = text[2] })
	if w then
		self:span(body, "Interval", { w[1], w[2] }, function(t)
			self:set(element, { window = { t[1], math.max(t[1] + 0.01, t[2]) } })
		end, { min = 0, step = 0.05, decimals = 2, unit = "s" })
	end
	if not text[3] or not bursts then
		return
	end
	for i, b in bursts do
		local row = UI.row(body, text[3] .. " " .. i)
		local columns = counted and 2 or 1
		UI.number(row, b[1], function(v)
			local copy = table.clone(bursts)
			copy[i] = { v, b[2] }
			self:set(element, { bursts = copy })
		end, { min = 0, step = 0.05, decimals = 2, unit = "s", tip = "Momentul" }).Size = fieldWidth(columns)
		if counted then
			UI.number(row, b[2], function(v)
				local copy = table.clone(bursts)
				copy[i] = { b[1], math.max(1, math.floor(v)) }
				self:set(element, { bursts = copy })
			end, { min = 1, step = 1, decimals = 0, tip = text[5] }).Size = fieldWidth(columns)
		end
		rigid(UI.iconButton(row, "trash", function()
			local copy = table.clone(bursts)
			table.remove(copy, i)
			self:set(element, { bursts = copy })
		end, { tip = "Șterge", danger = true }))
	end
end

return Panel
