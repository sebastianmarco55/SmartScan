-- LostCube > VFX tab: effects list, elements with presets, properties, timeline, live preview.
local Selection = game:GetService("Selection")

local UI = require(script.Parent.UI)
local C = UI.C

local Panel = {}
Panel.__index = Panel

local ORIENT = {
	{ value = "FacingCamera", label = "Spre cameră" },
	{ value = "FacingCameraWorldUp", label = "Spre cameră (vertical)" },
	{ value = "VelocityParallel", label = "Pe direcția mișcării (raze)" },
	{ value = "VelocityPerpendicular", label = "Culcat (cercuri pe sol)" },
}
local SHAPES = {
	{ value = "Point", label = "Punct" }, { value = "Box", label = "Cutie" }, { value = "Sphere", label = "Sferă" },
	{ value = "Cylinder", label = "Cilindru" }, { value = "Disc", label = "Disc" },
}
local DIRECTIONS = {
	{ value = "Top", label = "Sus" }, { value = "Bottom", label = "Jos" }, { value = "Front", label = "Față" },
	{ value = "Back", label = "Spate" }, { value = "Left", label = "Stânga" }, { value = "Right", label = "Dreapta" },
}
local KIND_ICON = { PARTICLES = "★", LIGHT = "☀", TRAIL = "≈", MESH = "■" }
local KIND_LABEL = { PARTICLES = "Particule", LIGHT = "Lumină", TRAIL = "Trail", MESH = "Mesh 3D" }
local MESH_MODES = {
	{ value = "Ring", label = "Inel (se lărgește)" }, { value = "Crack", label = "Crăpături (radial)" },
	{ value = "Pulse", label = "Puls (crește și dispare)" }, { value = "Puff", label = "Fum 3D (bile)" },
	{ value = "Trail", label = "Urmă pe sol (rămâne)" }, { value = "Debris", label = "Debris (fizică reală)" },
}
local PART_SHAPES = { { value = "Block", label = "Cub" }, { value = "Ball", label = "Bilă" },
	{ value = "Cylinder", label = "Cilindru" }, { value = "Wedge", label = "Pană" } }
local MATERIALS = {}
for _, m in { "Neon", "ForceField", "SmoothPlastic", "Glass", "Ice", "Slate", "Rock", "Concrete", "Plastic", "Sand" } do
	table.insert(MATERIALS, { value = m, label = m })
end

function Panel.new(ctx)
	return setmetatable({ ctx = ctx, Editor = ctx.Editor, effect = nil, element = nil, speed = 1, loop = false,
		confirm = nil, creating = false, handle = nil }, Panel)
end

function Panel:refresh()
	self.ctx.app:refresh()
end

-- every edit goes through the Editor (one undo step each); errors show up in the panel instead of breaking it
function Panel:try(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		self.error = tostring(err):gsub("^.-:%d+: ", "")
		warn("LostCube:", err)
	else
		self.error = nil
	end
	self:refresh()
end

function Panel:set(element, props)
	self:try(self.Editor.setProps, element, props)
end

-- ---------------------------------------------------------------------------------------------
-- preview
-- ---------------------------------------------------------------------------------------------
function Panel:play()
	if not self.effect then
		return
	end
	if self.handle and not self.handle.Done then
		self.handle:Destroy()
	end
	local ok, h = pcall(self.Editor.preview, self.effect, { speed = self.speed })
	if ok then
		self.handle = h
	else
		self.error = tostring(h)
		self:refresh()
	end
end

function Panel:setLoop(on)
	self.loop = on
	self.loopId = (self.loopId or 0) + 1
	if on then
		local id = self.loopId
		task.spawn(function()
			while self.loop and self.loopId == id and self.effect and self.effect.Parent do
				self:play()
				local ok, length = pcall(self.Editor.length, self.effect)
				task.wait(((ok and length or 1) + 0.35) / self.speed)
			end
		end)
	end
	self:refresh()
end

function Panel:togglePause()
	local h = self.handle
	if not h or h.Done then
		return
	end
	if self.paused then
		h:Resume()
		self.paused = false
	else
		h:Pause()
		self.paused = true
	end
	self:refresh()
end

function Panel:destroy()
	self.loop = false
	if self.handle and not self.handle.Done then
		self.handle:Destroy()
	end
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
	if self.error then
		UI.note(parent, "⚠ " .. self.error, C.warn)
		self.error = nil -- shown once; the next action sets it again if it still fails
	end
	local status = require(script.Parent.Installer).status()
	if not status.ok then
		local banner = UI.vstack(parent, 6)
		UI.note(banner, status.vfx and "Modulele LostCube din joc sunt mai vechi decât pluginul."
			or "Jocul nu are încă modulele LostCube (<b>VFX</b> redă efectele în joc, <b>Editor</b> e pentru Claude).", C.warn)
		UI.button(UI.hstack(banner, { height = 28 }), "Instalează în joc (ReplicatedStorage.LostCube)", function()
			self:try(require(script.Parent.Installer).install)
		end, { style = "primary", bold = true, height = 28 })
	end

	-- effects ---------------------------------------------------------------------------------
	local effects = Editor.effects()
	local body = UI.section(parent, "Efecte  (" .. #effects .. ")", { key = "vfx.effects" })
	local bar = UI.hstack(body)
	UI.button(bar, "+ Efect nou", function()
		self.creating = true
		self:refresh()
	end, { style = "primary", bold = true })
	if self.creating then
		local row = UI.hstack(body)
		local box = UI.textbox(row, "", nil, { placeholder = "Numele efectului (ex. Foc)" })
		UI.button(row, "Creează", function()
			local name = box.Text ~= "" and box.Text or "Efect"
			self.creating = false
			local ok, fx = pcall(Editor.newEffect, name, { duration = 1 })
			if ok then
				self.effect, self.element = fx, nil
			else
				self.error = tostring(fx)
			end
			self:refresh()
		end, { width = 74, style = "primary" })
		UI.button(row, "×", function()
			self.creating = false
			self:refresh()
		end, { width = 26, style = "ghost" })
		task.defer(function()
			if box.Parent then
				box:CaptureFocus()
			end
		end)
	end
	if #effects == 0 then
		UI.note(body, "Niciun efect încă. Apasă <b>+ Efect nou</b>, apoi adaugă elemente din preseturi.")
	end
	local list = #effects > 0 and UI.scrollList(body, 236) or body
	for _, fx in effects do
		local n = #Editor.elements(fx)
		local confirm = self.confirm == fx
		UI.item(list, fx.Name, {
			icon = "◆", selected = fx == self.effect, note = n .. " el.",
			onClick = function()
				self.effect = fx
				self.element = nil
				self.confirm = nil
				self:refresh()
			end,
			actions = {
				{ text = "📋", onClick = function()
					self:try(function()
						self.effect = Editor.duplicateEffect(fx)
					end)
				end },
				{ text = confirm and "✓?" or "×", color = C.danger, onClick = function()
					if confirm then
						self.confirm = nil
						if self.effect == fx then
							self.effect, self.element = nil, nil
						end
						self:try(Editor.removeEffect, fx)
					else
						self.confirm = fx
						self:refresh()
					end
				end },
			},
		})
	end
	if not self.effect then
		return
	end

	-- the effect ------------------------------------------------------------------------------
	local fx = self.effect
	body = UI.section(parent, "Efect: " .. fx.Name, { key = "vfx.effect" })
	UI.textbox(UI.row(body, "Nume"), fx.Name, function(text)
		if text ~= "" then
			self:try(Editor.setEffect, fx, { name = text })
		end
	end)
	UI.number(UI.row(body, "Durată (s)"), fx:GetAttribute("LC_Duration") or 1, function(v)
		self:try(Editor.setEffect, fx, { duration = v })
	end, { min = 0.01, step = 0.05, decimals = 2 })
	local attachItems = {}
	for _, a in Editor.ATTACH do
		table.insert(attachItems, { value = a.key, label = a.label })
	end
	UI.dropdown(UI.row(body, "Prins de"), attachItems, fx:GetAttribute("LC_Attach") or "GROUND", function(v)
		self:try(Editor.setEffect, fx, { attach = v })
	end, { menuWidth = 200 })

	local play = UI.hstack(body, { height = 28 })
	UI.button(play, "▶  Redă", function()
		self.paused = false
		self:play()
	end, { style = "primary", bold = true, height = 28 })
	UI.button(play, self.loop and "🔁 Repetă: DA" or "🔁 Repetă", function()
		self:setLoop(not self.loop)
	end, { selected = self.loop, height = 28 })
	UI.button(play, self.paused and "▶ Continuă" or "⏸ Pauză", function()
		self:togglePause()
	end, { height = 28 })
	UI.segmented(UI.row(body, "Viteză"), {
		{ value = 0.1, label = "×0.1" }, { value = 0.25, label = "×0.25" }, { value = 0.5, label = "×0.5" },
		{ value = 1, label = "×1" },
	}, self.speed, function(v)
		self.speed = v
		self:refresh()
	end)
	local timeRow = UI.row(body, "Întinde timpul")
	for _, k in { 0.8, 1.15, 1.3 } do
		UI.button(timeRow, "×" .. k, function()
			self:try(Editor.retime, fx, k)
		end, { textSize = 12, tip = "durată, emisii, burst-uri, chei și vieți x" .. k })
	end
	UI.label(body, "Se redă pe selecție (personaj / part) sau pe sol, în fața camerei.", { dim = true, size = 11, wrap = true })

	-- elements --------------------------------------------------------------------------------
	local elements = Editor.elements(fx)
	body = UI.section(parent, "Elemente  (" .. #elements .. ")", { key = "vfx.elements" })
	for _, e in elements do
		local muted = e:GetAttribute("LC_Muted") == true
		local kind = Editor.kindOf(e)
		UI.item(body, e.Name, {
			icon = KIND_ICON[kind], selected = e == self.element, muted = muted,
			onClick = function()
				self.element = e
				self:refresh()
			end,
			actions = {
				{ text = muted and "○" or "●", color = muted and C.dim or C.good, onClick = function()
					self:set(e, { muted = not muted })
				end },
				{ text = "📋", onClick = function()
					self:try(function()
						self.element = Editor.duplicate(e)
					end)
				end },
				{ text = "×", color = C.danger, onClick = function()
					if self.element == e then
						self.element = nil
					end
					self:try(Editor.remove, e)
				end },
			},
		})
	end
	local addItems = {}
	local lastKind
	for _, p in Editor.PRESETS do
		if p.kind ~= lastKind then
			table.insert(addItems, { header = true, label = KIND_LABEL[p.kind] })
			lastKind = p.kind
		end
		table.insert(addItems, { value = p.key, label = p.label })
	end
	table.insert(addItems, { header = true, label = "Gol" })
	table.insert(addItems, { value = "PARTICLES", label = "Particule (gol)" })
	table.insert(addItems, { value = "LIGHT", label = "Lumină (goală)" })
	table.insert(addItems, { value = "TRAIL", label = "Trail (gol)" })
	table.insert(addItems, { value = "MESH", label = "Mesh 3D (gol)" })
	UI.dropdown(UI.hstack(body), addItems, nil, function(key)
		self:try(function()
			self.element = Editor.addElement(fx, key)
		end)
	end, { text = "+ Adaugă element", style = "primary", menuWidth = 220 })

	if self.element then
		self:renderElement(parent, self.element)
	end
end

-- ---------------------------------------------------------------------------------------------
-- element properties
-- ---------------------------------------------------------------------------------------------
local function triple(self, body, label, values, element, key, opts)
	local area = UI.row(body, label)
	for i = 1, 3 do
		UI.number(area, values[i], function(v)
			local t = { values[1], values[2], values[3], mid = values.mid }
			t[i] = v
			self:set(element, { [key] = t })
		end, opts)
	end
end

local function pair(self, body, label, values, element, key, opts)
	local area = UI.row(body, label)
	for i = 1, 2 do
		UI.number(area, values[i], function(v)
			local t = { values[1], values[2] }
			t[i] = v
			self:set(element, { [key] = t })
		end, opts)
	end
end

local function vector(self, body, label, v, element, key, opts)
	local area = UI.row(body, label)
	for _, axis in { "X", "Y", "Z" } do
		UI.number(area, v[axis], function(x)
			local cur = (key == "position" and self.Editor.position(element)) or v
			local t = { X = cur.X, Y = cur.Y, Z = cur.Z }
			t[axis] = x
			self:set(element, { [key] = Vector3.new(t.X, t.Y, t.Z) })
		end, opts)
	end
end

local function single(self, body, label, value, element, key, opts)
	UI.number(UI.row(body, label), value, function(v)
		self:set(element, { [key] = v })
	end, opts)
end

function Panel:colorRow(body, data, element)
	local cols = data.color
	local mode = #cols
	UI.segmented(UI.row(body, "Culori"), {
		{ value = 1, label = "Una" }, { value = 2, label = "Două" }, { value = 3, label = "Trei" },
	}, mode, function(m)
		local a, b, c = cols[1], cols[2] or cols[1], cols[3] or cols[2] or cols[1]
		self:set(element, { color = m == 1 and a or (m == 2 and { a, b } or { a, b, c }) })
	end)
	local area = UI.row(body, mode == 1 and "Culoare" or "început → sfârșit")
	for i = 1, mode do
		UI.color(area, cols[i], function(c)
			local t = { cols[1], cols[2], cols[3], mid = cols.mid }
			t[i] = c
			self:set(element, { color = mode == 1 and c or (mode == 2 and { t[1], t[2] } or t) })
		end)
	end
end

function Panel:textureRow(body, data, element)
	local items = {}
	for _, t in self.Editor.TEXTURES do
		table.insert(items, { value = t.key, label = t.label })
	end
	table.insert(items, { value = "CUSTOM", label = "ID propriu…" })
	UI.dropdown(UI.row(body, "Textură"), items, data.texture, function(v)
		if v == "CUSTOM" then
			self.customTexture = true
			self:refresh()
		else
			self.customTexture = false
			self:set(element, { texture = v })
		end
	end, { menuWidth = 200 })
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
	local body = UI.section(parent, KIND_ICON[kind] .. "  " .. element.Name, { key = "vfx.element" })
	UI.textbox(UI.row(body, "Nume"), element.Name, function(text)
		if text ~= "" then
			self:set(element, { name = text })
		end
	end)
	local presetItems = {}
	for _, p in Editor.PRESETS do
		if p.kind == kind then
			table.insert(presetItems, { value = p.key, label = p.label })
		end
	end
	UI.dropdown(UI.row(body, "Preset"), presetItems, data.preset, function(v)
		self:try(Editor.applyPreset, element, v)
	end, { placeholder = "alege…", menuWidth = 210 })
	vector(self, body, "Poziție", data.position, element, "position", { step = 0.25, decimals = 2 })
	UI.button(UI.hstack(body), "Selectează în Explorer", function()
		Selection:Set({ element })
	end, { style = "ghost" })

	if kind == "PARTICLES" then
		body = UI.section(parent, "Aspect", { key = "vfx.look" })
		self:textureRow(body, data, element)
		self:colorRow(body, data, element)
		triple(self, body, "Mărime", data.size, element, "size", { min = 0, step = 0.1, decimals = 2 })
		triple(self, body, "Transparență", data.transparency, element, "transparency", { min = 0, max = 1, step = 0.05, decimals = 2 })
		UI.number(UI.row(body, "Mijloc la (0-1)"), data.size.mid or 0.5, function(v)
			local s, tr = data.size, data.transparency
			self:set(element, { size = { s[1], s[2], s[3], mid = v }, transparency = { tr[1], tr[2], tr[3], mid = v } })
		end, { min = 0.01, max = 0.99, step = 0.05, decimals = 2 })
		single(self, body, "Strălucire", data.LightEmission, element, "LightEmission", { min = 0, max = 1, step = 0.1, decimals = 2 })
		single(self, body, "Influență lumină", data.LightInfluence, element, "LightInfluence", { min = 0, max = 1, step = 0.1, decimals = 2 })
		single(self, body, "Luminozitate", data.Brightness, element, "Brightness", { min = 0, step = 0.25, decimals = 2 })
		single(self, body, "Squash", data.squash, element, "squash", { min = -3, max = 3, step = 0.25, decimals = 2 })
		UI.dropdown(UI.row(body, "Orientare"), ORIENT, data.Orientation, function(v)
			self:set(element, { Orientation = v })
		end, { menuWidth = 220 })
		single(self, body, "ZOffset", data.ZOffset, element, "ZOffset", { step = 0.25, decimals = 2 })

		body = UI.section(parent, "Mișcare", { key = "vfx.motion" })
		pair(self, body, "Viață (s)", data.lifetime, element, "lifetime", { min = 0, step = 0.05, decimals = 2 })
		pair(self, body, "Viteză", data.speed, element, "speed", { step = 0.5, decimals = 2 })
		single(self, body, "Rată / s", data.Rate, element, "Rate", { min = 0, step = 5, decimals = 1 })
		pair(self, body, "Spread X / Y", data.spread, element, "spread", { min = 0, max = 180, step = 5, decimals = 0 })
		vector(self, body, "Accelerație", data.acceleration, element, "acceleration", { step = 1, decimals = 2 })
		single(self, body, "Drag", data.Drag, element, "Drag", { min = 0, step = 0.5, decimals = 2 })
		pair(self, body, "Rotație", data.rotation, element, "rotation", { step = 15, decimals = 0 })
		pair(self, body, "Rotire / s", data.rotSpeed, element, "rotSpeed", { step = 15, decimals = 0 })
		UI.toggle(UI.hstack(body), data.LockedToPart, function(v)
			self:set(element, { LockedToPart = v })
		end, "Lipit de efect (LockedToPart)")

		body = UI.section(parent, "Formă și direcție", { key = "vfx.shape", collapsed = true })
		UI.dropdown(UI.row(body, "Formă"), SHAPES, data.shape, function(v)
			self:set(element, { shape = v })
		end)
		if data.shape ~= "Point" and data.partSize then
			vector(self, body, "Mărime formă", data.partSize, element, "partSize", { min = 0.05, step = 0.25, decimals = 2 })
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
		self:renderTimeline(parent, element, data)
	elseif kind == "MESH" then
		self:renderMesh(parent, element, data)
		self:renderTimeline(parent, element, data)
	elseif kind == "LIGHT" then
		body = UI.section(parent, "Lumină", { key = "vfx.light" })
		UI.color(UI.row(body, "Culoare"), data.Color, function(c)
			self:set(element, { Color = c })
		end)
		single(self, body, "Luminozitate", data.Brightness, element, "Brightness", { min = 0, step = 0.5, decimals = 2 })
		single(self, body, "Rază", data.Range, element, "Range", { min = 0, max = 60, step = 1, decimals = 1 })
		UI.toggle(UI.hstack(body), data.Shadows, function(v)
			self:set(element, { Shadows = v })
		end, "Umbre")
		body = UI.section(parent, "Chei (luminozitate în timp)", { key = "vfx.keys" })
		local keys = data.keys
		if #keys == 0 then
			UI.label(body, "Fără chei: lumina stă constantă.", { dim = true, size = 12 })
		end
		for i, k in keys do
			local area = UI.row(body, "Cheia " .. i, { labelWidth = 52 })
			for j = 1, 3 do
				UI.number(area, k[j], function(v)
					local copy = table.clone(keys)
					copy[i] = table.clone(k)
					copy[i][j] = v
					self:set(element, { keys = copy })
				end, { min = 0, step = j == 1 and 0.05 or 0.5, decimals = 2, tip = ({ "timp (s)", "luminozitate", "rază" })[j] })
			end
			UI.button(area, "×", function()
				local copy = table.clone(keys)
				table.remove(copy, i)
				self:set(element, { keys = copy })
			end, { width = 24, style = "ghost" })
		end
		UI.label(body, "timp (s) · luminozitate · rază", { dim = true, size = 11 })
		UI.button(UI.hstack(body), "+ Cheie", function()
			local copy = table.clone(keys)
			local last = keys[#keys]
			table.insert(copy, { last and last[1] + 0.1 or 0, data.Brightness, data.Range })
			self:set(element, { keys = copy })
		end)
	elseif kind == "TRAIL" then
		body = UI.section(parent, "Trail", { key = "vfx.trail" })
		self:textureRow(body, data, element)
		self:colorRow(body, data, element)
		pair(self, body, "Transparență", { data.transparency[1], data.transparency[3] }, element, "transparency",
			{ min = 0, max = 1, step = 0.05, decimals = 2 })
		single(self, body, "Viață (s)", data.lifetime, element, "lifetime", { min = 0.01, step = 0.05, decimals = 2 })
		single(self, body, data.ground and "Lățime (pe sol)" or "Înălțime", data.height, element, "height",
			{ min = 0.05, step = 0.25, decimals = 2 })
		single(self, body, "Lățime la vârf", data.widthHead, element, "widthHead", { min = 0, max = 1, step = 0.05, decimals = 2 })
		single(self, body, "Lățime la coadă", data.widthEnd, element, "widthEnd", { min = 0, max = 1, step = 0.05, decimals = 2 })
		single(self, body, "Strălucire", data.LightEmission, element, "LightEmission", { min = 0, max = 1, step = 0.1, decimals = 2 })
		UI.toggle(UI.hstack(body), data.ground, function(v)
			self:set(element, { ground = v })
		end, "Urmă plată pe sol (urmează piciorul)")
		if data.ground then
			single(self, body, "Curgere (cicluri/s)", data.flow, element, "flow", { min = 0, max = 6, step = 0.1, decimals = 2 })
			single(self, body, "Ridicare (studs)", data.lift, element, "lift", { min = 0, max = 0.3, step = 0.005, decimals = 3 })
		end
		self:renderTimeline(parent, element, data)
	end
end

function Panel:renderMesh(parent, element, data)
	local body = UI.section(parent, "Mesh 3D", { key = "vfx.mesh" })
	UI.dropdown(UI.row(body, "Mod"), MESH_MODES, data.mode, function(v)
		self:set(element, { mode = v })
	end, { menuWidth = 220 })
	local looks = UI.row(body, "Formă / material")
	UI.dropdown(looks, PART_SHAPES, data.shape, function(v)
		self:set(element, { shape = v })
	end)
	UI.dropdown(looks, MATERIALS, data.material, function(v)
		self:set(element, { material = v })
	end, { menuWidth = 150 })
	local colors = UI.row(body, "Culoare → final")
	UI.color(colors, data.color, function(c)
		self:set(element, { color = c })
	end)
	UI.color(colors, data.colorEnd or data.color, function(c)
		self:set(element, { colorEnd = c })
	end)
	vector(self, body, "Mărime", data.size, element, "size", { min = 0.02, step = 0.1, decimals = 2 })
	pair(self, body, "Creștere", data.grow, element, "grow", { min = 0, step = 0.1, decimals = 2 })
	pair(self, body, "Transparență", data.transparency, element, "transparency", { min = 0, max = 1, step = 0.05, decimals = 2 })
	pair(self, body, "Viață (s)", data.lifetime, element, "lifetime", { min = 0.02, step = 0.05, decimals = 2 })
	single(self, body, "Rată / s", data.Rate, element, "rate", { min = 0, step = 5, decimals = 1 })
	if data.mode == "Ring" or data.mode == "Crack" then
		single(self, body, "Segmente", data.count, element, "count", { min = 1, max = 64, step = 1, decimals = 0 })
		pair(self, body, data.mode == "Ring" and "Rază (început, final)" or "Lungime (min, max)", data.radius, element,
			"radius", { min = 0, step = 0.5, decimals = 2 })
	end
	if data.mode == "Puff" or data.mode == "Debris" then
		pair(self, body, "Viteză", data.speed, element, "speed", { min = 0, step = 1, decimals = 1 })
		pair(self, body, "Spread X / Y", data.spread, element, "spread", { min = 0, max = 180, step = 5, decimals = 0 })
		UI.dropdown(UI.row(body, "Direcție"), DIRECTIONS, data.direction, function(v)
			self:set(element, { direction = v })
		end)
	end
	if data.mode == "Puff" then
		single(self, body, "Urcare (studs)", data.rise, element, "rise", { step = 0.25, decimals = 2 })
	end
	if data.mode == "Debris" then
		single(self, body, "Rotire", data.spin, element, "spin", { min = 0, step = 2, decimals = 0 })
	end
	single(self, body, "Variație mărime", data.jitter, element, "jitter", { min = 0, max = 1, step = 0.05, decimals = 2 })
	UI.toggle(UI.hstack(body), data.ground, function(v)
		self:set(element, { ground = v })
	end, "Lipit de sol (găsește podeaua)")
	UI.label(body, "Piesele sunt 3D reale (Part): lumină, umbră și perspectivă adevărate.", { dim = true, size = 11, wrap = true })
end

function Panel:renderTimeline(parent, element, data)
	local body = UI.section(parent, "Timeline", { key = "vfx.timeline" })
	local w = data.window
	local area = UI.row(body, data.kind == "TRAIL" and "Activ (s)" or "Emisie (s)")
	UI.number(area, w and w[1] or 0, function(v)
		self:set(element, { window = { v, math.max(v + 0.01, w and w[2] or v + 0.3) } })
	end, { min = 0, step = 0.05, decimals = 2, tip = "de la" })
	UI.number(area, w and w[2] or 0, function(v)
		self:set(element, { window = { w and w[1] or 0, v } })
	end, { min = 0, step = 0.05, decimals = 2, tip = "până la" })
	UI.button(area, "×", function()
		self:set(element, { window = false })
	end, { width = 24, style = "ghost" })
	UI.label(body, w and string.format("emite continuu %s → %s s (Rată / s)", UI.fmt(w[1]), UI.fmt(w[2]))
		or "fără emisie continuă (doar burst-uri)", { dim = true, size = 11 })
	if data.kind ~= "PARTICLES" and data.kind ~= "MESH" then
		return
	end
	local bursts = data.bursts
	for i, b in bursts do
		local row = UI.row(body, "Burst " .. i, { labelWidth = 52 })
		UI.number(row, b[1], function(v)
			local copy = table.clone(bursts)
			copy[i] = { v, b[2] }
			self:set(element, { bursts = copy })
		end, { min = 0, step = 0.05, decimals = 2, tip = "timp (s)" })
		UI.number(row, b[2], function(v)
			local copy = table.clone(bursts)
			copy[i] = { b[1], math.max(1, math.floor(v)) }
			self:set(element, { bursts = copy })
		end, { min = 1, step = 1, decimals = 0, tip = "câte particule" })
		UI.button(row, "×", function()
			local copy = table.clone(bursts)
			table.remove(copy, i)
			self:set(element, { bursts = copy })
		end, { width = 24, style = "ghost" })
	end
	if #bursts > 0 then
		UI.label(body, "timp (s) · câte particule", { dim = true, size = 11 })
	end
	UI.button(UI.hstack(body), "+ Burst", function()
		local copy = table.clone(bursts)
		local last = bursts[#bursts]
		table.insert(copy, { last and last[1] + 0.1 or 0, last and last[2] or 20 })
		self:set(element, { bursts = copy })
	end)
end

return Panel
