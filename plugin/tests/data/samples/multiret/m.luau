-- sample for the multiret self-test: three spills (add, return, table), three fine uses
local function add(a, b, pos) end
add("x", string.find("abc", "b"))
add("x", (string.find("abc", "b")))
add("x", string.find("abc", "b"), 1)
local function f(s)
	return s:gsub("a", "b")
end
local function g(s)
	return (s:gsub("a", "b"))
end
local t = { 1, string.find("abc", "b") }
local u = { string.find("abc", "b"), 2 }
return f, g, t, u
