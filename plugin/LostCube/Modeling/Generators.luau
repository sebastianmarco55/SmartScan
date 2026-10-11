-- LostCube > Modeling > Generators: procedural builders as pure functions. Each one takes validated parameters and
-- returns { pieces = { piece }, terrain = { op }?, info = {...} } in LOCAL coordinates: the origin is the centre of the
-- footprint on the ground (y = 0), -Z is the front (the LookVector of the CFrame the model is placed at). init.luau turns
-- the pieces into one Model (one undo step). Same seed + same parameters = the same model.
--
-- Every generator is described by Generators.LIST[i] = { key, label, params = { field } } so a panel can draw its
-- controls and Claude can read the allowed parameters: field = { key, label, kind, default, min?, max?, options? }
-- kind: "number" | "int" | "bool" | "choice" | "color" ("#rrggbb") | "material" (Enum.Material name) | "points"
-- ({ { x, y, z }, ... }, local studs).
local Geometry = require(script.Parent.Geometry)
local V, M = Geometry.V, Geometry.M

local Generators = {}

local pi, sin, cos, tan, sqrt, floor, max, min, abs, atan2 =
	math.pi, math.sin, math.cos, math.tan, math.sqrt, math.floor, math.max, math.min, math.abs, math.atan2

-- Roblox scale (studs; 1 stud = 28 cm). Sources: docs/modeling-research.md 3.1 / 5.2 (official tutorials, Humanoid
-- defaults, the Roqer building guide). Interactive things are bigger than real proportions (doors 1.4-1.6x a player).
Generators.SCALE = {
	STUD_CM = 28,
	CHARACTER_HEIGHT = 5, -- classic avatar ~5 (R15 4.75-5.1, Rthro 5.75-6.5)
	CHARACTER_WIDTH = 2,
	JUMP_HEIGHT = 7.2, -- Humanoid.JumpHeight default: a barrier must be >= 8 to stop players
	WALK_SPEED = 16,
	BARRIER_HEIGHT = 8,
	GRID = 4, -- structure grid (terrain voxel = 4, texture tile = 8); details on 2 / 1 / 0.5
	DOOR_WIDTH = 5, -- 5 x 8 for multiplayer games; 4 x 7 is the minimum
	DOOR_HEIGHT = 8,
	DOOR_MIN = { 4, 7 },
	HALLWAY_WIDTH = 10,
	PATH_WIDTH = 6,
	STEP_RISE = 1, -- 0.8-1.25
	STEP_RUN = 1.5,
	FLOOR_HEIGHT = 12, -- ceilings 10-14
	WALL_THICKNESS = 1,
	WINDOW_WIDTH = 4,
	WINDOW_HEIGHT = 5,
	WINDOW_SILL = 3,
	RAILING_HEIGHT = 3.5,
	TABLE_HEIGHT = 3.5,
	SEAT_HEIGHT = 1.5,
	BED = { 5, 1.8, 7 }, -- width, height, length
	ROAD_LANE = 12,
	ROAD_WIDTH = 24, -- two lanes
	SIDEWALK = 6,
	CURB = 0.5,
}
local S = Generators.SCALE

-- ---------------------------------------------------------------------------------------------
-- pieces
-- ---------------------------------------------------------------------------------------------
local function piece(shape, size, cf, style, name)
	local pc = { shape = shape, size = size, cf = cf }
	if style then
		for k, v in style do
			pc[k] = v
		end
	end
	if name then
		pc.name = name
	end
	return pc
end

local function at(x, y, z, r)
	return { p = { x, y, z }, r = r or M.IDENTITY }
end

local function push(list, items)
	for _, it in items do
		table.insert(list, it)
	end
end

local function moved(pieces, frame)
	return Geometry.transformPieces(pieces, frame)
end

-- a vertical cylinder (Roblox cylinders run along X: rotate X to Y)
local ROT_UP = M.rz(pi / 2)
local function column(x, y0, z, height, diameter, style, name)
	return piece("Cylinder", { height, diameter, diameter }, at(x, y0 + height / 2, z, ROT_UP), style, name)
end

-- rectangle [x0, x1] x [y0, y1] minus rectangular holes -> rectangles (the better of a vertical and a horizontal sweep)
local function subtractRects(x0, x1, y0, y1, holes)
	local function sweep(a0, a1, b0, b1, hs)
		local xs = { a0, a1 }
		for _, h in hs do
			table.insert(xs, max(a0, min(a1, h[1])))
			table.insert(xs, max(a0, min(a1, h[2])))
		end
		table.sort(xs)
		local cuts = {}
		for _, x in xs do
			if #cuts == 0 or x - cuts[#cuts] > 1e-6 then
				table.insert(cuts, x)
			end
		end
		local rects, open = {}, {}
		for i = 1, #cuts - 1 do
			local s0, s1 = cuts[i], cuts[i + 1]
			local cover = {}
			for _, h in hs do
				if h[1] <= s0 + 1e-6 and h[2] >= s1 - 1e-6 then
					table.insert(cover, { max(b0, h[3]), min(b1, h[4]) })
				end
			end
			table.sort(cover, function(p, q)
				return p[1] < q[1]
			end)
			local free, cursor = {}, b0
			for _, cv in cover do
				if cv[1] - cursor > 1e-6 then
					table.insert(free, { cursor, cv[1] })
				end
				cursor = max(cursor, cv[2])
			end
			if b1 - cursor > 1e-6 then
				table.insert(free, { cursor, b1 })
			end
			local nextOpen = {}
			for _, fr in free do
				local key = string.format("%.5f:%.5f", fr[1], fr[2])
				local r = open[key]
				if r and abs(r[2] - s0) < 1e-6 then
					r[2] = s1
				else
					r = { s0, s1, fr[1], fr[2] }
					table.insert(rects, r)
				end
				nextOpen[key] = r
			end
			open = nextOpen
		end
		return rects
	end
	local vertical = sweep(x0, x1, y0, y1, holes)
	local flipped = {}
	for _, h in holes do
		table.insert(flipped, { h[3], h[4], h[1], h[2] })
	end
	local horizontal = sweep(y0, y1, x0, x1, flipped)
	if #horizontal < #vertical then
		local out = {}
		for _, r in horizontal do
			table.insert(out, { r[3], r[4], r[1], r[2] })
		end
		return out
	end
	return vertical
end
Generators.subtractRects = subtractRects

-- wall pieces in the wall's own frame: x along the wall (centred), y up from 0, thickness along z
local function wallPieces(length, height, thickness, holes, style, name)
	local out = {}
	for _, r in subtractRects(-length / 2, length / 2, 0, height, holes) do
		local w, h = r[2] - r[1], r[4] - r[3]
		if w >= Geometry.MIN_SIZE and h >= Geometry.MIN_SIZE then
			table.insert(out, piece("Block", { w, h, thickness }, at((r[1] + r[2]) / 2, (r[3] + r[4]) / 2, 0), style, name))
		end
	end
	return out
end

-- glass + trims inside an opening (x0, x1, y0, y1) of a wall `thickness` thick; frames: "none" | "sill" (one sill
-- standing out of the wall) | "full" (4 trims)
local function windowPieces(x0, x1, y0, y1, thickness, frames, glassStyle, trimStyle)
	local out = {}
	local w, h = x1 - x0, y1 - y0
	local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
	local frame = 0.3
	table.insert(out, piece("Block", { w, h, 0.2 }, at(cx, cy, 0), glassStyle, "Geam"))
	if frames == "sill" then
		table.insert(out, piece("Block", { w + 0.6, 0.3, thickness + 0.6 }, at(cx, y0 - 0.15, 0), trimStyle, "Pervaz"))
	elseif frames == "full" and w > 2 * frame and h > 2 * frame then
		local d = thickness + 0.2
		table.insert(out, piece("Block", { w, frame, d }, at(cx, y1 - frame / 2, 0), trimStyle, "Ramă"))
		table.insert(out, piece("Block", { w, frame, d }, at(cx, y0 + frame / 2, 0), trimStyle, "Pervaz"))
		table.insert(out, piece("Block", { frame, h - 2 * frame, d }, at(x0 + frame / 2, cy, 0), trimStyle, "Ramă"))
		table.insert(out, piece("Block", { frame, h - 2 * frame, d }, at(x1 - frame / 2, cy, 0), trimStyle, "Ramă"))
	end
	return out
end

local function style(color, material, extra)
	local s = { color = color, material = material }
	if extra then
		for k, v in extra do
			s[k] = v
		end
	end
	return s
end

-- ---------------------------------------------------------------------------------------------
-- roofs (base rectangle w x d centred at the origin, from y = 0 up to h; ridge along X)
-- ---------------------------------------------------------------------------------------------
local function gableRoof(w, d, h, overhang, infillStyle, roofStyle)
	local out = {}
	-- the triangular prism: two wedges whose high side meets at the ridge
	table.insert(out, piece("Wedge", { w, h, d / 2 }, at(0, h / 2, -d / 4), infillStyle, "Fronton"))
	table.insert(out, piece("Wedge", { w, h, d / 2 }, at(0, h / 2, d / 4, M.ry(pi)), infillStyle, "Fronton"))
	-- the roof panels, overhanging the walls
	local thick = 0.4
	local run = d / 2 + overhang
	local slope = atan2(h, d / 2)
	local length = run / cos(slope)
	for _, side in { -1, 1 } do
		local ridge = { 0, h, 0 }
		local eave = { 0, h - run * tan(slope), side * run }
		local down = V.sub(eave, ridge)
		local r = M.lookAlong(down, { 0, 1, 0 })
		local up = M.column(r, 2)
		local center = V.add(V.mid(ridge, eave), V.scale(up, thick / 2))
		table.insert(out, piece("Block", { w + 2 * overhang, thick, length }, { p = center, r = r }, roofStyle, "Acoperiș"))
	end
	return out
end

local function hipRoof(w, d, h, roofStyle)
	local out = {}
	local ridge = w - d
	if ridge > Geometry.MIN_SIZE then
		table.insert(out, piece("Wedge", { ridge, h, d / 2 }, at(0, h / 2, -d / 4), roofStyle, "Acoperiș"))
		table.insert(out, piece("Wedge", { ridge, h, d / 2 }, at(0, h / 2, d / 4, M.ry(pi)), roofStyle, "Acoperiș"))
	end
	local half = max(ridge, 0) / 2
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			-- quarter of the hip end: footprint d/2 x d/2, apex over its corner at the ridge end
			local c = { sx * (half + d / 4), h / 2, sz * d / 4 }
			table.insert(out, Geometry.cornerWedge(c, d / 2, h, d / 2, -sx, -sz, table.clone(roofStyle)))
			out[#out].name = "Acoperiș"
		end
	end
	return out
end

-- a roof on a w x d rectangle, ridge along the longer side
local function roof(kind, w, d, h, overhang, infillStyle, roofStyle)
	local alongZ = d > w
	local lw, ld = alongZ and d or w, alongZ and w or d
	local out
	if kind == "gable" then
		out = gableRoof(lw, ld, h, overhang, infillStyle, roofStyle)
	elseif kind == "hip" then
		out = hipRoof(lw + 2 * overhang, ld + 2 * overhang, h, roofStyle)
	else
		return {}
	end
	if alongZ then
		out = moved(out, { p = { 0, 0, 0 }, r = M.ry(pi / 2) })
	end
	return out
end

-- ---------------------------------------------------------------------------------------------
-- building
-- ---------------------------------------------------------------------------------------------
local function building(p)
	local W, D, floors, FH, T, slab = p.width, p.depth, p.floors, p.floorHeight, p.wall, p.slab
	local H = floors * FH
	local wallStyle = style(p.wallColor, p.wallMaterial)
	local trimStyle = style(p.trimColor, "SmoothPlastic")
	local glassStyle = style(p.glassColor, "Glass", { transparency = 0.45, castShadow = false })
	local floorStyle = style(p.floorColor, "WoodPlanks")
	local roofStyle = style(p.roofColor, p.roofMaterial)
	local out = {}
	local windows, doors = 0, 0
	local walls = {
		{ name = "Perete față", L = W, cf = at(0, 0, -D / 2 + T / 2), front = true },
		{ name = "Perete spate", L = W, cf = at(0, 0, D / 2 - T / 2, M.ry(pi)) },
		{ name = "Perete stânga", L = D - 2 * T, cf = at(-W / 2 + T / 2, 0, 0, M.ry(-pi / 2)) },
		{ name = "Perete dreapta", L = D - 2 * T, cf = at(W / 2 - T / 2, 0, 0, M.ry(pi / 2)) },
	}
	for _, wall in walls do
		local L = wall.L
		local holes, extras = {}, {}
		local n = 0
		if p.windows and p.windowSpacing > 0 then
			n = floor(L / p.windowSpacing)
			while n > 0 and n * p.windowWidth + (n + 1) * 1 > L do
				n -= 1
			end
		end
		local doorX0, doorX1
		if wall.front and p.door then
			doorX0, doorX1 = -p.doorWidth / 2, p.doorWidth / 2
			local top = slab + p.doorHeight
			table.insert(holes, { doorX0, doorX1, 0, top })
			table.insert(extras, piece("Block", { p.doorWidth - 0.2, p.doorHeight, 0.4 }, at(0, slab + p.doorHeight / 2, 0),
				style(p.doorColor, "Wood"), "Ușă"))
			doors += 1
		end
		for f = 0, floors - 1 do
			for i = 1, n do
				local cx = -L / 2 + L * (i - 0.5) / n
				local x0, x1 = cx - p.windowWidth / 2, cx + p.windowWidth / 2
				local y0 = f * FH + slab + p.sill
				local y1 = min(y0 + p.windowHeight, (f + 1) * FH - 0.5)
				local blocked = doorX0 and f == 0 and x1 > doorX0 - 1 and x0 < doorX1 + 1
				if y1 - y0 > 0.5 and not blocked then
					table.insert(holes, { x0, x1, y0, y1 })
					push(extras, windowPieces(x0, x1, y0, y1, T, p.frames, glassStyle, trimStyle))
					windows += 1
				end
			end
		end
		push(out, moved(wallPieces(L, H, T, holes, wallStyle, wall.name), wall.cf))
		push(out, moved(extras, wall.cf))
	end
	-- slabs: ground, interior floors (inside the walls), ceiling / roof base
	table.insert(out, piece("Block", { W, slab, D }, at(0, slab / 2, 0), floorStyle, "Podea"))
	if p.slabs then
		for f = 1, floors - 1 do
			table.insert(out, piece("Block", { W - 2 * T, slab, D - 2 * T }, at(0, f * FH + slab / 2, 0), floorStyle, "Planșeu"))
		end
	end
	table.insert(out, piece("Block", { W, slab, D }, at(0, H + slab / 2, 0), p.roof == "flat" and roofStyle or floorStyle, "Tavan"))
	local top = H + slab
	-- roof height from the pitch over the shorter span
	local roofHeight = math.min(W, D) / 2 * tan(math.rad(p.roofPitch))
	if p.roof == "flat" then
		local ph = 1.5
		table.insert(out, piece("Block", { W, ph, T }, at(0, top + ph / 2, -D / 2 + T / 2), wallStyle, "Parapet"))
		table.insert(out, piece("Block", { W, ph, T }, at(0, top + ph / 2, D / 2 - T / 2), wallStyle, "Parapet"))
		table.insert(out, piece("Block", { T, ph, D - 2 * T }, at(-W / 2 + T / 2, top + ph / 2, 0), wallStyle, "Parapet"))
		table.insert(out, piece("Block", { T, ph, D - 2 * T }, at(W / 2 - T / 2, top + ph / 2, 0), wallStyle, "Parapet"))
	else
		push(out, moved(roof(p.roof, W, D, roofHeight, p.overhang, wallStyle, roofStyle), at(0, top, 0)))
	end
	return { pieces = out, info = { windows = windows, doors = doors, height = top + (p.roof == "flat" and 1.5 or roofHeight) } }
end

-- ---------------------------------------------------------------------------------------------
-- stairs
-- ---------------------------------------------------------------------------------------------
-- one straight flight in its own frame: starts at z = 0, climbs toward -z; steps first..last (1-based), each `h` high
local function flight(firstStep, count, h, run, width, solid, baseY, st, thickness)
	local out = {}
	for k = 1, count do
		local i = firstStep + k - 1
		local topY = baseY + i * h
		local z = -(k - 0.5) * run
		if solid then
			table.insert(out, piece("Block", { width, topY, run }, at(0, topY / 2, z), st, "Treaptă"))
		else
			table.insert(out, piece("Block", { width, thickness, run }, at(0, topY - thickness / 2, z), st, "Treaptă"))
		end
	end
	return out
end

-- posts every `every` steps + one sloped handrail, on the side x = sideX of a flight (same frame as `flight`)
local function flightRailing(firstStep, count, h, run, sideX, railH, every, st)
	local out = {}
	local tops = {}
	for k = 1, count, every do
		local i = firstStep + k - 1
		local z = -(k - 0.5) * run
		local y = i * h
		table.insert(out, piece("Block", { 0.3, railH, 0.3 }, at(sideX, y + railH / 2, z), st, "Stâlp"))
		table.insert(tops, { sideX, y + railH, z })
	end
	if (count - 1) % every ~= 0 then
		local i = firstStep + count - 1
		local z = -(count - 0.5) * run
		table.insert(out, piece("Block", { 0.3, railH, 0.3 }, at(sideX, i * h + railH / 2, z), st, "Stâlp"))
		table.insert(tops, { sideX, i * h + railH, z })
	end
	if #tops >= 2 then
		local rail = Geometry.beam(tops[1], tops[#tops], 0.35, 0.25)
		if rail then
			rail.size[3] += 0.3
			push(out, { piece(rail.shape, rail.size, rail.cf, st, "Mână curentă") })
		end
	end
	return out
end

local function stairs(p)
	local n = math.ceil(p.height / p.rise - 1e-9)
	local h = p.height / n
	local st = style(p.color, p.material)
	local railSt = style(p.railColor, "Metal")
	local out = {}
	local solid = p.style == "solid"
	local turn = p.turn == "left" and -1 or 1
	if p.kind == "straight" then
		push(out, flight(1, n, h, p.run, p.width, solid, 0, st, 0.4))
		if p.railings then
			for _, sx in { -1, 1 } do
				push(out, flightRailing(1, n, h, p.run, sx * (p.width / 2 - 0.2), p.railHeight, 2, railSt))
			end
		end
	elseif p.kind == "L" then
		local n1 = max(1, floor(n / 2))
		local n2 = n - n1
		push(out, flight(1, n1, h, p.run, p.width, solid, 0, st, 0.4))
		local landY = n1 * h
		local landZ = -n1 * p.run - p.width / 2
		if solid then
			table.insert(out, piece("Block", { p.width, landY, p.width }, at(0, landY / 2, landZ), st, "Podest"))
		else
			table.insert(out, piece("Block", { p.width, 0.4, p.width }, at(0, landY - 0.2, landZ), st, "Podest"))
		end
		-- second flight: leaves the landing sideways (turn = 1: toward +x)
		local frame2 = at(turn * p.width / 2, 0, landZ, M.ry(-turn * pi / 2))
		if n2 > 0 then
			push(out, moved(flight(n1 + 1, n2, h, p.run, p.width, solid, 0, st, 0.4), frame2))
		end
		if p.railings then
			push(out, flightRailing(1, n1, h, p.run, -turn * (p.width / 2 - 0.2), p.railHeight, 2, railSt))
			if n2 > 0 then
				push(out, moved(flightRailing(n1 + 1, n2, h, p.run, turn * (p.width / 2 - 0.2), p.railHeight, 2, railSt), frame2))
			end
		end
	else -- spiral
		local R, c = p.radius, p.column
		local stepAngle = 2 * pi / p.stepsPerTurn
		table.insert(out, column(0, 0, 0, p.height + (p.railings and p.railHeight or 0), 2 * c, st, "Coloană"))
		local treadLen = R - c * 0.5
		local treadW = 2 * R * tan(stepAngle / 2) * 1.08
		local thick = solid and h or 0.4
		local tops = {}
		for i = 1, n do
			local a = turn * stepAngle * (i - 1)
			local r = M.ry(-a)
			local mid = c * 0.5 + treadLen / 2
			local pos = M.apply(r, { mid, i * h - thick / 2, 0 })
			table.insert(out, piece("Block", { treadLen, thick, treadW }, { p = pos, r = r }, st, "Treaptă"))
			if p.railings and (i % 2 == 1 or i == n) then
				local post = M.apply(r, { R - 0.3, 0, 0 })
				table.insert(out, piece("Block", { 0.3, p.railHeight, 0.3 }, at(post[1], i * h + p.railHeight / 2, post[3]), railSt, "Stâlp"))
				table.insert(tops, { post[1], i * h + p.railHeight, post[3] })
			end
		end
		for i = 1, #tops - 1 do
			local rail = Geometry.beam(tops[i], tops[i + 1], 0.35, 0.25)
			if rail then
				rail.size[3] += 0.3
				table.insert(out, piece(rail.shape, rail.size, rail.cf, railSt, "Mână curentă"))
			end
		end
	end
	return { pieces = out, info = { steps = n, rise = h } }
end

-- ---------------------------------------------------------------------------------------------
-- fence / railing along a path
-- ---------------------------------------------------------------------------------------------
local function pathPoints(p)
	local pts = {}
	for _, v in p.points do
		table.insert(pts, V.from(v))
	end
	if p.smooth and #pts >= 3 then
		local sp = Geometry.spline(pts, { tension = 0, segments = 12 })
		if sp then
			local out = {}
			for _, smp in sp.samples(max(1, p.postSpacing / 2)) do
				table.insert(out, smp.p)
			end
			return out
		end
	end
	return pts
end

local function fence(p)
	local st = style(p.color, p.material)
	local metal = p.style == "metal"
	local out = {}
	local pts = pathPoints(p)
	-- post positions: every vertex + even subdivisions of each segment
	local posts = {}
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local d = V.dist(a, b)
		local k = max(1, math.ceil(d / p.postSpacing - 1e-9))
		for j = 0, k - 1 do
			table.insert(posts, V.lerp(a, b, j / k))
		end
	end
	table.insert(posts, pts[#pts])
	for _, q in posts do
		if metal then
			table.insert(out, column(q[1], q[2], q[3], p.height, p.postSize * 0.6, st, "Stâlp"))
		else
			table.insert(out, piece("Block", { p.postSize, p.height, p.postSize }, at(q[1], q[2] + p.height / 2, q[3]), st, "Stâlp"))
		end
	end
	local rails = max(1, p.rails)
	for i = 1, #posts - 1 do
		local a, b = posts[i], posts[i + 1]
		for r = 1, rails do
			local y = rails == 1 and p.height * 0.8 or (p.height * (0.35 + 0.45 * (r - 1) / (rails - 1)))
			if metal and r == rails then
				y = p.height - 0.1
			end
			local ra, rb = V.add(a, { 0, y, 0 }), V.add(b, { 0, y, 0 })
			if metal then
				local rod = Geometry.rod(ra, rb, 0.25)
				if rod then
					table.insert(out, piece(rod.shape, rod.size, rod.cf, st, "Bară"))
				end
			else
				local beam = Geometry.beam(ra, rb, 0.3, 0.45)
				if beam then
					table.insert(out, piece(beam.shape, beam.size, beam.cf, st, "Scândură"))
				end
			end
		end
		if p.style == "picket" then
			local d = V.dist(a, b)
			local k = floor(d / 0.9)
			local dir = V.unit(V.sub(b, a), { 1, 0, 0 }) :: any
			local r = M.lookAlong(dir, { 0, 1, 0 })
			for j = 1, k - 1 do
				local q = V.lerp(a, b, j / k)
				table.insert(out, piece("Block", { 0.4, p.height * 0.85, 0.15 }, { p = { q[1], q[2] + p.height * 0.425, q[3] }, r = r }, st, "Șipcă"))
			end
		end
	end
	if p.collision == "box" then
		-- the visible parts stop colliding; one invisible box per straight run blocks the way
		for _, pc in out do
			pc.canCollide = false
		end
		for i = 1, #pts - 1 do
			local a, b = pts[i], pts[i + 1]
			local beam = Geometry.beam(V.add(a, { 0, p.height / 2, 0 }), V.add(b, { 0, p.height / 2, 0 }), max(1, p.postSize), p.height)
			if beam then
				table.insert(out, piece(beam.shape, beam.size, beam.cf, { transparency = 1, castShadow = false, material = "SmoothPlastic" }, "Coliziune"))
			end
		end
	end
	return { pieces = out, info = { posts = #posts } }
end

-- ---------------------------------------------------------------------------------------------
-- bridge (along Z, from z = -length/2 to +length/2; the deck's top at y = height)
-- ---------------------------------------------------------------------------------------------
local function railingAlong(z0, z1, x, y, h, spacing, st)
	local out = {}
	local k = max(1, math.ceil((z1 - z0) / spacing - 1e-9))
	for j = 0, k do
		local z = z0 + (z1 - z0) * j / k
		table.insert(out, piece("Block", { 0.4, h, 0.4 }, at(x, y + h / 2, z), st, "Stâlp"))
	end
	table.insert(out, piece("Block", { 0.4, 0.3, z1 - z0 + 0.4 }, at(x, y + h - 0.15, (z0 + z1) / 2), st, "Balustradă"))
	table.insert(out, piece("Block", { 0.25, 0.25, z1 - z0 }, at(x, y + h * 0.5, (z0 + z1) / 2), st, "Balustradă"))
	return out
end

local function bridge(p)
	local L, Wd, H, dk = p.length, p.width, p.height, p.deck
	local st = style(p.color, p.material)
	local metal = style(p.cableColor, "Metal")
	local out = {}
	table.insert(out, piece("Block", { Wd, dk, L }, at(0, H - dk / 2, 0), st, "Tablier"))
	if p.kind == "beam" then
		for _, sx in { -1, 1 } do
			table.insert(out, piece("Block", { 1, 1.5, L }, at(sx * (Wd / 2 - 1), H - dk - 0.75, 0), st, "Grindă"))
		end
		local piers = max(1, math.ceil(L / p.pierSpacing - 1e-9))
		for j = 0, piers do
			local z = -L / 2 + 1 + (L - 2) * j / piers
			local ph = H - dk - 1.5
			if ph > Geometry.MIN_SIZE then
				table.insert(out, piece("Block", { Wd - 1, ph, 2 }, at(0, ph / 2, z), st, "Pilon"))
			end
		end
	elseif p.kind == "arch" then
		local rise = max(1, H - dk - 0.5)
		local half = L / 2
		local R = (half * half + rise * rise) / (2 * rise)
		local cy = rise - R -- circle centre (y), z = 0
		local a0 = atan2(-half, -cy) -- angle of the springing points from the vertical
		local segs = p.segments
		local pts = {}
		for j = 0, segs do
			local a = a0 + (-2 * a0) * j / segs
			table.insert(pts, { 0, cy + R * cos(a), R * sin(a) })
		end
		for j = 1, segs do
			local beam = Geometry.beam(pts[j], pts[j + 1], Wd, 1.5)
			if beam then
				beam.size[3] *= 1.04
				table.insert(out, piece(beam.shape, beam.size, beam.cf, st, "Arc"))
			end
		end
		-- spandrel posts between the arch and the deck
		local k = floor(L / 4)
		for j = 1, k - 1 do
			local z = -half + L * j / k
			local a = math.asin(max(-1, min(1, z / R)))
			local yArch = cy + R * cos(a)
			local ph = H - dk - yArch
			if ph > 0.3 then
				table.insert(out, piece("Block", { Wd, ph, 0.8 }, at(0, yArch + ph / 2, z), st, "Montant"))
			end
		end
	else -- suspension
		local tz = L / 2 - L * 0.2
		local towerH = H + p.towerHeight
		for _, sz in { -1, 1 } do
			for _, sx in { -1, 1 } do
				table.insert(out, piece("Block", { 1.5, towerH, 1.5 }, at(sx * (Wd / 2 + 0.75), towerH / 2, sz * tz), st, "Pilon"))
			end
			table.insert(out, piece("Block", { Wd + 3, 1.5, 1.5 }, at(0, towerH - 0.75, sz * tz), st, "Traversă"))
			table.insert(out, piece("Block", { Wd + 3, 1, 1.5 }, at(0, H - dk - 0.5, sz * tz), st, "Traversă"))
		end
		-- main cables: anchor -> tower top -> sag (parabola) -> tower top -> anchor
		local sagY = H + 1.5
		local function cableY(z)
			local az = abs(z)
			if az >= tz then -- side span: straight from the tower top down to the anchor at the deck end
				local t = (az - tz) / (L / 2 - tz)
				return towerH + (H + 0.5 - towerH) * t
			end
			local u = z / tz
			return sagY + (towerH - sagY) * u * u
		end
		local samples = {}
		local cableSeg = p.segments
		local zs = { -L / 2 }
		for j = 1, 3 do
			table.insert(zs, -L / 2 + (L / 2 - tz) * j / 3)
		end
		for j = 1, cableSeg - 1 do
			table.insert(zs, -tz + 2 * tz * j / cableSeg)
		end
		table.insert(zs, tz)
		for j = 1, 3 do
			table.insert(zs, tz + (L / 2 - tz) * j / 3)
		end
		for _, z in zs do
			table.insert(samples, z)
		end
		for _, sx in { -1, 1 } do
			local x = sx * (Wd / 2 + 0.75)
			for j = 1, #samples - 1 do
				local a = { x, cableY(samples[j]), samples[j] }
				local b = { x, cableY(samples[j + 1]), samples[j + 1] }
				local rod = Geometry.rod(a, b, 0.4)
				if rod then
					table.insert(out, piece(rod.shape, rod.size, rod.cf, metal, "Cablu"))
				end
			end
			-- hangers
			local k = floor(2 * tz / 3)
			for j = 1, k - 1 do
				local z = -tz + 2 * tz * j / k
				local top = cableY(z)
				local rod = Geometry.rod({ x, H, z }, { x, top, z }, 0.15)
				if rod and top - H > 0.3 then
					table.insert(out, piece(rod.shape, rod.size, rod.cf, metal, "Tirant"))
				end
			end
		end
	end
	if p.railings then
		for _, sx in { -1, 1 } do
			push(out, railingAlong(-L / 2 + 0.2, L / 2 - 0.2, sx * (Wd / 2 - 0.2), H, 4, 6, p.kind == "suspension" and metal or st))
		end
	end
	return { pieces = out, info = {} }
end

-- ---------------------------------------------------------------------------------------------
-- tower
-- ---------------------------------------------------------------------------------------------
local function tower(p)
	local R, H, T = p.radius, p.height, p.wall
	local st = style(p.color, p.material)
	local floorSt = style(p.floorColor, "WoodPlanks")
	local out = {}
	local doorW, doorH = S.DOOR_WIDTH, S.DOOR_HEIGHT
	local merlonH = p.crenellations and 3 or 0
	if p.shape == "round" then
		local n = p.segments
		local segW = 2 * R * tan(pi / n) + 0.05
		for k = 0, n - 1 do
			local a = 2 * pi * k / n
			local r = M.ry(-a)
			local dir = M.apply(r, { 0, 0, -1 }) -- the outward normal of segment k (k = 0 faces -Z)
			local c = V.scale(dir, R - T / 2)
			local frame = { p = c, r = r }
			if k == 0 and p.door then
				local holes = { { -min(doorW, segW - 0.6) / 2, min(doorW, segW - 0.6) / 2, 0, doorH } }
				push(out, moved(wallPieces(segW, H, T, holes, st, "Zid"), frame))
			else
				push(out, moved({ piece("Block", { segW, H, T }, at(0, H / 2, 0), st, "Zid") }, frame))
			end
			if p.crenellations and k % 2 == 0 then
				push(out, moved({ piece("Block", { segW * 0.9, merlonH, T }, at(0, H + merlonH / 2, 0), st, "Merlon") }, frame))
			end
		end
		table.insert(out, column(0, 0, 0, 1, 2 * (R - T / 2), floorSt, "Podea"))
		table.insert(out, column(0, H - 1, 0, 1, 2 * (R - T / 2), floorSt, "Platformă"))
		for f = 1, p.floors do
			local y = H * f / (p.floors + 1)
			table.insert(out, column(0, y - 0.5, 0, 1, 2 * (R - T / 2), floorSt, "Planșeu"))
		end
	else
		local W = 2 * R
		local sides = {
			{ L = W, cf = at(0, 0, -R + T / 2), front = true },
			{ L = W, cf = at(0, 0, R - T / 2, M.ry(pi)) },
			{ L = W - 2 * T, cf = at(-R + T / 2, 0, 0, M.ry(-pi / 2)) },
			{ L = W - 2 * T, cf = at(R - T / 2, 0, 0, M.ry(pi / 2)) },
		}
		for _, s in sides do
			local holes = {}
			if s.front and p.door then
				table.insert(holes, { -doorW / 2, doorW / 2, 0, doorH })
			end
			push(out, moved(wallPieces(s.L, H, T, holes, st, "Zid"), s.cf))
			if p.crenellations then
				local mw = 2 -- merlons 2 wide on a pitch of 4
				local k = max(1, floor(s.L / (2 * mw)))
				for j = 0, k - 1 do
					local x = -s.L / 2 + mw / 2 + (s.L - mw) * (k == 1 and 0.5 or j / (k - 1))
					push(out, moved({ piece("Block", { mw, merlonH, T }, at(x, H + merlonH / 2, 0), st, "Merlon") }, s.cf))
				end
			end
		end
		table.insert(out, piece("Block", { W - 2 * T, 1, W - 2 * T }, at(0, 0.5, 0), floorSt, "Podea"))
		table.insert(out, piece("Block", { W - 2 * T, 1, W - 2 * T }, at(0, H - 0.5, 0), floorSt, "Platformă"))
		for f = 1, p.floors do
			local y = H * f / (p.floors + 1)
			table.insert(out, piece("Block", { W - 2 * T, 1, W - 2 * T }, at(0, y, 0), floorSt, "Planșeu"))
		end
	end
	if p.roof == "pyramid" then
		local w = 2 * R + 1
		push(out, Geometry.pyramid({ 0, H + merlonH, 0 }, w, w, R * 1.2, style(p.roofColor, "Slate", { name = "Acoperiș" })))
	end
	return { pieces = out, info = {} }
end

-- ---------------------------------------------------------------------------------------------
-- arch, colonnade, wall with gate
-- ---------------------------------------------------------------------------------------------
-- semicircular arch ring (in the XY plane, depth along Z) springing at height y0 with inner radius r
local function archRing(r, thickness, depth, y0, segments, st)
	local out = {}
	local rm = r + thickness / 2
	local da = pi / segments
	for i = 0, segments - 1 do
		local a = da * (i + 0.5)
		local chord = 2 * (r + thickness) * sin(da / 2) + 0.02
		local pos = { -cos(a) * rm, y0 + sin(a) * rm, 0 }
		-- X tangent to the circle, Y radial
		local radial = { -cos(a), sin(a), 0 }
		local tangent = { sin(a), cos(a), 0 }
		local rot = M.fromColumns(tangent, radial, V.cross(tangent, radial))
		table.insert(out, piece("Block", { chord, thickness, depth }, { p = pos, r = rot }, st, i == floor(segments / 2) and "Cheie" or "Bolțar"))
	end
	return out
end

local function arch(p)
	local st = style(p.color, p.material)
	local out = {}
	local r = p.span / 2
	for _, sx in { -1, 1 } do
		table.insert(out, piece("Block", { p.pillarWidth, p.height, p.depth }, at(sx * (r + p.pillarWidth / 2), p.height / 2, 0), st, "Pilastru"))
	end
	push(out, archRing(r, p.thickness, p.depth, p.height, p.segments, st))
	return { pieces = out, info = {} }
end

local function colonnade(p)
	local st = style(p.color, p.material)
	local out = {}
	local n = p.count
	local dia = p.diameter
	local capH = 0.6
	local shaft = p.height - (p.base and capH or 0) - (p.capital and capH or 0)
	for i = 0, n - 1 do
		local x = (i - (n - 1) / 2) * p.spacing
		local y = 0
		if p.base then
			table.insert(out, piece("Block", { dia * 1.5, capH, dia * 1.5 }, at(x, capH / 2, 0), st, "Bază"))
			y = capH
		end
		table.insert(out, column(x, y, 0, shaft, dia, st, "Coloană"))
		if p.capital then
			table.insert(out, piece("Block", { dia * 1.5, capH, dia * 1.5 }, at(x, y + shaft + capH / 2, 0), st, "Capitel"))
		end
	end
	local span = (n - 1) * p.spacing + dia * 1.5
	if p.arches and n >= 2 then
		local r = (p.spacing - dia * 1.5) / 2
		for i = 0, n - 2 do
			local x = (i + 0.5 - (n - 1) / 2) * p.spacing
			push(out, moved(archRing(r, 1, dia * 1.5, p.height, 7, st), at(x, 0, 0)))
		end
	end
	if p.entablature then
		local top = p.height + (p.arches and (p.spacing / 2) or 0)
		table.insert(out, piece("Block", { span + 1, 1.5, dia * 1.5 + 0.5 }, at(0, top + 0.75, 0), st, "Antablament"))
	end
	return { pieces = out, info = { columns = n } }
end

local function gateWall(p)
	local st = style(p.color, p.material)
	local out = {}
	local L, H, T, gw, gh = p.length, p.height, p.thickness, p.gateWidth, min(p.gateHeight, p.height - 0.5)
	push(out, wallPieces(L, H, T, { { -gw / 2, gw / 2, 0, gh } }, st, "Zid"))
	if p.doors then
		for _, sx in { -1, 1 } do
			table.insert(out, piece("Block", { gw / 2 - 0.1, gh - 0.1, 0.6 }, at(sx * gw / 4, (gh - 0.1) / 2, 0), style(p.doorColor, "Wood"), "Poartă"))
		end
	end
	local towerW = p.towers and 6 or 0
	if p.crenellations then
		local mw = 2
		local usable = L - 2 * towerW
		local k = max(1, floor(usable / (2 * mw)))
		for j = 0, k - 1 do
			local x = -usable / 2 + mw / 2 + (usable - mw) * (k == 1 and 0.5 or j / (k - 1))
			table.insert(out, piece("Block", { mw, 2, T }, at(x, H + 1, 0), st, "Merlon"))
		end
	end
	if p.towers then
		local th = H + 4
		for _, sx in { -1, 1 } do
			local x = sx * (L / 2 - towerW / 2)
			table.insert(out, piece("Block", { towerW, th, towerW }, at(x, th / 2, 0), st, "Turn"))
			if p.crenellations then
				for _, cx in { -1, 1 } do
					for _, cz in { -1, 1 } do
						table.insert(out, piece("Block", { 1.5, 2, 1.5 }, at(x + cx * (towerW / 2 - 0.75), th + 1, cz * (towerW / 2 - 0.75)), st, "Merlon"))
					end
				end
			end
		end
	end
	return { pieces = out, info = {} }
end

-- ---------------------------------------------------------------------------------------------
-- roads (asphalt top at y = 1; sidewalks + curb above it)
-- ---------------------------------------------------------------------------------------------
local function roadArm(length, p, centerLine, asphalt, walk, paint, yellow)
	-- in the arm's frame: runs along Z from 0 to `length`... centred: z in [-length/2, length/2]
	local out = {}
	local w, sw = p.width, p.sidewalk
	table.insert(out, piece("Block", { w, 1, length }, at(0, 0.5, 0), asphalt, "Asfalt"))
	if sw > 0 then
		for _, sx in { -1, 1 } do
			table.insert(out, piece("Block", { sw, 1 + p.curb, length }, at(sx * (w / 2 + sw / 2), (1 + p.curb) / 2, 0), walk, "Trotuar"))
		end
	end
	if p.lines then
		local lineY = 1.025
		if centerLine then
			local period = p.dash + p.gap
			local k = floor((length + p.gap) / period)
			local used = k * period - p.gap
			for j = 0, k - 1 do
				local z = -used / 2 + j * period + p.dash / 2
				table.insert(out, piece("Block", { 0.5, 0.05, p.dash }, at(0, lineY, z), yellow, "Marcaj"))
			end
		end
		for _, sx in { -1, 1 } do
			table.insert(out, piece("Block", { 0.3, 0.05, length }, at(sx * (w / 2 - 0.6), lineY, 0), paint, "Marcaj"))
		end
	end
	return out
end

-- zebra stripes 1 wide, 8 long, every 2 studs across the road
local function crosswalk(w, z, paint)
	local out = {}
	local k = floor((w - 2) / 2) + 1
	for j = 0, k - 1 do
		local x = -(k - 1) + 2 * j
		table.insert(out, piece("Block", { 1, 0.05, 8 }, at(x, 1.025, z), paint, "Trecere"))
	end
	return out
end

local function road(p)
	local asphalt = style(p.color, "Asphalt")
	local walk = style(p.sidewalkColor, "Concrete")
	local paint = style("#f2f2f2", "SmoothPlastic", { canCollide = false, castShadow = false })
	local yellow = style("#f2c12e", "SmoothPlastic", { canCollide = false, castShadow = false })
	local out = {}
	local w, sw, L = p.width, p.sidewalk, p.length
	if p.kind == "straight" then
		push(out, roadArm(L, p, true, asphalt, walk, paint, yellow))
		return { pieces = out, info = {} }
	end
	-- intersection: a square of w x w + arms; "cross" = 4 arms, "T" = 3 (no arm toward +Z)
	local arm = (L - w) / 2
	if arm < 1 then
		arm = 1
	end
	table.insert(out, piece("Block", { w, 1, w }, at(0, 0.5, 0), asphalt, "Asfalt"))
	local dirs = { 0, pi / 2, pi, -pi / 2 } -- -Z, -X, +Z, +X
	for i, a in dirs do
		if not (p.kind == "T" and i == 3) then
			local frame = { p = M.apply(M.ry(a), { 0, 0, -(w / 2 + arm / 2) }), r = M.ry(a) }
			push(out, moved(roadArm(arm, p, true, asphalt, walk, paint, yellow), frame))
			if p.crosswalks and arm >= 10 then
				push(out, moved(crosswalk(w, arm / 2 - 5, paint), frame))
			end
		end
	end
	if sw > 0 then
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				table.insert(out, piece("Block", { sw, 1 + p.curb, sw }, at(sx * (w / 2 + sw / 2), (1 + p.curb) / 2, sz * (w / 2 + sw / 2)), walk, "Trotuar"))
			end
		end
		if p.kind == "T" then -- the closed side: a sidewalk across the square
			table.insert(out, piece("Block", { w, 1 + p.curb, sw }, at(0, (1 + p.curb) / 2, w / 2 + sw / 2), walk, "Trotuar"))
		end
	end
	return { pieces = out, info = {} }
end

-- ---------------------------------------------------------------------------------------------
-- nature: trees, rocks, crystals
-- ---------------------------------------------------------------------------------------------
local function tree(p, rng)
	local bark = style(p.trunkColor, "Wood")
	local leaf = style(p.leafColor, "Grass")
	local out = {}
	local H = p.height
	if p.kind == "pine" then
		local trunkH = H * 0.3
		table.insert(out, column(0, 0, 0, trunkH + 1, p.trunk, bark, "Trunchi"))
		local tiers = p.crown
		local crownH = H - trunkH
		local tierH = tiers == 1 and crownH or crownH / tiers * 1.45 -- tiers overlap; the top one ends at H
		local width = max(2, H * 0.45)
		for k = 1, tiers do
			local y0 = tiers == 1 and trunkH or trunkH + (k - 1) * (crownH - tierH) / (tiers - 1)
			local w = width * (1 - (k - 1) / (tiers + 0.6))
			local yaw = rng.range(0, pi / 2)
			push(out, Geometry.pyramid({ 0, y0, 0 }, w, w, tierH, { color = p.leafColor, material = "Grass", name = "Coroană" }, M.ry(yaw)))
		end
	elseif p.kind == "round" then
		local trunkH = H * 0.5
		table.insert(out, column(0, 0, 0, trunkH + 1, p.trunk, bark, "Trunchi"))
		local cr = max(1.5, H * 0.28)
		local center = { 0, trunkH + cr * 0.55, 0 }
		for k = 1, p.crown do
			local dir = V.unit({ rng.range(-1, 1), rng.range(-0.4, 1), rng.range(-1, 1) }, { 0, 1, 0 }) :: any
			local off = V.scale(dir, k == 1 and 0 or cr * rng.range(0.35, 0.6))
			local s = cr * (k == 1 and 1.5 or rng.range(0.9, 1.3))
			local r = M.fromOrientation(rng.range(0, pi), rng.range(0, pi), rng.range(0, pi))
			table.insert(out, piece("Block", { s, s * rng.range(0.8, 1), s }, { p = V.add(center, off), r = r }, leaf, "Coroană"))
		end
	else -- palm
		local segs = 6
		local lean = math.rad(rng.range(12, 22))
		local heading = rng.range(0, 2 * pi)
		local dirH = { cos(heading), 0, sin(heading) }
		local pts = {}
		for i = 0, segs do
			local t = i / segs
			local y = H * 0.82 * t
			local off = H * 0.82 * sin(lean) * t * t
			table.insert(pts, { dirH[1] * off, y, dirH[3] * off })
		end
		for i = 1, segs do
			local d = p.trunk * (1 - 0.35 * (i - 1) / segs)
			local rod = Geometry.rod(pts[i], pts[i + 1], d)
			if rod then
				rod.size[1] += 0.2
				table.insert(out, piece(rod.shape, rod.size, rod.cf, bark, "Trunchi"))
			end
		end
		local top = pts[#pts]
		local fronds = p.crown
		for k = 1, fronds do
			local a = 2 * pi * k / fronds + rng.range(-0.2, 0.2)
			local out1 = { cos(a), 0, sin(a) }
			local l1, l2 = H * 0.22, H * 0.26
			local p1 = V.add(top, V.add(V.scale(out1, l1 * cos(0.25)), { 0, l1 * sin(0.25), 0 }))
			local droop = rng.range(0.45, 0.75)
			local p2 = V.add(p1, V.add(V.scale(out1, l2 * cos(droop)), { 0, -l2 * sin(droop), 0 }))
			for _, seg in { { top, p1, 1.4 }, { p1, p2, 1.1 } } do
				local b = Geometry.beam(seg[1], seg[2], seg[3], 0.2)
				if b then
					b.size[3] += 0.3
					table.insert(out, piece(b.shape, b.size, b.cf, leaf, "Frunză"))
				end
			end
		end
		for k = 1, 3 do
			local a = 2 * pi * k / 3 + rng.range(-0.3, 0.3)
			table.insert(out, piece("Ball", { 0.9, 0.9, 0.9 }, at(top[1] + cos(a) * 0.6, top[2] - 0.6, top[3] + sin(a) * 0.6), style("#5a3d1e", "Wood"), "Nucă de cocos"))
		end
	end
	return { pieces = out, info = {} }
end

-- random points of a low-poly rock (on a squashed ellipsoid), lowest point slightly under y = 0
function Generators.rockPoints(rng, size: number, detail: number, flatten: number): { Geometry.Vec }
	local count = 8 + 5 * detail
	local pts = {}
	local lowest = math.huge
	for i = 1, count do
		-- evenly spread directions (golden spiral) with jitter, so the hull never collapses
		local yv = 1 - 2 * (i - 0.5) / count
		local rr = sqrt(max(0, 1 - yv * yv))
		local a = i * 2.399963 + rng.range(-0.3, 0.3)
		local radius = size / 2 * rng.range(0.72, 1)
		local q: Geometry.Vec = { cos(a) * rr * radius, yv * radius * flatten, sin(a) * rr * radius }
		table.insert(pts, q)
		lowest = min(lowest, q[2])
	end
	-- about 20 % of the height under the ground: rocks look set, not dropped
	local highest = -math.huge
	for _, q in pts do
		highest = max(highest, q[2])
	end
	local sink = lowest + (highest - lowest) * 0.2
	for _, q in pts do
		q[2] -= sink
	end
	return pts
end

local function rock(p, rng)
	local st = style(p.color, p.material)
	local out = {}
	if p.style == "blocks" then
		local k = 3 + p.detail
		for i = 1, k do
			local s = p.size * (i == 1 and 0.75 or rng.range(0.35, 0.6))
			local off = i == 1 and { 0, 0, 0 } or { rng.range(-0.3, 0.3) * p.size, rng.range(-0.1, 0.15) * p.size, rng.range(-0.3, 0.3) * p.size }
			local r = M.fromOrientation(rng.range(-0.5, 0.5), rng.range(0, pi), rng.range(-0.5, 0.5))
			table.insert(out, piece("Block", { s, s * p.flatten, s * rng.range(0.8, 1.1) }, { p = V.add(off, { 0, s * p.flatten * 0.35, 0 }), r = r }, st, "Rocă"))
		end
		return { pieces = out, info = {} }
	end
	local pts = Generators.rockPoints(rng, p.size, p.detail, p.flatten)
	local faces = Geometry.convexHull(pts) or {}
	local thick = max(0.2, p.size * 0.12)
	for _, f in faces do
		local w = Geometry.triangleWedges(pts[f[1]], pts[f[2]], pts[f[3]], { thickness = thick, align = "front" })
		for _, pc in (w or {}) do
			for k, v in st do
				pc[k] = v
			end
			pc.name = "Rocă"
			table.insert(out, pc)
		end
	end
	return { pieces = out, info = { faces = #faces } }
end

local function crystals(p, rng)
	local st = style(p.color, p.material, { transparency = p.material == "Glass" and 0.2 or nil })
	local out = {}
	for i = 1, p.count do
		local main = i == 1
		local h = p.height * (main and 1 or rng.range(0.45, 0.8))
		local w = p.width * (main and 1 or rng.range(0.6, 0.9))
		local yaw = 2 * pi * (i - 1) / max(1, p.count - 1) + rng.range(-0.3, 0.3)
		local dist = main and 0 or p.width * rng.range(0.4, 0.9)
		local base = { cos(yaw) * dist, 0, sin(yaw) * dist }
		local tilt = main and math.rad(rng.range(0, 6)) or math.rad(rng.range(p.spread * 0.5, p.spread))
		local outward = { cos(yaw), 0, sin(yaw) }
		local axis = V.unit(V.cross({ 0, 1, 0 }, outward), { 1, 0, 0 }) :: any
		local r = M.mul(M.axisAngle(axis, tilt), M.ry(pi / 4 + rng.range(-0.2, 0.2)))
		local tipH = w * 1.3
		local bodyH = max(0.5, h - tipH)
		local bury = 0.3
		local frame = { p = base, r = r }
		local parts = { piece("Block", { w, bodyH, w }, at(0, bodyH / 2 - bury, 0), st, "Cristal") }
		push(parts, Geometry.pyramid({ 0, bodyH - bury, 0 }, w, w, tipH, { color = st.color, material = st.material, transparency = st.transparency, name = "Vârf" }))
		push(out, moved(parts, frame))
	end
	if p.base then
		local sub = rock({ style = "blocks", size = p.width * 2.2, detail = 0, flatten = 0.45, color = "#5b5560", material = "Slate" }, rng)
		push(out, sub.pieces)
	end
	return { pieces = out, info = {} }
end

-- ---------------------------------------------------------------------------------------------
-- furniture (character scale: seat at 2 studs, table top at 3)
-- ---------------------------------------------------------------------------------------------
local function tablePieces(wood, w, d)
	local out = {}
	local top = S.TABLE_HEIGHT
	table.insert(out, piece("Block", { w, 0.4, d }, at(0, top - 0.2, 0), wood, "Blat"))
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			table.insert(out, piece("Block", { 0.4, top - 0.4, 0.4 }, at(sx * (w / 2 - 0.4), (top - 0.4) / 2, sz * (d / 2 - 0.4)), wood, "Picior"))
		end
	end
	return out
end

-- chair 2 x 3.5 x 2, seat at 1.5 (a real Seat: characters can sit), back at +Z
local function chairPieces(wood, seat)
	local out = {}
	local sh = S.SEAT_HEIGHT
	table.insert(out, piece("Block", { 2, 0.3, 2 }, at(0, sh - 0.15, 0), seat, "Șezut"))
	out[#out].class = "Seat"
	table.insert(out, piece("Block", { 2, 2, 0.3 }, at(0, sh + 1, 0.85), wood, "Spătar"))
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			table.insert(out, piece("Block", { 0.3, sh - 0.3, 0.3 }, at(sx * 0.85, (sh - 0.3) / 2, sz * 0.85), wood, "Picior"))
		end
	end
	return out
end

local function furniture(p)
	local wood = style(p.color, "Wood")
	local fabric = style(p.fabricColor, "Fabric")
	local out = {}
	local kind = p.kind
	if kind == "table" then
		push(out, tablePieces(wood, 6, 3))
	elseif kind == "chair" then
		push(out, chairPieces(wood, wood))
	elseif kind == "bed" then
		local b = S.BED -- width, height, length; the head at +Z
		table.insert(out, piece("Block", { b[1], 0.9, b[3] }, at(0, 0.45, 0), wood, "Pat"))
		table.insert(out, piece("Block", { b[1] - 0.3, 0.7, b[3] - 0.4 }, at(0, 1.25, -0.1), style("#f2f2f5", "Fabric"), "Saltea"))
		table.insert(out, piece("Block", { b[1] - 1.6, 0.4, 1.2 }, at(0, 1.8, b[3] / 2 - 1.1), style("#ffffff", "Fabric"), "Pernă"))
		table.insert(out, piece("Block", { b[1] - 0.2, 0.15, b[3] * 0.55 }, at(0, 1.66, -b[3] * 0.2), fabric, "Pătură"))
		table.insert(out, piece("Block", { b[1], 3, 0.4 }, at(0, 1.5, b[3] / 2 + 0.2), wood, "Tăblie"))
	elseif kind == "shelf" then
		local w, h, d = 4, 6, 1.5
		for _, sx in { -1, 1 } do
			table.insert(out, piece("Block", { 0.3, h, d }, at(sx * (w / 2 - 0.15), h / 2, 0), wood, "Lateral"))
		end
		table.insert(out, piece("Block", { w - 0.6, h, 0.2 }, at(0, h / 2, d / 2 - 0.1), wood, "Spate"))
		for k = 0, 4 do
			local y = 0.2 + (h - 0.4) * k / 4
			table.insert(out, piece("Block", { w - 0.6, 0.25, d - 0.2 }, at(0, y, -0.1), wood, "Raft"))
		end
	elseif kind == "bench" then -- 6 x 3 x 2, seat at 1.5
		table.insert(out, piece("Block", { 6, 0.3, 2 }, at(0, S.SEAT_HEIGHT - 0.15, 0), wood, "Șezut"))
		out[#out].class = "Seat"
		table.insert(out, piece("Block", { 6, 1.5, 0.3 }, at(0, S.SEAT_HEIGHT + 0.75, 0.85), wood, "Spătar"))
		for _, sx in { -1, 1 } do
			table.insert(out, piece("Block", { 0.4, S.SEAT_HEIGHT - 0.3, 1.8 }, at(sx * 2.6, (S.SEAT_HEIGHT - 0.3) / 2, 0), style("#3a3a3a", "Metal"), "Picior"))
		end
	elseif kind == "crate" then
		table.insert(out, piece("Block", { 3, 3, 3 }, at(0, 1.5, 0), wood, "Ladă"))
		for _, sy in { 0.25, 2.75 } do
			table.insert(out, piece("Block", { 3.1, 0.4, 3.1 }, at(0, sy, 0), style("#5c3a1e", "WoodPlanks"), "Șipcă"))
		end
	elseif kind == "barrel" then
		table.insert(out, column(0, 0, 0, 4, 3, wood, "Butoi"))
		for _, y in { 0.6, 3.4 } do
			table.insert(out, column(0, y - 0.15, 0, 0.3, 3.1, style("#3a3a3a", "Metal"), "Cerc"))
		end
	elseif kind == "lamp" then -- street lamp: post 0.5 x 11, light range 24
		local metal = style("#2f2f2f", "Metal")
		table.insert(out, column(0, 0, 0, 0.6, 1.4, metal, "Bază"))
		table.insert(out, column(0, 0, 0, 11, 0.5, metal, "Stâlp"))
		table.insert(out, piece("Block", { 0.4, 0.4, 2 }, at(0, 11, -0.8), metal, "Braț"))
		table.insert(out, piece("Block", { 1.2, 0.6, 1.2 }, at(0, 10.6, -1.6), style("#fff2c8", "Neon", { castShadow = false }), "Lampă"))
		out[#out].light = { range = 24, brightness = 1.5, color = "#ffe6b0" }
	else -- set: a table with chairs around it
		push(out, tablePieces(wood, 6, 3))
		local seats = p.seats
		-- { x, z, side }: side = the direction the chair's back points to (away from the table)
		local places = {
			{ 0, -2.6, "-z" }, { 0, 2.6, "+z" }, { -4.1, 0, "-x" }, { 4.1, 0, "+x" },
			{ -1.6, -2.6, "-z" }, { 1.6, 2.6, "+z" }, { 1.6, -2.6, "-z" }, { -1.6, 2.6, "+z" },
		}
		if seats >= 6 then -- two per long side + the ends
			places = { { -1.6, -2.6, "-z" }, { 1.6, -2.6, "-z" }, { -1.6, 2.6, "+z" }, { 1.6, 2.6, "+z" }, { -4.1, 0, "-x" }, { 4.1, 0, "+x" },
				{ 0, -2.6, "-z" }, { 0, 2.6, "+z" } }
			if seats >= 7 then
				places[1], places[2], places[7] = { -2.2, -2.6, "-z" }, { 2.2, -2.6, "-z" }, { 0, -2.6, "-z" }
			end
			if seats >= 8 then
				places[3], places[4], places[8] = { -2.2, 2.6, "+z" }, { 2.2, 2.6, "+z" }, { 0, 2.6, "+z" }
			end
		end
		-- the chair's back is at its local +Z; Ry(a) * (0, 0, 1) = (sin a, 0, cos a)
		local YAW = { ["+z"] = 0, ["-z"] = pi, ["+x"] = pi / 2, ["-x"] = -pi / 2 }
		for i = 1, min(seats, #places) do
			local pl = places[i]
			push(out, moved(chairPieces(wood, wood), { p = { pl[1], 0, pl[2] }, r = M.ry(YAW[pl[3]]) }))
		end
	end
	return { pieces = out, info = {} }
end

-- ---------------------------------------------------------------------------------------------
-- terrain (Terrain:FillBall / FillBlock / FillWedge; material "Air" carves)
-- ---------------------------------------------------------------------------------------------
local function terrain(p, rng)
	local ops = {}
	local R = p.radius
	local mat = p.material
	if p.kind == "clear" then
		table.insert(ops, { op = "block", cf = at(0, R / 2, 0), size = { 2 * R, R, 2 * R }, material = "Air" })
		return { pieces = {}, terrain = ops, info = {} }
	elseif p.kind == "ramp" then
		-- a slope R wide and 2R long rising toward +Z (like a WedgePart) to R * flatten, on a 4-stud base
		local h = R * p.flatten
		table.insert(ops, { op = "wedge", cf = at(0, h / 2, 0), size = { R, h, 2 * R }, material = mat })
		table.insert(ops, { op = "block", cf = at(0, -2, 0), size = { R, 4, 2 * R }, material = mat })
		return { pieces = {}, terrain = ops, info = {} }
	end
	if p.kind == "hill" then
		local layers = 5
		for k = 0, layers - 1 do
			local t = k / layers
			local r = R * (1 - t * 0.75)
			table.insert(ops, { op = "ball", center = { 0, -r * 0.55 + R * p.flatten * t * 1.1, 0 }, radius = r, material = mat })
		end
	else -- blob / cave: a big ball and satellites
		table.insert(ops, { op = "ball", center = { 0, R * 0.35, 0 }, radius = R, material = mat })
		for _ = 1, p.lumps do
			local a = rng.range(0, 2 * pi)
			local d = R * rng.range(0.5, 0.85)
			local r = R * rng.range(0.4, 0.65)
			table.insert(ops, { op = "ball", center = { cos(a) * d, R * rng.range(0, 0.5), sin(a) * d }, radius = r, material = mat })
		end
		if p.kind == "cave" then
			-- a winding tunnel through the blob, entrance at -Z
			local pos = { 0, 2.5, -R * 1.4 }
			local heading = 0
			local steps = max(4, floor(R * 2.4 / 3))
			for _ = 1, steps do
				table.insert(ops, { op = "ball", center = V.copy(pos), radius = p.tunnel, material = "Air" })
				heading += rng.range(-0.35, 0.35)
				pos = V.add(pos, { sin(heading) * 3, rng.range(-0.3, 0.4), cos(heading) * 3 })
				pos[2] = max(p.tunnel * 0.6, pos[2])
			end
			table.insert(ops, { op = "ball", center = V.copy(pos), radius = p.tunnel * 1.8, material = "Air" })
		end
	end
	return { pieces = {}, terrain = ops, info = { ops = #ops } }
end

-- ---------------------------------------------------------------------------------------------
-- registry + parameter schemas
-- ---------------------------------------------------------------------------------------------
local function num(key, label, default, lo, hi)
	return { key = key, label = label, kind = "number", default = default, min = lo, max = hi }
end
local function int(key, label, default, lo, hi)
	return { key = key, label = label, kind = "int", default = default, min = lo, max = hi }
end
local function bool(key, label, default)
	return { key = key, label = label, kind = "bool", default = default }
end
local function choice(key, label, default, options)
	return { key = key, label = label, kind = "choice", default = default, options = options }
end
local function color(key, label, default)
	return { key = key, label = label, kind = "color", default = default }
end
local function material(key, label, default)
	return { key = key, label = label, kind = "material", default = default }
end
local SEED = int("seed", "Seed (variație)", 1, 0, 2147483646)

Generators.LIST = {
	{ key = "building", label = "Clădire", build = building, params = {
		num("width", "Lățime (X)", 24, 8, 400), num("depth", "Adâncime (Z)", 20, 8, 400),
		int("floors", "Etaje", 2, 1, 40), num("floorHeight", "Înălțime etaj", S.FLOOR_HEIGHT, 8, 30),
		num("wall", "Grosime perete", S.WALL_THICKNESS, 0.2, 4), num("slab", "Grosime planșeu", 1, 0.2, 3),
		bool("windows", "Ferestre", true), num("windowWidth", "Lățime fereastră", S.WINDOW_WIDTH, 1, 20),
		num("windowHeight", "Înălțime fereastră", S.WINDOW_HEIGHT, 1, 20), num("sill", "Înălțime parapet fereastră", S.WINDOW_SILL, 0, 10),
		num("windowSpacing", "Distanță între ferestre", 8, 2, 60), choice("frames", "Rame la ferestre", "sill", { "none", "sill", "full" }),
		bool("door", "Ușă (față)", true), num("doorWidth", "Lățime ușă", S.DOOR_WIDTH, S.DOOR_MIN[1], 20),
		num("doorHeight", "Înălțime ușă", S.DOOR_HEIGHT, S.DOOR_MIN[2], 20),
		bool("slabs", "Planșee interioare", true),
		choice("roof", "Acoperiș", "gable", { "flat", "gable", "hip" }), num("roofPitch", "Pantă acoperiș (grade)", 30, 5, 60),
		num("overhang", "Streașină", 2, 0, 6),
		color("wallColor", "Culoare pereți", "#b8735a"), material("wallMaterial", "Material pereți", "Brick"),
		color("trimColor", "Culoare rame", "#f2efe6"), color("glassColor", "Culoare geam", "#9fd3ff"),
		color("doorColor", "Culoare ușă", "#6b4226"), color("floorColor", "Culoare podea", "#8a6f53"),
		color("roofColor", "Culoare acoperiș", "#5a3a2e"), material("roofMaterial", "Material acoperiș", "Slate"),
	} },
	{ key = "stairs", label = "Scări", build = stairs, params = {
		choice("kind", "Tip", "straight", { "straight", "L", "spiral" }), num("height", "Înălțime totală", 12, 1, 200),
		num("width", "Lățime", S.PATH_WIDTH, 1, 40), num("rise", "Înălțime treaptă", S.STEP_RISE, 0.2, 2), num("run", "Adâncime treaptă", S.STEP_RUN, 0.5, 4),
		choice("style", "Stil", "solid", { "solid", "floating" }), choice("turn", "Întoarcere (L / spirală)", "right", { "right", "left" }),
		bool("railings", "Balustradă", true), num("railHeight", "Înălțime balustradă", S.RAILING_HEIGHT, 1, 6),
		num("radius", "Rază (spirală)", 6, 2, 40), num("column", "Rază coloană (spirală)", 1, 0.2, 10), int("stepsPerTurn", "Trepte pe tură (spirală)", 16, 6, 64),
		color("color", "Culoare", "#9c8b7a"), material("material", "Material", "Concrete"), color("railColor", "Culoare balustradă", "#3a3a3a"),
	} },
	{ key = "fence", label = "Gard / balustradă", build = fence, params = {
		{ key = "points", label = "Traseu (puncte)", kind = "points", default = { { -12, 0, 0 }, { 12, 0, 0 } } },
		bool("smooth", "Traseu curb (spline)", false),
		num("height", "Înălțime (>= 8 ca să oprească jucătorii)", 4, 0.5, 30), num("postSpacing", "Distanță între stâlpi", 6, 1, 40),
		num("postSize", "Grosime stâlp", 0.5, 0.1, 4), int("rails", "Bare orizontale", 2, 1, 6),
		choice("style", "Stil", "wood", { "wood", "metal", "picket" }),
		choice("collision", "Coliziune", "box", { "box", "parts" }),
		color("color", "Culoare", "#8b5a2b"), material("material", "Material", "Wood"),
	} },
	{ key = "bridge", label = "Pod", build = bridge, params = {
		choice("kind", "Tip", "beam", { "beam", "arch", "suspension" }), num("length", "Lungime (Z)", 40, 8, 1000),
		num("width", "Lățime", 12, 2, 100), num("height", "Înălțimea tablierului", 6, 1, 200), num("deck", "Grosime tablier", 1.5, 0.2, 5),
		bool("railings", "Balustradă", true), num("pierSpacing", "Distanță între piloni (grindă)", 24, 5, 200),
		int("segments", "Segmente (arc / cablu)", 12, 4, 48), num("towerHeight", "Înălțime turnuri (suspendat)", 16, 4, 200),
		color("color", "Culoare", "#8e8e8e"), material("material", "Material", "Concrete"), color("cableColor", "Culoare cabluri", "#2f2f2f"),
	} },
	{ key = "tower", label = "Turn", build = tower, params = {
		choice("shape", "Formă", "round", { "round", "square" }), num("radius", "Rază / jumătate de lățime", 8, 3, 100),
		num("height", "Înălțime", 48, 6, 500), num("wall", "Grosime zid", 2, 0.3, 6), int("segments", "Segmente (rotund)", 16, 6, 64),
		bool("crenellations", "Creneluri", true), bool("door", "Intrare", true), int("floors", "Planșee interioare", 3, 0, 30),
		choice("roof", "Acoperiș", "flat", { "flat", "pyramid" }),
		color("color", "Culoare", "#8f8a80"), material("material", "Material", "Cobblestone"), color("floorColor", "Culoare podea", "#7a5c3e"),
		color("roofColor", "Culoare acoperiș", "#4b3b6b"),
	} },
	{ key = "arch", label = "Arc", build = arch, params = {
		num("span", "Deschidere", 10, 2, 200), num("height", "Înălțimea stâlpilor", 8, 0, 200), num("thickness", "Grosime arc", 2, 0.3, 20),
		num("depth", "Adâncime", 2, 0.3, 40), num("pillarWidth", "Lățime stâlp", 2, 0.3, 20), int("segments", "Bolțari", 9, 3, 48),
		color("color", "Culoare", "#c9c0b0"), material("material", "Material", "Limestone"),
	} },
	{ key = "colonnade", label = "Colonadă", build = colonnade, params = {
		int("count", "Coloane", 6, 2, 100), num("spacing", "Distanță între coloane", 8, 2, 60), num("height", "Înălțime", 10, 2, 100),
		num("diameter", "Diametru coloană", 1.6, 0.3, 10), bool("base", "Bază", true), bool("capital", "Capitel", true),
		bool("entablature", "Antablament", true), bool("arches", "Arce între coloane", false),
		color("color", "Culoare", "#e6e0d2"), material("material", "Material", "Marble"),
	} },
	{ key = "wall", label = "Zid cu poartă", build = gateWall, params = {
		num("length", "Lungime", 40, 10, 1000), num("height", "Înălțime", 12, 3, 200), num("thickness", "Grosime", 3, 0.5, 20),
		num("gateWidth", "Lățime poartă", 8, 2, 100), num("gateHeight", "Înălțime poartă", 10, 2, 100),
		bool("crenellations", "Creneluri", true), bool("towers", "Turnuri la capete", true), bool("doors", "Porți", true),
		color("color", "Culoare", "#8f8a80"), material("material", "Material", "Cobblestone"), color("doorColor", "Culoare porți", "#5c3a1e"),
	} },
	{ key = "road", label = "Drum", build = road, params = {
		choice("kind", "Tip", "straight", { "straight", "cross", "T" }), num("length", "Lungime", 40, 8, 2000),
		num("width", "Lățime carosabil", S.ROAD_WIDTH, 6, 200), num("sidewalk", "Lățime trotuar", S.SIDEWALK, 0, 40),
		num("curb", "Înălțime bordură", S.CURB, 0, 3), bool("lines", "Marcaje", true), num("dash", "Lungime linie", 6, 0.5, 40),
		num("gap", "Pauză între linii", 6, 0.5, 40), bool("crosswalks", "Treceri de pietoni", true),
		color("color", "Culoare asfalt", "#3b3b3e"), color("sidewalkColor", "Culoare trotuar", "#a3a29d"),
	} },
	{ key = "tree", label = "Copac low-poly", build = tree, params = {
		choice("kind", "Tip", "pine", { "pine", "round", "palm" }), num("height", "Înălțime", 14, 3, 200),
		num("trunk", "Grosime trunchi", 1, 0.2, 10), int("crown", "Etaje / bucăți coroană / frunze", 3, 1, 12), SEED,
		color("leafColor", "Culoare frunze", "#4f8f3a"), color("trunkColor", "Culoare trunchi", "#6b4a2f"),
	} },
	{ key = "rock", label = "Rocă low-poly", build = rock, params = {
		num("size", "Mărime", 4, 0.5, 200), int("detail", "Detaliu", 0, 0, 3), num("flatten", "Turtire (Y)", 0.7, 0.2, 1.5),
		choice("style", "Stil", "hull", { "hull", "blocks" }), SEED,
		color("color", "Culoare", "#7d7a75"), material("material", "Material", "Slate"),
	} },
	{ key = "crystals", label = "Cristale", build = crystals, params = {
		int("count", "Număr", 5, 1, 30), num("height", "Înălțime", 6, 0.5, 100), num("width", "Grosime", 1.2, 0.1, 20),
		num("spread", "Înclinare maximă (grade)", 30, 0, 80), bool("base", "Rocă la bază", true), SEED,
		color("color", "Culoare", "#7fd4ff"), material("material", "Material", "Glass"),
	} },
	{ key = "furniture", label = "Mobilier", build = furniture, params = {
		choice("kind", "Tip", "set", { "set", "table", "chair", "bed", "shelf", "bench", "crate", "barrel", "lamp" }),
		int("seats", "Scaune (set)", 4, 1, 8),
		color("color", "Culoare lemn", "#8b5a2b"), color("fabricColor", "Culoare textil", "#3f6fb5"),
	} },
	{ key = "terrain", label = "Teren (deal / peșteră)", build = terrain, terrainOnly = true, params = {
		choice("kind", "Tip", "blob", { "blob", "hill", "cave", "ramp", "clear" }), num("radius", "Rază", 16, 4, 400),
		int("lumps", "Umflături", 4, 0, 20), num("flatten", "Înălțime relativă (deal)", 0.6, 0.1, 2), num("tunnel", "Rază tunel (peșteră)", 5, 2, 50), SEED,
		material("material", "Material", "Rock"),
	} },
}
Generators.BY_KEY = {}
for _, g in Generators.LIST do
	Generators.BY_KEY[g.key] = g
end

-- params -> validated copy with defaults, or nil + list of errors (Romanian). Unknown keys are errors (a typo must not
-- be silently ignored). isMaterial(name, forTerrain) -> bool checks material names (init.luau passes Enum.Material;
-- forTerrain = the generator writes smooth terrain, where Air and Water are allowed).
function Generators.normalize(kind, params, isMaterial)
	local gen = Generators.BY_KEY[kind]
	if not gen then
		local keys = {}
		for _, g in Generators.LIST do
			table.insert(keys, g.key)
		end
		return nil, { "Generator necunoscut „" .. tostring(kind) .. "”. Există: " .. table.concat(keys, ", ") .. "." }
	end
	params = params or {}
	if type(params) ~= "table" then
		return nil, { "Parametrii trebuie să fie un tabel." }
	end
	local out, errors = {}, {}
	local known = {}
	for _, f in gen.params do
		known[f.key] = true
		local v = params[f.key]
		local where = kind .. "." .. f.key
		if v == nil then
			v = type(f.default) == "table" and table.clone(f.default) or f.default
		elseif f.kind == "number" or f.kind == "int" then
			if type(v) ~= "number" or v ~= v then
				table.insert(errors, where .. ": trebuie să fie un număr.")
				v = f.default
			elseif f.kind == "int" and v % 1 ~= 0 then
				table.insert(errors, where .. ": trebuie să fie un număr întreg.")
				v = f.default
			elseif v < f.min or v > f.max then
				table.insert(errors, string.format("%s: trebuie să fie între %s și %s (primit %s).", where, tostring(f.min), tostring(f.max), tostring(v)))
				v = f.default
			end
		elseif f.kind == "bool" then
			if type(v) ~= "boolean" then
				table.insert(errors, where .. ": trebuie să fie true sau false.")
				v = f.default
			end
		elseif f.kind == "choice" then
			if not table.find(f.options, v) then
				table.insert(errors, where .. ": trebuie să fie una dintre " .. table.concat(f.options, ", ") .. ".")
				v = f.default
			end
		elseif f.kind == "color" then
			if type(v) ~= "string" or not string.match(v, "^#?%x%x%x%x%x%x$") then
				table.insert(errors, where .. ": culoarea trebuie să fie „#rrggbb”.")
				v = f.default
			elseif string.sub(v, 1, 1) ~= "#" then
				v = "#" .. v
			end
		elseif f.kind == "material" then
			if type(v) ~= "string" or (isMaterial and not isMaterial(v, gen.terrainOnly == true)) then
				table.insert(errors, where .. ": material necunoscut „" .. tostring(v) .. "” (un nume din Enum.Material).")
				v = f.default
			end
		elseif f.kind == "points" then
			local pts = {}
			if type(v) == "table" then
				for i, q in v do
					local vec = V.from(q)
					if not vec then
						table.insert(errors, where .. "[" .. tostring(i) .. "]: un punct este { x, y, z }.")
					else
						table.insert(pts, vec)
					end
				end
			end
			if #pts < 2 then
				table.insert(errors, where .. ": e nevoie de cel puțin 2 puncte.")
				pts = table.clone(f.default)
			end
			v = pts
		end
		out[f.key] = v
	end
	for k in params do
		if not known[k] then
			local list = {}
			for _, f in gen.params do
				table.insert(list, f.key)
			end
			table.insert(errors, kind .. ": parametru necunoscut „" .. tostring(k) .. "” (există: " .. table.concat(list, ", ") .. ").")
		end
	end
	-- cross-field checks
	if kind == "building" then
		if out.windowWidth + 2 > out.width and out.windows then
			table.insert(errors, "building: ferestrele sunt mai late decât clădirea.")
		end
		if out.door and (out.doorWidth > out.width - 2 or out.doorHeight + out.slab > out.floorHeight * out.floors) then
			table.insert(errors, "building: ușa nu încape în perete.")
		end
	elseif kind == "wall" then
		if out.gateWidth > out.length - (out.towers and 14 or 2) then
			table.insert(errors, "wall: poarta e mai lată decât zidul.")
		end
	elseif kind == "tower" then
		if out.wall * 2 >= out.radius then
			table.insert(errors, "tower: zidul e prea gros pentru raza dată.")
		end
	elseif kind == "stairs" and out.kind == "spiral" and out.column >= out.radius - 0.5 then
		table.insert(errors, "stairs: coloana e mai groasă decât scara.")
	end
	if #errors > 0 then
		return nil, errors
	end
	return out
end

-- kind + params -> { pieces, terrain?, info, params } or nil + error text
function Generators.generate(kind, params, isMaterial)
	local values, errors = Generators.normalize(kind, params, isMaterial)
	if not values then
		return nil, table.concat(errors, "\n")
	end
	local gen = Generators.BY_KEY[kind]
	local rng = Geometry.rng(values.seed or 1)
	local result = gen.build(values, rng)
	result.terrain = result.terrain or {}
	result.params = values
	result.kind = kind
	return result
end

return Generators
