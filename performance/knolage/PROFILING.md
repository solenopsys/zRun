# VM profiling handoff (2026-09-28)

These host-specific results describe the code and toolchain on that date.
Recheck current source and repeat the profile before using them to guide a new
optimization.

## Profiler is available

`/usr/bin/perf` is installed (`perf version 7.2.7-1`). The host runs Linux
`7.2.6-arch2-1`, and `perf_event_paranoid=2`. Unprivileged `cycles:u` counting
and sampling both work. Use `perf` for the next bottleneck investigation; the
older notes that say it is unavailable describe an earlier environment.

The in-process comparator runs the same MQuickJS bytecode image in MQuickJS C
and zRun, with loading outside its timer. It builds the C sources through
Zig's Clang with `-O3` and the Zig module with `-OReleaseFast` (hardcoded in
[`build.zig`](../../build.zig)). `-Doptimize=fast` does not change this
comparator. The default CPU target, `-Dcpu=native`, and `-Dcpu=znver4` resolve
to the same cached binary on this Ryzen 7 8845H host.

The benchmark timer is `std.Io.Clock.awake`, which maps to Linux
`CLOCK_MONOTONIC`; both engines use the same `timedRun` harness. Only
`prepared.run()` is inside the timed region, not bytecode loading or context
setup. Each engine gets seven timed samples and two warmups. This makes timer
choice/overhead an implausible explanation for a multi-millisecond engine
gap. The `perf stat` commands below measure the whole comparator process,
however, not just one engine's timed region.

## Reproduce a profile

From the `zrun` directory:

```sh
/path/to/mqjs -o /tmp/zrun-empty-calls.bin performance/workloads/inprocess/empty_calls.js
zig build compare -Dcpu=znver4 -- /tmp/zrun-empty-calls.bin
compare_bin=$(ls -t .zig-cache/o/*/zrun-compare | head -1)
perf record -e cycles:u -F 1999 --call-graph fp \
  -o /tmp/zrun-empty-calls.perf.data -- \
  taskset -c 0 "$compare_bin" /tmp/zrun-empty-calls.bin
perf report -i /tmp/zrun-empty-calls.perf.data --stdio -g none \
  --no-children --sort symbol
perf report -i /tmp/zrun-empty-calls.perf.data --stdio -g none \
  --no-children --sort symbol,srcline
perf annotate -i /tmp/zrun-empty-calls.perf.data --stdio \
  --symbol 'vm.VM.executeFrames__anon_30897'
```

Build/warm the comparator first, then pass the cached executable directly to
`perf`. Do not run `zig build` inside `perf record`: that also samples build
runner/compiler work and contaminates the VM profile. The comparator itself
runs both VMs plus setup and seven timed/two warmup executions; percentages
are fractions of *all* sampled cycles, not of one engine's timed region. Use
the comparator's medians for speed ratios. Replace the fixture with
`../workloads/inprocess/empty_loop.js`, `../workloads/inprocess/local_empty_calls.js`, or
`../workloads/inprocess/local_calls.js` to isolate more of the call path. `compare-stats`
checks that both VMs executed matching opcode counts; never time that
instrumented build.

For the CPU target control, warm and profile again with
`-Dcpu=znver4-avx512f` in the build command. For a quick permission check,
run `perf stat -e cycles:u -- taskset -c 0 "$compare_bin"
/tmp/zrun-empty-calls.bin`; the total still includes both engines.

For a broad hardware-counter check, use:

```sh
perf stat -e cycles:u,instructions:u,branches:u,branch-misses:u,L1-icache-loads:u,L1-icache-load-misses:u,iTLB-loads:u,iTLB-load-misses:u -- \
  taskset -c 0 "$compare_bin" /tmp/zrun-empty-calls.bin
```

On 2026-09-28, run directly on the comparator, this counted 189.2M cycles,
794.1M instructions, 136.8M branches, 12.5K branch misses, and 1.7K L1
instruction-cache misses. Branch misses were about 0.009% of branches.
Events were multiplexed to about 75% running time, and the run combines C,
Zig, and comparator overhead; these counts are a coarse screen, not
per-engine attribution. They do not point to branch prediction or L1
instruction-cache misses as the dominant issue. Repeat with scoped profiling
before drawing cache conclusions.

## Measurements

On the same 700k-call MQuickJS bytecode, two interleaved A/B repeats of the
original VM measured roughly:

| Case | `znver4` zRun | `znver4-avx512f` zRun | C in the paired builds |
|---|---:|---:|---:|
| Empty global calls | 38.66-39.28 ms | 29.44-30.18 ms | 17.4-18.95 ms |
| Local calls with argument/body | 52.21-53.60 ms | 43.65-44.44 ms | 23.76-25.11 ms |
| Empty loop | 16.73-18.60 ms | 17.88-20.53 ms | 11.1-12.45 ms |

`-Dcpu=baseline` also moved global empty calls from about 38 ms to 28 ms in
zRun, while C changed from about 18 ms to 19 ms. Arithmetic did not gain
reliably under `znver4-avx512f`; callback-array timing improved roughly 16.3
to 14.0 ms, and SSR moved only slightly. The target flag is a useful control,
not a universal performance policy. Its effect shows target-dependent code
generation or layout, but does not prove that one AVX-512 instruction is the
cause. The `znver4` `executeFrames` has ZMM instructions, some outside the hot
`.call` branch; the `znver4-avx512f` build has none there. Both builds already
use indirect jump-table opcode dispatch.

An earlier report recorded around `zig build` is contaminated by build-runner
samples; do not use its percentages to infer VM hotspots. Corrected direct
profiles of the 700k fixtures show for empty global calls: 44.15% in
`VM.executeFrames`, 40.44% in C `JS_Call`, 4.72% in Wyhash, 3.56% in
`CallFrame.init`, and 2.37% in `findString`. For local calls with an
argument/body: 45.38% in `VM.executeFrames`, 39.56% in C `JS_Call`, 6.28% in
`CallFrame.init`, 5.15% in `findString`, and 2.28% in Wyhash. Line-level
samples concentrate at the Zig opcode dispatch ([`vm.zig`](../../src/vm.zig#L312));
`perf annotate` shows the indirect jump-table dispatch is a substantial part
of this hot loop. C's call and frame handling stay inside `JS_Call`, so symbol
percentages alone cannot isolate a C-versus-Zig frame cost.

## Current code experiment

The current [`isTruthyWithObjects`](../../src/vm.zig#L1635) skips string lookup
for immediate non-string values. This is semantically valid for the current
`Value` representation: static/dynamic strings are pointers, and character
strings have their own tag. A focused test covers numeric, boolean, empty,
and non-empty string truthiness. `zig build test` passed (exit 0; the
`NotCallable` and `MaxCallDepth` diagnostic lines come from expected-error
tests).

Interleaved before/after/before runs on `znver4` gave 700k empty global calls
about 38 ms before versus 27-28 ms after, and local calls with an argument
about 52 ms before versus 41 ms after. Empty-loop time stayed near 17 ms;
arithmetic moved from about 13.75 ms to 14.05 ms, callback arrays stayed near
15 ms, and SSR templates moved from about 12.5-12.8 to 12.1 ms. A new `perf`
profile still samples `findString` and `Wyhash`, but `CallFrame.init` fell
from 7.69% to 2.28% of total samples on empty global calls. Removing one
string lookup cannot by itself explain the entire 10-11 ms improvement, and
the code change may also have shifted the interpreter's layout. Keep the
A/B data and reprofile after larger edits rather than attributing the full
gain to truthiness.

The latest change caches local/argument binding slices in `CallFrame`, so
frame switches restore precomputed views rather than rebuilding them. Three
interleaved old/new runs on the same bytecode gave medians: local calls 41.31
to 36.25 ms (-12.3%), empty global calls 27.42 to 25.72 ms (-6.2%), empty
loop 16.03 to 13.17 ms (-17.8%), and arithmetic 14.03 to 10.66 ms (-24.0%).
The gains extend to a workload without repeated interpreted calls, so these
are measured code/layout effects, not proof that slice recomputation caused
every improvement. Keep the change for now and recheck after the next VM
layout/dispatch edit.

The following `stringBytes` change handles immediate ASCII characters first
and rejects other non-pointer values before searching runtime/static strings.
On four alternating old/new runs of the same local-call bytecode, Zig median
fell from 36.20 to 29.67 ms (18.0%). A direct profile of the new binary has
no `findString` symbol above 1%; `stringBytes` accounts for about 3.6% of Zig
samples. The profile still places most VM time in `executeFrames` dispatch and
frame execution, so string lookup is no longer the main target.

## Same-Bytecode Profile Diff (2026-09-28)

The comparator loads one MQuickJS-compiled image into both VMs, so these
profiles remove compiler/code-generation differences. Record command:

```sh
perf record -e cycles:u -F 1999 --call-graph fp -o /tmp/profile.perf.data -- \
  taskset -c 0 .zig-cache/o/<compare-build>/zrun-compare /tmp/workload.bin
perf report -i /tmp/profile.perf.data --stdio -g none --no-children --sort symbol,srcline
```

### Arithmetic and Calls

The first fresh arithmetic profile showed zRun `VM.concatenate` at 14.0% and
`Store.stringLength` at 7.8% of all comparator samples. The source explained
why: zRun handled `.add` by trying string concatenation before numeric
addition (`vm.zig`); MQuickJS `OP_add` first tests whether both operands are
tagged integers and falls through to `js_add_slow` only for other types
(`mquickjs.c`, `OP_add`). Thus every ordinary integer `+` in Zig performed
string classification and pointer-index lookup before reaching the existing
integer fast path.

Moved the both-tagged-int case ahead of `concatenate` for `.add` and
`.add_loc`. Existing tests passed. Three interleaved A/B runs on the same
bytecode, pinned to CPU 0, gave:

| Fixture | Before zRun | After zRun | MQuickJS | Effect |
|---|---:|---:|---:|---:|
| 400k integer arithmetic | 12.71 ms | 7.44 ms | 8.43 ms | zRun -41%, now about 1.13x faster |
| 700k local calls with integer addition | 44.25 ms | 28.95 ms | 22.63 ms | zRun -35%, still about 1.28x slower |
| 12k SSR template renders | 13.10 ms | 12.92 ms | 2.64 ms | within measurement noise; separate hotspot |

After the change, arithmetic's visible profile was mostly `executeFrames`
(44%) and C `JS_Call` (51%) in the combined comparator sample; the string
helpers no longer appeared as significant symbols. On the call fixture the
combined profile attributed 45% to Zig `executeFrames`, 44% to C `JS_Call`,
6% to `CallFrame.init`, and 4% to Wyhash. These are percentages of all samples
from both VMs, not per-engine-normalized percentages; use the benchmark medians
for the speed ratio.

### SSR Strings

The new fast path does not fix the SSR-shaped case. In its combined profile,
zRun samples included `ArenaAllocator.alloc` (12.1%), Wyhash (8.6%), array
index hashmap growth (5.9%), `memcpy` (5.2%), `VM.concatenate` (6.2%),
`Store.stringLength` (5.8%), and `Store.stringObject` (4.6%). MQuickJS's
`string_buffer_concat_str` accounted for 1.6% of the combined samples. This
points to a different cost center: dynamic string creation/retention plus
address-index maintenance in the Zig object store, rather than integer
addition. Since these are combined-process percentages and the MQuickJS and
zRun run times differ substantially, they identify candidate paths, not a
normalized per-engine cost decomposition. Next isolate the string allocation
and object-index work with A/B variants before changing the representation.

## Callback Frame Reservation Diff (2026-09-28)

Second pass: callback-heavy array bytecode, compiled once by MQuickJS and
run in both interpreters. On CPU 0, the in-process medians were 6.47 ms for
MQuickJS and 13.43 ms for zRun (`0.48x` MQuickJS/zRun). Opcode histograms
matched exactly. In the 4,000-iteration workload there are 140,000 interpreted
function returns, 16,000 method calls, and 12,001 ordinary calls. Array plugin
callbacks invoke an interpreted closure through `invokeClosure`, which starts
a nested `executeFrames` invocation for each callback.

The profile's call graph attributes 43.1% of combined samples to Zig
`executeFrames`; its native-call branch accounts for 16.6% inclusive, with
map/filter/some/reduce callback paths visible underneath. `CallFrame.init` is
2.9% of combined samples. The significant difference is visible in the actual
function prologues from `perf annotate`:

| Engine function | Reserved native stack per invocation | Where VM frame/operand state lives |
|---|---:|---|
| MQuickJS `JS_Call` | 120 bytes (`sub $0x78,%rsp`) | Shared `JSContext` stack (`ctx->sp`, `ctx->fp`) |
| zRun `executeFrames` | 62,760 bytes (`sub $0xf528,%rsp`) | Local `[64]CallFrame` array; each frame embeds operand and binding storage |

This is a 523x difference in reserved native stack size per interpreter entry.
It looked especially relevant because the native array methods re-enter the
interpreter for each callback. The large array is declared at
[`vm.zig:275`](../../src/vm.zig#L275); MQuickJS `JS_Call` reads its current stack
pointers from `JSContext` in the MQuickJS source (`mquickjs.c`, `JS_Call`).
Reserving this much address space does not mean all 62 KiB is committed or
cleared on every call, so this is not itself proof of a CPU bottleneck.

### Rejected Frame-Pool A/B

Tried replacing the local `[64]CallFrame` array with eight inline frames and a
spill block for frames 9-64, preserving the maximum call depth. The first build
used zero-value struct initialization and `perf` immediately showed `compiler_rt.memset`
consuming 80% of samples while clearing the 6,352-byte inline frame store; that
variant was discarded. Initializing only the spill pointer removed the
`memset`, and `executeFrames`'s prologue reservation fell from 62,760 to
20,584 bytes, but it did not improve the workload. Four interleaved runs of
this final variant versus the original were slower: arithmetic 10.81 vs 7.57
ms, calls 34.96 vs 29.53 ms, arrays 15.29 vs 13.85 ms, and SSR 13.62 vs 12.94
ms. The frame-pool code was reverted; the original 64-frame stack remains.
Conclusion: reducing reserved stack size alone is not a performance fix here.

### Resolved Callback A/B

The callback profile also exposed a repeated closure lookup: array methods
validated the callback before entering the loop, but `callback()` called
`findClosure` again for every item. Resolve it once to a closure pointer or
native index before the loop. Three interleaved same-bytecode A/B runs gave
array medians of 13.61 ms before and 13.12 ms after (-3.6%); arithmetic and SSR
controls stayed within noise. In the updated profile, Wyhash no longer appears
among significant symbols. The array workload still takes about twice as long
as MQuickJS, so this removes redundant lookup but does not explain the main
remaining gap.

Next target the interpreter dispatch/call path itself, not another frame-array
size change or callback pointer lookup.

## Next localization

The tested local-call fixture is now about 1.28x slower than MQuickJS after
removing the numeric string-probe overhead. Remaining call samples concentrate
in VM dispatch/frame execution and `CallFrame.init`; investigate call/return
state and closure resolution on ordinary bytecode calls with focused
same-bytecode A/B runs. A prior
`VM`-by-pointer parameter change and `.call` branch reordering regressed
control workloads and were reverted. No single dispatch instruction has been
shown to justify inline assembly yet. SSR is a separate target: isolate
dynamic-string allocation/retention and object-index costs first.

For the next pass, profile one fixture at a time (`../workloads/inprocess/empty_calls.js`,
`../workloads/inprocess/local_calls.js`, then `../workloads/inprocess/empty_loop.js`), compare flat
`--no-children` symbol and source-line reports, and inspect only hot symbols
with `perf annotate`. Keep `perf stat` totals as supporting context: because
the current comparator executes both engines in one process, it cannot say
which VM incurred a particular cache miss or cycle. Record the exact build
target, fixture, median timings, and profile filename with every A/B result.
