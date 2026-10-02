#!/usr/bin/env python3
"""Compare language feature workloads on MQuickJS and zRun."""

import argparse
import statistics
import subprocess
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent.parent
CASES = sorted((ROOT / "performance" / "workloads" / "features").glob("*.js"))


def run(command):
    return subprocess.run(command, cwd=ROOT, text=True, capture_output=True)


def checked(command, expected=None):
    result = run(command)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"command failed: {' '.join(map(str, command))}\n{detail}")
    if expected is not None and result.stdout != expected:
        raise RuntimeError(f"output mismatch: {' '.join(map(str, command))}\n{result.stdout!r} != {expected!r}")
    return result.stdout


def timed(command):
    start = time.perf_counter_ns()
    result = run(command)
    elapsed = time.perf_counter_ns() - start
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"timed command failed: {' '.join(map(str, command))}\n{detail}")
    return elapsed, result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", help="path to an MQuickJS mqjs executable")
    parser.add_argument("--runs", type=int, default=7)
    parser.add_argument("--warmups", type=int, default=2)
    args = parser.parse_args()
    reference = Path(args.reference).resolve()
    if not reference.is_file():
        parser.error(f"reference engine not found: {reference}")
    checked(["zig", "build", "-Doptimize=ReleaseFast"])
    zig = ROOT / "zig-out" / "bin" / "zrun"

    for source in CASES:
        c_command = [str(reference), str(source)]
        zig_command = [str(zig), str(source)]
        expected = checked(c_command)
        checked(zig_command, expected)
        samples = {"MQuickJS": [], "zRun": []}
        commands = {"MQuickJS": c_command, "zRun": zig_command}
        for _ in range(args.warmups):
            checked(c_command, expected)
            checked(zig_command, expected)
        for index in range(args.runs):
            order = ("MQuickJS", "zRun") if index % 2 == 0 else ("zRun", "MQuickJS")
            for runtime in order:
                elapsed, output = timed(commands[runtime])
                if output != expected:
                    raise RuntimeError(f"{source.name}: {runtime} checksum output changed")
                samples[runtime].append(elapsed)
        c_median = statistics.median(samples["MQuickJS"])
        zig_median = statistics.median(samples["zRun"])
        print(f"PASS {source.name}: C/Zig {c_median / zig_median:.2f}x")
        print(f"  MQuickJS: {c_median} ns; zRun ReleaseFast: {zig_median} ns")

    print(f"Language feature workloads: {len(CASES)} measured, 0 blocked")
    print("Timings include process startup, source compilation, and execution.")


if __name__ == "__main__":
    main()
