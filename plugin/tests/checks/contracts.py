"""Cross-module contract check: every `Module.member` a LostCube file uses must be defined by that module.

The modules are developed side by side (panels call UI / Editor / Analyzer / AI / Tools ...). Luau only notices a renamed or
mistyped function when that line runs, which in a Studio plugin can be a rarely clicked button. This check reads the
sources (no execution): for each `local X = require(script.Parent.<Module>)` it collects the members the module defines
(`function M.name`, `M.name = ...`, keys of `local M = { ... }`) and reports `X.name` uses that no module defines.
It also checks the colour palette (`C.name` where `local C = UI.C`) and treats `Editor` / `ctx.Editor` /
`self.Editor` as the Editor module (the panels receive it through their context).
"""
import os
import re

import apicheck  # strip_comments / table_keys

REQUIRE = re.compile(r"\blocal\s+(\w+)\s*=\s*require\(\s*script\.(?:Parent\.)?(\w+)\s*\)(?!\s*[.:(\[])")
EDITOR_ALIAS = re.compile(r"(?<![\w.])(?:(?:self\.)?ctx\.|self\.)Editor\.(\w+)")
PALETTE_ALIAS = re.compile(r"\blocal\s+(\w+)\s*=\s*(\w+)\.C\b")


def _read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def _modules(src):
    """module name -> path of its source (Editor is Editor/init.luau, Editor.VFX is Editor/VFX.luau)."""
    out = {}
    for root, _, names in os.walk(src):
        for n in names:
            if not n.endswith(".luau") or n.startswith("init.server"):
                continue
            full = os.path.join(root, n)
            rel = os.path.relpath(full, src).replace(os.sep, "/")
            if rel == "Editor/init.luau":
                out["Editor"] = full
            elif "/" not in rel:
                out[n[:-5]] = full
            elif rel == "Editor/VFX.luau":
                out["Editor.VFX"] = full
    return out


def _line(code, offset):
    return code.count("\n", 0, offset) + 1


def _defined(path):
    """(members, open?) of the table a module returns. open = it also fills the table dynamically (skip checks)."""
    code, blank = apicheck.strip_comments(_read(path))
    returned = re.findall(r"^return\s+(\w+)\s*$", blank, re.M)
    if not returned:
        return set(), True
    var = returned[-1]
    members = set()
    dynamic = False
    for m in re.finditer(r"^\s*function\s+%s[.:](\w+)" % re.escape(var), blank, re.M):
        members.add(m.group(1))
    for m in re.finditer(r"(?<![\w.])%s\.(\w+)\s*=(?!=)" % re.escape(var), blank):
        members.add(m.group(1))
    if re.search(r"(?<![\w.])%s\s*\[[^\]]+\]\s*=(?!=)" % re.escape(var), blank) or re.search(r"setmetatable\(\s*%s\b" % re.escape(var), blank):
        dynamic = True
    ctor = re.search(r"^local\s+%s(?:\s*:[^=]+)?\s*=\s*\{" % re.escape(var), blank, re.M)
    if ctor:
        keys, _ = apicheck.table_keys(code, blank, ctor.end() - 1)
        members.update(k for k, _, _ in keys)
    return members, dynamic


def check(src):
    """Returns (problems, stats). problems: list of 'file:line: message'."""
    modules = _modules(src)
    defined = {name: _defined(path) for name, path in modules.items()}
    palette = set()
    ui_path = modules.get("UI")
    if ui_path:
        code, blank = apicheck.strip_comments(_read(ui_path))
        m = re.search(r"(?<![\w.])UI\.C\s*=\s*\{", blank)
        if m:
            keys, _ = apicheck.table_keys(code, blank, m.end() - 1)
            palette = {k for k, _, _ in keys}

    files = {name: _read(path) for name, path in modules.items()}
    paths = dict(modules)
    server = os.path.join(src, "init.server.luau")
    if os.path.isfile(server):
        files["init.server"] = _read(server)
        paths["init.server"] = server

    # members that consumers assign (UI.onCollapse = ... in App) are part of the module's surface
    assigned = {name: set() for name in modules}
    uses = []  # (file, line, module, member)
    palette_uses = []
    for fname, text in files.items():
        code, blank = apicheck.strip_comments(text)
        aliases = {}
        for m in REQUIRE.finditer(blank):
            if m.group(2) in modules and m.group(2) != fname:
                aliases[m.group(1)] = m.group(2)
        if fname != "Editor" and fname != "Editor.VFX":
            aliases.setdefault("Editor", "Editor")  # the panels get Editor through their context
        for alias, module in aliases.items():
            pattern = re.compile(r"(?<![\w.:\]])%s\s*([.:])\s*(\w+)(\s*=(?!=))?" % re.escape(alias))
            for m in pattern.finditer(blank):
                member, is_assign = m.group(2), bool(m.group(3)) and m.group(1) == "."
                if is_assign:
                    assigned[module].add(member)
                else:
                    uses.append((fname, _line(blank, m.start()), module, member))
        # self.Editor.x / ctx.Editor.x
        if fname not in ("Editor", "Editor.VFX"):
            for m in EDITOR_ALIAS.finditer(blank):
                uses.append((fname, _line(blank, m.start()), "Editor", m.group(1)))
        for m in PALETTE_ALIAS.finditer(blank):
            if aliases.get(m.group(2)) == "UI" or m.group(2) == "UI":
                pal_alias = m.group(1)
                for u in re.finditer(r"(?<![\w.:\]])%s\.(\w+)" % re.escape(pal_alias), blank):
                    palette_uses.append((fname, _line(blank, u.start()), u.group(1)))

    problems, seen = [], set()
    for fname, line, module, member in uses:
        members, dynamic = defined[module]
        if dynamic or member in members or member in assigned[module]:
            continue
        key = (fname, line, module, member)
        if key in seen:
            continue
        seen.add(key)
        problems.append("%s:%d: %s.%s is not defined by %s" % (os.path.relpath(paths[fname], src).replace(os.sep, "/"), line, module, member,
                                                               os.path.relpath(modules[module], src).replace(os.sep, "/")))
    if palette:
        for fname, line, member in palette_uses:
            if member not in palette:
                key = (fname, line, "C", member)
                if key not in seen:
                    seen.add(key)
                    problems.append("%s:%d: palette colour C.%s does not exist in UI.C" % (
                        os.path.relpath(paths[fname], src).replace(os.sep, "/"), line, member))
    stats = {"modules": len(modules), "member uses": len(uses), "palette uses": len(palette_uses)}
    return sorted(problems), stats
