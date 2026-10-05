# Results — independent compilation and execution

The input JavaScript is identical for MQuickJS, saved zRun before and current zRun after. Each engine compiles its own artifact. No foreign bytecode is used by this measurement.

31 samples per engine and phase; 5 warmups; CPU 0; rotating engine order. Compilation includes source loading, serialization and process startup. Execution includes artifact loading and process startup, with compilation excluded. Builds are outside both timers.

## Findings

- Nonblank zRun source lines: **10,626 → 10,622** using the existing `source_line_counts` function.
- The implementation removes four compiler lines (`dup` and `drop` around unused results). No VM, opcode or artifact-format changes.
- The synthetic local-update loop executes faster, but the standard workload suite does not demonstrate a general execution-speed improvement.
- The small compile-time changes include process startup and are not evidence of a significant compiler algorithm improvement.

| Scope | Compile time change | Execute time change |
|---|---:|---:|
| 19 standard workloads | -2.32% | +1.03% |
| 20 workloads including synthetic loop | -2.78% | +0.18% |

Changes are geometric means of after/before time ratios, equal weight per workload. Negative means less time. The synthetic loop is listed separately to avoid overstating the broader effect.

## Per-workload zRun execution

| Workload | Before ms | After ms | Time change | Artifact bytes before → after |
|---|---:|---:|---:|---|
| cli/arithmetic.js | 23.845 | 25.762 | +8.04% | 87 → 87 |
| cli/arrays.js | 1.970 | 1.958 | -0.60% | 102 → 102 |
| cli/calls.js | 11.573 | 12.670 | +9.47% | 138 → 138 |
| cli/ssr.js | 3.355 | 3.435 | +2.40% | 205 → 205 |
| features/arrays.js | 39.893 | 40.157 | +0.66% | 775 → 775 |
| features/collections.js | 60.581 | 62.002 | +2.35% | 271 → 271 |
| features/concat_indexof_shift.js | 16.114 | 16.957 | +5.23% | 196 → 194 |
| features/constructors_this.js | 9.934 | 10.204 | +2.72% | 279 → 279 |
| features/control.js | 4.583 | 4.470 | -2.46% | 263 → 263 |
| features/functions.js | 10.204 | 10.344 | +1.37% | 220 → 220 |
| features/json.js | 27.511 | 27.295 | -0.78% | 253 → 253 |
| features/lowered_optional.js | 25.389 | 25.758 | +1.45% | 281 → 281 |
| features/lowered_spread.js | 33.079 | 32.782 | -0.90% | 307 → 307 |
| features/numeric_operators.js | 20.986 | 19.418 | -7.47% | 265 → 265 |
| features/object_methods.js | 42.512 | 42.104 | -0.96% | 323 → 323 |
| features/objects.js | 28.417 | 27.918 | -1.76% | 256 → 256 |
| features/regexp.js | 6.911 | 6.870 | -0.58% | 225 → 223 |
| features/ssr_templates.js | 35.666 | 35.737 | +0.20% | 279 → 279 |
| features/strings.js | 88.378 | 90.593 | +2.51% | 387 → 387 |
| synthetic/local_updates.js | 101.977 | 86.874 | -14.81% | 107 → 99 |

The arithmetic and call cases regress about 8.0% and 9.5% in this run. Their generated artifacts have unchanged sizes. The cause was not isolated; no performance guarantee is inferred from the four-line compiler change.

## Validation and checkpoint

- All 20 pipeline workloads produced matching stdout in every measured execution across all three engine versions.
- The existing verification runner completed with exit 0; its Zig 0.17 optimization spelling was adapted from `ReleaseFast` to `fast` in a local copy (`run-verification.sh`).
- `update_semantics.js` passed on saved before/after compiler-runtime pairs: standalone updates, used prefix/postfix results, mutable captures and loop stack balance.
- `unit-tests.log` records the unit-test summary.
- Initial `src/execution.zig` changes were retained. They are included in `before-working-tree.patch` and `before-source.tar.gz`.

Raw samples and separate compilation/execution medians: [pipeline.json](pipeline.json). Full tables: [pipeline.log](pipeline.log). Exact command: [pipeline-command.txt](pipeline-command.txt). Earlier same-bytecode measurements remain archived and are not used as the main assessment.

## Follow-up: the apparent call regression was not reproduced

The +9.5% call execution time in the original pipeline run is an observation from that run, not an established slowdown caused by the compiler change. Each saved compiler independently compiled the same `cli/calls.js`; the resulting artifacts are byte-for-byte identical. The saved before/after production runtimes also have identical `.text`, `.rodata` and `.data` sections. Thus no call-handler code change explains that difference. Evidence is in `calls-code-evidence.json`.

Three additional paired rounds measured compilation outputs on their respective runtimes, with 61 execution samples per version, 5 warmups and seeded random order within each pair on CPU 0:

| Round | Before ms | After ms | Time change |
|---|---:|---:|---:|
| 1 | 13.205 | 12.832 | -2.83% |
| 2 | 11.972 | 11.810 | -1.35% |
| 3 | 12.443 | 12.642 | +1.59% |

The sign changes between rounds. A persistent call regression is not established. The cause of the earlier timing difference was not isolated; measurement/environment variability is a hypothesis. Raw samples are in `calls-recheck.json`. This does not establish a general performance improvement.
