-- Tools.luau, the 3D modeling tools (get_modeling_guide, validate_spec, describe_model, model_summary, generate_model,
-- regenerate_model, build_from_spec, modeling_op, place_terrain) against the REAL Modeling engine on its typed Roblox
-- mock (tests/mocks/modeling_env.luau): every write is one undo step (the engine's own recording joins the tool's),
-- a failed write is rolled back, results stay under AI.MAX_TOOL_RESULT, read-only tools change nothing.
local LC, t = ...

local ENV = LC.run("tests/mocks/modeling_env.luau", nil, LC)
local services = ENV.__services
services.HttpService = {} -- AI.luau asks for it when it loads (no request is made here)
local history, terrain, csg = ENV.__history, ENV.__terrain, ENV.__csg
local Vector3, CFrame = ENV.Vector3, ENV.CFrame
local workspace = ENV.workspace

local MISSING = LC.modtree.MISSING
local tree = LC.modtree.new({ env = ENV, mocks = { Analyzer = MISSING, Editor = MISSING } })
local Tools = tree.load("Tools")
local AI = tree.load("AI")

local function has(text, needle)
	return type(text) == "string" and string.find(text, needle, 1, true) ~= nil
end
local function run(name, input)
	return Tools.run(name, input, {})
end
-- a tool call with its undo log: { "begin ...", "refused ...", "finish Commit" }
local function logged(name, input)
	local n0, out0 = #history.log, history.outside
	local ok, text = run(name, input)
	local added = {}
	for i = n0 + 1, #history.log do
		table.insert(added, history.log[i])
	end
	return ok, text, added, history.outside - out0
end
local function oneStep(label, added, outside)
	t.check(#added >= 2 and string.find(added[1], "^begin LostCube %(Claude%): ") ~= nil and added[#added] == "finish Commit",
		label .. ": one committed undo step (" .. table.concat(added, " | ") .. ")")
	local begins = 0
	for _, line in added do
		if string.find(line, "^begin ") then
			begins += 1
		end
	end
	t.eq(label .. ": a single recording", begins, 1)
	t.eq(label .. ": nothing changed outside it", outside, 0)
end
local function rolledBack(label, added)
	t.check(#added == 0 or added[#added] == "finish Cancel", label .. ": rolled back (" .. table.concat(added, " | ") .. ")")
end
local function models(name)
	local out = {}
	for _, c in workspace:GetChildren() do
		if c.Name == name then
			table.insert(out, c)
		end
	end
	return out
end

local baseplate = ENV.part("Part", Vector3.new(512, 1, 512), CFrame.new(0, -0.5, 0))
baseplate.Name = "Baseplate"

t.section("modeling tools: definitions", function()
	local byName = {}
	for _, def in Tools.definitions() do
		byName[def.name] = def
	end
	for _, name in { "get_modeling_guide", "validate_spec", "describe_model", "model_summary" } do
		t.check(byName[name] ~= nil and Tools.isWrite(name) == false, "read-only " .. name)
	end
	for _, name in { "build_from_spec", "generate_model", "regenerate_model", "modeling_op", "place_terrain" } do
		t.check(byName[name] ~= nil and Tools.isWrite(name) == true, "write " .. name)
	end
	-- free-form params / spec objects are the only non-strict ones
	for _, name in { "validate_spec", "build_from_spec", "generate_model", "regenerate_model", "modeling_op" } do
		t.check(byName[name].strict == nil, "not strict (free object) " .. name)
	end
	for _, name in { "get_modeling_guide", "describe_model", "model_summary", "place_terrain" } do
		t.check(byName[name].strict == true, "strict " .. name)
	end
	t.check(#byName.modeling_op.input_schema.properties.op.enum >= 18, "modeling_op lists its operations")
	t.check(has(byName.generate_model.description, "get_modeling_guide") and has(byName.model_summary.description, "after every build"),
		"descriptions say when to use them")
	for _, def in Tools.LIST do
		t.check(type(Tools.summary(def.name, {})) == "string", "summary of " .. def.name)
	end
end)

t.section("get_modeling_guide", function()
	local ok, text = run("get_modeling_guide", {})
	t.check(ok, "guide ok")
	t.check(#text <= AI.MAX_TOOL_RESULT - 400 and not has(text, "[tăiat"), "the whole guide fits in one result, with room: " .. #text)
	t.check(has(text, "Building in Roblox Studio") and has(text, "model_summary") and has(text, "generate_model"),
		"the instructions name the real tools")
	t.check(has(text, "building: width=24 [8-400]") and has(text, "floors=2 int[1-40]") and has(text, "roof=flat|gable*|hip"),
		"compact generator schemas")
	t.check(has(text, "DOOR_WIDTH 5") and has(text, "JUMP_HEIGHT 7.2"), "scale constants")
	t.check(has(text, "LostCube build spec"), "the spec reference")
	t.check(#Tools.MODELING_INSTRUCTIONS <= 6000, "the instructions block stays short: " .. #Tools.MODELING_INSTRUCTIONS)
	for _, topic in { "instructions", "generators", "spec" } do
		local okTopic, part = run("get_modeling_guide", { topic = topic })
		t.check(okTopic and #part < #text, "topic " .. topic)
	end
	t.check(not run("get_modeling_guide", { topic = "nope" }), "unknown topic fails")
end)

t.section("validate_spec", function()
	local n0 = #history.log
	local ok, text = run("validate_spec", { spec = { name = "Cabană", parts = { { size = { 8, 1, 8 }, color = "#8a6f53" } },
		generators = { { kind = "tree", params = { height = 10 }, at = { 10, 0, 0 } } } } })
	t.check(ok and has(text, "Spec valid") and has(text, "piese"), text)
	ok, text = run("validate_spec", { spec = '{"parts": [{"size": [1, -2, 1]}], "colour": 1}' })
	t.check(ok and has(text, "Spec invalid") and has(text, "parts[1].size") and has(text, "colour"), text)
	t.eq("validate builds nothing", #history.log, n0)
	t.eq("nothing named Cabană", #models("Cabană"), 0)
end)

local house
t.section("generate_model", function()
	local ok, text, added, outside = logged("generate_model", { kind = "building", params = { width = 24, depth = 20, floors = 2 },
		position = { 40, 0, 0 }, yaw = 90, name = "Casa" })
	t.check(ok, text)
	oneStep("generate", added, outside)
	house = models("Casa")[1]
	t.check(house ~= nil and house:GetAttribute("LC_Generator") == "building", "the model is in Workspace with its recipe")
	t.check(has(text, "Workspace.Casa") and has(text, "Readback:") and has(text, "params: {"), text)
	t.check(math.abs(house.WorldPivot.Position.X - 40) < 1e-6, "placed at the position")
	-- bad parameters: an error, rolled back, nothing built
	local before = #workspace:GetChildren()
	ok, text, added = logged("generate_model", { kind = "building", params = { width = 2, wings = 3 } })
	t.check(not ok and has(text, "Eroare") and has(text, "wings") and has(text, "nu s-a schimbat nimic"), text)
	rolledBack("bad params", added)
	t.eq("nothing added", #workspace:GetChildren(), before)
	ok, text = run("generate_model", { kind = "spaceship" })
	t.check(not ok and has(text, "Generator necunoscut"), text)
	-- no position: in front of the camera, the front turned toward it
	ok, text = run("generate_model", { kind = "tree", params = { kind = "pine", seed = 2 }, name = "Brad" })
	t.check(ok and #models("Brad") == 1, text)
end)

t.section("describe_model / model_summary", function()
	local n0 = #history.log
	local ok, text = run("describe_model", { path = "Workspace.Casa" })
	t.check(ok and has(text, "Model Casa") and has(text, "spec (pos / rot") and has(text, '"parts":['), text)
	t.check(#text <= AI.MAX_TOOL_RESULT, "describe fits: " .. #text)
	ok, text = run("describe_model", { path = "Workspace.Casa", max_parts = 500 })
	t.check(ok and #text <= AI.MAX_TOOL_RESULT and not has(text, "[tăiat"), "a big describe shrinks itself to fit: " .. #text)
	ok, text = run("model_summary", { path = "Workspace.Casa", budget = 40, optimize_report = true })
	t.check(ok and has(text, "budget parts") and has(text, "DEPĂȘIT") and has(text, "Optimize (dry run)"), text)
	ok, text = run("describe_model", { path = "Workspace.Nimic" })
	t.check(not ok and has(text, "Nu există instanța"), text)
	ENV.__services.Selection:Set({})
	ok, text = run("model_summary", {})
	t.check(not ok and has(text, "Nu e nimic selectat"), text)
	ENV.__services.Selection:Set({ house })
	ok, text = run("model_summary", {})
	t.check(ok and has(text, "Model Casa"), "the selection by default")
	t.eq("reads record nothing", #history.log, n0)
end)

t.section("regenerate_model", function()
	local parts0 = house:GetAttribute("LC_Parts")
	local ok, text, added, outside = logged("regenerate_model", { path = "Workspace.Casa", params = { floors = 3 } })
	t.check(ok, text)
	oneStep("regenerate", added, outside)
	local fresh = models("Casa")
	t.eq("one Casa left", #fresh, 1)
	t.check(fresh[1] ~= house and house.Parent == nil, "the old model was replaced")
	t.check(fresh[1]:GetAttribute("LC_Parts") > parts0 and has(text, '"floors":3'), "three floors now")
	house = fresh[1]
	ok, text = run("regenerate_model", { path = "Workspace.Baseplate", params = { floors = 1 } })
	t.check(not ok and has(text, "regenerate"), text)
end)

t.section("build_from_spec", function()
	local spec = { name = "Curte", parts = { { size = { 20, 1, 20 }, pos = { 0, 0.5, 0 }, color = "#7a7a7a", material = "Concrete" },
		{ shape = "Cylinder", size = { 6, 1, 1 }, pos = { 0, 4, 0 }, rot = { 0, 0, 90 }, name = "Stâlp" } },
		generators = { { kind = "fence", params = { points = { { -10, 0, -10 }, { 10, 0, -10 } } } } },
		arrays = { { kind = "linear", of = { 2 }, count = 3, offset = { 6, 0, 0 } } } }
	local ok, text, added, outside = logged("build_from_spec", { spec = spec, position = { -60, 0, 0 } })
	t.check(ok, text)
	oneStep("build_from_spec", added, outside)
	t.check(#models("Curte") == 1 and has(text, "Workspace.Curte") and has(text, "1 generatoare") and has(text, "Readback:"), text)
	ok, text, added = logged("build_from_spec", { spec = { parts = { { size = { 1, 1 } } } } })
	t.check(not ok and has(text, "Spec invalid") and has(text, "parts[1].size"), text)
	rolledBack("invalid spec", added)
	ok, text = run("build_from_spec", { spec = '{"name": "Din text", "parts": [{"size": [2, 2, 2]}]}' })
	t.check(ok and #models("Din text") == 1, "a spec given as JSON text: " .. text)
end)

t.section("modeling_op", function()
	local crate = ENV.part("Part", Vector3.new(2, 2, 2), CFrame.new(100, 1, 0))
	crate.Name = "Ladă"
	local ok, text, added, outside = logged("modeling_op", { op = "linear_array", targets = { "Workspace.Ladă" },
		params = { count = 4, offset = { 3, 0, 0 } } })
	t.check(ok and has(text, "3 copii"), text)
	oneStep("linear_array", added, outside)
	t.eq("four crates", #models("Ladă"), 4)
	-- the selection is the default target; snake_case params work
	ENV.__services.Selection:Set({ crate })
	ok, text, added, outside = logged("modeling_op", { op = "mirror", params = { plane = "X", copy = true } })
	t.check(ok and has(text, "Oglindit"), text)
	oneStep("mirror", added, outside)
	ok, text = run("modeling_op", { op = "radial_array", targets = { "selection" }, params = { count = 6, radius = 8 } })
	t.check(ok and has(text, "5 copii în cerc"), text)
	ok, text = run("modeling_op", { op = "triangle_fill", params = { points = { { 0, 5, 0 }, { 8, 5, 0 }, { 0, 5, 8 } },
		thickness = 0.5, color = "#ff8800" } })
	t.check(ok and has(text, "pene"), text)
	ok, text = run("modeling_op", { op = "align", targets = { "Workspace.Ladă", "Workspace.Curte" }, params = { axis = "Y",
		mode = "min", target = 0 } })
	t.check(ok and has(text, "Aliniat 2"), text)
	ok, text = run("modeling_op", { op = "snap_to_grid", targets = { "Workspace.Ladă" }, params = { grid = 4 } })
	t.check(ok and has(text, "grila de 4"), text)
	ok, text = run("modeling_op", { op = "along_spline", params = { kind = "pipe", points = { { 0, 2, 40 }, { 20, 2, 50 }, { 40, 2, 40 } },
		spacing = 4 } })
	t.check(ok and has(text, "pipe") and has(text, "Readback:"), text)
	ok, text = run("modeling_op", { op = "scatter", targets = { "Workspace.Brad" }, params = { region = { center = { 0, 10, -80 },
		size = { 60, 40, 60 } }, count = 8, min_distance = 4, seed = 7 } })
	t.check(ok and has(text, "Am împrăștiat") and has(text, "seed 7"), text)
	ok, text = run("modeling_op", { op = "optimize", targets = { "Workspace.Casa" }, params = { dry_run = true } })
	t.check(ok and has(text, "Optimize (dry run)"), text)
	-- a CSG failure: an error, the whole step rolled back
	csg.fail = "test"
	local b1 = ENV.part("Part", Vector3.new(4, 4, 4), CFrame.new(150, 2, 0))
	b1.Name = "A"
	local b2 = ENV.part("Part", Vector3.new(4, 4, 4), CFrame.new(152, 2, 0))
	b2.Name = "B"
	ok, text, added = logged("modeling_op", { op = "merge", targets = { "Workspace.A", "Workspace.B" } })
	t.check(not ok and has(text, "Eroare") and has(text, "nu s-a schimbat nimic"), text)
	rolledBack("merge failure", added)
	t.check(b1.Parent == workspace and b2.Parent == workspace, "the parts are still there")
	csg.fail = false
	-- bad input
	ok, text = run("modeling_op", { op = "explode" })
	t.check(not ok and has(text, "Operație necunoscută") and has(text, "linear_array"), text)
	ok, text = run("modeling_op", { op = "linear_array", targets = { "Workspace.Nu" }, params = { count = 2, offset = { 1, 0, 0 } } })
	t.check(not ok and has(text, "Nu există instanța"), text)
	ok, text = run("modeling_op", { op = "linear_array", targets = { "Workspace.Ladă" }, params = { count = 2, offset = "x" } })
	t.check(not ok and has(text, "offset"), text)
end)

t.section("place_terrain", function()
	local calls0 = #terrain.calls
	local ok, text, added, outside = logged("place_terrain", { kind = "hill", radius = 20, material = "Grass", position = { 0, 0, -200 } })
	t.check(ok and has(text, "Teren „hill”") and has(text, "operații"), text)
	oneStep("place_terrain", added, outside)
	t.check(#terrain.calls > calls0, "terrain was filled")
	ok, text = run("place_terrain", { kind = "hill", material = "Cheese" })
	t.check(not ok and has(text, "material"), text)
end)
