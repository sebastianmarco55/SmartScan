-- sample for the patterns self-test: five literal patterns, two are malformed ("%" at the end, unbalanced "[")
local s = "abc"
local a = string.find(s, "%d+")
local b = s:match("^%s*(.-)%s*$")
for w in s:gmatch("[^;]+") do end
local c = s:gsub("%", "x")
local d = string.find(s, "[abc")
local e = string.find(s, "(", 1, true) -- plain: not a pattern
return a, b, c, d, e
