-- Modeling, the pure part (no Instances): Geometry (triangle -> wedges on 2000 random triangles, polygons, gap fill,
-- arrays, mirror by comparing the real corner sets of every shape, splines, Poisson sampling, convex hull, align /
-- distribute / resize maths), Generators (every generator and every choice builds; part counts, bounds, determinism,
-- parameter validation), Mesh (closed meshes wound outward, volumes, limits, the wedge fallback) and Spec (JSON codec,
-- compile errors and limits, arrays, describePiece as the inverse of a part).
local LC = ...
local t = LC.kit.new("modeling_geometry")

local tree = LC.modtree.new({ env = LC.env() })
local G = tree.load("Modeling.Geometry")
local Gen = tree.load("Modeling.Generators")
local Mesh = tree.load("Modeling.Mesh")
local Spec = tree.load("Modeling.Spec")
local V, M, F = G.V, G.M, G.F

local function vnear(a, b, eps)
	return V.dist(a, b) <= (eps or 1e-6)
end
local function orthonormal(r, eps)
	eps = eps or 1e-6
	local x, y, z = M.column(r, 1), M.column(r, 2), M.column(r, 3)
	return math.abs(V.len(x) - 1) < eps and math.abs(V.len(y) - 1) < eps and math.abs(V.len(z) - 1) < eps
		and math.abs(V.dot(x, y)) < eps and math.abs(V.dot(y, z)) < eps and math.abs(V.dot(x, z)) < eps
		and math.abs(M.det(r) - 1) < eps
end
-- every point of `a` has a match in `b` and vice versa
local function sameSet(a, b, eps)
	if #a ~= #b then
		return false
	end
	for _, list in { { a, b }, { b, a } } do
		for _, p in list[1] do
			local found = false
			for _, q in list[2] do
				if vnear(p, q, eps) then
					found = true
					break
				end
			end
			if not found then
				return false
			end
		end
	end
	return true
end
local rng = G.rng(12345)
local function rvec(s)
	return { rng.range(-s, s), rng.range(-s, s), rng.range(-s, s) }
end
local function rframe(s)
	local axis = V.unit(rvec(1), { 0, 1, 0 })
	return { p = rvec(s or 50), r = M.axisAngle(axis, rng.range(-math.pi, math.pi)) }
end

-- 1. vectors, matrices, frames ---------------------------------------------------------------------------------------
t.section("matrices", function()
	for _ = 1, 200 do
		local x, y, z = rng.range(-1.5, 1.5), rng.range(-3, 3), rng.range(-3, 3)
		local r = M.fromOrientation(x, y, z)
		t.check(orthonormal(r), "fromOrientation is a rotation")
		local x2, y2, z2 = M.toOrientation(r)
		local back = M.fromOrientation(x2, y2, z2)
		local ok = true
		for i = 1, 9 do
			ok = ok and math.abs(back[i] - r[i]) < 1e-9
		end
		t.check(ok, "toOrientation inverts fromOrientation")
	end
	-- gimbal lock: x = 90 degrees still round-trips the rotation
	local r = M.fromOrientation(math.pi / 2, 0.7, 0.3)
	local x2, y2, z2 = M.toOrientation(r)
	local back = M.fromOrientation(x2, y2, z2)
	local ok = true
	for i = 1, 9 do
		ok = ok and math.abs(back[i] - r[i]) < 1e-6
	end
	t.check(ok, "toOrientation at gimbal lock")
	-- Roblox convention: Orientation (0, 90, 0) turns the look vector (-Z) toward -X
	local look = V.neg(M.column(M.fromOrientation(0, math.rad(90), 0), 3))
	t.check(vnear(look, { -1, 0, 0 }), "yaw +90 looks toward -X")
	local f = rframe()
	t.check(F.near(F.mul(f, F.inv(f)), F.IDENTITY, 1e-9), "frame * inverse = identity")
	local p = rvec(10)
	t.check(vnear(F.toLocal(f, F.point(f, p)), p, 1e-9), "toLocal inverts point")
	t.check(orthonormal(M.lookAlong({ 0.3, -0.2, 1 })), "lookAlong is a rotation")
	t.check(vnear(V.neg(M.column(M.lookAlong({ 0, 0, 5 }), 3)), { 0, 0, 1 }), "lookAlong: -Z = forward")
	t.check(orthonormal(M.lookAlong({ 0, 1, 0 })), "lookAlong straight up")
	t.check(vnear(M.column(M.alongX({ 0, 2, 0 }), 1), { 0, 1, 0 }), "alongX: X = the axis")
	t.eq("V.from Vector-like table", V.from({ x = 1, y = 2, z = 3 })[3], 3)
	t.eq("V.from junk", V.from("x"), nil)
end)

-- 2. triangle fill ---------------------------------------------------------------------------------------------------
local function checkTriangle(a, b, c, thickness, label)
	local wedges, err, n = G.triangleWedges(a, b, c, { thickness = thickness })
	if not t.check(wedges ~= nil, label .. ": wedges (" .. tostring(err) .. ")") then
		return
	end
	t.check(#wedges >= 1 and #wedges <= 2, label .. ": 1-2 wedges")
	local area = G.triangleArea(a, b, c)
	local sum = 0
	local corners = {}
	for _, w in wedges do
		t.check(w.shape == "Wedge", label .. ": shape")
		t.check(orthonormal(w.cf.r, 1e-9), label .. ": proper rotation (det +1)")
		t.check(math.abs(w.size[1] - thickness) < 1e-12, label .. ": thickness = size.X")
		t.check(w.size[2] >= G.MIN_SIZE and w.size[3] >= G.MIN_SIZE, label .. ": no sliver")
		local tri = G.wedgeTriangle(w.cf, w.size)
		sum += G.triangleArea(tri[1], tri[2], tri[3])
		for _, p in tri do
			t.check(math.abs(V.dot(V.sub(p, a), n)) < 1e-6, label .. ": wedge vertex in the triangle's plane")
			table.insert(corners, p)
		end
		-- the right angle of the wedge's cross-section is at local (-y, +z)
		local ra = tri[2]
		t.check(math.abs(V.dot(V.sub(tri[1], ra), V.sub(tri[3], ra))) < 1e-6 * math.max(1, area), label .. ": right angle")
	end
	t.check(math.abs(sum - area) <= 1e-6 * math.max(1, area), label .. ": the wedges cover exactly the triangle's area")
	for _, v in { a, b, c } do
		local found = false
		for _, p in corners do
			if vnear(p, v, 1e-3) then
				found = true
			end
		end
		t.check(found, label .. ": every triangle vertex is a wedge vertex (within 1e-3)")
	end
	-- random points of the triangle are inside one of the wedge triangles
	for _ = 1, 3 do
		local u, w = rng.next(), rng.next()
		if u + w > 1 then
			u, w = 1 - u, 1 - w
		end
		local p = V.add(a, V.add(V.scale(V.sub(b, a), u), V.scale(V.sub(c, a), w)))
		local inside = false
		for _, wd in wedges do
			local tri = G.wedgeTriangle(wd.cf, wd.size)
			local s = G.triangleArea(tri[1], tri[2], p) + G.triangleArea(tri[2], tri[3], p) + G.triangleArea(tri[3], tri[1], p)
			if math.abs(s - G.triangleArea(tri[1], tri[2], tri[3])) < 1e-6 * math.max(1, area) then
				inside = true
			end
		end
		t.check(inside, label .. ": a point of the triangle is covered")
	end
	return wedges, n
end

t.section("triangleFill: 2000 random triangles", function()
	local before = t.fails
	for i = 1, 2000 do
		local s = i % 4 == 0 and 500 or 20
		checkTriangle(rvec(s), rvec(s), rvec(s), 0.2 + (i % 3) * 0.3, "random #" .. i)
		if t.fails > before + 20 then
			break
		end
	end
end)

t.section("triangleFill: special cases", function()
	-- right triangle: one wedge
	local w = checkTriangle({ 0, 0, 0 }, { 4, 0, 0 }, { 0, 3, 0 }, 0.2, "right triangle")
	t.eq("right triangle -> 1 wedge", w and #w, 1)
	-- axis-aligned: the wedge sizes are the legs
	local w2 = G.triangleWedges({ 0, 0, 0 }, { 0, 0, -6 }, { 0, 4, 0 }, { thickness = 1 })
	t.eq("axis-aligned right triangle -> 1 wedge", #w2, 1)
	t.check(math.abs(w2[1].size[2] * w2[1].size[3] - 24) < 1e-9, "legs 4 x 6")
	-- isoceles: two equal wedges
	local w3 = checkTriangle({ -5, 0, 0 }, { 5, 0, 0 }, { 0, 0, 7 }, 0.5, "isoceles")
	t.eq("isoceles -> 2 wedges", w3 and #w3, 2)
	-- obtuse, thin, far away, tiny
	checkTriangle({ 0, 0, 0 }, { 100, 0, 0 }, { 1, 0.5, 0 }, 0.2, "obtuse thin")
	checkTriangle({ 10000, 500, -9000 }, { 10010, 503, -9004 }, { 10002, 520, -8990 }, 0.3, "far from the origin")
	checkTriangle({ 0, 0, 0 }, { 0.01, 0, 0 }, { 0, 0.01, 0 }, 0.001, "tiny")
	-- degenerate
	local none, err = G.triangleWedges({ 0, 0, 0 }, { 1, 1, 1 }, { 2, 2, 2 })
	t.check(none == nil and string.find(err, "degenerat") ~= nil, "collinear -> error")
	none, err = G.triangleWedges({ 1, 2, 3 }, { 1, 2, 3 }, { 4, 5, 6 })
	t.check(none == nil and err ~= nil, "two equal points -> error")
	none, err = G.triangleWedges({ 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { thickness = 0 })
	t.check(none == nil and string.find(err, "Grosimea") ~= nil, "zero thickness -> error")
	none = G.triangleWedges({ 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { thickness = 0 / 0 })
	t.check(none == nil, "NaN thickness -> error")
	-- align: "front" puts the wedges behind the triangle (against the normal of a -> b -> c)
	local a, b, c = { 0, 0, 0 }, { 4, 0, 0 }, { 0, 0, -3 }
	local centered = G.triangleWedges(a, b, c, { thickness = 1 })
	local front, _, n = G.triangleWedges(a, b, c, { thickness = 1, align = "front" })
	t.check(vnear(n, { 0, 1, 0 }), "normal of a counter-clockwise triangle seen from above = +Y")
	t.check(vnear(V.sub(front[1].cf.p, centered[1].cf.p), { 0, -0.5, 0 }), "front: shifted half a thickness against the normal")
	local back = G.triangleWedges(a, b, c, { thickness = 1, align = "back" })
	t.check(vnear(V.sub(back[1].cf.p, centered[1].cf.p), { 0, 0.5, 0 }), "back: shifted along the normal")
end)

-- 3. polygons and gap fill -------------------------------------------------------------------------------------------
local function piecesArea(pieces)
	local area = 0
	for _, pc in pieces do
		if pc.shape == "Wedge" then
			local tri = G.wedgeTriangle(pc.cf, pc.size)
			area += G.triangleArea(tri[1], tri[2], tri[3])
		else
			area += pc.size[1] * pc.size[3]
		end
	end
	return area
end

t.section("polygons", function()
	local square = { { 0, 0, 0 }, { 4, 0, 0 }, { 4, 0, -4 }, { 0, 0, -4 } }
	local tris = G.triangulate(square)
	t.eq("square -> 2 triangles", #tris, 2)
	-- concave L (area 12), with a collinear and a duplicated point
	local L = { { 0, 0, 0 }, { 2, 0, 0 }, { 4, 0, 0 }, { 4, 0, -2 }, { 2, 0, -2 }, { 2, 0, -4 }, { 0, 0, -4 }, { 0, 0, -4 } }
	local lt = G.triangulate(L)
	local area = 0
	for _, tr in lt do
		area += G.triangleArea(L[tr[1]], L[tr[2]], L[tr[3]])
	end
	t.near("concave L: the triangles cover its area", area, 12, 1e-9)
	local w = G.polygonWedges(L, { thickness = 0.3 })
	t.near("concave L: wedges cover its area", piecesArea(w), 12, 1e-6)
	-- tilted 3D polygon (a regular hexagon on a slanted plane)
	local hex = {}
	local fr = rframe(5)
	for i = 0, 5 do
		table.insert(hex, F.point(fr, { math.cos(i * math.pi / 3) * 3, 0, math.sin(i * math.pi / 3) * 3 }))
	end
	local hw = G.polygonWedges(hex)
	t.near("hexagon area", piecesArea(hw), 3 * math.sqrt(3) / 2 * 9, 1e-6)
	-- winding is kept: the normals of the wedge triangles agree with the polygon's
	local bow = { { 0, 0, 0 }, { 4, 0, -4 }, { 4, 0, 0 }, { 0, 0, -4 } }
	local bt, berr = G.triangulate(bow)
	t.check(bt == nil and berr ~= nil, "self-intersecting bow-tie -> error")
	t.check(G.triangulate({ { 0, 0, 0 }, { 1, 0, 0 } }) == nil, "2 points -> error")
	t.check(G.triangulate({ { 0, 0, 0 }, { 1, 0, 0 }, { 2, 0, 0 } }) == nil, "collinear -> error")
end)

t.section("gapFill", function()
	-- a planar rectangle -> exactly one block
	local r = G.gapFill({ { 0, 0, 0 }, { 6, 0, 0 } }, { { 0, 0, -4 }, { 6, 0, -4 } }, { thickness = 0.5 })
	t.eq("rectangle -> 1 piece", #r, 1)
	t.eq("rectangle -> a block", r[1].shape, "Block")
	t.check(vnear(r[1].cf.p, { 3, 0, -2 }), "block centred between the edges")
	t.check(math.abs(r[1].size[1] - 6) < 1e-9 and math.abs(r[1].size[2] - 0.5) < 1e-9 and math.abs(r[1].size[3] - 4) < 1e-9, "block size 6 x 0.5 x 4")
	t.check(orthonormal(r[1].cf.r), "block rotation")
	-- reversed second edge: no bow-tie
	local r2 = G.gapFill({ { 0, 0, 0 }, { 6, 0, 0 } }, { { 6, 0, -4 }, { 0, 0, -4 } })
	t.eq("reversed edge -> still 1 block", #r2, 1)
	-- parallel, offset edges (a trapezoid of area (6 + 4) / 2 * 4 = 20): block + right-triangle wedges
	local tz = G.gapFill({ { 0, 0, 0 }, { 6, 0, 0 } }, { { 1, 0, -4 }, { 5, 0, -4 } })
	t.near("trapezoid area", piecesArea(tz), 20, 1e-9)
	t.eq("trapezoid -> block + 2 wedges", #tz, 3)
	-- parallel but shifted (parallelogram, area 24)
	local pg = G.gapFill({ { 0, 0, 0 }, { 6, 0, 0 } }, { { 2, 0, -4 }, { 8, 0, -4 } })
	t.near("parallelogram area", piecesArea(pg), 24, 1e-9)
	t.check(#pg <= 3, "parallelogram -> at most 3 parts")
	-- non-parallel, non-coplanar edges: two triangles
	local skew = G.gapFill({ { 0, 0, 0 }, { 6, 0, 0 } }, { { 0, 3, -4 }, { 6, 0, -5 } })
	t.check(#skew >= 2 and #skew <= 4, "skew edges -> 2-4 wedges")
	-- a shared corner: one triangle
	local tri = G.gapFill({ { 0, 0, 0 }, { 6, 0, 0 } }, { { 0, 0, 0 }, { 0, 0, -5 } })
	t.near("shared corner -> the triangle", piecesArea(tri), 15, 1e-9)
	local none, err = G.gapFill({ { 0, 0, 0 }, { 6, 0, 0 } }, { { 0, 0, 0 }, { 6, 0, 0 } })
	t.check(none == nil and err ~= nil, "identical edges -> error")
	none, err = G.gapFill({ { 0, 0, 0 }, { 6, 0, 0 } }, { { 2, 0, 0 }, { 8, 0, 0 } })
	t.check(none == nil and err ~= nil, "collinear edges -> error")
end)

-- 4. arrays ----------------------------------------------------------------------------------------------------------
t.section("arrays", function()
	local lin = G.linearTransforms({ 4, 0, 1 }, 5)
	t.eq("linear: count 5 -> 4 copies", #lin, 4)
	t.check(vnear(lin[4].p, { 16, 0, 4 }), "linear: 4th copy at 4 * offset")
	t.check(G.linearTransforms({ 0, 0, 0 }, 3) == nil, "linear: zero offset -> error")
	t.check(G.linearTransforms({ 1, 0, 0 }, 1) == nil, "linear: count 1 -> error")
	t.check(G.linearTransforms({ 1, 0, 0 }, 2.5) == nil, "linear: fractional count -> error")
	-- radial full ring: 8 items 45 degrees apart, none on the original
	local center = { 10, 0, 0 }
	local item = { 10, 0, -6 }
	local rad = G.radialTransforms(center, { 0, 1, 0 }, 8, 360)
	t.eq("radial: 7 copies", #rad, 7)
	for k, tf in rad do
		local p = F.point(tf, item)
		t.near("radial: distance to the centre kept", V.dist(p, center), 6, 1e-9)
		local a = math.acos(math.max(-1, math.min(1, V.dot(V.unit(V.sub(p, center)) :: any, { 0, 0, -1 }))))
		local want = math.rad(45 * k)
		if want > math.pi then
			want = 2 * math.pi - want
		end
		t.near("radial: angle step 45", a, want, 1e-9)
	end
	-- partial arc: 90 degrees over 4 items -> the last at exactly 90
	local arc90 = G.radialTransforms(center, { 0, 1, 0 }, 4, 90)
	local last = F.point(arc90[3], item)
	t.check(vnear(last, { 4, 0, 0 }) or vnear(last, { 16, 0, 0 }), "radial 90 degrees: the last item a quarter turn away")
	-- Archimedes arc: a 10 x 4 x 2 wall segment turning 15 degrees around Y
	local ref = { cf = { p = { 0, 2, 0 }, r = M.IDENTITY }, size = { 10, 4, 2 } }
	local arcs = G.arcTransforms(ref, { axis = "Y", angle = 15, count = 25 })
	t.eq("arc: 24 copies", #arcs, 24)
	-- consecutive segments share their inner edge: the leading inner corner of copy k-1 = the trailing one of copy k
	local leading, trailing = { 5, 2, -1 }, { -5, 2, -1 } -- +X end, inner side (-Z) for a positive turn around Y
	local prev = F.IDENTITY
	local okEdge = true
	for _, tf in arcs do
		local a = F.point(F.mul(prev, ref.cf), V.sub(leading, ref.cf.p))
		local b = F.point(F.mul(tf, ref.cf), V.sub(trailing, ref.cf.p))
		okEdge = okEdge and vnear(a, b, 1e-9)
		t.check(orthonormal(tf.r, 1e-9), "arc transform is rigid")
		prev = tf
	end
	t.check(okEdge, "arc: neighbouring segments meet on the inner edge (no gap)")
	t.check(F.near(arcs[24], F.IDENTITY, 1e-6), "arc: 24 x 15 degrees closes the ring onto the original")
	-- negative angle turns to the other side; radius widens the curve
	local other = G.arcTransforms(ref, { axis = "Y", angle = -15, count = 3 })
	t.check(F.point(other[1], ref.cf.p)[3] > 0, "arc: negative angle turns toward +Z")
	local wide = G.arcTransforms(ref, { axis = "Y", angle = 15, count = 3, radius = 20 })
	t.check(V.dist(F.point(wide[1], ref.cf.p), ref.cf.p) > V.dist(F.point(arcs[1], ref.cf.p), ref.cf.p), "arc: a radius moves the pivot out")
	t.check(G.arcTransforms(ref, { axis = "W" }) == nil, "arc: bad axis -> error")
	t.check(G.arcTransforms(ref, { angle = 0 }) == nil, "arc: zero angle -> error")
	t.check(G.arcTransforms(ref, { axis = "Y", length = "Y" }) == nil, "arc: length on the rotation axis -> error")
end)

-- 5. mirror ----------------------------------------------------------------------------------------------------------
t.section("mirror", function()
	for _, shape in { "Block", "Wedge", "CornerWedge", "Cylinder", "Ball" } do
		for i = 1, 60 do
			local f = rframe(30)
			local size = { rng.range(0.5, 8), rng.range(0.5, 8), rng.range(0.5, 8) }
			if shape == "Ball" then
				size = { size[1], size[1], size[1] }
			elseif shape == "Cylinder" then
				size = { size[1], size[2], size[2] }
			end
			local q = rvec(20)
			local n = i % 3 == 0 and { 1, 0, 0 } or V.unit(rvec(1), { 0, 1, 0 })
			local mf, msize, exact = G.mirrorFrame(f, size, shape, q, n)
			t.check(orthonormal(mf.r, 1e-9), shape .. ": mirrored rotation is proper (det +1)")
			t.check(exact, shape .. ": exact")
			local want = {}
			for _, c in G.shapeCorners(shape, f, size) do
				table.insert(want, G.reflectPoint(c, q, n))
			end
			t.check(sameSet(G.shapeCorners(shape, mf, msize), want, 1e-6), shape .. ": the mirrored part's corners = the reflected corners")
		end
	end
	-- mirroring twice gives the original shape back
	local f, size = rframe(), { 2, 3, 5 }
	local m1, s1 = G.mirrorFrame(f, size, "CornerWedge", { 0, 0, 0 }, { 0, 0, 1 })
	local m2, s2 = G.mirrorFrame(m1, s1, "CornerWedge", { 0, 0, 0 }, { 0, 0, 1 })
	t.check(sameSet(G.shapeCorners("CornerWedge", m2, s2), G.shapeCorners("CornerWedge", f, size), 1e-6), "corner wedge mirrored twice = itself")
	-- an axis-aligned block mirrored across X = 0 keeps its rotation
	local b = G.mirrorFrame({ p = { 3, 1, 2 }, r = M.IDENTITY }, { 1, 1, 1 }, "Block", { 0, 0, 0 }, { 1, 0, 0 })
	t.check(F.near(b, { p = { -3, 1, 2 }, r = M.IDENTITY }, 1e-12), "block across X: same rotation, mirrored position")
	local _, _, approx = G.mirrorFrame(f, size, "Mesh", { 0, 0, 0 }, { 1, 0, 0 })
	t.check(approx == false, "MeshPart: reported as approximate")
end)

-- 6. align / distribute / snap / resize ------------------------------------------------------------------------------
t.section("align and distribute", function()
	local boxes = {
		{ min = { 0, 0, 0 }, max = { 2, 2, 2 } },
		{ min = { 5, 3, 0 }, max = { 6, 5, 1 } },
		{ min = { -4, -1, 2 }, max = { -1, 1, 3 } },
	}
	local off = G.alignOffsets(boxes, "Y", "min")
	t.check(vnear(off[2], { 0, -4, 0 }) and vnear(off[3], { 0, 0, 0 }), "align Y min to the lowest")
	off = G.alignOffsets(boxes, "X", "max", 10)
	t.check(vnear(off[1], { 8, 0, 0 }) and vnear(off[2], { 4, 0, 0 }), "align X max to a value")
	off = G.alignOffsets(boxes, "Z", "center")
	local c = (1 + 0.5 + 2.5) / 3
	t.near("align centre to the mean", 1 + off[1][3], c, 1e-12)
	t.check(G.alignOffsets(boxes, "Q", "min") == nil, "bad axis")
	t.check(G.alignOffsets(boxes, "X", "middle") == nil, "bad mode")
	local row = {
		{ min = { 0, 0, 0 }, max = { 2, 1, 1 } },
		{ min = { 3, 0, 0 }, max = { 4, 1, 1 } },
		{ min = { 20, 0, 0 }, max = { 24, 1, 1 } },
		{ min = { 5, 0, 0 }, max = { 6, 1, 1 } },
	}
	local d = G.distributeOffsets(row, "X")
	-- span 0..24, sizes 2 + 1 + 1 + 4 = 8 -> gap 16 / 3
	local gap = 16 / 3
	t.near("distribute gap: 2nd starts after the 1st + gap", row[2].min[1] + d[2][1], 2 + gap, 1e-9)
	t.near("distribute gap: 3rd (sorted) placed", row[4].min[1] + d[4][1], 2 + gap + 1 + gap, 1e-9)
	t.near("distribute keeps the ends", d[1][1] + d[3][1], 0, 1e-12)
	local dc = G.distributeOffsets(row, "X", "center")
	t.near("distribute centres evenly", (row[2].min[1] + row[2].max[1]) / 2 + dc[2][1], 1 + 21 / 3, 1e-9)
	t.check(G.distributeOffsets({ row[1], row[2] }, "X") == nil, "distribute needs 3")
	local s = G.snapFrame({ p = { 1.3, 2.6, -0.4 }, r = M.fromOrientation(0, math.rad(31), 0) }, 1, 15)
	t.check(vnear(s.p, { 1, 3, 0 }), "snap position")
	t.near("snap yaw to 30", F.orientation(s)[2], 30, 1e-9)
	-- resize-align: grow the top of a 4 x 1 x 4 part up to a ceiling at y = 10
	local f = { p = { 0, 0.5, 0 }, r = M.IDENTITY }
	local corners, n = G.boxFace(f, { 4, 1, 4 }, "Top")
	t.check(vnear(n, { 0, 1, 0 }), "top face normal")
	local dist = G.extendDistance(corners, n, { 0, 10, 0 }, { 0, -1, 0 }, "center")
	t.near("extend distance", dist, 9, 1e-12)
	local nf, ns = G.resizeFace(f, { 4, 1, 4 }, "Top", dist)
	t.check(vnear(ns, { 4, 10, 4 }) and vnear(nf.p, { 0, 5, 0 }), "resized: the bottom stays, the top reaches 10")
	-- a slanted target: outer / inner touch differ
	local tilt = V.unit({ 0, -1, -1 }) :: any
	local outer = G.extendDistance(corners, n, { 0, 10, 0 }, tilt, "outer")
	local inner = G.extendDistance(corners, n, { 0, 10, 0 }, tilt, "inner")
	t.check(outer > inner, "outer touch goes further than inner touch")
	t.check(G.extendDistance(corners, n, { 0, 10, 0 }, { 1, 0, 0 }) == nil, "parallel target -> error")
	t.check(G.resizeFace(f, { 4, 1, 4 }, "Top", -5) == nil, "shrinking past the other face -> error")
	t.check(G.resizeFace(f, { 4, 1, 4 }, "Up", 1) == nil, "bad face name -> error")
end)

-- 7. splines -------------------------------------------------------------------------------------------------------------
t.section("splines", function()
	local pts = { { 0, 0, 0 }, { 10, 0, 5 }, { 20, 3, 0 }, { 30, 0, -10 }, { 31, 0, -30 } }
	for _, alpha in { 0, 0.5, 1 } do
		local sp = G.spline(pts, { alpha = alpha })
		for i, p in pts do
			t.check(vnear(sp.at((i - 1) / (#pts - 1)), p, 1e-9), "alpha " .. alpha .. ": passes through control point " .. i)
		end
		-- arc-length samples are evenly spaced
		local samples = sp.samples(2)
		local step = sp.length / (#samples - 1)
		local worst = 0
		for i = 2, #samples do
			worst = math.max(worst, math.abs(V.dist(samples[i].p, samples[i - 1].p) - step))
		end
		t.check(worst < step * 0.02, "alpha " .. alpha .. ": even spacing along the curve (worst " .. worst .. ")")
		t.check(vnear(samples[1].p, pts[1], 1e-9) and vnear(samples[#samples].p, pts[#pts], 1e-9), "samples include both ends")
		local chord = 0
		for i = 2, #pts do
			chord += V.dist(pts[i], pts[i - 1])
		end
		t.check(sp.length >= chord - 1e-6, "the curve is at least as long as the polyline")
		for _, fr in sp.frames(3) do
			t.check(orthonormal(fr.r, 1e-6), "spline frames are rotations")
		end
	end
	-- tension 1: points stay on the straight segments
	local tight = G.spline({ { 0, 0, 0 }, { 10, 0, 0 }, { 10, 0, 10 } }, { tension = 1 })
	local mid = tight.at(0.25)
	t.check(math.abs(mid[3]) < 1e-9 and mid[1] > 0 and mid[1] < 10, "tension 1: straight segment")
	-- the tangent follows the curve; frames look along it
	local line = G.spline({ { 0, 0, 0 }, { 0, 0, -20 } })
	t.check(vnear(line.tangent(0.5), { 0, 0, -1 }, 1e-9), "straight line tangent")
	t.near("straight line length", line.length, 20, 1e-6)
	local fr = line.frames(5)[2]
	t.check(vnear(V.neg(M.column(fr.r, 3)), { 0, 0, -1 }, 1e-9) and vnear(M.column(fr.r, 2), { 0, 1, 0 }, 1e-9), "frame: -Z along the curve, Y up")
	-- closed curve comes back to the start
	local ring = G.spline({ { 10, 0, 0 }, { 0, 0, 10 }, { -10, 0, 0 }, { 0, 0, -10 } }, { closed = true })
	t.check(vnear(ring.at(0), ring.at(1), 1e-9), "closed spline: ends meet")
	t.check(G.spline({ { 1, 1, 1 } }) == nil, "one point -> error")
	t.check(G.spline({ { 1, 1, 1 }, { 1, 1, 1 } }) == nil, "two equal points -> error")
	t.check(G.spline({ "x", { 1, 1, 1 } }) == nil, "bad point -> error")
	-- centripetal (the default): no backtracking loop on unevenly spaced points, where the uniform curve has one
	local uneven = { { 0, 0, 0 }, { 1, 0, 0 }, { 1.2, 0, 0.2 }, { 30, 0, 0.4 } }
	local minXc, minXu = math.huge, math.huge
	local cent, unif = G.spline(uneven), G.spline(uneven, { alpha = 0 })
	for i = 0, 300 do
		minXc = math.min(minXc, cent.at(i / 300)[1])
		minXu = math.min(minXu, unif.at(i / 300)[1])
	end
	t.check(minXu < -0.5, "uniform Catmull-Rom backtracks here (" .. minXu .. ")")
	t.check(minXc > -1e-9, "centripetal does not (" .. minXc .. ")")
	t.check(cent.length < unif.length, "and it is shorter")
end)

-- 8. random numbers, Poisson sampling, hull ----------------------------------------------------------------------------
t.section("rng and sampling", function()
	local a, b = G.rng(7), G.rng(7)
	local same = true
	for _ = 1, 100 do
		local x = a.next()
		same = same and x == b.next() and x >= 0 and x < 1
	end
	t.check(same, "same seed -> same sequence in [0, 1)")
	t.check(G.rng(7).next() ~= G.rng(8).next(), "different seeds differ")
	local r = G.rng(3)
	for _ = 1, 200 do
		local i = r.int(2, 5)
		t.check(i >= 2 and i <= 5 and i % 1 == 0, "int in range")
	end
	local p1 = G.poissonSample(G.rng(42), 0, 0, 100, 100, 60, 8)
	local p2 = G.poissonSample(G.rng(42), 0, 0, 100, 100, 60, 8)
	t.eq("poisson: count reached", #p1, 60)
	local identical = #p1 == #p2
	for i = 1, #p1 do
		identical = identical and p1[i][1] == p2[i][1] and p1[i][2] == p2[i][2]
	end
	t.check(identical, "poisson: deterministic for a seed")
	local minD = math.huge
	for i = 1, #p1 do
		for j = i + 1, #p1 do
			minD = math.min(minD, math.sqrt((p1[i][1] - p1[j][1]) ^ 2 + (p1[i][2] - p1[j][2]) ^ 2))
		end
		t.check(p1[i][1] >= 0 and p1[i][1] <= 100 and p1[i][2] >= 0 and p1[i][2] <= 100, "poisson: inside the area")
	end
	t.check(minD >= 8, "poisson: minimum distance respected (" .. minD .. ")")
	local p3 = G.poissonSample(G.rng(43), 0, 0, 100, 100, 60, 8)
	t.check(p3[1][1] ~= p1[1][1], "poisson: another seed, other points")
	local packed = G.poissonSample(G.rng(1), 0, 0, 10, 10, 1000, 5)
	t.check(#packed < 20, "poisson: stops when the area is full")
end)

local function signedVolume(verts, tris)
	local v = 0
	for _, tr in tris do
		local a, b, c = verts[tr[1]], verts[tr[2]], verts[tr[3]]
		v += V.dot(a, V.cross(b, c)) / 6
	end
	return v
end
local function closed(tris)
	local edges = {}
	for _, tr in tris do
		for e = 1, 3 do
			local a, b = tr[e], tr[e % 3 + 1]
			local k = a .. ":" .. b
			edges[k] = (edges[k] or 0) + 1
		end
	end
	for k, n in edges do
		local a, b = string.match(k, "(%d+):(%d+)")
		if n ~= 1 or edges[b .. ":" .. a] ~= 1 then
			return false
		end
	end
	return true
end

t.section("convex hull", function()
	local pts = {}
	for _, x in { -1, 1 } do
		for _, y in { -1, 1 } do
			for _, z in { -1, 1 } do
				table.insert(pts, { x * 2, y * 3, z * 4 })
			end
		end
	end
	for _ = 1, 10 do
		table.insert(pts, { rng.range(-1, 1), rng.range(-1, 1), rng.range(-1, 1) }) -- inside
	end
	local faces = G.convexHull(pts)
	t.eq("box hull: 12 triangles", #faces, 12)
	t.near("box hull volume", signedVolume(pts, faces), 4 * 6 * 8, 1e-9)
	t.check(closed(faces), "box hull is closed and consistently wound")
	local sphere = {}
	for i = 1, 40 do
		local y = 1 - 2 * (i - 0.5) / 40
		local r = math.sqrt(1 - y * y)
		table.insert(sphere, { math.cos(i * 2.4) * r * 5, y * 5, math.sin(i * 2.4) * r * 5 })
	end
	local sf = G.convexHull(sphere)
	t.eq("sphere points all on the hull: 2n - 4 faces", #sf, 76)
	t.check(signedVolume(sphere, sf) > 0, "outward winding (positive volume)")
	t.check(closed(sf), "sphere hull closed")
	t.check(G.convexHull({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { 1, 1, 0 } }) == nil, "coplanar -> error")
end)

-- 9. generators ------------------------------------------------------------------------------------------------------
local function validPieces(label, pieces)
	local ok = true
	for _, pc in pieces do
		local shapeOk = pc.shape == "Block" or pc.shape == "Wedge" or pc.shape == "CornerWedge" or pc.shape == "Cylinder" or pc.shape == "Ball"
		local sizeOk = pc.size[1] >= G.MIN_SIZE and pc.size[2] >= G.MIN_SIZE and pc.size[3] >= G.MIN_SIZE
			and pc.size[1] <= G.MAX_SIZE and pc.size[2] <= G.MAX_SIZE and pc.size[3] <= G.MAX_SIZE
		local rotOk = orthonormal(pc.cf.r, 1e-6)
		local colorOk = pc.color == nil or (type(pc.color) == "string" and string.match(pc.color, "^#%x%x%x%x%x%x$") ~= nil)
		if not (shapeOk and sizeOk and rotOk and colorOk) then
			ok = false
			t.fail(label .. ": bad piece " .. tostring(pc.name) .. " shape " .. tostring(pc.shape) .. " size " .. table.concat(pc.size, ","))
			break
		end
	end
	return ok
end

t.section("generators: every generator and choice builds", function()
	local counts = {}
	for _, g in Gen.LIST do
		local r, err = Gen.generate(g.key, {})
		if t.check(r ~= nil, g.key .. ": builds with defaults (" .. tostring(err) .. ")") then
			t.check(#r.pieces > 0 or #r.terrain > 0, g.key .. ": produces something")
			validPieces(g.key, r.pieces)
			counts[g.key] = #r.pieces
			t.check(#r.pieces <= 400, g.key .. ": default part count stays small (" .. #r.pieces .. ")")
			-- deterministic
			local again = Gen.generate(g.key, {})
			local same = #again.pieces == #r.pieces
			for i = 1, math.min(#again.pieces, #r.pieces) do
				same = same and F.near(again.pieces[i].cf, r.pieces[i].cf, 0) and again.pieces[i].size[1] == r.pieces[i].size[1]
			end
			t.check(same, g.key .. ": the same parameters give the same model")
		end
		for _, f in g.params do
			t.check(type(f.label) == "string" and f.label ~= "", g.key .. "." .. f.key .. ": label")
			if f.kind == "choice" then
				t.check(table.find(f.options, f.default) ~= nil, g.key .. "." .. f.key .. ": default is an option")
				for _, opt in f.options do
					local rr, e = Gen.generate(g.key, { [f.key] = opt })
					if t.check(rr ~= nil, g.key .. " " .. f.key .. "=" .. opt .. " builds (" .. tostring(e) .. ")") then
						validPieces(g.key .. " " .. f.key .. "=" .. opt, rr.pieces)
					end
				end
			elseif f.kind == "number" or f.kind == "int" then
				t.check(f.default >= f.min and f.default <= f.max, g.key .. "." .. f.key .. ": default in range")
			end
		end
	end
	local line = {}
	for _, g in Gen.LIST do
		table.insert(line, g.key .. "=" .. tostring(counts[g.key]))
	end
	print("default part counts: " .. table.concat(line, " "))
end)

t.section("generators: sizes and scale", function()
	local S = Gen.SCALE
	t.check(S.DOOR_WIDTH >= S.DOOR_MIN[1] and S.DOOR_HEIGHT >= S.DOOR_MIN[2], "default door >= the minimum")
	t.check(S.BARRIER_HEIGHT > S.JUMP_HEIGHT, "a barrier is higher than a jump")
	-- building: footprint, height, a door of the right size, windows
	local b = Gen.generate("building", { width = 24, depth = 20, floors = 2, roof = "flat" })
	local bb = G.piecesBounds(b.pieces)
	-- (window sills stand 0.3 out of the walls)
	t.near("building width", bb.max[1] - bb.min[1], 24, 0.6 + 1e-6)
	t.near("building depth", bb.max[3] - bb.min[3], 20, 0.6 + 1e-6)
	local walls = {}
	for _, pc in b.pieces do
		if string.find(pc.name or "", "^Perete") then
			table.insert(walls, pc)
		end
	end
	local wb = G.piecesBounds(walls)
	t.near("walls: exactly 24 wide", wb.max[1] - wb.min[1], 24, 1e-6)
	t.near("walls: exactly 20 deep", wb.max[3] - wb.min[3], 20, 1e-6)
	t.near("walls: 2 floors of 12", wb.max[2], 24, 1e-6)
	t.near("flat roof: walls 24 + slab 1 + parapet 1.5", bb.max[2], 26.5, 1e-6)
	t.near("sits on the ground", bb.min[2], 0, 1e-6)
	local door
	for _, pc in b.pieces do
		if pc.name == "Ușă" then
			door = pc
		end
	end
	t.check(door ~= nil and math.abs(door.size[2] - S.DOOR_HEIGHT) < 1e-9, "building: a door " .. S.DOOR_HEIGHT .. " high")
	t.check(b.info.windows > 0 and b.info.doors == 1, "building: windows and one door")
	-- gable: both infill wedges rise to the ridge (their top edge at z = 0), the roof panels cover them
	local gable = Gen.generate("building", { roof = "gable", width = 24, depth = 20 })
	local frontons = 0
	for _, pc in gable.pieces do
		if pc.name == "Fronton" then
			frontons += 1
			local cs = G.shapeCorners("Wedge", pc.cf, pc.size)
			t.near("gable wedge: top edge on the ridge", cs[3][3], 0, 1e-9)
			t.near("gable wedge: top edge on the ridge (2)", cs[6][3], 0, 1e-9)
			t.check(cs[3][2] > cs[1][2] + 1, "gable wedge: the top edge is the high one")
		end
	end
	t.eq("gable: two infill wedges", frontons, 2)
	local hip = Gen.generate("building", { roof = "hip", width = 30, depth = 20 })
	t.check(#hip.pieces > 0, "hip roof on a long building")
	local square = Gen.generate("building", { roof = "hip", width = 20, depth = 20 })
	local corners = 0
	for _, pc in square.pieces do
		if pc.shape == "CornerWedge" then
			corners += 1
		end
	end
	t.eq("square hip roof = a pyramid of 4 corner wedges", corners, 4)
	-- every quarter of a pyramid has its apex on the pyramid's top; together they cover the base
	for _, size in { { 6, 6 }, { 8, 4 } } do
		local base, h = { 3, 1, -2 }, 5
		local pyr = G.pyramid(base, size[1], size[2], h, nil, M.ry(0.4))
		local lo, hi = { math.huge, 0, math.huge }, { -math.huge, 0, -math.huge }
		for _, pc in pyr do
			local cs = G.shapeCorners("CornerWedge", pc.cf, pc.size)
			t.check(vnear(cs[1], { 3, 6, -2 }, 1e-9), "pyramid quarter: apex at the top centre")
			for k = 2, 5 do
				t.near("pyramid quarter: base on the ground", cs[k][2], 1, 1e-9)
				local l = M.apply(M.transpose(M.ry(0.4)), V.sub(cs[k], base))
				lo = { math.min(lo[1], l[1]), 0, math.min(lo[3], l[3]) }
				hi = { math.max(hi[1], l[1]), 0, math.max(hi[3], l[3]) }
			end
		end
		t.near("pyramid footprint X", hi[1] - lo[1], size[1], 1e-9)
		t.near("pyramid footprint Z", hi[3] - lo[3], size[2], 1e-9)
	end
	-- a hip roof's end quarters have their apex on the ridge
	local ridgeY
	for _, pc in hip.pieces do
		if pc.shape == "CornerWedge" then
			local apex = G.shapeCorners("CornerWedge", pc.cf, pc.size)[1]
			ridgeY = ridgeY or apex[2]
			t.near("hip roof: apex on the ridge height", apex[2], ridgeY, 1e-9)
			t.near("hip roof: apex on the ridge line (z = 0)", apex[3], 0, 1e-9)
		end
	end
	-- stairs: the top step at the requested height, steps of rise height
	for _, kind in { "straight", "L", "spiral" } do
		local st = Gen.generate("stairs", { kind = kind, height = 12, rise = 1 })
		t.eq(kind .. " stairs: 12 steps", st.info.steps, 12)
		local top = -math.huge
		for _, pc in st.pieces do
			if pc.name == "Treaptă" or pc.name == "Podest" then
				top = math.max(top, pc.cf.p[2] + pc.size[2] / 2)
			end
		end
		t.near(kind .. " stairs: top step at 12", top, 12, 1e-6)
	end
	local odd = Gen.generate("stairs", { height = 10, rise = 0.9 })
	t.near("rise adjusted so n * rise = height", odd.info.steps * odd.info.rise, 10, 1e-9)
	-- trees: the seed changes the shape, not the size class
	local t1, t2 = Gen.generate("tree", { kind = "round", seed = 1 }), Gen.generate("tree", { kind = "round", seed = 2 })
	t.check(not F.near(t1.pieces[2].cf, t2.pieces[2].cf, 1e-9), "tree: another seed, another crown")
	local pine = Gen.generate("tree", { kind = "pine", height = 14 })
	local pb = G.piecesBounds(pine.pieces)
	t.near("pine height", pb.max[2], 14, 1e-6)
	-- rocks: closed shells of wedges, partly under ground
	local rk = Gen.generate("rock", { size = 6, detail = 1, seed = 5 })
	local rb = G.piecesBounds(rk.pieces)
	t.check(rb.min[2] < 0 and rb.max[2] > 0, "rock: partly sunk")
	t.check(rb.max[1] - rb.min[1] <= 6.5, "rock: about the requested size")
	-- furniture at character scale
	local tbl = Gen.generate("furniture", { kind = "table" })
	t.near("table top at 3.5", G.piecesBounds(tbl.pieces).max[2], S.TABLE_HEIGHT, 1e-9)
	local chair = Gen.generate("furniture", { kind = "chair" })
	local seat
	for _, pc in chair.pieces do
		if pc.class == "Seat" then
			seat = pc
		end
	end
	t.check(seat ~= nil and math.abs(seat.cf.p[2] + seat.size[2] / 2 - S.SEAT_HEIGHT) < 1e-9, "chair: a Seat at 1.5")
	local set = Gen.generate("furniture", { kind = "set", seats = 6 })
	t.eq("set: table (5) + 6 chairs (6 each)", #set.pieces, 5 + 6 * 6)
	-- chairs of the set have their backs away from the table
	for _, pc in set.pieces do
		if pc.name == "Spătar" then
			local horizontal = { pc.cf.p[1], 0, pc.cf.p[3] }
			local back = M.column(pc.cf.r, 3)
			t.check(V.dot(horizontal, back) >= -1e-9, "set: chair back faces away from the table")
		end
	end
	-- fence: posts at every vertex; the collision box variant
	local fence = Gen.generate("fence", { points = { { 0, 0, 0 }, { 12, 0, 0 }, { 12, 0, 12 } }, postSpacing = 6 })
	t.eq("fence: 5 posts", fence.info.posts, 5)
	local boxes, colliding = 0, 0
	for _, pc in fence.pieces do
		if pc.name == "Coliziune" then
			boxes += 1
			t.check(pc.transparency == 1, "collision box invisible")
		elseif pc.canCollide ~= false then
			colliding += 1
		end
	end
	t.eq("fence: one collision box per straight run", boxes, 2)
	t.eq("fence: the visible parts do not collide", colliding, 0)
	-- terrain: only Fill operations, Air carves the cave
	local cave = Gen.generate("terrain", { kind = "cave", radius = 16 })
	local air = 0
	for _, op in cave.terrain do
		if op.material == "Air" then
			air += 1
		end
	end
	t.check(#cave.pieces == 0 and air > 3, "cave: a tunnel of Air balls")
end)

t.section("generators: parameter validation", function()
	local r, err = Gen.generate("castle", {})
	t.check(r == nil and string.find(err, "Generator necunoscut") ~= nil, "unknown generator")
	r, err = Gen.generate("building", { widht = 20 })
	t.check(r == nil and string.find(err, "parametru necunoscut") ~= nil and string.find(err, "width") ~= nil, "a typo is an error that lists the keys")
	r, err = Gen.generate("building", { floors = 0 })
	t.check(r == nil and string.find(err, "floors") ~= nil, "out of range")
	r, err = Gen.generate("building", { floors = 2.5 })
	t.check(r == nil and string.find(err, "întreg") ~= nil, "int expected")
	r, err = Gen.generate("building", { roof = "dome" })
	t.check(r == nil and string.find(err, "gable") ~= nil, "bad choice lists the options")
	r, err = Gen.generate("building", { wallColor = "red" })
	t.check(r == nil and string.find(err, "#rrggbb") ~= nil, "bad colour")
	r, err = Gen.generate("building", { wallMaterial = "Cheese" }, function(m)
		return m == "Brick"
	end)
	t.check(r == nil and string.find(err, "material") ~= nil, "bad material")
	r, err = Gen.generate("building", { windows = "yes" })
	t.check(r == nil and string.find(err, "true sau false") ~= nil, "bool expected")
	r, err = Gen.generate("fence", { points = { { 0, 0, 0 } } })
	t.check(r == nil and string.find(err, "2 puncte") ~= nil, "a fence needs 2 points")
	r, err = Gen.generate("tower", { radius = 3, wall = 2 })
	t.check(r == nil and string.find(err, "zidul") ~= nil, "cross-field check")
	r = Gen.generate("building", { wallColor = "B8735A" })
	t.eq("colour without # is accepted and normalised", r.params.wallColor, "#B8735A")
	local walls = Gen.subtractRects(-5, 5, 0, 10, { { -1, 1, 2, 4 }, { -1, 1, 6, 8 } })
	local area = 0
	for _, rc in walls do
		area += (rc[2] - rc[1]) * (rc[4] - rc[3])
	end
	t.near("wall minus two windows: the area", area, 100 - 8, 1e-9)
	t.check(#walls <= 5, "wall minus a column of windows: few rectangles (" .. #walls .. ")")
end)

-- 10. meshes ---------------------------------------------------------------------------------------------------------
t.section("meshes", function()
	local cyl = Mesh.lathe({ { 2, 0 }, { 2, 5 } }, 24)
	t.check(Mesh.check(cyl) == nil, "lathe: valid")
	t.check(closed(cyl.tris), "lathe with caps is closed")
	local vol = signedVolume(cyl.verts, cyl.tris)
	t.check(vol > 0, "lathe wound outward")
	t.near("lathe volume ~ pi r^2 h", vol, 0.5 * 24 * 4 * math.sin(2 * math.pi / 24) * 5, 1e-9)
	local vase = Mesh.lathe({ { 0, 0 }, { 2, 0 }, { 2.4, 1 }, { 1.2, 3 }, { 0, 3.4 } }, 12)
	t.check(closed(vase.tris) and signedVolume(vase.verts, vase.tris) > 0, "lathe with poles: closed, outward")
	local flat = Mesh.lathe({ { 2, 0 }, { 2, 5 } }, 8, { flat = true })
	t.eq("flat: 3 vertices per triangle", #flat.verts, 3 * #flat.tris)
	t.check(Mesh.lathe({ { 1, 0 } }, 8) == nil, "lathe needs 2 points")
	t.check(Mesh.lathe({ { 1, 0 }, { 1, 1 } }, 2) == nil, "lathe needs 3 segments")
	-- extrude: area x depth, either winding
	local sq = { { 0, 0 }, { 4, 0 }, { 4, 4 }, { 0, 4 } }
	for _, poly in { sq, { sq[4], sq[3], sq[2], sq[1] } } do
		local ex = Mesh.extrude(poly, 3)
		t.near("extrude volume", signedVolume(ex.verts, ex.tris), 48, 1e-9)
	end
	local bev = Mesh.extrude(sq, 3, 0.5)
	local bv = signedVolume(bev.verts, bev.tris)
	t.check(bv > 40 and bv < 48, "bevelled extrude: a bit less volume (" .. bv .. ")")
	local Lp = { { 0, 0 }, { 4, 0 }, { 4, 2 }, { 2, 2 }, { 2, 4 }, { 0, 4 } }
	t.near("concave extrude volume", signedVolume(Mesh.extrude(Lp, 2).verts, Mesh.extrude(Lp, 2).tris), 24, 1e-9)
	t.check(Mesh.extrude(sq, -1) == nil, "negative depth -> error")
	-- rock
	for detail = 0, 3 do
		local rk = Mesh.rock(4, detail)
		t.check(Mesh.check(rk) == nil and signedVolume(rk.verts, rk.tris) > 0, "rock detail " .. detail .. ": valid, outward")
	end
	local smooth = Mesh.rock(4, 2, { smooth = true })
	t.check(closed(smooth.tris), "smooth rock: closed, shared vertices")
	-- terrain chunk: res^2 * 2 triangles facing up
	local chunk = Mesh.terrainChunk(function(x, z)
		return math.sin(x * 0.1) * 2 + z * 0.05
	end, { size = 32, resolution = 8, flat = false })
	t.eq("terrain chunk triangles", #chunk.tris, 128)
	local up = true
	for _, tr in chunk.tris do
		local n = V.cross(V.sub(chunk.verts[tr[2]], chunk.verts[tr[1]]), V.sub(chunk.verts[tr[3]], chunk.verts[tr[1]]))
		up = up and n[2] > 0
	end
	t.check(up, "terrain chunk faces up")
	local grid = Mesh.terrainChunk({ { 0, 1 }, { 2, 3 } }, { size = 4, resolution = 1, flat = false })
	t.eq("height grid", grid.verts[4][2], 3)
	-- fallback to wedges and limits
	local pieces = Mesh.toPieces(Mesh.extrude(sq, 3))
	t.check(#pieces >= 12 and #pieces <= 24, "extruded box -> wedges")
	local center = Mesh.center(cyl)
	local cb = Mesh.bounds(cyl)
	t.check(vnear(center, { 0, 2.5, 0 }, 1e-9) and vnear(V.mid(cb.min, cb.max), { 0, 0, 0 }, 1e-9), "center() recentres")
	local big = { verts = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } }, tris = {} }
	for _ = 1, Mesh.MAX_TRIANGLES + 1 do
		table.insert(big.tris, { 1, 2, 3 })
	end
	t.check(string.find(Mesh.check(big) or "", "Prea multe") ~= nil, "triangle limit")
	t.check(Mesh.toPieces(big) == nil, "fallback limit")
	t.check(Mesh.check({ verts = {}, tris = { { 1, 2, 3 } } }) ~= nil, "bad vertex ids")
	local m, err = Mesh.make("donut", {})
	t.check(m == nil and string.find(err, "necunoscut") ~= nil, "unknown mesh kind")
	for _, k in Mesh.KINDS do
		local mm = Mesh.make(k, {})
		t.check(mm ~= nil and Mesh.check(mm) == nil, "Mesh.make " .. k .. " with defaults")
	end
end)

-- 11. spec -----------------------------------------------------------------------------------------------------------
t.section("spec: JSON", function()
	local value = { name = "Casă „veche”", parts = { { shape = "Block", size = { 1, 2.5, -3 }, color = "#a0b0c0" } },
		flag = true, nothing = false, n = 1e-7, big = 123456789, esc = "a\"b\\c\nd\t", list = {} }
	local text = Spec.toJSON(value)
	local back, err = Spec.fromJSON(text)
	t.check(back ~= nil, "round trip parses (" .. tostring(err) .. ")")
	t.eq("unicode kept", back.name, value.name)
	t.eq("escapes kept", back.esc, value.esc)
	t.eq("numbers", back.parts[1].size[2], 2.5)
	t.eq("negative", back.parts[1].size[3], -3)
	t.eq("booleans", back.nothing, false)
	t.eq("deterministic", Spec.toJSON(back), text)
	t.check(string.find(text, '"name":"Cas', 1, true) == 2, "name is the first key")
	t.eq("\\u escapes", Spec.fromJSON('"\\u0103\\ud83d\\ude00"'), "ă😀")
	for _, bad in { "{", "[1,]", '{"a" 1}', "tru", '"abc', "[1] x", "{1: 2}" } do
		local v, e = Spec.fromJSON(bad)
		t.check(v == nil and string.find(e or "", "JSON invalid") ~= nil, "bad JSON rejected: " .. bad)
	end
	t.eq("exponent", Spec.fromJSON("1.5e2"), 150)
end)

t.section("spec: compile", function()
	local spec = {
		name = "Test",
		parts = {
			{ shape = "Block", size = { 4, 1, 2 }, pos = { 0, 0.5, 0 }, name = "Bază" },
			{ shape = "Wedge", size = { 4, 2, 2 }, pos = { 0, 2, 0 }, rot = { 0, 90, 0 }, color = "#FF0000", material = "Wood" },
			{ shape = "Ball", size = { 3, 1, 1 }, pos = { 5, 1.5, 0 } },
			{ shape = "Cylinder", size = { 6, 1, 2 }, pos = { 0, 3, 0 }, rot = { 0, 0, 90 } },
			{ shape = "Triangle", points = { { 0, 0, 0 }, { 4, 0, 0 }, { 0, 3, 0 } }, thickness = 0.4 },
			{ shape = "CornerWedge", size = { 2, 2, 2 }, pos = { 8, 1, 0 }, transparency = 0.5, anchored = false, canCollide = false },
		},
		arrays = {
			{ kind = "linear", of = { 1 }, count = 3, offset = { 0, 0, 5 } },
			{ kind = "radial", of = { "Bază" }, count = 4, center = { 0, 0, 20 } },
			{ kind = "mirror", of = { 2, 6 }, normal = { 1, 0, 0 } },
			{ kind = "arc", of = { 3 }, count = 3, angle = 30 },
			{ kind = "path", of = { 4 }, points = { { 0, 3, 0 }, { 10, 3, 10 }, { 20, 3, 0 } }, spacing = 5 },
		},
		generators = { { kind = "tree", params = { kind = "pine" }, at = { pos = { 30, 0, 0 }, rot = { 0, 45, 0 } } } },
	}
	local plan, errors = Spec.compile(spec)
	if not t.check(plan ~= nil, "valid spec compiles: " .. table.concat(errors or {}, "; ")) then
		return
	end
	local byName = 0
	for _, pc in plan.pieces do
		if pc.name == "Bază" then
			byName += 1
		end
	end
	-- linear on part 1: 2 copies; radial on every "Bază" (now 3): 3 x 3 copies
	t.eq("linear + radial copies of Bază", byName, 3 + 9)
	t.eq("ball size made uniform", plan.pieces[3].size[2], 3)
	t.eq("cylinder: y = z = diameter", plan.pieces[4].size[3], 1)
	t.check(math.abs(F.orientation(plan.pieces[2].cf)[2] - 90) < 1e-9, "rot = Orientation")
	t.eq("colour normalised", plan.pieces[2].color, "#ff0000")
	t.eq("one generator", #plan.generators, 1)
	t.check(plan.count == #plan.pieces + #plan.generators[1].result.pieces, "count includes generator parts")
	t.check(vnear(plan.generators[1].frame.p, { 30, 0, 0 }), "generator placed at its pos")
	-- JSON text works the same
	local fromText = Spec.compile(Spec.toJSON(spec))
	t.eq("compile from JSON text", fromText and #fromText.pieces, #plan.pieces)
end)

t.section("spec: errors and limits", function()
	local function errorsOf(spec)
		local plan, errors = Spec.compile(spec, function(m)
			return m == "Plastic" or m == "Wood"
		end)
		t.check(plan == nil, "invalid spec does not compile")
		return table.concat(errors or {}, "\n")
	end
	t.has("unknown top key", errorsOf({ parts = {}, color = "#fff" }), "cheie necunoscută „color”")
	t.has("bad size names the item", errorsOf({ parts = { { size = { 1, 2 } }, { size = { 1, 2, 3 } } } }), "parts[1].size")
	t.has("size too small", errorsOf({ parts = { { size = { 0.01, 1, 1 } } } }), "parts[1].size")
	t.has("size too big", errorsOf({ parts = { { size = { 5000, 1, 1 } } } }), "2048")
	t.has("too far", errorsOf({ parts = { { size = { 1, 1, 1 }, pos = { 99999, 0, 0 } } } }), "prea departe")
	t.has("bad shape", errorsOf({ parts = { { shape = "Cone", size = { 1, 1, 1 } } } }), "parts[1].shape")
	t.has("bad colour", errorsOf({ parts = { { size = { 1, 1, 1 }, color = "blue" } } }), "parts[1].color")
	t.has("bad material", errorsOf({ parts = { { size = { 1, 1, 1 }, material = "Lava2" } } }), "parts[1].material")
	t.has("bad transparency", errorsOf({ parts = { { size = { 1, 1, 1 }, transparency = 2 } } }), "parts[1].transparency")
	t.has("unknown part key", errorsOf({ parts = { { size = { 1, 1, 1 }, Size = { 1, 1, 1 } } } }), "cheie necunoscută „Size”")
	t.has("degenerate triangle", errorsOf({ parts = { { shape = "Triangle", points = { { 0, 0, 0 }, { 1, 1, 1 }, { 2, 2, 2 } } } } }), "degenerat")
	t.has("triangle with size", errorsOf({ parts = { { shape = "Triangle", size = { 1, 1, 1 }, points = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } } } } }), "parts[1].size")
	t.has("array: missing part", errorsOf({ parts = { { size = { 1, 1, 1 } } }, arrays = { { kind = "linear", of = { 3 }, count = 2, offset = { 1, 0, 0 } } } }), "nu există parts[3]")
	t.has("array: unknown name", errorsOf({ parts = { { size = { 1, 1, 1 } } }, arrays = { { kind = "linear", of = { "Lampă" }, count = 2, offset = { 1, 0, 0 } } } }), "Lampă")
	t.has("array: bad kind", errorsOf({ parts = { { size = { 1, 1, 1 } } }, arrays = { { kind = "spiral", of = { 1 }, count = 2 } } }), "arrays[1].kind")
	t.has("array: bad count", errorsOf({ parts = { { size = { 1, 1, 1 } } }, arrays = { { kind = "linear", of = { 1 }, count = 0, offset = { 1, 0, 0 } } } }), "arrays[1].count")
	t.has("generator error names the item", errorsOf({ generators = { { kind = "tree", params = { height = -1 } } } }), "generators[1]")
	t.has("generator unknown key", errorsOf({ generators = { { kind = "tree", where = { 0, 0, 0 } } } }), "cheie necunoscută „where”")
	t.has("JSON error", errorsOf("{ not json"), "JSON invalid")
	-- the part limit counts arrays and generators
	t.has("too many parts via an array", errorsOf({ parts = { { size = { 1, 1, 1 } } },
		arrays = { { kind = "linear", of = { 1 }, count = 1000, offset = { 1, 0, 0 } }, { kind = "linear", of = { 1 }, count = 1000, offset = { 0, 1, 0 } }, { kind = "linear", of = { 1 }, count = 1000, offset = { 0, 0, 1 } } } }), "prea multe piese")
	local gens = {}
	for i = 1, 60 do
		gens[i] = { kind = "tree" }
	end
	t.has("too many generators", errorsOf({ generators = gens }), "generators: prea multe")
	local manyTrees = {}
	for i = 1, 40 do
		manyTrees[i] = { kind = "building", params = { floors = 3 } }
	end
	t.has("generator parts count toward the limit", errorsOf({ generators = manyTrees }), "prea multe piese în total")
end)

t.section("spec: describePiece is the inverse of a part", function()
	for i = 1, 200 do
		local shape = ({ "Block", "Wedge", "CornerWedge", "Cylinder", "Ball" })[i % 5 + 1]
		local size = { Spec.round(rng.range(0.5, 10), 3), Spec.round(rng.range(0.5, 10), 3), Spec.round(rng.range(0.5, 10), 3) }
		if shape == "Ball" then
			size = { size[1], size[1], size[1] }
		elseif shape == "Cylinder" then
			size = { size[1], size[2], size[2] }
		end
		local pc = { shape = shape, size = size, cf = F.fromPosOrientation(rvec(100), { rng.range(-89, 89), rng.range(-180, 180), rng.range(-180, 180) }),
			color = "#336699", material = "Wood", transparency = 0.25, anchored = false, name = "P" .. i }
		local entry = Spec.describePiece(pc)
		local back = Spec.part(entry, "x")
		if t.check(back ~= nil, "described part compiles") then
			local b = back[1]
			t.eq("shape", b.shape, shape)
			t.check(vnear(b.cf.p, pc.cf.p, 1e-3), "position within 1e-3")
			local cornersA = G.shapeCorners(shape, pc.cf, pc.size)
			local cornersB = G.shapeCorners(shape, b.cf, b.size)
			t.check(sameSet(cornersA, cornersB, 2e-3 * 10), "same corners after rounding (" .. shape .. ")")
			t.eq("color", b.color, "#336699")
			t.eq("anchored kept", b.anchored, false)
		end
	end
	local plainPiece = Spec.describePiece({ shape = "Block", size = { 4, 1, 2 }, cf = F.new({ 1, 2, 3 }), color = Spec.DEFAULT_COLOR,
		material = "Plastic", transparency = 0, anchored = true, canCollide = true, castShadow = true, name = "Part" })
	local keys = {}
	for k in plainPiece do
		table.insert(keys, k)
	end
	table.sort(keys)
	t.eq("defaults are left out", table.concat(keys, ","), "pos,size")
	t.check(#Spec.DOC > 1500 and string.find(Spec.DOC, "Triangle", 1, true) ~= nil, "Spec.DOC documents the format")
end)

t.finish()
