# Call execution profile baseline — 2026-10-06

Scope: execution only, using the exact unchanged `performance/workloads/inprocess/calls.js` source. Each engine compiled its own artifact before profiling. Each compiled artifact was run 10 times in separate processes pinned to CPU 0; compilation was outside `perf record`. Process startup and artifact loading are included, matching the execution CLI boundary.

Command profile: `perf record -e cycles:u -F 999 --call-graph fp`; 0 lost samples in both captures.

| Engine | Samples | Approx. user cycles (10 runs) | Main symbols |
|---|---:|---:|---|
| MQuickJS | 262 | 1,012,671,170 | `JS_Call` 91.78%; `JS_StackCheck` 6.72% |
| zRun | 420 | 1,847,083,876 | `vm.VM.executeFramesImpl` 49.42%; `heap.ArenaAllocator.alloc` 36.14%; `vm.CallFrame.init` 9.76%; `heap.ArenaAllocator.free` 3.45% |

zRun/MQuickJS sampled user-cycle ratio: 1.824x (about 82.4% more cycles for zRun on this call-heavy workload). This is one microbenchmark and is not a whole-suite result.

Raw perf data and text reports are kept alongside this file. `sha256.txt` records the source and executable identities used for the capture.

## First optimization

Change: artifact loading now sets a function's VM stack limit to `min(bytecode_bytes, 256)` (at least one). Small compiler-generated functions therefore use the existing 16-value inline stack instead of allocating a 256-value overflow stack on every call. The artifact encoding is unchanged.

The same-input before/after run used `performance/scripts/run.py`, 31 measured runs after 5 warmups, pinned to CPU 0, with the saved baseline compiler/runtime passed as the `before` engine. Compilation and execution were measured separately, and the runner checked that all outputs matched.

| Workload | zRun before execute | zRun after execute | Change |
|---|---:|---:|---:|
| `inprocess/calls.js` | 45.328 ms | 41.887 ms | -7.6% |
| `cli/calls.js` | 5.553 ms | 5.242 ms | -5.6% |
| `cli/ssr.js` | 1.792 ms | 1.478 ms | -17.5% |
| `cli/arrays.js` | 1.083 ms | 1.024 ms | -5.4% |
| `cli/arithmetic.js` | 9.141 ms | 9.093 ms | -0.5% |

The after profile for the exact in-process call workload (10 processes, same `perf` settings) has 417 samples, 0 lost, and about 1.730 billion user cycles versus 1.847 billion before (-6.3%). Hot symbols changed from `ArenaAllocator.alloc` 36.14% / `CallFrame.init` 9.76% to `executeFramesImpl` 75.86% / `CallFrame.init` 20.76%; allocator calls no longer appear in the sampled hot symbols. This confirms the targeted allocation cost was removed; the remaining interpreter/frame bookkeeping is the next cost center.

The full raw before/after samples are in `after-run.json`; profile capture is in `zrun-after.perf.data` and `zrun-after-report.txt`. The after executables and their hashes are saved as `after-zrun-compile`, `after-zrun-runtime`, and `after-sha256.txt`.
