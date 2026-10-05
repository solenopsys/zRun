#!/usr/bin/env python3
"""Alternate saved old/new development runners on identical upstream images."""
import json
import os
from pathlib import Path
import statistics
import subprocess
import time

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]
CPU = min(os.sched_getaffinity(0))
REF = "/home/alexstorm/distrib/business/rd/mquickjs/mqjs"
rows = []
for source in sorted((ROOT / "performance/workloads/cli").glob("*.js")):
    image = OUT / ("control-" + source.stem + ".bin")
    subprocess.run([REF, "-o", str(image), str(source)], check=True, capture_output=True)
    commands = [["taskset", "-c", str(CPU), str(OUT / (version + "-zrun")), "--bytecode", str(image)] for version in ("before", "after")]
    expected = subprocess.check_output([REF, "-b", str(image)])
    for _ in range(5):
        for command in commands:
            assert subprocess.check_output(command) == expected
    samples = [[], []]
    for repeat in range(31):
        for index in ((0, 1) if repeat % 2 == 0 else (1, 0)):
            start = time.perf_counter_ns()
            actual = subprocess.check_output(commands[index])
            elapsed = time.perf_counter_ns() - start
            assert actual == expected
            samples[index].append(elapsed)
    before, after = map(statistics.median, samples)
    rows.append({"source": source.name, "samples_ns": dict(zip(("before", "after"), samples)), "before_ns": before, "after_ns": after, "speedup": before / after})
    print(f"{source.stem}: {before / 1e6:.3f} -> {after / 1e6:.3f} ms; {before / after:.3f}x", flush=True)
(OUT / "paired-control.json").write_text(json.dumps({"runs": 31, "warmups": 5, "cpu": CPU, "rows": rows}, indent=2) + "\n")
