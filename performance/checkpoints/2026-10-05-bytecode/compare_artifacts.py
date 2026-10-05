#!/usr/bin/env python3
"""Compare old/new compiler output on the SAME runtime, alternating order."""
import json
import os
from pathlib import Path
import statistics
import subprocess
import time

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]
CPU = min(os.sched_getaffinity(0))
RUNS, WARMUPS = 21, 3
RUNTIME = OUT / "after-zrun-runtime"
SOURCES = sorted((ROOT / "performance/workloads/cli").glob("*.js")) + sorted((ROOT / "performance/workloads/features").glob("*.js")) + [OUT / "local_updates.js"]

def run(command):
    result = subprocess.run(command, capture_output=True, check=True)
    return result.stdout

rows = []
for source in SOURCES:
    commands = []
    sizes = []
    for version in ("before", "after"):
        compiler = OUT / (version + "-zrun-compile")
        artifact = OUT / (version + "-" + source.parent.name + "-" + source.stem + ".zbc")
        data = run([str(compiler), str(source)])
        artifact.write_bytes(data)
        sizes.append(len(data))
        commands.append(["taskset", "-c", str(CPU), str(RUNTIME), str(artifact)])
    expected = run(commands[0])
    if run(commands[1]) != expected:
        raise RuntimeError("output mismatch: " + source.name)
    for _ in range(WARMUPS):
        for command in commands:
            if run(command) != expected: raise RuntimeError("warmup mismatch")
    samples = [[], []]
    for repeat in range(RUNS):
        for index in ((0, 1) if repeat % 2 == 0 else (1, 0)):
            start = time.perf_counter_ns()
            actual = run(commands[index])
            elapsed = time.perf_counter_ns() - start
            if actual != expected: raise RuntimeError("sample mismatch")
            samples[index].append(elapsed)
    before, after = map(statistics.median, samples)
    row = {"source": str(source.relative_to(ROOT)), "artifact_bytes": dict(zip(("before", "after"), sizes)), "samples_ns": dict(zip(("before", "after"), samples)), "before_ns": before, "after_ns": after, "speedup": before / after}
    rows.append(row)
    (OUT / "paired-artifacts.json").write_text(json.dumps({"runs": RUNS, "warmups": WARMUPS, "cpu": CPU, "runtime": str(RUNTIME), "rows": rows}, indent=2) + "\n")
    print(f"{source.stem}: {before / 1e6:.3f} -> {after / 1e6:.3f} ms; {before / after:.3f}x; {sizes[0]} -> {sizes[1]} bytes", flush=True)
