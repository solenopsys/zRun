#!/usr/bin/env python3
"""Compare QuickJS and zRun on byte-array churn and equivalent normal arrays."""

import argparse
import os
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent


def peak_rss_kib(pid):
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmHWM:"):
                return int(line.split()[1])
    except (FileNotFoundError, ProcessLookupError, ValueError):
        pass
    return 0


def measured_run(command):
    start = time.perf_counter_ns()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    peak = peak_rss_kib(process.pid)
    while process.poll() is None:
        peak = max(peak, peak_rss_kib(process.pid))
        time.sleep(0.001)
    stdout, stderr = process.communicate()
    peak = max(peak, peak_rss_kib(process.pid))
    elapsed = time.perf_counter_ns() - start
    if process.returncode:
        raise RuntimeError(f"failed: {' '.join(map(str, command))}\n{stderr.decode(errors='replace')}")
    return elapsed, peak, stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quickjs", required=True, type=Path, help="path to the QuickJS qjs executable")
    parser.add_argument("--mquickjs", type=Path, help="path to the MQuickJS mqjs executable")
    parser.add_argument("--baseline-zrun-runtime", type=Path, help="previous zrun-runtime binary for before/after comparison")
    parser.add_argument("--runs", type=int, default=9)
    parser.add_argument("--warmups", type=int, default=2)
    parser.add_argument("--case", type=Path, action="append", default=[])
    args = parser.parse_args()
    if args.runs < 1 or args.warmups < 0:
        parser.error("--runs must be positive and --warmups nonnegative")
    quickjs = args.quickjs.resolve()
    if not quickjs.is_file() or not os.access(quickjs, os.X_OK):
        parser.error(f"QuickJS executable not found: {quickjs}")
    mquickjs = args.mquickjs.resolve() if args.mquickjs else None
    if mquickjs and (not mquickjs.is_file() or not os.access(mquickjs, os.X_OK)):
        parser.error(f"MQuickJS executable not found: {mquickjs}")
    baseline_runtime = args.baseline_zrun_runtime.resolve() if args.baseline_zrun_runtime else None
    if baseline_runtime and (not baseline_runtime.is_file() or not os.access(baseline_runtime, os.X_OK)):
        parser.error(f"baseline zRun runtime not found: {baseline_runtime}")

    cases = args.case or [
        ROOT / "performance/workloads/byte_array_churn.js",
        ROOT / "performance/workloads/array_churn.js",
        ROOT / "performance/workloads/array_allocate_only.js",
    ]
    if any(not case.is_file() for case in cases):
        parser.error("a benchmark case does not exist")

    if hasattr(os, "sched_getaffinity"):
        allowed = os.sched_getaffinity(0)
        if allowed:
            os.sched_setaffinity(0, {min(allowed)})

    compiler = ROOT / "zig-out/bin/zrun-compile"
    runtime = ROOT / "zig-out/bin/zrun-runtime"
    if not compiler.is_file() or not runtime.is_file():
        parser.error("build zRun first with `zig build -Doptimize=ReleaseFast`")

    print(f"QuickJS: {quickjs}")
    print(f"Samples: {args.runs}; warmups: {args.warmups}; process startup included")
    print("QuickJS measures source parse + execution; zRun and MQuickJS compile and execute their own artifacts separately.")
    print("RSS is peak VmHWM sampled from /proc for each process.")
    print("\n| Workload | Engine | Compile ms | Execute ms | Peak RSS KiB |")
    print("|---|---|---:|---:|---:|", flush=True)

    with tempfile.TemporaryDirectory(prefix="zrun-byte-churn-") as temporary:
        for case in cases:
            artifact = Path(temporary) / f"{case.stem}.zbc"
            compile_start = time.perf_counter_ns()
            with artifact.open("wb") as output:
                result = subprocess.run([str(compiler), str(case)], stdout=output, stderr=subprocess.PIPE)
            compile_ns = time.perf_counter_ns() - compile_start
            if result.returncode:
                raise RuntimeError(f"zRun compile failed: {case}\n{result.stderr.decode(errors='replace')}")

            compile_times = {"zRun": compile_ns}
            commands = {"QuickJS": [str(quickjs), str(case)]}
            if mquickjs:
                mq_artifact = Path(temporary) / f"{case.stem}.mqbc"
                compile_start = time.perf_counter_ns()
                result = subprocess.run([str(mquickjs), "-o", str(mq_artifact), str(case)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                compile_times["MQuickJS"] = time.perf_counter_ns() - compile_start
                if result.returncode:
                    raise RuntimeError(f"MQuickJS compile failed: {case}\n{result.stderr.decode(errors='replace')}")
                commands["MQuickJS"] = [str(mquickjs), "-b", str(mq_artifact)]
            if baseline_runtime:
                commands["zRun before"] = [str(baseline_runtime), str(artifact)]
            commands["zRun"] = [str(runtime), str(artifact)]
            results = {}
            for engine, command in commands.items():
                for _ in range(args.warmups):
                    measured_run(command)
                elapsed_samples = []
                rss_samples = []
                outputs = []
                for _ in range(args.runs):
                    elapsed, rss, stdout = measured_run(command)
                    elapsed_samples.append(elapsed)
                    rss_samples.append(rss)
                    outputs.append(stdout)
                if len(set(outputs)) != 1:
                    raise RuntimeError(f"unstable output: {case}: {engine}")
                results[engine] = (statistics.median(elapsed_samples), statistics.median(rss_samples), outputs[0])

            if results["QuickJS"][2] != results["zRun"][2]:
                raise RuntimeError(f"output mismatch: {case}")
            if "MQuickJS" in results and results["MQuickJS"][2] != results["zRun"][2]:
                raise RuntimeError(f"output mismatch: {case}: MQuickJS")
            if "zRun before" in results and results["zRun before"][2] != results["zRun"][2]:
                raise RuntimeError(f"output mismatch: {case}: baseline zRun")
            label = case.name
            for engine in ("QuickJS", "MQuickJS", "zRun before", "zRun"):
                if engine not in results:
                    continue
                elapsed, rss, _ = results[engine]
                compile_ms = f"{compile_times[engine] / 1e6:.3f}" if engine in compile_times else "n/a"
                print(f"| {label} | {engine} | {compile_ms} | {elapsed / 1e6:.3f} | {rss} |", flush=True)
            print(f"  output: {results['zRun'][2].decode(errors='replace').strip()}", flush=True)


if __name__ == "__main__":
    main()
