# Interpreted Call Isolation

This suite separates ordinary VM overhead from the extra work around an
interpreted function call. Each source is compiled once by MQuickJS into its
bytecode image; that same image is run in both VM implementations. Context
creation, bytecode loading, and relocation are outside the timer. The table
uses 700k-iteration fixtures to reduce timer noise; MQuickJS is compiled
`-O3`, zRun is `ReleaseFast`, and runs are pinned to CPU 0.

From the repository root, compile a fixture with an external MQuickJS `mqjs`
binary and run the comparator:

```sh
/path/to/mqjs -o /tmp/case.bin performance/workloads/inprocess/empty_loop.js
taskset -c 0 zig build compare -Doptimize=fast -- /tmp/case.bin
taskset -c 0 zig build compare-stats -Doptimize=fast -- /tmp/case.bin
```

Substitute any fixture below for `performance/workloads/inprocess/empty_loop.js`.
All tested images had identical per-opcode execution counts in both VMs.

## Measurements

This table is the baseline before the immediate-value truthiness change on
2026-09-28. Current before/after numbers and sampled profiles are in
[PROFILING.md](PROFILING.md).

| Fixture | Isolated behavior | MQuickJS | zRun | zRun/MQuickJS |
|---|---|---:|---:|---:|
| [Empty loop](../workloads/inprocess/empty_loop.js) | 700k local loop iterations, no repeated interpreted calls | 11.242 ms | 17.574 ms | 1.56x |
| [Global function reads](../workloads/inprocess/global_function_reads.js) | 700k reads of a global function value, no repeated calls | 13.832 ms | 19.671 ms | 1.42x |
| [Empty global calls](../workloads/inprocess/empty_calls.js) | 700k calls through a global function binding; empty callee | 18.426 ms | 38.890 ms | 2.11x |
| [Empty local calls](../workloads/inprocess/local_empty_calls.js) | Same empty callee, copied to a local before the loop | 16.992 ms | 28.269 ms | 1.66x |
| [Calls with arithmetic](../workloads/inprocess/calls.js) | 700k global-scope calls with one argument and integer addition | 27.96 ms | 41.60 ms | 1.49x |
| [Local calls with arithmetic](../workloads/inprocess/local_calls.js) | Same call and arithmetic inside a function with local loop state | 24.70 ms | 52.08 ms | 2.11x |

Subtracting the no-call loop from the global empty-call case estimates the
marginal cost of the combined call path: about 7.184 ms in MQuickJS and 21.316
ms in zRun for 700k iterations, approximately 2.97x apart. With a local
function alias, subtracting the no-call loop gives 5.750 ms versus 10.695 ms,
about 1.86x apart. These deltas include callee lookup, frame entry/return, and
dropping the empty result; they are not pure measurements of one instruction.
The loop/name-resolution work is not perfectly matched, so treat the deltas as
localization evidence, not an exact cost model.

The read-only global-reference control is important: it does **not** reproduce
the call slowdown by itself. Replacing a global call target with a local alias
helps zRun more than MQuickJS, but the data does not justify blaming
`get_var_ref` alone. The excess is in the combined interpreted-call path and
its interaction with closure lookup/frame state.

An earlier QuickJS source comparison reported a much larger ratio because it
compared independently compiled bytecode streams as well as their VMs. Before
the compiler correction below, a 70k-call fixture measured 16.66x elapsed time,
not 16.66x for the VM call implementation alone. Same-bytecode MQuickJS
controls put the call-heavy workload around 1.5x, with empty-call marginal
deltas around 1.9-3.0x depending on callee lookup. See [the QuickJS comparison](QUICKJS_2026.md).

The 2026-09-28 compiler change (conditional self-binding, used-only captures;
see [the optimization log](OPTIMIZATIONS.md#named-function-self-binding-and-over-capture-2026-09-28))
removed the largest source-side contributor to that QuickJS call ratio: the
per-invocation `fclosure8` self-binding closure for named functions. The steady
call fixture measured about 2.0x QuickJS instead of 16.66x. These same-bytecode
controls are unaffected, because the fix changes zRun's own code generation,
not the VM. The residual call cost measured here (about 1.5-2.0x) is therefore
the current VM-side target.

## Dispatch Experiment

An A/B/A experiment moved the `.call` handler earlier in the opcode dispatch
chain. On the 70k global empty-call fixture, zRun improved from about 3.84 ms
to 2.85-3.08 ms (roughly 20-26%); MQuickJS stayed around 1.82-1.87 ms. On
700k controls, however, the candidate regressed zRun empty loop by 7.1%,
global function reads by 3.3%, and local-alias empty calls by 6.8%, while the
global empty-call case improved by 26.5%. This is code-layout/workload
sensitivity, not a broad dispatch win, so the branch order was reverted. No
runtime source change from this experiment remains.

## Machine-Code Inspection

On the tested x86_64 ReleaseFast build, `executeFrames` starts with an indirect
jump through the opcode table (`jmp *table(,%rcx,8)`). Zig has already lowered
the enum switch to a jump table; handwritten dispatch assembly is not a
justified next step. The same function reserves `0x2c618` (181,784) bytes of
stack, largely because it embeds 64 `CallFrame`s, each with a 256-value stack
and 32 bindings. `CallFrame.init` remains an out-of-line call and compiles to
about 1.7 KiB of machine code; `findClosure` is also out of line. These are
structural candidates for targeted A/B work, not proof that the Zig compiler
is generating a poor dispatch loop.

`perf` is now installed and hardware `cycles:u` sampling works. The first
profiles and exact reproduction commands are in [PROFILING.md](PROFILING.md).
The isolated deltas above remain useful controls. Test frame initialization
and closure resolution against them and keep only repeatable wins. Do not add
inline assembly until a profile identifies a specific code-generation issue.
