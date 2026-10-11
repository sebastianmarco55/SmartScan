-- LostCube > Modeling > Geometry: the pure maths of the modeling engine (no Instances, no Roblox datatypes), so every
-- algorithm runs and is unit-tested in the plain Luau CLI. init.luau converts at the boundary (Vector3 <-> { x, y, z },
-- CFrame <-> frame).
--
-- Conventions (the same as Roblox):
--   vector  { x, y, z }                       plain array, studs
--   matrix  { r00, r01, r02, r10, ... r22 }   row major; its COLUMNS are the part's right (X), up (Y) and back (Z) axes,
--                                             like CFrame.new(x, y, z, r00, r01, ... r22) / CFrame:GetComponents()
--   frame   { p = vector, r = matrix }        a CFrame
--   piece   { shape, size, cf, color?, material?, transparency?, name?, ... }  one part to build (init.luau `build`)
--           shape: "Block" | "Wedge" | "CornerWedge" | "Cylinder" (axis = local X) | "Ball"
-- Roblox part geometry used here (local coordinates, h = size / 2):
--   WedgePart:       bottom face full, back face (+Z) full, the slope goes from the bottom-front edge (y = -h, z = -h)
--                    up to the top-back edge (y = +h, z = +h); its YZ cross-section has the right angle at (-h.y, +h.z)
--   CornerWedgePart: square bottom face and one apex above the bottom corner (+h.x, -h.z): (+h.x, +h.y, -h.z)
local Geometry = {}

export type Vec = { number }
export type Mat = { number }
export type Frame = { p: Vec, r: Mat }

Geometry.EPS = 1e-9
Geometry.MIN_SIZE = 0.001 -- smallest part dimension Roblox keeps (smaller sizes are clamped)
Geometry.MAX_SIZE = 2048 -- largest part dimension
Geometry.CORNER_APEX = { 1, 1, -1 } -- CornerWedgePart apex corner (signs of the local half size)

local EPS = Geometry.EPS
local sqrt, abs, sin, cos, atan2, asin, floor, min, max, pi =
	math.sqrt, math.abs, math.sin, math.cos, math.atan2, math.asin, math.floor, math.min, math.max, math.pi

-- ---------------------------------------------------------------------------------------------
-- vectors
-- ---------------------------------------------------------------------------------------------
local V = {}
Geometry.V = V

function V.new(x: number?, y: number?, z: number?): Vec
	return { x or 0, y or 0, z or 0 }
end
function V.add(a: Vec, b: Vec): Vec
	return { a[1] + b[1], a[2] + b[2], a[3] + b[3] }
end
function V.sub(a: Vec, b: Vec): Vec
	return { a[1] - b[1], a[2] - b[2], a[3] - b[3] }
end
function V.scale(a: Vec, s: number): Vec
	return { a[1] * s, a[2] * s, a[3] * s }
end
function V.mul(a: Vec, b: Vec): Vec -- component-wise
	return { a[1] * b[1], a[2] * b[2], a[3] * b[3] }
end
function V.neg(a: Vec): Vec
	return { -a[1], -a[2], -a[3] }
end
function V.dot(a: Vec, b: Vec): number
	return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end
function V.cross(a: Vec, b: Vec): Vec
	return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end
function V.len(a: Vec): number
	return sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3])
end
function V.dist(a: Vec, b: Vec): number
	local x, y, z = a[1] - b[1], a[2] - b[2], a[3] - b[3]
	return sqrt(x * x + y * y + z * z)
end
-- unit vector; `fallback` (or nil) for a zero vector
function V.unit(a: Vec, fallback: Vec?): Vec?
	local l = V.len(a)
	if l < EPS then
		return fallback
	end
	return { a[1] / l, a[2] / l, a[3] / l }
end
function V.lerp(a: Vec, b: Vec, t: number): Vec
	return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
end
function V.mid(a: Vec, b: Vec): Vec
	return { (a[1] + b[1]) / 2, (a[2] + b[2]) / 2, (a[3] + b[3]) / 2 }
end
function V.copy(a: Vec): Vec
	return { a[1], a[2], a[3] }
end
function V.near(a: Vec, b: Vec, eps: number?): boolean
	return V.dist(a, b) <= (eps or 1e-6)
end
-- any unit vector perpendicular to a (a must not be zero)
function V.perpendicular(a: Vec): Vec
	local other = abs(a[2]) < 0.9 and { 0, 1, 0 } or { 1, 0, 0 }
	return V.unit(V.cross(a, other)) :: any
end
-- a vector given as { x, y, z }, { x = .., y = .., z = .. } or a Vector3-like value with X / Y / Z -> { x, y, z } or nil
function V.from(v: any): Vec?
	local t = type(v)
	if t == "table" then
		if type(v[1]) == "number" and type(v[2]) == "number" and type(v[3]) == "number" then
			return { v[1], v[2], v[3] }
		elseif type(v.x) == "number" and type(v.y) == "number" and type(v.z) == "number" then
			return { v.x, v.y, v.z }
		end
	elseif t == "userdata" or t == "vector" then
		local ok, x, y, z = pcall(function()
			return v.X, v.Y, v.Z
		end)
		if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then
			return { x, y, z }
		end
	end
	return nil
end

local add, sub, scale, dot, cross, len, unit = V.add, V.sub, V.scale, V.dot, V.cross, V.len, V.unit

-- ---------------------------------------------------------------------------------------------
-- rotation matrices (row major, columns = right, up, back)
-- ---------------------------------------------------------------------------------------------
local M = {}
Geometry.M = M

M.IDENTITY = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }

function M.fromColumns(x: Vec, y: Vec, z: Vec): Mat
	return { x[1], y[1], z[1], x[2], y[2], z[2], x[3], y[3], z[3] }
end
function M.column(m: Mat, i: number): Vec
	return { m[i], m[i + 3], m[i + 6] }
end
function M.mul(a: Mat, b: Mat): Mat
	return {
		a[1] * b[1] + a[2] * b[4] + a[3] * b[7], a[1] * b[2] + a[2] * b[5] + a[3] * b[8], a[1] * b[3] + a[2] * b[6] + a[3] * b[9],
		a[4] * b[1] + a[5] * b[4] + a[6] * b[7], a[4] * b[2] + a[5] * b[5] + a[6] * b[8], a[4] * b[3] + a[5] * b[6] + a[6] * b[9],
		a[7] * b[1] + a[8] * b[4] + a[9] * b[7], a[7] * b[2] + a[8] * b[5] + a[9] * b[8], a[7] * b[3] + a[8] * b[6] + a[9] * b[9],
	}
end
function M.transpose(a: Mat): Mat
	return { a[1], a[4], a[7], a[2], a[5], a[8], a[3], a[6], a[9] }
end
function M.apply(a: Mat, v: Vec): Vec
	return {
		a[1] * v[1] + a[2] * v[2] + a[3] * v[3],
		a[4] * v[1] + a[5] * v[2] + a[6] * v[3],
		a[7] * v[1] + a[8] * v[2] + a[9] * v[3],
	}
end
function M.det(a: Mat): number
	return a[1] * (a[5] * a[9] - a[6] * a[8]) - a[2] * (a[4] * a[9] - a[6] * a[7]) + a[3] * (a[4] * a[8] - a[5] * a[7])
end
-- rotation of `angle` radians around the unit vector `axis` (right-handed, like CFrame.fromAxisAngle)
function M.axisAngle(axis: Vec, angle: number): Mat
	local x, y, z = axis[1], axis[2], axis[3]
	local c, s = cos(angle), sin(angle)
	local t = 1 - c
	return {
		t * x * x + c, t * x * y - s * z, t * x * z + s * y,
		t * x * y + s * z, t * y * y + c, t * y * z - s * x,
		t * x * z - s * y, t * y * z + s * x, t * z * z + c,
	}
end
function M.rx(a: number): Mat
	local c, s = cos(a), sin(a)
	return { 1, 0, 0, 0, c, -s, 0, s, c }
end
function M.ry(a: number): Mat
	local c, s = cos(a), sin(a)
	return { c, 0, s, 0, 1, 0, -s, 0, c }
end
function M.rz(a: number): Mat
	local c, s = cos(a), sin(a)
	return { c, -s, 0, s, c, 0, 0, 0, 1 }
end
-- Part.Orientation / CFrame.fromOrientation (= fromEulerAnglesYXZ): Ry(y) * Rx(x) * Rz(z), radians
function M.fromOrientation(x: number, y: number, z: number): Mat
	return M.mul(M.ry(y), M.mul(M.rx(x), M.rz(z)))
end
-- inverse of fromOrientation (CFrame:ToOrientation), radians
function M.toOrientation(m: Mat): (number, number, number)
	local sx = -m[6]
	sx = max(-1, min(1, sx))
	local x = asin(sx)
	if abs(sx) < 0.999999 then
		return x, atan2(m[3], m[9]), atan2(m[4], m[5])
	end
	-- gimbal lock (x = +-90): only y + z (or y - z) is defined; keep z = 0
	return x, atan2(-m[7], m[1]), 0
end
-- rotation whose -Z (look) axis is `forward` and whose up is as close as possible to `upHint` (CFrame.lookAt)
function M.lookAlong(forward: Vec, upHint: Vec?): Mat
	local f = unit(forward, { 0, 0, -1 }) :: any
	local u = upHint or { 0, 1, 0 }
	local r = cross(f, u)
	if len(r) < 1e-6 then
		r = cross(f, abs(f[2]) < 0.9 and { 0, 1, 0 } or { 0, 0, 1 })
	end
	r = unit(r) :: any
	local up = cross(r, f)
	return M.fromColumns(r, up, scale(f, -1))
end
-- rotation whose X axis is `axisX` (cylinders: their axis is X), Y as close to upHint as possible
function M.alongX(axisX: Vec, upHint: Vec?): Mat
	local x = unit(axisX, { 1, 0, 0 }) :: any
	local u = upHint or { 0, 1, 0 }
	local z = cross(x, u)
	if len(z) < 1e-6 then
		z = cross(x, abs(x[3]) < 0.9 and { 0, 0, 1 } or { 1, 0, 0 })
	end
	z = unit(z) :: any
	return M.fromColumns(x, cross(z, x), z)
end
-- re-orthonormalises a nearly-orthonormal matrix (keeps the Y column, then Z)
function M.orthonormalize(m: Mat): Mat
	local y = unit(M.column(m, 2), { 0, 1, 0 }) :: any
	local z = M.column(m, 3)
	local x = unit(cross(y, z), nil)
	if not x then
		return M.IDENTITY
	end
	z = cross(x, y)
	return M.fromColumns(x, y, z)
end

-- ---------------------------------------------------------------------------------------------
-- frames (rigid transforms, = CFrame)
-- ---------------------------------------------------------------------------------------------
local F = {}
Geometry.F = F

function F.new(p: Vec?, r: Mat?): Frame
	return { p = p and V.copy(p) or { 0, 0, 0 }, r = r or M.IDENTITY }
end
F.IDENTITY = F.new()
-- position + Part.Orientation in degrees
function F.fromPosOrientation(p: Vec, deg: Vec?): Frame
	deg = deg or { 0, 0, 0 }
	return { p = V.copy(p), r = M.fromOrientation(math.rad(deg[1]), math.rad(deg[2]), math.rad(deg[3])) }
end
function F.orientation(f: Frame): Vec
	local x, y, z = M.toOrientation(f.r)
	return { math.deg(x), math.deg(y), math.deg(z) }
end
function F.mul(a: Frame, b: Frame): Frame
	return { p = add(a.p, M.apply(a.r, b.p)), r = M.mul(a.r, b.r) }
end
function F.inv(a: Frame): Frame
	local rt = M.transpose(a.r)
	return { p = scale(M.apply(rt, a.p), -1), r = rt }
end
function F.point(f: Frame, v: Vec): Vec -- local point -> world
	return add(f.p, M.apply(f.r, v))
end
function F.vector(f: Frame, v: Vec): Vec -- local direction -> world
	return M.apply(f.r, v)
end
function F.toLocal(f: Frame, v: Vec): Vec -- world point -> local
	return M.apply(M.transpose(f.r), sub(v, f.p))
end
function F.translate(f: Frame, v: Vec): Frame
	return { p = add(f.p, v), r = f.r }
end
-- rotation of `angle` radians around the world axis through `point`, as a frame to left-multiply with
function F.rotationAbout(point: Vec, axis: Vec, angle: number): Frame
	local r = M.axisAngle(unit(axis, { 0, 1, 0 }) :: any, angle)
	return { p = sub(point, M.apply(r, point)), r = r }
end
function F.near(a: Frame, b: Frame, eps: number?): boolean
	eps = eps or 1e-6
	if not V.near(a.p, b.p, eps) then
		return false
	end
	for i = 1, 9 do
		if abs(a.r[i] - b.r[i]) > eps then
			return false
		end
	end
	return true
end

-- ---------------------------------------------------------------------------------------------
-- boxes
-- ---------------------------------------------------------------------------------------------
-- the 8 corners of a box (frame + size)
function Geometry.boxCorners(f: Frame, size: Vec): { Vec }
	local h = scale(size, 0.5)
	local out = {}
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				table.insert(out, F.point(f, { h[1] * sx, h[2] * sy, h[3] * sz }))
			end
		end
	end
	return out
end

-- the corners that really belong to the shape (wedges have 6, corner wedges 5; round shapes use their box)
function Geometry.shapeCorners(shape, f, size)
	local h = scale(size, 0.5)
	if shape == "Wedge" then
		local out = {}
		for _, sx in { -1, 1 } do
			table.insert(out, F.point(f, { sx * h[1], -h[2], -h[3] }))
			table.insert(out, F.point(f, { sx * h[1], -h[2], h[3] }))
			table.insert(out, F.point(f, { sx * h[1], h[2], h[3] }))
		end
		return out
	elseif shape == "CornerWedge" then
		local a = Geometry.CORNER_APEX
		local out = { F.point(f, { a[1] * h[1], a[2] * h[2], a[3] * h[3] }) }
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				table.insert(out, F.point(f, { sx * h[1], -h[2], sz * h[3] }))
			end
		end
		return out
	end
	return Geometry.boxCorners(f, size)
end

-- world-axis bounds { min, max } of a list of points
function Geometry.bounds(points: { Vec }): { min: Vec, max: Vec }
	local lo = { math.huge, math.huge, math.huge }
	local hi = { -math.huge, -math.huge, -math.huge }
	for _, p in points do
		for i = 1, 3 do
			if p[i] < lo[i] then
				lo[i] = p[i]
			end
			if p[i] > hi[i] then
				hi[i] = p[i]
			end
		end
	end
	return { min = lo, max = hi }
end

-- world-axis bounds of pieces (their real corners); nil for an empty list
function Geometry.piecesBounds(pieces, frame)
	local pts = {}
	for _, pc in pieces do
		local f = frame and F.mul(frame, pc.cf) or pc.cf
		for _, c in Geometry.shapeCorners(pc.shape, f, pc.size) do
			table.insert(pts, c)
		end
	end
	if #pts == 0 then
		return nil
	end
	return Geometry.bounds(pts)
end

-- bounds of box corners measured in the axes of `rot` (oriented bounding box): frame + size
function Geometry.orientedBounds(rot, boxes)
	local rt = M.transpose(rot)
	local pts = {}
	for _, b in boxes do
		for _, c in Geometry.boxCorners(b.cf, b.size) do
			table.insert(pts, M.apply(rt, c))
		end
	end
	local bb = Geometry.bounds(pts)
	local centerLocal = V.mid(bb.min, bb.max)
	return { p = M.apply(rot, centerLocal), r = rot }, sub(bb.max, bb.min)
end

-- ---------------------------------------------------------------------------------------------
-- triangles -> wedges (the classic algorithm)
-- ---------------------------------------------------------------------------------------------
-- A triangle is split by one of its altitudes into two right triangles, each the cross-section of a WedgePart (right
-- angle at the foot). The edge whose foot lands nearest its middle is used (no slivers; stravant's GapFill does the
-- same, MIT, reimplemented here); a triangle with a right angle is exactly one wedge.
-- opts: thickness (studs, default 0.2), align = "center" (the triangle is the wedges' mid-plane, default) | "front"
-- (the wedges sit behind the triangle: its face is on the triangle, thickness goes against the normal of a -> b -> c)
-- | "back" (the opposite side). Returns pieces (shape "Wedge") + the unit normal, or nil + error message.
function Geometry.triangleWedges(a, b, c, opts)
	opts = opts or {}
	local thickness = opts.thickness or 0.2
	if type(thickness) ~= "number" or thickness ~= thickness or thickness <= 0 then
		return nil, "Grosimea trebuie să fie un număr pozitiv."
	end
	thickness = max(thickness, Geometry.MIN_SIZE)
	local n = cross(sub(b, a), sub(c, a))
	local area2 = len(n)
	if area2 < 1e-7 then
		return nil, "Triunghi degenerat: cele trei puncte sunt (aproape) coliniare."
	end
	n = scale(n, 1 / area2)
	-- pick the split: (apex, p, q) = the vertex opposite the edge p q and the edge
	local verts = { a, b, c }
	local bestApex, bestP, bestQ, bestScore, rightAngle
	for i = 1, 3 do
		local apex, p, q = verts[i], verts[i % 3 + 1], verts[(i + 1) % 3 + 1]
		local e1, e2 = sub(p, apex), sub(q, apex)
		if abs(dot(e1, e2)) <= 1e-9 * len(e1) * len(e2) then
			rightAngle = i
		end
		local edge = sub(q, p)
		local u = dot(sub(apex, p), edge) / dot(edge, edge) -- where the foot lands on p -> q (0..1 = inside)
		if u >= -1e-9 and u <= 1 + 1e-9 then
			local score = abs(u - 0.5)
			if not bestScore or score < bestScore then
				bestApex, bestP, bestQ, bestScore = apex, p, q, score
			end
		end
	end
	local shift = { 0, 0, 0 }
	if opts.align == "front" then
		shift = scale(n, -thickness / 2)
	elseif opts.align == "back" then
		shift = scale(n, thickness / 2)
	end
	-- one wedge from the right triangle (apex, foot, base): right angle at the foot, apex up, base at the front
	local function wedge(apex, foot, base)
		local height = V.dist(apex, foot)
		local depth = V.dist(base, foot)
		if height < Geometry.MIN_SIZE or depth < Geometry.MIN_SIZE then
			return nil
		end
		local up = scale(sub(apex, foot), 1 / height)
		local back = scale(sub(foot, base), 1 / depth)
		local center = add(add(foot, scale(up, height / 2)), scale(back, -depth / 2))
		return { shape = "Wedge", size = { thickness, height, depth }, cf = { p = add(center, shift), r = M.fromColumns(cross(up, back), up, back) } }
	end
	local out = {}
	if rightAngle then
		local v = verts[rightAngle]
		local p, q = verts[rightAngle % 3 + 1], verts[(rightAngle + 1) % 3 + 1]
		local w = wedge(q, v, p)
		if w then
			table.insert(out, w)
		end
	else
		local edge = sub(bestQ, bestP)
		local dir = scale(edge, 1 / len(edge))
		local foot = add(bestP, scale(dir, dot(sub(bestApex, bestP), dir)))
		if V.dist(bestApex, foot) < Geometry.MIN_SIZE then
			return nil, "Triunghi degenerat: prea subțire (înălțime < " .. Geometry.MIN_SIZE .. ")."
		end
		for _, base in { bestP, bestQ } do
			local w = wedge(bestApex, foot, base)
			if w then
				table.insert(out, w)
			end
		end
	end
	if #out == 0 then
		return nil, "Triunghi degenerat: prea mic pentru o piesă."
	end
	return out, nil, n
end

-- the triangle a wedge piece covers on its mid-plane (x = 0): bottom-front, bottom-back (right angle), top-back
function Geometry.wedgeTriangle(f, size)
	local h = scale(size, 0.5)
	return { F.point(f, { 0, -h[2], -h[3] }), F.point(f, { 0, -h[2], h[3] }), F.point(f, { 0, h[2], h[3] }) }
end

function Geometry.triangleArea(a: Vec, b: Vec, c: Vec): number
	return len(cross(sub(b, a), sub(c, a))) / 2
end

-- ---------------------------------------------------------------------------------------------
-- polygons
-- ---------------------------------------------------------------------------------------------
-- Newell normal of a (possibly non-planar) polygon, not normalised; zero for a degenerate one
function Geometry.polygonNormal(points)
	local nx, ny, nz = 0, 0, 0
	local count = #points
	for i = 1, count do
		local p, q = points[i], points[i % count + 1]
		nx += (p[2] - q[2]) * (p[3] + q[3])
		ny += (p[3] - q[3]) * (p[1] + q[1])
		nz += (p[1] - q[1]) * (p[2] + q[2])
	end
	return { nx, ny, nz }
end

-- ear clipping of a simple polygon (3D points, roughly planar, any winding). Returns { { i, j, k } } index triples in
-- the polygon's own winding, or nil + error. Collinear and duplicate points are dropped first.
function Geometry.triangulate(points)
	local count = #points
	if count < 3 then
		return nil, "Un poligon are nevoie de cel puțin 3 puncte."
	end
	local normal = unit(Geometry.polygonNormal(points), nil)
	if not normal then
		return nil, "Poligon degenerat: punctele sunt coliniare."
	end
	-- 2D projection on the polygon's plane, counter-clockwise around the normal
	local u = V.perpendicular(normal)
	local w = cross(normal, u)
	local pts2 = {}
	for i, p in points do
		pts2[i] = { dot(p, u), dot(p, w) }
	end
	local idx = {}
	for i = 1, count do
		local prev = idx[#idx]
		if not prev or V.dist(points[prev], points[i]) > 1e-9 then
			table.insert(idx, i)
		end
	end
	if #idx > 1 and V.dist(points[idx[1]], points[idx[#idx]]) <= 1e-9 then
		table.remove(idx)
	end
	local function crossZ(a, b, c)
		return (pts2[b][1] - pts2[a][1]) * (pts2[c][2] - pts2[a][2]) - (pts2[b][2] - pts2[a][2]) * (pts2[c][1] - pts2[a][1])
	end
	local function inside(pIdx, a, b, c)
		local d1, d2, d3 = crossZ(a, b, pIdx), crossZ(b, c, pIdx), crossZ(c, a, pIdx)
		return d1 >= -1e-12 and d2 >= -1e-12 and d3 >= -1e-12
	end
	local tris = {}
	local guard = 0
	while #idx > 3 do
		guard += 1
		if guard > count * count + 10 then
			return nil, "Poligonul se intersectează singur (nu se poate triangula)."
		end
		local n = #idx
		local clipped = false
		for i = 1, n do
			local ia, ib, ic = idx[(i - 2) % n + 1], idx[i], idx[i % n + 1]
			local turn = crossZ(ia, ib, ic)
			if abs(turn) <= 1e-12 * max(1, V.dist(points[ia], points[ic]) ^ 2) then
				-- collinear: drop the middle point
				table.remove(idx, i)
				clipped = true
				break
			elseif turn > 0 then
				local ear = true
				for _, other in idx do
					if other ~= ia and other ~= ib and other ~= ic and inside(other, ia, ib, ic) then
						ear = false
						break
					end
				end
				if ear then
					table.insert(tris, { ia, ib, ic })
					table.remove(idx, i)
					clipped = true
					break
				end
			end
		end
		if not clipped then
			return nil, "Poligonul se intersectează singur (nu se poate triangula)."
		end
	end
	if #idx == 3 and abs(crossZ(idx[1], idx[2], idx[3])) > 1e-12 then
		table.insert(tris, { idx[1], idx[2], idx[3] })
	end
	if #tris == 0 then
		return nil, "Poligon degenerat: punctele sunt coliniare."
	end
	return tris
end

-- wedges for a polygon (fan / ear clipping), opts as triangleWedges
function Geometry.polygonWedges(points, opts)
	local tris, err = Geometry.triangulate(points)
	if not tris then
		return nil, err
	end
	local out = {}
	for _, t in tris do
		local w = Geometry.triangleWedges(points[t[1]], points[t[2]], points[t[3]], opts)
		for _, piece in (w or {}) do
			table.insert(out, piece)
		end
	end
	if #out == 0 then
		return nil, "Poligon degenerat."
	end
	return out
end

-- the block covering the rectangle p1 p2 (p2 + p4 - p1) p4, winding p1 -> p2 -> ... (its normal = (p2-p1) x (p4-p1))
local function rectangleBlock(p1, p2, p4, opts)
	local thickness = max(opts.thickness or 0.2, Geometry.MIN_SIZE)
	local e1, e2 = sub(p2, p1), sub(p4, p1)
	local l1, l2 = len(e1), len(e2)
	local n = unit(cross(e1, e2), nil)
	if not n or l1 < Geometry.MIN_SIZE or l2 < Geometry.MIN_SIZE then
		return nil
	end
	local x, z = scale(e1, 1 / l1), scale(e2, 1 / l2)
	local center = V.mid(p2, p4)
	if opts.align == "front" then -- like triangleWedges: the thickness goes against the normal
		center = add(center, scale(n, -thickness / 2))
	elseif opts.align == "back" then
		center = add(center, scale(n, thickness / 2))
	end
	return { shape = "Block", size = { l1, thickness, l2 }, cf = { p = center, r = M.fromColumns(x, cross(z, x), z) } }
end

-- distinct points of a polygon (keeps the order)
local function distinct(points)
	local out = {}
	for _, p in points do
		local dup = false
		for _, q in out do
			if V.dist(p, q) < 1e-6 then
				dup = true
				break
			end
		end
		if not dup then
			table.insert(out, p)
		end
	end
	return out
end

local function fillPolygonPieces(points, opts, out)
	local pts = distinct(points)
	if #pts == 3 then
		for _, w in (Geometry.triangleWedges(pts[1], pts[2], pts[3], opts) or {}) do
			table.insert(out, w)
		end
	elseif #pts > 3 then
		for _, w in (Geometry.polygonWedges(pts, opts) or {}) do
			table.insert(out, w)
		end
	end
end

-- Fill between two edges (pairs of points): the quad a1 a2 b2 b1 (b is reversed when that avoids a bow-tie).
-- Parallel edges (the idea of stravant's GapFill, MIT; reimplemented): one block over the stretch the edges share
-- + a right triangle (one wedge) at each end. Otherwise two triangles split on the shorter diagonal (2-4 wedges).
function Geometry.gapFill(edgeA, edgeB, opts)
	opts = opts or {}
	local a1, a2, b1, b2 = edgeA[1], edgeA[2], edgeB[1], edgeB[2]
	if V.dist(a1, b1) + V.dist(a2, b2) > V.dist(a1, b2) + V.dist(a2, b1) + 1e-9 then
		b1, b2 = b2, b1
	end
	local quad = distinct({ a1, a2, b2, b1 })
	if #quad < 3 then
		return nil, "Muchiile coincid: nu e nimic de umplut."
	elseif #quad == 3 then
		return Geometry.triangleWedges(quad[1], quad[2], quad[3], opts)
	end
	local out = {}
	local lenA = V.dist(a1, a2)
	local dirA = lenA > 1e-9 and scale(sub(a2, a1), 1 / lenA) or nil
	local dirB = unit(sub(b2, b1), nil)
	if dirA and dirB and len(cross(dirA, dirB)) < 1e-6 and dot(dirA, dirB) > 0 then
		local s1, s2 = dot(sub(b1, a1), dirA), dot(sub(b2, a1), dirA)
		local lo, hi = max(0, s1), min(lenA, s2)
		local aLo, aHi = add(a1, scale(dirA, lo)), add(a1, scale(dirA, hi))
		local bLo, bHi = add(b1, scale(dirA, lo - s1)), add(b1, scale(dirA, hi - s1))
		local block = hi - lo > Geometry.MIN_SIZE and rectangleBlock(aLo, aHi, bLo, opts)
		if block then
			table.insert(out, block)
			fillPolygonPieces({ a1, aLo, bLo, b1 }, opts, out)
			fillPolygonPieces({ aHi, a2, b2, bHi }, opts, out)
			return out
		elseif V.dist(aLo, bLo) < 1e-9 then
			return nil, "Muchiile sunt coliniare: nu e nimic de umplut."
		end
	end
	local t1, t2
	if V.dist(a1, b2) <= V.dist(a2, b1) then
		t1, t2 = { a1, a2, b2 }, { a1, b2, b1 }
	else
		t1, t2 = { a1, a2, b1 }, { a2, b2, b1 }
	end
	for _, t in { t1, t2 } do
		local w = Geometry.triangleWedges(t[1], t[2], t[3], opts)
		for _, piece in (w or {}) do
			table.insert(out, piece)
		end
	end
	if #out == 0 then
		return nil, "Muchiile sunt coliniare: nu e nimic de umplut."
	end
	return out
end

-- ---------------------------------------------------------------------------------------------
-- arrays: world transforms T (frames) to left-multiply with every part of the group (copy = T * part)
-- `count` is always the TOTAL number of items, the original included (count = 5 -> 4 new copies)
-- ---------------------------------------------------------------------------------------------
local function checkCount(count)
	if type(count) ~= "number" or count ~= count or count < 2 or count > 1000 or count % 1 ~= 0 then
		return "Numărul de elemente trebuie să fie un întreg între 2 și 1000 (originalul inclus)."
	end
	return nil
end
Geometry.checkCount = checkCount

function Geometry.linearTransforms(offset, count)
	local err = checkCount(count)
	if err then
		return nil, err
	end
	if len(offset) < EPS then
		return nil, "Distanța dintre copii nu poate fi zero."
	end
	local out = {}
	for k = 1, count - 1 do
		table.insert(out, { p = scale(offset, k), r = M.IDENTITY })
	end
	return out
end

-- copies around the world axis through `center`; angle = total angle in degrees (360 = full ring: the items are spread
-- evenly and the last one does not land on the original)
function Geometry.radialTransforms(center, axis, count, angle)
	local err = checkCount(count)
	if err then
		return nil, err
	end
	local ax = unit(axis, nil)
	if not ax then
		return nil, "Axa rotației nu poate fi zero."
	end
	angle = angle or 360
	local step = (abs(angle) >= 360 - 1e-9) and (angle / count) or (angle / (count - 1))
	local out = {}
	for k = 1, count - 1 do
		table.insert(out, F.rotationAbout(center, ax, math.rad(step * k)))
	end
	return out
end

local AXIS = { X = 1, Y = 2, Z = 3 }
Geometry.AXIS = AXIS
local function unitAxis(i, sign)
	local v = { 0, 0, 0 }
	v[i] = sign or 1
	return v
end
Geometry.unitAxis = unitAxis

-- Archimedes-style arc: every copy continues the previous one along its length and turns by `angle` around the edge
-- they share, so curved walls, rings and ramps close without gaps on the inside of the turn.
--   ref = { cf = frame, size = vector }: the reference box (a part, or the group's oriented bounds)
--   opts.axis   "X" | "Y" | "Z" (local axis of ref; default "Y")
--   opts.angle  degrees per copy (default 15; the sign picks the side of the turn)
--   opts.count  total items (default 6)
--   opts.length the local axis the copies continue along (default: the longer of the two other axes)
--   opts.radius extra distance of the pivot from the inner edge (0 = the edge itself; larger = wider curve)
--   opts.pivot  local point to turn around (overrides the edge), opts.step local translation before turning
function Geometry.arcTransforms(ref, opts)
	opts = opts or {}
	local count = opts.count or 6
	local err = checkCount(count)
	if err then
		return nil, err
	end
	local ai = AXIS[opts.axis or "Y"]
	if not ai then
		return nil, "Axa trebuie să fie X, Y sau Z."
	end
	local angle = opts.angle or 15
	if type(angle) ~= "number" or angle ~= angle or abs(angle) < 1e-6 or abs(angle) > 180 then
		return nil, "Unghiul trebuie să fie între -180 și 180 de grade (și nu 0)."
	end
	local size = ref.size
	local others = {}
	for i = 1, 3 do
		if i ~= ai then
			table.insert(others, i)
		end
	end
	local li = AXIS[opts.length or ""] or ((size[others[1]] >= size[others[2]]) and others[1] or others[2])
	if li == ai then
		return nil, "Direcția de continuare nu poate fi chiar axa rotației."
	end
	local wi = (others[1] == li) and others[2] or others[1]
	local axisV = unitAxis(ai)
	local lengthV = unitAxis(li)
	-- the inner side: rotating +angle around the axis turns +length toward axis x length
	local turnDir = cross(axisV, lengthV)
	local sideSign = (turnDir[wi] >= 0 and 1 or -1) * (angle > 0 and 1 or -1)
	local pivot = opts.pivot
	if not pivot then
		pivot = { 0, 0, 0 }
		pivot[li] = size[li] / 2
		pivot[wi] = sideSign * (size[wi] / 2 + (opts.radius or 0))
	end
	local step = opts.step or scale(lengthV, size[li])
	-- local step: move by `step`, then turn around the pivot (expressed after the move: the shared edge)
	local turn = F.rotationAbout(pivot, axisV, math.rad(angle))
	local delta = F.mul(turn, { p = step, r = M.IDENTITY })
	local out = {}
	local acc = F.IDENTITY
	local inv = F.inv(ref.cf)
	for _ = 1, count - 1 do
		acc = F.mul(acc, delta)
		table.insert(out, F.mul(F.mul(ref.cf, acc), inv))
	end
	return out
end

-- ---------------------------------------------------------------------------------------------
-- mirror (Model Reflect)
-- ---------------------------------------------------------------------------------------------
-- reflection of a point across the plane (point q, normal n)
function Geometry.reflectPoint(p, q, n)
	local d = dot(sub(p, q), n)
	return sub(p, scale(n, 2 * d))
end

-- Mirrors a part. A reflection has det -1, which no CFrame can hold, so the result is the reflected shape expressed as
-- a proper rotation of a (possibly re-sized) part of the same kind:
--   Block / Cylinder / Ball / unknown: flip the local axis most aligned with the plane normal (symmetric shapes: exact)
--   Wedge: flip local X (a wedge is symmetric across its YZ plane)
--   CornerWedge: compose with the diagonal reflection that maps the apex corner onto the apex of a part with X and Z
--   sizes swapped (exact)
-- MeshParts / unions are only right when their mesh is symmetric across the flipped axis: `exact` = false for them.
-- Returns frame, size, exact (bool).
-- I - 2 n n^T (n unit): the reflection across a plane with normal n
function Geometry.reflection(n)
	return {
		1 - 2 * n[1] * n[1], -2 * n[1] * n[2], -2 * n[1] * n[3],
		-2 * n[2] * n[1], 1 - 2 * n[2] * n[2], -2 * n[2] * n[3],
		-2 * n[3] * n[1], -2 * n[3] * n[2], 1 - 2 * n[3] * n[3],
	}
end

function Geometry.mirrorFrame(f, size, shape, planePoint, planeNormal)
	local n = unit(planeNormal, nil)
	assert(n, "normala planului nu poate fi zero")
	local reflect = Geometry.reflection(n)
	local p = Geometry.reflectPoint(f.p, planePoint, n)
	local r = M.mul(reflect, f.r)
	local newSize = V.copy(size)
	local exact = true
	if shape == "Wedge" then
		r = M.mul(r, { -1, 0, 0, 0, 1, 0, 0, 0, 1 })
	elseif shape == "CornerWedge" then
		-- (x, y, z) -> (s z, y, s x) maps the apex corner of an (X, Y, Z) part to the one of a (Z, Y, X) part; with the
		-- apex at (+x, -z) this is diag(-1, 1, 1) * Ry(90 degrees), as in docs/modeling-research.md 1.4-E
		local a = Geometry.CORNER_APEX
		local s = a[1] * a[3]
		r = M.mul(r, { 0, 0, s, 0, 1, 0, s, 0, 0 })
		newSize = { size[3], size[2], size[1] }
	else
		local best, bestDot = 1, -1
		for i = 1, 3 do
			local d = abs(dot(M.column(f.r, i), n))
			if d > bestDot + 1e-9 then
				best, bestDot = i, d
			end
		end
		local fix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
		fix[(best - 1) * 4 + 1] = -1
		r = M.mul(r, fix)
		exact = shape == "Block" or shape == "Cylinder" or shape == "Ball"
	end
	return { p = p, r = r }, newSize, exact
end

-- ---------------------------------------------------------------------------------------------
-- align / distribute / snap (world axes, on bounds { min, max })
-- ---------------------------------------------------------------------------------------------
-- offsets (vectors) that align the boxes on `axis` ("X" | "Y" | "Z"); mode "min" | "center" | "max";
-- target: a number (the coordinate to align to) or nil (min: the smallest min, max: the largest max, center: the mean)
function Geometry.alignOffsets(boxes, axis, mode, target)
	local i = AXIS[axis or ""]
	if not i then
		return nil, "Axa trebuie să fie X, Y sau Z."
	end
	mode = mode or "min"
	if mode ~= "min" and mode ~= "max" and mode ~= "center" then
		return nil, "Modul trebuie să fie min, center sau max."
	end
	local function key(b)
		if mode == "min" then
			return b.min[i]
		elseif mode == "max" then
			return b.max[i]
		end
		return (b.min[i] + b.max[i]) / 2
	end
	if target == nil then
		if mode == "min" then
			target = math.huge
			for _, b in boxes do
				target = min(target, key(b))
			end
		elseif mode == "max" then
			target = -math.huge
			for _, b in boxes do
				target = max(target, key(b))
			end
		else
			local sum = 0
			for _, b in boxes do
				sum += key(b)
			end
			target = sum / max(1, #boxes)
		end
	end
	local out = {}
	for k, b in boxes do
		local v = { 0, 0, 0 }
		v[i] = target - key(b)
		out[k] = v
	end
	return out
end

-- offsets that spread the boxes evenly on `axis` between the first and the last one (sorted by centre). mode "gap"
-- (default: equal empty space between neighbours) | "center" (equal distance between centres)
function Geometry.distributeOffsets(boxes, axis, mode)
	local i = AXIS[axis or ""]
	if not i then
		return nil, "Axa trebuie să fie X, Y sau Z."
	end
	if #boxes < 3 then
		return nil, "Distribuirea are nevoie de cel puțin 3 piese."
	end
	local order = {}
	for k in boxes do
		table.insert(order, k)
	end
	local function c(b)
		return (b.min[i] + b.max[i]) / 2
	end
	table.sort(order, function(x, y)
		local cx, cy = c(boxes[x]), c(boxes[y])
		if cx == cy then
			return x < y
		end
		return cx < cy
	end)
	local out = {}
	for k in boxes do
		out[k] = { 0, 0, 0 }
	end
	local first, last = boxes[order[1]], boxes[order[#order]]
	if mode == "center" then
		local c0, c1 = c(first), c(last)
		for rank, k in order do
			local want = c0 + (c1 - c0) * (rank - 1) / (#order - 1)
			out[k][i] = want - c(boxes[k])
		end
	else
		local total = 0
		for _, k in order do
			total += boxes[k].max[i] - boxes[k].min[i]
		end
		local span = last.max[i] - first.min[i]
		local gap = (span - total) / (#order - 1)
		local cursor = first.min[i]
		for _, k in order do
			local b = boxes[k]
			out[k][i] = cursor - b.min[i]
			cursor += (b.max[i] - b.min[i]) + gap
		end
	end
	return out
end

local function roundTo(x: number, step: number): number
	return floor(x / step + 0.5) * step
end
Geometry.roundTo = roundTo

-- snaps a frame's position to `grid` studs (number, or vector per axis) and, when rotStep (degrees) is given, its
-- orientation to multiples of rotStep
function Geometry.snapFrame(f, grid, rotStep)
	local g = type(grid) == "table" and grid or { grid, grid, grid }
	local p = V.copy(f.p)
	for i = 1, 3 do
		if g[i] and g[i] > 0 then
			p[i] = roundTo(p[i], g[i])
		end
	end
	local r = f.r
	if rotStep and rotStep > 0 then
		local o = F.orientation(f)
		r = M.fromOrientation(math.rad(roundTo(o[1], rotStep)), math.rad(roundTo(o[2], rotStep)), math.rad(roundTo(o[3], rotStep)))
	end
	return { p = p, r = r }
end

-- ResizeAlign: how far the face (normal n, corners) must move along n to reach the plane (point q, normal m).
-- mode "center" (the face centre reaches the plane), "outer" (every corner reaches it), "inner" (the first corner
-- touches it). Returns the distance (negative = the face moves back) or nil + error.
function Geometry.extendDistance(faceCorners, n, q, m, mode)
	local denom = dot(n, m)
	if abs(denom) < 1e-6 then
		return nil, "Fața țintă e paralelă cu direcția de extindere: nu se pot întâlni."
	end
	local function distFor(p)
		return dot(sub(q, p), m) / denom
	end
	if mode == "outer" or mode == "inner" then
		local best
		for _, cpt in faceCorners do
			local d = distFor(cpt)
			if best == nil or (mode == "outer" and d > best) or (mode == "inner" and d < best) then
				best = d
			end
		end
		return best
	end
	local center = { 0, 0, 0 }
	for _, cpt in faceCorners do
		center = add(center, cpt)
	end
	return distFor(scale(center, 1 / #faceCorners))
end

-- the 4 corners and the outward normal of a box face; face = "Right" | "Left" | "Top" | "Bottom" | "Back" | "Front"
-- (Enum.NormalId names: Right = +X, Top = +Y, Back = +Z)
local FACES = { Right = { 1, 1 }, Left = { 1, -1 }, Top = { 2, 1 }, Bottom = { 2, -1 }, Back = { 3, 1 }, Front = { 3, -1 } }
Geometry.FACES = FACES
function Geometry.boxFace(f, size, face)
	local spec = FACES[face]
	assert(spec, "față necunoscută " .. tostring(face))
	local i, sgn = spec[1], spec[2]
	local h = scale(size, 0.5)
	local j, k = i % 3 + 1, (i + 1) % 3 + 1
	local corners = {}
	for _, sj in { -1, 1 } do
		for _, sk in { -1, 1 } do
			local v = { 0, 0, 0 }
			v[i] = sgn * h[i]
			v[j] = sj * h[j]
			v[k] = sk * h[k]
			table.insert(corners, F.point(f, v))
		end
	end
	return corners, F.vector(f, unitAxis(i, sgn)), i, sgn
end

-- a part grown (or shrunk) by `dist` along one face: new frame + size, or nil + error
function Geometry.resizeFace(f, size, face, dist)
	local spec = FACES[face]
	if not spec then
		return nil, "Fața trebuie să fie Right, Left, Top, Bottom, Back sau Front."
	end
	local i, sgn = spec[1], spec[2]
	local newSize = V.copy(size)
	newSize[i] = size[i] + dist
	if newSize[i] < Geometry.MIN_SIZE then
		return nil, "Piesa ar ajunge la o dimensiune negativă (ținta e în spatele feței opuse)."
	elseif newSize[i] > Geometry.MAX_SIZE then
		return nil, "Piesa ar depăși " .. Geometry.MAX_SIZE .. " de studs."
	end
	local shift = { 0, 0, 0 }
	shift[i] = sgn * dist / 2
	return { p = F.point(f, shift), r = f.r }, newSize
end

-- ---------------------------------------------------------------------------------------------
-- deterministic random numbers (Park-Miller: exact in doubles, the same in Studio and in the tests)
-- ---------------------------------------------------------------------------------------------
function Geometry.rng(seed)
	local s = floor(abs(tonumber(seed) or 1)) % 2147483646 + 1
	local self = {}
	function self.next() -- [0, 1)
		s = (s * 48271) % 2147483647
		return (s - 1) / 2147483646
	end
	function self.range(a, b)
		return a + (b - a) * self.next()
	end
	function self.int(a, b)
		return min(b, a + floor(self.next() * (b - a + 1)))
	end
	function self.sign()
		return self.next() < 0.5 and -1 or 1
	end
	for _ = 1, 3 do
		self.next()
	end
	return self
end

-- ---------------------------------------------------------------------------------------------
-- Poisson-disk-ish sampling (dart throwing on a grid): points { x, z } in a rectangle, at least minDistance apart
-- ---------------------------------------------------------------------------------------------
function Geometry.poissonSample(rng, x0, z0, x1, z1, count, minDistance, attempts)
	local out = {}
	minDistance = max(0, minDistance or 0)
	attempts = attempts or count * 30
	local cell = minDistance > 0 and minDistance / sqrt(2) or 1
	local grid = {}
	local function key(ix, iz)
		return ix * 73856093 + iz * 19349663
	end
	local function ok(x, z)
		if minDistance <= 0 then
			return true
		end
		local ix, iz = floor((x - x0) / cell), floor((z - z0) / cell)
		for dx = -2, 2 do
			for dz = -2, 2 do
				local list = grid[key(ix + dx, iz + dz)]
				if list then
					for _, p in list do
						local ex, ez = p[1] - x, p[2] - z
						if ex * ex + ez * ez < minDistance * minDistance then
							return false
						end
					end
				end
			end
		end
		return true
	end
	local tries = 0
	while #out < count and tries < attempts do
		tries += 1
		local x, z = rng.range(x0, x1), rng.range(z0, z1)
		if ok(x, z) then
			local p = { x, z }
			table.insert(out, p)
			if minDistance > 0 then
				local k = key(floor((x - x0) / cell), floor((z - z0) / cell))
				grid[k] = grid[k] or {}
				table.insert(grid[k], p)
			end
		end
	end
	return out
end

-- ---------------------------------------------------------------------------------------------
-- splines: a cardinal (Catmull-Rom when tension = 0) curve through every control point, with an arc-length table
-- ---------------------------------------------------------------------------------------------
-- points: { vector } (>= 2); opts: tension (0..1, default 0: smooth; 1: straight segments), alpha (0 = uniform,
-- 0.5 = centripetal (default: no cusps or self-loops on uneven spacing), 1 = chordal), segments (samples per span for
-- the length table, default 16), closed (bool). Returns an evaluator:
--   s.at(t) / s.tangent(t)       t in [0, 1] over the whole curve (spans share it evenly)
--   s.length                     total arc length
--   s.atDistance(d), s.tangentAtDistance(d)
--   s.samples(spacing)           { { p, tangent, d } } every `spacing` studs (both ends included)
--   s.frames(spacing, up)        { { p = .., r = .. } } oriented along the curve (-Z forward), parallel-transported up
function Geometry.spline(points, opts)
	opts = opts or {}
	local pts = {}
	for _, p in points or {} do
		local v = V.from(p)
		if not v then
			return nil, "Punctele curbei trebuie să fie vectori { x, y, z }."
		end
		if #pts == 0 or V.dist(pts[#pts], v) > 1e-9 then
			table.insert(pts, v)
		end
	end
	local closed = opts.closed == true
	if closed and #pts > 2 and V.dist(pts[1], pts[#pts]) <= 1e-9 then
		table.remove(pts)
	end
	if #pts < 2 then
		return nil, "O curbă are nevoie de cel puțin 2 puncte distincte."
	end
	local tension = opts.tension or 0
	if type(tension) ~= "number" or tension ~= tension then
		tension = 0
	end
	tension = max(0, min(1, tension))
	local segments = max(2, min(256, floor(opts.segments or 16)))
	local n = #pts
	local spans = closed and n or n - 1
	local function P(i)
		if closed then
			return pts[(i - 1) % n + 1]
		end
		if i < 1 then -- reflected end points: the curve leaves the ends in the direction of the first / last span
			return sub(scale(pts[1], 2), pts[2])
		elseif i > n then
			return sub(scale(pts[n], 2), pts[n - 1])
		end
		return pts[i]
	end
	local alpha = type(opts.alpha) == "number" and max(0, min(1, opts.alpha)) or 0.5
	local function knot(a, b)
		return max(1e-6, V.dist(a, b) ^ alpha)
	end
	local function span(t)
		t = max(0, min(1, t)) * spans
		local i = min(spans - 1, floor(t))
		return i + 1, t - i
	end
	-- non-uniform Catmull-Rom as a cubic Hermite span: tangents from the knot intervals d0, d1, d2
	local function hermite(i, u)
		local p0, p1, p2, p3 = P(i - 1), P(i), P(i + 1), P(i + 2)
		local d0, d1, d2 = knot(p0, p1), knot(p1, p2), knot(p2, p3)
		local m1 = add(sub(scale(sub(p1, p0), 1 / d0), scale(sub(p2, p0), 1 / (d0 + d1))), scale(sub(p2, p1), 1 / d1))
		local m2 = add(sub(scale(sub(p2, p1), 1 / d1), scale(sub(p3, p1), 1 / (d1 + d2))), scale(sub(p3, p2), 1 / d2))
		m1 = scale(m1, d1 * (1 - tension))
		m2 = scale(m2, d1 * (1 - tension))
		local u2, u3 = u * u, u * u * u
		local h00, h10, h01, h11 = 2 * u3 - 3 * u2 + 1, u3 - 2 * u2 + u, -2 * u3 + 3 * u2, u3 - u2
		local d00, d10, d01, d11 = 6 * u2 - 6 * u, 3 * u2 - 4 * u + 1, -6 * u2 + 6 * u, 3 * u2 - 2 * u
		local pos = add(add(scale(p1, h00), scale(m1, h10)), add(scale(p2, h01), scale(m2, h11)))
		local der = add(add(scale(p1, d00), scale(m1, d10)), add(scale(p2, d01), scale(m2, d11)))
		return pos, der
	end
	local s = { points = pts, closed = closed, spans = spans }
	function s.at(t)
		local i, u = span(t)
		return (hermite(i, u))
	end
	function s.tangent(t)
		local i, u = span(t)
		local _, d = hermite(i, u)
		local tu = unit(d, nil)
		if not tu then -- zero derivative (tension 1 at a control point): the chord direction
			tu = unit(sub(P(i + 1), P(i)), { 0, 0, -1 })
		end
		return tu
	end
	-- arc-length table
	local ts, ds = { 0 }, { 0 }
	local total = 0
	local prev = s.at(0)
	local steps = spans * segments
	for j = 1, steps do
		local t = j / steps
		local p = s.at(t)
		total += V.dist(prev, p)
		prev = p
		table.insert(ts, t)
		table.insert(ds, total)
	end
	s.length = total
	local function tAt(d)
		if d <= 0 then
			return 0
		elseif d >= total then
			return 1
		end
		local lo, hi = 1, #ds
		while hi - lo > 1 do
			local mid = (lo + hi) // 2
			if ds[mid] <= d then
				lo = mid
			else
				hi = mid
			end
		end
		local seg = ds[hi] - ds[lo]
		local f = seg > 0 and (d - ds[lo]) / seg or 0
		return ts[lo] + (ts[hi] - ts[lo]) * f
	end
	s.tAt = tAt
	function s.atDistance(d)
		return s.at(tAt(d))
	end
	function s.tangentAtDistance(d)
		return s.tangent(tAt(d))
	end
	function s.samples(spacing)
		spacing = spacing or 4
		if type(spacing) ~= "number" or spacing ~= spacing or spacing <= 0 then
			spacing = 4
		end
		local count = max(1, floor(total / spacing + 0.5))
		local out = {}
		for j = 0, count do
			local d = total * j / count
			local t = tAt(d)
			table.insert(out, { p = s.at(t), tangent = s.tangent(t), d = d })
		end
		return out
	end
	function s.frames(spacing, upHint)
		local out = {}
		local up = upHint or { 0, 1, 0 }
		for _, smp in s.samples(spacing) do
			local f = smp.tangent
			-- parallel transport: keep the previous up, minus its component along the new tangent
			local u = sub(up, scale(f, dot(up, f)))
			if len(u) < 1e-4 then
				u = V.perpendicular(f)
			end
			up = unit(u) :: any
			table.insert(out, { p = smp.p, r = M.lookAlong(f, up), d = smp.d })
		end
		return out
	end
	return s
end

-- ---------------------------------------------------------------------------------------------
-- pieces along a polyline (segments between consecutive points)
-- ---------------------------------------------------------------------------------------------
-- a block from a to b (length along its Z), width x height cross-section, Y as close to `up` as possible
function Geometry.beam(a, b, width, height, up)
	local d = sub(b, a)
	local l = len(d)
	if l < Geometry.MIN_SIZE then
		return nil
	end
	return { shape = "Block", size = { width, height, l }, cf = { p = V.mid(a, b), r = M.lookAlong(d, up) } }
end

-- a cylinder from a to b (Roblox cylinders run along their X axis)
function Geometry.rod(a, b, diameter)
	local d = sub(b, a)
	local l = len(d)
	if l < Geometry.MIN_SIZE then
		return nil
	end
	return { shape = "Cylinder", size = { l, diameter, diameter }, cf = { p = V.mid(a, b), r = M.alongX(d) } }
end

-- ---------------------------------------------------------------------------------------------
-- 3D convex hull (incremental; small point sets: rocks, crystals)
-- ---------------------------------------------------------------------------------------------
-- returns { { i, j, k } } faces wound counter-clockwise seen from outside, or nil + error
function Geometry.convexHull(points)
	local n = #points
	if n < 4 then
		return nil, "Învelișul convex are nevoie de cel puțin 4 puncte."
	end
	local function normalOf(i, j, k)
		return cross(sub(points[j], points[i]), sub(points[k], points[i]))
	end
	-- initial tetrahedron from non-coplanar points
	local i0, i1 = 1, nil
	for i = 2, n do
		if V.dist(points[i], points[i0]) > 1e-7 then
			i1 = i
			break
		end
	end
	if not i1 then
		return nil, "Punctele coincid."
	end
	local i2
	for i = 1, n do
		if i ~= i0 and i ~= i1 and len(normalOf(i0, i1, i)) > 1e-7 then
			i2 = i
			break
		end
	end
	if not i2 then
		return nil, "Punctele sunt coliniare."
	end
	local i3
	local nrm = normalOf(i0, i1, i2)
	for i = 1, n do
		if i ~= i0 and i ~= i1 and i ~= i2 and abs(dot(nrm, sub(points[i], points[i0]))) > 1e-7 then
			i3 = i
			break
		end
	end
	if not i3 then
		return nil, "Punctele sunt coplanare."
	end
	local faces = {}
	local function addFace(a, b, c)
		table.insert(faces, { a, b, c })
	end
	if dot(nrm, sub(points[i3], points[i0])) > 0 then
		addFace(i0, i2, i1)
		addFace(i0, i1, i3)
		addFace(i1, i2, i3)
		addFace(i2, i0, i3)
	else
		addFace(i0, i1, i2)
		addFace(i0, i3, i1)
		addFace(i1, i3, i2)
		addFace(i2, i3, i0)
	end
	local used = { [i0] = true, [i1] = true, [i2] = true, [i3] = true }
	for p = 1, n do
		if not used[p] then
			local visible = {}
			local any = false
			for fi, f in faces do
				local fn = normalOf(f[1], f[2], f[3])
				if dot(fn, sub(points[p], points[f[1]])) > 1e-9 * max(1, len(fn)) then
					visible[fi] = true
					any = true
				end
			end
			if any then
				-- horizon: edges of visible faces whose twin belongs to a hidden face (in face order: deterministic)
				local edges = {}
				for fi, f in faces do
					if visible[fi] then
						for e = 1, 3 do
							edges[f[e] .. ":" .. f[e % 3 + 1]] = true
						end
					end
				end
				local kept = {}
				for fi, f in faces do
					if not visible[fi] then
						table.insert(kept, f)
					end
				end
				for fi, f in faces do
					if visible[fi] then
						for e = 1, 3 do
							local a, b = f[e], f[e % 3 + 1]
							if not edges[b .. ":" .. a] then
								table.insert(kept, { a, b, p })
							end
						end
					end
				end
				faces = kept
			end
		end
	end
	return faces
end

-- ---------------------------------------------------------------------------------------------
-- part -> terrain (the mapping of Quenty's PartToTerrain, MIT; reimplemented): one Fill* call per piece
-- ---------------------------------------------------------------------------------------------
function Geometry.terrainOp(pc, material)
	local s = pc.size
	if pc.shape == "Ball" then
		return { op = "ball", center = V.copy(pc.cf.p), radius = min(s[1], s[2], s[3]) / 2, material = material }
	elseif pc.shape == "Cylinder" then -- terrain cylinders stand on their local Y, parts lie on X
		return { op = "cylinder", cf = F.mul(pc.cf, { p = { 0, 0, 0 }, r = M.rz(pi / 2) }), height = s[1], radius = min(s[2], s[3]) / 2, material = material }
	elseif pc.shape == "Wedge" then
		return { op = "wedge", cf = pc.cf, size = V.copy(s), material = material }
	end
	return { op = "block", cf = pc.cf, size = V.copy(s), material = material }
end

-- ---------------------------------------------------------------------------------------------
-- small helpers for generators
-- ---------------------------------------------------------------------------------------------
-- a piece at a local position + orientation (degrees) inside a parent frame
function Geometry.place(shape, size, pos, deg, extra)
	local piece = { shape = shape, size = size, cf = F.fromPosOrientation(pos, deg) }
	if extra then
		for k, v in extra do
			piece[k] = v
		end
	end
	return piece
end

-- moves pieces by a frame (returns new pieces; the other fields are shared)
function Geometry.transformPieces(pieces, frame)
	local out = {}
	for i, pc in pieces do
		local copy = table.clone(pc)
		copy.cf = F.mul(frame, pc.cf)
		out[i] = copy
	end
	return out
end

-- corner wedge whose apex stands over the base corner in direction (sx, sz) (signs, +-1) of its own footprint;
-- footprint (x, z) and height y; centre = centre of its bounding box
function Geometry.cornerWedge(center, sizeX, sizeY, sizeZ, sx, sz, extra)
	local a = Geometry.CORNER_APEX
	-- rotation about Y by k * 90 degrees mapping the local apex corner (a1, a3) to (sx, sz)
	local best
	for k = 0, 3 do
		local ang = k * pi / 2
		local r = M.ry(ang)
		local swap = k % 2 == 1
		local lx, lz = swap and sizeZ or sizeX, swap and sizeX or sizeZ
		local apex = M.apply(r, { a[1] * lx / 2, 0, a[3] * lz / 2 })
		if (apex[1] > 0) == (sx > 0) and (apex[3] > 0) == (sz > 0) then
			best = { r = r, size = { lx, sizeY, lz } }
			break
		end
	end
	local piece = { shape = "CornerWedge", size = best.size, cf = { p = V.copy(center), r = best.r } }
	if extra then
		for k, v in extra do
			piece[k] = v
		end
	end
	return piece
end

-- four corner wedges = a pyramid with a w x d base, height h, base centre at `base` (y up)
function Geometry.pyramid(base, w, d, h, extra, rot)
	local out = {}
	local r = rot or M.IDENTITY
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			-- the quarter's apex corner points at the pyramid's centre (-sx, -sz from the quarter's centre)
			local c = { sx * w / 4, h / 2, sz * d / 4 }
			local pc = Geometry.cornerWedge(c, w / 2, h, d / 2, -sx, -sz, extra)
			pc.cf = F.mul({ p = base, r = r }, pc.cf)
			table.insert(out, pc)
		end
	end
	return out
end

return Geometry
