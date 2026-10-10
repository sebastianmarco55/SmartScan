#!/usr/bin/env python3
"""LostCube test runner (Python 3 standard library only).

    python3 plugin/tests/run.py                  # everything
    python3 plugin/tests/run.py --only ai,build  # some steps (names: see --list; groups: static, suites)
    python3 plugin/tests/run.py --list
    python3 plugin/tests/run.py -v               # show the output of passing steps too

Steps, in order (see plugin/tests/README.md):
  compile, analyze        luau-compile and luau-analyze on every module (Roblox-global noise filtered)
  <suite> ...             one step per plugin/tests/suites/<name>.test.luau, run by the Luau CLI against the REAL sources
  contracts               Module.member references across the plugin's files
  api-usage               Roblox API usage of the sources against API-Dump.json (downloaded into .cache/ on demand)
  multiret, patterns      find()/gsub() multi-return spills, malformed Lua patterns
  selftest                the static checkers must still detect known defects (data/samples/)
  build, rbxmx-fresh      plugin/build.py to a temp file + XML / module tree check; the committed .rbxmx is up to date

Exit code 0 only if every selected step passed. Luau tools: $LUAU_BIN_DIR, PATH, or a download into .cache/.
"""
import argparse
import concurrent.futures
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.dirname(HERE)
SRC = os.path.join(PLUGIN, "LostCube")
CACHE = os.path.join(HERE, ".cache")
sys.path.insert(0, os.path.join(HERE, "checks"))

import luau_tools  # noqa: E402
from common import FAIL, PASS, SKIP, Result  # noqa: E402


class Context:
    def __init__(self, tools, tools_label):
        self.tools = tools
        self.tools_label = tools_label
        self.update_baselines = False
        self._files = None

    def files(self):
        if self._files is None:
            self._files = luau_tools.collect_files(PLUGIN, HERE)
            # the API-dump subset as a Luau table for the typed Roblox mock
            import json
            subset = os.path.join(HERE, "data", "api_subset.json")
            with open(subset, encoding="utf-8") as f:
                self._files["tests/data/api_subset.luau"] = "return " + luau_tools.to_luau(json.load(f)) + "\n"
        return self._files


# --- steps ---------------------------------------------------------------------------------------------------------------

def suite_names():
    folder = os.path.join(HERE, "suites")
    return sorted(n[:-len(".test.luau")] for n in os.listdir(folder) if n.endswith(".test.luau"))


def run_suite_step(name):
    def step(ctx):
        out_path = os.path.join(CACHE, "gen", name + ".luau")
        luau_tools.write_suite_file(out_path, ctx.files(), "tests/suites/%s.test.luau" % name)
        code, output = luau_tools.run_suite(ctx.tools["luau"], out_path)
        match = re.search(r"^LC-RESULT (\S+) passed=(\d+) failed=(\d+)\s*$", output, re.M)
        extra = ""
        if "BODY>>>" in output:  # the ai_agent suite prints the request bodies: re-validate them with Python's json
            import validate_bodies
            problems, count = validate_bodies.validate(output)
            if problems:
                return Result(FAIL, "%d request-body problem(s)" % len(problems), "\n".join(problems))
            extra = ", %d request bodies valid" % count
            output = re.sub(r"BODY>>>.*?<<<BODY\n?", "", output, flags=re.S)  # (huge, and already validated)
        if code == 0 and match and int(match.group(3)) == 0:
            return Result(PASS, "%s checks%s" % (match.group(2), extra), output)
        detail = "%s failed" % match.group(3) if match and int(match.group(3)) else "crashed (exit code %d)" % code
        return Result(FAIL, detail, output)
    return step


def step_compile(ctx):
    import static_checks
    return static_checks.compile_all(ctx, PLUGIN, HERE)


def step_analyze(ctx):
    import static_checks
    return static_checks.analyze_all(ctx, PLUGIN)


def step_contracts(ctx):
    import static_checks
    return static_checks.contracts(ctx, SRC)


def step_api_usage(ctx):
    import static_checks
    return static_checks.api_usage(ctx, SRC, CACHE)


def step_multiret(ctx):
    import static_checks
    return static_checks.multiret(ctx, SRC)


def step_patterns(ctx):
    import static_checks
    return static_checks.patterns(ctx, SRC, ctx.tools["luau"], CACHE)


def step_selftest(ctx):
    import static_checks
    return static_checks.selftest(ctx, CACHE)


def step_build(ctx):
    import static_checks
    return static_checks.build(ctx, PLUGIN, SRC)


def step_rbxmx_fresh(ctx):
    import static_checks
    return static_checks.rbxmx_fresh(ctx, PLUGIN)


def all_steps():
    steps = [("compile", "static", step_compile), ("analyze", "static", step_analyze)]
    steps += [(name, "suites", run_suite_step(name)) for name in suite_names()]
    steps += [("contracts", "static", step_contracts), ("api-usage", "static", step_api_usage),
              ("multiret", "static", step_multiret), ("patterns", "static", step_patterns),
              ("selftest", "static", step_selftest), ("build", "static", step_build),
              ("rbxmx-fresh", "static", step_rbxmx_fresh)]
    return steps


# --- driver --------------------------------------------------------------------------------------------------------------

def run_step(ctx, name, fn):
    started = time.time()
    try:
        result = fn(ctx)
    except SystemExit as e:
        result = Result(FAIL, "step aborted", str(e))
    except Exception:
        import traceback
        result = Result(FAIL, "runner error", traceback.format_exc())
    result.seconds = time.time() - started
    return result


def clip(text, limit):
    """Indented output; over `limit` lines it keeps the first and the last half (the verdict is at the end)."""
    lines = text.rstrip().splitlines()
    if limit and len(lines) > limit:
        half = limit // 2
        lines = lines[:half] + ["... (%d lines left out, use -v)" % (len(lines) - 2 * half)] + lines[-half:]
    return "\n".join("    " + (l if len(l) < 400 else l[:400] + " ...") for l in lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description="LostCube test runner")
    parser.add_argument("--only", action="append", default=[], metavar="STEP[,STEP]",
                        help="run only these steps / groups (compile, analyze, <suite>, api-usage, multiret, patterns, build; "
                             "groups: static, suites)")
    parser.add_argument("--list", action="store_true", help="list the steps and exit")
    parser.add_argument("-v", "--verbose", action="store_true", help="print the output of passing steps, do not clip failures")
    parser.add_argument("--update-baselines", action="store_true",
                        help="rewrite data/api_usage_baseline.txt / multiret_baseline.txt from the current findings (review the diff!)")
    parser.add_argument("-j", "--jobs", type=int, default=0, help="suites in parallel (default: number of CPUs, max 4)")
    args = parser.parse_args(argv)

    steps = all_steps()
    if args.list:
        for name, group, _ in steps:
            print("%-14s %s" % (name, group))
        return 0

    wanted = [w.strip() for chunk in args.only for w in chunk.split(",") if w.strip()]
    if wanted:
        known = {s[0] for s in steps} | {s[1] for s in steps}
        unknown = [w for w in wanted if w not in known]
        if unknown:
            print("unknown step(s): %s\n(available: %s)" % (", ".join(unknown), ", ".join(sorted(known))))
            return 2
        steps = [s for s in steps if s[0] in wanted or s[1] in wanted]

    os.makedirs(CACHE, exist_ok=True)
    tools, label = luau_tools.locate(CACHE, log=lambda m: print("[tools] " + m, flush=True))
    ctx = Context(tools, label)
    ctx.update_baselines = args.update_baselines
    print("LostCube tests: %d step(s); Luau tools from %s (%s)" % (len(steps), label, luau_tools.version_of(tools)))
    ctx.files()  # read once, shared by the suites

    results = {}
    jobs = args.jobs or min(4, os.cpu_count() or 1)
    suite_steps = [s for s in steps if s[1] == "suites"]
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs))
    futures = {name: pool.submit(run_step, ctx, name, fn) for name, _, fn in suite_steps}

    width = max(len(s[0]) for s in steps)
    failed = 0
    for index, (name, group, fn) in enumerate(steps, 1):
        result = futures[name].result() if name in futures else run_step(ctx, name, fn)
        results[name] = result
        mark = {PASS: "PASS", FAIL: "FAIL", SKIP: "skip"}[result.status]
        print("[%2d/%d] %-*s  %s  %s  (%.1fs)" % (index, len(steps), width, name, mark, result.detail, result.seconds), flush=True)
        if result.status == FAIL or (args.verbose and result.output):
            if result.output:
                print(clip(result.output, 0 if args.verbose else 60))
        if result.status == FAIL:
            failed += 1
    pool.shutdown()

    passed = sum(1 for r in results.values() if r.status == PASS)
    skipped = sum(1 for r in results.values() if r.status == SKIP)
    print("\n" + "=" * 60)
    for name, result in results.items():
        print("  %-*s %s" % (width + 2, name, result.status))
    print("=" * 60)
    print("%s: %d passed, %d failed, %d skipped" % ("FAIL" if failed else "PASS", passed, failed, skipped))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
