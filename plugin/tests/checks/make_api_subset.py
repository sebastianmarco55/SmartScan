#!/usr/bin/env python3
"""Regenerates plugin/tests/data/api_subset.json (the small part of Roblox's API dump that the typed mock needs).

    python3 plugin/tests/checks/make_api_subset.py [path/to/API-Dump.json]

Without an argument the dump is taken from plugin/tests/.cache/API-Dump.json (run.py downloads it there).
Kept: the classes listed below, every class the Editor / VFX / Installer sources create or test for
(`Instance.new("X")`, `:IsA("X")`, `:FindFirstChildOfClass("X")`), the enums those sources and the test files use (`Enum.X.`) and the enums
that the properties of the kept classes have. Per class: the superclass chain and every property with its value type
("P:" primitive, "E:" enum, "C:" class, "D:" datatype / content) and ":ro" when it is read-only; per enum the items as
[name, value]. The mocks (tests/mocks/api_env.luau, vfx_env.luau) refuse properties, classes and enum items that are not
in this file: run this script again after the sources start using a new class.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
CLASSES = ["Instance", "ParticleEmitter", "Trail", "Beam", "Sound", "PointLight", "SpotLight", "SurfaceLight", "Part",
           "MeshPart", "Attachment", "Model", "Folder", "Decal", "Humanoid", "Tool", "Script", "LocalScript", "ModuleScript",
           "Fire", "Smoke", "Sparkles", "Explosion", "Configuration", "ColorCorrectionEffect", "WeldConstraint", "Camera",
           "Workspace", "StringValue"]
ENUMS = ["CollisionFidelity", "ExplosionType", "FinishRecordingOperation", "FluidFidelity", "FormFactor",
         "HumanoidCollisionType", "HumanoidDisplayDistanceType", "HumanoidHealthDisplayType", "HumanoidRigType", "InputType",
         "Material", "ModelLevelOfDetail", "ModelStreamingMode", "NameOcclusion", "NormalId", "PartType",
         "ParticleEmitterShape", "ParticleEmitterShapeInOut", "ParticleEmitterShapeStyle", "ParticleFlipbookLayout",
         "ParticleFlipbookMode", "ParticleOrientation", "PredictionMode", "RenderFidelity", "ResamplerMode", "RunContext",
         "SurfaceType", "TextureMode"]
CATEGORY = {"Primitive": "P", "Enum": "E", "Class": "C", "DataType": "D"}


SOURCES = ["Editor/init.luau", "Editor/VFX.luau", "Installer.luau"]
USED_CLASS = re.compile(r'(?:Instance\.new|:IsA|:FindFirstChildOfClass|:FindFirstAncestorOfClass)\(\s*"(\w+)"')
USED_ENUM = re.compile(r"\bEnum\.(\w+)\.")


def used_names():
    classes, enums = set(), set()
    for rel in SOURCES:
        path = os.path.join(os.path.dirname(TESTS), "LostCube", rel)
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as f:
                text = f.read()
            classes.update(USED_CLASS.findall(text))
            enums.update(USED_ENUM.findall(text))
    # enums the test files themselves name (Enum.SavedQualitySetting in a mock, ...)
    for sub in ("mocks", "suites", "lib"):
        base = os.path.join(TESTS, sub)
        for root, _, names in os.walk(base):
            for name in names:
                if name.endswith(".luau"):
                    with open(os.path.join(root, name), encoding="utf-8") as f:
                        enums.update(USED_ENUM.findall(f.read()))
    return classes, enums


def build(dump):
    by_name = {c["Name"]: c for c in dump["Classes"]}
    enums = {e["Name"]: [[i["Name"], i["Value"]] for i in sorted(e["Items"], key=lambda i: i["Value"])] for e in dump["Enums"]}
    used_classes, used_enums = used_names()
    wanted_classes = list(CLASSES) + sorted(c for c in used_classes if c in by_name and c not in CLASSES)
    out = {"classes": {}, "enums": {}}
    property_enums = set()
    for name in wanted_classes:
        chain, props = [], {}
        cls = name
        while cls and cls in by_name:
            chain.append(cls)
            cls = by_name[cls].get("Superclass")
            if cls == "<<<ROOT>>>":
                break
        for cls_name in reversed(chain):  # superclass first, like the mocks expect
            for member in by_name[cls_name]["Members"]:
                if member["MemberType"] == "Property":
                    vt = member["ValueType"]
                    kind = CATEGORY.get(vt["Category"], "D")
                    text = "%s:%s" % (kind, vt["Name"]) + (":ro" if "ReadOnly" in (member.get("Tags") or []) else "")
                    props[member["Name"]] = text
                    if kind == "E":
                        property_enums.add(vt["Name"])
        out["classes"][name] = {"chain": chain, "props": props}
    for name in sorted(set(ENUMS) | used_enums | property_enums):
        if name in enums:
            out["enums"][name] = enums[name]
    return out


def main():
    source = sys.argv[1] if len(sys.argv) > 1 else os.path.join(TESTS, ".cache", "API-Dump.json")
    with open(source, encoding="utf-8") as f:
        dump = json.load(f)
    result = build(dump)
    target = os.path.join(TESTS, "data", "api_subset.json")
    with open(target, "w", encoding="utf-8", newline="\n") as f:
        json.dump(result, f, indent=0, sort_keys=False, separators=(",", ":"))
        f.write("\n")
    print("wrote %s (%d classes, %d enums)" % (target, len(result["classes"]), len(result["enums"])))


if __name__ == "__main__":
    main()
