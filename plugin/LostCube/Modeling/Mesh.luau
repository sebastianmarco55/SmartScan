-- LostCube > Modeling > Mesh: procedural triangle meshes as plain data, built without Roblox:
--   mesh = { verts = { { x, y, z } }, tris = { { i, j, k } } (counter-clockwise seen from outside), flat = bool }
-- init.luau turns a mesh into a MeshPart through AssetService:CreateEditableMesh + CreateMeshPartAsync when the engine
-- allows it, and otherwise into WedgeParts (Mesh.toPieces: two wedges per triangle at most), so every shape exists in
-- both forms. flat = true: every triangle gets its own 3 vertices (faceted normals); false: shared vertices (smooth).
local Geometry = require(script.Parent.Geometry)
local Generators = require(script.Parent.Generators)
local V = Geometry.V

local Mesh = {}

-- EditableMesh budget (per mesh) and the size of the parts fallback
Mesh.MAX_TRIANGLES = 20000
Mesh.MAX_VERTICES = 60000
Mesh.MAX_FALLBACK_TRIANGLES = 1500

local pi, sin, cos, floor, max, min = math.pi, math.sin, math.cos, math.floor, math.max, math.min

local function new(flat)
	return { verts = {}, tris = {}, flat = flat == true }
end

local function addVert(m, v)
	table.insert(m.verts, v)
	return #m.verts
end

local function addTri(m, a, b, c)
	table.insert(m.tris, { a, b, c })
end

-- a copy with one vertex per triangle corner (faceted look)
function Mesh.flatten(m)
	local out = new(true)
	for _, t in m.tris do
		local a = addVert(out, V.copy(m.verts[t[1]]))
		local b = addVert(out, V.copy(m.verts[t[2]]))
		local c = addVert(out, V.copy(m.verts[t[3]]))
		addTri(out, a, b, c)
	end
	return out
end

function Mesh.bounds(m)
	return Geometry.bounds(m.verts)
end

-- moves the mesh so its bounding box is centred on the origin; returns the offset that was removed
function Mesh.center(m)
	local b = Mesh.bounds(m)
	local c = V.mid(b.min, b.max)
	for i, v in m.verts do
		m.verts[i] = V.sub(v, c)
	end
	return c
end

function Mesh.area(m)
	local total = 0
	for _, t in m.tris do
		total += Geometry.triangleArea(m.verts[t[1]], m.verts[t[2]], m.verts[t[3]])
	end
	return total
end

-- nil, or the reason this mesh cannot be built
function Mesh.check(m)
	if type(m) ~= "table" or type(m.verts) ~= "table" or type(m.tris) ~= "table" then
		return "Mesh invalid."
	end
	if #m.tris == 0 then
		return "Mesh-ul nu are niciun triunghi."
	end
	if #m.tris > Mesh.MAX_TRIANGLES then
		return string.format("Prea multe triunghiuri (%d; maxim %d).", #m.tris, Mesh.MAX_TRIANGLES)
	end
	if #m.verts > Mesh.MAX_VERTICES then
		return string.format("Prea multe vârfuri (%d; maxim %d).", #m.verts, Mesh.MAX_VERTICES)
	end
	for _, t in m.tris do
		for k = 1, 3 do
			local i = t[k]
			if type(i) ~= "number" or not m.verts[i] then
				return "Triunghi cu un vârf inexistent."
			end
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------------------------
-- builders
-- ---------------------------------------------------------------------------------------------
-- surface of revolution around Y. profile = { { radius, y } } from bottom to top; ends with radius > 0 are capped.
-- Vases, columns, domes, bottles, tree trunks, lamp posts.
function Mesh.lathe(profile, segments, opts)
	opts = opts or {}
	segments = floor(segments or 16)
	if segments < 3 or segments > 256 then
		return nil, "Numărul de segmente trebuie să fie între 3 și 256."
	end
	if type(profile) ~= "table" or #profile < 2 then
		return nil, "Profilul are nevoie de cel puțin 2 puncte { rază, y }."
	end
	local prof = {}
	for i, q in profile do
		local r, y = q[1] or q.r, q[2] or q.y
		if type(r) ~= "number" or type(y) ~= "number" or r < 0 then
			return nil, "Punctul " .. i .. " al profilului trebuie să fie { rază >= 0, y }."
		end
		table.insert(prof, { r, y })
	end
	local m = new(false)
	local rings = {}
	for i, q in prof do
		if q[1] < 1e-9 then
			rings[i] = { addVert(m, { 0, q[2], 0 }) } -- a pole: one vertex
		else
			local ring = {}
			for s = 0, segments - 1 do
				local a = 2 * pi * s / segments
				table.insert(ring, addVert(m, { cos(a) * q[1], q[2], -sin(a) * q[1] }))
			end
			rings[i] = ring
		end
	end
	-- the rings turn counter-clockwise seen from above; with the profile going up, these windings face away from the axis
	for i = 1, #prof - 1 do
		local lo, hi = rings[i], rings[i + 1]
		for s = 1, segments do
			local s2 = s % segments + 1
			if #lo == 1 and #hi > 1 then
				addTri(m, lo[1], hi[s2], hi[s])
			elseif #hi == 1 and #lo > 1 then
				addTri(m, lo[s], lo[s2], hi[1])
			elseif #lo > 1 and #hi > 1 then
				addTri(m, lo[s], hi[s2], hi[s])
				addTri(m, lo[s], lo[s2], hi[s2])
			end
		end
	end
	if opts.caps ~= false then
		local first, last = rings[1], rings[#rings]
		if #first > 1 then
			local c = addVert(m, { 0, prof[1][2], 0 })
			for s = 1, segments do
				addTri(m, c, first[s % segments + 1], first[s])
			end
		end
		if #last > 1 then
			local c = addVert(m, { 0, prof[#prof][2], 0 })
			for s = 1, segments do
				addTri(m, c, last[s], last[s % segments + 1])
			end
		end
	end
	if opts.flat then
		return Mesh.flatten(m)
	end
	return m
end

-- inward offset of a 2D polygon (counter-clockwise, { x, z }) by d along the vertex bisectors
local function insetPolygon(poly, d)
	local n = #poly
	local out = {}
	for i = 1, n do
		local p0, p1, p2 = poly[(i - 2) % n + 1], poly[i], poly[i % n + 1]
		local e1 = { p1[1] - p0[1], p1[2] - p0[2] }
		local e2 = { p2[1] - p1[1], p2[2] - p1[2] }
		local l1 = math.sqrt(e1[1] ^ 2 + e1[2] ^ 2)
		local l2 = math.sqrt(e2[1] ^ 2 + e2[2] ^ 2)
		-- inward normals of a counter-clockwise polygon (x right, z "up" in 2D): (-ez, ex)
		local n1 = { -e1[2] / l1, e1[1] / l1 }
		local n2 = { -e2[2] / l2, e2[1] / l2 }
		local b = { n1[1] + n2[1], n1[2] + n2[2] }
		local bl = math.sqrt(b[1] ^ 2 + b[2] ^ 2)
		if bl < 1e-9 then
			b, bl = n1, 1
		end
		b = { b[1] / bl, b[2] / bl }
		local cosHalf = max(0.2, b[1] * n1[1] + b[2] * n1[2])
		table.insert(out, { p1[1] + b[1] * d / cosHalf, p1[2] + b[2] * d / cosHalf })
	end
	return out
end

-- a 2D polygon { { x, z } } extruded up (Y) by `depth`, optionally with a chamfer of `bevel` around the top
function Mesh.extrude(polygon, depth, bevel)
	if type(polygon) ~= "table" or #polygon < 3 then
		return nil, "Poligonul are nevoie de cel puțin 3 puncte { x, z }."
	end
	if type(depth) ~= "number" or depth <= 0 then
		return nil, "Înălțimea extrudării trebuie să fie pozitivă."
	end
	bevel = max(0, min(bevel or 0, depth * 0.9))
	local poly = {}
	for i, q in polygon do
		local x, z = q[1] or q.x, q[2] or q.z
		if type(x) ~= "number" or type(z) ~= "number" then
			return nil, "Punctul " .. i .. " al poligonului trebuie să fie { x, z }."
		end
		table.insert(poly, { x, z })
	end
	-- counter-clockwise when seen from above (+Y): with x right and -z away from the viewer the signed area (x, -z) > 0
	local area = 0
	for i = 1, #poly do
		local a, b = poly[i], poly[i % #poly + 1]
		area += a[1] * (-b[2]) - b[1] * (-a[2])
	end
	if math.abs(area) < 1e-9 then
		return nil, "Poligon degenerat."
	end
	if area < 0 then
		local rev = {}
		for i = #poly, 1, -1 do
			table.insert(rev, poly[i])
		end
		poly = rev
	end
	local tris3, err = Geometry.triangulate((function()
		local pts = {}
		for _, q in poly do
			table.insert(pts, { q[1], 0, q[2] })
		end
		return pts
	end)())
	if not tris3 then
		return nil, err
	end
	-- 2D "counter-clockwise" in (x, -z) is clockwise in (x, z): insetPolygon expects (x, z) counter-clockwise
	local top = bevel > 0 and insetPolygon((function()
		local rev = {}
		for i = #poly, 1, -1 do
			table.insert(rev, poly[i])
		end
		return rev
	end)(), bevel) or nil
	if top then
		local back = {}
		for i = #top, 1, -1 do
			table.insert(back, top[i])
		end
		top = back
	end
	local m = new(true)
	local n = #poly
	local function ring(points, y)
		local ids = {}
		for _, q in points do
			table.insert(ids, addVert(m, { q[1], y, q[2] }))
		end
		return ids
	end
	local bottom = ring(poly, 0)
	local mid = ring(poly, depth - bevel)
	local upper = top and ring(top, depth) or mid
	-- side walls (outward normals for a polygon counter-clockwise seen from above)
	local function band(lo, hi)
		for i = 1, n do
			local j = i % n + 1
			addTri(m, lo[i], lo[j], hi[j])
			addTri(m, lo[i], hi[j], hi[i])
		end
	end
	band(bottom, mid)
	if top then
		band(mid, upper)
	end
	-- caps: the triangulation follows the polygon's winding (counter-clockwise from above = normal +Y)
	for _, t in tris3 do
		addTri(m, upper[t[1]], upper[t[2]], upper[t[3]])
		addTri(m, bottom[t[1]], bottom[t[3]], bottom[t[2]])
	end
	return Mesh.flatten(m)
end

-- low-poly rock: convex hull of random points; detail >= 2 subdivides and roughens it
function Mesh.rock(seed, detail, opts)
	opts = opts or {}
	detail = max(0, min(4, floor(detail or 1)))
	local rng = Geometry.rng(seed or 1)
	local size = opts.size or 6
	local pts = Generators.rockPoints(rng, size, min(detail, 3), opts.flatten or 0.7)
	local faces, err = Geometry.convexHull(pts)
	if not faces then
		return nil, err
	end
	local m = new(false)
	m.verts = pts
	m.tris = faces
	for _ = 3, detail + 1 do
		-- split every triangle in 4; midpoints pushed in / out a little
		local cache = {}
		local tris = {}
		local function midpoint(a, b)
			local key = a < b and (a .. ":" .. b) or (b .. ":" .. a)
			if cache[key] then
				return cache[key]
			end
			local p = V.mid(m.verts[a], m.verts[b])
			local c = { 0, size * 0.25, 0 }
			local dir = V.unit(V.sub(p, c), { 0, 1, 0 }) :: any
			p = V.add(p, V.scale(dir, size * rng.range(-0.03, 0.06)))
			table.insert(m.verts, p)
			cache[key] = #m.verts
			return #m.verts
		end
		for _, t in m.tris do
			local ab, bc, ca = midpoint(t[1], t[2]), midpoint(t[2], t[3]), midpoint(t[3], t[1])
			table.insert(tris, { t[1], ab, ca })
			table.insert(tris, { ab, t[2], bc })
			table.insert(tris, { ca, bc, t[3] })
			table.insert(tris, { ab, bc, ca })
		end
		m.tris = tris
	end
	if opts.smooth then
		return m
	end
	return Mesh.flatten(m)
end

-- height field: heightFn(x, z) -> y over a square of `size` studs centred on the origin, `resolution` cells per side.
-- heightFn may also be a 2D array heights[row][col] of (resolution + 1)^2 values.
function Mesh.terrainChunk(heightFn, opts)
	opts = opts or {}
	local size = opts.size or 64
	local res = floor(opts.resolution or 16)
	if res < 1 or res > 128 then
		return nil, "Rezoluția trebuie să fie între 1 și 128."
	end
	local function h(i, j, x, z)
		if type(heightFn) == "function" then
			local ok, y = pcall(heightFn, x, z)
			return (ok and type(y) == "number" and y == y) and y or 0
		elseif type(heightFn) == "table" then
			local row = heightFn[i + 1]
			local y = row and row[j + 1]
			return type(y) == "number" and y or 0
		end
		return 0
	end
	local m = new(opts.flat ~= false)
	local ids = {}
	for i = 0, res do
		ids[i] = {}
		for j = 0, res do
			local x = -size / 2 + size * j / res
			local z = -size / 2 + size * i / res
			ids[i][j] = addVert(m, { x, h(i, j, x, z), z })
		end
	end
	for i = 0, res - 1 do
		for j = 0, res - 1 do
			local a, b, c, d = ids[i][j], ids[i][j + 1], ids[i + 1][j], ids[i + 1][j + 1]
			-- counter-clockwise seen from above (+Y): z grows "down" the screen
			addTri(m, a, c, b)
			addTri(m, b, c, d)
		end
	end
	if m.flat then
		return Mesh.flatten(m)
	end
	return m
end

-- the same shape as WedgeParts (the fallback when EditableMesh is unavailable); thickness grows inward
function Mesh.toPieces(m, opts)
	opts = opts or {}
	if #m.tris > Mesh.MAX_FALLBACK_TRIANGLES then
		return nil, string.format("Prea multe triunghiuri pentru varianta din piese (%d; maxim %d).", #m.tris, Mesh.MAX_FALLBACK_TRIANGLES)
	end
	local out = {}
	for _, t in m.tris do
		local w = Geometry.triangleWedges(m.verts[t[1]], m.verts[t[2]], m.verts[t[3]], { thickness = opts.thickness or 0.2, align = "front" })
		for _, pc in (w or {}) do
			table.insert(out, pc)
		end
	end
	return out
end

-- kind + params -> mesh (used by Modeling.mesh); params as in the header of init.luau
Mesh.KINDS = { "lathe", "extrude", "rock", "terrain" }
function Mesh.make(kind, params)
	params = params or {}
	if kind == "lathe" then
		local profile = params.profile or { { 0, 0 }, { 2, 0 }, { 2.4, 1 }, { 1.2, 3 }, { 1.6, 5 }, { 0, 5.4 } }
		return Mesh.lathe(profile, params.segments or 16, { flat = params.flat })
	elseif kind == "extrude" then
		local polygon = params.polygon or { { -4, -2 }, { 4, -2 }, { 4, 2 }, { 0, 4 }, { -4, 2 } }
		return Mesh.extrude(polygon, params.depth or 2, params.bevel or 0)
	elseif kind == "rock" then
		return Mesh.rock(params.seed or 1, params.detail or 2, { size = params.size, flatten = params.flatten, smooth = params.smooth })
	elseif kind == "terrain" then
		local fn = params.heights
		if fn == nil then
			local rng = Geometry.rng(params.seed or 1)
			local amp = params.amplitude or 6
			local waves = {}
			for i = 1, 4 do
				table.insert(waves, { rng.range(0.03, 0.12) * i, rng.range(0.03, 0.12) * i, rng.range(0, 2 * pi), amp / (i * 1.6) })
			end
			fn = function(x, z)
				local y = 0
				for _, w in waves do
					y += sin(x * w[1] + w[3]) * cos(z * w[2] - w[3]) * w[4]
				end
				return y
			end
		end
		return Mesh.terrainChunk(fn, { size = params.size or 64, resolution = params.resolution or 16, flat = params.flat })
	end
	return nil, "Tip de mesh necunoscut „" .. tostring(kind) .. "” (" .. table.concat(Mesh.KINDS, ", ") .. ")."
end

return Mesh
