# Bytecode compiler checkpoint — 2026-10-05

Baseline captured before compiler changes, including the pre-existing change in `src/execution.zig`.
`before-source.tar.gz` preserves sources, build configuration, benchmark scripts/workloads and verification fixtures.
`before-working-tree.patch` records the original uncommitted change; `environment.json` records Git and toolchain versions and the reference binary hash.
Source snapshots and executable copies are retained locally and ignored by Git.

## Scope

Remove redundant `dup`/`drop` when a standalone local increment or compound assignment discards its result. Four compiler source lines removed. VM, opcode set and artifact format unchanged.

## Current measurement protocol

`performance/scripts/run.py` now uses identical source files and independent compilation in every engine. It measures CLI compilation/artifact serialization separately from CLI execution/artifact loading. Process startup belongs to each respective phase; builds are excluded. `pipeline-command.txt`, `pipeline.log` and `pipeline.json` record a three-engine comparison (MQuickJS, saved zRun before, current zRun after), using rotating engine order, 31 samples and 5 warmups on CPU 0. Old binaries allow the original checkpoint to be measured with the new protocol without restoring sources.

The final interpretation uses this pipeline protocol. The measurements below are the earlier experiment, preserved as history.

## Earlier measurements

- Existing `run.py`: same MQuickJS-compiled bytecode, process startup/loading included. This is a runtime control: it cannot demonstrate improvements to zRun compiler output.
- Existing `run_features.py`: source compilation and execution, 15 workloads with outputs checked against MQuickJS.
- `source_line_counts` imported from the existing `run_overall.py`: nonblank source lines, using its existing file exclusions. Inline tests count as source lines.
- Both suites: CPU 0, 21 samples per engine, 3 warmups; alternating engine order. Builds completed outside timing.
- `compare_artifacts.py`: old and new compiler output, executed on the SAME new runtime, 21 samples and 3 warmups, alternating old/new order. Raw samples saved in `paired-artifacts.json`. Compiling occurs outside timing; process startup and artifact loading are included.
- `local_updates.js` deliberately exercises the changed instructions. It is a synthetic workload, not a claim about overall application performance.
- `update_semantics.js` checks standalone updates, used increment results, captured mutable variables and loop stack balance.

Full before/after logs, commands, line counts and the implementation patch are stored beside this file. Final results are in `RESULTS.md`.
