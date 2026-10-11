-- Modeling on a typed Roblox mock (tests/mocks/modeling_env.luau): every operation is ONE undo step and changes nothing
-- in the place outside it; fills give the right WedgeParts (their corners reproduce the triangle), arrays / mirror /
-- align / drop / extend move real instances correctly, scatter is deterministic with a seed and keeps its spacing,
-- CSG and EditableMesh failures are reported and rolled back, generators build models with their recipe, and
-- buildFromSpec(describe(model)) rebuilds the same parts.
local LC = ...
local t = LC.kit.new("modeling_build")

local ENV = LC.run("tests/mocks/modeling_env.luau", nil, LC)
local tree = LC.modtree.new({ env = ENV })
local Modeling = tree.load("Modeling")
local G = Modeling.Geometry
local V, M, F = G.V, G.M, G.F
local Vector3, CFrame, Color3, Enum, Instance = ENV.Vector3, ENV.CFrame, ENV.Color3, ENV.Enum, ENV.Instance
local workspace = ENV.workspace
local history = ENV.__history
local Selection = ENV.__services.Selection

local function v(x, y, z)
	return Vector3.new(x, y, z)
end
local function vec(p)
	return { p.X, p.Y, p.Z }
end
local function vnear(a, b, eps)
	return V.dist(a, b) <= (eps or 1e-6)
end
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
local function frameOf(part)
	return Modeling.fromCFrame(part.CFrame)
end
local function cornersOf(part)
	return G.shapeCorners(Modeling.shapeOf(part) or "Block", frameOf(part), vec(part.Size))
end
local function partsIn(root)
	local out = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(out, d)
		end
	end
	return out
end

-- one undo step: exactly one recording, committed, and no change to the place outside it
local function oneStep(label, fn, ...)
	local n0, out0 = #history.log, history.outside
	local results = table.pack(pcall(fn, ...))
	if not results[1] then
		t.fail(label .. ": crashed: " .. tostring(results[2]))
		return
	end
	local added = {}
	for i = n0 + 1, #history.log do
		table.insert(added, history.log[i])
	end
	t.check(#added == 2 and string.find(added[1], "^begin LostCube: ") ~= nil and added[2] == "finish Commit",
		label .. ": one committed undo step (got " .. table.concat(added, " | ") .. ")")
	t.eq(label .. ": nothing changed outside the recording", history.outside - out0, 0)
	if history.outside - out0 > 0 then
		print("  outside: " .. table.concat(history.outsideWhat, ", ", out0 + 1))
	end
	return table.unpack(results, 2, results.n)
end
-- a rejected call: an error with `needle`, and no recording at all (or a cancelled one) and nothing changed
local function rejected(label, needle, fn, ...)
	local n0, out0 = #history.log, history.outside
	local ok, err = pcall(fn, ...)
	t.check(not ok, label .. ": raises an error")
	if needle then
		t.has(label .. ": message", tostring(err), needle)
	end
	local added = {}
	for i = n0 + 1, #history.log do
		table.insert(added, history.log[i])
	end
	t.check(#added == 0 or (#added == 2 and added[2] == "finish Cancel"), label .. ": nothing committed (" .. table.concat(added, " | ") .. ")")
	t.eq(label .. ": nothing changed", history.outside - out0, 0)
end

local baseplate = ENV.part("Part", v(512, 1, 512), CFrame.new(0, -0.5, 0))
baseplate.Name = "Baseplate"

-- 1. fills -------------------------------------------------------------------------------------------------------------
t.section("triangleFill", function()
	local a, b, c = v(0, 5, 0), v(8, 9, -3), v(2, 14, 6)
	local wedges = oneStep("triangleFill", Modeling.triangleFill, a, b, c, { thickness = 0.4, color = "#ff0000", material = "Wood" })
	t.check(wedges and #wedges >= 1 and #wedges <= 2, "1-2 wedges")
	local corners = {}
	local area = 0
	for _, w in wedges do
		t.eq("class", w.ClassName, "WedgePart")
		t.eq("parent", w.Parent, workspace)
		t.eq("anchored", w.Anchored, true)
		t.eq("smooth top", w.TopSurface, Enum.SurfaceType.Smooth)
		t.eq("colour", w.Color, Color3.fromHex("#ff0000"))
		t.eq("material", w.Material, Enum.Material.Wood)
		t.near("thickness", w.Size.X, 0.4, 1e-9)
		local tri = G.wedgeTriangle(frameOf(w), vec(w.Size))
		area += G.triangleArea(tri[1], tri[2], tri[3])
		for _, p in tri do
			table.insert(corners, p)
		end
	end
	for _, p in { a, b, c } do
		local found = false
		for _, q in corners do
			found = found or vnear(q, vec(p), 1e-3)
		end
		t.check(found, "the wedges reproduce triangle vertex " .. tostring(p) .. " within 1e-3")
	end
	t.near("same area", area, G.triangleArea(vec(a), vec(b), vec(c)), 1e-6)
	-- the look of a source part
	local src = ENV.part("Part", v(2, 2, 2), CFrame.new(30, 1, 30))
	src.Color = Color3.fromRGB(10, 200, 30)
	src.Material = Enum.Material.Slate
	local copied = oneStep("triangleFill with source", Modeling.triangleFill, { 30, 2, 30 }, { 34, 2, 30 }, { 30, 2, 26 }, { source = src })
	t.eq("right triangle -> one wedge", #copied, 1)
	t.eq("look copied", copied[1].Color, src.Color)
	t.eq("material copied", copied[1].Material, Enum.Material.Slate)
	rejected("degenerate", "degenerat", Modeling.triangleFill, v(0, 0, 0), v(1, 1, 1), v(2, 2, 2))
	rejected("not a vector", "Vector3", Modeling.triangleFill, "a", v(1, 1, 1), v(2, 2, 2))
	rejected("bad colour", "Culoarea", Modeling.triangleFill, v(0, 0, 0), v(1, 0, 0), v(0, 1, 0), { color = "red" })
	rejected("bad material", "Material", Modeling.triangleFill, v(0, 0, 0), v(1, 0, 0), v(0, 1, 0), { material = "Cheese" })
	for _, w in wedges do
		w:Destroy()
	end
	copied[1]:Destroy()
	src:Destroy()
end)

t.section("polygonFill and gapFill", function()
	local L = { v(0, 1, 0), v(4, 1, 0), v(4, 1, -2), v(2, 1, -2), v(2, 1, -4), v(0, 1, -4) }
	local parts = oneStep("polygonFill", Modeling.polygonFill, L, { thickness = 0.5 })
	local area = 0
	for _, p in parts do
		local tri = G.wedgeTriangle(frameOf(p), vec(p.Size))
		area += G.triangleArea(tri[1], tri[2], tri[3])
		p:Destroy()
	end
	t.near("L polygon area", area, 12, 1e-6)
	rejected("polygon: 2 points", "3 puncte", Modeling.polygonFill, { v(0, 0, 0), v(1, 0, 0) })
	-- two parts 4 studs apart: the gap between their facing edges becomes one block
	local A = ENV.part("Part", v(2, 1, 10), CFrame.new(0, 0.5, 40))
	local B = ENV.part("Part", v(2, 1, 10), CFrame.new(6, 0.5, 40))
	local fill = oneStep("gapFill between parts", Modeling.gapFill, A, B, { thickness = 1 })
	t.eq("one block", #fill, 1)
	if fill[1] then
		local s = fill[1].Size
		local dims = { s.X, s.Y, s.Z }
		table.sort(dims)
		t.check(math.abs(dims[2] - 4) < 1e-6 and math.abs(dims[3] - 10) < 1e-6, "block spans the 4 x 10 gap (" .. tostring(s) .. ")")
		t.check(math.abs(fill[1].Position.X - 3) < 1e-6, "centred in the gap")
		t.eq("the fill copies the first part's look", fill[1].Material, A.Material)
		fill[1]:Destroy()
	end
	local edges = Modeling.partEdges(A)
	t.eq("12 edges", #edges, 12)
	local manual = oneStep("gapFill edges", Modeling.gapFill, { v(0, 0, 0), v(0, 0, -8) }, { v(5, 2, 0), v(5, 0, -8) })
	t.check(#manual >= 2, "non-parallel edges -> wedges")
	for _, p in manual do
		p:Destroy()
	end
	rejected("gapFill: same edge", "coincid", Modeling.gapFill, { v(0, 0, 0), v(1, 0, 0) }, { v(0, 0, 0), v(1, 0, 0) })
	A:Destroy()
	B:Destroy()
end)

-- 2. arrays ------------------------------------------------------------------------------------------------------------
t.section("arrays", function()
	local post = ENV.part("Part", v(1, 4, 1), CFrame.new(0, 2, -60))
	post.Name = "Stâlp"
	local copies = oneStep("linearArray", Modeling.linearArray, post, { offset = v(5, 0, 0), count = 4 })
	t.eq("3 copies", #copies, 3)
	for k, cpy in copies do
		t.check(vnear(vec(cpy.Position), { 5 * k, 2, -60 }), "copy " .. k .. " at 5k")
		t.eq("name kept", cpy.Name, "Stâlp")
		t.eq("same parent", cpy.Parent, workspace)
		cpy:Destroy()
	end
	-- the selection is used when no targets are given
	Selection:Set({ post })
	local fromSel = oneStep("linearArray on the selection", Modeling.linearArray, nil, { offset = v(0, 0, 3), count = 2 })
	t.eq("selection: 1 copy", #fromSel, 1)
	fromSel[1]:Destroy()
	Selection:Set({})
	rejected("empty selection", "Selectează", Modeling.linearArray, nil, { offset = v(1, 0, 0), count = 2 })
	rejected("count 1", "între 2 și 1000", Modeling.linearArray, post, { offset = v(1, 0, 0), count = 1 })
	-- a model is copied as a whole
	local model = Instance.new("Model")
	model.Name = "Bancă"
	local p1 = ENV.part("Part", v(4, 1, 2), CFrame.new(20, 0.5, -60), model)
	ENV.part("Part", v(4, 2, 0.4), CFrame.new(20, 1.5, -59), model)
	model.PrimaryPart = p1
	model.Parent = workspace
	local mc = oneStep("linearArray of a model", Modeling.linearArray, model, { offset = v(0, 0, 4), count = 3 })
	t.eq("2 model copies", #mc, 2)
	t.eq("copies are models", mc[1].ClassName, "Model")
	t.check(vnear(vec(mc[2]:GetPivot().Position), { 20, 0.5, -52 }), "model copy moved by its pivot")
	t.eq("primary part remapped to the copy", mc[1].PrimaryPart.Parent, mc[1])
	for _, m in mc do
		m:Destroy()
	end
	-- radial: 8 columns around a centre
	local col = ENV.part("Part", v(1, 6, 1), CFrame.new(50, 3, -10))
	local ring = oneStep("radialArray", Modeling.radialArray, col, { center = v(50, 0, 0), count = 8 })
	t.eq("7 copies", #ring, 7)
	for _, c in ring do
		t.near("on the circle", (c.Position - v(50, 3, 0)).Magnitude, 10, 1e-6)
		c:Destroy()
	end
	-- Archimedes arc: segments share their inner edge
	local seg = ENV.part("Part", v(10, 4, 2), CFrame.new(0, 2, -100))
	local arc = oneStep("arcArray", Modeling.arcArray, seg, { axis = "Y", angle = 30, count = 4 })
	t.eq("3 arc copies", #arc, 3)
	local prev = seg
	for _, c in arc do
		local lead = prev.CFrame * v(5, 0, -1)
		local trail = c.CFrame * v(-5, 0, -1)
		t.check((lead - trail).Magnitude < 1e-6, "arc: continuous inner edge")
		prev = c
	end
	for _, c in arc do
		c:Destroy()
	end
	-- along a path: copies follow the curve
	local lamp = ENV.part("Part", v(1, 8, 1), CFrame.new(0, 4, -140))
	local onPath = oneStep("pathArray", Modeling.pathArray, lamp, { v(0, 4, -140), v(20, 4, -130), v(40, 4, -140) }, 5)
	t.check(#onPath >= 8, "copies along the path (" .. #onPath .. ")")
	for i = 2, #onPath do
		local d = (onPath[i].Position - onPath[i - 1].Position).Magnitude
		t.check(d > 4 and d < 5.2, "path spacing ~5 (" .. d .. ")")
	end
	for _, c in onPath do
		c:Destroy()
	end
	rejected("pathArray spacing", "pozitiv", Modeling.pathArray, lamp, { v(0, 0, 0), v(1, 0, 0) }, 0)
	for _, x in { post, model, col, seg, lamp } do
		x:Destroy()
	end
end)

-- 3. mirror ------------------------------------------------------------------------------------------------------------
t.section("mirror", function()
	local model = Instance.new("Model")
	model.Name = "Aripă"
	local block = ENV.part("Part", v(4, 2, 1), CFrame.new(6, 1, 3) * CFrame.Angles(0.3, 0.5, 0.1), model)
	block.Name = "Bloc"
	local wedge = ENV.part("WedgePart", v(2, 3, 5), CFrame.new(8, 2, -2) * CFrame.Angles(0, 1.1, 0.4), model)
	local corner = ENV.part("CornerWedgePart", v(3, 2, 4), CFrame.new(10, 1, 1) * CFrame.Angles(0.2, -0.7, 0), model)
	local ball = ENV.part("Part", v(2, 2, 2), CFrame.new(5, 4, 0), model)
	ball.Shape = Enum.PartType.Ball
	ball.Name = "Bilă"
	local att = Instance.new("Attachment")
	att.CFrame = CFrame.new(1.5, 0.5, 0)
	att.Parent = block
	local weld = Instance.new("WeldConstraint")
	weld.Part0, weld.Part1 = block, wedge
	weld.Parent = block
	local mesh = ENV.part("MeshPart", v(1, 1, 1), CFrame.new(7, 3, 0), model)
	model.Parent = workspace
	local before = {}
	for _, p in partsIn(model) do
		before[p.Name .. p.ClassName] = cornersOf(p)
	end
	local attWorld = vec((block.CFrame * att.CFrame).Position)
	local out, warnings = oneStep("mirror", Modeling.mirror, model, { point = v(0, 0, 0), normal = v(1, 0, 0) })
	local copy = out[1]
	t.check(copy ~= model and copy.Parent == workspace, "a mirrored copy")
	for _, p in partsIn(copy) do
		local want = {}
		for _, c in before[p.Name .. p.ClassName] do
			table.insert(want, { -c[1], c[2], c[3] })
		end
		if p.ClassName ~= "MeshPart" then
			t.check(sameSet(cornersOf(p), want, 1e-6), p.ClassName .. ": a true mirror image")
		end
		local r = frameOf(p).r
		t.near(p.ClassName .. ": det +1", M.det(r), 1, 1e-9)
	end
	local cBlock = copy:FindFirstChild("Bloc")
	local cAtt = cBlock and cBlock:FindFirstChildOfClass("Attachment")
	t.check(cAtt ~= nil and vnear(vec((cBlock.CFrame * cAtt.CFrame).Position), { -attWorld[1], attWorld[2], attWorld[3] }, 1e-6), "attachment mirrored")
	local cWeld = cBlock:FindFirstChildOfClass("WeldConstraint")
	t.check(cWeld and cWeld.Enabled and cWeld.Part1 and cWeld.Part1:IsDescendantOf(copy), "weld re-enabled and pointing inside the copy")
	t.check(#warnings == 1 and string.find(warnings[1], "MeshPart") ~= nil, "the MeshPart is reported as approximate")
	t.check(sameSet(cornersOf(block), before[block.Name .. block.ClassName], 1e-9), "the original is untouched")
	copy:Destroy()
	-- in place, across the group's own centre
	local single = ENV.part("WedgePart", v(2, 2, 4), CFrame.new(0, 1, -200))
	local c0 = cornersOf(single)
	oneStep("mirror in place", Modeling.mirror, single, "Z", { copy = false })
	local want = {}
	for _, c in c0 do
		table.insert(want, { c[1], c[2], -400 - c[3] })
	end
	t.check(sameSet(cornersOf(single), want, 1e-6), "mirrored in place across its own centre")
	rejected("bad plane", "Planul", Modeling.mirror, single, "W")
	single:Destroy()
	model:Destroy()
end)

-- 4. align, distribute, snap, drop, extend ------------------------------------------------------------------------------
t.section("align, distribute, snap", function()
	local a = ENV.part("Part", v(2, 2, 2), CFrame.new(0, 3, 80))
	local b = ENV.part("Part", v(2, 4, 2), CFrame.new(5, 7, 80))
	local c = ENV.part("Part", v(2, 1, 2), CFrame.new(20, 1, 80))
	oneStep("align Y min", Modeling.align, { a, b, c }, "Y", "min")
	t.near("a bottom", a.Position.Y - 1, 0.5, 1e-9)
	t.near("b bottom", b.Position.Y - 2, 0.5, 1e-9)
	oneStep("align X max to a value", Modeling.align, { a, b }, "X", "max", 10)
	t.near("a right side at 10", a.Position.X + 1, 10, 1e-9)
	oneStep("align to the first", Modeling.align, { c, a }, "Z", "center", "first")
	oneStep("distribute X", Modeling.distribute, { a, b, c }, "X")
	rejected("distribute 2", "cel puțin 3", Modeling.distribute, { a, b }, "X")
	rejected("align bad axis", "Axa", Modeling.align, { a, b }, "W", "min")
	local s = ENV.part("Part", v(1, 1, 1), CFrame.new(1.3, 2.6, -0.4) * CFrame.fromOrientation(0, math.rad(31), 0))
	oneStep("snapToGrid", Modeling.snapToGrid, s, 1, { rotation = 15 })
	t.check(vnear(vec(s.Position), { 1, 3, 0 }), "snapped position")
	local _, yaw = s.CFrame:ToOrientation()
	t.near("snapped yaw", math.deg(yaw), 30, 1e-9)
	rejected("grid 0", "pozitiv", Modeling.snapToGrid, s, 0)
	for _, x in { a, b, c, s } do
		x:Destroy()
	end
end)

t.section("dropToSurface and extendTo", function()
	local crate = ENV.part("Part", v(3, 3, 3), CFrame.new(100, 20, 100))
	local moved, missed = oneStep("dropToSurface", Modeling.dropToSurface, crate)
	t.eq("moved", #moved, 1)
	t.eq("missed", missed, 0)
	t.near("rests on the baseplate", crate.Position.Y, 1.5, 1e-6)
	-- a slope: the crate turns to the surface normal
	local ramp = ENV.part("Part", v(20, 1, 20), CFrame.new(150, 5, 100) * CFrame.Angles(0, 0, math.rad(20)))
	local box = ENV.part("Part", v(2, 2, 2), CFrame.new(150, 30, 100))
	oneStep("dropToSurface aligned", Modeling.dropToSurface, box, { alignToNormal = true })
	local up = box.CFrame.UpVector
	t.check(vnear(vec(up), vec(ramp.CFrame.UpVector), 1e-6), "aligned to the slope's normal")
	t.check(box.Position.Y < 30, "dropped onto the ramp")
	local nowhere = ENV.part("Part", v(1, 1, 1), CFrame.new(5000, 10, 5000))
	rejected("nothing below", "Nu am găsit", Modeling.dropToSurface, nowhere)
	local _, miss = oneStep("drop with one miss", Modeling.dropToSurface, { crate, nowhere })
	t.eq("one missed", miss, 1)
	-- extend the top of a pillar up to a ceiling
	local pillar = ENV.part("Part", v(2, 4, 2), CFrame.new(-100, 2, 100))
	local ceiling = ENV.part("Part", v(10, 1, 10), CFrame.new(-100, 15.5, 100))
	local _, dist = oneStep("extendTo", Modeling.extendTo, pillar, "Top", ceiling)
	t.near("extended by 11", dist, 11, 1e-9)
	t.near("new height", pillar.Size.Y, 15, 1e-9)
	t.near("bottom kept", pillar.Position.Y - pillar.Size.Y / 2, 0, 1e-9)
	rejected("extendTo bad face", "față", Modeling.extendTo, pillar, "Up", ceiling)
	rejected("extendTo parallel", "paralelă", Modeling.extendTo, pillar, "Right", { point = v(0, 0, 0), normal = v(0, 1, 0) })
	for _, x in { crate, ramp, box, nowhere, pillar, ceiling } do
		x:Destroy()
	end
end)

-- 5. scatter -----------------------------------------------------------------------------------------------------------
t.section("scatter", function()
	local field = ENV.part("Part", v(80, 1, 80), CFrame.new(300, 0.5, 300))
	field.Name = "Câmp"
	local tree1 = Instance.new("Model")
	tree1.Name = "Copac"
	local trunk = ENV.part("Part", v(1, 6, 1), CFrame.new(0, 103, 0), tree1)
	ENV.part("Part", v(4, 4, 4), CFrame.new(0, 107, 0), tree1)
	tree1.PrimaryPart = trunk
	tree1.Parent = workspace
	local rock = ENV.part("Part", v(2, 1, 2), CFrame.new(10, 100.5, 0))
	local function positions(container)
		local out = {}
		for _, m in container:GetChildren() do
			table.insert(out, vec(m:GetPivot().Position))
		end
		return out
	end
	local c1, report = oneStep("scatter", Modeling.scatter, field, { tree1, rock }, { count = 25, minDistance = 6, seed = 7, scaleRange = { 0.8, 1.25 } })
	local c2 = oneStep("scatter again", Modeling.scatter, field, { tree1, rock }, { count = 25, minDistance = 6, seed = 7, scaleRange = { 0.8, 1.25 } })
	local p1, p2 = positions(c1), positions(c2)
	t.check(#p1 >= 15, "most of the 25 placed (" .. #p1 .. ")")
	t.eq("report counts", report.placed, #p1)
	local same = #p1 == #p2
	for i = 1, math.min(#p1, #p2) do
		same = same and vnear(p1[i], p2[i], 1e-9)
	end
	t.check(same, "same seed -> the same layout")
	local minD = math.huge
	for i = 1, #p1 do
		for j = i + 1, #p1 do
			minD = math.min(minD, math.sqrt((p1[i][1] - p1[j][1]) ^ 2 + (p1[i][3] - p1[j][3]) ^ 2))
		end
	end
	t.check(minD >= 6 - 1e-6, "minimum distance kept (" .. minD .. ")")
	for _, m in c1:GetChildren() do
		local lo = math.huge
		for _, part in (m:IsA("Model") and partsIn(m) or { m }) do
			lo = math.min(lo, part.Position.Y - part.Size.Y / 2)
		end
		t.near("sits on the field", lo, 1, 1e-6)
		local x, z = m:GetPivot().X, m:GetPivot().Z
		t.check(math.abs(x - 300) <= 40 and math.abs(z - 300) <= 40, "inside the field")
	end
	local c3 = oneStep("scatter other seed", Modeling.scatter, field, { tree1, rock }, { count = 25, minDistance = 6, seed = 8 })
	t.check(not vnear(positions(c3)[1], p1[1], 1e-6), "another seed, another layout")
	local c4 = oneStep("scatter weights", Modeling.scatter, field, { tree1, rock }, { count = 10, seed = 3, weights = { 0, 1 } })
	local onlyRocks = true
	for _, m in c4:GetChildren() do
		onlyRocks = onlyRocks and m:IsA("BasePart")
	end
	t.check(onlyRocks, "weights: only the second template")
	-- a slope steeper than maxSlope only: nothing valid
	local wall = ENV.part("Part", v(40, 1, 40), CFrame.new(-300, 20, -300) * CFrame.Angles(0, 0, math.rad(20)))
	rejected("too steep", "Nicio poziție", Modeling.scatter, wall, { rock }, { count = 10, maxSlope = 10 })
	rejected("no templates", "șablon", Modeling.scatter, field, {}, { count = 10 })
	for _, x in { c1, c2, c3, c4, field, tree1, rock, wall } do
		x:Destroy()
	end
end)

-- 6. splines and pieces along them -----------------------------------------------------------------------------------
t.section("spline and alongSpline", function()
	local pts = { v(0, 0, 200), v(20, 0, 210), v(40, 0, 200), v(60, 0, 220) }
	local sp = Modeling.spline(pts)
	t.check((sp.at(0) - pts[1]).Magnitude < 1e-9 and (sp.at(1) - pts[4]).Magnitude < 1e-9, "spline ends")
	t.check(sp.length > 60, "spline length")
	local cfs = sp.cframes(10)
	t.check(#cfs >= 6 and ENV.typeof(cfs[1]) == "CFrame", "cframes along the curve")
	local pipe, rep = oneStep("alongSpline pipe", Modeling.alongSpline, "pipe", pts, { spacing = 5 })
	local rods, balls = 0, 0
	for _, p in partsIn(pipe) do
		if p.Shape == Enum.PartType.Cylinder then
			rods += 1
		elseif p.Shape == Enum.PartType.Ball then
			balls += 1
		end
	end
	t.check(rods >= 12 and balls == rods - 1, "pipe: cylinders with a ball at every joint (" .. rods .. "/" .. balls .. ")")
	t.eq("report parts", rep.parts, #partsIn(pipe))
	local road = oneStep("alongSpline road", Modeling.alongSpline, "road", pts, { spacing = 6 })
	local wedges = 0
	for _, p in partsIn(road) do
		if p:IsA("WedgePart") then
			wedges += 1
		end
	end
	t.check(wedges > 0, "road: wedges fill the outside of the turns")
	-- the joint fill sits on the outside of a turn: a left turn at (0, 0, -20) gets it at x > 0, z < -20
	for _, corner in { { { 0, 0, 0 }, { 0, 0, -20 }, { -20, 0, -20 } }, { { 0, 0, 0 }, { 0, 0, -20 }, { 20, 0, -20 } } } do
		local sp2 = G.spline(corner, { tension = 1 })
		local fills = {}
		for _, pc in Modeling.alongPieces(sp2, { kind = "strip", width = 4, thickness = 1, height = 0 }, { spacing = 10 }) do
			if pc.shape == "Wedge" then
				table.insert(fills, pc)
			end
		end
		t.check(#fills >= 1, "a fill at the corner")
		local outward = corner[3][1] < 0 and 1 or -1 -- left turn: outside = +x; right turn: -x
		for _, pc in fills do
			t.check(pc.cf.p[1] * outward > 0 and pc.cf.p[3] < -20, "the fill is on the outside of the turn")
		end
	end
	local fence = oneStep("alongSpline fence", Modeling.alongSpline, "fence", pts, {})
	t.eq("fence is a generated model", fence:GetAttribute("LC_Generator"), "fence")
	local post = ENV.part("Part", v(1, 3, 1), CFrame.new(0, 1.5, 200))
	local copies = oneStep("alongSpline template", Modeling.alongSpline, post, pts, { spacing = 10 })
	t.check(#copies >= 5, "template copies along the curve")
	rejected("alongSpline unknown kind", "Tip necunoscut", Modeling.alongSpline, "river", pts)
	for _, x in { pipe, road, fence, post } do
		x:Destroy()
	end
	for _, c in copies do
		c:Destroy()
	end
end)

-- 7. CSG and hygiene ---------------------------------------------------------------------------------------------------
t.section("merge and subtract", function()
	local parts = {}
	for i = 1, 3 do
		parts[i] = ENV.part("Part", v(2, 2, 2), CFrame.new(i * 2, 1, 400))
	end
	local union = oneStep("merge", Modeling.merge, parts, { name = "Zid" })
	t.eq("a union", union.ClassName, "UnionOperation")
	t.eq("named", union.Name, "Zid")
	t.eq("parented", union.Parent, workspace)
	t.check(parts[1].Parent == nil and parts[3].Parent == nil, "the originals are gone")
	-- many parts: chunks of 150 then the chunks
	local many = {}
	for i = 1, 320 do
		many[i] = ENV.part("Part", v(1, 1, 1), CFrame.new(i, 0.5, 420))
	end
	local calls0 = #ENV.__csg.calls
	local big = oneStep("merge 320", Modeling.merge, many)
	t.eq("4 CSG calls (3 chunks + 1)", #ENV.__csg.calls - calls0, 4)
	local unions = 0
	for _, d in workspace:GetChildren() do
		if d.ClassName == "UnionOperation" then
			unions += 1
		end
	end
	t.eq("only the final unions remain", unions, 2)
	-- a failure is reported and rolled back
	local keep = { ENV.part("Part", v(1, 1, 1), CFrame.new(0, 0.5, 440)), ENV.part("Part", v(1, 1, 1), CFrame.new(1, 0.5, 440)) }
	ENV.__csg.fail = "geometrie invalidă"
	local n0 = #history.log
	local res, err = Modeling.merge(keep)
	ENV.__csg.fail = false
	t.check(res == nil and string.find(err, "UnionAsync") ~= nil, "failure: nil + message")
	t.eq("failure: recording cancelled", history.log[#history.log], "finish Cancel")
	t.eq("failure: one recording", #history.log - n0, 2)
	t.check(keep[1].Parent == workspace, "failure: parts kept")
	local _, few = Modeling.merge({ keep[1] })
	t.has("merge needs 2", few, "cel puțin 2")
	-- subtract
	local base = ENV.part("Part", v(10, 10, 1), CFrame.new(0, 5, 460))
	local hole = ENV.part("Part", v(4, 7, 3), CFrame.new(0, 3.5, 460))
	local cut = oneStep("subtract", Modeling.subtract, base, hole)
	t.eq("subtract: a union", cut.ClassName, "UnionOperation")
	t.check(base.Parent == nil and hole.Parent == nil, "subtract: base and cutter replaced")
	for _, x in { union, big, cut, keep[1], keep[2] } do
		x:Destroy()
	end
end)

t.section("optimize, weldAll, group", function()
	local model = Instance.new("Model")
	model.Name = "Decor"
	local big = ENV.part("Part", v(20, 1, 20), CFrame.new(0, 0.5, 500), model)
	for i = 1, 6 do
		local bolt = ENV.part("Part", v(0.3, 0.3, 0.3), CFrame.new(i, 1.15, 500), model)
		bolt.Anchored = false
	end
	local mesh = ENV.part("MeshPart", v(3, 3, 3), CFrame.new(5, 2.5, 500), model)
	mesh.CanCollide = false
	model.Parent = workspace
	local n0, out0 = #history.log, history.outside
	local dry = Modeling.optimize(model, { dryRun = true })
	t.eq("dry run: no recording", #history.log, n0)
	t.eq("dry run: nothing changed", history.outside, out0)
	t.eq("report: parts", dry.parts, 8)
	t.eq("report: to anchor", dry.anchored, 6)
	t.eq("report: decor collisions", dry.canCollide, 6)
	t.eq("report: shadows", dry.castShadow, 6)
	t.eq("report: mesh fidelity", dry.renderFidelity, 1)
	t.eq("report: box collisions", dry.collisionFidelity, 1)
	local report = oneStep("optimize", Modeling.optimize, model)
	t.eq("changes counted", report.changes, 6 + 12 + 6 + 2)
	local bolt = model:GetChildren()[2]
	t.check(bolt.Anchored and not bolt.CanCollide and not bolt.CanTouch and not bolt.CastShadow, "a bolt is optimised")
	t.eq("mesh fidelity", mesh.RenderFidelity, Enum.RenderFidelity.Performance)
	t.eq("mesh collisions", mesh.CollisionFidelity, Enum.CollisionFidelity.Box)
	t.eq("nothing left to do", Modeling.optimize(model).changes, 0)
	local welds = oneStep("weldAll", Modeling.weldAll, model)
	t.eq("a weld per part", #welds, 7)
	t.eq("welded to the biggest part", welds[1].Part0, big)
	t.eq("no duplicate welds", #oneStep("weldAll again", Modeling.weldAll, model), 0)
	local a = ENV.part("Part", v(1, 1, 1), CFrame.new(0, 0.5, 520))
	local b = ENV.part("Part", v(3, 1, 3), CFrame.new(3, 0.5, 520))
	local g = oneStep("group", Modeling.group, { a, b }, "Grupul meu")
	t.check(a.Parent == g and b.Parent == g and g.Parent == workspace, "grouped")
	t.eq("primary part = the biggest", g.PrimaryPart, b)
	model:Destroy()
	g:Destroy()
end)

-- 8. generators --------------------------------------------------------------------------------------------------------
t.section("generators", function()
	local origin = CFrame.new(100, 0, -300) * CFrame.fromOrientation(0, math.rad(90), 0)
	local model, report = oneStep("generate building", Modeling.generate, "building", { floors = 2, roof = "hip" }, workspace, origin)
	t.eq("a model", model.ClassName, "Model")
	t.eq("parented", model.Parent, workspace)
	t.eq("generator recorded", model:GetAttribute("LC_Generator"), "building")
	t.eq("params recorded", Modeling.Spec.fromJSON(model:GetAttribute("LC_Params")).floors, 2)
	t.eq("report parts = real parts", report.parts, #partsIn(model))
	t.check(model.WorldPivot == origin, "pivot = the origin")
	local _, size = model:GetBoundingBox() -- in the pivot's axes
	t.near("bounding box: 24 + 2 x 2 overhang along the model's X", size.X, 28, 1e-6)
	t.near("bounding box: 20 + 2 x 2 along its Z", size.Z, 24, 1e-6)
	local door
	for _, p in partsIn(model) do
		if p.Name == "Ușă" then
			door = p
		end
	end
	-- yaw +90: the model's front (-Z) faces world -X
	t.check(door and math.abs(door.Position.X - (100 - 9.5)) < 1e-6 and math.abs(door.Position.Z + 300) < 1e-6, "the door is on the front, turned with the model")
	t.check(report.size.Y > 24, "report size")
	local seats = 0
	local furniture = oneStep("generate furniture", Modeling.generate, "furniture", { kind = "set" }, workspace, CFrame.new(0, 0, -340))
	for _, p in partsIn(furniture) do
		if p.ClassName == "Seat" then
			seats += 1
		end
	end
	t.eq("4 real Seats", seats, 4)
	local lamp = oneStep("generate lamp", Modeling.generate, "furniture", { kind = "lamp" }, workspace, CFrame.new(10, 0, -340))
	local light
	for _, d in lamp:GetDescendants() do
		if d.ClassName == "PointLight" then
			light = d
		end
	end
	t.check(light and light.Range == 24, "lamp: a PointLight")
	-- regenerate in place with other parameters
	local fresh = oneStep("regenerate", Modeling.regenerate, model, { floors = 1, roof = "flat" })
	t.check(model.Parent == nil and fresh.Parent == workspace, "old model replaced")
	t.check(fresh.WorldPivot == origin, "same place")
	t.eq("new params", Modeling.Spec.fromJSON(fresh:GetAttribute("LC_Params")).floors, 1)
	t.eq("other params kept", Modeling.Spec.fromJSON(fresh:GetAttribute("LC_Params")).windowSpacing, 8)
	-- terrain only
	local calls0 = #ENV.__terrain.calls
	local none, tr = oneStep("generate cave", Modeling.generate, "terrain", { kind = "cave", radius = 16 }, nil, CFrame.new(0, 0, 600))
	t.eq("terrain: no model", none, nil)
	t.eq("terrain: the fills happened", #ENV.__terrain.calls - calls0, tr.terrainOps)
	local air = 0
	for i = calls0 + 1, #ENV.__terrain.calls do
		if ENV.__terrain.calls[i].material == "Air" then
			air += 1
		end
	end
	t.check(air > 0, "cave carved with Air")
	t.check(ENV.__terrain.calls[calls0 + 1].center.Z > 580, "terrain placed at the origin")
	local c1 = #ENV.__terrain.calls
	oneStep("generate ramp", Modeling.generate, "terrain", { kind = "ramp", radius = 8 }, nil, CFrame.new(40, 0, 600))
	t.eq("ramp: a FillWedge", ENV.__terrain.calls[c1 + 1].op, "wedge")
	t.near("ramp: 8 x 4.8 x 16", ENV.__terrain.calls[c1 + 1].size.Z, 16, 1e-9)
	rejected("generate: typo", "parametru necunoscut", Modeling.generate, "building", { flors = 2 })
	rejected("generate: unknown", "Generator necunoscut", Modeling.generate, "castle", {})
	rejected("generate: bad parent", "parent", Modeling.generate, "tree", {}, "workspace")
	t.has("help", Modeling.generatorHelp("building"), "width")
	t.has("help list", Modeling.generatorHelp(), "stairs")
	for _, x in { fresh, furniture, lamp } do
		x:Destroy()
	end
end)

t.section("every generator builds real instances", function()
	for _, g in Modeling.GENERATORS do
		if g.key ~= "terrain" then
			local model, report = oneStep("generate " .. g.key, Modeling.generate, g.key, {}, workspace, CFrame.new(0, 0, 900))
			if model then
				t.eq(g.key .. ": parts", #partsIn(model), report.parts)
				model:Destroy()
			end
		end
	end
end)

t.section("toTerrain", function()
	local blk = ENV.part("Part", v(8, 4, 8), CFrame.new(0, 2, 700))
	local wdg = ENV.part("WedgePart", v(4, 4, 8), CFrame.new(10, 2, 700))
	local ball = ENV.part("Part", v(6, 6, 6), CFrame.new(20, 3, 700))
	ball.Shape = Enum.PartType.Ball
	ball.Material = Enum.Material.Grass
	local cyl = ENV.part("Part", v(10, 4, 4), CFrame.new(30, 2, 700))
	cyl.Shape = Enum.PartType.Cylinder
	local calls0 = #ENV.__terrain.calls
	t.eq("4 fills", oneStep("toTerrain", Modeling.toTerrain, { blk, wdg, ball, cyl }), 4)
	local ops = {}
	for i = calls0 + 1, #ENV.__terrain.calls do
		ops[ENV.__terrain.calls[i].op] = ENV.__terrain.calls[i]
	end
	t.check(ops.block and ops.wedge and ops.ball and ops.cylinder, "one fill per shape")
	t.eq("ball radius", ops.ball.radius, 3)
	t.eq("ball keeps a terrain material", ops.ball.material, "Grass")
	t.eq("plastic becomes rock", ops.block.material, "Rock")
	t.eq("cylinder height = its length", ops.cylinder.height, 10)
	t.check(vnear(vec(ops.cylinder.cframe.UpVector), { 1, 0, 0 }, 1e-9) or vnear(vec(ops.cylinder.cframe.UpVector), { -1, 0, 0 }, 1e-9), "terrain cylinder axis = the part's X")
	t.check(blk.Parent == nil, "parts removed")
	local leftover = ENV.part("Part", v(1, 1, 1), CFrame.new(0, 0.5, 720))
	rejected("toTerrain bad material", "teren", Modeling.toTerrain, leftover, { material = "Cheese" })
	leftover:Destroy()
end)

-- 9. meshes ------------------------------------------------------------------------------------------------------------
t.section("meshes", function()
	local ok = Modeling.meshAvailable()
	t.check(ok, "EditableMesh available in the mock")
	local part, report = oneStep("mesh lathe", Modeling.mesh, "lathe", { segments = 12 }, workspace, CFrame.new(0, 0, 800), { mode = "mesh" })
	t.eq("a MeshPart", part.ClassName, "MeshPart")
	t.eq("mode", report.mode, "mesh")
	t.eq("recipe saved", part:GetAttribute("LC_Mesh"), "lathe")
	t.check(report.warning ~= nil and string.find(report.warning, "publicat") ~= nil, "persistence warning")
	t.check(part.Position.Y > 0, "placed by its centre above the origin")
	-- the default is the part fallback (it survives saving the place)
	local model, r2 = oneStep("mesh default", Modeling.mesh, "rock", { seed = 2, detail = 1 }, workspace, CFrame.new(20, 0, 800))
	t.eq("default: parts", r2.mode, "parts")
	t.eq("default: a model of wedges", model.ClassName, "Model")
	t.check(#partsIn(model) >= r2.triangles, "about two wedges per triangle")
	-- unavailable: auto falls back, mesh mode reports
	ENV.__mesh.available = false
	local avail, why = Modeling.meshAvailable()
	t.check(not avail and string.find(why, "Allow Mesh") ~= nil, "unavailable: the reason says what to enable")
	local fb, r3 = oneStep("mesh auto fallback", Modeling.mesh, "extrude", { depth = 3 }, workspace, nil, { mode = "auto" })
	t.eq("auto: parts", r3.mode, "parts")
	t.check(r3.fallback ~= nil, "auto: the fallback reason")
	local n0 = #history.log
	local nothing, err = Modeling.mesh("lathe", {}, workspace, nil, { mode = "mesh" })
	t.check(nothing == nil and err ~= nil and #history.log == n0, "mesh mode unavailable: nil + reason, nothing recorded")
	ENV.__mesh.available = true
	ENV.__mesh.meshPartFails = true
	local fb2, r4 = Modeling.mesh("lathe", {}, workspace, nil, { mode = "auto" })
	t.check(fb2 and r4.mode == "parts" and string.find(r4.fallback, "MeshPart") ~= nil, "CreateMeshPartAsync failure -> parts")
	ENV.__mesh.meshPartFails = false
	rejected("mesh: unknown kind", "necunoscut", Modeling.mesh, "donut", {})
	rejected("mesh: bad mode", "auto, mesh sau parts", Modeling.mesh, "rock", {}, nil, nil, { mode = "fast" })
	rejected("mesh: bad colour", "#rrggbb", Modeling.mesh, "rock", { color = "grey" })
	local rebuilt = oneStep("rebuildMesh", Modeling.rebuildMesh, model)
	t.check(model.Parent == nil and rebuilt.Parent == workspace, "rebuilt from the recipe")
	t.check(vnear(vec(rebuilt:GetPivot().Position), vec(CFrame.new(20, 0, 800) * v(0, 0, 0)), 50), "rebuilt in the same place")
	for _, x in { part, rebuilt, fb, fb2 } do
		x:Destroy()
	end
end)

-- 10. spec -------------------------------------------------------------------------------------------------------------
local function signature(root, originCF)
	local inv = originCF:Inverse()
	local out = {}
	for _, p in partsIn(root) do
		local rel = inv * p.CFrame
		local x, y, z = rel:GetComponents()
		table.insert(out, { shape = Modeling.shapeOf(p), pos = { x, y, z }, corners = G.shapeCorners(Modeling.shapeOf(p) or "Block",
			Modeling.fromCFrame(rel), vec(p.Size)), color = p.Color:ToHex(), material = p.Material.Name, class = p.ClassName })
	end
	table.sort(out, function(a, b)
		for i = 1, 3 do
			if math.abs(a.pos[i] - b.pos[i]) > 1e-3 then
				return a.pos[i] < b.pos[i]
			end
		end
		return a.class < b.class
	end)
	return out
end

t.section("buildFromSpec and describe", function()
	local spec = {
		name = "Chioșc",
		parts = {
			{ size = { 12, 1, 12 }, pos = { 0, 0.5, 0 }, color = "#8a6f53", material = "WoodPlanks", name = "Podea" },
			{ shape = "Cylinder", size = { 8, 1, 1 }, pos = { 5, 5, 5 }, rot = { 0, 0, 90 }, name = "Stâlp" },
			{ shape = "Wedge", size = { 12, 3, 6 }, pos = { 0, 10.5, -3 }, color = "#5a3a2e", material = "Slate" },
			{ shape = "Wedge", size = { 12, 3, 6 }, pos = { 0, 10.5, 3 }, rot = { 0, 180, 0 }, color = "#5a3a2e", material = "Slate" },
			{ shape = "CornerWedge", size = { 2, 2, 2 }, pos = { 8, 1, 8 }, rot = { 10, 20, 30 } },
			{ shape = "Ball", size = { 1, 1, 1 }, pos = { 0, 13, 0 }, color = "#ffd700", material = "Neon", canCollide = false },
			{ shape = "Triangle", points = { { -6, 1, -6 }, { -2, 1, -6 }, { -6, 4, -6 } } },
		},
		arrays = { { kind = "radial", of = { "Stâlp" }, count = 4, center = { 0, 0, 0 } } },
		generators = { { kind = "tree", params = { kind = "round", seed = 4 }, at = { pos = { 20, 0, 0 } } } },
	}
	local origin = CFrame.new(-200, 0, 0) * CFrame.fromOrientation(0, math.rad(30), 0)
	local model, report = oneStep("buildFromSpec", Modeling.buildFromSpec, spec, workspace, origin)
	t.eq("named", model.Name, "Chioșc")
	t.eq("report parts", report.parts, #partsIn(model))
	t.eq("one generator", report.generators, 1)
	local sub = model:FindFirstChildOfClass("Model")
	t.check(sub and sub:GetAttribute("LC_Generator") == "tree", "the generator is a child model")
	local stalpi = 0
	for _, p in partsIn(model) do
		if p.Name == "Stâlp" then
			stalpi += 1
		end
	end
	t.eq("radial array: 4 posts", stalpi, 4)
	local neon
	for _, p in partsIn(model) do
		if p.Material == Enum.Material.Neon then
			neon = p
		end
	end
	t.check(neon and not neon.CanCollide and neon.Shape == Enum.PartType.Ball, "ball: neon, no collision")
	-- describe -> spec -> build again = the same parts
	local described = Modeling.describe(model)
	t.check(described.generators and #described.generators == 1 and described.generators[1].kind == "tree", "describe: the generator stays a GEN entry")
	t.eq("describe: parts listed (the generator's are not)", #described.parts, #partsIn(model) - #partsIn(sub))
	t.eq("describe: count = all parts", described.count, #partsIn(model))
	t.check(type(described.summary) == "string" and string.find(described.summary, "parts " .. #partsIn(model), 1, true) ~= nil, "describe: a readback summary")
	print(described.summary)
	local text = Modeling.Spec.toJSON(described)
	t.check(#text < 6000, "describe is compact (" .. #text .. " chars)")
	local again = oneStep("buildFromSpec(describe)", Modeling.buildFromSpec, text, workspace, model:GetPivot())
	local s1, s2 = signature(model, model:GetPivot()), signature(again, again:GetPivot())
	t.eq("round trip: same number of parts", #s2, #s1)
	local same = #s1 == #s2
	for i = 1, math.min(#s1, #s2) do
		local a, b = s1[i], s2[i]
		local ok = a.shape == b.shape and a.color == b.color and a.material == b.material and sameSet(a.corners, b.corners, 5e-3)
		if not ok then
			t.fail("round trip differs at " .. i .. ": " .. tostring(a.class) .. " " .. tostring(a.shape) .. " vs " .. tostring(b.shape))
			same = false
			break
		end
	end
	t.check(same, "round trip: the same parts (shape, corners within 5e-3, colour, material)")
	local validOk, validErrors, count = Modeling.validateSpec(spec)
	t.check(validOk and #validErrors == 0 and count == report.parts, "validateSpec")
	-- invalid specs build nothing
	local before = #workspace:GetChildren()
	rejected("invalid spec", "parts[1].size", Modeling.buildFromSpec, { parts = { { size = { 0, 1, 1 } } } })
	rejected("invalid JSON", "JSON invalid", Modeling.buildFromSpec, "{ parts: [ }")
	rejected("bad parent", "parent", Modeling.buildFromSpec, { parts = {} }, "x")
	t.eq("nothing added", #workspace:GetChildren(), before)
	local badOk, errs = Modeling.validateSpec({ parts = { { size = { 1, 1 } }, { shape = "Cone", size = { 1, 1, 1 } } } })
	t.check(not badOk and #errs == 2, "validateSpec lists every problem")
	-- unsupported parts and floating ones show up in describe
	local mesh = ENV.part("MeshPart", v(2, 2, 2), CFrame.new(0, 30, 0), model)
	local d2 = Modeling.describe(model)
	t.check(d2.unsupported and d2.unsupported[1].class == "MeshPart", "MeshPart listed as unsupported")
	t.check(string.find(d2.summary, "floating (" .. mesh.Name, 1, true) ~= nil, "the hanging MeshPart is reported floating first")
	local limited = Modeling.describe(model, { maxParts = 3 })
	t.check(#limited.parts <= 3 and limited.truncated and limited.truncated > 0, "maxParts truncates")
	local summary = Modeling.summary(again, { budget = 10 })
	t.has("summary budget", summary, "DEPĂȘIT")
	model:Destroy()
	again:Destroy()
end)

-- 11. placement and self check --------------------------------------------------------------------------------------
t.section("placement and selfCheck", function()
	local cf = Modeling.placement(40)
	t.near("placement on the baseplate", cf.Y, 0, 1e-6)
	t.near("placement looks level", cf.LookVector.Y, 0, 1e-9)
	local n0, out0 = #history.log, history.outside
	local check = Modeling.selfCheck()
	t.eq("selfCheck: wedge convention holds", check.wedge, true)
	t.eq("selfCheck: corner wedge convention holds", check.cornerWedge, true)
	t.eq("selfCheck: EditableMesh", check.editableMesh, true)
	t.eq("selfCheck: a cancelled recording", history.log[#history.log], "finish Cancel")
	t.eq("selfCheck: one recording", #history.log - n0, 2)
	t.eq("selfCheck: nothing outside", history.outside - out0, 0)
	t.eq("selfCheck: the probes are gone", #workspace:GetChildren() > 0 and workspace:FindFirstChild("WedgePart"), nil)
end)

t.finish()
