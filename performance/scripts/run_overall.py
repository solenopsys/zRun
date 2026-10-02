#!/usr/bin/env python3
"""Report averaged runtime gaps and source line counts against JS engines."""

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


def median_times(commands, runs, warmups):
    for _ in range(warmups):
        for command in commands:
            run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    samples = [[] for _ in commands]
    for index in range(runs):
        start = index % len(commands)
        order = list(range(start, len(commands))) + list(range(start))
        for engine in order:
            before = time.perf_counter_ns()
            run(commands[engine], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            samples[engine].append(time.perf_counter_ns() - before)
    return [statistics.median(engine_samples) for engine_samples in samples]


def geometric_slowdown(reference_times, zrun_times):
    ratios = [runtime / reference for reference, runtime in zip(reference_times, zrun_times)]
    return math.exp(sum(math.log(ratio) for ratio in ratios) / len(ratios))


def source_line_counts(mqjs_source):
    # Count production runtime sources, not demo/benchmark/test-only entrypoints.
    zrun_excluded = {"root.zig", "memory_probe.zig"}
    zrun_files = [
        path for path in (ROOT / "src").rglob("*.zig")
        if "demo" not in path.relative_to(ROOT / "src").parts
        and not path.name.startswith("performance")
        and path.name not in zrun_excluded
    ]
    # Match the upstream mqjs executable sources from its Makefile. Include
    # their hand-written headers, but omit generated headers and build tools.
    mqjs_runtime_sources = {
        "mqjs.c", "mquickjs.c", "cutils.c", "dtoa.c", "libm.c",
        "readline.c", "readline_tty.c", "mqjs_stdlib.c",
    }
    mqjs_generated_or_build_only = {
        "mquickjs_atom.h", "mqjs_stdlib.h", "mquickjs_build.c",
        "mquickjs_build.h",
    }
    mqjs_files = [
        path for path in mqjs_source.iterdir()
        if path.suffix in {".c", ".h"}
        and (path.name in mqjs_runtime_sources or path.suffix == ".h")
        and path.name not in mqjs_generated_or_build_only
        and not path.name.startswith("example")
    ]

    def count(files):
        return sum(
            1
            for path in files
            for line in path.read_text(errors="replace").splitlines()
            if line.strip()
        )

    return count(zrun_files), count(mqjs_files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quickjs", type=Path, required=True)
    parser.add_argument("--mqjs", type=Path, required=True)
    parser.add_argument("--mquickjs-source", type=Path, required=True)
    parser.add_argument("--v8-root", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=11)
    parser.add_argument("--warmups", type=int, default=3)
    args = parser.parse_args()

    quickjs = args.quickjs.resolve()
    mqjs = args.mqjs.resolve()
    mqjs_source = args.mquickjs_source.resolve()
    v8_root = args.v8_root.resolve()
    if not quickjs.is_file():
        parser.error(f"official QuickJS binary not found: {quickjs}; build with make -C ../quickjs qjs")
    if not mqjs.is_file():
        parser.error(f"MQuickJS binary not found: {mqjs}; build with make -C ../mquickjs mqjs")
    if not CASES:
        parser.error("no performance fixtures found")
    if args.runs < 1 or args.warmups < 0:
        parser.error("--runs must be positive and --warmups cannot be negative")

    cxx = os.environ.get("CXX", "g++")
    lld = Path("/usr/lib/llvm21/bin/ld.lld")
    linker = ["-B/usr/lib/llvm21/bin", "-fuse-ld=lld"] if lld.is_file() else ["-fuse-ld=lld"]

    with tempfile.TemporaryDirectory(prefix="zrun-overall-performance-") as temporary:
        v8_runner = Path(temporary) / "v8-runner"
        run(["zig", "build", "-Doptimize=ReleaseFast"], cwd=ROOT)
        zrun = ROOT / "zig-out" / "bin" / "zrun"
        run(["zig", "build", "-Dv8-backend=real"], cwd=v8_root)
        run([
            cxx, "-O1", str(PERFORMANCE / "v8_runner.cc"), "-o", str(v8_runner),
            str(v8_root / "third-party" / "v8-shim.o"),
            str(v8_root / "zig-out" / "lib" / "libv8.a"),
            str(v8_root / "third-party" / "v8" / "libv8_monolith.a"),
            "-lstdc++", "-lpthread", "-ldl", "-latomic", *linker,
        ], cwd=v8_root)

        times = {name: [[], []] for name in ("quickjs", "mqjs", "v8")}
        for source in CASES:
            commands = [
                [str(quickjs), str(source)],
                [str(zrun), str(source)],
                [str(mqjs), str(source)],
                [str(v8_runner), str(source)],
            ]
            outputs = [
                run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
                for command in commands
            ]
            if any(output != outputs[0] for output in outputs[1:]):
                raise SystemExit(
                    f"output mismatch: {source.name}\n"
                    f"QuickJS: {outputs[0]!r}\nzRun: {outputs[1]!r}\n"
                    f"MQuickJS: {outputs[2]!r}\nV8: {outputs[3]!r}"
                )

            medians = median_times(commands, args.runs, args.warmups)
            for name, reference_index in (("quickjs", 0), ("mqjs", 2), ("v8", 3)):
                times[name][0].append(medians[reference_index])
                times[name][1].append(medians[1])

    print(f"Overall zRun ReleaseFast lag; geometric mean across {len(CASES)} equal-weight fixtures.")
    print(f"QuickJS: {format_lag(geometric_slowdown(*times['quickjs']))}")
    print(f"MQuickJS: {format_lag(geometric_slowdown(*times['mqjs']))}")
    print(f"V8:       {format_lag(geometric_slowdown(*times['v8']))}")
    zrun_lines, mqjs_lines = source_line_counts(mqjs_source)
    print(
        f"Nonblank source lines (runtime scope): zRun {zrun_lines:,}; "
        f"MQuickJS {mqjs_lines:,}; MQuickJS/zRun {mqjs_lines / zrun_lines:.2f}x"
    )


def format_lag(slowdown):
    if slowdown >= 1:
        return f"{(slowdown - 1) * 100:.1f}% slower"
    return f"{(1 - slowdown) * 100:.1f}% faster"


if __name__ == "__main__":
    main()
