-- Markdown.luau: the pure parts (inline -> RichText, block parser). Rendering to GUI is exercised by the claude_panel suite.
local LC = ...
local t = LC.kit.new("markdown")
local function eq(name, got, want)
	t.eq(name, got, want)
end

local tree = LC.modtree.new{
	env = LC.env{ Color3 = { fromRGB = function(...) return { ... } end } },
	mocks = { UI = { C = {}, FONT = 0 } },
}
local Markdown = tree.load("Markdown")
local I = Markdown.inline

-- escaping
eq("escape", Markdown.escape("a < b && c > d"), "a &lt; b &amp;&amp; c &gt; d")
eq("escape tags", I("<script>x</script>"), "&lt;script&gt;x&lt;/script&gt;")
eq("bold", I("a **b** c"), "a <b>b</b> c")
eq("italic", I("a *b* c"), "a <i>b</i> c")
eq("bold+italic", I("**a** and *b*"), "<b>a</b> and <i>b</i>")
eq("nested", I("**bold *it* x**"), "<b>bold <i>it</i> x</b>")
eq("underscore italic", I("_hi there_"), "<i>hi there</i>")
eq("snake_case kept", I("LC_Duration and LC_On_x"), "LC_Duration and LC_On_x")
eq("snake in sentence", I("set my_var_name now"), "set my_var_name now")
eq("__bold__", I("__strong__ word"), "<b>strong</b> word")
eq("mult", I("2 * 3 * 4"), "2 * 3 * 4")
eq("strike", I("~~old~~ new"), "<s>old</s> new")
eq("code", I("use `Editor.newEffect(\"a<b>\")` now"),
	'use <font face="RobotoMono" color="#D7B8FF">Editor.newEffect("a&lt;b&gt;")</font> now')
eq("code no format", I("`**not bold**`"), '<font face="RobotoMono" color="#D7B8FF">**not bold**</font>')
eq("bold around code", I("**see `x`**"), '<b>see <font face="RobotoMono" color="#D7B8FF">x</font></b>')
eq("double ticks", I("``a ` b``"), '<font face="RobotoMono" color="#D7B8FF">a ` b</font>')
eq("unbalanced bold", I("**open"), "**open")
eq("broken nesting falls back", I("**a *b** c*"), "**a *b** c*")
eq("amp in bold", I("**R&D**"), "<b>R&amp;D</b>")
eq("link", I("[docs](https://create.roblox.com/a_b)"),
	'<u>docs</u> <font color="#9696A6">(https://create.roblox.com/a_b)</font>')
eq("control chars stripped", I("a\1b\2c"), "abc")
eq("path with dots", I("`ServerScriptService.Combat`"), '<font face="RobotoMono" color="#D7B8FF">ServerScriptService.Combat</font>')

-- blocks
local doc = [[
# Titlu
## Pe scurt
Un paragraf
pe două rânduri.

- unu **bold**
- doi
  continuare
  - sub
    - subsub
- trei

1. primul
2. al doilea

10. zece
---
> citat
> pe două rânduri
```lua
local x = 1 < 2
	print(x)
```
| A | B |
|---|---|
| 1 | 2 \| 3 |

- [ ] de făcut
- [x] gata
### Final ###
~~~
unclosed tilde
]]
local blocks = Markdown.parse(doc)
local kinds = {}
for _, b in blocks do
	table.insert(kinds, b.type .. (b.level and tostring(b.level) or ""))
end
eq("block kinds", table.concat(kinds, ","),
	"heading1,heading2,paragraph,list,list,rule,quote,code,table,list,heading3,code")
eq("paragraph text", blocks[3].text, "Un paragraf\npe două rânduri.")
local l = blocks[4]
eq("list ordered", l.ordered, false)
eq("list count", #l.items, 5)
eq("item1", l.items[1].text, "unu **bold**")
eq("continuation", l.items[2].text, "doi\ncontinuare")
eq("sub level", l.items[3].level, 1)
eq("subsub level", l.items[4].level, 2)
eq("back to top", l.items[5].level, 0)
local n = blocks[5]
eq("numbered", n.ordered, true)
eq("numbered count (blank line keeps list)", #n.items, 3)
eq("number kept", n.items[3].number, 10)
eq("quote", blocks[7].text, "citat\npe două rânduri")
eq("code lang", blocks[8].lang, "lua")
eq("code body", blocks[8].code, "local x = 1 < 2\n\tprint(x)")
eq("table rows", #blocks[9].rows, 2)
eq("table header", blocks[9].rows[1].header, true)
eq("table cell escaped pipe", blocks[9].rows[2].cells[2], "2 | 3")
eq("task unchecked", blocks[10].items[1].task, false)
eq("task checked", blocks[10].items[2].task, true)
eq("task text", blocks[10].items[2].text, "gata")
eq("heading trailing hashes", blocks[11].text, "Final")
eq("unclosed fence keeps the rest", blocks[12].code, "unclosed tilde")

-- bold line is not a list; *** is a rule; code fenced inside a list item
local b2 = Markdown.parse("**Model:** Opus\n**Efort:** mediu\n\n***\n1. pas\n   ```lua\n   print(1)\n   ```\n2. pas doi")
eq("bold lines paragraph", b2[1].type .. "|" .. b2[1].text, "paragraph|**Model:** Opus\n**Efort:** mediu")
eq("rule ***", b2[2].type, "rule")
eq("list before code", b2[3].type, "list")
eq("indented code dedented", b2[4].code, "print(1)")
eq("list after code", b2[5].type .. #b2[5].items, "list1")
eq("number after code", b2[5].items[1].number, 2)

-- empty / whitespace
eq("empty", #Markdown.parse(""), 0)
eq("crlf", Markdown.parse("a\r\nb")[1].text, "a\nb")


t.finish()
