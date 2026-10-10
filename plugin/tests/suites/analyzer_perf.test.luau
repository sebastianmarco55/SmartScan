-- Analyzer on a big place (about 100 000 instances, 2 000 scripts): the scan must finish, stay inside the frame budget
-- (it yields often; the fake clock makes every os.clock() call cost 4 ms) and its context for Claude must stay cheap.
local LC = ...
local T = LC.kit.new("analyzer_perf")
local M = LC.run("tests/mocks/datamodel.luau")
local tree = LC.modtree.new{ env = LC.env(M.globals()) }
local Analyzer = tree.load("Analyzer")
local new, service, V3, Color3, Enum, workspace, realOs = M.new, M.service, M.V3, M.Color3, M.Enum, M.workspace, M.realOs
local game = M.game
service("ServerStorage")

local SSS = service("ServerScriptService", {})
local RS = service("ReplicatedStorage", {})
local body = {}
for i = 1, 30 do
	table.insert(body, "local Players = game:GetService('Players')")
	table.insert(body, "local function f" .. i .. "(player, amount)")
	table.insert(body, "\tif typeof(amount) ~= 'number' then return end -- check")
	table.insert(body, "\tplayer.leaderstats.Coins.Value += amount")
	table.insert(body, "end")
end
local source = table.concat(body, "\n") .. "\nremote.OnServerEvent:Connect(function(p, a)\n\tf1(p, a)\nend)\nwhile true do\n\ttask.wait(1)\nend\n"
local folder = new("Folder", "Systems")
folder.Parent = SSS
for i = 1, 2000 do
	new(i % 3 == 0 and "ModuleScript" or "Script", "System" .. i, { Source = source }).Parent = folder
end
local map = new("Model", "Map")
map.Parent = workspace
for m = 1, 1000 do
	local model = new("Model", "Building" .. m)
	model.Parent = map
	for p = 1, 99 do
		new("Part", "Part", { Anchored = p % 10 ~= 0, Size = V3(4, 1, 2), Position = V3(m, p, 0),
			Color = Color3.fromRGB((m * 7) % 255, (p * 13) % 255, 90), Material = Enum.Material.Plastic, Transparency = 0,
			CanCollide = true }).Parent = model
	end
end
local t0 = realOs.clock()
local report
local co = coroutine.create(function()
	report = Analyzer.run(nil)
end)
local frames, worst, last = 0, 0, realOs.clock()
while coroutine.status(co) ~= "dead" do
	local s = realOs.clock()
	local ok, err = coroutine.resume(co)
	if not ok then
		T.fail("scan crashed: " .. tostring(err))
		break
	end
	worst = math.max(worst, realOs.clock() - s)
	frames += 1
end
local total = realOs.clock() - t0
T.check(report ~= nil, "the scan finished with a report")
if report then
	print(string.format("instances %d scripts %d lines %d: %.2f s total, %d frames, worst frame %.1f ms", report.totals.instances,
		report.totals.scripts, report.totals.lines, total, frames, worst * 1000))
	T.check(report.totals.instances >= 100000, "every instance was visited: " .. report.totals.instances)
	T.check(report.totals.scripts == 2000, "all scripts were read: " .. report.totals.scripts)
	T.check(report.totals.errors == 0, "no visit errors: " .. tostring(report.totals.errors))
	T.check(frames >= 50, "the scan is cut into many frames: " .. frames)
	-- a frame must stay short even on this much work (budget ~16 ms of fake time; generous limit for slow CI machines)
	T.check(worst < 1.5, string.format("worst frame %.0f ms", worst * 1000))
	local t1 = realOs.clock()
	local ctx = Analyzer.context(report)
	local ctxTime = realOs.clock() - t1
	print(string.format("context %d chars in %.1f ms; issues %d", #ctx, ctxTime * 1000, #report.issues))
	T.check(#ctx <= 15000, "the context for Claude stays small: " .. #ctx)
	T.check(ctxTime < 5, string.format("context built in %.0f ms", ctxTime * 1000))
	local stored = game:GetService("ServerStorage"):FindFirstChild("LostCubeAnalysis")
	T.check(stored ~= nil and #stored.Report.Value > 0, "the report was saved in the place")
end
T.finish()
