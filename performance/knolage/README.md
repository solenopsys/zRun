# Performance Notes

This folder keeps benchmark results that include a useful method or
optimization finding. Measurements are dated snapshots from one host, not
current performance guarantees. Re-run workloads before using them for release
or capacity decisions.

The in-process VM microbenchmarks run without external engines:

```sh
zig build bench -Doptimize=fast
```

Run commands from the zRun repository root. Workloads are grouped by behavior:

- `performance/workloads/cli/` measures end-to-end script execution.
- `performance/workloads/features/` covers builtins and language features.
- `performance/workloads/inprocess/` contains same-bytecode VM comparisons.

Python runners are in `../scripts/`. Cross-engine comparisons require the
reference executables as explicit arguments, so the project does not depend on
unbundled engine checkouts:

```sh
python3 performance/scripts/run.py /path/to/mqjs
python3 performance/scripts/run_features.py /path/to/mqjs
python3 performance/scripts/run_quickjs.py --quickjs /path/to/qjs
```

## Latest Run

Measured on 2026-09-29 with Zig 0.16.0, Linux x86_64, AMD Ryzen 7 8845H.
Ratios are reference time / zRun time; below `1.00x` means zRun was slower.
Each runner reports medians; suites use different workloads and timing scopes,
so compare only within a row. The runs were not CPU-pinned.

| Benchmark | Cases | Result | Scope |
|---|---:|---:|---|
| zRun VM microbenchmarks | 4 | stack push/pop `0.52 ns/pair`; arithmetic `1.023 ms`; calls `0.307 ms`; native methods `2.318 ms` | Internal VM only; medians of 5 samples |
| MQuickJS same-bytecode | 8 | geometric mean `0.92x` | Same compiled images; 2 warmups, 7 timed runs |
| MQuickJS CLI bytecode | 4 | geometric mean `0.87x` | Process startup and bytecode loading; 2 warmups, 9 timed runs |
| MQuickJS language features | 15 | geometric mean `0.56x` | Source compile and execution; 2 warmups, 7 timed runs |
| Official QuickJS CLI | 4 | geometric mean `0.91x` | Source compile and execution; 3 warmups, 11 timed runs |
| Compile-only comparison | 4 | geometric mean `0.60x` | MQuickJS C `-O3` vs zRun Zig `ReleaseFast`; 15 timed runs |

The comparative suites use the MQuickJS and QuickJS checkouts outside this
repository. These fresh results supersede the older snapshots where the same
suite and scope overlap; historical optimization experiments remain in their
dated notes below.

## Same-Bytecode Results

Latest in-process run on the same eight compiled images. Values are median
`JS_Run` times; image loading and process startup are excluded. The ratio is
MQuickJS/zRun, so above `1.00x` means zRun was faster for that workload.

| Workload | MQuickJS | zRun | MQuickJS/zRun |
|---|---:|---:|---:|
| Arithmetic | 8.511 ms | 7.413 ms | 1.15x |
| Calls | 25.452 ms | 29.433 ms | 0.86x |
| Empty calls | 16.068 ms | 23.073 ms | 0.70x |
| Empty loop | 9.811 ms | 8.828 ms | 1.11x |
| Global function reads | 12.054 ms | 10.455 ms | 1.15x |
| Local calls | 22.082 ms | 28.276 ms | 0.78x |
| Local empty calls | 15.465 ms | 22.595 ms | 0.68x |
| Locals | 7.710 ms | 6.863 ms | 1.12x |

## Findings

- [Feature workload baseline](WORKLOAD_BASELINE.md): broad source-level results.
- [Call isolation](CALL_ISOLATION.md): same-bytecode call overhead controls.
- [QuickJS comparison](QUICKJS_2026.md): CLI snapshot and scope caveats.
- [Optimization log](OPTIMIZATIONS.md): retained and rejected changes with measured effects.
- [Profiling notes](PROFILING.md): hardware-specific profiles and follow-up findings.
