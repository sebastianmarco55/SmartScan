-- AI.luau agent mode: the JSON encoder, rawField, truncate and the agent loop (tool_use / tool_result,
-- append-only request bodies, iteration cap, cancel, refusals, HTTP errors, retries) against a scripted HttpService.
-- The test body (suites/bodies/ai_agent.luau) runs in the mock environment, so it uses the mock's globals directly
-- (check, has, load, Http, JSON, Instance, game ...). The real sources come from the modtree.
local LC = ...
local t = LC.kit.new("ai_agent")

local env = LC.env()
LC.run("tests/mocks/agent_env.luau", env, LC)
env.TREE = LC.modtree.new{ env = env, mocks = env.MOCKS, require = function(ref) return env.reqInstance(ref) end }

LC.run("tests/suites/bodies/ai_agent.luau", env)

t.passes += env.PASS
t.fails += env.FAIL
for _, e in env.MOCK_ERRORS do
	t.fail("mock / runtime error: " .. tostring(e))
end
t.finish()
