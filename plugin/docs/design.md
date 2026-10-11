# LostCube 2.1 — design system

How the LostCube window looks and how to build a panel with the UI kit. This document is the spec: migrate a panel
using only what is here. Sources: `LostCube/Theme.luau` (tokens, type, spacing), `LostCube/Icons.luau` (glyphs and
class icons), `LostCube/UI.luau` (components), `LostCube/App.luau` (window shell). Tests: `tests/suites/ui.test.luau`.

## 1. Direction

LostCube should read as a first-party Studio panel (like Studio's Properties / Explorer, Moon Animator 2,
Archimedes): calm, dense, precise, nothing decorative.

- **Colours come from the Studio theme** (Light and Dark), through tokens. Never write `Color3.fromRGB` for UI chrome.
- **One accent**: Studio's own main-button blue (`C.accent`), only for the primary action, the selection and focus.
  No purple, no gradients, no glow, no shadows.
- **No emoji, anywhere.** Not in labels, titles, buttons, notes, menu items or toasts. Glyphs are Studio images
  (`Icons`), instance kinds are class icons.
- **Flat structure**: sections are a small dim uppercase header with a chevron and a divider under them; no cards,
  no boxes inside boxes, no filled section headers.
- **Few words**: short Romanian sentence-case labels; persistent states get a quiet note, one-off results a toast.

## 2. Colour tokens

Use `local C = UI.C` and read `C.<token>` when you paint. The values are replaced *in place* when Studio switches
theme, and App re-renders the panel, so a colour read at render time is always current. Do not keep a Color3 in a
long-lived upvalue. For an instance you create yourself and that outlives renders, bind it:
`UI.skin(inst, { BackgroundColor3 = "surface", TextColor3 = "text" })` (it repaints on theme change).

| Token | Studio source (`StudioStyleGuideColor`, modifier) | Use |
|---|---|---|
| `bg` | MainBackground | window / panel background |
| `header` | Titlebar | (reserved) title strips |
| `surface` | Dropdown | floating surfaces: menus, popovers, toasts, dialogs (always with a 1 px `border`) |
| `surfaceHover` | Item, Hover | hover background of rows, icon buttons, ghost buttons |
| `surfacePressed` | Item, Pressed | pressed state |
| `raised` | bg mixed 4–6 % toward text | quiet fills: notes, chips, badges, progress track |
| `raisedStrong` | field mixed 10–16 % toward text | the chosen segment of a segmented control |
| `field` | InputFieldBackground | text / number / dropdown / colour fields |
| `fieldBorder` | InputFieldBorder | field border at rest |
| `fieldBorderHover` | InputFieldBorder, Hover | field border on hover |
| `focus` | InputFieldBorder, Selected | field border while focused or its menu is open |
| `border` | Border | 1 px borders of floating surfaces, swatches |
| `divider` | Separator | section dividers, `UI.divider` |
| `button` / `buttonHover` / `buttonPressed` | Button (Default / Hover / Pressed) | secondary buttons |
| `buttonBorder` | ButtonBorder | secondary button border |
| `buttonText` | ButtonText | secondary button text |
| `text` | MainText | body text, values |
| `textDim` | SubText | labels of rows, section titles, meta, glyphs at rest |
| `textDisabled` | DimmedText | disabled text, placeholders |
| `textBright` | BrightText | panel titles, the app name |
| `accent` / `accentHover` / `accentPressed` | MainButton (Default / Hover / Pressed) | primary button, selection bar, switch on, focus glyphs |
| `accentText` | DialogMainButtonText | text on `accent` |
| `accentSoft` / `accentSoftHover` | bg mixed toward accent | selected row / chip background |
| `link` | LinkText | links |
| `danger` / `dangerSoft` | ErrorText (+ tint) | errors, destructive actions |
| `warning` / `warningSoft` | WarningText (+ tint) | warnings |
| `success` / `successSoft` | built-in green (Studio has none) | success |
| `info` | = accent | info toasts / notes |
| `scrollbar` | ScrollBar | scroll bars |
| `tooltip` | Tooltip | tooltip background |
| `switchOff`, `knob`, `scrim` | derived | switch track off, switch / slider knob, modal scrim |

The 2.0 names still work and map to tokens: `section`→`bg`, `item`→`raised`, `hover`→`surfaceHover`,
`input`→`field`, `dim`→`textDim`, `accentDark`→`accentSoft`, `good`→`success`, `warn`→`warning`
(`bg`, `header`, `border`, `text`, `accent`, `accentHover`, `danger` keep their names). New code uses the token names.

Data colours (an effect's colour, a palette swatch, a map colour) are not UI colours: show them as they are.

Outside Studio (tests, ScreenGui, previews) the tokens come from built-in Dark / Light palettes;
`Theme.force("Light" | "Dark" | nil)` switches them for previews and tests.

## 3. Typography

Builder Sans through `FontFace` (`Font.new("rbxasset://fonts/families/BuilderSans.json", weight)`), code in
Builder Mono. Five sizes only.

| Role | Size | Weight | Use |
|---|---|---|---|
| `caps` | 11 | Bold | section titles, menu group headers (uppercase via `<uc>`, colour `textDim`) |
| `meta` | 11 | Regular | counts, units, hints on the right of a row, versions, tooltips |
| `body` | 12 | Regular | text, field values, row labels, menu items |
| `control` | 12 | Medium | buttons, tabs, chips |
| `emphasis` | 13 | Medium | empty-state and dialog titles, the app name |
| `title` | 15 | Bold | panel title (`UI.header`) |
| `code` | 12 | Regular, Builder Mono | code, ids |

- `UI.label(parent, text, { role = "meta" })`; for your own instances `UI.textStyle(instOrProps, role, weight?)`.
- Sentence case everywhere. The only uppercase is the `caps` role, done by `UI.section` / menu headers with the RichText
  tag `<uc>`; never type text in capitals.
- `UI.FONT`, `UI.FONT_MED`, `UI.FONT_BOLD` (Enum.Font) remain for old code; new code does not set `.Font`.

## 4. Spacing, sizes, radius

- 4 px grid: `UI.SPACE = { xxs = 2, xs = 4, sm = 8, md = 12, lg = 16, xl = 24 }`.
- Panel padding 12 (App gives it: do not pad the panel root again). Rows inside a section: 4 px apart
  (the section body is a `vlist(4)`); groups of rows: a spacer of 8 or a new section.
- Control height `UI.H` = 24 (fields, buttons, rows); `UI.H_LARGE` = 28 (primary call to action, list rows, section
  header). Label column of a row `UI.LABEL_W` = 96, gap 8.
- Radius 4 for controls (`UI.RADIUS.control`), 6 for floating surfaces (`UI.RADIUS.surface`), pills fully round.
- Borders are 1 px from tokens. Prefer a border or nothing to a fill.
- Glyphs 16 px (12 for chevrons in fields and section headers, 14 in small buttons).

## 5. Motion

Short and quiet: `Theme.MOTION = { fast = 0.08, base = 0.12, slow = 0.15 }` seconds, Quad Out, via `UI.animate`.
Used for hover / press colours, focus borders, the switch knob, the section chevron, progress. No bounce, no slides,
no loops. Everything still works instantly where TweenService is missing.

## 6. Window and navigation (App)

```
┌ header 40 ─ [cube mark] LostCube 2.1.0 ............ [?] [gear] ┐
├ tabs 32 ── [icon Joc] [icon] [icon] [icon] [icon] [icon]       ┤  divider
│ content (scrolls, padding 12) — the panel's sections           │
│                                         toasts (bottom, ≤ 360) │
└────────────────────────────────────────────────────────────────┘
```

- Tabs, in order: **Joc** (`Game`, AnalysisPanel), **Efecte** (`VFX`, VFXPanel), **Animații** (`Anim`, AnimPanel),
  **Bibliotecă** (`Library`, LibraryPanel), **Modelare** (`Build`, BuildPanel), **Claude** (`Claude`, ClaudePanel).
  Each has a Studio glyph (`game`, `effects`, `animation`, `library`, `build`, `chat`) and a one-word label.
- **Compaction** (`UI.tabsMode(width, items)`, label widths measured with TextService):
  `full` — every tab shows icon + label (wide windows, ≈ 540 px and up);
  `compact` — only the open tab shows its label, the others are 32 px icons (the usual 300–420 px dock);
  `icons` — icons only (very narrow). Hidden labels become tooltips. The open tab: text colour, accent glyph and a
  2 px accent line at the bottom; others `textDim`, `text` on hover. The bar rebuilds when the tab or the width class
  changes.
- A tab whose module is not in the plugin yet shows a quiet empty state (“În lucru”, “Apare într-o versiune
  următoare.”) instead of an error. Adding a tab = one entry in `App.TABS` + a `<Name>Panel.luau` with
  `new(ctx)` / `render(parent)` / optional `destroy()`.
- Header: help (shortcuts popover) and settings (menu: fold / unfold all sections). App remembers the open tab, the
  folded sections and the recent colours in the plugin settings.
- App holds a refresh while the user types in a text box or while `UI.busy()` (a drag, a menu, the colour picker or a
  dialog is open), then redraws once.

## 7. Components

All components take `parent` first (the frame they go into), return the instance you would want to keep, and accept
an `opts` table last. Colour options take a Color3 *or* a token name (`"danger"`); token values stay live.

### Structure

**`UI.section(parent, title, opts) -> body`** — flat collapsible group: 28 px header (chevron, `caps` title in
`textDim`, optional badge / right controls), the body (vertical, rows 4 px apart, 12 px under), a divider. The
fold state lives in `UI.collapsed[key]` and survives renders. opts: `key` (default the title; give one, titles change),
`collapsed` (first time), `collapsible = false` (plain group label), `badge` (count shown on the right),
`right(frame)` + `rightWidth` (icon buttons in the header), `onToggle(collapsed)`. A body you build only when open:
check `UI.collapsed[key]` after creating it. One level only: never put a section in a section.
```lua
local body = UI.section(parent, "Elemente", { key = "vfx.elements", badge = #elements, right = function(r)
	UI.iconButton(r, "plus", addElement, { tip = "Adaugă element" })
end, rightWidth = 28 })
```

**`UI.header(parent, title, opts) -> Frame`** — panel title (15 Bold) with optional `subtitle` (meta) and
`actions = { { icon, tip, onClick, active, danger } }` on the right. Use at most once, at the top of a panel that
needs a title (most panels do not: the tab says where you are).

**`UI.row(parent, label, opts) -> area`** — a 24 px row: dim label in a 96 px column, the controls share the rest.
opts: `labelWidth`, `height`. **`UI.hstack(parent, { height, gap = 8, fill = true })`**,
**`UI.vstack(parent, gap = 4)`**, **`UI.spacer(parent, h)`**, **`UI.divider(parent, { inset, vertical })`**.

### Text and feedback

**`UI.label(parent, text, opts) -> TextLabel`** — opts: `role`, `dim`, `color`, `wrap`, `rich`, `width`, `height`,
`align`, `bold` / `medium`, `size` (2.0 code; prefer `role`).

**`UI.note(parent, text, color?) -> Frame`** — quiet callout for a state that lasts (no module installed, no API key).
Rich text. `color` = `C.warning` / `C.danger` / `C.success` / `C.accent` (or `"warning"`, …) adds a 2 px bar on the
left; nil = neutral (dim text). No “⚠” in the text: the bar says it. Not for results of an action (toast).
```lua
UI.note(body, "Jocul nu are încă modulele LostCube.", C.warning)
```

**`UI.toast(text, kind?, opts?) -> { dismiss, frame }`** — message at the bottom of the window, gone after 4 s
(errors 6 s). kind: `"info"` (default), `"success"`, `"warning"`, `"error"`. opts: `duration` (0 = until closed),
`action = { text, onClick }` (one ghost button, e.g. undo). At most three at once. Use for the outcome of an action
(saved, installed, copied, failed).
```lua
UI.toast("Efectul a fost duplicat.", "success", { action = { text = "Anulează", onClick = undo } })
UI.toast("Cererea a eșuat: " .. err, "error")
```

**`UI.confirm(title, text, confirmText, onConfirm, opts) -> Frame`** — small modal (scrim, Cancel + action).
opts: `danger` (red action), `cancelText` (“Anulează”), `onCancel`. Escape / outside click cancel. Only for
destructive actions that Ctrl+Z cannot undo; for undoable ones act at once and offer “Anulează” in a toast.
```lua
UI.confirm("Ștergi cheia API?", "Va trebui să o introduci din nou.", "Șterge", deleteKey, { danger = true })
```

**`UI.empty(parent, text, actionText?, onAction?, opts?) -> Frame`** — empty state: one short sentence and at most one
primary action. opts: `icon` (glyph), `title`.
```lua
UI.empty(body, "Niciun efect încă.", "Efect nou", createEffect, { icon = "effects" })
```

**`UI.progress(parent, fraction, opts) -> track, set(fraction)`** — 4 px bar (opts: `height`, `color` token).
**`UI.badge(parent, text, kind?)`** — small pill (`"neutral"`, `"accent"`, `"success"`, `"warning"`, `"danger"`).
**`UI.tip(target, text)`** — tooltip after 0.45 s (most components take `opts.tip`).

### Buttons

**`UI.button(parent, text, onClick, opts) -> TextButton`** — styles (`opts.style`): `"primary"` (accent fill: one per
view, the main action), `"normal"` (default: Studio button with border), `"ghost"` (no fill until hover: tertiary),
`"danger"` (red text: destructive), `"destructive"` (red fill: only inside a confirm), `"link"` (accent text).
opts: `icon` (glyph, left of the text), `selected` (pressed-in), `disabled`, `width` / `scale` / `autoWidth`,
`height` (24; 28 for a primary call to action), `align`, `tip`. A button that has an icon left-aligns its text: give it
`autoWidth = true` or a width.
```lua
UI.button(bar, "Redă", play, { style = "primary", icon = "play" })
UI.button(bar, "Duplică", duplicate, { icon = "duplicate", autoWidth = true })
```

**`UI.iconButton(parent, glyph, onClick, opts) -> TextButton`** — 24 px square, glyph `textDim`, hover background.
opts: `tip` (always give one), `active` (toggled on: accent glyph on `accentSoft`), `danger` (red on hover),
`size`, `iconSize`, `color`, `disabled`. Named `IconButton_<glyph>`.

**`UI.chip(parent, text, opts) -> TextButton`** — pill for filters / tags: `selected`, `onClick`, `icon`,
`onRemove` (adds a close glyph), `tip`.

### Inputs

**`UI.textbox(parent, value, onChange(text, enter), opts) -> TextBox`** — field look, focus border. opts:
`placeholder`, `width`, `scale`, `mono`.

**`UI.number(parent, value, onChange(v), opts) -> TextBox`** — numeric field; Ctrl + wheel = ±step (Shift ×10), one
commit per gesture. opts: `min`, `max`, `step` (0.1), `decimals`, `unit` (dim suffix inside the field: `"s"`, `"°"`,
`"studs"`, `"/s"`), `width`, `tip`.

**`UI.scrub(parent, label, value, onChange(v), opts) -> row, box`** — a row whose *label* you drag left / right to
change the number (1 px = 1 step, Shift = step / 10), plus the number field. One `onChange` on release (one Ctrl+Z);
`opts.onInput(v)` while dragging for live preview. opts as `UI.number` + `labelWidth`. Use it instead of
`UI.number(UI.row(...))` for every continuous value.
```lua
UI.scrub(body, "Durată", fx.duration, setDuration, { min = 0.05, max = 10, step = 0.05, unit = "s" })
```

**`UI.slider(parent, value, onChange(v), opts) -> Frame`** — track + knob, value on the right. One `onChange` on
release, `onInput` while dragging. opts: `min` (0), `max` (1), `step` (0.01), `decimals`, `unit`, `field = true`
(editable number instead of the read-out), `valueWidth`. For bounded values where the position matters
(intensity, transparency, mix); unbounded values use `UI.scrub`.

**`UI.toggle(parent, value, onChange(newValue), text, opts) -> TextButton`** — a real switch with its label; the whole
row is clickable. Attribute `Checked` = state. opts: `width`, `scale`, `tip`, `disabled`. Never write “✓” in the text.
**`UI.switch(parent, value, onChange(newValue), opts)`** — the switch alone (in a row next to a label).

**`UI.segmented(parent, items, value, onChange)`** — 2–4 exclusive choices with short labels
(`items = { { value, label, tip } }`). More than 4, or long labels: a dropdown.

**`UI.dropdown(parent, items, value, onChange, opts) -> TextButton`** — select field: current label, chevron glyph;
the menu shows a check on the chosen item, group headers (`{ header = true, label }`), separators
(`{ separator = true }`), item glyphs (`icon`) or class icons (`classIcon = "ParticleEmitter"`), a dim `hint` on the
right, and a filter box above 14 items. opts: `placeholder`, `width`, `scale`, `menuWidth`, `tip`; an *action menu*
(a button that opens a list of things to add) is `opts.text = "Adaugă element"` + `style = "primary"`.
```lua
UI.dropdown(UI.row(body, "Prins de"), ATTACH_ITEMS, fx:GetAttribute("LC_Attach"), setAttach)
UI.dropdown(UI.hstack(body), presetItems, nil, addElement, { text = "Adaugă element", style = "primary", menuWidth = 240 })
```

**`UI.menu(anchor, items, opts)`** — a menu of actions under any button (`items = { label, icon, hint, danger,
disabled, onClick }`, separators, headers). Use with a `more` icon button for secondary row actions.

**`UI.search(parent, value, onChange(text), opts) -> frame, box`** — search field with glyph and clear button;
`onChange` after a 0.15 s pause, at once on Enter / clear. opts: `placeholder` (“Caută”), `width`, `delay`.

**`UI.color(parent, color, onChange(color), opts) -> TextButton`** — colour field (swatch + hex); opens
**`UI.colorPicker(anchor, color, onChange, opts)`**: saturation / value square, hue strip, hex field, recent colours
(`UI.recentColors`, saved by App). `onChange` on each choice (end of drag, Enter in hex, a recent swatch);
`opts.onInput` while dragging.

### Lists

**`UI.item(parent, text, opts) -> TextButton`** — 28 px row (24 with `height = 24` for dense lists): hover background;
selected = `accentSoft` background + 2 px accent bar on the left. opts: `selected`, `onClick`, `muted` (hidden /
disabled element: dim text and icon), `classIcon` (instance kind: `"ParticleEmitter"`, `"PointLight"`, `"Trail"`,
`"Beam"`, `"Sound"`, `"Part"`, `"Animation"`, `"KeyframeSequence"`, `"Script"`, `"Model"`, `"Folder"`, …), `icon`
(a glyph name), `note` (dim text on the right: `"7 el."`, `"1.2 s"`), `noteWidth`,
`actions = { { icon = "eye" / "eyeOff" / "duplicate" / "trash" / "more" …, tip, onClick, danger, active } }`.
```lua
UI.item(list, e.Name, { classIcon = CLASS[kind], selected = e == self.element, muted = muted,
	onClick = function() self.element = e; self:refresh() end,
	actions = {
		{ icon = muted and "eyeOff" or "eye", tip = muted and "Arată" or "Ascunde", onClick = toggleMute },
		{ icon = "duplicate", tip = "Duplică", onClick = duplicate },
		{ icon = "trash", tip = "Șterge", danger = true, onClick = remove },
	} })
```

**`UI.scrollList(parent, maxHeight) -> ScrollingFrame`** — a list that scrolls on its own past `maxHeight`.

**`UI.tabs(parent, items, value, onChange, opts)`** / **`UI.tabsMode(width, items)`** — the tab bar (App uses it;
see §6). `items = { { key, label, icon, tip } }`, `opts.mode`.

### Low level

`UI.make(class, props, children)`, `UI.corner(r)`, `UI.stroke(color|token, thickness)`, `UI.pad(t, r, b, l)`,
`UI.vlist(gap)`, `UI.hlist(gap, fill)`, `UI.icon(parent, glyph, { size, color, class, rotation, position, anchor })`,
`UI.skin(inst, map)`, `UI.textStyle(inst, role, weight)`, `UI.animate(inst, props, duration)`,
`UI.textWidth(text, role)`, `UI.popover(anchor, w, h)` (a raw floating surface), `UI.closePopup()`, `UI.busy()`,
`UI.escape(text)` (for rich text), `UI.fmt(v, decimals)`, `UI.setRoot(frame)` / `UI.release()` (App).

Popups (menus, picker, popovers, dialogs) always stay inside the window (they open above the anchor when there is no
room below) and close on a click outside or Escape.

## 8. Icons

`Icons.get(name)` / `UI.icon(parent, name)` / `opts.icon` take a glyph name; `Icons.class(className)` /
`opts.classIcon` take a class name (`StudioService:GetClassIcon`, falling back to Studio's own files).

| Glyph | Meaning | Glyph | Meaning |
|---|---|---|---|
| `chevronRight` / `chevronDown` / `chevronLeft` | expand, open menu, back | `caretRight` / `caretDown` | tree arrows |
| `plus` | add / new | `close` | close, remove from a list |
| `more` / `moreVertical` | more actions (menu) | `search` / `clear` | search field |
| `copy` | copy to clipboard | `duplicate` | duplicate an object |
| `paste` | paste | `trash` | delete |
| `undo` / `redo` | undo / redo | `refresh` | analyse again, reload |
| `check` | done / chosen | `filter` | filters |
| `history` | history / recent | `open` | open a file / script |
| `import` | import (Creator Store) | `locate` | select / show in the scene |
| `grid` / `list` | view modes | `play` / `pause` / `stop` | preview |
| `toStart` / `toEnd` | timeline ends | `eye` / `eyeOff` | shown / hidden |
| `info` | information | `help` | help |
| `gear` | settings | `bookmark` | favourite |
| `script` / `runScript` | a script / run code | `explorer` / `output` | Studio windows |
| `collapseAll` / `expandAll` | fold / unfold all | `placeholder` | unknown |
| `game` `effects` `animation` `library` `build` `chat` | the tabs | | |
| `infoColor` `successColor` `warningColor` `errorColor` | coloured status glyphs (toasts) | | |

Monochrome glyphs are tinted from tokens (`textDim` at rest, `text` on hover, `accent` when active/selected,
`danger` for destructive hover); coloured ones are used as they are. Shapes drawn from frames, for places without
images: `Icons.draw(parent, "chevron" | "plus" | "minus" | "close" | "check" | "dot" | "cube", size, color)`.

A new glyph: find it in `rbxManifest.txt` of MaximumADHD/Roblox-Client-Tracker (branch `roblox`), under
`content\studio_svg_textures\…` (Dark variant, monochrome #E0E0E0), add it to `Icons.GLYPHS` and to
`tests/suites/data/studio_icons.luau` (the `ui` suite rejects paths that are not there). Never an emoji or a Unicode
symbol instead.

## 9. Copy (Romanian)

- **Sentence case**, short: labels 1–3 words (“Durată”, “Prins de”, “Rată”), buttons a verb or verb + object
  (“Redă”, “Oprește”, “Duplică”, “Șterge”, “Instalează în joc”, “Analizează din nou”).
- **No emoji, no symbols as icons** (“✨ VFX”, “⚠ …”, “✓ Mod agent”, “📋”, “×”, “▶ Redă” → glyphs or nothing).
- **No exclamation marks.** No “magic”, “AI”, “inteligent”, “super”, “wow”. Claude is “Claude”.
- **Numbers with units**, a space before the unit: “1.3 s”, “120 /s”, “300 studs”, “45°”, “7 elemente”. Counts in
  section headers go to `badge`, not into the title (“Elemente” + badge 7, not “Elemente  (7)”).
- **Diacritics** with comma below: ș ț (not ş ţ); quotes „…”; ellipsis “…” for work in progress (“Analizez…”).
- **Messages**: what happened, then what to do, in one or two sentences. “Cererea a expirat. Încearcă efortul Rapid.”
  Not “Eroare!”, not stack traces in notes (warn() them, toast a short text).
- **Empty states**: one sentence + one action (“Niciun efect încă.” + “Efect nou”).
- **Tooltips** say what a control does, briefly; they are where longer explanations go, not notes.
- Long explanations (how API keys are billed, how to publish an animation) belong in a collapsed “Despre …” section
  or in the help popover, not in the main flow.

## 10. Migrating a 2.0 panel (checklist)

Every 2.0 call still works and already renders in the new style; these steps make a panel look native.

1. **Titles and labels**: remove emoji and symbols from section titles, buttons, notes, items, menu labels; move
   counts to `badge`; make labels sentence case and short (§9). Give every section a stable `key`.
2. **Item icons**: `icon = "◆"` / `"★"` / `KIND_ICON[kind]` → `classIcon = "<Class>"` (particles `ParticleEmitter`,
   lights `PointLight`, trails `Trail`, beams `Beam`, sounds `Sound`, meshes `Part`, camera `Camera`, animations
   `Animation` / `KeyframeSequence`, scripts `Script`, models `Model`, folders `Folder`). Dropdown items too.
3. **Row actions**: `{ text = "📋" }`, `"×"`, `"●/○"`, `"✓?"` → `{ icon = "duplicate" | "trash" | "eye"/"eyeOff",
   tip = …, danger = … }`. Two-click “✓?” confirmations: delete at once with a toast “Anulează” when Ctrl+Z restores
   it, else `UI.confirm`.
4. **Buttons**: “+ Efect nou” → `UI.button(bar, "Efect nou", fn, { style = "primary", icon = "plus" })`;
   “▶ Redă” / “⏸” / “⏹” → `icon = "play" / "pause" / "stop"` (icon buttons in a transport bar); one primary button
   per view; `bold` is ignored.
5. **Toggles**: keep `UI.toggle`; drop any “✓” from the text. Tests read `button:GetAttribute("Checked")`.
6. **Numbers**: `UI.number(UI.row(body, "X"), …)` → `UI.scrub(body, "X", …)` with `unit`; bounded 0–1 values →
   `UI.slider`. Panel-made sliders / progress bars → `UI.slider` / `UI.progress`.
7. **Search**: a `UI.textbox` used as a filter → `UI.search`.
8. **Notes**: `UI.note(p, "⚠ " .. err, C.warn)` after an action → `UI.toast(err, "error")`; keep `UI.note` only for
   states that last, without the symbol. Explanatory notes → tooltips or a collapsed “Despre …” section.
9. **Hand-made frames**: remove card fills (`C.section` / `C.item` + corner + stroke around groups). Use sections,
   rows and `UI.item`. Custom instances paint with tokens and `UI.skin`; text with `UI.textStyle`.
10. **No hard-coded colours** for UI (`Color3.fromRGB(110, 44, 50)`, violet `#9B5CFF` in rich text): tokens
    (`C.danger:ToHex()` in rich text is fine).
11. **Empty and error states**: `UI.empty` for “nothing here yet”; render errors are shown by App.
12. **Check it**: `python3 plugin/tests/run.py` and the preview renderer
    (`python3 plugin/tests/preview/render.py --tab VFX --theme dark|light --height full --out /tmp/x.png`),
    both themes, at 300 px and 360 px wide.

Tests that look for text: section titles are `"<uc>" .. title .. "</uc>"` (substring searches still match),
icon buttons are named `IconButton_<glyph>`, switches carry `Checked`, list rows `Selected`, tabs `Selected`.

## 11. Not verified without Studio

Checked against the API dump and the Studio file manifest, run in mocks and the preview renderer, but not yet in Studio:
the RichText `<uc>` tag, the exact `GetClassIcon` dictionary of the current Studio, Escape reaching a dock widget
(handled both through the window's own input and UserInputService), the real Studio theme colours behind each token,
and `TextService:GetTextSize` widths used to choose the tab-bar mode.
