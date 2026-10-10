-- LibraryPanel + AnimLibrary + UI (all real) against a permissive proxy for the Roblox API: every unknown global and
-- member is an inert proxy, so this suite is about the panel's own logic (search, filters, selection, custom ids, owner
-- line, add to game, default animation set) and about not crashing on any state, not about GUI properties.
local LC = ...
local t = LC.kit.new("library_panel")
local function check(cond, msg)
	t.check(cond, msg)
end

local Proxy = {}
local function isProxy(v) return type(v) == "table" and getmetatable(v) == Proxy end
local created = {}
local function new(name)
	local p = setmetatable({ __name = name, __store = {} }, Proxy)
	return p
end
Proxy.__index = function(t, k)
	local store = rawget(t, "__store")
	if store[k] ~= nil then return store[k] end
	local child = new(tostring(rawget(t, "__name")) .. "." .. tostring(k))
	store[k] = child
	return child
end
Proxy.__newindex = function(t, k, v) rawget(t, "__store")[k] = v end
Proxy.__call = function(t, ...) return new(tostring(rawget(t, "__name")) .. "()") end
Proxy.__add = function() return new("arith") end
Proxy.__sub = Proxy.__add
Proxy.__mul = Proxy.__add
Proxy.__div = Proxy.__add
Proxy.__unm = Proxy.__add
Proxy.__lt = function() return false end
Proxy.__le = function() return false end
Proxy.__concat = function(a, b) return tostring(isProxy(a) and "<p>" or a) .. tostring(isProxy(b) and "<p>" or b) end
Proxy.__tostring = function(t) return "<proxy>" end


local log = {}
local env = LC.env()
local proxies = {}
setmetatable(env, { __index = function(_, k)
	local p = proxies[k]
	if p == nil then
		p = new(k)
		proxies[k] = p
	end
	return p
end })
env.task = { defer = function(f) end, delay = function(t, f) end, spawn = function(f, ...) return f(...) end, wait = function() return 0 end }
env.Instance = { new = function(class) local p = new("Instance:" .. class) rawget(p, "__store").ClassName = class return p end }
env.game = { GetService = function(_, name) return new("service:" .. name) end }
env.workspace = new("workspace")
env.warn = function(...) table.insert(log, table.concat({ ... }, " ")) end
env.typeof = function(v) return isProxy(v) and "Instance" or typeof(v) end

local tree = LC.modtree.new{ env = env, mocks = { Editor = new("Editor") } }
local UI = tree.load("UI")
local Lib = tree.load("AnimLibrary")
local Panel = tree.load("LibraryPanel")

local refreshes = 0
local ctx = { Editor = new("Editor"), app = { refresh = function() refreshes += 1 end } }

local function parentFrame() return new("parent") end

-- 1. initial render
local p = Panel.new(ctx)
p:render(parentFrame())

-- 2. search + filters
local function names(groups)
	local out = {}
	for _, item in groups do table.insert(out, item.group.key .. ":" .. #item.entries) end
	return table.concat(out, " ")
end
p.query = "ninja"
local g, searching = p:visibleGroups()
check(searching and #g == 1 and g[1].group.key == "ninja" and #g[1].entries == 10, names(g))
p.query = "ninja walk"
g = p:visibleGroups()
check(#g == 1 and #g[1].entries == 1 and g[1].entries[1].id == 656121766, names(g))
p.query = "656118852"
g = p:visibleGroups()
check(#g == 1 and g[1].group.key == "ninja" and g[1].entries[1].state == "run", names(g))
p.query = "wave"
g = p:visibleGroups()
check(#g == 3, names(g))
p.kind = "pack"; g = p:visibleGroups(); check(#g == 0, names(g))
p.kind = "emote"; g = p:visibleGroups(); check(#g == 3)
p.rigFilter = "R6"; g = p:visibleGroups(); check(#g == 1 and g[1].group.key == "emote_r6", names(g))
p.query = ""; p.kind = "all"; p.rigFilter = "all"
g, searching = p:visibleGroups()
check(not searching and #g == 24, names(g))
p.rigFilter = "R6"; g = p:visibleGroups(); check(#g == 2, names(g))
p.rigFilter = "all"
p.query = "zzzzz"; g = p:visibleGroups(); check(#g == 0)
p.query = ""

-- 3. select + render with a selection (+ open group + broad search with row cap)
local entry = Lib.find("astronaut.walk")
check(entry and entry.id == 891667138)
p:select(entry)
check(p.sel == entry and p.openGroup == "astronaut")
p:render(parentFrame())
p.query = "r15"
p:render(parentFrame())
p.query = ""
p:select(Lib.find("emote_r6.dance1a"))
p:render(parentFrame())

-- 4. custom id
p:setCustom("rbxassetid://12345678")
check(p.sel.id == 12345678 and p.sel.kind == "custom")
p:render(parentFrame())
p:setCustom("abc")
check(p.notice and p.notice.text:find("ID"), "notice for a bad custom id")

-- 5. render in 'playing' + 'pack code' states, with a fake track
p:select(Lib.find("ninja.run"))
p.track = { TimePosition = 0.5, Length = 1.2, IsPlaying = true }
p.playing = true
p.codeMode = "pack"
p:render(parentFrame())
p.owner[656118852] = { ok = true, name = "Ninja Run", creator = "Roblox", assetType = 24, roblox = true }
p:render(parentFrame())
local text, color = p:ownerLine(p.sel)
check(text:find("✓"), text)
p.owner[656118852] = { ok = true, name = "x", creator = "Someone", assetType = 24, roblox = false }
text = p:ownerLine(p.sel); check(text:find("✗"), text)
p.owner[656118852] = { ok = true, name = "x", creator = "Roblox", assetType = 61, roblox = true }
text = p:ownerLine(p.sel); check(text:find("61"), text)
p.owner[656118852] = { ok = false, err = "HTTP 403" }
text = p:ownerLine(p.sel); check(text:find("403"), text)
p.track = nil; p.playing = false

-- 6. addToGame / installDefault / removeDefault run end to end against proxies
p:addToGame(Lib.group("ninja"), Lib.group("ninja").entries, "Ninja")
check(p.notice and p.notice.text:find("10 animații"), p.notice and p.notice.text)
p:installDefault(Lib.group("ninja"))
p:removeDefault()

-- 7. Heartbeat/StepAnimations path: play with a rig made of proxies must not error
p.rig = new("rig")
rawget(p.rig, "__store").Parent = new("workspace")
rawget(p.rig, "__store").GetDescendants = function() return {} end
p:select(Lib.find("mage.idle1"))
p:play()
p:stop()
check(refreshes > 0, "the panel asked the app to refresh")
check(#log == 0, "no warnings: " .. table.concat(log, " | "))

t.finish()
