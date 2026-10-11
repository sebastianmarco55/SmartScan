--[[ LostCube Modeling - fast 3D modeling in Studio (plugin-only engine; the panel and Claude's tools call this API).
Every operation that changes the place is ONE undo step (ChangeHistoryService) and returns what it created / changed.
Bad input raises an error with a Romanian message and changes nothing; engine failures that are not the caller's fault
(CSG, EditableMesh) return nil + message (the step is rolled back). `targets` = a BasePart / Model / Folder, a list of
them, or nil = the current Selection. Vectors may be Vector3 or { x, y, z }. The maths lives in Geometry (pure,
unit-tested), the procedural builders in Generators, meshes in Mesh, the build format in Spec (Spec.DOC).
Algorithms reimplemented from published ideas: triangle -> 2 wedges and GapFill / ResizeAlign (stravant, MIT),
Part -> Terrain (Quenty, MIT); see docs/modeling-research.md.

	local Modeling = require(LostCube.Modeling)
	-- fills (GapFill / triangle fill)
	Modeling.triangleFill(a, b, c, opts)         -> { WedgePart }  any 3D triangle as 1-2 wedges; opts: thickness (0.2),
	                                                align "center"|"front"|"back", color, material, source (a part whose
	                                                look is copied), parent
	Modeling.polygonFill(points, opts)           -> { WedgePart }  any simple polygon (ear clipping), opts as above
	Modeling.gapFill(edgeA, edgeB, opts)         -> { BasePart }   edges { Vector3, Vector3 }, or two parts (their facing
	                                                edges); parallel edges: one block + a wedge per end
	Modeling.partEdges(part), Modeling.closestEdges(partA, partB)
	-- arrays (count = TOTAL items, the original included)
	Modeling.linearArray(targets, { offset, count })                      -> copies
	Modeling.radialArray(targets, { count, center? | radius?, axis = Y, angle = 360 })
	Modeling.arcArray(targets, { count, angle = 15, axis = "Y", radius = 0, length?, pivot? })  Archimedes: each copy
	                                                continues the previous one and turns around the shared edge
	Modeling.pathArray(targets, points | spline, spacing, { align = true, tension = 0 })
	-- transforms
	Modeling.mirror(targets, plane, { copy = true }) -> { Instance }, warnings   plane "X"|"Y"|"Z" (through the group's
	                                                centre) or { point, normal }; wedges, corner wedges and attachments
	                                                are re-oriented so the result is a true mirror image
	Modeling.align(targets, axis, mode, target?)    mode "min"|"center"|"max"; target: number | Instance | "first"
	Modeling.distribute(targets, axis, mode?)       mode "gap" (equal spaces, default) | "center"
	Modeling.snapToGrid(targets, grid, { rotation? })
	Modeling.dropToSurface(targets, { alignToNormal, offset, maxDistance }) -> moved, missed
	Modeling.extendTo(part, face, target, { mode = "center"|"outer"|"inner", targetFace? }) -> part, distance  (ResizeAlign;
	                                                target: a part, { part, face } or { point, normal })
	Modeling.scatter(surfaces | { cframe, size }, templates, { count | density (per 10 000 stud^2), minDistance = 2,
	                 randomRotation, scaleRange, weights, alignToNormal, maxSlope = 30, sink, seed, parent })
	                                             -> Model, report   (Brushtool; deterministic for a seed)
	Modeling.toTerrain(targets, { material?, keep? }) -> fills       parts -> smooth terrain
	-- curves
	Modeling.spline(points, { tension, alpha = 0.5, segments, closed }) -> { at, tangent, atDistance, points(spacing),
	                                                cframes(spacing), length }   (centripetal Catmull-Rom)
	Modeling.alongSpline(kind | template, points, opts) -> Model, report   kind "rail"|"pipe"|"cable"|"road"|"wall"|"fence";
	                                                opts: spacing, width, thickness, height, diameter, color, material
	-- solids and hygiene
	Modeling.merge(targets, opts) -> UnionOperation | nil, err   (chunks of 150)   Modeling.subtract(base, cutters, opts)
	Modeling.optimize(root, opts) -> report         Modeling.weldAll(root, opts) -> welds   Modeling.group(targets, name)
	-- generators (Modeling.GENERATORS: keys, labels, parameter schemas; Modeling.SCALE: Roblox scale constants)
	Modeling.generate(kind, params, parent?, cframe?) -> Model?, report      Modeling.regenerate(model, params?)
	Modeling.generatorHelp(kind?) -> text           Modeling.placement(distance?) -> CFrame on the ground in front of the camera
	-- procedural meshes: parts (wedges) by default; mode "mesh" / "auto" uses EditableMesh -> MeshPart when the
	-- experience allows it (such a MeshPart may not survive saving the place without an upload)
	Modeling.mesh(kind, params, parent?, cframe?, { mode = "parts"|"auto"|"mesh" }) -> Instance, report
	                 kind "lathe" { profile, segments }, "extrude" { polygon, depth, bevel }, "rock" { seed, detail, size },
	                 "terrain" { heights | seed, size, resolution, amplitude }; params.color / params.material
	Modeling.rebuildMesh(instance, opts) -> Instance, report       Modeling.meshAvailable() -> bool, reason
	-- spec (the compact format for Claude: Modeling.SPEC_DOC) and readback
	Modeling.buildFromSpec(spec | json, parent?, cframe?) -> Model, report     Modeling.validateSpec(spec) -> ok, errors, parts
	Modeling.describe(instance | list, { maxParts = 500, budget? }) -> spec (+ bounds, count, summary)
	Modeling.summary(instance | list, { budget? }) -> text   (bbox, counts, materials, floating / default-gray / unanchored)
	Modeling.selfCheck() -> { wedge, cornerWedge, editableMesh, notes }   runtime check of the shape conventions
]]
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")

local Geometry = require(script.Geometry)
local Generators = require(script.Generators)
local Mesh = require(script.Mesh)
local Spec = require(script.Spec)
local V, M, F = Geometry.V, Geometry.M, Geometry.F

local Modeling = {}
Modeling.VERSION = "2.1.0"
Modeling.Geometry = Geometry
Modeling.Generators = Generators
Modeling.Mesh = Mesh
Modeling.Spec = Spec
Modeling.SCALE = Generators.SCALE
Modeling.LIMITS = Spec.LIMITS
Modeling.GENERATORS = Generators.LIST
Modeling.SPEC_DOC = Spec.DOC

-- ---------------------------------------------------------------------------------------------
-- conversions (Roblox datatypes <-> Geometry's plain tables)
-- ---------------------------------------------------------------------------------------------
local function toV3(v)
	return Vector3.new(v[1], v[2], v[3])
end
local function fromV3(v)
	return { v.X, v.Y, v.Z }
end
local function toCF(f)
	local p, r = f.p, f.r
	return CFrame.new(p[1], p[2], p[3], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9])
end
local function fromCF(cf)
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	return { p = { x, y, z }, r = { r00, r01, r02, r10, r11, r12, r20, r21, r22 } }
end
Modeling.toVector3, Modeling.fromVector3, Modeling.toCFrame, Modeling.fromCFrame = toV3, fromV3, toCF, fromCF

-- Vector3 or { x, y, z } -> plain vector; `what` names the argument in the error
local function vecArg(v, what)
	if typeof(v) == "Vector3" then
		return fromV3(v)
	end
	local out = V.from(v)
	if not out then
		error("„" .. what .. "” trebuie să fie un Vector3 (sau { x, y, z }).", 0)
	end
	return out
end

local function cframeArg(cf, what)
	if cf == nil then
		return CFrame.new()
	end
	if typeof(cf) ~= "CFrame" then
		error("„" .. (what or "cframe") .. "” trebuie să fie un CFrame.", 0)
	end
	return cf
end

local function toColor3(c)
	if typeof(c) == "Color3" then
		return c
	end
	local hex = Spec.hexColor(c)
	if hex then
		return Color3.fromHex(hex)
	end
	return nil
end

local function materialItem(m)
	if typeof(m) == "EnumItem" then
		return m
	end
	if type(m) ~= "string" then
		return nil
	end
	local ok, item = pcall(function()
		return (Enum.Material :: any)[m]
	end)
	return ok and item or nil
end

-- part materials (Air and Water are terrain-only)
local function isPartMaterial(name)
	return name ~= "Air" and name ~= "Water" and materialItem(name) ~= nil
end
local function isTerrainMaterial(name)
	return materialItem(name) ~= nil
end
-- the checker Generators / Spec get: forTerrain = the value goes to Terrain:Fill*
local function materialCheck(name, forTerrain)
	if forTerrain then
		return isTerrainMaterial(name)
	end
	return isPartMaterial(name)
end
Modeling.isMaterial = materialCheck

-- ---------------------------------------------------------------------------------------------
-- undo: one recording per operation (nested calls join the outer one)
-- ---------------------------------------------------------------------------------------------
local depth = 0
local function record(name, fn, ...)
	if depth > 0 then
		return fn(...)
	end
	local okBegin, id = pcall(ChangeHistoryService.TryBeginRecording, ChangeHistoryService, "LostCube: " .. name)
	depth += 1
	local results = table.pack(pcall(fn, ...))
	depth -= 1
	if okBegin and id then
		-- a failed step is rolled back, a good one becomes one Ctrl+Z
		local op = results[1] and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
		pcall(ChangeHistoryService.FinishRecording, ChangeHistoryService, id, op)
	end
	if not results[1] then
		error(results[2], 0)
	end
	return table.unpack(results, 2, results.n)
end

-- engine failures become nil + message (the step was rolled back)
local function soft(name, fn, ...)
	local results = table.pack(pcall(record, name, fn, ...))
	if not results[1] then
		-- drop a "Script.Path:12: " prefix (our own messages have none)
		return nil, (string.gsub(tostring(results[2]), "^[^%s:]+:%d+: ", ""))
	end
	return table.unpack(results, 2, results.n)
end

-- ---------------------------------------------------------------------------------------------
-- targets
-- ---------------------------------------------------------------------------------------------
local function isPart(x)
	return typeof(x) == "Instance" and x:IsA("BasePart") and not x:IsA("Terrain")
end
local function isObject(x)
	return isPart(x) or (typeof(x) == "Instance" and x:IsA("Model"))
end

-- top-level BaseParts / Models of the input (Folders expand to their children), no duplicates, no descendants of
-- another item of the list
local function objectsOf(input)
	if input == nil then
		input = Selection:Get()
	elseif typeof(input) == "Instance" then
		input = { input }
	end
	if type(input) ~= "table" then
		error("Țintele trebuie să fie o piesă, un model sau o listă de piese / modele.", 0)
	end
	local list, seen = {}, {}
	local function add(x)
		if isObject(x) then
			if not seen[x] then
				seen[x] = true
				table.insert(list, x)
			end
		elseif typeof(x) == "Instance" and (x:IsA("Folder") or x:IsA("WorldModel")) then
			for _, c in x:GetChildren() do
				add(c)
			end
		end
	end
	for _, x in input do
		add(x)
	end
	local out = {}
	for _, x in list do
		local nested = false
		local p = x.Parent
		while p do
			if seen[p] then
				nested = true
				break
			end
			p = p.Parent
		end
		if not nested then
			table.insert(out, x)
		end
	end
	return out
end

local function partsOf(input)
	local out, seen = {}, {}
	for _, obj in objectsOf(input) do
		if isPart(obj) then
			if not seen[obj] then
				seen[obj] = true
				table.insert(out, obj)
			end
		else
			for _, d in obj:GetDescendants() do
				if isPart(d) and not seen[d] then
					seen[d] = true
					table.insert(out, d)
				end
			end
		end
	end
	return out
end

local function requireObjects(input, minimum)
	local objs = objectsOf(input)
	if #objs < (minimum or 1) then
		if (minimum or 1) <= 1 then
			error("Selectează cel puțin o piesă sau un model.", 0)
		end
		error("Selectează cel puțin " .. minimum .. " piese sau modele.", 0)
	end
	return objs
end

function Modeling.selection()
	return objectsOf(nil)
end

-- the box of an object: frame + size (Models: GetBoundingBox)
local function boxOf(obj)
	if obj:IsA("Model") then
		local cf, size = obj:GetBoundingBox()
		return fromCF(cf), fromV3(size)
	end
	return fromCF(obj.CFrame), fromV3(obj.Size)
end

local function worldBounds(obj)
	local f, size = boxOf(obj)
	return Geometry.bounds(Geometry.boxCorners(f, size))
end

-- the shape name of a part ("Block", "Wedge", ...) or nil for meshes / unions / others
local function shapeOf(part)
	if part:IsA("WedgePart") then
		return "Wedge"
	elseif part:IsA("CornerWedgePart") then
		return "CornerWedge"
	elseif part:IsA("Part") then
		return part.Shape.Name
	end
	return nil
end
Modeling.shapeOf = shapeOf

-- ---------------------------------------------------------------------------------------------
-- pieces -> Instances
-- ---------------------------------------------------------------------------------------------
local CLASS = { Block = "Part", Cylinder = "Part", Ball = "Part", Wedge = "WedgePart", CornerWedge = "CornerWedgePart" }
local DEFAULT_COLOR = Spec.DEFAULT_COLOR

local function clampSize(size)
	local out = {}
	for i = 1, 3 do
		out[i] = math.max(Geometry.MIN_SIZE, math.min(Geometry.MAX_SIZE, size[i]))
	end
	return out
end

-- one piece (frame already in world space) -> a new, unparented part
local function makePart(pc, world)
	local className = (pc.class == "Seat") and "Seat" or CLASS[pc.shape] or "Part"
	local part = Instance.new(className)
	if (className == "Part" or className == "Seat") and pc.shape ~= "Block" then
		part.Shape = (Enum.PartType :: any)[pc.shape]
	end
	part.Name = pc.name or Spec.DEFAULT_NAME[pc.shape] or "Part"
	part.Anchored = pc.anchored ~= false
	part.Size = toV3(clampSize(pc.size))
	part.CFrame = toCF(world)
	part.Color = toColor3(pc.color) or (Color3.fromHex(DEFAULT_COLOR) :: any)
	part.Material = materialItem(pc.material) or Enum.Material.Plastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if pc.transparency and pc.transparency > 0 then
		part.Transparency = pc.transparency
	end
	if pc.reflectance and pc.reflectance > 0 then
		part.Reflectance = pc.reflectance
	end
	if pc.canCollide == false then
		part.CanCollide = false
		part.CanTouch = false
	end
	if pc.castShadow == false then
		part.CastShadow = false
	end
	if pc.light then
		local light = Instance.new("PointLight")
		light.Range = pc.light.range or 16
		light.Brightness = pc.light.brightness or 1
		light.Color = toColor3(pc.light.color) or Color3.new(1, 1, 1)
		light.Parent = part
	end
	return part
end

-- pieces (local to `origin`, a frame) -> parts parented to `parent` (which is not in the workspace yet: one
-- replication / physics update for the whole model). Big builds yield now and then so Studio stays responsive.
local function buildPieces(pieces, parent, origin)
	local out = {}
	for i, pc in pieces do
		local part = makePart(pc, F.mul(origin, pc.cf))
		part.Parent = parent
		table.insert(out, part)
		if i % 500 == 0 then
			task.wait()
		end
	end
	return out
end

local function newModel(name, parent, origin)
	local model = Instance.new("Model")
	model.Name = name
	model:SetAttribute("LC_Tool", "LostCube")
	model.WorldPivot = toCF(origin)
	return model
end

-- the look of a fill: opts.color / opts.material, or copied from opts.source
local function lookFrom(opts)
	local look = {}
	local src = opts.source
	if isPart(src) then
		look.color = src.Color
		look.material = src.Material
		look.transparency = src.Transparency
		look.reflectance = src.Reflectance
	end
	if opts.color ~= nil then
		look.color = toColor3(opts.color) or error("Culoarea trebuie să fie un Color3 sau „#rrggbb”.", 0)
	end
	if opts.material ~= nil then
		look.material = materialItem(opts.material) or error("Material necunoscut: " .. tostring(opts.material), 0)
	end
	return look
end

local function withLook(pieces, look, name)
	for _, pc in pieces do
		for k, v in look do
			pc[k] = v
		end
		pc.name = pc.name or name
	end
	return pieces
end

local function defaultParent(opts, fallback)
	if opts.parent ~= nil then
		if typeof(opts.parent) ~= "Instance" then
			error("„parent” trebuie să fie un Instance.", 0)
		end
		return opts.parent
	end
	return fallback or workspace
end

-- ---------------------------------------------------------------------------------------------
-- 1. fills
-- ---------------------------------------------------------------------------------------------
function Modeling.triangleFill(a, b, c, opts)
	opts = opts or {}
	local wedges, err = Geometry.triangleWedges(vecArg(a, "a"), vecArg(b, "b"), vecArg(c, "c"), {
		thickness = opts.thickness, align = opts.align })
	if not wedges then
		error(err, 0)
	end
	withLook(wedges, lookFrom(opts), "Umplere")
	return record("umplere triunghi", function()
		return buildPieces(wedges, defaultParent(opts, opts.source and opts.source.Parent), F.IDENTITY)
	end)
end

function Modeling.polygonFill(points, opts)
	opts = opts or {}
	if type(points) ~= "table" then
		error("Poligonul trebuie să fie o listă de puncte (Vector3).", 0)
	end
	local pts = {}
	for i, p in points do
		pts[i] = vecArg(p, "points[" .. i .. "]")
	end
	local wedges, err = Geometry.polygonWedges(pts, { thickness = opts.thickness, align = opts.align })
	if not wedges then
		error(err, 0)
	end
	withLook(wedges, lookFrom(opts), "Umplere")
	return record("umplere poligon", function()
		return buildPieces(wedges, defaultParent(opts, opts.source and opts.source.Parent), F.IDENTITY)
	end)
end

-- the 12 edges of a part's box: { { Vector3, Vector3 } }
function Modeling.partEdges(part)
	if not isPart(part) then
		error("partEdges are nevoie de o piesă.", 0)
	end
	local f, size = fromCF(part.CFrame), fromV3(part.Size)
	local h = V.scale(size, 0.5)
	local edges = {}
	for axis = 1, 3 do
		local j, k = axis % 3 + 1, (axis + 1) % 3 + 1
		for _, sj in { -1, 1 } do
			for _, sk in { -1, 1 } do
				local a, b = { 0, 0, 0 }, { 0, 0, 0 }
				a[axis], b[axis] = -h[axis], h[axis]
				a[j], b[j] = sj * h[j], sj * h[j]
				a[k], b[k] = sk * h[k], sk * h[k]
				table.insert(edges, { toV3(F.point(f, a)), toV3(F.point(f, b)) })
			end
		end
	end
	return edges
end

-- the pair of edges (one per part) that face each other best: close and parallel, not touching; on a tie the longest
-- pair (two parallel parts: the long edges, not the short ones)
function Modeling.closestEdges(partA, partB)
	local best, bestScore, bestLen
	for _, ea in Modeling.partEdges(partA) do
		for _, eb in Modeling.partEdges(partB) do
			local a1, a2, b1, b2 = fromV3(ea[1]), fromV3(ea[2]), fromV3(eb[1]), fromV3(eb[2])
			local da, db = V.sub(a2, a1), V.sub(b2, b1)
			local la, lb = V.len(da), V.len(db)
			local parallel = math.abs(V.dot(da, db)) / math.max(1e-9, la * lb)
			local dist = V.dist(V.mid(a1, a2), V.mid(b1, b2))
			if dist > 1e-3 then
				local score = dist + (1 - parallel) * (la + lb)
				local length = math.min(la, lb)
				if not bestScore or score < bestScore - 1e-6 or (score < bestScore + 1e-6 and length > bestLen) then
					best, bestScore, bestLen = { ea, eb }, score, length
				end
			end
		end
	end
	return best[1], best[2]
end

function Modeling.gapFill(edgeA, edgeB, opts)
	opts = opts or {}
	if isPart(edgeA) and isPart(edgeB) then
		opts.source = opts.source or edgeA
		edgeA, edgeB = Modeling.closestEdges(edgeA, edgeB)
	end
	if type(edgeA) ~= "table" or type(edgeB) ~= "table" then
		error("gapFill are nevoie de două muchii { Vector3, Vector3 } (sau două piese).", 0)
	end
	local ea = { vecArg(edgeA[1], "edgeA[1]"), vecArg(edgeA[2], "edgeA[2]") }
	local eb = { vecArg(edgeB[1], "edgeB[1]"), vecArg(edgeB[2], "edgeB[2]") }
	local pieces, err = Geometry.gapFill(ea, eb, { thickness = opts.thickness, align = opts.align })
	if not pieces then
		error(err, 0)
	end
	withLook(pieces, lookFrom(opts), "Umplere")
	return record("umplere spațiu", function()
		return buildPieces(pieces, defaultParent(opts, opts.source and opts.source.Parent), F.IDENTITY)
	end)
end

-- ---------------------------------------------------------------------------------------------
-- 2. arrays
-- ---------------------------------------------------------------------------------------------
local function cloneMoved(objs, transforms)
	local out = {}
	for _, tf in transforms do
		local cf = toCF(tf)
		for _, obj in objs do
			local copy = obj:Clone()
			if not copy then
				error("„" .. obj.Name .. "” nu poate fi copiat (Archivable = false).", 0)
			end
			copy:PivotTo(cf * obj:GetPivot())
			copy.Parent = obj.Parent
			table.insert(out, copy)
		end
	end
	return out
end

-- the group's oriented box in the first object's pivot rotation
local function groupBox(objs)
	if #objs == 1 then
		local f, size = boxOf(objs[1])
		return { cf = f, size = size }
	end
	local rot = fromCF(objs[1]:GetPivot()).r
	local boxes = {}
	for _, obj in objs do
		local f, size = boxOf(obj)
		table.insert(boxes, { cf = f, size = size })
	end
	local cf, size = Geometry.orientedBounds(rot, boxes)
	return { cf = cf, size = size }
end

local function groupCenter(objs)
	local lo, hi
	for _, obj in objs do
		local b = worldBounds(obj)
		if not lo then
			lo, hi = b.min, b.max
		else
			lo = { math.min(lo[1], b.min[1]), math.min(lo[2], b.min[2]), math.min(lo[3], b.min[3]) }
			hi = { math.max(hi[1], b.max[1]), math.max(hi[2], b.max[2]), math.max(hi[3], b.max[3]) }
		end
	end
	return V.mid(lo, hi), lo, hi
end

function Modeling.linearArray(targets, opts)
	opts = opts or {}
	local objs = requireObjects(targets)
	local transforms, err = Geometry.linearTransforms(vecArg(opts.offset, "offset"), opts.count or 2)
	if not transforms then
		error(err, 0)
	end
	return record("matrice liniară", cloneMoved, objs, transforms)
end

function Modeling.radialArray(targets, opts)
	opts = opts or {}
	local objs = requireObjects(targets)
	local center
	if opts.center ~= nil then
		center = vecArg(opts.center, "center")
	else
		local pivot = objs[1]:GetPivot()
		center = fromV3(pivot.Position + pivot.LookVector * (opts.radius or 10))
	end
	local axis = opts.axis ~= nil and vecArg(opts.axis, "axis") or { 0, 1, 0 }
	local transforms, err = Geometry.radialTransforms(center, axis, opts.count or 8, opts.angle or 360)
	if not transforms then
		error(err, 0)
	end
	return record("matrice circulară", cloneMoved, objs, transforms)
end

function Modeling.arcArray(targets, opts)
	opts = opts or {}
	local objs = requireObjects(targets)
	local transforms, err = Geometry.arcTransforms(groupBox(objs), {
		axis = opts.axis, angle = opts.angle, count = opts.count, radius = opts.radius, length = opts.length,
		pivot = opts.pivot ~= nil and vecArg(opts.pivot, "pivot") or nil })
	if not transforms then
		error(err, 0)
	end
	return record("matrice în arc", cloneMoved, objs, transforms)
end

local function splineOf(curve, opts)
	if type(curve) == "table" and curve.raw and curve.raw.frames then
		return curve.raw
	end
	if type(curve) ~= "table" then
		error("Curba trebuie să fie o listă de puncte sau un Modeling.spline.", 0)
	end
	local pts = {}
	for i, p in curve do
		pts[i] = vecArg(p, "points[" .. i .. "]")
	end
	local sp, err = Geometry.spline(pts, { tension = opts and opts.tension, closed = opts and opts.closed })
	if not sp then
		error(err, 0)
	end
	return sp
end

function Modeling.pathArray(targets, curve, spacing, opts)
	opts = opts or {}
	local objs = requireObjects(targets)
	if type(spacing) ~= "number" or spacing <= 0 then
		error("Distanța dintre copii trebuie să fie un număr pozitiv.", 0)
	end
	local sp = splineOf(curve, opts)
	local transforms = Spec.pathTransforms(sp, spacing, fromCF(objs[1]:GetPivot()), opts.align ~= false)
	if #transforms * #objs > 2000 then
		error("Prea multe copii (" .. #transforms * #objs .. "; maxim 2000).", 0)
	end
	return record("copii pe traseu", cloneMoved, objs, transforms)
end

-- ---------------------------------------------------------------------------------------------
-- 3. transforms
-- ---------------------------------------------------------------------------------------------
local function planeArg(plane, objs)
	if plane == "X" or plane == "Y" or plane == "Z" then
		local n = Geometry.unitAxis(Geometry.AXIS[plane])
		return (groupCenter(objs)), n
	end
	if type(plane) == "table" and plane.normal ~= nil then
		local n = vecArg(plane.normal, "plane.normal")
		if V.len(n) < 1e-9 then
			error("Normala planului nu poate fi zero.", 0)
		end
		return plane.point ~= nil and vecArg(plane.point, "plane.point") or (groupCenter(objs)), V.unit(n) :: any
	end
	error("Planul trebuie să fie \"X\", \"Y\", \"Z\" sau { point = Vector3, normal = Vector3 }.", 0)
end

-- mirrors one part in place (and its attachments); returns false when the result is only approximate
local function mirrorPart(part, q, n)
	local shape = shapeOf(part)
	local before = fromCF(part.CFrame)
	local f, size, exact = Geometry.mirrorFrame(before, fromV3(part.Size), shape or "Mesh", q, n)
	-- new = reflect * old * fix, so the local reflection is fix = old^-1 * reflect * new (reflect^-1 = reflect)
	local fix = M.mul(M.transpose(before.r), M.mul(Geometry.reflection(n), f.r))
	part.Size = toV3(size)
	part.CFrame = toCF(f)
	for _, child in part:GetChildren() do
		if child:IsA("Attachment") then
			local a = fromCF(child.CFrame)
			-- world = old * a  ->  reflect(world) = new * (fix * a * fix)
			child.CFrame = toCF({ p = M.apply(fix, a.p), r = M.mul(fix, M.mul(a.r, fix)) })
		end
	end
	return exact
end

function Modeling.mirror(targets, plane, opts)
	opts = opts or {}
	local objs = requireObjects(targets)
	local q, n = planeArg(plane, objs)
	return record("oglindire", function()
		local out, warnings = {}, {}
		for _, obj in objs do
			local item = obj
			if opts.copy ~= false then
				item = obj:Clone()
				if not item then
					error("„" .. obj.Name .. "” nu poate fi copiat (Archivable = false).", 0)
				end
				item.Parent = obj.Parent
			end
			local parts = isPart(item) and { item } or {}
			local welds = {}
			if not isPart(item) then
				for _, d in item:GetDescendants() do
					if isPart(d) then
						table.insert(parts, d)
					elseif d:IsA("WeldConstraint") and d.Enabled then
						d.Enabled = false -- moving one welded part would drag the others
						table.insert(welds, d)
					elseif d:IsA("JointInstance") then
						table.insert(warnings, "„" .. d.Name .. "” (" .. d.ClassName .. "): C0 / C1 nu sunt oglindite; refă sudura.")
					end
				end
			end
			for _, part in parts do
				if not mirrorPart(part, q, n) then
					table.insert(warnings, "„" .. part.Name .. "” (" .. part.ClassName .. "): un mesh nu se poate inversa; e corect doar dacă e simetric.")
				end
			end
			for _, w in welds do
				w.Enabled = true
			end
			if item:IsA("Model") then
				local pivot = Geometry.mirrorFrame(fromCF(item.WorldPivot), { 1, 1, 1 }, "Block", q, n)
				item.WorldPivot = toCF(pivot)
			end
			table.insert(out, item)
		end
		return out, warnings
	end)
end

local function axisArg(axis)
	if axis ~= "X" and axis ~= "Y" and axis ~= "Z" then
		error("Axa trebuie să fie \"X\", \"Y\" sau \"Z\".", 0)
	end
	return axis
end

local function moveBy(obj, offset)
	if offset[1] ~= 0 or offset[2] ~= 0 or offset[3] ~= 0 then
		obj:PivotTo(obj:GetPivot() + toV3(offset))
	end
end

function Modeling.align(targets, axis, mode, target)
	local objs = requireObjects(targets)
	axisArg(axis)
	local boxes = {}
	for i, obj in objs do
		boxes[i] = worldBounds(obj)
	end
	local value = target
	if target == "first" then
		value = nil
		local only = Geometry.alignOffsets({ boxes[1] }, axis, mode)
		if not only then
			error("Modul trebuie să fie min, center sau max.", 0)
		end
		local i = Geometry.AXIS[axis]
		local b = boxes[1]
		value = (mode == "max" and b.max[i]) or (mode == "center" and (b.min[i] + b.max[i]) / 2) or b.min[i]
	elseif isObject(target) then
		local b = worldBounds(target)
		local i = Geometry.AXIS[axis]
		value = (mode == "max" and b.max[i]) or (mode == "center" and (b.min[i] + b.max[i]) / 2) or b.min[i]
	elseif target ~= nil and type(target) ~= "number" then
		error("Ținta alinierii: un număr, o piesă / un model sau \"first\".", 0)
	end
	local offsets, err = Geometry.alignOffsets(boxes, axis, mode, value)
	if not offsets then
		error(err, 0)
	end
	return record("aliniere " .. axis, function()
		for i, obj in objs do
			moveBy(obj, offsets[i])
		end
		return objs
	end)
end

function Modeling.distribute(targets, axis, mode)
	local objs = requireObjects(targets, 3)
	axisArg(axis)
	local boxes = {}
	for i, obj in objs do
		boxes[i] = worldBounds(obj)
	end
	local offsets, err = Geometry.distributeOffsets(boxes, axis, mode)
	if not offsets then
		error(err, 0)
	end
	return record("distribuire " .. axis, function()
		for i, obj in objs do
			moveBy(obj, offsets[i])
		end
		return objs
	end)
end

function Modeling.snapToGrid(targets, grid, opts)
	opts = opts or {}
	local objs = requireObjects(targets)
	if type(grid) ~= "number" or grid <= 0 then
		error("Pasul grilei trebuie să fie un număr pozitiv (studs).", 0)
	end
	if opts.rotation ~= nil and (type(opts.rotation) ~= "number" or opts.rotation <= 0) then
		error("Pasul de rotație trebuie să fie un număr pozitiv (grade).", 0)
	end
	return record("aliniere la grilă", function()
		for _, obj in objs do
			obj:PivotTo(toCF(Geometry.snapFrame(fromCF(obj:GetPivot()), grid, opts.rotation)))
		end
		return objs
	end)
end

-- the rotation that turns `from` onto `to` (unit vectors)
local function rotationBetween(from, to)
	local axis = V.cross(from, to)
	local s = V.len(axis)
	local c = V.dot(from, to)
	if s < 1e-9 then
		if c > 0 then
			return M.IDENTITY
		end
		return M.axisAngle(V.perpendicular(from), math.pi)
	end
	return M.axisAngle(V.scale(axis, 1 / s), math.atan2(s, c))
end

function Modeling.dropToSurface(targets, opts)
	opts = opts or {}
	local objs = requireObjects(targets)
	local maxDistance = opts.maxDistance or 512
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = objs
	-- the highest hit under the bottom face (centre + corners), cast from the top of the object
	local plans = {}
	for _, obj in objs do
		local b = worldBounds(obj)
		local cx, cz = (b.min[1] + b.max[1]) / 2, (b.min[3] + b.max[3]) / 2
		local hx, hz = (b.max[1] - b.min[1]) * 0.45, (b.max[3] - b.min[3]) * 0.45
		local best, centerHit
		for k, d in { { 0, 0 }, { -hx, -hz }, { hx, -hz }, { -hx, hz }, { hx, hz } } do
			local origin = Vector3.new(cx + d[1], b.max[2] + 0.01, cz + d[2])
			local hit = workspace:Raycast(origin, Vector3.new(0, -(b.max[2] - b.min[2] + maxDistance), 0), params)
			if hit then
				if k == 1 then
					centerHit = hit
				end
				if not best or hit.Position.Y > best.Position.Y then
					best = hit
				end
			end
		end
		if best then
			table.insert(plans, { obj = obj, y = best.Position.Y, bottom = { cx, b.min[2], cz }, normal = (centerHit or best).Normal })
		end
	end
	local missed = #objs - #plans
	if #plans == 0 then
		error("Nu am găsit nicio suprafață sub obiectele alese (în " .. maxDistance .. " studs).", 0)
	end
	return record("lăsat pe suprafață", function()
		local moved = {}
		for _, plan in plans do
			local obj = plan.obj
			local dy = plan.y - plan.bottom[2] + (opts.offset or 0)
			local pivot = obj:GetPivot()
			if opts.alignToNormal then
				-- lift onto the contact point, then turn the object's up onto the surface normal around that point
				local up = fromV3(pivot.UpVector)
				local r = rotationBetween(V.unit(up, { 0, 1, 0 }) :: any, V.unit(fromV3(plan.normal), { 0, 1, 0 }) :: any)
				local contact = { plan.bottom[1], plan.y, plan.bottom[3] }
				local turn = { p = V.sub(contact, M.apply(r, contact)), r = r }
				local lifted = F.translate(fromCF(pivot), { 0, dy, 0 })
				obj:PivotTo(toCF(F.mul(turn, lifted)))
			else
				obj:PivotTo(pivot + Vector3.new(0, dy, 0))
			end
			table.insert(moved, obj)
		end
		return moved, missed
	end)
end

local FACE_NAMES = { "Right", "Left", "Top", "Bottom", "Back", "Front" }
local function faceArg(face, what)
	if typeof(face) == "EnumItem" then
		face = face.Name
	end
	if not Geometry.FACES[face] then
		error("„" .. what .. "” trebuie să fie o față: " .. table.concat(FACE_NAMES, ", ") .. " (sau Enum.NormalId).", 0)
	end
	return face
end

-- target: BasePart (+ opts.targetFace, default: its face that looks back at ours), { part, face } or { point, normal }
function Modeling.extendTo(part, face, target, opts)
	opts = opts or {}
	if not isPart(part) then
		error("extendTo are nevoie de o piesă.", 0)
	end
	face = faceArg(face, "face")
	local f, size = fromCF(part.CFrame), fromV3(part.Size)
	local corners, n = Geometry.boxFace(f, size, face)
	local q, m
	local tpart, tface = target, opts.targetFace
	if type(target) == "table" and target.part ~= nil then
		tpart, tface = target.part, target.face
	end
	if isPart(tpart) then
		local tf, tsize = fromCF(tpart.CFrame), fromV3(tpart.Size)
		if tface == nil then
			local best
			for _, name in FACE_NAMES do
				local _, normal = Geometry.boxFace(tf, tsize, name)
				local d = V.dot(normal, n)
				if not best or d < best then
					best, tface = d, name
				end
			end
		end
		tface = faceArg(tface, "targetFace")
		local tc, tn = Geometry.boxFace(tf, tsize, tface)
		q = V.scale(V.add(V.add(tc[1], tc[2]), V.add(tc[3], tc[4])), 0.25)
		m = tn
	elseif type(target) == "table" and target.point ~= nil and target.normal ~= nil then
		q, m = vecArg(target.point, "target.point"), V.unit(vecArg(target.normal, "target.normal"), nil)
		if not m then
			error("Normala țintei nu poate fi zero.", 0)
		end
	else
		error("Ținta: o piesă, { part, face } sau { point, normal }.", 0)
	end
	local dist, err = Geometry.extendDistance(corners, n, q, m, opts.mode or "center")
	if not dist then
		error(err, 0)
	end
	local newFrame, newSize = Geometry.resizeFace(f, size, face, dist)
	if not newFrame then
		error(newSize, 0)
	end
	return record("extindere până la țintă", function()
		part.Size = toV3(newSize)
		part.CFrame = toCF(newFrame)
		return part, dist
	end)
end

-- ---------------------------------------------------------------------------------------------
-- 4. scatter (Brushtool)
-- ---------------------------------------------------------------------------------------------
-- opts: count (or density = items per 10 000 stud^2 of the area, default 50), minDistance (2), randomRotation (true =
-- any yaw, a number = +- that many degrees / 2, false = none), scaleRange ({ 1, 1 }; 0.8-1.25 looks natural),
-- weights ({ number } per template), alignToNormal (false), maxSlope (30 degrees), sink (0..1 of the template's
-- height pushed under the surface; 0.2-0.3 for rocks), seed (1), parent, name. Same seed + same surfaces = same result.
function Modeling.scatter(surfaces, templates, opts)
	opts = opts or {}
	local tmpl = objectsOf(templates)
	if #tmpl == 0 then
		error("Alege cel puțin un șablon (piesă sau model) de împrăștiat.", 0)
	end
	local seed = opts.seed or 1
	local rng = Geometry.rng(seed)
	local lo, hi
	local params = RaycastParams.new()
	local region = type(surfaces) == "table" and surfaces.cframe ~= nil and surfaces.size ~= nil
	if region then
		local f, size = fromCF(cframeArg(surfaces.cframe, "cframe")), vecArg(surfaces.size, "size")
		local b = Geometry.bounds(Geometry.boxCorners(f, size))
		lo, hi = b.min, b.max
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = tmpl
	else
		local surf = objectsOf(surfaces)
		if #surf == 0 then
			error("Alege suprafața (piese / modele) sau o regiune { cframe, size }.", 0)
		end
		local _, l, h = groupCenter(surf)
		lo, hi = l, h
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = surf
	end
	local area = math.max(1, (hi[1] - lo[1]) * (hi[3] - lo[3]))
	local count = opts.count or math.floor(area / 10000 * (opts.density or 50) + 0.5)
	if type(count) ~= "number" or count < 1 or count > 5000 then
		error("Numărul de obiecte trebuie să fie între 1 și 5000 (zona e prea mică sau densitatea prea mare).", 0)
	end
	local weights = opts.weights
	local totalWeight = 0
	for i = 1, #tmpl do
		local w = weights and weights[i] or 1
		if type(w) ~= "number" or w < 0 then
			error("Greutățile șabloanelor trebuie să fie numere >= 0.", 0)
		end
		totalWeight += w
	end
	if totalWeight <= 0 then
		error("Cel puțin un șablon trebuie să aibă greutate > 0.", 0)
	end
	local function pick(r)
		local acc = r * totalWeight
		for i = 1, #tmpl do
			acc -= weights and weights[i] or 1
			if acc < 0 then
				return i
			end
		end
		return #tmpl
	end
	local minDistance = opts.minDistance or 2
	local scaleRange = opts.scaleRange or { 1, 1 }
	local minUp = math.cos(math.rad(opts.maxSlope or 30)) - 1e-6
	local points = Geometry.poissonSample(rng, lo[1], lo[3], hi[1], hi[3], count, minDistance)
	-- every template's bottom-centre relative to its pivot (world axes) and its height
	local bottoms, heights = {}, {}
	for i, t in tmpl do
		local b = worldBounds(t)
		local bottom = { (b.min[1] + b.max[1]) / 2, b.min[2], (b.min[3] + b.max[3]) / 2 }
		bottoms[i] = V.sub(fromV3(t:GetPivot().Position), bottom)
		heights[i] = b.max[2] - b.min[2]
	end
	local plans = {}
	for _, pt in points do
		-- the random choices are drawn for every point (hit or not), so a miss does not shift the next ones
		local which = pick(rng.next())
		local yaw = 0
		if opts.randomRotation ~= false then
			local maxYaw = type(opts.randomRotation) == "number" and opts.randomRotation or 360
			yaw = math.rad(rng.range(-maxYaw / 2, maxYaw / 2))
		end
		local s = rng.range(scaleRange[1], scaleRange[2])
		local origin = Vector3.new(pt[1], hi[2] + 1, pt[2])
		local hit = workspace:Raycast(origin, Vector3.new(0, -(hi[2] - lo[2] + 2), 0), params)
		if hit and hit.Normal.Y >= minUp then
			table.insert(plans, { which = which, yaw = yaw, scale = s, pos = fromV3(hit.Position), normal = fromV3(hit.Normal) })
		end
	end
	if #plans == 0 then
		error("Nicio poziție validă: razele nu au atins suprafața sau panta e peste " .. (opts.maxSlope or 30) .. "°.", 0)
	end
	return record("împrăștiere", function()
		local container = Instance.new("Model")
		container.Name = opts.name or "Împrăștiere"
		container:SetAttribute("LC_Tool", "LostCube")
		container:SetAttribute("LC_Seed", seed)
		local placed = {}
		for _, plan in plans do
			local t = tmpl[plan.which]
			local copy = t:Clone()
			if copy then
				local base = t:GetPivot()
				local rot = M.ry(plan.yaw)
				if opts.alignToNormal then
					rot = M.mul(rotationBetween({ 0, 1, 0 }, V.unit(plan.normal, { 0, 1, 0 }) :: any), rot)
				end
				if plan.scale ~= 1 then
					if copy:IsA("Model") then
						copy:ScaleTo(copy:GetScale() * plan.scale)
					else
						copy.Size = copy.Size * plan.scale
					end
				end
				local lift = V.scale(bottoms[plan.which], plan.scale)
				if opts.sink then
					lift = V.sub(lift, { 0, heights[plan.which] * plan.scale * opts.sink, 0 })
				end
				local target = { p = V.add(plan.pos, M.apply(rot, lift)), r = M.mul(rot, fromCF(base).r) }
				copy:PivotTo(toCF(target))
				copy.Parent = container
				table.insert(placed, copy)
			end
		end
		container.Parent = defaultParent(opts, workspace)
		return container, { placed = #placed, missed = #points - #plans, requested = count, seed = seed }
	end)
end

-- ---------------------------------------------------------------------------------------------
-- 5. splines
-- ---------------------------------------------------------------------------------------------
function Modeling.spline(points, opts)
	local sp = splineOf(points, opts)
	local s = { raw = sp, length = sp.length }
	function s.at(t)
		return toV3(sp.at(t))
	end
	function s.tangent(t)
		return toV3(sp.tangent(t))
	end
	function s.atDistance(d)
		return toV3(sp.atDistance(d))
	end
	function s.points(spacing)
		local out = {}
		for _, smp in sp.samples(spacing) do
			table.insert(out, toV3(smp.p))
		end
		return out
	end
	function s.cframes(spacing, up)
		local out = {}
		for _, fr in sp.frames(spacing, up and fromV3(up) or nil) do
			table.insert(out, toCF(fr))
		end
		return out
	end
	return s
end

local ALONG = {
	rail = { kind = "rod", diameter = 0.4, height = 3, caps = true, color = "#3a3a3a", material = "Metal", name = "Șină" },
	pipe = { kind = "rod", diameter = 2, height = 1, caps = true, color = "#8a8f95", material = "Metal", name = "Țeavă" },
	cable = { kind = "rod", diameter = 0.2, height = 0, caps = false, color = "#202020", material = "SmoothPlastic", name = "Cablu" },
	road = { kind = "strip", width = 16, thickness = 1, height = 0.5, color = "#3b3b3e", material = "Asphalt", name = "Drum" },
	wall = { kind = "strip", width = 1, thickness = 8, height = 4, color = "#8f8a80", material = "Cobblestone", name = "Zid" },
}

-- pieces along a curve (pure; used by alongSpline): rods with ball joints, or strips with wedge fills on the outside of
-- every turn so the edge stays continuous
local function alongPieces(sp, cfg, opts)
	local spacing = opts.spacing or 4
	local samples = sp.samples(spacing)
	local out = {}
	local look = { color = opts.color or cfg.color, material = opts.material or cfg.material }
	local up = { 0, opts.height or cfg.height, 0 }
	local pts = {}
	for i, smp in samples do
		pts[i] = V.add(smp.p, up)
	end
	if cfg.kind == "rod" then
		local d = opts.diameter or cfg.diameter
		for i = 1, #pts - 1 do
			local rod = Geometry.rod(pts[i], pts[i + 1], d)
			if rod then
				rod.size[1] += cfg.caps and 0 or d * 0.5
				table.insert(out, rod)
			end
		end
		if cfg.caps then
			for i = 2, #pts - 1 do
				table.insert(out, { shape = "Ball", size = { d, d, d }, cf = F.new(pts[i]) })
			end
		end
	else
		local w, h = opts.width or cfg.width, opts.thickness or cfg.thickness
		local dirs = {}
		for i = 1, #pts - 1 do
			local beam = Geometry.beam(pts[i], pts[i + 1], w, h)
			if beam then
				table.insert(out, beam)
			end
			dirs[i] = V.unit(V.sub(pts[i + 1], pts[i]), { 0, 0, -1 })
		end
		for i = 2, #pts - 1 do
			local d0, d1 = dirs[i - 1], dirs[i]
			if d0 and d1 then
				local turn = V.cross(d0, d1)
				local flat0 = V.unit({ d0[1], 0, d0[3] }, nil)
				local flat1 = V.unit({ d1[1], 0, d1[3] }, nil)
				if V.len(turn) > 1e-4 and flat0 and flat1 then
					-- the outside of the turn: a left turn ((d0 x d1).y > 0) opens its gap on the right (flat x up)
					local side = turn[2] > 0 and 1 or -1
					local r0 = V.scale(V.cross(flat0, { 0, 1, 0 }), side * w / 2)
					local r1 = V.scale(V.cross(flat1, { 0, 1, 0 }), side * w / 2)
					local wedges = Geometry.triangleWedges(pts[i], V.add(pts[i], r0), V.add(pts[i], r1), { thickness = h })
					for _, pc in (wedges or {}) do
						table.insert(out, pc)
					end
				end
			end
		end
	end
	return withLook(out, look, cfg.name)
end
Modeling.alongPieces = alongPieces

function Modeling.alongSpline(what, points, opts)
	opts = opts or {}
	local sp = splineOf(points, opts)
	if what == "fence" then
		local pts = {}
		for _, p in sp.samples(opts.spacing or 6) do
			table.insert(pts, p.p)
		end
		local params = table.clone(opts.params or {})
		params.points = pts
		return Modeling.generate("fence", params, opts.parent, CFrame.new())
	end
	if isObject(what) then
		local copies = Modeling.pathArray({ what }, { raw = sp }, opts.spacing or 4, opts)
		return copies, { parts = #copies }
	end
	local cfg = ALONG[what]
	if not cfg then
		error("Tip necunoscut „" .. tostring(what) .. "”: rail, pipe, cable, road, wall, fence sau o piesă / un model șablon.", 0)
	end
	local pieces = alongPieces(sp, cfg, opts)
	if #pieces > Spec.LIMITS.MAX_PARTS then
		error("Prea multe piese (" .. #pieces .. "); mărește distanța dintre puncte (spacing).", 0)
	end
	return record("construit pe traseu", function()
		local model = newModel(opts.name or cfg.name, nil, F.IDENTITY)
		buildPieces(pieces, model, F.IDENTITY)
		model.Parent = defaultParent(opts, workspace)
		return model, { parts = #pieces, length = sp.length }
	end)
end

-- ---------------------------------------------------------------------------------------------
-- 6. solids and hygiene
-- ---------------------------------------------------------------------------------------------
local CSG_CHUNK = 150
Modeling.CSG_CHUNK = CSG_CHUNK

local function fidelity(opts)
	local cf = opts.collisionFidelity and (Enum.CollisionFidelity :: any)[opts.collisionFidelity] or Enum.CollisionFidelity.Default
	local rf = opts.renderFidelity and (Enum.RenderFidelity :: any)[opts.renderFidelity] or Enum.RenderFidelity.Automatic
	return cf, rf
end

function Modeling.merge(targets, opts)
	opts = opts or {}
	local parts = partsOf(targets)
	if #parts < 2 then
		return nil, "Unirea are nevoie de cel puțin 2 piese."
	end
	local cf, rf = fidelity(opts)
	local function unite(list)
		local base = list[1]
		local others = table.move(list, 2, #list, 1, {})
		local ok, union = pcall(base.UnionAsync, base, others, cf, rf)
		if not ok or not union then
			error("Unirea (UnionAsync) a eșuat: " .. tostring(union), 0)
		end
		return union
	end
	return soft("unire piese", function()
		local base = parts[1]
		-- big selections are united in chunks of 150, then the chunks (one huge CSG call tends to fail)
		local level = parts
		local made = {}
		while #level > 1 do
			local nextLevel = {}
			for i = 1, #level, CSG_CHUNK do
				local chunk = table.move(level, i, math.min(#level, i + CSG_CHUNK - 1), 1, {})
				if #chunk == 1 then
					table.insert(nextLevel, chunk[1])
				else
					local union = unite(chunk)
					table.insert(made, union)
					table.insert(nextLevel, union)
				end
			end
			level = nextLevel
		end
		local union = level[1]
		for _, u in made do
			if u ~= union then
				u:Destroy()
			end
		end
		union.Name = opts.name or "Unire"
		union.Anchored = base.Anchored
		union.Parent = base.Parent
		if opts.decor then
			union.CollisionFidelity = Enum.CollisionFidelity.Box
		end
		if not opts.keep then
			for _, p in parts do
				p:Destroy()
			end
		end
		return union
	end)
end

function Modeling.subtract(base, cutters, opts)
	opts = opts or {}
	if not isPart(base) then
		return nil, "Scăderea are nevoie de o piesă de bază."
	end
	local cuts = partsOf(cutters)
	if #cuts == 0 then
		return nil, "Alege cel puțin o piesă care taie."
	end
	local cf, rf = fidelity(opts)
	return soft("scădere piese", function()
		local ok, union = pcall(base.SubtractAsync, base, cuts, cf, rf)
		if not ok or not union then
			error("Scăderea (SubtractAsync) a eșuat: " .. tostring(union), 0)
		end
		union.Name = base.Name
		union.Anchored = base.Anchored
		union.Parent = base.Parent
		base:Destroy()
		if not opts.keepCutters then
			for _, p in cuts do
				p:Destroy()
			end
		end
		return union
	end)
end

-- performance hygiene of a build. opts (defaults): anchorAll = true, decorSize = 1 (parts smaller than this on every
-- axis stop colliding / touching: canCollideDecor = true), shadowSize = 1.5 (smaller parts stop casting shadows:
-- castShadowSmall = true), renderFidelity = "Performance" (MeshParts / unions; false = keep), collisionFidelityBox = true
-- (non-colliding MeshParts / unions get Box collisions), dryRun = false (report only)
function Modeling.optimize(root, opts)
	opts = opts or {}
	local parts = partsOf(root)
	if #parts == 0 then
		error("Nu am găsit nicio piesă de optimizat.", 0)
	end
	local decor = opts.decorSize or 1
	local shadow = opts.shadowSize or 1.5
	local report = { parts = #parts, meshes = 0, unions = 0, anchored = 0, canCollide = 0, castShadow = 0,
		renderFidelity = 0, collisionFidelity = 0, suggestions = {} }
	local changes = {}
	local small = 0
	for _, p in parts do
		local size = p.Size
		local biggest = math.max(size.X, size.Y, size.Z)
		local isMesh = p:IsA("MeshPart")
		local isUnion = p:IsA("PartOperation")
		if isMesh then
			report.meshes += 1
		elseif isUnion then
			report.unions += 1
		end
		if opts.anchorAll ~= false and not p.Anchored then
			table.insert(changes, { p, "Anchored", true })
			report.anchored += 1
		end
		local isDecor = biggest < decor
		if isDecor then
			small += 1
		end
		if opts.canCollideDecor ~= false and isDecor and (p.CanCollide or p.CanTouch) then
			table.insert(changes, { p, "CanCollide", false })
			table.insert(changes, { p, "CanTouch", false })
			report.canCollide += 1
		end
		if opts.castShadowSmall ~= false and biggest < shadow and p.CastShadow then
			table.insert(changes, { p, "CastShadow", false })
			report.castShadow += 1
		end
		if isMesh or isUnion then
			local want = opts.renderFidelity == nil and "Performance" or opts.renderFidelity
			if want and p.RenderFidelity.Name ~= want then
				table.insert(changes, { p, "RenderFidelity", (Enum.RenderFidelity :: any)[want] })
				report.renderFidelity += 1
			end
			if opts.collisionFidelityBox ~= false and (not p.CanCollide or isDecor) and p.CollisionFidelity ~= Enum.CollisionFidelity.Box then
				table.insert(changes, { p, "CollisionFidelity", Enum.CollisionFidelity.Box })
				report.collisionFidelity += 1
			end
		end
	end
	if small > 50 then
		table.insert(report.suggestions, small .. " piese foarte mici: unește-le (Modeling.merge) sau fă-le un singur MeshPart.")
	end
	if #parts > 5000 then
		table.insert(report.suggestions, "Peste 5000 de piese: împarte construcția sau folosește StreamingEnabled / LevelOfDetail.")
	end
	if report.unions > 20 then
		table.insert(report.suggestions, report.unions .. " uniri (CSG): uniunile mari sunt scumpe; păstrează-le puține.")
	end
	report.changes = #changes
	if opts.dryRun or #changes == 0 then
		return report
	end
	return record("optimizare", function()
		for _, ch in changes do
			pcall(function()
				(ch[1] :: any)[ch[2]] = ch[3]
			end)
		end
		return report
	end)
end

function Modeling.weldAll(root, opts)
	opts = opts or {}
	local parts = partsOf(root)
	if #parts < 2 then
		error("Sudura are nevoie de cel puțin 2 piese.", 0)
	end
	local main = typeof(root) == "Instance" and root:IsA("Model") and root.PrimaryPart or nil
	if not main then
		local best = -1
		for _, p in parts do
			local s = p.Size
			local v = s.X * s.Y * s.Z
			if v > best then
				best, main = v, p
			end
		end
	end
	return record("sudură", function()
		local welds = {}
		local done = {}
		for _, w in main:GetChildren() do
			if w:IsA("WeldConstraint") and w.Name == "LostCubeWeld" and w.Part1 then
				done[w.Part1] = true
			end
		end
		for _, p in parts do
			if p ~= main and not done[p] then
				local w = Instance.new("WeldConstraint")
				w.Name = "LostCubeWeld"
				w.Part0 = main
				w.Part1 = p
				w.Parent = main
				table.insert(welds, w)
			end
			if opts.unanchor then
				p.Anchored = false
			end
		end
		return welds
	end)
end

function Modeling.group(targets, name)
	local objs = requireObjects(targets)
	return record("grupare", function()
		local model = Instance.new("Model")
		model.Name = name or "Grup"
		local parent = objs[1].Parent
		local biggest, primary = -1, nil
		for _, obj in objs do
			obj.Parent = model
			if isPart(obj) then
				local s = obj.Size
				if s.X * s.Y * s.Z > biggest then
					biggest, primary = s.X * s.Y * s.Z, obj
				end
			end
		end
		model.PrimaryPart = primary
		model.Parent = parent
		return model
	end)
end

-- materials smooth terrain can use
local TERRAIN_MATERIALS = {}
for _, name in { "Asphalt", "Basalt", "Brick", "Cobblestone", "Concrete", "CrackedLava", "Glacier", "Grass", "Ground",
	"Ice", "LeafyGrass", "Limestone", "Mud", "Pavement", "Rock", "Salt", "Sand", "Sandstone", "Slate", "Snow",
	"WoodPlanks", "Water", "Air" } do
	TERRAIN_MATERIALS[name] = true
end

local function applyTerrain(ops, origin)
	if #ops == 0 then
		return 0
	end
	local terrain = workspace.Terrain
	for _, op in ops do
		local mat = materialItem(op.material) or Enum.Material.Rock
		if op.op == "ball" then
			terrain:FillBall(toV3(F.point(origin, op.center)), op.radius, mat)
		elseif op.op == "block" then
			terrain:FillBlock(toCF(F.mul(origin, op.cf)), toV3(op.size), mat)
		elseif op.op == "wedge" then
			terrain:FillWedge(toCF(F.mul(origin, op.cf)), toV3(op.size), mat)
		elseif op.op == "cylinder" then
			terrain:FillCylinder(toCF(F.mul(origin, op.cf)), op.height, op.radius, mat)
		end
	end
	return #ops
end

-- parts -> smooth terrain (Block / Wedge / Ball / Cylinder; others as their box), opts: material (default: from the
-- part's material when terrain has it, else Rock), keep (false = the parts are deleted)
function Modeling.toTerrain(targets, opts)
	opts = opts or {}
	local parts = partsOf(targets)
	if #parts == 0 then
		error("Alege piesele de transformat în teren.", 0)
	end
	if opts.material ~= nil and not isTerrainMaterial(opts.material) then
		error("Material de teren necunoscut: " .. tostring(opts.material), 0)
	end
	local ops = {}
	for _, part in parts do
		local material = opts.material
		if not material then
			local name = part.Material.Name
			material = TERRAIN_MATERIALS[name] and name or "Rock"
		end
		local pc = { shape = shapeOf(part) or "Block", size = fromV3(part.Size), cf = fromCF(part.CFrame) }
		table.insert(ops, Geometry.terrainOp(pc, material))
	end
	return record("piese în teren", function()
		applyTerrain(ops, F.IDENTITY)
		if not opts.keep then
			for _, part in parts do
				part:Destroy()
			end
		end
		return #ops
	end)
end

-- Runtime check of the shape conventions the maths relies on (the tests run on a simulated Roblox): raycasts against a
-- temporary WedgePart / CornerWedgePart far above the map, inside an undo recording that is cancelled (nothing stays in
-- the place or in the history). Returns { wedge = bool, cornerWedge = bool, editableMesh = bool, notes = { text } }.
function Modeling.selfCheck()
	local report = { notes = {} }
	local okBegin, recording = pcall(ChangeHistoryService.TryBeginRecording, ChangeHistoryService, "LostCube: verificare")
	local function probe(className, size, rayXZ)
		local part = Instance.new(className)
		part.Anchored = true
		part.Archivable = false
		part.Size = size
		part.CFrame = CFrame.new(0, 10000, 0)
		part.Parent = workspace
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { part }
		local heights = {}
		for i, xz in rayXZ do
			local hit = workspace:Raycast(Vector3.new(xz[1], 10010, xz[2]), Vector3.new(0, -20, 0), params)
			heights[i] = hit and hit.Position.Y or nil
		end
		part:Destroy()
		return heights
	end
	local ok, err = pcall(function()
		-- WedgePart: the slope rises toward +Z
		local w = probe("WedgePart", Vector3.new(1, 4, 4), { { 0, 1.5 }, { 0, -1.5 } })
		report.wedge = w[1] ~= nil and w[2] ~= nil and w[1] > w[2]
		-- CornerWedgePart: the apex stands over the (+X, -Z) corner
		local a = Geometry.CORNER_APEX
		local c = probe("CornerWedgePart", Vector3.new(4, 4, 4), { { a[1] * 1.5, a[3] * 1.5 }, { -a[1] * 1.5, -a[3] * 1.5 } })
		report.cornerWedge = c[1] ~= nil and c[2] ~= nil and c[1] > c[2] + 1
	end)
	if okBegin and recording then
		pcall(ChangeHistoryService.FinishRecording, ChangeHistoryService, recording, Enum.FinishRecordingOperation.Cancel)
	end
	if not ok then
		table.insert(report.notes, "Testul cu raycast a eșuat: " .. tostring(err))
	end
	if report.wedge == false then
		table.insert(report.notes, "WedgePart are altă orientare decât se presupune: umplerile de triunghiuri vor ieși greșit.")
	end
	if report.cornerWedge == false then
		table.insert(report.notes, "CornerWedgePart are vârful în alt colț: acoperișurile în patru ape și oglindirea lor vor ieși greșit.")
	end
	local meshOk, why = Modeling.meshAvailable()
	report.editableMesh = meshOk
	if not meshOk then
		table.insert(report.notes, tostring(why))
	end
	return report
end

-- ---------------------------------------------------------------------------------------------
-- 7. generators
-- ---------------------------------------------------------------------------------------------
local function generatedModel(result, origin, name)
	local model = newModel(name, nil, origin)
	model:SetAttribute("LC_Generator", result.kind)
	model:SetAttribute("LC_Params", Spec.toJSON(result.params))
	model:SetAttribute("LC_Parts", #result.pieces)
	buildPieces(result.pieces, model, origin)
	return model
end

local function generateReport(result, origin)
	local b = Geometry.piecesBounds(result.pieces)
	return {
		kind = result.kind,
		parts = #result.pieces,
		terrainOps = #result.terrain,
		size = b and toV3(V.sub(b.max, b.min)) or Vector3.zero,
		center = b and toV3(F.point(origin, V.mid(b.min, b.max))) or toV3(origin.p),
		info = result.info,
		params = result.params,
	}
end

function Modeling.generate(kind, params, parent, cframe)
	local result, err = Generators.generate(kind, params, materialCheck)
	if not result then
		error(err, 0)
	end
	local origin = fromCF(cframeArg(cframe))
	local label = Generators.BY_KEY[kind].label
	if parent ~= nil and typeof(parent) ~= "Instance" then
		error("„parent” trebuie să fie un Instance.", 0)
	end
	return record("generat " .. label, function()
		local model
		if #result.pieces > 0 then
			model = generatedModel(result, origin, label)
			model.Parent = parent or workspace
		end
		applyTerrain(result.terrain, origin)
		return model, generateReport(result, origin)
	end)
end

-- rebuilds a generated model with changed parameters (same place, same parent); one undo step
function Modeling.regenerate(model, params)
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		error("regenerate are nevoie de un model generat de LostCube.", 0)
	end
	local kind = model:GetAttribute("LC_Generator")
	local saved = Spec.fromJSON(model:GetAttribute("LC_Params") or "")
	if type(kind) ~= "string" or type(saved) ~= "table" then
		error("„" .. model.Name .. "” nu e un model generat (lipsesc LC_Generator / LC_Params).", 0)
	end
	for k, v in params or {} do
		saved[k] = v
	end
	local result, err = Generators.generate(kind, saved, materialCheck)
	if not result then
		error(err, 0)
	end
	local origin = fromCF(model.WorldPivot)
	return record("regenerat " .. model.Name, function()
		local fresh = generatedModel(result, origin, model.Name)
		fresh.Parent = model.Parent
		model:Destroy()
		return fresh, generateReport(result, origin)
	end)
end

-- a spot in front of the camera, on whatever is under it (or y = 0)
function Modeling.placement(distance)
	distance = distance or 40
	local cam = workspace.CurrentCamera
	if not cam then
		return CFrame.new()
	end
	local look = cam.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, -1)
	end
	flat = flat.Unit
	local spot = cam.CFrame.Position + flat * distance
	local hit = workspace:Raycast(spot + Vector3.new(0, 200, 0), Vector3.new(0, -1000, 0))
	local y = hit and hit.Position.Y or 0
	return CFrame.lookAt(Vector3.new(spot.X, y, spot.Z), Vector3.new(spot.X, y, spot.Z) + flat)
end

-- ---------------------------------------------------------------------------------------------
-- 8. procedural meshes
-- ---------------------------------------------------------------------------------------------
local function assetService()
	local ok, service = pcall(function()
		return game:GetService("AssetService")
	end)
	return ok and service or nil
end

local function editableMesh()
	local service = assetService()
	if not service then
		return nil, "AssetService nu e disponibil."
	end
	local ok, em = pcall(function()
		return service:CreateEditableMesh({})
	end)
	if not ok or not em then
		return nil, "EditableMesh nu e disponibil (" .. tostring(em) .. "). În Studio: Game Settings → Security → „Allow Mesh / Image APIs”."
	end
	return em, service
end

function Modeling.meshAvailable()
	local em, err = editableMesh()
	if not em then
		return false, err
	end
	pcall(function()
		em:Destroy()
	end)
	return true
end

-- mesh data (local to the mesh centre) -> MeshPart, or nil + reason
local function meshPartFrom(data)
	local em, service = editableMesh()
	if not em then
		return nil, service
	end
	local ok, result = pcall(function()
		local ids = {}
		for i, v in data.verts do
			ids[i] = em:AddVertex(toV3(v))
		end
		for _, t in data.tris do
			em:AddTriangle(ids[t[1]], ids[t[2]], ids[t[3]])
		end
		local content = Content.fromObject(em)
		local okHull, part = pcall(function()
			return (service :: any):CreateMeshPartAsync(content, { CollisionFidelity = Enum.CollisionFidelity.Hull })
		end)
		if okHull and part then
			return part
		end
		return (service :: any):CreateMeshPartAsync(content, {})
	end)
	if not ok or not result then
		pcall(function()
			em:Destroy()
		end)
		return nil, "Crearea MeshPart-ului a eșuat: " .. tostring(result)
	end
	return result
end

function Modeling.mesh(kind, params, parent, cframe, opts)
	opts = opts or {}
	local data, err = Mesh.make(kind, params)
	if not data then
		error(err, 0)
	end
	local problem = Mesh.check(data)
	if problem then
		error(problem, 0)
	end
	-- default "parts": a MeshPart from an EditableMesh does not survive saving the place without an upload
	local mode = opts.mode or "parts"
	if mode ~= "auto" and mode ~= "mesh" and mode ~= "parts" then
		error("Modul trebuie să fie auto, mesh sau parts.", 0)
	end
	local origin = fromCF(cframeArg(cframe))
	local center = Mesh.center(data)
	local look = { color = (params and params.color) or "#8a8580", material = (params and params.material) or "SmoothPlastic" }
	if not isPartMaterial(look.material) then
		error("Material necunoscut: " .. tostring(look.material), 0)
	end
	if not toColor3(look.color) then
		error("Culoarea trebuie să fie „#rrggbb”.", 0)
	end
	if parent ~= nil and typeof(parent) ~= "Instance" then
		error("„parent” trebuie să fie un Instance.", 0)
	end
	local report = { kind = kind, triangles = #data.tris, vertices = #data.verts }
	local recipe = Spec.toJSON(params or {})
	local meshPart, why
	if mode ~= "parts" then
		meshPart, why = meshPartFrom(data)
		if not meshPart and mode == "mesh" then
			return nil, why
		end
	end
	return record("mesh " .. kind, function()
		local frame = F.mul(origin, F.new(center))
		if meshPart then
			meshPart.Name = opts.name or ("Mesh " .. kind)
			meshPart.Anchored = true
			meshPart.CFrame = toCF(frame)
			meshPart.Color = toColor3(look.color) :: any
			meshPart.Material = materialItem(look.material) :: any
			meshPart:SetAttribute("LC_Mesh", kind)
			meshPart:SetAttribute("LC_Params", recipe)
			meshPart.Parent = parent or workspace
			report.mode = "mesh"
			report.parts = 1
			report.warning = "MeshPart din EditableMesh: conținutul e generat în memorie și poate să nu se salveze odată cu place-ul "
				.. "până nu e publicat ca asset; rețeta e păstrată în atributele LC_Mesh / LC_Params (Modeling.rebuildMesh)."
			return meshPart, report
		end
		local pieces, perr = Mesh.toPieces(data, { thickness = opts.thickness })
		if not pieces then
			error(perr, 0)
		end
		withLook(pieces, look, "Fațetă")
		local model = newModel(opts.name or ("Mesh " .. kind), nil, frame)
		model:SetAttribute("LC_Mesh", kind)
		model:SetAttribute("LC_Params", recipe)
		buildPieces(pieces, model, frame)
		model.Parent = parent or workspace
		report.mode = "parts"
		report.parts = #pieces
		report.fallback = why
		return model, report
	end)
end

-- rebuilds a mesh made by Modeling.mesh from its saved recipe (after reopening a place, or to switch mode)
function Modeling.rebuildMesh(inst, opts)
	if typeof(inst) ~= "Instance" or type(inst:GetAttribute("LC_Mesh")) ~= "string" then
		error("rebuildMesh are nevoie de un obiect creat de Modeling.mesh.", 0)
	end
	local params = Spec.fromJSON(inst:GetAttribute("LC_Params") or "{}") or {}
	local pivot = inst:GetPivot()
	return record("refăcut mesh", function()
		local data = Mesh.make(inst:GetAttribute("LC_Mesh"), params)
		local center = data and Mesh.center(data) or { 0, 0, 0 }
		local origin = fromCF(pivot) -- the pivot is the mesh centre: put the origin back where it was
		origin = F.mul(origin, F.new(V.neg(center)))
		local made, report = Modeling.mesh(inst:GetAttribute("LC_Mesh"), params, inst.Parent, toCF(origin), opts)
		if made then
			inst:Destroy()
		end
		return made, report
	end)
end

-- ---------------------------------------------------------------------------------------------
-- 9. readback (docs/modeling-research.md 4.3): a few lines that let Claude check a build without the whole tree
-- ---------------------------------------------------------------------------------------------
local DOOR_NAMES = { ["Ușă"] = true, Door = true, ["Poartă"] = true, Gate = true }
local DEFAULT_GRAY = Color3.fromRGB(163, 162, 165)

local function fmt(x)
	return Spec.toJSON(Spec.round(x, 1))
end

local function summaryOf(name, parts, origin, opts)
	opts = opts or {}
	local inv = F.inv(origin)
	local n = #parts
	local meshes, unions, tris, anchored, collide, gray = 0, 0, 0, 0, 0, 0
	local materials, pts = {}, {}
	local doors = {}
	for _, p in parts do
		if p:IsA("MeshPart") then
			meshes += 1
		elseif p:IsA("PartOperation") then
			unions += 1
			local ok, count = pcall(function()
				return (p :: any).TriangleCount
			end)
			if ok and type(count) == "number" then
				tris += count
			end
		end
		if p.Anchored then
			anchored += 1
		end
		if p.CanCollide then
			collide += 1
		end
		local mat = p.Material.Name
		materials[mat] = (materials[mat] or 0) + 1
		if mat == "Plastic" and p.Color == DEFAULT_GRAY then
			gray += 1
		end
		for _, c in Geometry.boxCorners(F.mul(inv, fromCF(p.CFrame)), fromV3(p.Size)) do
			table.insert(pts, c)
		end
		if DOOR_NAMES[p.Name] then
			table.insert(doors, p)
		end
	end
	local lines = {}
	local head = "Model " .. name
	if #pts > 0 then
		local b = Geometry.bounds(pts)
		head ..= string.format("  bbox %sx%sx%s (min %s,%s,%s)", fmt(b.max[1] - b.min[1]), fmt(b.max[2] - b.min[2]),
			fmt(b.max[3] - b.min[3]), fmt(b.min[1]), fmt(b.min[2]), fmt(b.min[3]))
	end
	head ..= string.format("  parts %d  meshparts %d  unions %d", n, meshes, unions)
	if tris > 0 then
		head ..= string.format("  tris~%.1fk", tris / 1000)
	end
	table.insert(lines, head)
	local mats = {}
	for k, v in materials do
		table.insert(mats, { k, v })
	end
	table.sort(mats, function(a, b)
		return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1])
	end)
	local matText = {}
	for i = 1, math.min(6, #mats) do
		table.insert(matText, mats[i][1] .. " " .. mats[i][2])
	end
	if #mats > 6 then
		table.insert(matText, "+" .. (#mats - 6))
	end
	table.insert(lines, string.format("materials: %s | anchored %d/%d | collide %d/%d", table.concat(matText, ", "), anchored, n, collide, n))
	-- floating: nothing within 0.5 studs under the bottom (centre + 4 inset corners; up to 300 parts checked). The rays
	-- start at the top of the part's box, so a part sunk into another one counts as supported.
	local floating = {}
	local checked = math.min(n, opts.maxChecks or 300)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	for i = 1, checked do
		local p = parts[i]
		local b = Geometry.bounds(Geometry.boxCorners(fromCF(p.CFrame), fromV3(p.Size)))
		params.FilterDescendantsInstances = { p }
		local cx, cz = (b.min[1] + b.max[1]) / 2, (b.min[3] + b.max[3]) / 2
		local hx, hz = (b.max[1] - b.min[1]) * 0.4, (b.max[3] - b.min[3]) * 0.4
		local gap = math.huge
		for _, d in { { 0, 0 }, { -hx, -hz }, { hx, -hz }, { -hx, hz }, { hx, hz } } do
			local hit = workspace:Raycast(Vector3.new(cx + d[1], b.max[2] + 0.05, cz + d[2]), Vector3.new(0, -(b.max[2] - b.min[2] + 50), 0), params)
			if hit then
				gap = math.min(gap, b.min[2] - hit.Position.Y)
			end
		end
		if gap > 0.5 then
			table.insert(floating, { p, gap })
		end
	end
	table.sort(floating, function(x, y)
		return x[2] > y[2]
	end)
	local issues = { string.format("%d floating", #floating) }
	if #floating > 0 then
		local names = {}
		for i = 1, math.min(3, #floating) do
			local f = floating[i]
			table.insert(names, f[1].Name .. (f[2] < math.huge and (" y+" .. fmt(f[2])) or " (nimic dedesubt)"))
		end
		issues[1] ..= " (" .. table.concat(names, ", ") .. (#floating > 3 and ", ..." or "") .. ")"
	end
	table.insert(issues, string.format("%d default-gray", gray))
	table.insert(issues, string.format("%d unanchored", n - anchored))
	if checked < n then
		table.insert(issues, string.format("(verificate %d/%d)", checked, n))
	end
	table.insert(lines, "issues: " .. table.concat(issues, ", "))
	local checks = {}
	local minW, minH = Generators.SCALE.DOOR_MIN[1], Generators.SCALE.DOOR_MIN[2]
	for i = 1, math.min(4, #doors) do
		local d = doors[i]
		local w = math.max(d.Size.X, d.Size.Z)
		local h = d.Size.Y
		table.insert(checks, string.format("door %sx%s %s", fmt(w), fmt(h), (w >= minW - 0.3 and h >= minH - 0.3) and "ok" or "îngustă"))
	end
	if opts.budget then
		table.insert(checks, string.format("budget parts %d/%d%s", n, opts.budget, n > opts.budget and " DEPĂȘIT" or ""))
	end
	if #checks > 0 then
		table.insert(lines, "checks: " .. table.concat(checks, " | "))
	end
	return table.concat(lines, "\n")
end

-- the readback text of a model / part / list (opts: budget, maxChecks)
function Modeling.summary(target, opts)
	local parts = partsOf(target)
	local origin = F.IDENTITY
	if typeof(target) == "Instance" and (target:IsA("Model") or isPart(target)) then
		origin = fromCF(target:GetPivot())
	end
	local name = typeof(target) == "Instance" and target.Name or "Selecție"
	return summaryOf(name, parts, origin, opts)
end

-- ---------------------------------------------------------------------------------------------
-- 10. spec (Spec.DOC)
-- ---------------------------------------------------------------------------------------------
local function specErrors(errors)
	local shown = {}
	for i = 1, math.min(12, #errors) do
		table.insert(shown, errors[i])
	end
	if #errors > 12 then
		table.insert(shown, "(încă " .. (#errors - 12) .. " erori)")
	end
	return "Spec invalid:\n" .. table.concat(shown, "\n")
end

function Modeling.validateSpec(spec)
	local plan, errors = Spec.compile(spec, materialCheck)
	if not plan then
		return false, errors
	end
	return true, {}, plan.count
end

function Modeling.buildFromSpec(spec, parent, cframe, opts)
	opts = opts or {}
	local plan, errors = Spec.compile(spec, materialCheck)
	if not plan then
		error(specErrors(errors), 0)
	end
	local origin = fromCF(cframeArg(cframe))
	if parent ~= nil and typeof(parent) ~= "Instance" then
		error("„parent” trebuie să fie un Instance.", 0)
	end
	return record("construit „" .. plan.name .. "”", function()
		local model = newModel(plan.name, nil, origin)
		buildPieces(plan.pieces, model, origin)
		local terrainOps = 0
		for _, g in plan.generators do
			local frame = F.mul(origin, g.frame)
			local sub = generatedModel(g.result, frame, Generators.BY_KEY[g.kind].label)
			sub.Parent = model
			terrainOps += applyTerrain(g.result.terrain, frame)
		end
		model.Parent = parent or workspace
		return model, { parts = plan.count, generators = #plan.generators, terrainOps = terrainOps }
	end)
end

-- a part -> piece (frame relative to `inv` = origin^-1); nil for unsupported classes
local function pieceOf(part, inv)
	local shape = shapeOf(part)
	if not shape then
		return nil
	end
	return {
		shape = shape,
		size = fromV3(part.Size),
		cf = F.mul(inv, fromCF(part.CFrame)),
		color = "#" .. part.Color:ToHex(),
		material = part.Material.Name,
		transparency = part.Transparency,
		reflectance = part.Reflectance,
		anchored = part.Anchored,
		canCollide = part.CanCollide,
		castShadow = part.CastShadow,
		name = part.Name,
	}
end

function Modeling.describe(target, opts)
	opts = opts or {}
	local maxParts = opts.maxParts or 500
	local origin
	if opts.relativeTo ~= nil then
		origin = fromCF(cframeArg(opts.relativeTo, "relativeTo"))
	elseif typeof(target) == "Instance" and (target:IsA("Model") or isPart(target)) then
		origin = fromCF(target:GetPivot())
	else
		origin = F.IDENTITY
	end
	local inv = F.inv(origin)
	local spec = { name = typeof(target) == "Instance" and target.Name or "Selecție", parts = {} }
	local generators, unsupported = {}, {}
	local pts = {}
	local allParts = {}
	local total = 0
	local function addCorners(f, size)
		for _, c in Geometry.boxCorners(f, size) do
			table.insert(pts, c)
		end
	end
	local function visit(inst, isRoot)
		if isPart(inst) then
			total += 1
			table.insert(allParts, inst)
			local pc = pieceOf(inst, inv)
			if #spec.parts + #unsupported >= maxParts then
				return
			end
			if pc then
				table.insert(spec.parts, Spec.describePiece(pc))
				addCorners(pc.cf, pc.size)
			else
				local f = F.mul(inv, fromCF(inst.CFrame))
				table.insert(unsupported, { class = inst.ClassName, name = inst.Name,
					pos = { Spec.round(f.p[1], 3), Spec.round(f.p[2], 3), Spec.round(f.p[3], 3) },
					size = { Spec.round(inst.Size.X, 3), Spec.round(inst.Size.Y, 3), Spec.round(inst.Size.Z, 3) } })
				addCorners(f, fromV3(inst.Size))
			end
		elseif inst:IsA("Model") and not isRoot and type(inst:GetAttribute("LC_Generator")) == "string" then
			local params = Spec.fromJSON(inst:GetAttribute("LC_Params") or "")
			if type(params) == "table" then
				local f = F.mul(inv, fromCF(inst.WorldPivot))
				local o = F.orientation(f)
				table.insert(generators, { kind = inst:GetAttribute("LC_Generator"), params = params, at = {
					pos = { Spec.round(f.p[1], 3), Spec.round(f.p[2], 3), Spec.round(f.p[3], 3) },
					rot = { Spec.round(o[1], 2), Spec.round(o[2], 2), Spec.round(o[3], 2) } } })
				for _, d in inst:GetDescendants() do
					if isPart(d) then
						total += 1
						table.insert(allParts, d)
						addCorners(F.mul(inv, fromCF(d.CFrame)), fromV3(d.Size))
					end
				end
				return
			end
		end
		if not isPart(inst) or isRoot then
			for _, c in inst:GetChildren() do
				visit(c, false)
			end
		end
	end
	if type(target) == "table" then
		for _, x in target do
			if typeof(x) == "Instance" then
				visit(x, false)
			end
		end
	elseif typeof(target) == "Instance" then
		if isPart(target) then
			visit(target, false)
		else
			visit(target, true)
		end
	else
		error("describe are nevoie de un model, o piesă sau o listă.", 0)
	end
	if #generators > 0 then
		spec.generators = generators
	end
	if #unsupported > 0 then
		spec.unsupported = unsupported
	end
	if #pts > 0 then
		local b = Geometry.bounds(pts)
		spec.bounds = { Spec.round(b.max[1] - b.min[1], 2), Spec.round(b.max[2] - b.min[2], 2), Spec.round(b.max[3] - b.min[3], 2) }
	end
	spec.count = total
	local listed = #spec.parts + #unsupported
	if total > listed and listed >= maxParts then
		spec.truncated = total - listed
	end
	if opts.summary ~= false then
		spec.summary = summaryOf(spec.name, allParts, origin, opts)
	end
	return spec
end

-- help text for Claude / a panel: one generator's parameters (or the list of generators)
function Modeling.generatorHelp(kind)
	if kind == nil then
		local lines = {}
		for _, g in Generators.LIST do
			table.insert(lines, g.key .. " – " .. g.label)
		end
		return table.concat(lines, "\n")
	end
	local g = Generators.BY_KEY[kind]
	if not g then
		error("Generator necunoscut „" .. tostring(kind) .. "”.", 0)
	end
	local lines = { g.key .. " (" .. g.label .. "):" }
	for _, f in g.params do
		local range = ""
		if f.min then
			range = string.format(" %s..%s", tostring(f.min), tostring(f.max))
		elseif f.options then
			range = " " .. table.concat(f.options, "|")
		end
		local def = type(f.default) == "table" and Spec.toJSON(f.default) or tostring(f.default)
		table.insert(lines, string.format("  %s (%s%s, implicit %s) – %s", f.key, f.kind, range, def, f.label))
	end
	return table.concat(lines, "\n")
end

return Modeling
