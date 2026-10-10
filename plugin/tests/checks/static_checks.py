"""Static steps of run.py: luau-compile, luau-analyze, API usage, multi-return and Lua-pattern checks, rbxmx build."""
import collections
import json
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

import apicheck
import contracts as contracts_check
import luau_tools
from common import FAIL, PASS, SKIP, Result

DUMP_URL = "https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/%s/API-Dump.json"
VERSION_URL = "https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/%s/version.txt"

# Globals that exist in Roblox but not in plain Luau: luau-analyze reports them as "Unknown global"
ROBLOX_GLOBALS = {
    "game", "workspace", "script", "plugin", "shared", "Instance", "Enum", "task", "warn", "wait", "spawn", "delay", "tick",
    "time", "elapsedTime", "settings", "UserSettings", "stats", "version", "printidentity", "typeof",
    "Vector3", "Vector2", "Vector3int16", "Vector2int16", "CFrame", "Color3", "BrickColor", "UDim", "UDim2", "Rect",
    "NumberRange", "NumberSequence", "NumberSequenceKeypoint", "ColorSequence", "ColorSequenceKeypoint", "TweenInfo",
    "RaycastParams", "OverlapParams", "PhysicalProperties", "DockWidgetPluginGuiInfo", "DateTime", "Random", "Ray",
    "Region3", "Region3int16", "Axes", "Faces", "Font", "PathWaypoint", "SharedTable", "CatalogSearchParams",
    "FloatCurveKey", "RotationCurveKey", "Content", "Secret",
}


def _run(cmd, cwd=None):
    proc = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return proc.returncode, proc.stdout.decode("utf-8", "replace")


def _luau_files(folder):
    out = []
    for root, _, names in os.walk(folder):
        for n in sorted(names):
            if n.endswith(".luau"):
                out.append(os.path.join(root, n))
    return sorted(out)


# --- compile -----------------------------------------------------------------------------------------------------------------

def compile_all(ctx, plugin, tests):
    """luau-compile on every plugin module and every test file: any syntax error fails."""
    compiler = ctx.tools["luau-compile"]
    groups = [("module", _luau_files(os.path.join(plugin, "LostCube")), plugin),
              ("test file", [f for sub in ("lib", "mocks", "suites") for f in _luau_files(os.path.join(tests, sub))], plugin)]
    problems, counts = [], []
    for label, files, cwd in groups:
        counts.append("%d %ss" % (len(files), label))
        for f in files:
            rel = os.path.relpath(f, cwd)
            code, out = _run([compiler, "--null", rel], cwd=cwd)
            if code != 0:
                problems.append(out.strip() or ("luau-compile failed on " + rel))
    if problems:
        return Result(FAIL, "syntax errors", "\n".join(problems))
    return Result(PASS, "compiled " + ", ".join(counts))


# --- analyze -----------------------------------------------------------------------------------------------------------------

DIAG = re.compile(r"^(?P<file>.+?)\((?P<line>\d+),(?P<col>\d+)(?:-\d+)?\): (?P<kind>\w+): (?P<msg>.*)$")


def is_noise(kind, msg):
    """Diagnostics that only mean "this is a Roblox program, not plain Luau"."""
    m = re.match(r"Unknown global '(\w+)'", msg)
    if m and kind in ("TypeError", "UnknownGlobal"):
        return m.group(1) in ROBLOX_GLOBALS
    if msg.startswith("Unknown type '") and kind in ("TypeError", "UnknownType"):
        return True  # Instance, BasePart, Color3 ... (types of the Roblox API)
    if msg.startswith("Type inference failed to complete"):
        return True  # the new solver gives up on the two biggest files because of the unknown Roblox globals
    return False


def analyze_all(ctx, plugin):
    analyzer = ctx.tools["luau-analyze"]
    files = [os.path.relpath(f, plugin).replace(os.sep, "/") for f in _luau_files(os.path.join(plugin, "LostCube"))]
    code, out = _run([analyzer] + files, cwd=plugin)
    real, noise, incomplete = [], 0, set()
    for line in out.splitlines():
        if not line.strip():
            continue
        m = DIAG.match(line)
        if not m:
            real.append(line)
            continue
        if is_noise(m.group("kind"), m.group("msg")):
            noise += 1
            if m.group("msg").startswith("Type inference failed"):
                incomplete.add(m.group("file"))
            continue
        real.append(line)
    if real:
        return Result(FAIL, "%d diagnostic(s)" % len(real), "\n".join(real))
    detail = "%d modules clean (%d Roblox-global diagnostics filtered" % (len(files), noise)
    if incomplete:
        detail += "; type inference incomplete in %s" % ", ".join(
            sorted(re.sub(r"^(\./)?LostCube/", "", f) for f in incomplete))
    return Result(PASS, detail + ")")


# --- baselines -----------------------------------------------------------------------------------------------------------------

def read_baseline(path):
    entries = collections.Counter()
    if os.path.isfile(path):
        for line in luau_tools.read_text(path).splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                entries[line] += 1
    return entries


def compare_baseline(found, baseline):
    """found: list of keys. Returns ({new key: how many}, {stale baseline key: how many}), multiset semantics."""
    have = collections.Counter(found)
    new, stale = {}, {}
    for key, n in have.items():
        if n > baseline.get(key, 0):
            new[key] = n - baseline.get(key, 0)
    for key, n in baseline.items():
        if n > have.get(key, 0):
            stale[key] = n - have.get(key, 0)
    return new, stale


def write_baseline(path, header, keys):
    lines = ["# " + l if l else "#" for l in header.strip().splitlines()] + [""]
    lines += sorted(keys)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def data_path(name):
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", name)


def _key_without_line(file, kind, message):
    return "%s: [%s] %s" % (file.replace(os.sep, "/"), kind, re.sub(r"\s+", " ", message).strip())


# --- cross-module contracts ----------------------------------------------------------------------------------------------------

def contracts(ctx, src):
    """Module.member uses across the plugin's files against what each module defines (see checks/contracts.py)."""
    problems, stats = contracts_check.check(src)
    if problems:
        return Result(FAIL, "%d undefined cross-module reference(s)" % len(problems), "\n".join(problems))
    return Result(PASS, "%(member uses)d module member uses and %(palette uses)d palette colours resolve across %(modules)d modules" % stats)


# --- API usage ---------------------------------------------------------------------------------------------------------------

def api_usage(ctx, src, cache):
    """Roblox API usage of the sources against API-Dump.json (downloaded into .cache/ on demand)."""
    ref = os.environ.get("ROBLOX_API_REF", "roblox")
    dump = os.environ.get("ROBLOX_API_DUMP") or os.path.join(cache, "API-Dump.json")
    if not os.path.isfile(dump):
        try:
            luau_tools.fetch(DUMP_URL % ref, dump)
        except Exception as e:
            return Result(SKIP, "API-Dump.json not available (%s); set ROBLOX_API_DUMP=<file> to run offline" % e)
    version = ""
    try:
        version_file = os.path.join(cache, "API-Dump.version")
        if not os.path.isfile(version_file):
            luau_tools.fetch(VERSION_URL % ref, version_file, attempts=1, timeout=30)
        version = luau_tools.read_text(version_file).strip()
    except Exception:
        pass
    issues, stats, resolved = apicheck.check(dump, src)
    baseline_path = data_path("api_usage_baseline.txt")
    deprecated = [(f, l, k, m) for f, l, k, m in issues if k == "deprecated"]
    checked = [(f, l, k, m) for f, l, k, m in issues if k != "deprecated"]
    keys = [_key_without_line(f, k, m) for f, l, k, m in checked]
    where = collections.defaultdict(list)
    for f, l, k, m in checked:
        where[_key_without_line(f, k, m)].append(l)
    if getattr(ctx, "update_baselines", False):
        write_baseline(baseline_path, API_BASELINE_HEADER, keys)
        return Result(PASS, "baseline written: %d finding(s) (Roblox %s)" % (len(keys), version or ref))
    new, stale = compare_baseline(keys, read_baseline(baseline_path))
    lines = ["NEW  %s%s   (line %s)" % (k, " x%d" % n if n > 1 else "", ", ".join(map(str, where[k]))) for k, n in new.items()]
    lines += ["stale baseline entry (fixed? remove it from data/api_usage_baseline.txt): " + k for k in stale]
    lines += ["note: deprecated API still in use: %s:%d %s" % (f, l, m) for f, l, k, m in deprecated]
    detail = "%d members resolved against Roblox %s; %d known finding(s), %d deprecated note(s)" % (
        resolved, version or ref, len(keys) - sum(new.values()), len(deprecated))
    if new:
        return Result(FAIL, "%d NEW finding(s); a false positive goes into data/api_usage_baseline.txt (--update-baselines)" % sum(new.values()),
                      "\n".join(lines))
    return Result(PASS, detail, "\n".join(lines))


API_BASELINE_HEADER = """
Known findings of checks/apicheck.py that were reviewed and accepted: the checker follows variables line by line, so a
variable reused for another class shows up as `no-member`. One line per finding (file, kind, message; no line numbers).
Rewrite with: python3 plugin/tests/run.py --only api-usage --update-baselines   (review the diff first!)
Deprecated-API uses are not listed here: the step prints them as notes.
"""

MULTIRET_BASELINE_HEADER = """
find() / gsub() calls that end an argument list, a table or a return list: their extra return values spill into
following parameters. These were reviewed: the callee ignores the extra values (checked at the time of writing).
Rewrite with: python3 plugin/tests/run.py --only multiret --update-baselines   (review the diff first!)
"""


# --- multi-return --------------------------------------------------------------------------------------------------------------

def _ast(tool, path):
    code, out = None, None
    proc = subprocess.run([tool, path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    # string constants carry raw bytes: latin-1 keeps every byte as one character
    return json.loads(proc.stdout.decode("latin-1"))


def _call_name(call):
    func = call.get("func", {})
    if func.get("type") == "AstExprIndexName":
        return func.get("index")
    if func.get("type") == "AstExprGlobal":
        return func.get("global")
    if func.get("type") == "AstExprLocal":
        return func["local"]["name"]
    return None


def find_multiret(tool, src):
    """[(file, line, message)] for the calls whose find() / gsub() result spills into following values."""
    found = []

    def flag(expr, context, fname):
        if isinstance(expr, dict) and expr.get("type") == "AstExprCall" and _call_name(expr) in ("gsub", "find"):
            line = int(expr["location"].split(",")[0]) + 1
            found.append((fname, line, "%s() multi-return as %s" % (_call_name(expr), context)))

    def walk(n, fname):
        if isinstance(n, dict):
            kind = n.get("type")
            if kind == "AstExprCall" and n.get("args"):
                flag(n["args"][-1], "last arg of %s()" % _call_name(n), fname)
            if kind == "AstStatReturn" and n.get("list"):
                flag(n["list"][-1], "last return value", fname)
            if kind == "AstExprTable" and n.get("items"):
                item = n["items"][-1]
                if item.get("kind") == "item":
                    flag(item["value"], "last table item", fname)
            for v in n.values():
                walk(v, fname)
        elif isinstance(n, list):
            for v in n:
                walk(v, fname)

    for path in _luau_files(src):
        walk(_ast(tool, path)["root"], os.path.relpath(path, src).replace(os.sep, "/"))
    return found


def multiret(ctx, src):
    """find() / gsub() return several values: as the LAST argument of a call, the last item of a table or the last
    return value they spill into the following parameters / items (the usual `add(x, string.find(...))` bug)."""
    tool = ctx.tools.get("luau-ast")
    if not tool:
        return Result(SKIP, "luau-ast not found")
    found = find_multiret(tool, src)
    baseline_path = data_path("multiret_baseline.txt")
    keys = ["%s: %s" % (f, msg) for f, line, msg in found]
    if getattr(ctx, "update_baselines", False):
        write_baseline(baseline_path, MULTIRET_BASELINE_HEADER, keys)
        return Result(PASS, "baseline written: %d entr(ies)" % len(keys))
    new, stale = compare_baseline(keys, read_baseline(baseline_path))
    where = collections.defaultdict(list)
    for f, line, msg in found:
        where["%s: %s" % (f, msg)].append(line)
    out = ["NEW  %s%s   (line %s)" % (k, " x%d" % n if n > 1 else "", ", ".join(map(str, where[k]))) for k, n in new.items()]
    out += ["stale baseline entry (fixed? remove it from data/multiret_baseline.txt): " + k for k in stale]
    if new:
        return Result(FAIL, "%d new multi-return spill(s): wrap the call in parentheses, e.g. (string.find(...))" % sum(new.values()),
                      "\n".join(out))
    return Result(PASS, "%d known, reviewed spill(s)" % len(found), "\n".join(out))


# --- Lua patterns --------------------------------------------------------------------------------------------------------------

PATTERN_FUNCS = {"find", "match", "gmatch", "gsub"}


def _lua_escape(text):
    return "".join("\\%03d" % ord(c) if (ord(c) < 32 or ord(c) >= 127 or c in "\\\"") else c for c in text)


def collect_patterns(tool, src):
    """{pattern bytes-as-latin-1 string: ["file:line", ...]} of every literal Lua pattern used with find/match/gmatch/gsub."""
    found = {}

    def literal(node):
        return node.get("value") if isinstance(node, dict) and node.get("type") == "AstExprConstantString" else None

    def walk(n, fname):
        if isinstance(n, dict):
            if n.get("type") == "AstExprCall":
                func, args = n.get("func", {}), n.get("args", [])
                if func.get("type") == "AstExprIndexName" and func.get("index") in PATTERN_FUNCS:
                    obj = func.get("expr", {})
                    on_string_lib = func.get("op") == "." and obj.get("type") == "AstExprGlobal" and obj.get("global") == "string"
                    pattern = literal(args[1]) if on_string_lib and len(args) > 1 else (literal(args[0]) if func.get("op") == ":" and args else None)
                    plain = func.get("index") == "find" and len(args) >= (4 if on_string_lib else 3) and \
                        isinstance(args[-1], dict) and args[-1].get("type") == "AstExprConstantBool" and args[-1].get("value")
                    if pattern is not None and not plain:
                        line = int(n["location"].split(",")[0]) + 1
                        found.setdefault(pattern, []).append("%s:%d" % (fname, line))
            for v in n.values():
                walk(v, fname)
        elif isinstance(n, list):
            for v in n:
                walk(v, fname)

    for path in _luau_files(src):
        walk(_ast(tool, path)["root"], os.path.relpath(path, src).replace(os.sep, "/"))
    return found


def run_patterns(luau, found, cache):
    """Runs every pattern once in the Luau VM. Returns (returncode, output)."""
    script = ["local bad = 0", "local function try(where, pattern)",
              "\tlocal ok, err = pcall(string.find, 'sample text\\n-- x [[y]] require(123456)', pattern)",
              "\tif not ok then bad += 1 print('BAD PATTERN', where, err) end", "end"]
    for pattern, where in found.items():
        script.append('try("%s", "%s")' % (where[0], _lua_escape(pattern)))
    script.append("print('checked', %d, 'bad', bad)" % len(found))
    script.append("if bad > 0 then error('malformed pattern(s)', 0) end")
    os.makedirs(os.path.join(cache, "gen"), exist_ok=True)
    path = os.path.join(cache, "gen", "patterns.luau")
    with open(path, "wb") as f:
        f.write("\n".join(script).encode("latin-1"))
    return _run([luau, path])


def patterns(ctx, src, luau, cache):
    """Every literal Lua pattern in the sources is run once: a malformed pattern ("malformed pattern (ends with '%')",
    unbalanced brackets ...) only fails at run time, on the path that uses it."""
    tool = ctx.tools.get("luau-ast")
    if not tool:
        return Result(SKIP, "luau-ast not found")
    found = collect_patterns(tool, src)
    code, out = run_patterns(luau, found, cache)
    if code != 0:
        return Result(FAIL, "malformed Lua pattern(s)", out)
    return Result(PASS, "%d distinct literal patterns (%d uses) are well formed" % (len(found), sum(len(v) for v in found.values())))


# --- the checkers check themselves ------------------------------------------------------------------------------------------

def selftest(ctx, cache):
    """Runs the static checkers on small files with known defects: a checker that stopped finding anything (a new Luau
    release changed luau-ast's JSON, a refactor broke a regex) must not turn into a silent PASS."""
    samples = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "samples")
    problems, notes = [], []

    # contracts: 2 wrong references in a sample plugin tree, 3 right ones
    found, stats = contracts_check.check(os.path.join(samples, "contracts"))
    wanted = {"Panel.luau:7: UI.buton is not defined by UI.luau", "Panel.luau:9: palette colour C.dangr does not exist in UI.C"}
    if set(found) != wanted:
        problems.append("contracts: expected %s, got %s" % (sorted(wanted), found))
    notes.append("contracts %d/%d" % (len(wanted & set(found)), len(wanted)))

    # multiret: three spills in the sample, the parenthesised and the plain calls are fine
    tool = ctx.tools.get("luau-ast")
    if tool:
        spills = find_multiret(tool, os.path.join(samples, "multiret"))
        if sorted(m for _, _, m in spills) != sorted(["find() multi-return as last arg of add()",
                                                       "gsub() multi-return as last return value",
                                                       "find() multi-return as last table item"]):
            problems.append("multiret: unexpected result %s" % spills)
        notes.append("multiret %d/3" % len(spills))
        pats = collect_patterns(tool, os.path.join(samples, "patterns"))
        code, out = run_patterns(ctx.tools["luau"], pats, cache)
        bad = out.count("BAD PATTERN")
        if len(pats) != 5 or bad != 2:
            problems.append("patterns: expected 5 patterns of which 2 malformed, got %d / %d\n%s" % (len(pats), bad, out))
        notes.append("patterns %d malformed of %d" % (bad, len(pats)))
    else:
        notes.append("luau-ast missing: multiret / patterns not self-tested")

    # apicheck: a file full of wrong Roblox API use (needs the dump)
    dump = os.environ.get("ROBLOX_API_DUMP") or os.path.join(cache, "API-Dump.json")
    if os.path.isfile(dump):
        issues, _, _ = apicheck.check(dump, os.path.join(samples, "api"))
        kinds = collections.Counter(k for _, _, k, _ in issues)
        missing = [k for k in ("service", "no-member", "value-type", "class", "enum") if not kinds.get(k)]
        if missing or len(issues) < 12:
            problems.append("apicheck: expected findings of kinds service / no-member / value-type / class / enum (>= 12), got %s" % dict(kinds))
        notes.append("apicheck %d findings" % len(issues))
    else:
        notes.append("no API dump: apicheck not self-tested")

    if problems:
        return Result(FAIL, "a checker stopped detecting known defects", "\n".join(problems))
    return Result(PASS, "; ".join(notes))


# --- build ------------------------------------------------------------------------------------------------------------------

def _items_tree(item):
    return (item.get("class"), item.find("Properties/string[@name='Name']").text,
            [_items_tree(c) for c in item.findall("Item")])


def build(ctx, plugin, src):
    """plugin/build.py to a temp file; the XML must parse and its tree of scripts must mirror plugin/LostCube."""
    with tempfile.TemporaryDirectory() as tmp:
        out_path = os.path.join(tmp, "LostCube.rbxmx")
        code, out = _run([sys.executable, os.path.join(plugin, "build.py"), out_path])
        if code != 0 or not os.path.isfile(out_path):
            return Result(FAIL, "build.py failed", out)
        raw = open(out_path, "rb").read()
        try:
            root = ET.fromstring(raw)
        except ET.ParseError as e:
            return Result(FAIL, "the built XML does not parse: %s" % e)
    problems = []
    if root.tag != "roblox" or root.get("version") != "4":
        problems.append("root element should be <roblox version=\"4\">, got <%s version=%s>" % (root.tag, root.get("version")))
    tops = root.findall("Item")
    if len(tops) != 1:
        problems.append("expected exactly one top-level Item, got %d" % len(tops))
        return Result(FAIL, "unexpected XML layout", "\n".join(problems))
    top = tops[0]

    referents = [i.get("referent") for i in root.iter("Item")]
    if len(set(referents)) != len(referents) or any(not re.fullmatch(r"RBX\d+", r or "") for r in referents):
        problems.append("referents are not unique RBX<number> values")

    # expected tree from the folder: init.server.luau = Script, init.luau = ModuleScript with children, NAME.luau = ModuleScript
    def expected(path, name):
        init_server, init_module = os.path.join(path, "init.server.luau"), os.path.join(path, "init.luau")
        cls = "Script" if os.path.exists(init_server) else "ModuleScript"
        kids = []
        for entry in sorted(os.listdir(path)):
            if entry.startswith("init."):
                continue
            full = os.path.join(path, entry)
            if os.path.isdir(full):
                kids.append(expected(full, entry))
            elif entry.endswith(".luau"):
                kids.append(("ModuleScript", entry[:-5], []))
        return (cls, name, kids)

    def shape(tree):  # compare as sets of children (build.py fixes a sibling order that the runner does not repeat)
        return (tree[0], tree[1], sorted(shape(k) for k in tree[2]))

    want, got = shape(expected(src, "LostCube")), shape(_items_tree(top))
    if want != got:
        problems.append("script tree differs from the folder:\n  folder: %s\n  xml:    %s" % (want, got))

    # every Source is the exact text of its file
    def check_sources(item, path):  # path: the folder of a module with children, else its .luau file
        name = item.find("Properties/string[@name='Name']").text
        if os.path.isdir(path):
            init_server = os.path.join(path, "init.server.luau")
            file = init_server if os.path.exists(init_server) else os.path.join(path, "init.luau")
        else:
            file = path
        source = item.find("Properties/ProtectedString[@name='Source']")
        if source is None:
            problems.append("%s has no Source" % name)
        else:
            with open(file, encoding="utf-8", newline="") as f:
                if (source.text or "") != f.read():
                    problems.append("Source of %s differs from %s" % (name, os.path.relpath(file, src)))
        for child in item.findall("Item"):
            child_name = child.find("Properties/string[@name='Name']").text
            sub = os.path.join(path, child_name)
            check_sources(child, sub if os.path.isdir(sub) else sub + ".luau")

    check_sources(top, src)
    count = sum(1 for _ in root.iter("Item"))
    if problems:
        return Result(FAIL, "build problems", "\n".join(problems))
    return Result(PASS, "built %d KB, %d scripts, tree and sources match the folder" % (len(raw) // 1024, count))


def rbxmx_fresh(ctx, plugin):
    """The committed plugin/LostCube.rbxmx must be what build.py makes from the current sources."""
    committed = os.path.join(plugin, "LostCube.rbxmx")
    if not os.path.isfile(committed):
        return Result(FAIL, "plugin/LostCube.rbxmx is not in the repository")
    with tempfile.TemporaryDirectory() as tmp:
        out_path = os.path.join(tmp, "LostCube.rbxmx")
        code, out = _run([sys.executable, os.path.join(plugin, "build.py"), out_path])
        if code != 0:
            return Result(FAIL, "build.py failed", out)
        fresh = open(out_path, "rb").read()
    old = open(committed, "rb").read()
    if fresh == old:
        return Result(PASS, "plugin/LostCube.rbxmx is up to date with the sources")
    return Result(FAIL, "plugin/LostCube.rbxmx is STALE: run `python3 plugin/build.py` and commit it",
                  "committed %d bytes, fresh build %d bytes" % (len(old), len(fresh)))
