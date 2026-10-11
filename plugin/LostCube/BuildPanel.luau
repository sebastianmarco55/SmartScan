-- LostCube > Modelare tab: procedural generators with a live ghost preview, and the modeling operations on the
-- selection (fills, arrays, mirror, align, placement, scatter, curves, solids, optimize). Every change goes through the
-- Modeling engine (one undo step each); the preview ghost lives in workspace.CurrentCamera, is not archivable and stays
-- outside the undo history. Forms are drawn from the generator schemas (Modeling.GENERATORS), cached per kind.
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")

local UI = require(script.Parent.UI)
local Modeling = require(script.Parent.Modeling)

local Spec = Modeling.Spec
local Generators = Modeling.Generators
local SPACE = UI.SPACE

local Panel = {}
Panel.__index = Panel

local LABEL_W = 104 -- label column of the forms (a little wider than UI.LABEL_W: Romanian labels are long)
local TILE_H, TILE_MIN, TILE_GAP = 56, 58, 4
local GHOST_NAME = "LostCube previzualizare"
local GHOST_LIMIT = 1500 -- parts drawn in the preview (bigger builds show their bounding box)
local GHOST_DELAY = 0.25 -- seconds after the last change before the preview is rebuilt
local WATCH_EVERY = 0.4 -- seconds between checks that the preview is still wanted (tab, window)

-- ---------------------------------------------------------------------------------------------
-- generators: schemas (cached once), short names, form layout, pictograms
-- ---------------------------------------------------------------------------------------------
local GEN = {} -- key -> generator entry of Modeling.GENERATORS
local FIELDS = {} -- key -> field key -> field
for _, g in Modeling.GENERATORS do
	GEN[g.key] = g
	FIELDS[g.key] = {}
	for _, f in g.params do
		FIELDS[g.key][f.key] = f
	end
end

local SHORT = {
	building = "Clădire", stairs = "Scări", fence = "Gard", bridge = "Pod", tower = "Turn", arch = "Arc",
	colonnade = "Colonadă", wall = "Zid", road = "Drum", tree = "Copac", rock = "Rocă", crystals = "Cristale",
	furniture = "Mobilier", terrain = "Teren",
}

-- the first fields are the form; the groups are folded sections under it. Fields of a schema that are not listed here
-- go to a last "Altele" group, so a new engine parameter always shows up.
local FORM = {
	building = { main = { "width", "depth", "floors", "roof", "windows", "door" }, groups = {
		{ "structure", "Structură", { "floorHeight", "wall", "slab", "slabs" } },
		{ "windows", "Ferestre", { "windowWidth", "windowHeight", "sill", "windowSpacing", "frames" } },
		{ "door", "Ușă", { "doorWidth", "doorHeight" } },
		{ "roof", "Acoperiș", { "roofPitch", "overhang" } },
		{ "look", "Aspect", { "wallColor", "wallMaterial", "roofColor", "roofMaterial", "trimColor", "glassColor", "doorColor",
			"floorColor" } },
	} },
	stairs = { main = { "kind", "height", "width", "railings" }, groups = {
		{ "steps", "Trepte", { "rise", "run", "style", "turn" } },
		{ "spiral", "Spirală", { "radius", "column", "stepsPerTurn" } },
		{ "look", "Aspect", { "color", "material", "railHeight", "railColor" } },
	} },
	fence = { main = { "points", "height", "postSpacing", "style" }, groups = {
		{ "details", "Detalii", { "smooth", "postSize", "rails", "collision" } },
		{ "look", "Aspect", { "color", "material" } },
	} },
	bridge = { main = { "kind", "length", "width", "height", "railings" }, groups = {
		{ "structure", "Structură", { "deck", "pierSpacing", "segments", "towerHeight" } },
		{ "look", "Aspect", { "color", "material", "cableColor" } },
	} },
	tower = { main = { "shape", "radius", "height", "floors", "roof" }, groups = {
		{ "details", "Detalii", { "wall", "segments", "crenellations", "door" } },
		{ "look", "Aspect", { "color", "material", "floorColor", "roofColor" } },
	} },
	arch = { main = { "span", "height", "thickness", "depth" }, groups = {
		{ "details", "Detalii", { "pillarWidth", "segments" } },
		{ "look", "Aspect", { "color", "material" } },
	} },
	colonnade = { main = { "count", "spacing", "height", "diameter", "arches" }, groups = {
		{ "details", "Detalii", { "base", "capital", "entablature" } },
		{ "look", "Aspect", { "color", "material" } },
	} },
	wall = { main = { "length", "height", "thickness", "gateWidth", "gateHeight" }, groups = {
		{ "details", "Detalii", { "crenellations", "towers", "doors" } },
		{ "look", "Aspect", { "color", "material", "doorColor" } },
	} },
	road = { main = { "kind", "length", "width", "sidewalk" }, groups = {
		{ "marks", "Marcaje", { "lines", "dash", "gap", "crosswalks", "curb" } },
		{ "look", "Aspect", { "color", "sidewalkColor" } },
	} },
	tree = { main = { "kind", "height", "trunk", "crown", "seed" }, groups = {
		{ "look", "Aspect", { "leafColor", "trunkColor" } },
	} },
	rock = { main = { "size", "detail", "flatten", "style", "seed" }, groups = {
		{ "look", "Aspect", { "color", "material" } },
	} },
	crystals = { main = { "count", "height", "width", "spread", "base", "seed" }, groups = {
		{ "look", "Aspect", { "color", "material" } },
	} },
	furniture = { main = { "kind", "seats" }, groups = {
		{ "look", "Aspect", { "color", "fabricColor" } },
	} },
	terrain = { main = { "kind", "radius", "lumps", "flatten", "tunnel", "seed", "material" }, groups = {} },
}

-- short labels (the schema's own label is the tooltip); per kind first, then by key
local LABELS = {
	width = "Lățime", depth = "Adâncime", floors = "Etaje", floorHeight = "Înălțime etaj", wall = "Perete", slab = "Planșeu",
	windows = "Ferestre", windowWidth = "Lățime", windowHeight = "Înălțime", sill = "Parapet", windowSpacing = "Distanță",
	frames = "Rame", door = "Ușă", doorWidth = "Lățime", doorHeight = "Înălțime", slabs = "Planșee", roof = "Acoperiș",
	roofPitch = "Pantă", overhang = "Streașină", wallColor = "Pereți", wallMaterial = "Material pereți", trimColor = "Rame",
	glassColor = "Geam", doorColor = "Ușă", floorColor = "Podea", roofColor = "Acoperiș", roofMaterial = "Material acoperiș",
	kind = "Tip", height = "Înălțime", rise = "Treaptă", run = "Adâncime treaptă", style = "Stil", turn = "Întoarcere",
	railings = "Balustradă", railHeight = "Balustradă", radius = "Rază", column = "Coloană", stepsPerTurn = "Trepte pe tură",
	color = "Culoare", material = "Material", railColor = "Culoare bare", points = "Lungime", smooth = "Traseu curb",
	postSpacing = "Între stâlpi", postSize = "Stâlp", rails = "Bare", collision = "Coliziune", length = "Lungime",
	deck = "Tablier", pierSpacing = "Între piloni", segments = "Segmente", towerHeight = "Turnuri", cableColor = "Cabluri",
	shape = "Formă", crenellations = "Creneluri", span = "Deschidere", thickness = "Grosime", pillarWidth = "Lățime stâlp",
	count = "Număr", spacing = "Distanță", diameter = "Diametru", base = "Bază", capital = "Capitel",
	entablature = "Antablament", arches = "Arce", gateWidth = "Lățime poartă", gateHeight = "Înălțime poartă",
	towers = "Turnuri", doors = "Porți", sidewalk = "Trotuar", curb = "Bordură", lines = "Marcaje", dash = "Linie",
	gap = "Pauză", crosswalks = "Treceri", sidewalkColor = "Trotuar", trunk = "Trunchi", crown = "Coroană", seed = "Seed",
	leafColor = "Frunze", trunkColor = "Trunchi", size = "Mărime", detail = "Detaliu", flatten = "Turtire",
	spread = "Înclinare", fabricColor = "Textil", seats = "Scaune", lumps = "Umflături", tunnel = "Tunel",
}
local KIND_LABELS = {
	tower = { floors = "Planșee", wall = "Zid", door = "Intrare", segments = "Laturi" },
	arch = { height = "Stâlpi", segments = "Bolțari" },
	colonnade = { count = "Coloane" },
	road = { width = "Carosabil", color = "Asfalt" },
	crystals = { width = "Grosime", base = "Rocă la bază" },
	furniture = { kind = "Obiect", color = "Lemn" },
	terrain = { flatten = "Înălțime" },
	stairs = { color = "Culoare" },
}

-- option labels of choice fields (the value itself when missing)
local OPTIONS = {
	frames = { none = "Fără", sill = "Pervaz", full = "Ramă" },
	roof = { flat = "Plat", gable = "2 ape", hip = "4 ape", pyramid = "Piramidă" },
	style = { solid = "Pline", floating = "Suspendate", wood = "Lemn", metal = "Metal", picket = "Șipci", hull = "Fațete",
		blocks = "Blocuri" },
	turn = { right = "Dreapta", left = "Stânga" },
	collision = { box = "O cutie", parts = "Piese" },
	shape = { round = "Rotund", square = "Pătrat" },
}
local KIND_OPTIONS = {
	stairs = { straight = "Drepte", L = "În L", spiral = "Spirală" },
	bridge = { beam = "Grindă", arch = "Arc", suspension = "Suspendat" },
	road = { straight = "Drept", cross = "Cruce", T = "În T" },
	tree = { pine = "Brad", round = "Rotund", palm = "Palmier" },
	furniture = { set = "Masă cu scaune", table = "Masă", chair = "Scaun", bed = "Pat", shelf = "Raft", bench = "Bancă",
		crate = "Ladă", barrel = "Butoi", lamp = "Felinar" },
	terrain = { blob = "Movilă", hill = "Deal", cave = "Peșteră", ramp = "Rampă", clear = "Golește" },
}

-- numbers: unit, step, decimals; sliders for bounded values whose position matters, segments for tiny int ranges
local DEGREES = { roofPitch = true, spread = true }
local SLIDERS = { roofPitch = true, spread = true, flatten = true }
local RATIOS = { flatten = true }

local PART_MATERIALS = { "Plastic", "SmoothPlastic", "Wood", "WoodPlanks", "Brick", "Concrete", "Cobblestone", "Slate",
	"Granite", "Marble", "Limestone", "Sandstone", "Basalt", "Rock", "Pavement", "Asphalt", "Plaster", "RoofShingles",
	"ClayRoofTiles", "CeramicTiles", "Metal", "DiamondPlate", "CorrodedMetal", "Foil", "Glass", "Neon", "Ice", "Grass",
	"LeafyGrass", "Sand", "Fabric", "Snow" }
local TERRAIN_MATERIALS = { "Grass", "LeafyGrass", "Ground", "Mud", "Rock", "Slate", "Basalt", "Sandstone", "Limestone",
	"Sand", "Snow", "Ice", "Glacier", "Salt", "Asphalt", "Cobblestone", "Concrete", "Pavement", "Brick", "WoodPlanks",
	"CrackedLava", "Water", "Air" }

-- line pictograms of the generator tiles, on a 16-unit grid (x right, y down): { x1, y1, x2, y2 } per stroke
local PICTO = {
	building = { { 2.5, 8, 2.5, 14 }, { 2.5, 14, 13.5, 14 }, { 13.5, 14, 13.5, 8 }, { 1.5, 8.5, 8, 3 }, { 8, 3, 14.5, 8.5 },
		{ 6.5, 14, 6.5, 10.5 }, { 6.5, 10.5, 9.5, 10.5 }, { 9.5, 10.5, 9.5, 14 } },
	stairs = { { 2, 14, 2, 11 }, { 2, 11, 5, 11 }, { 5, 11, 5, 8 }, { 5, 8, 8, 8 }, { 8, 8, 8, 5 }, { 8, 5, 11, 5 },
		{ 11, 5, 11, 2 }, { 11, 2, 14, 2 }, { 14, 2, 14, 14 }, { 2, 14, 14, 14 } },
	fence = { { 3, 3, 3, 14 }, { 8, 3, 8, 14 }, { 13, 3, 13, 14 }, { 1.5, 6.5, 14.5, 6.5 }, { 1.5, 10.5, 14.5, 10.5 } },
	bridge = { { 1, 6, 15, 6 }, { 2, 6, 2, 14 }, { 14, 6, 14, 14 }, { 2, 14, 4, 10.5 }, { 4, 10.5, 8, 9 }, { 8, 9, 12, 10.5 },
		{ 12, 10.5, 14, 14 } },
	tower = { { 3.5, 2.5, 3.5, 14.5 }, { 12.5, 2.5, 12.5, 14.5 }, { 3.5, 14.5, 12.5, 14.5 }, { 3.5, 2.5, 5.5, 2.5 },
		{ 5.5, 2.5, 5.5, 4.5 }, { 5.5, 4.5, 7, 4.5 }, { 7, 4.5, 7, 2.5 }, { 7, 2.5, 9, 2.5 }, { 9, 2.5, 9, 4.5 },
		{ 9, 4.5, 10.5, 4.5 }, { 10.5, 4.5, 10.5, 2.5 }, { 10.5, 2.5, 12.5, 2.5 }, { 7, 14.5, 7, 11 }, { 7, 11, 9, 11 },
		{ 9, 11, 9, 14.5 } },
	arch = { { 2, 14.5, 2, 8 }, { 14, 14.5, 14, 8 }, { 2, 8, 3, 5 }, { 3, 5, 5.5, 3 }, { 5.5, 3, 8, 2.5 }, { 8, 2.5, 10.5, 3 },
		{ 10.5, 3, 13, 5 }, { 13, 5, 14, 8 }, { 5, 14.5, 5, 9 }, { 11, 14.5, 11, 9 }, { 5, 9, 6, 7 }, { 6, 7, 8, 6.3 },
		{ 8, 6.3, 10, 7 }, { 10, 7, 11, 9 } },
	colonnade = { { 1, 2.5, 15, 2.5 }, { 1.5, 4.5, 14.5, 4.5 }, { 3, 4.5, 3, 12.5 }, { 8, 4.5, 8, 12.5 }, { 13, 4.5, 13, 12.5 },
		{ 1.5, 12.5, 14.5, 12.5 }, { 1, 14.5, 15, 14.5 } },
	wall = { { 1.5, 5, 1.5, 14.5 }, { 14.5, 5, 14.5, 14.5 }, { 1.5, 14.5, 6, 14.5 }, { 10, 14.5, 14.5, 14.5 },
		{ 6, 14.5, 6, 10 }, { 6, 10, 8, 8.5 }, { 8, 8.5, 10, 10 }, { 10, 10, 10, 14.5 }, { 1.5, 5, 3.5, 5 }, { 3.5, 5, 3.5, 3 },
		{ 3.5, 3, 6.5, 3 }, { 6.5, 3, 6.5, 5 }, { 6.5, 5, 9.5, 5 }, { 9.5, 5, 9.5, 3 }, { 9.5, 3, 12.5, 3 }, { 12.5, 3, 12.5, 5 },
		{ 12.5, 5, 14.5, 5 } },
	road = { { 2.5, 15, 6, 1 }, { 13.5, 15, 10, 1 }, { 8, 14.5, 8, 11.5 }, { 8, 9, 8, 6.5 }, { 8, 4, 8, 2 } },
	tree = { { 8, 1.5, 4, 6.5 }, { 8, 1.5, 12, 6.5 }, { 4, 6.5, 12, 6.5 }, { 8, 4.5, 2.5, 11 }, { 8, 4.5, 13.5, 11 },
		{ 2.5, 11, 13.5, 11 }, { 8, 11, 8, 15 } },
	rock = { { 2, 13, 3.5, 8 }, { 3.5, 8, 6.5, 4.5 }, { 6.5, 4.5, 10.5, 3.5 }, { 10.5, 3.5, 13.5, 7 }, { 13.5, 7, 14.5, 13 },
		{ 14.5, 13, 2, 13 }, { 6.5, 4.5, 8.5, 9 }, { 8.5, 9, 13.5, 7 }, { 8.5, 9, 9, 13 }, { 3.5, 8, 8.5, 9 } },
	crystals = { { 5, 13.5, 3, 9 }, { 3, 9, 5, 4.5 }, { 5, 4.5, 7, 9 }, { 7, 9, 5, 13.5 }, { 10.5, 13.5, 8.5, 7 },
		{ 8.5, 7, 10.5, 1.5 }, { 10.5, 1.5, 12.5, 7 }, { 12.5, 7, 10.5, 13.5 }, { 1.5, 14.5, 14.5, 14.5 } },
	furniture = { { 1.5, 6.5, 14.5, 6.5 }, { 1.5, 8, 14.5, 8 }, { 3.5, 8, 3.5, 14.5 }, { 12.5, 8, 12.5, 14.5 } },
	terrain = { { 1, 13.5, 5, 7 }, { 5, 7, 7.5, 10 }, { 7.5, 10, 10.5, 4.5 }, { 10.5, 4.5, 15, 13.5 }, { 1, 13.5, 15, 13.5 } },
}

-- ---------------------------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------------------------
-- "Script.Path:12: message" -> "message"
local function clean(err)
	local text = tostring(err)
	text = string.gsub(text, "^[^%s:]+:%d+: ", "")
	return (string.gsub(text, "^LostCube: ", ""))
end

-- Romanian plural with the "de" form: 1 piesă, 5 piese, 20 de piese, 101 piese
local function plural(n, one, many)
	if n == 1 then
		return "1 " .. one
	end
	local r = n % 100
	if n ~= 0 and (r == 0 or r >= 20) then
		return n .. " de " .. many
	end
	return n .. " " .. many
end
Panel.plural = plural

local function fmt(v, decimals)
	return UI.fmt(v, decimals or 2)
end

local function undo()
	pcall(function()
		ChangeHistoryService:Undo()
	end)
end

local function select(list)
	pcall(function()
		Selection:Set(list)
	end)
end

local function deepCopy(v)
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

local function defaults(kind)
	local out = {}
	for _, f in GEN[kind].params do
		out[f.key] = deepCopy(f.default)
	end
	return out
end

-- stored LC_Params -> values for the form (normalized; fields an older version saved and this one lacks are dropped)
local function loadParams(kind, raw)
	local values, errors = Generators.normalize(kind, raw, Modeling.isMaterial)
	if values then
		return values
	end
	local out = defaults(kind)
	for key, v in raw do
		if FIELDS[kind][key] then
			out[key] = v
		end
	end
	local again = Generators.normalize(kind, out, Modeling.isMaterial)
	return again or defaults(kind), errors
end

local function labelOf(kind, key)
	return (KIND_LABELS[kind] and KIND_LABELS[kind][key]) or LABELS[key] or (FIELDS[kind][key] and FIELDS[kind][key].label) or key
end

local function rangeText(f)
	if f.min and f.max then
		local unit = DEGREES[f.key] and "°" or ((f.kind == "number" and not RATIOS[f.key]) and " studs" or "")
		return string.format(" · %s–%s%s", fmt(f.min), fmt(f.max), unit)
	end
	return ""
end

local function optionLabel(kind, f, value)
	local own = f.key == "kind" and KIND_OPTIONS[kind] or OPTIONS[f.key]
	return own and own[value] or tostring(value)
end

local function positionOf(inst)
	local ok, p = pcall(function()
		if inst:IsA("Attachment") then
			local parent = inst.Parent
			if parent and parent:IsA("BasePart") then
				return (parent.CFrame * inst.CFrame).Position
			end
			return inst.WorldPosition
		elseif inst:IsA("BasePart") then
			return inst.Position
		elseif inst:IsA("Model") then
			return inst:GetPivot().Position
		end
		return nil
	end)
	return ok and p or nil
end

local function countParts(model)
	local stored = model:GetAttribute("LC_Parts")
	if type(stored) == "number" then
		return stored
	end
	local n = 0
	for i, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			n += 1
		end
		if i > 50000 then
			break
		end
	end
	return n
end

-- world box (min, max) of objects (parts: their rotated box, models: GetBoundingBox)
local function worldBox(objs)
	local lo, hi
	for _, obj in objs do
		local cf, size
		if obj:IsA("Model") then
			cf, size = obj:GetBoundingBox()
		else
			cf, size = obj.CFrame, obj.Size
		end
		local h = size / 2
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local p = cf:PointToWorldSpace(Vector3.new(h.X * sx, h.Y * sy, h.Z * sz))
					lo = lo and Vector3.new(math.min(lo.X, p.X), math.min(lo.Y, p.Y), math.min(lo.Z, p.Z)) or p
					hi = hi and Vector3.new(math.max(hi.X, p.X), math.max(hi.Y, p.Y), math.max(hi.Z, p.Z)) or p
				end
			end
		end
	end
	return lo, hi
end

-- a frame on `point` whose LookVector (the front of a generated model, -Z) turns toward the camera
local function facingCamera(point)
	local cam = workspace.CurrentCamera
	local look = Vector3.new(0, 0, 1)
	if cam then
		local d = cam.CFrame.Position - point
		if Vector3.new(d.X, 0, d.Z).Magnitude > 1e-3 then
			look = Vector3.new(d.X, 0, d.Z).Unit
		end
	end
	return CFrame.lookAt(point, point + look)
end

local AXES = { { value = "X", label = "X" }, { value = "Y", label = "Y" }, { value = "Z", label = "Z" } }
local AXIS_VECTOR = { X = Vector3.new(1, 0, 0), Y = Vector3.new(0, 1, 0), Z = Vector3.new(0, 0, 1) }

-- ---------------------------------------------------------------------------------------------
-- panel
-- ---------------------------------------------------------------------------------------------
local selfChecked = false -- Modeling.selfCheck runs once per plugin session

function Panel.new(ctx)
	local self = setmetatable({
		ctx = ctx,
		mode = "gen", -- "gen" (generators) | "ops" (operations on the selection)
		kind = nil, -- the chosen generator
		values = {}, -- kind -> the form's values
		preview = true,
		where = "camera", -- the preview spot: "camera" | "selection"
		editing = nil, -- a generated Model of the selection (Actualizează)
		editingJSON = nil,
		ghostGen = 0,
		op = {
			fill = { mode = "triangle", thickness = 0.4, align = "center" },
			array = { mode = "linear", count = 5, axis = "X", gap = 0, radius = 12, angle = 360, arcAngle = 15, arcAxis = "Y",
				arcRadius = 0, spacing = 8, align = true },
			mirror = { axis = "X", copy = true },
			align = { axis = "Y", mode = "min", to = "group" },
			place = { normal = false, grid = 1, rotation = 0, face = "auto", extend = "center" },
			scatter = { density = 50, minDistance = 4, scaleMin = 0.8, scaleMax = 1.25, rotate = true, normal = false, seed = 1,
				area = 64 },
			spline = { kind = "rail", spacing = 4, width = 16, height = 8, diameter = 0.4, closed = false },
			solid = { keep = false },
			optimize = { anchorAll = true, decor = true, shadows = true, fidelity = true },
		},
		conns = {},
	}, Panel)
	local saved = self:setting("build.mode")
	if saved == "gen" or saved == "ops" then
		self.mode = saved
	end
	pcall(function()
		table.insert(self.conns, Selection.SelectionChanged:Connect(function()
			self:onSelection()
		end))
	end)
	return self
end

function Panel:setting(key)
	local app = self.ctx.app
	if app and app.setting then
		local ok, v = pcall(app.setting, app, key)
		return ok and v or nil
	end
	return nil
end

function Panel:refresh()
	local app = self.ctx.app
	if app and not self.dead then
		app:refresh()
	end
end

-- true while the Modelare tab is the one shown
function Panel:visible()
	local app = self.ctx.app
	if self.dead then
		return false
	end
	if not app then
		return true
	end
	if app.tab ~= "Build" or app.dead then
		return false
	end
	-- the dock widget can be closed while the tab stays chosen
	local ok, enabled = pcall(function()
		local container = app.root and app.root.Parent
		if container and container:IsA("PluginGui") then
			return container.Enabled
		end
		return true
	end)
	return not ok or enabled ~= false
end

function Panel:setMode(mode)
	if self.mode == mode then
		return
	end
	self.mode = mode
	local app = self.ctx.app
	if app and app.save then
		pcall(app.save, app, "build.mode", mode)
	end
	if mode ~= "gen" then
		self:clearGhost()
	else
		self:scheduleGhost(0)
	end
	self:refresh()
end

-- ---------------------------------------------------------------------------------------------
-- selection (read once per change, never during a render)
-- ---------------------------------------------------------------------------------------------
function Panel:selection()
	if self.sel then
		return self.sel
	end
	local raw = {}
	pcall(function()
		raw = Selection:Get()
	end)
	local info = { raw = raw, objects = {}, parts = {}, models = {}, attachments = {}, points = {}, partCount = 0 }
	local ok, objs = pcall(Modeling.selection)
	info.objects = ok and objs or {}
	for _, inst in raw do
		if inst:IsA("Attachment") then
			table.insert(info.attachments, inst)
		end
		local p = positionOf(inst)
		if p then
			table.insert(info.points, p)
		end
	end
	for _, obj in info.objects do
		if obj:IsA("BasePart") then
			table.insert(info.parts, obj)
			info.partCount += 1
		elseif obj:IsA("Model") then
			table.insert(info.models, obj)
			info.partCount += countParts(obj)
		end
	end
	local only = #info.objects == 1 and info.objects[1] or nil
	if only and only:IsA("Model") and type(only:GetAttribute("LC_Generator")) == "string" then
		info.generated = only
	end
	self.sel = info
	return info
end

function Panel:onSelection()
	self.sel = nil
	self.optReport = nil
	if self.dead then
		return
	end
	local info = self:selection()
	local model = info.generated
	if model and model ~= self.editing then
		local kind = model:GetAttribute("LC_Generator")
		local raw = Spec.fromJSON(model:GetAttribute("LC_Params") or "")
		if GEN[kind] and type(raw) == "table" then
			local values = loadParams(kind, raw)
			self.kind = kind
			self.values[kind] = values
			self.editing = model
			self.editingJSON = Spec.toJSON(values)
		end
	elseif not model then
		self.editing = nil
		self.editingJSON = nil
	end
	if self:visible() then
		self:refresh()
		self:scheduleGhost(0.05)
	end
end

function Panel:status(info)
	if #info.raw == 0 then
		return "Nimic selectat"
	end
	if info.generated then
		local g = GEN[info.generated:GetAttribute("LC_Generator")]
		return string.format("%s · %s · %s", info.generated.Name, g and string.lower(SHORT[g.key] or g.label) or "generat",
			plural(info.partCount, "piesă", "piese"))
	end
	if #info.objects == 1 then
		local obj = info.objects[1]
		if obj:IsA("Model") then
			return string.format("%s · %s", obj.Name, plural(info.partCount, "piesă", "piese"))
		end
		return string.format("%s · %s", obj.Name, obj.ClassName)
	end
	if #info.objects == 0 and #info.attachments > 0 then
		return plural(#info.attachments, "atașament", "atașamente")
	end
	local text = string.format("%s · %s", plural(#info.objects, "obiect", "obiecte"), plural(info.partCount, "piesă", "piese"))
	if #info.attachments > 0 then
		text ..= " · " .. plural(#info.attachments, "atașament", "atașamente")
	end
	return text
end

-- ---------------------------------------------------------------------------------------------
-- generator values, compute (cached), ghost preview
-- ---------------------------------------------------------------------------------------------
function Panel:valuesOf(kind)
	if not self.values[kind] then
		self.values[kind] = defaults(kind)
	end
	return self.values[kind]
end

-- the generator's result for the current values (cached by their JSON): result or nil, errors text
function Panel:compute()
	local kind = self.kind
	if not kind then
		return nil, nil
	end
	local key = kind .. "|" .. Spec.toJSON(self:valuesOf(kind))
	if self.cacheKey ~= key then
		local ok, result, err = pcall(Generators.generate, kind, deepCopy(self:valuesOf(kind)), Modeling.isMaterial)
		if not ok then
			result, err = nil, clean(result)
		end
		self.cacheKey, self.cacheResult, self.cacheError = key, result, err
	end
	return self.cacheResult, self.cacheError, self.cacheKey
end

function Panel:dirty()
	if not self.editing then
		return false
	end
	return Spec.toJSON(self:valuesOf(self.kind)) ~= self.editingJSON
end

function Panel:isEditing()
	local m = self.editing
	return m ~= nil and m.Parent ~= nil and m:GetAttribute("LC_Generator") == self.kind
end

-- the spot in front of the camera (kept until Mută asks for a new one, so the preview does not chase the camera)
function Panel:cameraAnchor()
	if not self.cameraCF then
		local ok, cf = pcall(Modeling.placement)
		cf = ok and cf or CFrame.new()
		-- Modeling.placement() turns the model's front (-Z) away from the camera: turn it around so it faces the camera
		self.cameraCF = cf * CFrame.Angles(0, math.pi, 0)
	end
	return self.cameraCF
end

-- where the preview / a new model goes: the edited model, the top of the selection or in front of the camera
function Panel:anchorCF()
	if self:isEditing() then
		return self.editing.WorldPivot
	end
	if self.where == "selection" then
		local info = self:selection()
		if #info.objects > 0 then
			local ok, cf = pcall(function()
				local lo, hi = worldBox(info.objects)
				return facingCamera(Vector3.new((lo.X + hi.X) / 2, hi.Y, (lo.Z + hi.Z) / 2))
			end)
			if ok and cf then
				return cf
			end
		end
	end
	return self:cameraAnchor()
end

function Panel:wantsGhost()
	if not (self.preview and self.mode == "gen" and self.kind and self:visible()) then
		return false
	end
	if self:isEditing() then
		return self:dirty()
	end
	return true
end

function Panel:scheduleGhost(delay)
	self.ghostGen += 1
	local gen = self.ghostGen
	task.delay(delay or GHOST_DELAY, function()
		if gen == self.ghostGen and not self.dead then
			self:syncGhost()
		end
	end)
end

function Panel:clearGhost()
	local ghost = self.ghost
	self.ghost, self.ghostContent, self.ghostCF = nil, nil, nil
	if ghost then
		pcall(function()
			ghost:Destroy()
		end)
	end
end

-- one translucent, unselectable, non-archivable part of the preview
local GHOST_CLASS = { Wedge = "WedgePart", CornerWedge = "CornerWedgePart" }
local function ghostPart(shape, size, cf, color)
	local part = Instance.new(GHOST_CLASS[shape] or "Part")
	if part:IsA("Part") and shape and shape ~= "Block" and not GHOST_CLASS[shape] then
		part.Shape = (Enum.PartType :: any)[shape]
	end
	part.Name = "Ghost"
	part.Archivable = false
	part.Anchored = true
	part.Locked = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = 0.45
	part.Size = Vector3.new(math.max(0.05, size[1]), math.max(0.05, size[2]), math.max(0.05, size[3]))
	part.CFrame = cf
	part.Color = color
	return part
end

function Panel:syncGhost()
	if not self:wantsGhost() then
		self:clearGhost()
		return
	end
	local result, _, key = self:compute()
	if not result then
		self:clearGhost()
		return
	end
	local cf = self:anchorCF()
	if self.ghost and self.ghost.Parent and self.ghostContent == key then
		if self.ghostCF ~= cf then
			pcall(function()
				self.ghost:PivotTo(cf)
			end)
			self.ghostCF = cf
		end
		return
	end
	self:clearGhost()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local model = Instance.new("Model")
	model.Name = GHOST_NAME
	model.Archivable = false
	local ok, err = pcall(function()
		local pieces = result.pieces
		if #pieces > GHOST_LIMIT then
			local b = Modeling.Geometry.piecesBounds(pieces)
			local mid = { (b.min[1] + b.max[1]) / 2, (b.min[2] + b.max[2]) / 2, (b.min[3] + b.max[3]) / 2 }
			ghostPart("Block", { b.max[1] - b.min[1], b.max[2] - b.min[2], b.max[3] - b.min[3] },
				cf * CFrame.new(mid[1], mid[2], mid[3]), Color3.fromHex("#9fb4c8")).Parent = model
		else
			for _, pc in pieces do
				local hex = Spec.hexColor(pc.color) or Spec.DEFAULT_COLOR
				ghostPart(pc.shape, pc.size, cf * Modeling.toCFrame(pc.cf), Color3.fromHex(hex)).Parent = model
			end
		end
		if #pieces == 0 then -- terrain: a disc with the generator's radius
			local r = (self:valuesOf(self.kind).radius or 16)
			ghostPart("Cylinder", { 0.4, r * 2, r * 2 }, cf * CFrame.new(0, 0.2, 0) * CFrame.Angles(0, 0, math.pi / 2),
				Color3.fromHex("#7a9a5a")).Parent = model
		end
		model.WorldPivot = cf
	end)
	if not ok then
		warn("LostCube: previzualizarea nu s-a putut construi:", err)
		pcall(function()
			model:Destroy()
		end)
		return
	end
	model.Parent = camera
	self.ghost, self.ghostContent, self.ghostCF = model, key, cf
	self:watchGhost()
end

-- while a preview exists: take it away when the tab, the window or the mode changes (App has no tab events)
function Panel:watchGhost()
	if self.watching then
		return
	end
	self.watching = true
	local function check()
		if not self.ghost then
			self.watching = false
			return
		end
		if self.dead or not self:wantsGhost() then
			self.watching = false
			self:clearGhost()
			return
		end
		task.delay(WATCH_EVERY, check)
	end
	task.delay(WATCH_EVERY, check)
end

-- a form value changed: live = while dragging (no redraw of the panel, only the preview)
function Panel:edited(live)
	self:scheduleGhost(live and 0.12 or GHOST_DELAY)
	if not live then
		self:refresh()
	end
end

function Panel:choose(kind)
	if self.kind == kind then
		return
	end
	self.kind = kind
	if self.editing and self.editing:GetAttribute("LC_Generator") ~= kind then
		self.editing, self.editingJSON = nil, nil
	end
	self:scheduleGhost(0.05)
	self:refresh()
end

function Panel:resetValues()
	if self.kind then
		self.values[self.kind] = defaults(self.kind)
		self:edited()
	end
end

function Panel:setPreview(on)
	self.preview = on
	if on then
		self:scheduleGhost(0)
	else
		self:clearGhost()
	end
	self:refresh()
end

function Panel:recenter()
	self.cameraCF = nil
	self.where = "camera"
	self:scheduleGhost(0)
	self:refresh()
end

-- commits a new model (one undo step)
function Panel:place(copy)
	local kind = self.kind
	if not kind then
		return
	end
	local cf
	if copy then
		cf = self:cameraAnchor() -- a copy of the edited model: in front of the camera, not on top of it
	else
		cf = (self.ghost and self.ghostCF) or self:anchorCF()
	end
	self:clearGhost()
	local values = deepCopy(self:valuesOf(kind))
	local ok, model, report = pcall(Modeling.generate, kind, values, nil, cf)
	if not ok then
		UI.toast(clean(model), "error")
		self:scheduleGhost()
		return
	end
	local name = SHORT[kind] or GEN[kind].label
	if model then
		self.values[kind] = deepCopy(report.params or values)
		self.editing, self.editingJSON = model, Spec.toJSON(self.values[kind])
		select({ model })
		UI.toast(string.format("Am plasat „%s” (%s).", name, plural(report.parts, "piesă", "piese")), "success",
			{ action = { text = "Anulează", onClick = undo } })
	else
		UI.toast(string.format("Am generat terenul (%s).", plural(report.terrainOps, "operație", "operații")), "success",
			{ action = { text = "Anulează", onClick = undo } })
		self:scheduleGhost()
	end
	self:refresh()
end

-- rebuilds the selected generated model with the form's values (one undo step)
function Panel:update()
	local model = self.editing
	if not (model and model.Parent) then
		return
	end
	self:clearGhost()
	local ok, fresh, report = pcall(Modeling.regenerate, model, deepCopy(self:valuesOf(self.kind)))
	if not ok then
		UI.toast(clean(fresh), "error")
		self:scheduleGhost()
		return
	end
	self.editing, self.editingJSON = fresh, Spec.toJSON(report.params)
	select({ fresh })
	UI.toast(string.format("Am actualizat „%s” (%s).", fresh.Name, plural(report.parts, "piesă", "piese")), "success",
		{ action = { text = "Anulează", onClick = undo } })
	self:refresh()
end

-- ---------------------------------------------------------------------------------------------
-- layout helpers
-- ---------------------------------------------------------------------------------------------
-- a 24 px row: dim label (LABEL_W), the controls (they share the width), optional fixed room on the right
local function row(parent, label, opts)
	opts = opts or {}
	local frame = UI.make("Frame", { Name = "Row", Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H) },
		{ UI.hlist(SPACE.sm, false) })
	local l = UI.label(frame, label, { width = LABEL_W, dim = true })
	if opts.tip then
		UI.tip(l, opts.tip)
	end
	local rightW = opts.rightWidth or 0
	local area = UI.make("Frame", { Name = "Area", Parent = frame, BackgroundTransparency = 1,
		Size = UDim2.new(1, -(LABEL_W + SPACE.sm + (rightW > 0 and rightW + SPACE.sm or 0)), 1, 0) }, { UI.hlist(SPACE.xs, true) })
	local right = nil
	if rightW > 0 then
		right = UI.make("Frame", { Name = "Right", Parent = frame, BackgroundTransparency = 1, Size = UDim2.new(0, rightW, 1, 0) },
			{ UI.hlist(0, false) })
	end
	return area, right
end

local function buttonWidth(text, icon)
	return math.max(64, UI.textWidth(text, "control") + 24 + (icon and 22 or 0))
end

-- the action line of an operation: a dim hint on the left (what will happen, or why it cannot), buttons on the right.
-- buttons: { { text, onClick, disabled, tip, style, icon } }
local function actionRow(parent, hint, buttons, height)
	height = height or UI.H
	local frame = UI.make("Frame", { Name = "Action", Parent = parent, BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, height) })
	local total = 0
	for i, b in buttons do
		total += buttonWidth(b.text, b.icon) + (i > 1 and SPACE.xs or 0)
	end
	local right = UI.make("Frame", { Name = "Buttons", Parent = frame, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, total, 1, 0) },
		{ UI.make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, SPACE.xs),
			FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Center }) })
	local made = {}
	for _, b in buttons do
		local button = UI.button(right, b.text, b.onClick, { style = b.style, width = buttonWidth(b.text, b.icon), height = height,
			disabled = b.disabled, tip = b.tip, icon = b.icon })
		table.insert(made, button)
	end
	if hint and hint ~= "" then
		local l = UI.label(frame, hint, { role = "meta", dim = true, height = height })
		l.Size = UDim2.new(1, -(total + SPACE.sm), 0, height)
	end
	return frame, made
end

-- a small heading inside a section body (groups of rows of one operation)
local function subhead(parent, text)
	local l = UI.label(parent, text, { role = "meta", medium = true, color = "text", height = 18 })
	return l
end

-- the strokes of a pictogram, as thin frames painted with a token
local function picto(parent, key, size, token)
	local holder = UI.make("Frame", { Name = "Picto", Parent = parent, BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10), Size = UDim2.fromOffset(size, size) })
	local k = size / 16
	local w = 1.5
	local lines = {}
	for _, s in PICTO[key] or {} do
		local x1, y1, x2, y2 = s[1] * k, s[2] * k, s[3] * k, s[4] * k
		local dx, dy = x2 - x1, y2 - y1
		local len = math.sqrt(dx * dx + dy * dy)
		local bar = UI.make("Frame", { Name = "Stroke", Parent = holder, AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset((x1 + x2) / 2, (y1 + y2) / 2), Size = UDim2.fromOffset(len + w * 0.5, w),
			Rotation = math.deg(math.atan2(dy, dx)) })
		UI.skin(bar, { BackgroundColor3 = token })
		table.insert(lines, bar)
	end
	return lines
end

function Panel:contentWidth()
	local app = self.ctx.app
	local w = 360
	if app and app.root then
		local ok, size = pcall(function()
			return app.root.AbsoluteSize
		end)
		if ok and size and size.X > 0 then
			w = size.X
		end
	end
	return w - 2 * 12 - 6
end

-- a section whose body is only built while it is open (folding it open redraws the panel)
function Panel:fold(parent, key, title, collapsed, build, opts)
	opts = opts or {}
	local body = UI.section(parent, title, { key = key, collapsed = collapsed, badge = opts.badge, right = opts.right,
		rightWidth = opts.rightWidth, onToggle = function(c)
			if not c then
				self:refresh()
			end
		end })
	if not UI.collapsed[key] then
		build(body)
	end
	return body
end

-- ---------------------------------------------------------------------------------------------
-- render
-- ---------------------------------------------------------------------------------------------
function Panel:render(parent)
	local root = UI.make("Frame", { Name = "BuildPanel", Parent = parent, BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, { UI.vlist(SPACE.sm) })
	self:selfCheck()
	local info = self:selection()
	UI.header(root, "Modelare", { subtitle = self:status(info) })
	UI.segmented(root, {
		{ value = "gen", label = "Generatoare", tip = "Clădiri, scări, poduri, copaci, teren: construite din parametri" },
		{ value = "ops", label = "Operații", tip = "Umple, repetă, oglindește, aliniază, împrăștie, unește ce ai selectat" },
	}, self.mode, function(v)
		self:setMode(v)
	end)
	if self.mode == "gen" then
		self:renderGenerators(root, info)
		self:scheduleGhost()
	else
		self:renderOps(root, info)
	end
end

function Panel:selfCheck()
	if selfChecked then
		return
	end
	selfChecked = true
	task.defer(function()
		local ok, report = pcall(Modeling.selfCheck)
		if ok and report.wedge == true and report.cornerWedge == true then
			return
		end
		local why = ok and table.concat(report.notes or {}, " ") or clean(report)
		warn("LostCube Modeling.selfCheck:", why)
		UI.toast("Verificarea pieselor-pană a eșuat: umplerile de triunghiuri și acoperișurile pot ieși greșit.", "warning",
			{ duration = 8 })
	end)
end

-- ---------------------------------------------------------------------------------------------
-- generators view
-- ---------------------------------------------------------------------------------------------
function Panel:renderGenerators(root, info)
	local body = UI.section(root, "Generatoare", { key = "build.generators", badge = #Modeling.GENERATORS })
	if not UI.collapsed["build.generators"] then
		self:renderTiles(body)
	end
	if not self.kind then
		UI.label(body, "Alege ce construiești; previzualizarea apare în fața camerei, iar Plasează o adaugă în joc.",
			{ role = "meta", dim = true, wrap = true })
		return
	end
	self:renderForm(root, info)
end

function Panel:renderTiles(body)
	local list = Modeling.GENERATORS
	local cols = math.clamp(math.floor((self:contentWidth() + TILE_GAP) / (TILE_MIN + TILE_GAP)), 3, 7)
	local rows = math.ceil(#list / cols)
	-- rows of equal tiles that share the width (a flex list, so they follow the window when it is resized)
	local grid = UI.make("Frame", { Name = "Generators", Parent = body, BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, rows * TILE_H + (rows - 1) * TILE_GAP) }, { UI.vlist(TILE_GAP) })
	for r = 1, rows do
		local line = UI.make("Frame", { Name = "TileRow", Parent = grid, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, TILE_H) },
			{ UI.hlist(TILE_GAP, true) })
		for c = 1, cols do
			local g = list[(r - 1) * cols + c]
			if g then
				self:tile(line, g, cols)
			else
				UI.make("Frame", { Name = "Spacer", Parent = line, BackgroundTransparency = 1, Size = UDim2.new(1 / cols, 0, 1, 0) })
			end
		end
	end
end

function Panel:tile(line, g, cols)
	local selected = self.kind == g.key
	local b = UI.make("TextButton", { Name = "Tile_" .. g.key, Parent = line, Text = "", AutoButtonColor = false,
		BackgroundTransparency = selected and 0 or 1, Size = UDim2.new(1 / cols, 0, 1, 0) }, { UI.corner(UI.RADIUS.control) })
	UI.skin(b, { BackgroundColor3 = selected and "accentSoft" or "surfaceHover" })
	if selected then
		UI.stroke("accent").Parent = b
	end
	b:SetAttribute("Selected", selected)
	local rest = selected and "accent" or "textDim"
	local lines = picto(b, g.key, 20, rest)
	local label = UI.label(b, SHORT[g.key] or g.label, { role = "meta", medium = selected, align = Enum.TextXAlignment.Center,
		color = selected and "text" or "textDim", height = 14 })
	label.Position = UDim2.new(0, 2, 1, -19)
	label.Size = UDim2.new(1, -4, 0, 14)
	local function paint(lineToken, textToken)
		for _, line in lines do
			UI.skin(line, { BackgroundColor3 = lineToken })
		end
		UI.skin(label, { TextColor3 = textToken })
	end
	if not selected then
		b.MouseEnter:Connect(function()
			b.BackgroundTransparency = 0
			paint("text", "text")
		end)
		b.MouseLeave:Connect(function()
			b.BackgroundTransparency = 1
			paint("textDim", "textDim")
		end)
	end
	b.MouseButton1Click:Connect(function()
		self:choose(g.key)
	end)
	UI.tip(b, g.label)
	return b
end

function Panel:renderForm(root, info)
	local kind = self.kind
	local g = GEN[kind]
	local values = self:valuesOf(kind)
	local result, err = self:compute()
	local editing = self:isEditing()
	local badge = "?"
	if result then
		badge = #result.pieces > 0 and plural(#result.pieces, "piesă", "piese") or "teren"
	end
	local form = FORM[kind] or { main = {}, groups = {} }
	local body = UI.section(root, SHORT[kind] or g.label, { key = "build.form", badge = badge, rightWidth = 52,
		right = function(r)
			UI.iconButton(r, self.preview and "eye" or "eyeOff", function()
				self:setPreview(not self.preview)
			end, { tip = self.preview and "Ascunde previzualizarea" or "Arată previzualizarea" })
			UI.iconButton(r, "refresh", function()
				self:resetValues()
			end, { tip = "Valorile implicite" })
		end })
	if UI.collapsed["build.form"] then
		return
	end
	-- the fields of the form; the rest go to folded sections under it
	local listed = {}
	for _, key in form.main do
		listed[key] = true
		if FIELDS[kind][key] then
			self:field(body, kind, FIELDS[kind][key], values)
		end
	end
	for _, group in form.groups do
		for _, key in group[3] do
			listed[key] = true
		end
	end
	if err then
		UI.note(body, UI.escape((string.gsub(err, "\n", " "))), "danger")
	end
	-- where the new model goes (not while editing a generated model: it stays where it is)
	if not editing then
		local hasObjects = #info.objects > 0
		UI.segmented(row(body, "Loc", { tip = "Unde apare clădirea nouă" }), {
			{ value = "camera", label = "În fața camerei", tip = "Pe sol, în fața camerei (Mută aduce previzualizarea aici)" },
			{ value = "selection", label = "Pe selecție", tip = "Deasupra obiectelor selectate" },
		}, self.where, function(v)
			self.where = v
			self:scheduleGhost(0)
			self:refresh()
		end)
		if self.where == "selection" and not hasObjects then
			UI.label(body, "Nimic selectat: modelul apare în fața camerei.", { role = "meta", dim = true })
		end
	end
	UI.spacer(body, 2)
	local reason = err and "Corectează parametrii marcați." or nil
	local bar = UI.make("Frame", { Name = "PlaceBar", Parent = body, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, UI.H_LARGE) },
		{ UI.hlist(SPACE.xs, false) })
	if editing then
		local dirty = self:dirty()
		local copyW = buttonWidth("Plasează copie")
		local primary = UI.button(bar, "Actualizează", function()
			self:update()
		end, { style = dirty and "primary" or "normal", height = UI.H_LARGE, disabled = err ~= nil or not dirty,
			tip = reason or (dirty and "Reconstruiește modelul selectat cu acești parametri (un singur Ctrl+Z)"
				or "Schimbă un parametru ca să actualizezi modelul selectat") })
		primary.Size = UDim2.new(1, -(copyW + SPACE.xs), 0, UI.H_LARGE)
		UI.button(bar, "Plasează copie", function()
			self:place(true)
		end, { width = copyW, height = UI.H_LARGE, disabled = err ~= nil, tip = reason or "Un model nou, în fața camerei" })
	else
		local primary = UI.button(bar, "Plasează", function()
			self:place(false)
		end, { style = "primary", height = UI.H_LARGE, disabled = err ~= nil, tip = reason or "Adaugă modelul în joc (un singur Ctrl+Z)" })
		primary.Size = UDim2.new(1, -(UI.H_LARGE + SPACE.xs), 0, UI.H_LARGE)
		UI.iconButton(bar, "locate", function()
			self:recenter()
		end, { tip = "Mută previzualizarea în fața camerei", size = UI.H_LARGE })
	end
	-- what will be built: size, parts, where
	if result then
		local parts = {}
		local b = #result.pieces > 0 and Modeling.Geometry.piecesBounds(result.pieces) or nil
		if b then
			table.insert(parts, string.format("%s × %s × %s studs", fmt(b.max[1] - b.min[1], 1), fmt(b.max[2] - b.min[2], 1),
				fmt(b.max[3] - b.min[3], 1)))
		elseif result.terrain and #result.terrain > 0 then
			table.insert(parts, plural(#result.terrain, "operație de teren", "operații de teren"))
		end
		if editing then
			table.insert(parts, self:dirty() and "modificat" or "fără modificări")
		elseif not self.preview then
			table.insert(parts, "previzualizare oprită")
		end
		UI.label(body, table.concat(parts, " · "), { role = "meta", dim = true, height = 16 })
	end
	-- the folded groups
	local extra = {}
	for _, f in g.params do
		if not listed[f.key] then
			table.insert(extra, f.key)
		end
	end
	local groups = table.clone(form.groups)
	if #extra > 0 then
		table.insert(groups, { "other", "Altele", extra })
	end
	for _, group in groups do
		self:fold(root, "build.form." .. group[1], group[2], true, function(gbody)
			for _, key in group[3] do
				if FIELDS[kind][key] then
					self:field(gbody, kind, FIELDS[kind][key], values)
				end
			end
		end)
	end
end

-- one control of the form, from the field's schema
function Panel:field(body, kind, f, values)
	local key = f.key
	local label = labelOf(kind, key)
	local tip = f.label .. rangeText(f)
	local function set(v, live)
		values[key] = v
		self:edited(live)
	end
	if f.kind == "number" or f.kind == "int" then
		local isInt = f.kind == "int"
		if key == "seed" then
			local area, right = row(body, label, { rightWidth = UI.H, tip = "Aceeași valoare dă același rezultat" })
			UI.number(area, values[key], function(v)
				set(math.clamp(math.floor(v + 0.5), f.min, f.max))
			end, { min = f.min, max = f.max, step = 1, decimals = 0, tip = tip })
			UI.iconButton(right, "refresh", function()
				set(math.random(1, 99999))
			end, { tip = "Seed aleator" })
			return
		end
		if isInt and f.max - f.min <= 3 then
			local items = {}
			for i = f.min, f.max do
				table.insert(items, { value = i, label = tostring(i) })
			end
			UI.segmented(row(body, label, { tip = tip }), items, values[key], function(v)
				set(v)
			end)
			return
		end
		local unit = if DEGREES[key] then "°" elseif isInt or RATIOS[key] then nil else "studs"
		local step = isInt and 1 or (DEGREES[key] and 1 or (RATIOS[key] and 0.05 or 0.25))
		local decimals = isInt and 0 or (DEGREES[key] and 0 or 2)
		local function commit(v)
			if isInt then
				v = math.floor(v + 0.5)
			end
			return math.clamp(v, f.min, f.max)
		end
		if SLIDERS[key] then
			UI.slider(row(body, label, { tip = tip }), values[key], function(v)
				set(commit(v))
			end, { min = f.min, max = f.max, step = step, decimals = decimals, unit = unit, field = true, valueWidth = 64,
				onInput = function(v)
					set(commit(v), true)
				end })
		else
			UI.scrub(body, label, values[key], function(v)
				set(commit(v))
			end, { min = f.min, max = f.max, step = step, decimals = decimals, unit = unit, labelWidth = LABEL_W, tip = tip,
				onInput = function(v)
					set(commit(v), true)
				end })
		end
	elseif f.kind == "bool" then
		UI.switch(row(body, label, { tip = tip }), values[key] == true, function(v)
			set(v)
		end, { tip = f.label })
	elseif f.kind == "choice" then
		local items = {}
		for _, option in f.options do
			table.insert(items, { value = option, label = optionLabel(kind, f, option) })
		end
		if #items <= 3 or (#items == 4 and kind ~= "terrain") then
			UI.segmented(row(body, label, { tip = tip }), items, values[key], function(v)
				set(v)
			end)
		else
			UI.dropdown(row(body, label, { tip = tip }), items, values[key], function(v)
				set(v)
			end, { menuWidth = 180 })
		end
	elseif f.kind == "color" then
		local ok, color = pcall(Color3.fromHex, values[key])
		UI.color(row(body, label, { tip = tip }), ok and color or Color3.new(1, 1, 1), function(c)
			set("#" .. string.lower(c:ToHex()))
		end)
	elseif f.kind == "material" then
		local terrain = GEN[kind].terrainOnly == true
		local items, found = {}, false
		for _, name in terrain and TERRAIN_MATERIALS or PART_MATERIALS do
			if Modeling.isMaterial(name, terrain) then
				table.insert(items, { value = name, label = name })
				found = found or name == values[key]
			end
		end
		if not found then
			table.insert(items, 1, { value = values[key], label = tostring(values[key]) })
		end
		UI.dropdown(row(body, label, { tip = tip }), items, values[key], function(v)
			set(v)
		end, { menuWidth = 180 })
	elseif f.kind == "points" then
		-- a straight run is edited as its length; a path from a model keeps its points until the length is changed
		local pts = values[key]
		local length = nil
		if type(pts) == "table" and #pts == 2 and pts[1][2] == 0 and pts[2][2] == 0 and pts[1][3] == 0 and pts[2][3] == 0 then
			length = math.abs(pts[2][1] - pts[1][1])
		end
		if length then
			UI.scrub(body, label, length, function(v)
				values[key] = { { -v / 2, 0, 0 }, { v / 2, 0, 0 } }
				self:edited()
			end, { min = 2, max = 2000, step = 0.5, decimals = 2, unit = "studs", labelWidth = LABEL_W,
				tip = "Lungimea traseului drept · pentru un traseu prin piese: Operații, Curbe, Gard",
				onInput = function(v)
					values[key] = { { -v / 2, 0, 0 }, { v / 2, 0, 0 } }
					self:edited(true)
				end })
		else
			local area = row(body, "Traseu", { tip = f.label })
			UI.label(area, plural(type(pts) == "table" and #pts or 0, "punct", "puncte"), { dim = true })
			UI.button(area, "Drept", function()
				values[key] = deepCopy(f.default)
				self:edited()
			end, { style = "ghost", tip = "Înlocuiește traseul cu unul drept" })
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- operations view
-- ---------------------------------------------------------------------------------------------
-- runs an engine call; errors become a toast. Returns ok, results...
local function attempt(fn, ...)
	local results = table.pack(pcall(fn, ...))
	if not results[1] then
		UI.toast(clean(results[2]), "error")
		return false
	end
	return true, table.unpack(results, 2, results.n)
end

local function done(text, kind)
	UI.toast(text, kind or "success", { action = { text = "Anulează", onClick = undo } })
end

function Panel:renderOps(root, info)
	if #info.raw == 0 then
		local empty = UI.empty(root, "Selectează piese, modele sau atașamente ca să le umpli, repeți, oglindești sau aliniezi.",
			nil, nil, { icon = "build", title = "Nimic selectat" })
		UI.button(empty, "Pornește de la un generator", function()
			self:setMode("gen")
		end, { style = "link", autoWidth = true })
		return
	end
	self:renderFill(root, info)
	self:renderArray(root, info)
	self:renderMirror(root, info)
	self:renderAlign(root, info)
	self:renderPlace(root, info)
	self:renderScatter(root, info)
	self:renderSpline(root, info)
	self:renderSolid(root, info)
	self:renderOptimize(root, info)
end

-- Umplere: triangle (3 points), polygon (3+ points), gap between 2 parts
function Panel:renderFill(root, info)
	local o = self.op.fill
	self:fold(root, "build.op.fill", "Umplere", true, function(body)
		UI.segmented(body, {
			{ value = "triangle", label = "Triunghi", tip = "Un triunghi prin 3 piese sau atașamente (1-2 pene)" },
			{ value = "polygon", label = "Poligon", tip = "Un poligon prin 3 sau mai multe puncte, în ordinea selecției" },
			{ value = "gap", label = "Spațiu", tip = "Umple spațiul dintre muchiile apropiate a 2 piese" },
		}, o.mode, function(v)
			o.mode = v
			self:refresh()
		end)
		UI.scrub(body, "Grosime", o.thickness, function(v)
			o.thickness = v
		end, { min = 0.05, max = 20, step = 0.05, decimals = 2, unit = "studs", labelWidth = LABEL_W })
		if o.mode ~= "gap" then
			UI.segmented(row(body, "Aliniere", { tip = "Unde stă grosimea față de planul triunghiului" }), {
				{ value = "center", label = "Centru" }, { value = "front", label = "Față" }, { value = "back", label = "Spate" },
			}, o.align, function(v)
				o.align = v
				self:refresh()
			end)
		end
		local n = #info.points
		local ok, hint
		if o.mode == "triangle" then
			ok = n == 3
			hint = ok and "3 vârfuri" or "Selectează exact 3 piese sau atașamente."
		elseif o.mode == "polygon" then
			ok = n >= 3
			hint = ok and (plural(n, "punct", "puncte") .. ", în ordinea selecției") or "Selectează cel puțin 3 puncte, în ordine."
		else
			ok = #info.parts == 2
			hint = ok and "Între cele 2 piese" or "Selectează exact 2 piese."
		end
		actionRow(body, hint, { { text = "Umple", disabled = not ok, tip = not ok and hint or nil, onClick = function()
			self:runFill(info)
		end } })
	end)
end

function Panel:runFill(info)
	local o = self.op.fill
	local source = info.parts[1]
	if not source and info.attachments[1] and info.attachments[1].Parent and info.attachments[1].Parent:IsA("BasePart") then
		source = info.attachments[1].Parent
	end
	local opts = { thickness = o.thickness, align = o.align, source = source }
	local ok, made
	if o.mode == "triangle" then
		local p = info.points
		ok, made = attempt(Modeling.triangleFill, p[1], p[2], p[3], opts)
	elseif o.mode == "polygon" then
		ok, made = attempt(Modeling.polygonFill, info.points, opts)
	else
		ok, made = attempt(Modeling.gapFill, info.parts[1], info.parts[2], { thickness = o.thickness })
	end
	if ok then
		select(made)
		done(string.format("Am umplut cu %s.", plural(#made, "piesă", "piese")))
	end
end

-- Repetare: linear, radial, arc, along a path
function Panel:renderArray(root, info)
	local o = self.op.array
	self:fold(root, "build.op.array", "Repetare", false, function(body)
		UI.segmented(body, {
			{ value = "linear", label = "Liniar", tip = "Copii în linie, una lângă alta" },
			{ value = "radial", label = "Radial", tip = "Copii în cerc, în jurul unui centru" },
			{ value = "arc", label = "Arc", tip = "Fiecare copie continuă precedenta și se rotește pe muchia comună (ziduri curbe, inele)" },
			{ value = "path", label = "Traseu", tip = "Copii ale primului obiect de-a lungul reperelor selectate după el" },
		}, o.mode, function(v)
			o.mode = v
			self:refresh()
		end)
		if o.mode ~= "path" then
			UI.scrub(body, "Total", o.count, function(v)
				o.count = math.floor(v + 0.5)
			end, { min = 2, max = 500, step = 1, decimals = 0, labelWidth = LABEL_W, tip = "Numărul total de obiecte, cu originalul" })
		end
		if o.mode == "linear" then
			UI.segmented(row(body, "Axă", { tip = "Axa obiectului (a lumii pentru mai multe obiecte)" }), AXES, o.axis, function(v)
				o.axis = v
				self:refresh()
			end)
			UI.scrub(body, "Spațiu", o.gap, function(v)
				o.gap = v
			end, { min = -1000, max = 1000, step = 0.25, decimals = 2, unit = "studs", labelWidth = LABEL_W,
				tip = "Golul dintre copii (0 = lipite)" })
		elseif o.mode == "radial" then
			UI.scrub(body, "Rază", o.radius, function(v)
				o.radius = v
			end, { min = 0, max = 2000, step = 0.5, decimals = 2, unit = "studs", labelWidth = LABEL_W,
				tip = "Distanța până la centru, în fața obiectului" })
			UI.slider(row(body, "Unghi"), o.angle, function(v)
				o.angle = v
			end, { min = 15, max = 360, step = 5, decimals = 0, unit = "°", field = true, valueWidth = 64 })
		elseif o.mode == "arc" then
			UI.scrub(body, "Unghi", o.arcAngle, function(v)
				o.arcAngle = v
			end, { min = -180, max = 180, step = 1, decimals = 1, unit = "°", labelWidth = LABEL_W, tip = "Rotația fiecărei copii" })
			UI.segmented(row(body, "Axă", { tip = "Axa obiectului în jurul căreia se rotește" }), AXES, o.arcAxis, function(v)
				o.arcAxis = v
				self:refresh()
			end)
			UI.scrub(body, "Rază", o.arcRadius, function(v)
				o.arcRadius = v
			end, { min = 0, max = 1000, step = 0.25, decimals = 2, unit = "studs", labelWidth = LABEL_W,
				tip = "Mută pivotul în afară (curbă mai largă)" })
		else
			UI.scrub(body, "Pas", o.spacing, function(v)
				o.spacing = v
			end, { min = 0.25, max = 1000, step = 0.25, decimals = 2, unit = "studs", labelWidth = LABEL_W,
				tip = "Distanța dintre copii pe traseu" })
			UI.switch(row(body, "Aliniază"), o.align, function(v)
				o.align = v
			end, { tip = "Copiile se rotesc după direcția traseului" })
		end
		local ok, hint
		if o.mode == "path" then
			ok = #info.objects >= 1 and #info.points >= 3
			hint = ok and plural(#info.points - 1, "reper", "repere") or "Selectează obiectul, apoi cel puțin 2 repere."
		else
			ok = #info.objects >= 1
			hint = ok and (plural(#info.objects, "obiect", "obiecte") .. " × " .. o.count) or "Selectează ce repeți."
		end
		actionRow(body, hint, { { text = "Repetă", disabled = not ok, tip = not ok and hint or nil, onClick = function()
			self:runArray(info)
		end } })
	end)
end

-- the step of a linear array: along the axis of the object (of the world for several), the object's size + the gap
local function linearOffset(objs, axis, gap)
	local dir, extent
	if #objs == 1 then
		local obj = objs[1]
		local cf, size
		if obj:IsA("Model") then
			cf, size = obj:GetBoundingBox()
		else
			cf, size = obj.CFrame, obj.Size
		end
		dir = cf:VectorToWorldSpace(AXIS_VECTOR[axis])
		extent = (axis == "X" and size.X) or (axis == "Y" and size.Y) or size.Z
	else
		local lo, hi = worldBox(objs)
		dir = AXIS_VECTOR[axis]
		local d = hi - lo
		extent = (axis == "X" and d.X) or (axis == "Y" and d.Y) or d.Z
	end
	return dir * (extent + gap)
end

function Panel:runArray(info)
	local o = self.op.array
	local ok, made
	if o.mode == "linear" then
		ok, made = attempt(Modeling.linearArray, info.objects, { count = o.count, offset = linearOffset(info.objects, o.axis, o.gap) })
	elseif o.mode == "radial" then
		ok, made = attempt(Modeling.radialArray, info.objects, { count = o.count, radius = o.radius, angle = o.angle })
	elseif o.mode == "arc" then
		ok, made = attempt(Modeling.arcArray, info.objects, { count = o.count, angle = o.arcAngle, axis = o.arcAxis,
			radius = o.arcRadius })
	else
		local template = info.objects[1]
		local points = table.move(info.points, 2, #info.points, 1, {})
		ok, made = attempt(Modeling.pathArray, { template }, points, o.spacing, { align = o.align })
	end
	if ok then
		done(string.format("Am făcut %s.", plural(#made, "copie", "copii")))
	end
end

-- Oglindire
function Panel:renderMirror(root, info)
	local o = self.op.mirror
	self:fold(root, "build.op.mirror", "Oglindire", false, function(body)
		UI.segmented(row(body, "Plan", { tip = "Normala planului de oglindire (prin centrul grupului)" }), AXES, o.axis, function(v)
			o.axis = v
			self:refresh()
		end)
		UI.switch(row(body, "Copie"), o.copy, function(v)
			o.copy = v
		end, { tip = "Pornit: originalul rămâne și se adaugă imaginea în oglindă" })
		local ok = #info.objects >= 1
		local hint = ok and ("Prin centrul selecției, pe " .. o.axis) or "Selectează ce oglindești."
		actionRow(body, hint, { { text = "Oglindește", disabled = not ok, tip = not ok and hint or nil, onClick = function()
			local okRun, made, warnings = attempt(Modeling.mirror, info.objects, o.axis, { copy = o.copy })
			if okRun then
				if o.copy then
					select(made)
				end
				if warnings and #warnings > 0 then
					done("Oglindit, cu observații: " .. warnings[1], "warning")
				else
					done(string.format("Am oglindit %s.", plural(#made, "obiect", "obiecte")))
				end
			end
		end } })
	end)
end

-- Aliniere: align on an axis, distribute
function Panel:renderAlign(root, info)
	local o = self.op.align
	self:fold(root, "build.op.align", "Aliniere", false, function(body)
		UI.segmented(row(body, "Axă"), AXES, o.axis, function(v)
			o.axis = v
			self:refresh()
		end)
		UI.segmented(row(body, "Spre"), {
			{ value = "min", label = "Min" }, { value = "center", label = "Centru" }, { value = "max", label = "Max" },
		}, o.mode, function(v)
			o.mode = v
			self:refresh()
		end)
		UI.segmented(row(body, "Față de"), {
			{ value = "group", label = "Grup", tip = "Marginea / centrul întregii selecții" },
			{ value = "first", label = "Primul", tip = "Primul obiect selectat stă pe loc" },
		}, o.to, function(v)
			o.to = v
			self:refresh()
		end)
		local n = #info.objects
		local hint = n >= 2 and plural(n, "obiect", "obiecte") or "Selectează cel puțin 2 obiecte."
		actionRow(body, hint, {
			{ text = "Distribuie", disabled = n < 3, tip = n < 3 and "Distribuirea are nevoie de cel puțin 3 obiecte."
				or "Spații egale între obiecte, pe axă", onClick = function()
				if attempt(Modeling.distribute, info.objects, o.axis, "gap") then
					done(string.format("Am distribuit %s pe %s.", plural(n, "obiect", "obiecte"), o.axis))
				end
			end },
			{ text = "Aliniază", disabled = n < 2, tip = n < 2 and hint or nil, onClick = function()
				if attempt(Modeling.align, info.objects, o.axis, o.mode, o.to == "first" and "first" or nil) then
					done(string.format("Am aliniat %s pe %s.", plural(n, "obiect", "obiecte"), o.axis))
				end
			end },
		})
	end)
end

-- Plasare: drop to the surface, snap to the grid, extend a part up to another one
local FACES = {
	{ value = "auto", label = "Automat", hint = "spre țintă" },
	{ value = "Top", label = "Sus", hint = "+Y" }, { value = "Bottom", label = "Jos", hint = "−Y" },
	{ value = "Right", label = "Dreapta", hint = "+X" }, { value = "Left", label = "Stânga", hint = "−X" },
	{ value = "Back", label = "Spate", hint = "+Z" }, { value = "Front", label = "Față", hint = "−Z" },
}

-- the face of `part` that looks most toward `target`
local function faceToward(part, target)
	local dir = target.Position - part.Position
	if dir.Magnitude < 1e-6 then
		return "Top"
	end
	dir = dir.Unit
	local cf = part.CFrame
	local normals = { Right = cf.RightVector, Left = -cf.RightVector, Top = cf.UpVector, Bottom = -cf.UpVector,
		Back = -cf.LookVector, Front = cf.LookVector }
	local best, bestDot = "Top", -math.huge
	for _, name in { "Right", "Left", "Top", "Bottom", "Back", "Front" } do
		local d = normals[name]:Dot(dir)
		if d > bestDot then
			best, bestDot = name, d
		end
	end
	return best
end

function Panel:renderPlace(root, info)
	local o = self.op.place
	self:fold(root, "build.op.place", "Plasare", true, function(body)
		local n = #info.objects
		subhead(body, "Pe suprafață")
		UI.switch(row(body, "Pe pantă"), o.normal, function(v)
			o.normal = v
		end, { tip = "Obiectele se înclină după suprafața de dedesubt" })
		actionRow(body, n >= 1 and "Coboară pe ce e dedesubt" or "Selectează ce așezi.", { { text = "Lasă jos", disabled = n < 1,
			onClick = function()
				local ok, moved, missed = attempt(Modeling.dropToSurface, info.objects, { alignToNormal = o.normal })
				if ok then
					local text = string.format("Am așezat %s.", plural(#moved, "obiect", "obiecte"))
					if missed and missed > 0 then
						text ..= " " .. plural(missed, "obiect nu are", "obiecte nu au") .. " nimic dedesubt."
					end
					done(text, missed and missed > 0 and "warning" or "success")
				end
			end } })
		UI.spacer(body, SPACE.xs)
		subhead(body, "La grilă")
		UI.scrub(body, "Grilă", o.grid, function(v)
			o.grid = v
		end, { min = 0.05, max = 64, step = 0.25, decimals = 2, unit = "studs", labelWidth = LABEL_W })
		UI.scrub(body, "Rotație", o.rotation, function(v)
			o.rotation = v
		end, { min = 0, max = 90, step = 1, decimals = 0, unit = "°", labelWidth = LABEL_W,
			tip = "Pasul de rotație (0 = rotația rămâne)" })
		actionRow(body, n >= 1 and plural(n, "obiect", "obiecte") or "Selectează ce aliniezi.", { { text = "La grilă",
			disabled = n < 1, onClick = function()
				local opts = o.rotation > 0 and { rotation = o.rotation } or nil
				if attempt(Modeling.snapToGrid, info.objects, o.grid, opts) then
					done(string.format("Am aliniat la grila de %s studs.", fmt(o.grid)))
				end
			end } })
		UI.spacer(body, SPACE.xs)
		subhead(body, "Extinde până la")
		UI.dropdown(row(body, "Față", { tip = "Fața primei piese care se întinde" }), FACES, o.face, function(v)
			o.face = v
			self:refresh()
		end, { menuWidth = 170 })
		UI.dropdown(row(body, "Atinge cu", { tip = "Cum ajunge o față înclinată la planul țintei: toate colțurile = fără gol, "
			.. "primul colț = fără suprapunere" }), {
			{ value = "center", label = "Centrul feței" }, { value = "outer", label = "Toate colțurile" },
			{ value = "inner", label = "Primul colț" },
		}, o.extend, function(v)
			o.extend = v
			self:refresh()
		end, { menuWidth = 180 })
		local ok = #info.parts == 2
		local hint = ok and string.format("%s până la %s", info.parts[1].Name, info.parts[2].Name)
			or "Selectează piesa, apoi ținta (2 piese)."
		actionRow(body, hint, { { text = "Extinde", disabled = not ok, tip = not ok and hint or nil, onClick = function()
			local part, target = info.parts[1], info.parts[2]
			local face = o.face == "auto" and faceToward(part, target) or o.face
			local okRun, _, dist = attempt(Modeling.extendTo, part, face, target, { mode = o.extend })
			if okRun then
				done(string.format("Am extins „%s” cu %s studs.", part.Name, fmt(dist or 0)))
			end
		end } })
	end)
end

-- Împrăștiere: copies of the selected models over the selected parts (or an area in front of the camera)
function Panel:renderScatter(root, info)
	local o = self.op.scatter
	self:fold(root, "build.op.scatter", "Împrăștiere", true, function(body)
		UI.slider(row(body, "Densitate", { tip = "Obiecte la 10 000 studs² de suprafață" }), o.density, function(v)
			o.density = v
		end, { min = 1, max = 400, step = 1, decimals = 0, field = true, valueWidth = 64 })
		UI.scrub(body, "Distanță min.", o.minDistance, function(v)
			o.minDistance = v
		end, { min = 0, max = 200, step = 0.25, decimals = 2, unit = "studs", labelWidth = LABEL_W })
		local area = row(body, "Scară", { tip = "Fiecare copie primește o scară între aceste valori" })
		UI.number(area, o.scaleMin, function(v)
			o.scaleMin = math.min(v, o.scaleMax)
		end, { min = 0.1, max = 10, step = 0.05, decimals = 2 })
		UI.number(area, o.scaleMax, function(v)
			o.scaleMax = math.max(v, o.scaleMin)
		end, { min = 0.1, max = 10, step = 0.05, decimals = 2 })
		UI.switch(row(body, "Rotație"), o.rotate, function(v)
			o.rotate = v
		end, { tip = "O rotație la întâmplare în jurul verticalei" })
		UI.switch(row(body, "Pe pantă"), o.normal, function(v)
			o.normal = v
		end, { tip = "Copiile se înclină după suprafață" })
		local surfaces = info.parts
		if #surfaces == 0 then
			UI.scrub(body, "Zonă", o.area, function(v)
				o.area = v
			end, { min = 8, max = 2000, step = 1, decimals = 0, unit = "studs", labelWidth = LABEL_W,
				tip = "Latura pătratului din fața camerei (nicio piesă selectată ca suprafață)" })
		end
		local seedArea, seedRight = row(body, "Seed", { rightWidth = UI.H, tip = "Același seed dă aceeași așezare" })
		UI.number(seedArea, o.seed, function(v)
			o.seed = math.max(0, math.floor(v + 0.5))
		end, { min = 0, max = 2147483646, step = 1, decimals = 0 })
		UI.iconButton(seedRight, "refresh", function()
			o.seed = math.random(1, 99999)
			self:refresh()
		end, { tip = "Seed aleator" })
		local ok = #info.models >= 1
		local hint
		if not ok then
			hint = "Selectează modelele de împrăștiat (și piesele-suprafață)."
		elseif #surfaces > 0 then
			hint = string.format("%s pe %s", plural(#info.models, "șablon", "șabloane"), plural(#surfaces, "suprafață", "suprafețe"))
		else
			hint = string.format("%s, în fața camerei", plural(#info.models, "șablon", "șabloane"))
		end
		actionRow(body, hint, { { text = "Împrăștie", disabled = not ok, tip = not ok and hint or nil, onClick = function()
			self:runScatter(info)
		end } })
	end)
end

function Panel:runScatter(info)
	local o = self.op.scatter
	local where
	if #info.parts > 0 then
		where = info.parts
	else
		local ok, cf = pcall(Modeling.placement, o.area / 2 + 20)
		where = { cframe = (ok and cf or CFrame.new()) * CFrame.new(0, 20, 0), size = Vector3.new(o.area, 80, o.area) }
	end
	local okRun, container, report = attempt(Modeling.scatter, where, info.models, { density = o.density, minDistance = o.minDistance,
		randomRotation = o.rotate, scaleRange = { o.scaleMin, o.scaleMax }, alignToNormal = o.normal, seed = o.seed })
	if okRun then
		select({ container })
		local text = string.format("Am împrăștiat %s.", plural(report.placed, "obiect", "obiecte"))
		if report.missed > 0 then
			text ..= " " .. plural(report.missed, "poziție a ratat", "poziții au ratat") .. " suprafața."
		end
		done(text)
	end
end

-- Curbe: a rail / pipe / cable / road / wall / fence through the selected points
local SPLINE_KINDS = {
	{ value = "rail", label = "Șină" }, { value = "pipe", label = "Țeavă" }, { value = "cable", label = "Cablu" },
	{ value = "road", label = "Drum" }, { value = "wall", label = "Zid" }, { value = "fence", label = "Gard" },
}

function Panel:renderSpline(root, info)
	local o = self.op.spline
	self:fold(root, "build.op.spline", "Curbe", true, function(body)
		UI.dropdown(row(body, "Tip"), SPLINE_KINDS, o.kind, function(v)
			o.kind = v
			self:refresh()
		end)
		UI.scrub(body, "Pas", o.spacing, function(v)
			o.spacing = v
		end, { min = 0.5, max = 100, step = 0.25, decimals = 2, unit = "studs", labelWidth = LABEL_W,
			tip = "Lungimea unui segment (mai mic = mai lin, mai multe piese)" })
		if o.kind == "road" or o.kind == "wall" then
			UI.scrub(body, "Lățime", o.width, function(v)
				o.width = v
			end, { min = 0.25, max = 200, step = 0.25, decimals = 2, unit = "studs", labelWidth = LABEL_W })
		end
		if o.kind == "wall" or o.kind == "fence" then
			UI.scrub(body, "Înălțime", o.height, function(v)
				o.height = v
			end, { min = 0.5, max = 100, step = 0.25, decimals = 2, unit = "studs", labelWidth = LABEL_W })
		end
		if o.kind == "rail" or o.kind == "pipe" or o.kind == "cable" then
			UI.scrub(body, "Diametru", o.diameter, function(v)
				o.diameter = v
			end, { min = 0.05, max = 40, step = 0.05, decimals = 2, unit = "studs", labelWidth = LABEL_W })
		end
		UI.switch(row(body, "Închisă"), o.closed, function(v)
			o.closed = v
		end, { tip = "Curba se întoarce la primul punct" })
		local ok = #info.points >= 2
		local hint = ok and (plural(#info.points, "punct", "puncte") .. ", în ordinea selecției") or "Selectează cel puțin 2 repere, în ordine."
		actionRow(body, hint, { { text = "Construiește", disabled = not ok, tip = not ok and hint or nil, onClick = function()
			local opts = { spacing = o.spacing, closed = o.closed or nil }
			if o.kind == "road" then
				opts.width = o.width
			elseif o.kind == "wall" then
				opts.width, opts.thickness, opts.height = o.width, o.height, o.height / 2
			elseif o.kind == "fence" then
				opts.params = { height = o.height }
			else
				opts.diameter = o.diameter
			end
			local okRun, made, report = attempt(Modeling.alongSpline, o.kind, info.points, opts)
			if okRun and made then
				select({ made })
				done(string.format("Am construit „%s” (%s).", made.Name, plural(report and report.parts or 0, "piesă", "piese")))
			end
		end } })
	end)
end

-- Solide: union / subtraction (CSG)
function Panel:renderSolid(root, info)
	local o = self.op.solid
	self:fold(root, "build.op.solid", "Solide", true, function(body)
		UI.switch(row(body, "Păstrează"), o.keep, function(v)
			o.keep = v
		end, { tip = "Piesele originale (unire) sau cele care taie (scădere) rămân în joc" })
		local canMerge = info.partCount >= 2
		local base = info.objects[1]
		local canCut = base ~= nil and base:IsA("BasePart") and #info.objects >= 2
		local hint = canMerge and plural(info.partCount, "piesă", "piese") or "Selectează cel puțin 2 piese."
		actionRow(body, hint, {
			{ text = "Scade", disabled = not canCut, tip = canCut and ("„" .. base.Name .. "” e baza; restul taie")
				or "Selectează întâi piesa de bază, apoi piesele care taie.", onClick = function()
				local cutters = table.move(info.objects, 2, #info.objects, 1, {})
				local result, err = Modeling.subtract(base, cutters, { keepCutters = o.keep })
				if not result then
					UI.toast((err or "Scăderea a eșuat.") .. " Încearcă mai puține piese sau forme mai simple.", "error")
					return
				end
				select({ result })
				done(string.format("Am scăzut %s din „%s”.", plural(#cutters, "piesă", "piese"), result.Name))
			end },
			{ text = "Unește", disabled = not canMerge, tip = not canMerge and hint or "Un singur UnionOperation", onClick = function()
				local result, err = Modeling.merge(info.objects, { keep = o.keep })
				if not result then
					UI.toast((err or "Unirea a eșuat.") .. " Încearcă mai puține piese sau forme mai simple.", "error")
					return
				end
				select({ result })
				done(string.format("Am unit %s.", plural(info.partCount, "piesă", "piese")))
			end },
		})
	end)
end

-- Optimizare: a dry run first (a table of what would change), then apply
local REPORT_ROWS = {
	{ "anchored", "Piese de ancorat" },
	{ "canCollide", "Decor fără coliziune" },
	{ "castShadow", "Fără umbre (piese mici)" },
	{ "renderFidelity", "Randare Performance" },
	{ "collisionFidelity", "Coliziune Box" },
}

function Panel:optimizeOptions(dryRun)
	local o = self.op.optimize
	local opts = { anchorAll = o.anchorAll, canCollideDecor = o.decor, castShadowSmall = o.shadows,
		collisionFidelityBox = o.fidelity, dryRun = dryRun }
	if not o.fidelity then
		opts.renderFidelity = false -- keep the render fidelity (nil = the engine's default, Performance)
	end
	return opts
end

function Panel:renderOptimize(root, info)
	local o = self.op.optimize
	self:fold(root, "build.op.optimize", "Optimizare", true, function(body)
		local function option(key, text, tip)
			UI.toggle(body, o[key], function(v)
				o[key] = v
				self.optReport = nil
				self:refresh()
			end, text, { tip = tip })
		end
		option("anchorAll", "Ancorează tot", "Anchored = true pe toate piesele")
		option("decor", "Decor fără coliziune", "Piesele mai mici de 1 stud nu mai au coliziune / atingere")
		option("shadows", "Fără umbre la piese mici", "Piesele mai mici de 1.5 studs nu mai aruncă umbre")
		option("fidelity", "Mesh-uri și uniri ușoare", "RenderFidelity Performance, coliziune Box la decor")
		local report = self.optReport
		if report then
			UI.spacer(body, SPACE.xs)
			self:reportTable(body, report)
		end
		local ok = #info.objects >= 1
		local buttons = { { text = "Analizează", disabled = not ok, tip = "Arată ce s-ar schimba, fără să schimbe nimic",
			onClick = function()
				local okRun, r = attempt(Modeling.optimize, info.objects, self:optimizeOptions(true))
				if okRun then
					self.optReport = r
					self:refresh()
				end
			end } }
		if report then
			local changes = report.changes or 0
			table.insert(buttons, { text = "Aplică", style = changes > 0 and "primary" or nil,
				disabled = changes == 0, tip = changes == 0 and "Nimic de schimbat" or "Un singur Ctrl+Z", onClick = function()
					local okRun, r = attempt(Modeling.optimize, info.objects, self:optimizeOptions(false))
					if okRun then
						self.optReport = nil
						done(string.format("Am aplicat %s pe %s.", plural(r.changes, "modificare", "modificări"),
							plural(r.parts, "piesă", "piese")))
						self:refresh()
					end
				end })
		end
		local hint = ok and (report and plural(report.parts, "piesă analizată", "piese analizate") or plural(info.partCount, "piesă", "piese"))
			or "Selectează modelul de optimizat."
		actionRow(body, hint, buttons)
	end)
end

-- the dry-run report: one line per kind of change, the total, the suggestions
function Panel:reportTable(body, report)
	local function line(label, value, strong)
		local frame = UI.make("Frame", { Name = "ReportRow", Parent = body, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20) })
		local l = UI.label(frame, label, { dim = not strong, medium = strong, height = 20 })
		l.Size = UDim2.new(1, -64, 0, 20)
		local v = UI.label(frame, tostring(value), { medium = strong, align = Enum.TextXAlignment.Right, height = 20,
			color = (value == 0 and not strong) and "textDisabled" or "text" })
		v.AnchorPoint = Vector2.new(1, 0)
		v.Position = UDim2.fromScale(1, 0)
		v.Size = UDim2.new(0, 60, 0, 20)
		return frame
	end
	for _, r in REPORT_ROWS do
		line(r[2], report[r[1]] or 0)
	end
	UI.divider(body)
	line("Proprietăți de schimbat", report.changes or 0, true)
	for _, s in report.suggestions or {} do
		UI.note(body, UI.escape(s))
	end
end

function Panel:destroy()
	self.dead = true
	self:clearGhost()
	for _, c in self.conns do
		pcall(function()
			c:Disconnect()
		end)
	end
	self.conns = {}
end

return Panel
