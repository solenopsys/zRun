# QuickJS 2026 Comparison

## Reference

The comparison used the official Bellard release `2026-06-04`, downloaded from
the official release page. The source archive SHA-256 was
`b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a`; the
extras archive SHA-256 is
`11549a45b25b055946eeac2a0064399297dcf80062c6c07b644e0bc5eb329817`.
`VERSION` in the checkout also says `2026-06-04`.

## Direct Workload Results

The CLI workloads under [`../workloads/cli/`](../workloads/cli/) run identical
JavaScript source on QuickJS and zRun. They include process start, parsing,
compilation, and execution. The zRun binary is built with
`zig build -Doptimize=fast`. These measurements were rerun on
2026-09-28, pinned to CPU 0, with 15 timed runs and 3 warmups. The original
record did not preserve full host/compiler metadata, so treat the table as a
historical result rather than a portable performance claim.

Milliseconds:

| Workload | QuickJS | zRun ReleaseFast | zRun slower |
|---|---:|---:|---:|
| CLI arithmetic | 8.142 | 12.340 | 51.6% |
| CLI function calls | 3.344 | 26.225 | 684.2% |
| CLI arrays | 1.363 | 1.167 | -14.4% |
| CLI component-like SSR | 0.964 | 1.720 | 78.3% |
| **CLI geometric mean** | | | **106.4%** |

These are narrow, matching-output fixtures, not a general-purpose JS engine
ranking. The CLI comparison runner is
[`../scripts/run_quickjs.py`](../scripts/run_quickjs.py).

As a control, the same 70,000-call MQuickJS bytecode image was run in both
MQuickJS and zRun with initialization outside the timed region. The in-process
medians were about 2.80 ms and 4.16 ms respectively (zRun about 1.49x slower). Opcode
histograms matched exactly, including 70,000 `call`, 70,000 `return_value`,
and 70,000 `get_arg0` executions. This is evidence of a real but much smaller
VM-side gap on that compatible bytecode. It is not an official QuickJS VM
comparison: full QuickJS uses a different bytecode/compiler ABI, so its
bytecode cannot currently be passed to zRun. Older repeated-source results
are omitted because their fixtures are not checked in and later compiler
changes made the headline call ratio obsolete.

## What the Source Comparison Shows

1. **Dispatch and bytecode optimization.** QuickJS enables computed-goto
   table dispatch on GCC/Clang (`DIRECT_DISPATCH`) and runs a bytecode peephole
   pass. In particular it fuses local read, integer/atom push, addition,
   duplicate, local write, and drop into `add_loc`. zRun uses an enum `switch`
   dispatch. The current local
   arithmetic case therefore pays both dispatch and bytecode-shape costs.
2. **Calls and frames.** QuickJS lays out local, operand-stack, argument, and
   reference slots in one exact-sized allocation in
   `JS_CallInternal`. zRun uses a fixed
   `CallFrame` array and performs explicit interpreter-level frame setup and
   teardown ([`CallFrame.init`](../../src/vm.zig#L44),
   [call/return dispatch](../../src/vm.zig#L805)). Every closure call also
   resolves the pointer through the closure hashmap
   ([`findClosure`](../../src/vm/objects.zig#L355)); this is a concrete candidate
   to isolate, not yet a proven share of the slowdown. The very large
   source-to-runtime call gap is much larger, but the compatible-bytecode
   control is about 1.49x rather than 16.66x. Isolated empty-call subtraction
   puts the marginal path at about 1.9-3.0x depending on callee lookup. Frame
   setup, dispatch, and closure resolution remain candidates for profiling;
   the direct-source difference also includes compiler lowering and bytecode
   optimizations.
3. **Allocation and objects.** QuickJS's 2026 source includes fixed-size
   allocation classes and arena/free-list paths for small blocks. zRun routes
   dynamic object/string/cell storage through its own object store and
   allocator. This is a plausible contributor for array/SSR workloads, but it
   is not enough to explain the integer or call gap. The object/property
   representation and allocation count need their own allocation-sensitive
   in-process profile before being changed.
4. **Runtime scope.** QuickJS implements a much broader language/runtime. Its
   features and full standard library are not zRun requirements. For the
   intended embedded-runtime scope, prioritize fast lowering and execution of
   the observed subset; do not import `eval`, dynamic source compilation, or
   broad standard-library compatibility just to match QuickJS.

## First Optimization Applied

zRun now recognizes local self-updates in expression statements and lowers
`x += expr` / `x -= expr` to `add_loc` / `sub_loc`. It also recognizes the
narrow form `x = x + integer_literal` or `x = x - integer_literal` when the
literal is followed immediately by the statement terminator. This bypasses a
local read, duplicate, local write, and drop sequence. The opcodes were
appended after existing values to preserve the existing bytecode numbering.
Implementation and correctness test:
[`compiler.zig`](../../src/compiler.zig),
[`opcode.zig`](../../src/opcode.zig),
[`vm.zig`](../../src/vm.zig).

In the in-process `ReleaseFast` microbench, arithmetic dispatch moved from
1,849,052 ns to 1,444,452 ns per 50,000 iterations (21.9% faster). The
steady arithmetic workload moved from 136.248 ms to 103.115 ms (24.3% faster
in zRun; same QuickJS baseline). The latest function-frame microbench is
904,913 ns versus the prior 894,492 ns (about 1.2% slower; no call-path win
demonstrated); array/string methods measured 3,006,785 ns and are too noisy to
attribute to this compiler change. This optimization is useful but does not
close the overall gap. QuickJS's optimizer already performs broader
`add_loc` fusion, including variable/argument RHS forms; zRun currently fuses
a deliberately small subset.

## Next Investigation

The order should follow measured impact:

1. Profile and reduce bytecode function-call/frame overhead using the
   in-process call benchmark. Compare frame initialization, local/binding
   representation, return/unwind work, and dispatch count separately. Preserve
   closure semantics; do not borrow caller slots without proving lifetime and
   capture safety.
2. Inspect generated code for the dispatch loop. Test a compiler-supported
   dispatch-table/computed-goto equivalent only as an isolated experiment, then
   compare dispatch-heavy arithmetic in-process. Keep the portable switch if
   Zig cannot produce a measurable improvement without fragile compiler
   assumptions.
3. Extend local-update fusion only where tests prove semantics and benchmark
   bytecode/opcode counts show the path is common. Add likely RHS-local forms
   before broad optimizer machinery.
4. Profile array/SSR allocation and string concatenation independently after
   call costs are under control. Avoid importing QuickJS's full allocator or
   object model without allocation counts and a focused A/B result.

The first dispatch-order A/B test has already been done and reverted: moving
the call handler earlier helped one global-call fixture by up to 26.5%, but
regressed the empty-loop/global-read/local-alias controls by 3-7%. Do not keep
that as a general dispatch optimization without a representative weighted
workload and a repeatable net win. Detailed figures and machine-code inspection
are in [CALL_ISOLATION.md](CALL_ISOLATION.md).

Re-run the comparisons with:

```sh
python3 performance/scripts/run_quickjs.py --quickjs /path/to/qjs --runs 15 --warmups 3
```

The comparison scripts and workload outputs are part of the evidence; do not
compare a different QuickJS build mode, CPU pinning, or fixture and label it an
engine-only speed ratio.
