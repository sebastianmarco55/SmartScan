-- Bootstrap of every Luau test suite (run.py writes one generated file per suite: a table of all sources and test
-- files as text + a call to this file). The real plugin sources are executed with loadstring + setfenv, so each module
-- sees the mock Roblox globals the suite gives it and nothing else.
--
--   FILES : path -> text    "LostCube/AI.luau" (the real sources), "tests/lib/..", "tests/mocks/..", "tests/suites/.."
--   SUITE : path of the suite to run
local FILES, SUITE = ...

local pristine = {}
for k, v in _G do
	pristine[k] = v
end

local LC = { files = FILES, suite = SUITE }

-- a flat copy of the standard globals (+ overrides): a plain table keeps global lookups as fast as the real ones
function LC.env(extra)
	local env = {}
	for k, v in pristine do
		env[k] = v
	end
	if extra then
		for k, v in extra do
			env[k] = v
		end
	end
	return env
end

-- the text of a file, optionally rewritten by `patch(text) -> text`
function LC.source(path, patch)
	local src = FILES[path]
	if not src then
		error("LC: no such file " .. path, 3)
	end
	if patch then
		src = patch(src)
	end
	return src
end

function LC.load(path, env, patch)
	local fn, err = loadstring(LC.source(path, patch), "@" .. path)
	if not fn then
		error(err, 0)
	end
	if env then
		setfenv(fn, env)
	end
	return fn
end

-- several files run as ONE chunk (the second can use the locals of the first); error positions then count from the top
function LC.loadJoined(paths, chunkname, env)
	local parts = {}
	for _, path in paths do
		table.insert(parts, LC.source(path))
	end
	local fn, err = loadstring(table.concat(parts, "\n"), "@" .. chunkname)
	if not fn then
		error(err, 0)
	end
	if env then
		setfenv(fn, env)
	end
	return fn
end

function LC.run(path, env, ...)
	return LC.load(path, env)(...)
end

LC.kit = LC.run("tests/lib/kit.luau")
LC.modtree = LC.run("tests/lib/modtree.luau", nil, LC)

LC.run(SUITE, nil, LC)
