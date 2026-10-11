-- Tools.luau: every tool Claude can call in agent mode, executed against a mock DataModel, a mock Editor / AnimGen,
-- the real AnimLibrary; read-only tools, writes in ONE undo step, rollback on failure, results cut to a limit.
-- The test body (suites/bodies/tools.luau) runs in the mock environment, so it uses the mock's globals directly
-- (check, has, load, Http, JSON, Instance, game ...). The real sources come from the modtree.
-- The 3D modeling tools run against the real Modeling engine on its typed mock (suites/bodies/tools_modeling.luau).
local LC = ...
local t = LC.kit.new("tools")

local env = LC.env()
LC.run("tests/mocks/agent_env.luau", env, LC)
env.TREE = LC.modtree.new{ env = env, mocks = env.MOCKS, require = function(ref) return env.reqInstance(ref) end }

LC.run("tests/suites/bodies/tools.luau", env)

t.passes += env.PASS
t.fails += env.FAIL
for _, e in env.MOCK_ERRORS do
	t.fail("mock / runtime error: " .. tostring(e))
end

LC.run("tests/suites/bodies/tools_modeling.luau", nil, LC, t)
t.finish()
