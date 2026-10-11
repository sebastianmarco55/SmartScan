#!/usr/bin/env python3
"""Renders the REAL LostCube GUI (App + panels, executed by the Luau CLI on mock Roblox objects) to PNG screenshots.

    python3 plugin/tests/preview/render.py --tab VFX [--theme dark|light] [--width 360 --height 900]
                [--open section-key ...] [--close section-key ...] [--click "button text" ...]
                [--state demo|empty] [--out path.png] [--scale 2] [-v]
    python3 plugin/tests/preview/render.py --all        # every tab, both themes -> plugin/tests/preview/out/

How it works (see README.md): main.luau + scenes/<tab>.luau mount the real App on a lenient GUI mock with a demo place and dump
the GUI tree as JSON (gui.luau); htmlgen.py turns the JSON into HTML that reproduces Roblox's layout rules; Chromium (Playwright)
lays it out, measures every element (the next Luau pass answers AbsoluteSize / AbsoluteContentSize with those numbers, so
code that sizes itself from them behaves) and takes the screenshot.
"""
import argparse
import json
import math
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
PLUGIN = os.path.dirname(TESTS)
sys.path.insert(0, os.path.join(TESTS, "checks"))
sys.path.insert(0, HERE)

import luau_tools  # noqa: E402  (plugin/tests/checks/luau_tools.py: finds / downloads the Luau CLI, writes the generated suite files)
import assets  # noqa: E402
import htmlgen  # noqa: E402

TABS = ["VFX", "Anim", "Library", "Game", "Build", "Claude"]
ALIASES = {"selftest": "Selftest", "vfx": "VFX", "anim": "Anim", "animatii": "Anim", "library": "Library", "lib": "Library", "game": "Game", "joc": "Game",
           "build": "Build", "modelare": "Build", "claude": "Claude"}
OUT_DIR = os.path.join(HERE, "out")
THEME_BG = {"dark": "rgb(46,46,46)", "light": "rgb(255,255,255)"}
MAX_PASSES = 4


# ---------------------------------------------------------------------------------------------------------------------
# Luau
# ---------------------------------------------------------------------------------------------------------------------
class LuauRunner:
    """Collects the sources once, runs main.luau with different arguments."""

    def __init__(self, verbose=False):
        self.verbose = verbose
        self.tools, label = luau_tools.locate(os.path.join(TESTS, ".cache"), log=lambda m: print("[tools] " + m, file=sys.stderr))
        self.files = None
        self.icons, self.icon_columns = assets.class_icons()

    def _collect(self):
        import json as _json
        files = luau_tools.collect_files(PLUGIN, TESTS)
        subset = os.path.join(TESTS, "data", "api_subset.json")
        with open(subset, encoding="utf-8") as f:
            files["tests/data/api_subset.luau"] = "return " + luau_tools.to_luau(_json.load(f)) + "\n"
        pdir = HERE
        for root, dirs, names in os.walk(pdir):
            dirs[:] = [d for d in dirs if d not in ("out", "fonts", "__pycache__")]
            for n in names:
                if n.endswith(".luau"):
                    full = os.path.join(root, n)
                    files["tests/preview/" + os.path.relpath(full, pdir).replace(os.sep, "/")] = luau_tools.read_text(full)
        # modtree needs an init file in every folder of the plugin (a plain folder like LostCube/Modeling has none)
        dirs = set()
        for p in list(files):
            if p.startswith("LostCube/") and p.count("/") >= 2:
                d = p.rsplit("/", 1)[0]
                while d != "LostCube":
                    dirs.add(d)
                    d = d.rsplit("/", 1)[0]
        for d in dirs:
            files.setdefault(d + "/init.luau", "return nil\n")
        return files

    def run(self, args):
        if self.files is None:
            self.files = self._collect()
        files = dict(self.files)
        full = dict(args)
        full["classIcons"] = self.icons
        full["classIconColumns"] = self.icon_columns
        files["tests/preview/args.luau"] = "return " + luau_tools.to_luau(full) + "\n"
        gen = os.path.join(TESTS, ".cache", "gen", "preview-%s.luau" % os.getpid())
        luau_tools.write_suite_file(gen, files, "tests/preview/main.luau")
        try:
            code, output = luau_tools.run_suite(self.tools["luau"], gen, timeout=300)
        finally:
            try:
                os.remove(gen)
            except OSError:
                pass
        m = re.search(r"PREVIEW-JSON-BEGIN\n(.*)\nPREVIEW-JSON-END", output, re.S)
        if not m:
            raise RuntimeError("the Luau side failed (exit code %d):\n%s" % (code, output[-3000:]))
        return json.loads(m.group(1)), output[:m.start()]


# ---------------------------------------------------------------------------------------------------------------------
# browser
# ---------------------------------------------------------------------------------------------------------------------
class Browser:
    def __init__(self):
        self.p = self.b = None

    def __enter__(self):
        try:
            from playwright.sync_api import sync_playwright
        except ImportError:
            raise SystemExit("Python Playwright is needed:  pip install playwright   (the browser itself is not downloaded: "
                             "set PLAYWRIGHT_BROWSERS_PATH to a folder that has a chromium-* build, e.g. /opt/pw-browsers, "
                             "or PLAYWRIGHT_CHROMIUM=/path/to/chrome)")
        self.p = sync_playwright().start()
        exe = assets.chromium_path()
        kwargs = {"args": ["--font-render-hinting=none", "--disable-lcd-text", "--force-color-profile=srgb"]}
        if exe:
            kwargs["executable_path"] = exe
        self.b = self.p.chromium.launch(**kwargs)
        return self

    def __exit__(self, *exc):
        try:
            self.b.close()
        finally:
            self.p.stop()

    def layout(self, html_path, width, height, scale, png=None):
        """loads the page, lets page.js lay it out, returns the measurements; takes the screenshot when png is given"""
        ctx = self.b.new_context(viewport={"width": width, "height": height}, device_scale_factor=scale)
        try:
            page = ctx.new_page()
            page.goto("file://" + html_path)
            page.evaluate("document.fonts.ready.then(() => true)")
            page.evaluate("window.__layout()")
            measure = page.evaluate("window.__measure()")
            if png:
                page.screenshot(path=png, clip={"x": 0, "y": 0, "width": width, "height": height})
            return measure
        finally:
            ctx.close()


# ---------------------------------------------------------------------------------------------------------------------
# one picture
# ---------------------------------------------------------------------------------------------------------------------
def full_height(measure, height):
    """the widget height at which the page's scrolling area (the biggest ScrollingFrame; the small scroll lists inside keep
    their own scrolling) shows all its content; None when it already does"""
    scrolls = [e for e in measure.values() if "cvh" in e]
    if not scrolls:
        return None
    page = max(scrolls, key=lambda e: e["h"])
    if page["cvh"] <= page["h"] + 1:
        return None
    return min(8000, int(math.ceil(height + page["cvh"] - page["h"])))


def close_enough(a, b, tol=0.6):
    if a.keys() != b.keys():
        return False
    for k, ea in a.items():
        eb = b[k]
        for f in ("x", "y", "w", "h", "cw", "ch", "cvw", "cvh"):
            if abs(ea.get(f, 0) - eb.get(f, 0)) > tol:
                return False
    return True


def render_one(runner, browser, opts, png, images):
    started = time.time()
    full = opts["height"] == "full"
    height = 900 if full else int(opts["height"])
    args = {"tab": opts["tab"], "theme": opts["theme"], "width": opts["width"], "height": height, "state": opts["state"],
            "open": opts["open"], "close": opts["close"], "click": opts["click"], "hover": opts["hover"], "measure": {}}
    html_path = os.path.splitext(png)[0] + ".html"
    measure = {}
    passes = since_resize = 0
    fonts = assets.fonts_css()

    def pack(m):
        return {k: {"c": v["c"], **{f: v[f] for f in ("x", "y", "w", "h", "cw", "ch", "cvw", "cvh", "tw", "th") if f in v}}
                for k, v in m.items()}

    while True:
        passes += 1
        since_resize += 1
        args["measure"] = measure
        dump, noise = runner.run(args)
        gen = htmlgen.Generator(dump, opts["width"], height, THEME_BG[opts["theme"]], images)
        page = htmlgen.page(gen, fonts, THEME_BG[opts["theme"]])
        with open(html_path, "w", encoding="utf-8") as f:
            f.write(page)
        new = browser.layout(os.path.abspath(html_path), opts["width"], height, opts["scale"], png)
        if full:  # grow the widget until the tallest scrolling area shows all its content
            wanted = full_height(new, height)
            if wanted and wanted != height and passes < 2 * MAX_PASSES:
                height = args["height"] = wanted
                measure, since_resize = pack(new), 0
                continue
        if dump.get("measureReads", 0) == 0 or since_resize >= MAX_PASSES or passes >= 2 * MAX_PASSES or close_enough(new, measure):
            break
        measure = pack(new)
    elapsed = time.time() - started
    errors = dump.get("errors", [])
    tag = "%s/%s" % (opts["tab"], opts["theme"])
    if full:
        tag += " %dpx" % height
    print("%-14s %s  (%d element(s), %d pass(es), %.1fs)" % (tag, os.path.relpath(png, os.getcwd()), gen.count, passes, elapsed))
    for n in gen.notes[len(dump.get("notes", [])):]:
        print("   renderer: " + n)  # a node the HTML generator could not handle
    for e in errors:
        lines = e.splitlines()
        print("   Luau: " + lines[0][:300])
        if opts["verbose"]:
            for extra in lines[1:8]:
                print("         " + extra[:200])
    if opts["verbose"]:
        for n in dump.get("notes", []):
            print("   note: " + n)
        if dump.get("sections"):
            print("   sections (for --open / --close): " + ", ".join(k + (" (folded)" if v else "") for k, v in sorted(dump["sections"].items())))
        for url in images.missing:
            print("   content not found in the mirror: " + url)
        if noise.strip():
            print("   output: " + noise.strip()[-500:])
    return html_path


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="Render the LostCube GUI to PNG without Roblox Studio",
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("--tab", help="VFX | Anim | Library | Game | Build | Claude (default VFX)")
    ap.add_argument("--all", action="store_true", help="every tab, both themes, into plugin/tests/preview/out/")
    ap.add_argument("--theme", default=None, choices=["dark", "light"], help="Studio theme (default dark; --all: both)")
    ap.add_argument("--width", type=int, default=360)
    ap.add_argument("--height", default="900", help="widget height in px, or 'full' = tall enough for the whole content (default 900)")
    ap.add_argument("--full", action="store_true", help="same as --height full")
    ap.add_argument("--font-scale", type=float, default=None, metavar="N",
                    help="em of the text = TextSize / N (default 1.26, the line height of Builder Sans; 1 = em equals TextSize)")
    ap.add_argument("--scale", type=float, default=2.0, help="device scale factor of the screenshot (default 2)")
    ap.add_argument("--open", action="append", default=[], metavar="KEY", help="open the section with this key (title when it has no key); repeatable, commas allowed")
    ap.add_argument("--close", action="append", default=[], metavar="KEY", help="collapse a section")
    ap.add_argument("--click", action="append", default=[], metavar="TEXT", help="click the button showing this text (after the tab is shown); repeatable")
    ap.add_argument("--hover", action="append", default=[], metavar="TEXT", help="hover the button showing this text (hover colour, tooltip); repeatable")
    ap.add_argument("--state", default="demo", choices=["demo", "empty"], help="demo place (effects, report, clips, key, chat) or a fresh one")
    ap.add_argument("--out", help="output PNG (single render) or folder (--all)")
    ap.add_argument("--offline", action="store_true", help="do not download anything (fonts, Roblox content)")
    ap.add_argument("-v", "--verbose", action="store_true")
    return ap.parse_args(argv)


def split_multi(values):
    out = []
    for v in values:
        out += [p.strip() for p in v.split(",") if p.strip()]
    return out


def main(argv=None):
    args = parse_args(argv)
    assets.OFFLINE = args.offline
    htmlgen.FONT_DIVISOR = args.font_scale
    if args.full:
        args.height = "full"
    if args.height != "full":
        try:
            int(args.height)
        except ValueError:
            raise SystemExit("--height wants a number of pixels or 'full'")
    opening, closing = split_multi(args.open), split_multi(args.close)
    clicks = [c for c in args.click if c]
    runner = LuauRunner(args.verbose)
    images = assets.Images()
    jobs = []
    if args.all:
        out_dir = args.out or OUT_DIR
        os.makedirs(out_dir, exist_ok=True)
        for theme in ([args.theme] if args.theme else ["dark", "light"]):
            for tab in TABS:
                jobs.append((tab, theme, os.path.join(out_dir, "%s-%s.png" % (tab, theme))))
    else:
        tab = ALIASES.get((args.tab or "VFX").lower())
        if not tab:
            raise SystemExit("unknown tab %r (VFX, Anim, Library, Game, Build, Claude)" % args.tab)
        theme = args.theme or "dark"
        out = args.out or os.path.join(OUT_DIR, "%s-%s.png" % (tab, theme))
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        jobs.append((tab, theme, os.path.abspath(out)))
    with Browser() as browser:
        for tab, theme, png in jobs:
            opts = {"tab": tab, "theme": theme, "width": args.width, "height": args.height, "scale": args.scale,
                    "state": args.state, "open": opening, "close": closing, "click": clicks, "hover": [h for h in args.hover if h],
                    "verbose": args.verbose}
            try:
                render_one(runner, browser, opts, png, images)
            except RuntimeError as e:
                print("%s/%s FAILED\n%s" % (tab, theme, e), file=sys.stderr)
                return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
