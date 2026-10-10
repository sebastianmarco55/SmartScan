#!/usr/bin/env python3
"""Builds plugin/LostCube.rbxmx from the Luau sources in plugin/LostCube/.

    python3 plugin/build.py            # writes plugin/LostCube.rbxmx
    python3 plugin/build.py out.rbxmx  # writes somewhere else

Copy the .rbxmx into Roblox Studio's Plugins folder (Studio > Plugins > Plugins Folder), or
right-click the Script in Explorer > "Save as Local Plugin...".
Folder layout -> instances: init.server.luau = Script, init.luau = ModuleScript (folder = its children),
NAME.luau = ModuleScript. SIBLING_ORDER below fixes the order of children (the XML must be stable).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "LostCube")
SIBLING_ORDER = ["UI", "App", "VFXPanel", "AnimPanel", "ClaudePanel", "Installer", "Editor"]

HEADER = ('<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
          'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
          'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">')

_next_id = 0


def cdata(text):
    return "<![CDATA[" + text.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def new_ref():
    global _next_id
    _next_id += 1
    return _next_id


def item(ref, cls, name, source, children):
    out = ['<Item class="%s" referent="RBX%d"><Properties><string name="Name">%s</string>'
           '<ProtectedString name="Source">%s</ProtectedString></Properties>' % (cls, ref, name, cdata(source))]
    out.extend(children)
    out.append("</Item>")
    return "".join(out)


def read(path):
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def build_dir(path, name, is_root=False):
    """A folder with an init file is an instance with children; plain files in it are its children."""
    ref = new_ref()  # pre-order, like Studio writes them
    init_server = os.path.join(path, "init.server.luau")
    init_module = os.path.join(path, "init.luau")
    if os.path.exists(init_server):
        cls, source = "Script", read(init_server)
    elif os.path.exists(init_module):
        cls, source = "ModuleScript", read(init_module)
    else:
        raise SystemExit("no init file in " + path)
    children = []
    names = set()
    for entry in os.listdir(path):
        if entry.startswith("init."):
            continue
        names.add(entry[:-len(".luau")] if entry.endswith(".luau") else entry)
    ordered = [n for n in SIBLING_ORDER if n in names] + sorted(n for n in names if n not in SIBLING_ORDER)
    for n in ordered:
        sub = os.path.join(path, n)
        if os.path.isdir(sub):
            children.append(build_dir(sub, n))
        else:
            children.append(item(new_ref(), "ModuleScript", n, read(sub + ".luau"), []))
    return item(ref, cls, name, source, children)


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "LostCube.rbxmx")
    xml = HEADER + build_dir(SRC, "LostCube", True) + "</roblox>"
    with open(out_path, "w", encoding="utf-8", newline="") as f:
        f.write(xml)
    print("wrote", out_path, "(%d bytes)" % len(xml.encode("utf-8")))


if __name__ == "__main__":
    main()
