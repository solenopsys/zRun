#!/usr/bin/env python3
"""Compare shared source fixtures on MQuickJS, zRun, and the real V8 backend."""

import argparse
import math
import os
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent.parent
PERFORMANCE = ROOT / "performance"
CASES = sorted((PERFORMANCE / "workloads" / "cli").glob("*.js"))


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def timed_medians(commands, runs, warmups):
    for _ in range(warmups):
        for command in commands:
            run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    samples = [[] for _ in commands]
    for index in range(runs):
        order = list(range(len(commands)))
        shift = index % len(order)
        order = order[shift:] + order[:shift]
        for engine in order:
            started = time.perf_counter_ns()
            run(commands[engine], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            samples[engine].append(time.perf_counter_ns() - started)
    return [statistics.median(engine_samples) for engine_samples in samples]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mqjs", type=Path, required=True)
    parser.add_argument("--zrun", type=Path, default=ROOT / "zig-out" / "bin" / "zrun")
    parser.add_argument("--v8-root", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=7)
    parser.add_argument("--warmups", type=int, default=2)
    args = parser.parse_args()
    mqjs = args.mqjs.resolve()
    v8_root = args.v8_root.resolve()
    if not mqjs.is_file():
        parser.error(f"MQuickJS not found: {mqjs}; build with make -C ../mquickjs mqjs")
    if args.runs < 1 or args.warmups < 0:
        parser.error("--runs must be positive and --warmups cannot be negative")
    if not CASES:
        parser.error("no performance fixtures found")
    cxx = os.environ.get("CXX", "g++")
    lld = Path("/usr/lib/llvm21/bin/ld.lld")
    linker = ["-B/usr/lib/llvm21/bin", "-fuse-ld=lld"] if lld.is_file() else ["-fuse-ld=lld"]

    with tempfile.TemporaryDirectory(prefix="zrun-v8-performance-") as temporary:
        v8_runner = Path(temporary) / "v8-runner"
        run(["zig", "build", "-Doptimize=ReleaseFast"], cwd=ROOT)
        zrun = (ROOT / "zig-out" / "bin" / "zrun").resolve() if args.zrun == ROOT / "zig-out" / "bin" / "zrun" else args.zrun.resolve()
        run(["zig", "build", "-Dv8-backend=real"], cwd=v8_root)
        run([
            cxx, "-O1", str(PERFORMANCE / "v8_runner.cc"), "-o", str(v8_runner),
            str(v8_root / "third-party" / "v8-shim.o"),
            str(v8_root / "zig-out" / "lib" / "libv8.a"),
            str(v8_root / "third-party" / "v8" / "libv8_monolith.a"),
            "-lstdc++", "-lpthread", "-ldl", "-latomic", *linker,
        ], cwd=v8_root)

        rows = []
        for source in CASES:
            commands = [
                [str(mqjs), str(source)],
                [str(zrun), str(source)],
                [str(v8_runner), str(source)],
            ]
            outputs = [run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout for command in commands]
            if outputs[0] != outputs[1] or outputs[0] != outputs[2]:
                raise SystemExit(
                    f"output mismatch: {source.name}\n"
                    f"mqjs: {outputs[0]!r}\nzrun: {outputs[1]!r}\nV8: {outputs[2]!r}"
                )
            medians = timed_medians(commands, args.runs, args.warmups)
            rows.append((source.stem, *medians))

    ratios_mqjs = [row[1] / row[2] for row in rows]
    ratios_v8 = [row[3] / row[2] for row in rows]
    print("Same JS fixtures and byte-identical stdout. Timings include process/runtime startup, source compilation, and execution.")
    print(f"MQuickJS: {mqjs} | zRun: {zrun} (ReleaseFast) | V8 backend: {v8_root}")
    print(f"Samples: {args.runs} per engine, {args.warmups} warmups; median wall time.")
    print("\n| Workload | MQuickJS ms | zRun ms | V8 ms | MQuickJS/zRun | V8/zRun |")
    print("|---|---:|---:|---:|---:|---:|")
    for name, mqjs_ns, zrun_ns, v8_ns in rows:
        print(f"| {name} | {mqjs_ns / 1e6:.3f} | {zrun_ns / 1e6:.3f} | {v8_ns / 1e6:.3f} | {mqjs_ns / zrun_ns:.2f}x | {v8_ns / zrun_ns:.2f}x |")
    print(f"\nGeometric mean MQuickJS/zRun: {math.exp(sum(math.log(r) for r in ratios_mqjs) / len(ratios_mqjs)):.2f}x")
    print(f"Geometric mean V8/zRun: {math.exp(sum(math.log(r) for r in ratios_v8) / len(ratios_v8)):.2f}x")
    print("Ratios below 1.00x mean the reference finished faster than zRun.")


if __name__ == "__main__":
    main()
