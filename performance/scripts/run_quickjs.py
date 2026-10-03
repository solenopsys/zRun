#!/usr/bin/env python3
"""Compare identical source workloads on official QuickJS and zRun ReleaseFast."""

import argparse
import math
import statistics
import subprocess
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent.parent
PERFORMANCE = ROOT / "performance" / "workloads" / "cli"
CASES = sorted(PERFORMANCE.glob("*.js"))


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def timed_medians(reference_command, zrun_command, runs, warmups):
    for _ in range(warmups):
        run(reference_command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run(zrun_command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    reference_samples = []
    zrun_samples = []
    for index in range(runs):
        commands = (
            (reference_command, reference_samples),
            (zrun_command, zrun_samples),
        )
        if index % 2:
            commands = commands[::-1]
        for command, samples in commands:
            started = time.perf_counter_ns()
            run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            samples.append(time.perf_counter_ns() - started)
    return statistics.median(reference_samples), statistics.median(zrun_samples)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quickjs", type=Path, required=True, help="path to the QuickJS qjs executable")
    parser.add_argument("--zrun", type=Path, default=ROOT / "zig-out" / "bin" / "zrun")
    parser.add_argument("--runs", type=int, default=11)
    parser.add_argument("--warmups", type=int, default=3)
    args = parser.parse_args()
    quickjs = args.quickjs.resolve()
    zrun = args.zrun.resolve()

    if not quickjs.is_file():
        parser.error(f"QuickJS binary not found: {quickjs}; build with make -C ../quickjs qjs")
    if args.runs < 1 or args.warmups < 0:
        parser.error("--runs must be positive and --warmups cannot be negative")

    run(["zig", "build", "-Doptimize=fast"], cwd=ROOT)
    zrun = (ROOT / "zig-out" / "bin" / "zrun").resolve() if args.zrun == ROOT / "zig-out" / "bin" / "zrun" else zrun
    if not zrun.is_file():
        parser.error(f"zRun binary not found: {zrun}")

    rows = []
    for source in CASES:
        reference_command = [str(quickjs), str(source)]
        zrun_command = [str(zrun), str(source)]
        expected = run(reference_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
        actual = run(zrun_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
        if actual != expected:
            raise SystemExit(f"output mismatch: {source.name}\nQuickJS: {expected!r}\nzRun:   {actual!r}")
        reference_ns, zrun_ns = timed_medians(
            reference_command, zrun_command, args.runs, args.warmups
        )
        rows.append((source.stem, reference_ns, zrun_ns, reference_ns / zrun_ns))

    geometric_ratio = math.exp(sum(math.log(row[3]) for row in rows) / len(rows))
    print("Same JavaScript source; process startup, parsing/compilation, and execution included.")
    print(f"QuickJS: {quickjs} | zRun: {zrun} (ReleaseFast)")
    print(f"Samples: {args.runs} per engine, {args.warmups} warmups; median wall time.")
    print("\n| Workload | QuickJS ms | zRun ms | QuickJS/zRun | zRun gap |")
    print("|---|---:|---:|---:|---:|")
    for name, reference_ns, zrun_ns, ratio in rows:
        gap = (1.0 / ratio - 1.0) * 100.0
        print(
            f"| {name} | {reference_ns / 1e6:.3f} | {zrun_ns / 1e6:.3f} "
            f"| {ratio:.2f}x | {gap:+.1f}% |"
        )
    gap = (1.0 / geometric_ratio - 1.0) * 100.0
    print(f"\nGeometric mean QuickJS/zRun: {geometric_ratio:.2f}x")
    print(f"Geometric mean zRun gap: {gap:+.1f}% (positive means zRun is slower).")


if __name__ == "__main__":
    main()
