-- Tiny test kit: counters, readable failures, sections that survive a crash, one result line for run.py.
--   local t = LC.kit.new("ai")
--   t.check(cond, "what")  t.eq("what", got, want)  t.has("what", text, "needle")  t.near("what", a, b, eps)
--   t.throws(fn, "needle in the error", "what")  t.section("title", function() ... end)  t.finish()
local Kit = {}

local function show(v)
	if type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

function Kit.new(name)
	local t = { name = name, passes = 0, fails = 0 }
	local section = ""

	local function fail(msg)
		t.fails += 1
		print("FAIL [" .. name .. (section ~= "" and (" / " .. section) or "") .. "] " .. tostring(msg))
	end
	t.fail = fail

	function t.check(cond, msg)
		if cond then
			t.passes += 1
		else
			fail(msg)
		end
		return cond
	end

	function t.eq(msg, got, want)
		if got == want then
			t.passes += 1
		else
			fail(msg .. "\n  got:  " .. show(got) .. "\n  want: " .. show(want))
		end
		return got == want
	end

	function t.has(msg, text, needle)
		local ok = type(text) == "string" and string.find(text, needle, 1, true) ~= nil
		if ok then
			t.passes += 1
		else
			fail(msg .. "\n  missing: " .. show(needle) .. "\n  in:      " .. show(text))
		end
		return ok
	end

	function t.near(msg, a, b, eps)
		local ok = type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (eps or 1e-6)
		if ok then
			t.passes += 1
		else
			fail(msg .. "\n  got " .. tostring(a) .. ", want " .. tostring(b))
		end
		return ok
	end

	-- fn must raise an error (containing `needle` when given)
	function t.throws(fn, needle, msg)
		local ok, err = pcall(fn)
		if ok then
			fail((msg or "expected an error") .. " (no error)")
			return false
		end
		if needle and not string.find(tostring(err), needle, 1, true) then
			fail((msg or "expected an error") .. "\n  wrong error: " .. tostring(err) .. "\n  wanted:      " .. needle)
			return false
		end
		t.passes += 1
		return true
	end

	-- runs fn; a crash is one failure (with its traceback) and the next sections still run
	function t.section(title, fn)
		local previous = section
		section = title
		local ok, err = xpcall(fn, function(e)
			return tostring(e) .. "\n" .. debug.traceback("", 2)
		end)
		if not ok then
			fail("crashed: " .. tostring(err))
		end
		section = previous
	end

	function t.finish()
		print(string.format("LC-RESULT %s passed=%d failed=%d", name, t.passes, t.fails))
		if t.fails > 0 then
			error(string.format("%s: %d check(s) failed", name, t.fails), 0)
		end
	end

	return t
end

return Kit
