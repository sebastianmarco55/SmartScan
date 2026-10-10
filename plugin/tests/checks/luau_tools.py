"""Finds (or downloads) the Luau command line tools and runs Luau test suites with them.

Order: $LUAU_BIN_DIR, then PATH, then plugin/tests/.cache/luau, then a download of the latest release of
luau-lang/luau (luau-ubuntu.zip / luau-macos.zip / luau-windows.zip) into that cache folder.
$LUAU_VERSION=<tag> pins a release instead of "latest" (for example LUAU_VERSION=0.700).
"""
import os
import shutil
import stat
import subprocess
import sys
import time
import urllib.request
import zipfile

REQUIRED = ("luau", "luau-analyze", "luau-compile")
OPTIONAL = ("luau-ast",)


def _exe(name):
    return name + (".exe" if sys.platform == "win32" else "")


def _asset():
    if sys.platform.startswith("linux"):
        return "luau-ubuntu.zip"
    if sys.platform == "darwin":
        return "luau-macos.zip"
    if sys.platform == "win32":
        return "luau-windows.zip"
    raise SystemExit("no Luau release asset known for platform " + sys.platform)


def _find_in(directory):
    found = {}
    for name in REQUIRED + OPTIONAL:
        path = os.path.join(directory, _exe(name))
        if os.path.isfile(path):
            found[name] = path
    return found


def _find_on_path():
    found = {}
    for name in REQUIRED + OPTIONAL:
        path = shutil.which(name)
        if path:
            found[name] = path
    return found


def fetch(url, target, attempts=3, timeout=180):
    """Downloads url to target (three tries: GitHub's CDN sometimes drops a connection)."""
    last = None
    for attempt in range(attempts):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "lostcube-tests"})
            with urllib.request.urlopen(request, timeout=timeout) as response, open(target + ".part", "wb") as out:
                shutil.copyfileobj(response, out)
            os.replace(target + ".part", target)
            return
        except Exception as e:  # noqa: BLE001 - any network problem is retried, the last one is raised
            last = e
            time.sleep(2 * (attempt + 1))
    raise last


def download(cache_dir, log=print):
    version = os.environ.get("LUAU_VERSION", "").strip()
    asset = _asset()
    if version:
        url = "https://github.com/luau-lang/luau/releases/download/%s/%s" % (version, asset)
    else:
        url = "https://github.com/luau-lang/luau/releases/latest/download/" + asset
    target = os.path.join(cache_dir, "luau")
    os.makedirs(target, exist_ok=True)
    zip_path = os.path.join(cache_dir, asset)
    log("downloading %s" % url)
    fetch(url, zip_path)
    with zipfile.ZipFile(zip_path) as archive:
        for member in archive.namelist():
            base = os.path.basename(member)
            if base in [_exe(n) for n in REQUIRED + OPTIONAL]:
                with archive.open(member) as src, open(os.path.join(target, base), "wb") as dst:
                    shutil.copyfileobj(src, dst)
                os.chmod(os.path.join(target, base), os.stat(os.path.join(target, base)).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    os.remove(zip_path)
    try:  # remember which release this is (the "latest" redirect ends in .../tag/<version>)
        probe = urllib.request.Request("https://github.com/luau-lang/luau/releases/latest", headers={"User-Agent": "lostcube-tests"})
        with urllib.request.urlopen(probe, timeout=30) as response:
            tag = response.geturl().rstrip("/").rsplit("/", 1)[-1]
        with open(os.path.join(target, "VERSION"), "w") as f:
            f.write(version or tag)
    except Exception:
        pass
    return target


def locate(cache_dir, log=print):
    """Returns {tool name: path}. Raises SystemExit with a clear message when the tools cannot be found."""
    sources = []
    env_dir = os.environ.get("LUAU_BIN_DIR")
    if env_dir:
        sources.append(("$LUAU_BIN_DIR", _find_in(env_dir)))
        if not all(n in sources[-1][1] for n in REQUIRED):
            raise SystemExit("LUAU_BIN_DIR=%s does not contain %s" % (env_dir, ", ".join(REQUIRED)))
    else:
        sources.append(("PATH", _find_on_path()))
        sources.append(("cache", _find_in(os.path.join(cache_dir, "luau"))))
    for label, tools in sources:
        if all(n in tools for n in REQUIRED):
            return tools, label
    try:
        download(cache_dir, log)
    except Exception as e:  # network down, release moved...
        raise SystemExit(
            "Luau tools not found and the download failed (%s).\n"
            "Install them from https://github.com/luau-lang/luau/releases (luau-ubuntu.zip) and set LUAU_BIN_DIR." % e)
    tools = _find_in(os.path.join(cache_dir, "luau"))
    if not all(n in tools for n in REQUIRED):
        raise SystemExit("the downloaded Luau archive does not contain " + ", ".join(REQUIRED))
    return tools, "downloaded"


def version_of(tools):
    """Best effort: the release tag written by download(), else the path."""
    path = tools["luau"]
    marker = os.path.join(os.path.dirname(path), "VERSION")
    if os.path.isfile(marker):
        return open(marker).read().strip()
    return os.path.dirname(path)


# --- test files -------------------------------------------------------------------------------------------------------

def long_string(text):
    """Text as a Lua long string literal that cannot be closed by the text itself."""
    n = 0
    while "]" + "=" * n + "]" in text:
        n += 1
    bar = "=" * n
    return "[" + bar + "[\n" + text + "\n]" + bar + "]"


def to_luau(value, indent=0):
    """A JSON-like Python value as a Luau table literal."""
    if value is None:
        return "nil"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        out = []
        for ch in value:
            if ch == "\\" or ch == '"':
                out.append("\\" + ch)
            elif ord(ch) < 32 or ord(ch) == 127:
                out.append("\\%03d" % ord(ch))
            else:
                out.append(ch)
        return '"' + "".join(out) + '"'
    if isinstance(value, list):
        return "{" + ", ".join(to_luau(v) for v in value) + "}"
    if isinstance(value, dict):
        return "{" + ", ".join("[%s] = %s" % (to_luau(k), to_luau(v)) for k, v in value.items()) + "}"
    raise TypeError(type(value))


def read_text(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8")


def collect_files(plugin_dir, tests_dir):
    """path -> text of every file a suite can load: the REAL sources (LostCube/...) and the test support files."""
    files = {}
    src_root = os.path.join(plugin_dir, "LostCube")
    for root, _, names in os.walk(src_root):
        for name in sorted(names):
            if name.endswith(".luau"):
                full = os.path.join(root, name)
                files["LostCube/" + os.path.relpath(full, src_root).replace(os.sep, "/")] = read_text(full)
    for sub in ("lib", "mocks", "suites"):
        base = os.path.join(tests_dir, sub)
        for root, _, names in os.walk(base):
            for name in sorted(names):
                if name.endswith(".luau"):
                    full = os.path.join(root, name)
                    files["tests/" + os.path.relpath(full, tests_dir).replace(os.sep, "/")] = read_text(full)
    return files


def write_suite_file(path, files, suite_path):
    parts = ["local FILES = {}\n"]
    for name in sorted(files):
        parts.append("FILES[%s] = %s\n" % (to_luau(name), long_string(files[name])))
    parts.append("local boot = loadstring(FILES[\"tests/lib/boot.luau\"], \"@tests/lib/boot.luau\")\n")
    parts.append("boot(FILES, %s)\n" % to_luau(suite_path))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write("".join(parts).encode("utf-8"))


def run_suite(luau, generated, timeout=600):
    """Runs one generated suite file. Returns (returncode, output)."""
    try:
        proc = subprocess.run([luau, generated], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        return proc.returncode, proc.stdout.decode("utf-8", "replace")
    except subprocess.TimeoutExpired as e:
        return 124, (e.stdout or b"").decode("utf-8", "replace") + "\nTIMEOUT after %ds" % timeout
