#!/usr/bin/env python3
"""Compile identical JavaScript independently; time compilation and execution separately."""

import argparse
import hashlib
import json
import math
import os
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

from run_overall import source_line_counts

ROOT = Path(__file__).resolve().parent.parent.parent


def checked(command, **kwargs):
    return subprocess.run(command, cwd=ROOT, check=True, stderr=subprocess.PIPE, **kwargs)


def compile_image(engine, source):
    if engine["compiler"] is None:
        command = [str(engine["runtime"]), "-o", str(engine["image"]), str(source)]
        start = time.perf_counter_ns()
        checked(command, stdout=subprocess.DEVNULL)
        return time.perf_counter_ns() - start
    with engine["image"].open("wb") as output:
        start = time.perf_counter_ns()
        checked([str(engine["compiler"]), str(source)], stdout=output)
        return time.perf_counter_ns() - start


def execute_image(engine):
    command = [str(engine["runtime"])]
    if engine["compiler"] is None:
        command.append("-b")
    command.append(str(engine["image"]))
    start = time.perf_counter_ns()
    result = checked(command, stdout=subprocess.PIPE)
    return time.perf_counter_ns() - start, result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path, help="MQuickJS mqjs executable")
    parser.add_argument("--runs", type=int, default=21)
    parser.add_argument("--warmups", type=int, default=3)
    parser.add_argument("--suite", choices=("cli", "features", "all"), default="cli")
    parser.add_argument("--case", type=Path, action="append", default=[], help="additional JavaScript file")
    parser.add_argument("--baseline-compiler", type=Path)
    parser.add_argument("--baseline-runtime", type=Path)
    parser.add_argument("--mquickjs-source", type=Path, help="source directory for the existing line counter")
    parser.add_argument("--json", type=Path, help="save raw samples and measurement metadata")
    parser.add_argument("--no-build", action="store_true", help="use already built ReleaseFast executables")
    args = parser.parse_args()
    if args.runs < 1 or args.warmups < 0:
        parser.error("--runs must be positive; --warmups must be nonnegative")
    if bool(args.baseline_compiler) != bool(args.baseline_runtime):
        parser.error("provide both --baseline-compiler and --baseline-runtime")
    reference = args.reference.resolve()
    binaries = [reference]
    if args.baseline_compiler:
        binaries += [args.baseline_compiler.resolve(), args.baseline_runtime.resolve()]
    for binary in binaries:
        if not binary.is_file() or not os.access(binary, os.X_OK):
            parser.error(f"executable not found: {binary}")
    suites = ("cli", "features") if args.suite == "all" else (args.suite,)
    cases = [source for suite in suites for source in sorted((ROOT / "performance/workloads" / suite).glob("*.js"))]
    cases += [source.resolve() for source in args.case]
    if not cases or any(not source.is_file() for source in cases):
        parser.error("no cases found or an additional case does not exist")
    if not args.no_build:
        checked(["zig", "build", "-Doptimize=fast"], stdout=subprocess.DEVNULL)
    compiler = ROOT / "zig-out/bin/zrun-compile"
    runtime = ROOT / "zig-out/bin/zrun-runtime"
    for binary in (compiler, runtime):
        if not binary.is_file():
            parser.error(f"build output missing: {binary}")

    report = {
        "scope": "CLI compilation + artifact serialization; separate CLI execution + artifact loading. Both include subprocess startup. Build excluded.",
        "runs": args.runs,
        "warmups": args.warmups,
        "cpu_affinity": sorted(os.sched_getaffinity(0)),
        "rows": [],
    }
    print("Same JavaScript input; each engine compiles and executes its OWN artifact.")
    print("Compile: source loading + compilation + serialization + process startup.")
    print("Execute: artifact loading + execution + process startup; compilation excluded.")
    print(f"Samples: {args.runs}; warmups: {args.warmups}; builds excluded.\n", flush=True)
    print("| Workload | Engine | Compile ms | Execute ms | Artifact bytes |")
    print("|---|---|---:|---:|---:|", flush=True)
    with tempfile.TemporaryDirectory(prefix="zrun-pipeline-") as temporary:
        temp = Path(temporary)
        engines = [{"name": "MQuickJS", "compiler": None, "runtime": reference, "image": temp / "mqjs.bin"}]
        if args.baseline_compiler:
            engines.append({"name": "zRun before", "compiler": args.baseline_compiler.resolve(), "runtime": args.baseline_runtime.resolve(), "image": temp / "before.zbc"})
        engines.append({"name": "zRun after" if args.baseline_compiler else "zRun", "compiler": compiler, "runtime": runtime, "image": temp / "after.zbc"})
        report["engines"] = [{
            "name": engine["name"],
            "compiler": str(engine["compiler"]) if engine["compiler"] else str(reference),
            "runtime": str(engine["runtime"]),
            "runtime_sha256": hashlib.sha256(engine["runtime"].read_bytes()).hexdigest(),
            "compiler_sha256": hashlib.sha256((engine["compiler"] or reference).read_bytes()).hexdigest(),
        } for engine in engines]
        for source in cases:
            samples = {engine["name"]: {"compile": [], "execute": []} for engine in engines}
            expected = None
            for iteration in range(args.warmups + args.runs):
                start_index = iteration % len(engines)
                order = engines[start_index:] + engines[:start_index]
                for engine in order:
                    elapsed = compile_image(engine, source)
                    if iteration >= args.warmups:
                        samples[engine["name"]]["compile"].append(elapsed)
                for engine in order:
                    elapsed, output = execute_image(engine)
                    if expected is None:
                        expected = output
                    if output != expected:
                        raise RuntimeError(f"output mismatch: {source}: {engine['name']}")
                    if iteration >= args.warmups:
                        samples[engine["name"]]["execute"].append(elapsed)
            try:
                label = str(source.relative_to(ROOT / "performance/workloads"))
            except ValueError:
                label = str(source)
            row = {"source": label, "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "output": expected.decode(errors="replace"), "engines": {}}
            for engine in engines:
                timing = samples[engine["name"]]
                values = {"compile_ns": statistics.median(timing["compile"]), "execute_ns": statistics.median(timing["execute"]), "artifact_bytes": engine["image"].stat().st_size, "samples_ns": timing}
                row["engines"][engine["name"]] = values
                print(f"| {label} | {engine['name']} | {values['compile_ns'] / 1e6:.3f} | {values['execute_ns'] / 1e6:.3f} | {values['artifact_bytes']} |", flush=True)
            report["rows"].append(row)
            if args.json:
                args.json.parent.mkdir(parents=True, exist_ok=True)
                args.json.write_text(json.dumps(report, indent=2) + "\n")
    source_directory = (args.mquickjs_source or reference.parent).resolve()
    if (source_directory / "mquickjs.c").is_file():
        zrun_lines, mqjs_lines = source_line_counts(source_directory)
        report["source_lines"] = {"zrun_nonblank": zrun_lines, "mquickjs_nonblank": mqjs_lines}
        print(f"\nNonblank source lines (existing counter): zRun {zrun_lines:,}; MQuickJS {mqjs_lines:,}.")
    if args.baseline_compiler:
        print("\nBefore/after geometric mean speedup (equal weight per workload):")
        for phase in ("compile_ns", "execute_ns"):
            ratios = [row["engines"]["zRun before"][phase] / row["engines"]["zRun after"][phase] for row in report["rows"]]
            print(f"{phase.removesuffix('_ns')}: {math.exp(statistics.mean(map(math.log, ratios))):.3f}x")
    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
