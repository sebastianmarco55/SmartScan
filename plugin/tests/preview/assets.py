"""Fonts, Roblox content images and class icons for the preview (everything is cached in plugin/tests/.cache/preview/).

Roblox content (rbxasset://...) is downloaded file by file from the GitHub mirror MaximumADHD/Roblox-Client-Tracker (branch
"roblox"), where `rbxasset://textures/x.png` is `textures/x.png` and `rbxasset://studio_svg_textures/...` is
`studio-svg-textures/...`. The mirror has no fonts and no uploaded assets (rbxassetid://), those get a placeholder.
"""
import base64
import gzip
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
CACHE = os.path.join(TESTS, ".cache", "preview")
MIRROR = "https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/"
MIRROR_GIT = "https://github.com/MaximumADHD/Roblox-Client-Tracker"
INTER_URL = "https://raw.githubusercontent.com/rsms/inter/master/docs/font-files/InterVariable.ttf"

OFFLINE = False


def log(msg):
    print("[preview] " + msg, file=sys.stderr, flush=True)


def fetch(url, dest, timeout=60):
    """Downloads url to dest; returns True on success, False on 404 / network failure."""
    if OFFLINE:
        return False
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    last = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "lostcube-preview"})
            with urllib.request.urlopen(req, timeout=timeout) as resp, open(dest + ".part", "wb") as out:
                shutil.copyfileobj(resp, out)
            os.replace(dest + ".part", dest)
            return True
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return False
            last = e
        except Exception as e:  # noqa: BLE001 - network trouble: retry, then give up quietly
            last = e
    log("download failed (%s): %s" % (url, last))
    return False


# ---------------------------------------------------------------------------------------------------------------------
# fonts
# ---------------------------------------------------------------------------------------------------------------------
def _file_url(path):
    return "file://" + path.replace(os.sep, "/") if not path.startswith("/") else "file://" + path


def fonts_css():
    """@font-face rules: 'LC Sans' (Builder Sans stand-in) and 'LC Mono'.

    Order: your own Builder Sans files in plugin/tests/preview/fonts/ (BuilderSans-Regular.otf, -Medium, -Bold, -ExtraBold ...
    from a Roblox install: content/fonts), else Inter (downloaded once), else a system font."""
    rules = []
    own = os.path.join(HERE, "fonts")
    weights = {"thin": 100, "extralight": 200, "light": 300, "regular": 400, "medium": 500, "semibold": 600, "bold": 700,
               "extrabold": 800, "heavy": 900, "black": 900}
    found = []
    if os.path.isdir(own):
        for name in sorted(os.listdir(own)):
            m = re.match(r"(?i)^BuilderSans-?([A-Za-z]+?)(Italic)?\.(otf|ttf|woff2?)$", name)
            if m and m.group(1).lower() in weights:
                found.append((os.path.join(own, name), weights[m.group(1).lower()], bool(m.group(2))))
    if found:
        for path, weight, italic in found:
            rules.append("@font-face{font-family:'LC Sans';src:url('%s');font-weight:%d;font-style:%s}" % (
                _file_url(path), weight, "italic" if italic else "normal"))
        return "\n".join(rules) + "\n" + _mono_rule()
    inter = os.path.join(CACHE, "InterVariable.ttf")
    if not os.path.isfile(inter):
        fetch(INTER_URL, inter)
    if os.path.isfile(inter):
        rules.append("@font-face{font-family:'LC Sans';src:url('%s');font-weight:100 900}" % _file_url(inter))
    else:
        rules.append("@font-face{font-family:'LC Sans';src:local('Inter'),local('Inter Regular'),local('DejaVu Sans'),local('Arial');font-weight:100 900}")
    return "\n".join(rules) + "\n" + _mono_rule()


def _mono_rule():
    return ("@font-face{font-family:'LC Mono';src:local('JetBrains Mono'),local('Roboto Mono'),local('DejaVu Sans Mono'),"
            "local('Liberation Mono'),local('Menlo'),local('Consolas'),local('Courier New');font-weight:100 900}")


# ---------------------------------------------------------------------------------------------------------------------
# Roblox content images
# ---------------------------------------------------------------------------------------------------------------------
def png_size(path):
    with open(path, "rb") as f:
        head = f.read(32)
    if head[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", head[16:24])
    return None


class Images:
    """Resolves Image URLs of the dump. resolve(url) -> {"kind": "file", "src": data URI, "w", "h"} or a placeholder."""

    def __init__(self):
        self._tree = None
        self._memo = {}
        self.missing = []

    def _tree_index(self):
        """lower-case path -> real path of the mirror (made once with a tree-only clone, ~1 s)"""
        if self._tree is not None:
            return self._tree
        path = os.path.join(CACHE, "mirror-tree.txt.gz")
        if not os.path.isfile(path) and not OFFLINE:
            tmp = tempfile.mkdtemp(prefix="lc-mirror-")
            try:
                subprocess.run(["git", "clone", "--quiet", "--filter=blob:none", "--no-checkout", "--depth", "1", "--branch",
                                "roblox", MIRROR_GIT, os.path.join(tmp, "m")], check=True, timeout=300,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                out = subprocess.run(["git", "-C", os.path.join(tmp, "m"), "ls-tree", "-r", "--name-only", "HEAD"], check=True,
                                     stdout=subprocess.PIPE, timeout=120).stdout
                os.makedirs(CACHE, exist_ok=True)
                with gzip.open(path, "wb") as f:
                    f.write(out)
            except Exception as e:  # noqa: BLE001
                log("could not list the content mirror: %s" % e)
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
        index = {}
        if os.path.isfile(path):
            with gzip.open(path, "rt", encoding="utf-8") as f:
                for line in f:
                    line = line.rstrip("\n")
                    index[line.lower()] = line
        self._tree = index
        return index

    def _mirror_candidates(self, rel):
        parts = rel.split("/")
        if parts[0].lower() == "studio_svg_textures":
            parts[0] = "studio-svg-textures"
        rel = "/".join(parts)
        base, ext = os.path.splitext(rel)
        out = [rel]
        if ext:
            for e in (ext.upper(), ext.lower()):
                if base + e not in out:
                    out.append(base + e)
        return out

    def _local(self, rel):
        for cand in self._mirror_candidates(rel):
            dest = os.path.join(CACHE, "content", cand)
            if os.path.isfile(dest):
                return dest
        for cand in self._mirror_candidates(rel):
            dest = os.path.join(CACHE, "content", cand)
            if fetch(MIRROR + cand.replace(" ", "%20"), dest):
                return dest
        real = self._tree_index().get("/".join(self._mirror_candidates(rel)[0].split("/")).lower())
        if real:
            dest = os.path.join(CACHE, "content", real)
            if fetch(MIRROR + real.replace(" ", "%20"), dest):
                return dest
        return None

    def resolve(self, url):
        if url in self._memo:
            return self._memo[url]
        info = self._resolve(url)
        self._memo[url] = info
        return info

    def _resolve(self, url):
        m = re.match(r"(?i)^rbxasset://(.+)$", url)
        if m:
            path = self._local(m.group(1))
            if path:
                ext = os.path.splitext(path)[1].lower()
                mime = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml",
                        "webp": "image/webp"}.get(ext[1:])
                if mime:
                    size = png_size(path) or (0, 0)
                    with open(path, "rb") as f:
                        data = base64.b64encode(f.read()).decode("ascii")
                    return {"kind": "file", "src": "data:%s;base64,%s" % (mime, data), "w": size[0], "h": size[1]}
            self.missing.append(url)
            return {"kind": "placeholder", "label": m.group(1).rsplit("/", 1)[-1]}
        m = re.search(r"(?i)(?:rbxassetid://|[?&]id=|/asset/\?id=|/asset/)(\d+)", url)
        if m:
            return {"kind": "placeholder", "label": m.group(1)}
        return {"kind": "placeholder", "label": url[-24:]}


# ---------------------------------------------------------------------------------------------------------------------
# class icons (StudioService:GetClassIcon): ExplorerImageIndex of ReflectionMetadata.xml, 16x16 tiles of ClassImages.PNG
# ---------------------------------------------------------------------------------------------------------------------
def class_icons():
    """-> ({class name: tile index}, tiles per row of the sprite sheet)"""
    import json
    cached = os.path.join(CACHE, "class-icons.json")
    if os.path.isfile(cached):
        with open(cached, encoding="utf-8") as f:
            data = json.load(f)
        return data["icons"], data["columns"]
    sheet = os.path.join(CACHE, "content", "textures", "ClassImages.PNG")
    xml_path = os.path.join(CACHE, "ReflectionMetadata.xml")
    if not os.path.isfile(sheet):
        fetch(MIRROR + "textures/ClassImages.PNG", sheet)
    if not os.path.isfile(xml_path):
        fetch(MIRROR + "ReflectionMetadata.xml", xml_path)
    icons, columns = {}, 1000
    size = png_size(sheet) if os.path.isfile(sheet) else None
    if size:
        columns = max(1, size[0] // 16)
    if os.path.isfile(xml_path):
        try:
            root = ET.parse(xml_path).getroot()
            for item in root.iter("Item"):
                if item.get("class") != "ReflectionMetadataClass":
                    continue
                props = item.find("Properties")
                if props is None:
                    continue
                name = index = None
                for p in props:
                    if p.get("name") == "Name":
                        name = p.text
                    elif p.get("name") == "ExplorerImageIndex":
                        index = int(p.text)
                if name and index is not None:
                    icons[name] = index
        except Exception as e:  # noqa: BLE001
            log("could not read ReflectionMetadata.xml: %s" % e)
    if icons and size:
        os.makedirs(CACHE, exist_ok=True)
        with open(cached, "w", encoding="utf-8") as f:
            json.dump({"icons": icons, "columns": columns}, f)
    return icons, columns


# ---------------------------------------------------------------------------------------------------------------------
# the Chromium of Playwright
# ---------------------------------------------------------------------------------------------------------------------
def chromium_path():
    """The Chromium to launch: $PLAYWRIGHT_CHROMIUM, then the newest in $PLAYWRIGHT_BROWSERS_PATH (default /opt/pw-browsers,
    ~/.cache/ms-playwright). None: let Playwright find its own."""
    env = os.environ.get("PLAYWRIGHT_CHROMIUM")
    if env and os.path.isfile(env):
        return env
    roots = [os.environ.get("PLAYWRIGHT_BROWSERS_PATH"), "/opt/pw-browsers", os.path.expanduser("~/.cache/ms-playwright")]
    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        names = sorted((d for d in os.listdir(root) if d.startswith("chromium") and not d.startswith("chromium_headless")),
                       reverse=True)
        for d in names:
            for rel in ("chrome-linux/chrome", "chrome-linux64/chrome", "chrome-win/chrome.exe", "chrome-mac/Chromium.app/Contents/MacOS/Chromium"):
                p = os.path.join(root, d, rel)
                if os.path.isfile(p):
                    return p
    return None
