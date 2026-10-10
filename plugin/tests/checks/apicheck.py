"""Static Roblox API check for the LostCube Luau sources, against API-Dump.json.

    python3 -I apicheck.py API-Dump.json SRC_DIR [--all] [--unbound]      (also imported by run.py: apicheck.check())

Extracts: Instance.new("Class") + props set on the bound variable, UI.make/make("Class", { Prop = ... }) tables,
Enum.X.Y, game:GetService("X"), service-variable member use, x:IsA("C") narrowed blocks, (x :: C).Prop,
FindFirstChildOfClass / WhichIsA bindings, Editor preset PascalCase keys (by kind). Checks against the dump:
unknown classes / members / enum items, writes to read-only or restricted members, deprecated members, wrong literal
value types. The variable tracking is line based, so a few findings are false positives (a variable reused for another
class): run.py compares the findings with data/api_usage_baseline.txt and fails only on new ones.
"""
import functools
import json
import os
import re
import sys
from collections import defaultdict

dump = None
SRC = None
SHOW_ALL = False
UNBOUND = False
CLASSES = {}
ENUMS = {}
OK_SECURITY = {"None", "PluginSecurity"}

def members(cls):
    out = {}
    while cls:
        c = CLASSES.get(cls)
        if not c:
            break
        for m in c["Members"]:
            out.setdefault(m["Name"], (cls, m))
        sup = c.get("Superclass")
        cls = sup if sup and sup != "<<<ROOT>>>" else None
    return out


MEMBERS = {}


def mem(cls):
    if cls not in MEMBERS:
        MEMBERS[cls] = members(cls)
    return MEMBERS[cls]


def is_a(cls, base):
    while cls:
        if cls == base:
            return True
        c = CLASSES.get(cls)
        cls = c.get("Superclass") if c else None
    return False


issues = []
unbound = []
stats = defaultdict(int)
seen_ok = defaultdict(int)


def report(file, line, kind, msg):
    issues.append((file, line, kind, msg))


def sec_str(sec):
    if isinstance(sec, dict):
        return sec
    return {"Read": sec, "Write": sec}


def check_member(file, line, classes, name, write=False, call=False, ctx=""):
    if isinstance(classes, str):
        classes = [classes]
    stats["member"] += 1
    found = []
    for cls in classes:
        if cls not in CLASSES:
            report(file, line, "unknown-class", f"{cls} (in {ctx})")
            return
        m = mem(cls).get(name)
        if m:
            found.append((cls, m))
    if not found:
        report(file, line, "no-member", f"{'/'.join(classes)}.{name} {'(write)' if write else ''} {ctx}")
        return
    for cls, (owner, m) in found:
        tags = m.get("Tags", []) or []
        sec = sec_str(m.get("Security", "None"))
        if write:
            if m["MemberType"] != "Property":
                report(file, line, "write-nonprop", f"{cls}.{name} is a {m['MemberType']}")
            if "ReadOnly" in tags:
                report(file, line, "read-only", f"{cls}.{name} is ReadOnly")
            if sec.get("Write") not in OK_SECURITY:
                report(file, line, "security", f"{cls}.{name} write needs {sec.get('Write')}")
        else:
            if sec.get("Read") not in OK_SECURITY:
                report(file, line, "security", f"{cls}.{name} read/call needs {sec.get('Read')}")
        if "NotScriptable" in tags:
            report(file, line, "not-scriptable", f"{cls}.{name}")
        if "Deprecated" in tags:
            report(file, line, "deprecated", f"{owner}.{name} ({m['MemberType']})")
        if call and m["MemberType"] not in ("Function", "Callback"):
            report(file, line, "call-nonfunction", f"{cls}.{name} is {m['MemberType']}")
        seen_ok[f"{owner}.{name}"] += 1
        return m
    return None


VALUE_KINDS = [
    (re.compile(r'^"(?:[^"\\]|\\.)*"$|^\'(?:[^\'\\]|\\.)*\'$'), "string"),
    (re.compile(r'^-?\d+(\.\d+)?$'), "number"),
    (re.compile(r'^(true|false)$'), "bool"),
    (re.compile(r'^Enum\.(\w+)\.(\w+)$'), "enum"),
    (re.compile(r'^(UDim2|UDim|Color3|Vector3|Vector2|CFrame|NumberRange|NumberSequence|ColorSequence|Rect|PhysicalProperties|Font)\.\w+'), "datatype"),
]


def check_value(file, line, cls, prop, value):
    m = mem(cls).get(prop)
    if not m or m[1]["MemberType"] != "Property":
        return
    vt = m[1].get("ValueType", {})
    value = value.strip().rstrip(",").strip()
    for rx, kind in VALUE_KINDS:
        mt = rx.match(value)
        if not mt:
            continue
        cat, tname = vt.get("Category"), vt.get("Name")
        stats["value"] += 1
        if kind == "string" and not (cat == "Primitive" and tname == "string" or tname in ("Content", "ContentId")):
            report(file, line, "value-type", f"{cls}.{prop} = string, wants {cat}:{tname}")
        elif kind == "number" and not (cat == "Primitive" and tname in ("float", "double", "int", "int64")):
            report(file, line, "value-type", f"{cls}.{prop} = number, wants {cat}:{tname}")
        elif kind == "bool" and not (cat == "Primitive" and tname == "bool"):
            report(file, line, "value-type", f"{cls}.{prop} = bool, wants {cat}:{tname}")
        elif kind == "enum" and not (cat == "Enum" and tname == mt.group(1)):
            report(file, line, "value-type", f"{cls}.{prop} = Enum.{mt.group(1)}, wants {cat}:{tname}")
        elif kind == "datatype":
            dt = mt.group(1)
            if not (cat == "DataType" and tname == dt):
                report(file, line, "value-type", f"{cls}.{prop} = {dt}.*, wants {cat}:{tname}")
        return


_INTERESTING = re.compile(r"[-\[\"'`]")
_LONG_OPEN = re.compile(r"\[(=*)\[")
_COMMENT_LONG_OPEN = re.compile(r"--\[(=*)\[")
_NOT_NEWLINE = re.compile(r"[^\n]")


@functools.lru_cache(maxsize=None)
def strip_comments(src):
    """Blank out comments and string contents (keeping quotes and newlines) so regexes see code only.
    Returns (code_without_comments_with_strings, code_with_blanked_strings)."""
    out_keep = []
    out_blank = []
    i, n = 0, len(src)
    while i < n:
        m = _INTERESTING.search(src, i)
        if not m:
            out_keep.append(src[i:])
            out_blank.append(src[i:])
            break
        if m.start() > i:  # plain code in between
            out_keep.append(src[i:m.start()])
            out_blank.append(src[i:m.start()])
            i = m.start()
        c = src[i]
        if src.startswith("--", i):
            lm = _COMMENT_LONG_OPEN.match(src, i)
            if lm:
                end = src.find("]" + lm.group(1) + "]", i)
                end = n if end < 0 else end + len(lm.group(1)) + 2
            else:
                end = src.find("\n", i)
                end = n if end < 0 else end
            seg = _NOT_NEWLINE.sub(" ", src[i:end])
            out_keep.append(seg)
            out_blank.append(seg)
            i = end
            continue
        lm = _LONG_OPEN.match(src, i)
        if lm:
            end = src.find("]" + lm.group(1) + "]", i)
            end = n if end < 0 else end + len(lm.group(1)) + 2
            seg = src[i:end]
            out_keep.append(seg)
            out_blank.append(_NOT_NEWLINE.sub(" ", seg))
            i = end
            continue
        if c in "\"'`":
            j = i + 1
            while j < n and src[j] != c:
                if src[j] == "\\":
                    j += 1
                if src[j] == "\n" and c != "`":
                    break
                j += 1
            seg = src[i:j + 1]
            out_keep.append(seg)
            out_blank.append(c + _NOT_NEWLINE.sub("_", seg[1:-1]) + c)
            i = j + 1
            continue
        out_keep.append(c)  # a lone "-" or "["
        out_blank.append(c)
        i += 1
    return "".join(out_keep), "".join(out_blank)


def table_keys(code, blank, start):
    """code[start] == '{' : returns [(key, value_text, offset)] for top-level `Key = value` entries and end offset."""
    depth = 0
    i = start
    n = len(code)
    entries = []
    entry_start = start + 1
    while i < n:
        c = blank[i]
        if c in "{([":
            depth += 1
        elif c in "})]":
            depth -= 1
            if depth == 0:
                entries.append(code[entry_start:i])
                break
        elif c == "," and depth == 1:
            entries.append(code[entry_start:i])
            entry_start = i + 1
        i += 1
    out = []
    off = start + 1
    for e in entries:
        m = re.match(r"\s*([A-Za-z_]\w*)\s*=(?!=)\s*(.*)$", e, re.S)
        if m:
            out.append((m.group(1), m.group(2).strip(), off))
        off += len(e) + 1
    return out, i


SERVICE_RX = re.compile(r'game:GetService\("(\w+)"\)')
ENUM_RX = re.compile(r'\bEnum\.(\w+)(?:\.(\w+)|\[)?')
NEW_RX = re.compile(r'Instance\.new\("(\w+)"')
MAKE_RX = re.compile(r'(?<![\w.])(?:UI\.)?make\("(\w+)",\s*\{')
LOCAL_BIND_RX = re.compile(r'^\s*local\s+(\w+)(?:\s*:\s*[\w?]+)?\s*=\s*(.*)$')
FIELD_BIND_RX = re.compile(r'^\s*((?:self|ctx|state)\.\w+)\s*=(?!=)\s*(.*)$')
ASSIGN_BIND_RX = re.compile(r'^\s*(\w+)\s*=\s*(Instance\.new\("(\w+)"\)|(?:UI\.)?make\("(\w+)")')
LOCAL_MULTI_RX = re.compile(r'^\s*local\s+([\w\s,]+?)\s*=')
FUNC_RX = re.compile(r'function\s*[\w.:]*\s*\(([^)]*)\)')
FOR_RX = re.compile(r'^\s*for\s+([\w\s,]+?)\s+(?:in|=)')
IF_ISA_RX = re.compile(r'^(\s*)(?:if|elseif)\s+(.*)\s+then\s*$')
ISA_RX = re.compile(r'(not\s+)?\b(\w+):IsA\("(\w+)"\)')
CAST_RX = re.compile(r'\(\s*(\w+)\s*::\s*(\w+)\s*\)\s*([.:])(\w+)')
USE_RX = re.compile(r'(?<![\w.:"])((?:(?:self|ctx|state)\.)?\w+)([.:])([A-Za-z_]\w*)(\s*(?:=(?!=)|\())?')
MULTI_ASSIGN_RX = re.compile(r'^\s*((?:\w+\.\w+\s*,\s*)+\w+\.\w+)\s*=(?!=)')
GLOBALS = {"workspace": "Workspace", "game": "DataModel", "plugin": "Plugin"}
NOT_INSTANCE_MEMBERS = set()


def bind_from_expr(expr, services):
    m = re.match(r'Instance\.new\("(\w+)"', expr)
    if m:
        return m.group(1)
    m = re.match(r'(?:UI\.)?make\("(\w+)"', expr)
    if m:
        return m.group(1)
    m = SERVICE_RX.match(expr)
    if m:
        return m.group(1)
    m = re.match(r'[\w.:]+:FindFirstChild(?:OfClass|WhichIsA)\("(\w+)"\)', expr)
    if m:
        return m.group(1)
    m = re.match(r'[\w.]+:FindFirstAncestorOfClass\("(\w+)"\)', expr)
    if m:
        return m.group(1)
    m = re.match(r'UI\.(button|toggle|dropdown)\(', expr)
    if m:
        return "TextButton"
    m = re.match(r'UI\.(label)\(', expr)
    if m:
        return "TextLabel"
    m = re.match(r'UI\.(textbox|number)\(', expr)
    if m:
        return "TextBox"
    m = re.match(r'UI\.(section|vstack|hstack|row|note|spacer)\(', expr)
    if m:
        return "Frame"
    m = re.match(r'UI\.(item)\(', expr)
    if m:
        return "TextButton"
    m = re.match(r'UI\.(scrollList)\(', expr)
    if m:
        return "ScrollingFrame"
    m = re.match(r'(\w+)\s*$', expr)
    if m and m.group(1) in services:
        return services[m.group(1)]
    return None


EL = ["ParticleEmitter", "Trail", "PointLight", "Part", "Beam", "Sound", "Configuration"]
HINTS = {
    "Editor/init.luau": {"element": EL, "e": EL, "copy": EL, "emitter": ["ParticleEmitter"], "part": ["Part"], "p": ["Part"],
        "t": ["Trail"], "l": ["PointLight"], "a": ["Attachment"], "b": ["Attachment", "Beam"], "att": ["Attachment"], "model": ["Model"],
        "effect": ["Model"], "fx": ["Model"], "root": ["Part"], "parent": ["Attachment", "Part"], "old": ["Attachment", "Part"],
        "d": ["ParticleEmitter", "Trail", "PointLight", "SpotLight"], "source": ["Model"], "holder": ["Model"], "sel": ["Model", "BasePart"],
        "cam": ["Camera"], "folder": ["Folder"]},
    "Editor/VFX.luau": {"p": ["Part"], "template": ["Part"], "t": ["Part"], "emitter": ["ParticleEmitter", "Trail"],
        "particles": ["ParticleEmitter"], "trail": ["Trail"], "follower": ["Part"], "root": ["BasePart"], "tw": ["Tween"],
        "model": ["Model"], "track": ["AnimationTrack"], "follow": ["BasePart"], "part": ["BasePart"], "humanoid": ["Humanoid"],
        "character": ["Model"], "hit": [], "a0": ["Attachment"], "a1": ["Attachment"]},
    "AnimPanel.luau": {"track": ["AnimationTrack"], "self.track": ["AnimationTrack"], "animator": ["Animator"],
        "self.animator": ["Animator"], "self.clip": ["KeyframeSequence"], "clip": ["KeyframeSequence"], "kfs": ["KeyframeSequence"],
        "kf": ["Keyframe"], "pose": ["Pose"], "m": ["Motor6D", "KeyframeMarker"], "self.rig": ["Model"], "rig": ["Model"],
        "model": ["Model"], "root": ["BasePart"], "target": ["Keyframe"], "self.timeLabel": ["TextLabel"], "box": ["TextBox"],
        "hit": ["TextButton"], "fill": ["Frame"], "knob": ["Frame"], "owner": ["Humanoid", "AnimationController"], "h": ["Humanoid"],
        "sel": ["Instance"], "d": ["Pose", "Motor6D"]},
    "LibraryPanel.luau": {"track": ["AnimationTrack"], "self.track": ["AnimationTrack"], "animator": ["Animator"],
        "self.animator": ["Animator"], "self.seq": ["KeyframeSequence"], "seq": ["KeyframeSequence"], "self.rig": ["Model"],
        "rig": ["Model"], "model": ["Model"], "root": ["BasePart"], "inst": ["Animation"], "existing": ["Script", "Model"],
        "created": ["Script"], "box": ["TextBox"], "list": ["ScrollingFrame"], "self.timeLabel": ["TextLabel"], "m": ["Motor6D"],
        "owner": ["Humanoid", "AnimationController"], "h": ["Humanoid"]},
    "AnimGen.luau": {"kfs": ["KeyframeSequence"], "kf": ["Keyframe"], "p": ["Pose"], "m": ["KeyframeMarker"], "d": ["Motor6D"],
        "hrp": ["BasePart"], "humanoid": ["Humanoid"], "root": ["Motor6D"], "hip": ["Motor6D"], "knee": ["Motor6D"],
        "ankle": ["Motor6D"], "leg": ["BasePart"], "saves": ["Model"], "entry": ["ObjectValue"], "rig": ["Model"]},
    "Analyzer.luau": {"e": ["ParticleEmitter"], "b": ["Beam", "Trail"], "f": ["Fire", "Smoke", "Sparkles", "Folder"],
        "s": ["Sound", "Script", "LocalScript", "ModuleScript"], "h": ["Humanoid"], "k": ["KeyframeSequence"], "kf": ["Keyframe"],
        "a": ["Animation"], "g": ["ScreenGui", "GuiObject"], "l": ["PointLight", "SpotLight", "SurfaceLight"], "d": ["Decal", "Texture"],
        "r": ["RemoteEvent"], "t": ["Tool"], "p": ["BasePart", "MeshPart"], "inst": ["Instance"], "child": ["Instance"],
        "v": ["StringValue"], "sp": ["StarterPlayer"], "character": ["Model"], "humanoid": ["Humanoid"], "players": ["Players"],
        "L": ["Lighting"], "sss": ["ServerScriptService"], "m": ["KeyframeMarker"], "parent": ["Instance"], "first": ["StringValue"]},
    "AnalysisPanel.luau": {"box": ["TextBox"], "inst": ["Instance"], "row": ["TextButton"], "sw": ["Frame"], "fill": ["Frame"],
        "storage": ["Folder"]},
    "ClaudePanel.luau": {"box": ["TextBox"], "mask": ["TextLabel"], "list": ["ScrollingFrame"], "self.chatList": ["ScrollingFrame"],
        "self.input": ["TextBox"], "self.sendButton": ["TextButton"], "label": ["TextLabel"], "inst": ["Instance"]},
    "Markdown.luau": {"box": ["TextBox"], "selectAll": ["TextButton"], "label": ["TextLabel"]},
    "VFXPanel.luau": {"box": ["TextBox"], "nameBox": ["TextBox"], "idBox": ["TextBox"]},
    "UI.luau": {"target": ["GuiObject"], "tipLabel": ["TextLabel"], "overlay": ["TextButton"], "root": ["Frame"], "b": ["TextButton"],
        "box": ["TextBox"], "row": ["TextButton"], "ab": ["TextButton"], "frame": ["TextButton"], "head": ["TextButton"],
        "arrow": ["TextLabel"], "body": ["Frame"], "sf": ["ScrollingFrame"], "layout": ["UIListLayout"], "anchor": ["GuiObject"],
        "input": ["InputObject"], "name": ["TextLabel"], "t": ["TextLabel"], "grid": ["Frame"], "sw": ["TextButton"]},
    "App.luau": {"self.scroll": ["ScrollingFrame"], "self.root": ["Frame"], "self.tabBar": ["Frame"], "self.content": ["Frame"],
        "child": ["Instance"], "folder": ["Folder"], "root": ["Folder"], "effects": ["Folder"], "storage": ["ServerStorage"]},
    "Installer.luau": {"root": ["Folder"], "copy": ["ModuleScript"], "old": ["Instance"], "child": ["Instance"]},
    "init.server.luau": {"toolbar": ["PluginToolbar"], "button": ["PluginToolbarButton"], "widget": ["DockWidgetPluginGui"],
        "playAction": ["PluginAction"], "stopAction": ["PluginAction"]},
}


def check_file(path):
    rel = os.path.relpath(path, SRC)
    hints = HINTS.get(rel, {})
    src = open(path, encoding="utf-8").read()
    code, blank = strip_comments(src)
    lines = code.split("\n")
    blines = blank.split("\n")
    line_starts = [0]
    for ln in lines:
        line_starts.append(line_starts[-1] + len(ln) + 1)

    def line_of(off):
        lo, hi = 0, len(line_starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if line_starts[mid] <= off:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    # services
    for m in SERVICE_RX.finditer(blank.replace('"', '"')):
        pass
    for m in SERVICE_RX.finditer(code):
        stats["service"] += 1
        name = m.group(1)
        c = CLASSES.get(name)
        if not c or "Service" not in (c.get("Tags") or []):
            report(rel, line_of(m.start()), "service", f"GetService({name}) not a service")
        elif "Deprecated" in (c.get("Tags") or []):
            report(rel, line_of(m.start()), "deprecated", f"service {name}")
    # enums (on blanked strings so text in strings is not taken)
    for m in ENUM_RX.finditer(blank):
        stats["enum"] += 1
        en, item = m.group(1), m.group(2)
        e = ENUMS.get(en)
        if en in ("FinishRecordingOperation",) and not e:
            pass
        if not e:
            report(rel, line_of(m.start()), "enum", f"Enum.{en} unknown")
            continue
        if "Deprecated" in (e.get("Tags") or []):
            report(rel, line_of(m.start()), "deprecated", f"Enum.{en}")
        if item:
            names = {i["Name"]: i for i in e["Items"]}
            legacy = set()
            for i in e["Items"]:
                for ln in i.get("LegacyNames", []) or []:
                    legacy.add(ln)
            if item in ("GetEnumItems", "FromName", "FromValue"):
                continue
            if item not in names:
                report(rel, line_of(m.start()), "enum", f"Enum.{en}.{item} unknown" + (" (legacy name)" if item in legacy else ""))
            elif "Deprecated" in (names[item].get("Tags") or []):
                report(rel, line_of(m.start()), "deprecated", f"Enum.{en}.{item}")
    # Instance.new creatable
    for m in NEW_RX.finditer(code):
        stats["new"] += 1
        cls = m.group(1)
        c = CLASSES.get(cls)
        if not c:
            report(rel, line_of(m.start()), "class", f"Instance.new({cls}) unknown class")
            continue
        tags = c.get("Tags") or []
        if "NotCreatable" in tags or "Service" in tags:
            report(rel, line_of(m.start()), "class", f"Instance.new({cls}) not creatable {tags}")
        if "Deprecated" in tags:
            report(rel, line_of(m.start()), "deprecated", f"class {cls}")
    # make("Class", { ... }) tables
    for m in MAKE_RX.finditer(code):
        stats["make"] += 1
        cls = m.group(1)
        if cls not in CLASSES:
            report(rel, line_of(m.start()), "class", f"make({cls}) unknown class")
            continue
        tags = CLASSES[cls].get("Tags") or []
        if "NotCreatable" in tags:
            report(rel, line_of(m.start()), "class", f"make({cls}) not creatable")
        keys, _ = table_keys(code, blank, m.end() - 1)
        for key, value, off in keys:
            if key == "Parent":
                continue
            check_member(rel, line_of(off), cls, key, write=True, ctx="make table")
            check_value(rel, line_of(off), cls, key, value)
    # line-based variable tracking
    binds = {}  # var -> [classes]
    services = {}
    narrow = []  # stack of (indent, var, classes, prev)
    for idx, (ln, bl) in enumerate(zip(lines, blines)):
        lineno = idx + 1
        stripped = bl.strip()
        if not stripped:
            continue
        indent = len(bl) - len(bl.lstrip("\t"))
        # leave narrowed blocks
        while narrow and indent < narrow[-1][0]:
            ind, var, prev = narrow.pop()
            if prev is None:
                binds.pop(var, None)
            else:
                binds[var] = prev
        # function params / for vars unbind
        for fm in FUNC_RX.finditer(bl):
            for p in fm.group(1).split(","):
                p = p.strip().split(":")[0].strip()
                if p and p != "...":
                    binds.pop(p, None)
        fm = FOR_RX.match(bl)
        if fm:
            for p in fm.group(1).split(","):
                binds.pop(p.strip(), None)
        # local bindings
        lm = LOCAL_BIND_RX.match(ln)
        if lm and "," not in ln.split("=")[0]:
            var, expr = lm.group(1), lm.group(2).strip()
            cls = bind_from_expr(expr, services)
            if cls:
                binds[var] = [cls]
                if SERVICE_RX.match(expr):
                    services[var] = cls
            else:
                binds.pop(var, None)
        else:
            mm = LOCAL_MULTI_RX.match(bl)
            if mm:
                for p in mm.group(1).split(","):
                    binds.pop(p.strip(), None)
            am = ASSIGN_BIND_RX.match(ln)
            if am:
                binds[am.group(1)] = [am.group(3) or am.group(4)]
        fb = FIELD_BIND_RX.match(ln)
        if fb:
            cls = bind_from_expr(fb.group(2).strip(), services)
            if cls:
                binds[fb.group(1)] = [cls]
            else:
                binds.pop(fb.group(1), None)
        # if x:IsA("C") then  -> narrowed block
        im = IF_ISA_RX.match(bl)
        if im:
            cond = ln[len(im.group(1)):]
            isas = ISA_RX.findall(cond)
            if isas and " or " not in cond.replace(" or (", " or ") or (isas and all(v == isas[0][1] for _, v, _ in isas)):
                byvar = defaultdict(list)
                for neg, var, cls in isas:
                    if not neg:
                        byvar[var].append(cls)
                for var, clist in byvar.items():
                    if " or " in cond and len(clist) > 1:
                        cl = clist
                    elif " or " in cond:
                        continue
                    else:
                        cl = clist[-1:]
                    narrow.append((indent + 1, var, binds.get(var)))
                    binds[var] = cl
        # casts
        for cm in CAST_RX.finditer(ln):
            var, cls, op, name = cm.groups()
            if cls in CLASSES:
                rest = ln[cm.end():]
                write = bool(re.match(r'\s*=(?!=)', rest)) and op == "."
                check_member(rel, lineno, cls, name, write=write, call=op == ":", ctx="cast")
        # multi assign a.X, b.Y = ...
        ma = MULTI_ASSIGN_RX.match(ln)
        multi_targets = set()
        if ma:
            for t in ma.group(1).split(","):
                v, p = t.strip().split(".")
                multi_targets.add((v, p))
                if v in binds:
                    check_member(rel, lineno, binds[v], p, write=True, ctx="multi-assign")
                elif v in GLOBALS:
                    check_member(rel, lineno, GLOBALS[v], p, write=True, ctx="multi-assign")
        # member uses
        for um in USE_RX.finditer(bl):
            var, op, name, tail = um.groups()
            if (var, name) in multi_targets:
                continue
            cls = binds.get(var) or ([GLOBALS[var]] if var in GLOBALS else None)
            hinted = False
            if not cls and hints.get(var) and name[:1].isupper():
                cls, hinted = hints[var], True
            if not cls:
                if UNBOUND and name[:1].isupper() and (op == ":" or (tail or "").strip().startswith("=")):
                    unbound.append(f"{rel}:{lineno}: {var}{op}{name}{'=' if op=='.' else '()'}")
                continue
            # skip common Luau/Roblox non-API names
            if name in ("Connect", "Once", "Wait", "Disconnect"):
                continue
            write = op == "." and tail is not None and tail.strip().startswith("=")
            call = op == ":"
            check_member(rel, lineno, cls, name, write=write, call=call, ctx=f"{var}{op}{name}")
            if write:
                val = ln[um.end():]
                check_value(rel, lineno, cls[0], name, val.split("--")[0])


def preset_check(path):
    """Editor presets/templates: PascalCase keys are set straight on the instance (setOne fallback)."""
    rel = os.path.relpath(path, SRC)
    src = open(path, encoding="utf-8").read()
    code, blank = strip_comments(src)
    # preset kind -> Roblox class whose properties its PascalCase keys set. A kind that is not listed (a new one, or one
    # that is not an Instance property bag, like CAMERA) is skipped rather than guessed.
    KIND = {"PARTICLES": "ParticleEmitter", "TRAIL": "Trail", "LIGHT": "PointLight", "MESH": "Part", "BEAM": "Beam",
            "SOUND": "Sound"}
    kinds = {}
    for m in re.finditer(r'\{\s*key\s*=\s*"(\w+)",[^{}]*?kind\s*=\s*"(\w+)",\s*props\s*=\s*\{', code):
        kinds[m.group(1)] = m.group(2)
        cls = KIND.get(m.group(2))
        if cls is None or cls not in CLASSES:
            continue
        keys, _ = table_keys(code, blank, m.end() - 1)
        for key, value, off in keys:
            if key[0].isupper() and not (cls == "Part" and key in ("Rate", "EmissionDirection")):
                stats["preset"] += 1
                ln = code.count("\n", 0, off) + 1
                check_member(rel, ln, cls, key, write=True, ctx=f"preset {m.group(1)}")
                vm = re.match(r'"(\w+)"', value)
                mm = mem(cls).get(key)
                if vm and mm and mm[1].get("ValueType", {}).get("Category") == "Enum":
                    en = mm[1]["ValueType"]["Name"]
                    if vm.group(1) not in {i["Name"] for i in ENUMS[en]["Items"]}:
                        report(rel, ln, "enum", f"preset {m.group(1)} {key}={vm.group(1)} not in Enum.{en}")
            if key in ("shape", "material") and cls == "Part":
                vm = re.match(r'"(\w+)"', value)
                en = "PartType" if key == "shape" else "Material"
                if vm and vm.group(1) not in {i["Name"] for i in ENUMS[en]["Items"]}:
                    report(rel, code.count("\n", 0, off) + 1, "enum", f"{key}={vm.group(1)} not in Enum.{en}")
            if key == "shape" and cls == "ParticleEmitter":
                vm = re.match(r'"(\w+)"', value)
                if vm and vm.group(1) not in {i["Name"] for i in ENUMS["ParticleEmitterShape"]["Items"]}:
                    report(rel, code.count("\n", 0, off) + 1, "enum", f"shape={vm.group(1)} not in ParticleEmitterShape")
    # template overrides el("PRESET", { ... })
    for m in re.finditer(r'\bel\("(\w+)",\s*\{', code):
        kind = kinds.get(m.group(1))
        if not kind:
            report(rel, code.count("\n", 0, m.start()) + 1, "preset", f"template uses unknown preset {m.group(1)}")
            continue
        cls = KIND.get(kind)
        if cls is None or cls not in CLASSES:
            continue
        keys, _ = table_keys(code, blank, m.end() - 1)
        for key, value, off in keys:
            if key[0].isupper() and not (cls == "Part" and key in ("Rate", "EmissionDirection")):
                stats["preset"] += 1
                ln = code.count("\n", 0, off) + 1
                check_member(rel, ln, cls, key, write=True, ctx=f"template el {m.group(1)}")


def check(dump_path, src_dir, show_all=False, unbound_flag=False):
    """Returns (issues, stats, distinct members resolved). issues: sorted list of (file, line, kind, message)."""
    global dump, SRC, SHOW_ALL, UNBOUND, CLASSES, ENUMS, MEMBERS
    with open(dump_path, encoding="utf-8") as f:
        dump = json.load(f)
    SRC = src_dir
    SHOW_ALL = show_all
    UNBOUND = unbound_flag
    CLASSES = {c["Name"]: c for c in dump["Classes"]}
    ENUMS = {e["Name"]: e for e in dump["Enums"]}
    MEMBERS = {}
    issues.clear()
    unbound.clear()
    stats.clear()
    seen_ok.clear()
    files = []
    for root, _, names in os.walk(SRC):
        for n in names:
            if n.endswith(".luau"):
                files.append(os.path.join(root, n))
    files.sort()
    for f in files:
        check_file(f)
        if f.endswith(os.path.join("Editor", "init.luau")):
            preset_check(f)
    return sorted(set(issues)), dict(stats), len(seen_ok)


if __name__ == "__main__":
    found, counts, resolved = check(sys.argv[1], sys.argv[2], "--all" in sys.argv, "--unbound" in sys.argv)
    print("stats:", counts)
    print("distinct API members resolved OK:", resolved)
    for f, l, k, msg in found:
        print(f"{f}:{l}: [{k}] {msg}")
    if "--all" in sys.argv:
        for k, v in sorted(seen_ok.items()):
            print("  ok", k, v)
    if "--unbound" in sys.argv:
        print("---- unbound PascalCase writes / method calls:", len(unbound))
        for u in unbound:
            print(u)
