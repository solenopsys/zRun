#!/usr/bin/env python3
"""Compare both runtimes on the same upstream-compiled bytecode images."""

import argparse
import shutil
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent.parent
CASES = sorted((ROOT / "performance" / "workloads" / "cli").glob("*.js"))


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def paired_medians(c_command, zig_command, runs, warmups):
    for _ in range(warmups):
        run(c_command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run(zig_command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    c_samples = []
    zig_samples = []
    for index in range(runs):
        commands = ((c_command, c_samples), (zig_command, zig_samples))
        if index % 2:
            commands = commands[::-1]
        for command, samples in commands:
            start = time.perf_counter_ns()
            run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            samples.append(time.perf_counter_ns() - start)
    return statistics.median(c_samples), statistics.median(zig_samples)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", help="path to an MQuickJS mqjs executable")
    parser.add_argument("--runs", type=int, default=9)
    parser.add_argument("--warmups", type=int, default=2)
    args = parser.parse_args()
    reference = Path(args.reference).resolve()
    if not reference.is_file():
        parser.error(f"reference engine not found: {reference} (build it with make -C ../mquickjs mqjs)")
    if args.runs < 1 or args.warmups < 0:
        parser.error("--runs must be positive and --warmups cannot be negative")

    with tempfile.TemporaryDirectory(prefix="zrun-performance-") as temporary:
        temp = Path(temporary)
        run(["zig", "build", "-Doptimize=small"], cwd=ROOT)
        small_binary = temp / "zrun-release-small"
        shutil.copy2(ROOT / "zig-out" / "bin" / "zrun", small_binary)
        small_raw_size = small_binary.stat().st_size

        run(["zig", "build", "-Doptimize=fast"], cwd=ROOT)
        zig_vm = ROOT / "zig-out" / "bin" / "zrun"
        fast_binary = temp / "zrun-release-fast"
        shutil.copy2(zig_vm, fast_binary)
        fast_raw_size = fast_binary.stat().st_size

        rows = []
        for source in CASES:
            image = temp / f"{source.stem}.bin"
            run([str(reference), "-o", str(image), str(source)], cwd=ROOT,
                stdout=subprocess.DEVNULL)
            expected = run([str(reference), "-b", str(image)], cwd=ROOT,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
            actual = run([str(zig_vm), "--bytecode", str(image)], cwd=ROOT,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
            if actual != expected:
                raise SystemExit(f"output mismatch: {source.name}")

            c_command = [str(reference), "-b", str(image)]
            zig_command = [str(zig_vm), "--bytecode", str(image)]
            c_ns, zig_ns = paired_medians(c_command, zig_command, args.runs, args.warmups)
            rows.append((source.stem, c_ns, zig_ns, c_ns / zig_ns))

        stripped_reference = temp / "mqjs-stripped"
        shutil.copy2(reference, stripped_reference)
        run(["strip", "--strip-debug", str(stripped_reference)])
        reference_size = stripped_reference.stat().st_size
        stripped_small = temp / "zrun-release-small-stripped"
        shutil.copy2(small_binary, stripped_small)
        run(["strip", "--strip-debug", str(stripped_small)])
        small_size = stripped_small.stat().st_size
        stripped_fast = temp / "zrun-release-fast-stripped"
        shutil.copy2(fast_binary, stripped_fast)
        run(["strip", "--strip-debug", str(stripped_fast)])
        fast_size = stripped_fast.stat().st_size

    print("Same upstream-compiled bytecode; ReleaseFast process startup and image loading included.")
    print(f"Samples: {args.runs} per engine, {args.warmups} warmups; values are median wall time.")
    print("\n| Workload | mqjs ms | zrun ms | mqjs/zrun |")
    print("|---|---:|---:|---:|")
    for name, c_ns, zig_ns, ratio in rows:
        print(f"| {name} | {c_ns / 1e6:.3f} | {zig_ns / 1e6:.3f} | {ratio:.2f}x |")
    print("\n| Executable | File bytes |")
    print("|---|---:|")
    print(f"| mqjs (-Os, debug sections stripped) | {reference_size:,} |")
    print(f"| zrun (ReleaseSmall, debug sections stripped) | {small_size:,} |")
    print(f"| zrun (ReleaseFast, debug sections stripped) | {fast_size:,} |")
    print(f"| ReleaseFast before stripping | {fast_raw_size:,} |")
    print(f"| ReleaseSmall before stripping | {small_raw_size:,} |")
    print("\nTiming ratio above 1.00x means zrun was faster for that workload.")


if __name__ == "__main__":
    main()
