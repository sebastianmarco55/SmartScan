-- LostCube > Modeling > Spec: the compact build format Claude (or a panel) writes, validated and compiled into pieces
-- without touching Roblox; init.luau builds the result (Modeling.buildFromSpec) and reads models back into the same
-- format (Modeling.describe). Spec.DOC below is the format's reference, written to be handed to Claude verbatim.
-- Also: a small deterministic JSON codec (sorted keys, the same output in Studio and in the tests).
local Geometry = require(script.Parent.Geometry)
local Generators = require(script.Parent.Generators)
local V, M, F = Geometry.V, Geometry.M, Geometry.F

local Spec = {}

Spec.LIMITS = {
	MAX_PARTS = 2000, -- parts in one build, generators and arrays included
	MAX_GENERATORS = 50,
	MAX_ARRAYS = 100,
	MIN_SIZE = 0.05,
	MAX_SIZE = 2048,
	MAX_DISTANCE = 4096, -- |pos| from the model origin
	MAX_NAME = 100,
}
local LIMITS = Spec.LIMITS

Spec.DOC = [==[
LostCube build spec (a JSON object or a Luau table). Units: studs. One spec = one Model = one undo step.
Axes of the model: X right, Y up, -Z front. The origin is the centre of the model's footprint on the ground (y = 0).
Scale (studs, 1 stud = 28 cm): player ~5 tall, jumps 7.2 (a barrier that must stop players is >= 8 high), walks 16/s.
Door 5 x 8 (minimum 4 x 7), hallway >= 10 wide, path >= 6, ceiling / floor height 12, stairs rise 1 run 1.5, table top
3.5, seat 1.5, road lane 12. Grid 4 for structure (2, 1, 0.5 for details); prefer round values (multiples of 0.25).

{
  "name": "House",        Model name (default "Model LostCube")
  "parts": [PART, ...],   explicit parts
  "generators": [GEN, ...],  procedural sub-models (each becomes a child Model named after its kind)
  "arrays": [ARRAY, ...]  copies of parts, applied in order after "parts"
}

PART (every key optional except size, or points for a Triangle):
  "shape": "Block" (default) | "Wedge" | "CornerWedge" | "Cylinder" | "Ball" | "Triangle"
  "size": [x, y, z]       each 0.05..2048. Cylinder: x = length along its axis (local X), y = z = diameter.
                          Ball: a sphere of diameter x (Roblox keeps x = y = z).
  "pos": [x, y, z]        centre, relative to the model origin (default [0, 0, 0]); |pos| <= 4096
  "rot": [x, y, z]        degrees, exactly like Part.Orientation (applied Y, then X, then Z); default [0, 0, 0]
  "color": "#rrggbb"      default "#a3a2a5"
  "material": name        an Enum.Material name: Plastic (default), SmoothPlastic, Wood, WoodPlanks, Brick, Concrete,
                          Cobblestone, Slate, Granite, Marble, Limestone, Metal, DiamondPlate, Glass, Neon, Grass, Sand,
                          Ice, Fabric, Asphalt, Rock, ...
  "transparency": 0..1    "reflectance": 0..1
  "anchored": true        "canCollide": true        "castShadow": true      (defaults)
  "name": "Door"          default: Part / Wedge / CornerWedge
  Triangle: "points": [[x,y,z], [x,y,z], [x,y,z]] instead of size/pos/rot, optional "thickness" (default 0.2):
  becomes 1-2 WedgeParts covering the triangle exactly (any orientation, the classic triangle fill).
  Shapes: Wedge = full bottom and back (+Z) faces, the slope rises from the bottom-front edge to the top-back edge.
  CornerWedge = square bottom, one apex above the bottom corner at (+X, -Z). Cylinder axis = local X (rot [0,0,90]
  stands it up). Use rot to turn them.

GEN: { "kind": K, "params": {...}, "at": { "pos": [x,y,z], "rot": [x,y,z] } }   ("at" may also be just [x,y,z])
  K: building, stairs, fence, bridge, tower, arch, colonnade, wall, road, tree, rock, crystals, furniture (set, table,
     chair, bed, shelf, bench, crate, barrel, lamp), terrain (blob, hill, cave, ramp, clear; smooth Terrain, no parts).
  Every generator's origin is the centre of its footprint on the ground, front = -Z. Unknown params are errors; the
  list of params, defaults and ranges: Modeling.GENERATORS (key, label, params = { key, kind, default, min, max,
  options }). Examples:
    { "kind": "building", "params": { "width": 24, "depth": 20, "floors": 2, "roof": "gable" } }
    { "kind": "tree", "params": { "kind": "pine", "height": 14, "seed": 3 }, "at": [10, 0, 5] }
    { "kind": "stairs", "params": { "kind": "spiral", "height": 12 } }
    { "kind": "fence", "params": { "points": [[-10,0,0], [10,0,0], [10,0,12]], "style": "picket" } }

ARRAY ("of" = list of part indexes, 1-based into "parts", and/or part names; "count" = total items, original included):
  { "kind": "linear", "of": [1], "count": 5, "offset": [4, 0, 0] }
  { "kind": "radial", "of": [2], "count": 8, "center": [0, 0, 0], "axis": [0, 1, 0], "angle": 360 }
  { "kind": "arc", "of": [3], "count": 12, "angle": 15, "axis": "Y", "radius": 0 }
      each copy continues the previous one along its length and turns by "angle" degrees around the shared edge
      (curved walls, rings, ramps); "axis" is local to the first part; "radius" moves the pivot out (wider curve)
  { "kind": "path", "of": ["Lamp"], "points": [[0,0,0], [20,0,10], [40,0,0]], "spacing": 8, "align": true }
      copies along a smooth curve through the points ("tension" 0..1, 1 = straight segments)
  { "kind": "mirror", "of": [1, 2], "normal": [1, 0, 0], "point": [0, 0, 0] }
      mirrored copies (wedges and corner wedges are re-oriented so the copy is a true mirror image)

Limits: <= 2000 parts in total (generators and arrays included), <= 50 generators, <= 100 arrays. Errors name the
item ("parts[3].size: ...") and nothing is built while any error remains.

Modeling.describe(model) returns this format for an existing build (positions relative to the model's pivot, default
values left out, generator-made sub-models as GEN entries, unsupported parts such as MeshParts listed under
"unsupported" with class, name, pos and size) plus "bounds", "count" and a "summary" readback, e.g.
  Model House  bbox 28x26.1x24 (min -14,0,-12)  parts 112  meshparts 0  unions 0
  materials: Brick 38, SmoothPlastic 40, Glass 10, WoodPlanks 3 | anchored 112/112 | collide 112/112
  issues: 0 floating, 0 default-gray, 0 unanchored
  checks: door 5x8 ok
Feeding a describe() result back to buildFromSpec rebuilds the same parts (bounds / count / summary are ignored).
]==]

Spec.SHAPES = { "Block", "Wedge", "CornerWedge", "Cylinder", "Ball", "Triangle" }
Spec.DEFAULT_COLOR = "#a3a2a5"
Spec.DEFAULT_NAME = { Block = "Part", Cylinder = "Part", Ball = "Part", Wedge = "Wedge", CornerWedge = "CornerWedge" }

local PART_KEYS = {
	shape = true, size = true, pos = true, rot = true, color = true, material = true, transparency = true, reflectance = true,
	anchored = true, canCollide = true, castShadow = true, name = true, points = true, thickness = true,
}
local TOP_KEYS = { name = true, parts = true, generators = true, arrays = true, bounds = true, unsupported = true,
	count = true, truncated = true, summary = true } -- the last five come from describe and are ignored

-- ---------------------------------------------------------------------------------------------
-- JSON
-- ---------------------------------------------------------------------------------------------
local ORDER = { "name", "kind", "shape", "size", "pos", "rot", "points", "color", "material", "transparency", "reflectance",
	"anchored", "canCollide", "castShadow", "thickness", "params", "at", "of", "count", "parts", "generators", "arrays" }
local RANK = {}
for i, k in ORDER do
	RANK[k] = i
end

local function isArray(t)
	local n = #t
	local count = 0
	for _ in t do
		count += 1
	end
	return count == n
end

local function numberText(x)
	if x ~= x or x == math.huge or x == -math.huge then
		return "0"
	end
	if x % 1 == 0 and math.abs(x) < 1e15 then
		return string.format("%d", x)
	end
	local s = string.format("%.6f", x)
	s = string.gsub(s, "0+$", "")
	s = string.gsub(s, "%.$", "")
	if s == "-0" then
		return "0"
	end
	return s
end

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f" }
local function stringText(s)
	local out = string.gsub(s, '[%c"\\]', function(c)
		return ESC[c] or string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. out .. '"'
end

function Spec.toJSON(value)
	local parts = {}
	local function enc(v, depth)
		if depth > 64 then
			error("JSON: structură prea adâncă", 0)
		end
		local t = type(v)
		if t == "nil" then
			table.insert(parts, "null")
		elseif t == "boolean" then
			table.insert(parts, v and "true" or "false")
		elseif t == "number" then
			table.insert(parts, numberText(v))
		elseif t == "string" then
			table.insert(parts, stringText(v))
		elseif t == "table" then
			if isArray(v) then
				table.insert(parts, "[")
				for i, item in v do
					if i > 1 then
						table.insert(parts, ",")
					end
					enc(item, depth + 1)
				end
				table.insert(parts, "]")
			else
				local keys = {}
				for k in v do
					if type(k) == "string" then
						table.insert(keys, k)
					end
				end
				table.sort(keys, function(a, b)
					local ra, rb = RANK[a] or 1000, RANK[b] or 1000
					if ra ~= rb then
						return ra < rb
					end
					return a < b
				end)
				table.insert(parts, "{")
				for i, k in keys do
					if i > 1 then
						table.insert(parts, ",")
					end
					table.insert(parts, stringText(k))
					table.insert(parts, ":")
					enc(v[k], depth + 1)
				end
				table.insert(parts, "}")
			end
		else
			table.insert(parts, "null")
		end
	end
	enc(value, 0)
	return table.concat(parts)
end

function Spec.fromJSON(text)
	if type(text) ~= "string" then
		return nil, "JSON: textul lipsește."
	end
	local pos = 1
	local len = #text
	local function fail(msg)
		error({ json = string.format("JSON invalid la poziția %d: %s", pos, msg) }, 0)
	end
	local function skip()
		pos = string.find(text, "[^ \t\r\n]", pos) or len + 1
	end
	local value
	local function utf8char(code)
		return utf8.char(code)
	end
	local function str()
		pos += 1
		local out = {}
		while true do
			local c = string.sub(text, pos, pos)
			if c == "" then
				fail("șir neterminat")
			elseif c == '"' then
				pos += 1
				return table.concat(out)
			elseif c == "\\" then
				local e = string.sub(text, pos + 1, pos + 1)
				local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
				if map[e] then
					table.insert(out, map[e])
					pos += 2
				elseif e == "u" then
					local hex = string.sub(text, pos + 2, pos + 5)
					if not string.match(hex, "^%x%x%x%x$") then
						fail("\\u invalid")
					end
					local code = tonumber(hex, 16) :: number
					pos += 6
					if code >= 0xD800 and code <= 0xDBFF and string.sub(text, pos, pos + 1) == "\\u" then
						local lo = tonumber(string.sub(text, pos + 2, pos + 5), 16)
						if lo and lo >= 0xDC00 and lo <= 0xDFFF then
							code = 0x10000 + (code - 0xD800) * 0x400 + (lo - 0xDC00)
							pos += 6
						end
					end
					table.insert(out, utf8char(code))
				else
					fail("escape invalid")
				end
			else
				local stop = string.find(text, '["\\]', pos) or len + 1
				table.insert(out, string.sub(text, pos, stop - 1))
				pos = stop
			end
		end
	end
	function value(depth)
		if depth > 64 then
			fail("structură prea adâncă")
		end
		skip()
		local c = string.sub(text, pos, pos)
		if c == "{" then
			pos += 1
			local obj = {}
			skip()
			if string.sub(text, pos, pos) == "}" then
				pos += 1
				return obj
			end
			while true do
				skip()
				if string.sub(text, pos, pos) ~= '"' then
					fail("se aștepta o cheie între ghilimele")
				end
				local k = str()
				skip()
				if string.sub(text, pos, pos) ~= ":" then
					fail("se aștepta „:”")
				end
				pos += 1
				obj[k] = value(depth + 1)
				skip()
				local d = string.sub(text, pos, pos)
				pos += 1
				if d == "}" then
					return obj
				elseif d ~= "," then
					pos -= 1
					fail("se aștepta „,” sau „}”")
				end
			end
		elseif c == "[" then
			pos += 1
			local arr = {}
			skip()
			if string.sub(text, pos, pos) == "]" then
				pos += 1
				return arr
			end
			while true do
				table.insert(arr, value(depth + 1))
				skip()
				local d = string.sub(text, pos, pos)
				pos += 1
				if d == "]" then
					return arr
				elseif d ~= "," then
					pos -= 1
					fail("se aștepta „,” sau „]”")
				end
			end
		elseif c == '"' then
			return str()
		elseif string.sub(text, pos, pos + 3) == "true" then
			pos += 4
			return true
		elseif string.sub(text, pos, pos + 4) == "false" then
			pos += 5
			return false
		elseif string.sub(text, pos, pos + 3) == "null" then
			pos += 4
			return nil
		else
			local num = string.match(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
			if not num or num == "" or num == "-" then
				fail("valoare neașteptată")
			end
			pos += #(num :: string)
			local n = tonumber(num)
			if n == nil then
				fail("număr invalid")
			end
			return n
		end
	end
	local ok, result = pcall(function()
		local v = value(0)
		skip()
		if pos <= len then
			fail("text în plus după valoare")
		end
		return v
	end)
	if not ok then
		if type(result) == "table" and result.json then
			return nil, result.json
		end
		return nil, "JSON invalid: " .. tostring(result)
	end
	return result
end

-- ---------------------------------------------------------------------------------------------
-- validation helpers
-- ---------------------------------------------------------------------------------------------
local function finite(x: any): boolean
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function vec3(v: any): { number }?
	if type(v) ~= "table" then
		return nil
	end
	local x, y, z = v[1], v[2], v[3]
	if not (finite(x) and finite(y) and finite(z)) then
		return nil
	end
	return { x, y, z }
end
Spec.vec3 = vec3

local function hexColor(c)
	if type(c) ~= "string" then
		return nil
	end
	local h = string.match(c, "^#?(%x%x%x%x%x%x)$")
	return h and ("#" .. string.lower(h)) or nil
end
Spec.hexColor = hexColor

-- frame from { pos, rot } / [x, y, z] / nil
local function frameFrom(at)
	if at == nil then
		return F.new(), nil
	end
	local direct = vec3(at)
	if direct then
		return F.new(direct), nil
	end
	if type(at) ~= "table" then
		return nil, "trebuie să fie { pos = [x,y,z], rot = [x,y,z] } sau [x,y,z]"
	end
	local p = at.pos == nil and { 0, 0, 0 } or vec3(at.pos)
	local r = at.rot == nil and { 0, 0, 0 } or vec3(at.rot)
	if not p then
		return nil, "pos trebuie să fie [x, y, z]"
	end
	if not r then
		return nil, "rot trebuie să fie [x, y, z] (grade)"
	end
	return F.fromPosOrientation(p, r), nil
end
Spec.frameFrom = frameFrom

-- one PART -> pieces (a Triangle can give 1-2), or nil + error list
function Spec.part(item, where, isMaterial)
	local errors = {}
	local function err(msg)
		table.insert(errors, where .. msg)
	end
	if type(item) ~= "table" then
		return nil, { where .. ": trebuie să fie un obiect { shape, size, pos, ... }." }
	end
	for k in item do
		if not PART_KEYS[k] then
			err(": cheie necunoscută „" .. tostring(k) .. "”.")
		end
	end
	local shape = item.shape == nil and "Block" or item.shape
	if not table.find(Spec.SHAPES, shape) then
		err(".shape: trebuie să fie una dintre " .. table.concat(Spec.SHAPES, ", ") .. ".")
		return nil, errors
	end
	local look = {}
	if item.color ~= nil then
		local c = hexColor(item.color)
		if not c then
			err(".color: culoarea trebuie să fie „#rrggbb”.")
		end
		look.color = c
	end
	if item.material ~= nil then
		if type(item.material) ~= "string" or (isMaterial and not isMaterial(item.material)) then
			err(".material: material necunoscut „" .. tostring(item.material) .. "”.")
		else
			look.material = item.material
		end
	end
	for _, key in { "transparency", "reflectance" } do
		local v = item[key]
		if v ~= nil then
			if type(v) ~= "number" or v ~= v or v < 0 or v > 1 then
				err("." .. key .. ": trebuie să fie un număr între 0 și 1.")
			else
				look[key] = v
			end
		end
	end
	for _, key in { "anchored", "canCollide", "castShadow" } do
		local v = item[key]
		if v ~= nil then
			if type(v) ~= "boolean" then
				err("." .. key .. ": trebuie să fie true sau false.")
			else
				look[key] = v
			end
		end
	end
	if item.name ~= nil then
		if type(item.name) ~= "string" or #item.name == 0 or #item.name > LIMITS.MAX_NAME then
			err(".name: trebuie să fie un text de 1-" .. LIMITS.MAX_NAME .. " caractere.")
		else
			look.name = item.name
		end
	end
	if shape == "Triangle" then
		for _, k in { "size", "pos", "rot" } do
			if item[k] ~= nil then
				err("." .. k .. ": un Triangle se dă prin points, fără " .. k .. ".")
			end
		end
		local pts = {}
		if type(item.points) ~= "table" or #item.points ~= 3 then
			err(".points: un Triangle are exact 3 puncte [[x,y,z], [x,y,z], [x,y,z]].")
		else
			for i, q in item.points do
				local v = vec3(q)
				if not v then
					err(".points[" .. i .. "]: trebuie să fie [x, y, z].")
				elseif V.len(v) > LIMITS.MAX_DISTANCE then
					err(".points[" .. i .. "]: prea departe de origine (maxim " .. LIMITS.MAX_DISTANCE .. ").")
				else
					table.insert(pts, v)
				end
			end
		end
		local thickness = item.thickness == nil and 0.2 or item.thickness
		if type(thickness) ~= "number" or thickness < Geometry.MIN_SIZE or thickness > LIMITS.MAX_SIZE then
			err(".thickness: trebuie să fie un număr între " .. Geometry.MIN_SIZE .. " și " .. LIMITS.MAX_SIZE .. ".")
		end
		if #errors > 0 then
			return nil, errors
		end
		local wedges, werr = Geometry.triangleWedges(pts[1], pts[2], pts[3], { thickness = thickness })
		if not wedges then
			return nil, { where .. ": " .. tostring(werr) }
		end
		for _, w in wedges do
			for k, v in look do
				w[k] = v
			end
		end
		return wedges
	end
	if item.points ~= nil or item.thickness ~= nil then
		err(": points / thickness sunt doar pentru shape = \"Triangle\".")
	end
	local size = vec3(item.size)
	if not size then
		err(".size: trebuie să fie [x, y, z].")
	else
		for i = 1, 3 do
			if size[i] < LIMITS.MIN_SIZE or size[i] > LIMITS.MAX_SIZE then
				err(string.format(".size: fiecare dimensiune între %s și %d (primit %s).", tostring(LIMITS.MIN_SIZE), LIMITS.MAX_SIZE, tostring(size[i])))
				break
			end
		end
		if shape == "Ball" then
			size = { size[1], size[1], size[1] }
		elseif shape == "Cylinder" then
			local d = math.min(size[2], size[3])
			size = { size[1], d, d }
		end
	end
	local pos = item.pos == nil and { 0, 0, 0 } or vec3(item.pos)
	if not pos then
		err(".pos: trebuie să fie [x, y, z].")
	elseif V.len(pos) > LIMITS.MAX_DISTANCE then
		err(".pos: prea departe de origine (maxim " .. LIMITS.MAX_DISTANCE .. ").")
	end
	local rot = item.rot == nil and { 0, 0, 0 } or vec3(item.rot)
	if not rot then
		err(".rot: trebuie să fie [x, y, z] (grade).")
	end
	if #errors > 0 then
		return nil, errors
	end
	local pc = { shape = shape, size = size, cf = F.fromPosOrientation(pos :: any, rot :: any) }
	for k, v in look do
		pc[k] = v
	end
	return { pc }
end

-- ---------------------------------------------------------------------------------------------
-- arrays on pieces (pure; the same maths as the Instance operations)
-- ---------------------------------------------------------------------------------------------
local function copyPiece(pc, frame)
	local c = table.clone(pc)
	c.cf = F.mul(frame, pc.cf)
	return c
end

function Spec.arrayCopies(item, sources, where)
	local kind = item.kind
	local out = {}
	local function fail(msg)
		return nil, where .. msg
	end
	if kind == "mirror" then
		local normal = item.normal == nil and { 1, 0, 0 } or vec3(item.normal)
		local point = item.point == nil and { 0, 0, 0 } or vec3(item.point)
		if not normal or V.len(normal) < 1e-9 then
			return fail(".normal: trebuie să fie [x, y, z], nenul.")
		end
		if not point then
			return fail(".point: trebuie să fie [x, y, z].")
		end
		for _, pc in sources do
			local c = table.clone(pc)
			c.cf, c.size = Geometry.mirrorFrame(pc.cf, pc.size, pc.shape, point, normal)
			table.insert(out, c)
		end
		return out
	end
	local count = item.count
	if kind ~= "path" then
		local err = Geometry.checkCount(count)
		if err then
			return fail(".count: " .. err)
		end
	end
	local transforms, terr
	if kind == "linear" then
		local offset = vec3(item.offset)
		if not offset then
			return fail(".offset: trebuie să fie [x, y, z].")
		end
		transforms, terr = Geometry.linearTransforms(offset, count)
	elseif kind == "radial" then
		local center = item.center == nil and { 0, 0, 0 } or vec3(item.center)
		local axis = item.axis == nil and { 0, 1, 0 } or vec3(item.axis)
		if not center or not axis then
			return fail(": center / axis trebuie să fie [x, y, z].")
		end
		local angle = item.angle == nil and 360 or item.angle
		if type(angle) ~= "number" or angle ~= angle or math.abs(angle) > 360 or angle == 0 then
			return fail(".angle: între -360 și 360, nu 0.")
		end
		transforms, terr = Geometry.radialTransforms(center, axis, count, angle)
	elseif kind == "arc" then
		local first = sources[1]
		local ref
		if #sources == 1 then
			ref = { cf = first.cf, size = first.size }
		else
			local cf, size = Geometry.orientedBounds(first.cf.r, sources)
			ref = { cf = cf, size = size }
		end
		transforms, terr = Geometry.arcTransforms(ref, { axis = item.axis, angle = item.angle, count = count,
			radius = item.radius, length = item.length })
	elseif kind == "path" then
		local sp, serr = Geometry.spline(item.points or {}, { tension = item.tension })
		if not sp then
			return fail(".points: " .. tostring(serr))
		end
		local spacing = item.spacing
		if type(spacing) ~= "number" or spacing <= 0 then
			return fail(".spacing: trebuie să fie un număr pozitiv.")
		end
		transforms = Spec.pathTransforms(sp, spacing, sources[1].cf, item.align ~= false)
		if #transforms > 1000 then
			return fail(": prea multe copii (" .. #transforms .. ").")
		end
	else
		return fail(".kind: trebuie să fie linear, radial, arc, path sau mirror.")
	end
	if not transforms then
		return fail(": " .. tostring(terr))
	end
	for _, tf in transforms do
		for _, pc in sources do
			table.insert(out, copyPiece(pc, tf))
		end
	end
	return out
end

-- transforms that carry `ref` (the first item's frame) to every sample of a spline, every `spacing` studs (both ends
-- included); align = the items turn with the curve (their rotation relative to the curve's start frame is kept). The
-- original stays where it is: a sample that would put a copy exactly on it is skipped.
function Spec.pathTransforms(sp, spacing, ref, align)
	local out = {}
	local frames = sp.frames(spacing)
	local inv = F.inv(ref)
	local startInv = M.transpose(frames[1].r)
	for _, fr in frames do
		local r = align and M.mul(fr.r, M.mul(startInv, ref.r)) or ref.r
		local tf = F.mul({ p = fr.p, r = r }, inv)
		if not F.near(tf, F.IDENTITY, 1e-4) then
			table.insert(out, tf)
		end
	end
	return out
end

-- ---------------------------------------------------------------------------------------------
-- compile: spec -> { name, pieces, generators = { { kind, params, frame, result } }, count } or nil + errors
-- ---------------------------------------------------------------------------------------------
function Spec.compile(spec, isMaterial)
	if type(spec) == "string" then
		local decoded, jerr = Spec.fromJSON(spec)
		if decoded == nil then
			return nil, { jerr or "JSON gol." }
		end
		spec = decoded
	end
	if type(spec) ~= "table" then
		return nil, { "Spec-ul trebuie să fie un obiect { name, parts, generators, arrays }." }
	end
	local errors = {}
	for k in spec do
		if not TOP_KEYS[k] then
			table.insert(errors, "cheie necunoscută „" .. tostring(k) .. "” (există: name, parts, generators, arrays).")
		end
	end
	local name = spec.name == nil and "Model LostCube" or spec.name
	if type(name) ~= "string" or #name == 0 or #name > LIMITS.MAX_NAME then
		table.insert(errors, "name: trebuie să fie un text de 1-" .. LIMITS.MAX_NAME .. " caractere.")
		name = "Model LostCube"
	end
	local function list(key, max)
		local v = spec[key]
		if v == nil then
			return {}
		end
		if type(v) ~= "table" or not isArray(v) then
			table.insert(errors, key .. ": trebuie să fie o listă.")
			return {}
		end
		if #v > max then
			table.insert(errors, string.format("%s: prea multe elemente (%d; maxim %d).", key, #v, max))
		end
		return v
	end
	local partsIn = list("parts", LIMITS.MAX_PARTS)
	local gensIn = list("generators", LIMITS.MAX_GENERATORS)
	local arraysIn = list("arrays", LIMITS.MAX_ARRAYS)
	local pieces = {}
	local byIndex = {} -- parts index -> { piece }
	for i, item in partsIn do
		local made, perr = Spec.part(item, "parts[" .. i .. "]", isMaterial)
		if made then
			byIndex[i] = made
			for _, pc in made do
				table.insert(pieces, pc)
			end
		else
			for _, e in perr do
				table.insert(errors, e)
			end
		end
	end
	for i, item in arraysIn do
		local where = "arrays[" .. i .. "]"
		if type(item) ~= "table" then
			table.insert(errors, where .. ": trebuie să fie un obiect { kind, of, ... }.")
			continue
		end
		local of = item.of
		local sources, seen = {}, {}
		if type(of) ~= "table" or #of == 0 then
			table.insert(errors, where .. ".of: lista de piese (indici din parts și / sau nume).")
			continue
		end
		local bad = false
		for _, ref in of do
			local found = {}
			if type(ref) == "number" then
				found = byIndex[ref] or {}
				if partsIn[ref] == nil then
					table.insert(errors, where .. ".of: nu există parts[" .. tostring(ref) .. "].")
					bad = true
				end
			elseif type(ref) == "string" then
				for _, pc in pieces do
					if pc.name == ref then
						table.insert(found, pc)
					end
				end
				if #found == 0 then
					table.insert(errors, where .. ".of: nicio piesă numită „" .. ref .. "”.")
					bad = true
				end
			else
				table.insert(errors, where .. ".of: un indice (număr) sau un nume (text).")
				bad = true
			end
			for _, pc in found do
				if not seen[pc] then
					seen[pc] = true
					table.insert(sources, pc)
				end
			end
		end
		if not bad and #sources > 0 then
			local copies, aerr = Spec.arrayCopies(item, sources, where)
			if copies then
				for _, pc in copies do
					table.insert(pieces, pc)
				end
				if #pieces > LIMITS.MAX_PARTS then
					table.insert(errors, string.format("%s: prea multe piese în total (%d; maxim %d).", where, #pieces, LIMITS.MAX_PARTS))
					break
				end
			else
				table.insert(errors, aerr)
			end
		end
	end
	local generators = {}
	local total = #pieces
	for i, item in gensIn do
		local where = "generators[" .. i .. "]"
		if type(item) ~= "table" then
			table.insert(errors, where .. ": trebuie să fie un obiect { kind, params, at }.")
			continue
		end
		for k in item do
			if k ~= "kind" and k ~= "params" and k ~= "at" then
				table.insert(errors, where .. ": cheie necunoscută „" .. tostring(k) .. "” (kind, params, at).")
			end
		end
		local frame, ferr = frameFrom(item.at)
		if not frame then
			table.insert(errors, where .. ".at: " .. tostring(ferr) .. ".")
			continue
		end
		local result, gerr = Generators.generate(item.kind, item.params, isMaterial)
		if not result then
			table.insert(errors, where .. ": " .. string.gsub(tostring(gerr), "\n", "; " .. where .. ": "))
			continue
		end
		total += #result.pieces
		table.insert(generators, { kind = item.kind, params = result.params, frame = frame, result = result })
	end
	if total > LIMITS.MAX_PARTS then
		table.insert(errors, string.format("prea multe piese în total (%d; maxim %d).", total, LIMITS.MAX_PARTS))
	end
	if #errors > 0 then
		return nil, errors
	end
	return { name = name, pieces = pieces, generators = generators, count = total }
end

-- ---------------------------------------------------------------------------------------------
-- describe: pieces (frames relative to the origin, color "#hex", material name) -> PART entries
-- ---------------------------------------------------------------------------------------------
local function round(x, digits)
	local m = 10 ^ digits
	local v = math.floor(x * m + 0.5) / m
	if math.abs(v) < 0.5 / m then
		return 0
	end
	return v
end
Spec.round = round

local function roundVec(v, digits)
	return { round(v[1], digits), round(v[2], digits), round(v[3], digits) }
end

function Spec.describePiece(pc)
	local e = {}
	if pc.shape ~= "Block" then
		e.shape = pc.shape
	end
	local size = pc.size
	if pc.shape == "Ball" then
		e.size = roundVec({ size[1], size[1], size[1] }, 3)
	else
		e.size = roundVec(size, 3)
	end
	e.pos = roundVec(pc.cf.p, 3)
	local o = roundVec(F.orientation(pc.cf), 2)
	for i = 1, 3 do
		if o[i] == -180 then
			o[i] = 180
		end
	end
	if o[1] ~= 0 or o[2] ~= 0 or o[3] ~= 0 then
		e.rot = o
	end
	local color = hexColor(pc.color)
	if color and color ~= Spec.DEFAULT_COLOR then
		e.color = color
	end
	if pc.material and pc.material ~= "Plastic" then
		e.material = pc.material
	end
	if pc.transparency and pc.transparency > 0.001 then
		e.transparency = round(pc.transparency, 3)
	end
	if pc.reflectance and pc.reflectance > 0.001 then
		e.reflectance = round(pc.reflectance, 3)
	end
	if pc.anchored == false then
		e.anchored = false
	end
	if pc.canCollide == false then
		e.canCollide = false
	end
	if pc.castShadow == false then
		e.castShadow = false
	end
	if pc.name and pc.name ~= (Spec.DEFAULT_NAME[pc.shape] or "Part") then
		e.name = pc.name
	end
	return e
end

return Spec
