# Optimization Log

The measurements below are historical snapshots from the original project
layout and changing benchmark revisions; ratios are not a current release
baseline. The correctness fixtures are now run through the consolidated
`verification/run.sh` entry point.

This is the running record of performance hypotheses tested in zRun. Add an
entry whenever an optimization is tried, including negative results. "Keep"
means the implementation remains in the tree; it does not imply every change
has an independently isolated speedup.

Code links are relative to this file and point to the relevant implementation.

## Kept Changes

| Change and code | What changed | Observed effect | Status |
|---|---|---|---|
| [VM dispatch](../../src/vm.zig#L239) | Replaced `std.enums.fromInt` validation/conversion on every dispatch with a range check in checked builds and direct `@enumFromInt`. Generated code previously compared against enum tags linearly. | Largest localized win. In-process arithmetic moved from roughly 48-50 ms to roughly 18 ms in early runs; later work brought the pinned workload to 10.32 ms vs 9.80 ms for C. Early and current runs are not directly comparable. | Keep; dispatch/loop is near parity. |
| [Binary dispatch](../../src/vm.zig#L514) and [`binary`](../../src/vm.zig#L951) | Pass binary opcodes as comptime values and add raw tagged-integer add/subtract/comparison paths before generic decoding. | Further arithmetic improvement. A controlled intermediate run was about 12.94 ms vs 6.71 ms C; the current pinned result is 10.32 ms vs 9.80 ms C. The combined measurements do not isolate comptime dispatch from raw fast paths. | Keep; generic type/error paths remain for other values. |
| [Compact local/argument opcodes](../../src/vm.zig#L684) | Split compact get/put opcodes into direct cases instead of calculating the index and operation through helpers. | Local arithmetic improved across runs from about 13-14 ms to about 11-12 ms; current pinned result is 11.16 ms vs 9.25 ms C. Treat intermediate percentages as approximate. | Keep; direct cases are in the dispatch loop. |
| [ReleaseFast checks](../../src/vm.zig#L239), [`push`/`pop`/`peek`](../../src/vm.zig#L776), and [operand readers](../../src/vm.zig#L1061) | Omit repeated bytecode, operand, branch, index, and stack bounds checks in `ReleaseFast`; checked builds retain validation. | Removing hot-path checks improved pinned arithmetic from around 13 ms to around 10.5 ms in the relevant iteration (about 20%, subject to run variance). Current global-loop result is 1.05x C. | Keep with a contract: `ReleaseFast` expects valid, trusted bytecode; it is not for malformed/untrusted bytecode. |
| [Skip empty capture searches](../../src/vm.zig#L88) | Avoid scanning child capture metadata when there are no nested functions. | No repeatable timing improvement established. | Keep as a cheap redundant-work guard; not a demonstrated speedup. |
| [Relocation-only image init](../../src/bytecode.zig#L91), [CLI use](../../src/main.zig#L68), and [benchmark use](../../src/performance_compare.zig#L68) | Added `Image.initForRelocation`; callers that immediately relocate avoid a separate structural walk because `relocate` validates before rebasing. General `Image.init` still walks/validates. | No material end-to-end CLI improvement measured. | Keep to avoid duplicate validation for these callers; revisit if validation ownership changes. |
| [Heap address indexes](../../src/vm/objects.zig#L70) | Added address-keyed indexes for arrays, objects, and dynamic strings so `findArray`, `findObject`, and `findString` do not linearly scan every prior allocation. | The mixed 30k-iteration optional/spread microbench moved from about 304.7 ms to 7.8 ms in Zig (about 39x faster). The isolated allocation-heavy spread path remains 3.4x slower than MQuickJS; see [feature results](WORKLOAD_BASELINE.md). | Keep; correctness is tested across index growth/rehash. |
| [Closure address index](../../src/vm/objects.zig#L45) | Replaced the linear `closures` scan in `findClosure` with an address hash index. | On the source-CLI array workload, median fell from 482.2 ms to 51.4 ms (9.4x faster); relative to MQuickJS it is still 5.3x slower. The case creates a fresh inline callback on every outer loop, making the old lookup quadratic. | Keep; closure identity is checked across index growth. |
| [Native method arguments](../../src/vm.zig#L1002) | Prepend method receivers in an inline 8-value buffer; allocate only for larger calls. | No isolated win distinguishable in the whole-source suite yet. Removes one heap allocation/free from ordinary native method calls. | Keep provisionally; profile separately. |
| [Array result construction](../../src/vm/objects.zig#L125) and [array methods](../../src/plugins/array_methods.zig#L17) | Reserve result capacity and fill map/filter/flatMap results directly instead of building a temporary list and copying into a second array. | No stable effect in the end-to-end array workload beyond run noise. | Keep for lower allocation/copy count; callback-mutation semantics need a dedicated test. |
| [Frame bindings](../../src/vm.zig#L42) | Store uncaptured local/argument values inline; use heap cells only for closure-captured bindings. | The in-process 5k-call fixture moved from about 46% behind to about 19% behind in the latest median. Arithmetic-loop medians range from about 16% to 27% behind. | Keep; capture and mutation verification passes. |
| [Cached frame binding slices](../../src/vm.zig#L57) | Cache the local and argument slices in each `CallFrame` at initialization; frame switches restore them directly instead of selecting backing storage and recomputing slice bounds. | Three interleaved runs on the same bytecode: local calls 41.31 to 36.25 ms (-12.3%), empty global calls 27.42 to 25.72 ms (-6.2%), empty loop 16.03 to 13.17 ms (-17.8%), arithmetic 14.03 to 10.66 ms (-24.0%). Since gains also appear in the no-call arithmetic case, treat the magnitude as layout-sensitive and verify after later VM layout changes. | Keep provisionally; correctness suite passes, perf samples still show dispatch as the dominant VM cost. |
| [Immediate-value string guard](../../src/vm.zig#L1394) | Return before dynamic/static string lookup for non-pointer immediates; decode immediate ASCII chars directly. | Four interleaved old/new blocks on identical local-call bytecode: old median 36.20 ms, new 29.67 ms (18.0% less Zig runtime). Direct `perf` profile no longer shows `findString` among >=1% symbols; `stringBytes` is about 3.6% of Zig execution samples. | Keep; 66 tests pass, including static/dynamic string resolution and immediate-value rejection. Recheck other workloads because measured effect depends on how often operators stringify values. |
| [Inline frame stack sizing](../../src/vm.zig#L14) and [upstream stack metadata](../../src/bytecode.zig#L263) | Reduce each frame's inline operand stack from 256 to 16 `Value`s and use MQuickJS's computed per-function `stack_size` for overflow allocation instead of forcing every function to 256. | No repeatable runtime change in arithmetic, loops, calls, arrays, or SSR. Shrinks the fixed 64-frame reserve by about 120 KiB per VM entry; high-stack functions use a heap overflow stack. | Keep as a stack-footprint improvement, not a speed claim. MQuickJS compiler emits the exact max stack; the 66-test suite and all four upstream benchmark fixtures execute successfully. |
| Rejected: dynamic string lookup order/cache | Tried dynamic hashmap lookup before static strings and an 8-entry pointer cache for resolved string bytes. | Map-first was within noise on SSR (0.636 to 0.624 ms); adding the pointer cache rose to 0.650 ms (about 4% slower than map-first). | Reverted. Keep the simpler static-first lookup until a larger SSR fixture/profile justifies a different representation. |
| Rejected: preformatted primitive concatenation | Tried classifying/formatting primitive operands once before allocating and copying a concatenated string. | Six interleaved SSR A/B pairs gave medians 604.4 vs 602.4 us (about 0.3%); call/arithmetic controls were also within run noise. | Reverted; no stable speedup to justify a second concat path. Profile still points to concatenation/string handling as the SSR gap. |
| [Array/object pointer cache](../../src/vm/objects.zig#L314) | Added a small fixed cache in front of array and object address indexes; hashmap remains the fallback and ownership check. | Current fixed-bytecode CLI arrays are near parity at 0.95x; source array callback case remains about 0.21x. No isolated A/B result attributes the difference to this cache. | Keep provisionally; avoid widening without a measured win. |
| [Native method cache](../../src/vm.zig#L1017) | Cache the last eight receiver-kind/property-name to native-method resolutions per VM execution. | Source string workload has measured between 0.66x and 0.74x versus an earlier 0.61x run; timings vary materially. | Keep provisionally; lookup is in the repeated string-method path. |
| [Hoisted capture scan](../../src/vm.zig#L55) | Split frame initialization for functions with no nested functions so the no-child check is outside local/argument loops. | No standalone, repeatable gain established. | Keep as a low-risk simplification of the common path. |
| [Resolve array callback once](../../src/plugins/array_methods.zig#L10) and [`invokeClosure`](../../src/vm.zig#L236) | Resolve each callback to a closure pointer or native-function index before entering the map/filter/find/some/flatMap/reduce loop. Earlier code validated once but repeated `findClosure` hash lookup for every element. | Three interleaved same-bytecode A/B runs on the 4,000-iteration array workload: zRun 13.61 to 13.12 ms (-3.6%); arithmetic 7.50 to 7.66 ms and SSR 12.58 to 12.74 ms (within noise). The fresh profile no longer shows Wyhash among significant symbols. | Keep; removes redundant per-element closure resolution. The overall array gap remains about 2x MQuickJS, so this is a small optimization, not the main cause. |
| [Object-literal concise methods](../../src/compiler.zig#L1498) | Parse `name(args) { ... }` and emit the existing closure and object-field bytecode; no new VM opcode or runtime subsystem. Added correctness coverage for closure capture/`this` and a render-method workload. | Feature passes on zRun and MQuickJS. The SSR-shaped case measured 0.42x end-to-end and 0.24x in-process (MQuickJS/zRun); adding shorthand syntax did not remove the existing string-building/call-frame cost. | Keep as baseline JS syntax; performance target is not met. Continue profiling existing VM paths, not method syntax. |
| [Local self-update fusion](../../src/compiler.zig#L1250), [opcodes](../../src/opcode.zig#L144), and [VM handlers](../../src/vm.zig#L755) | Lower local `+=`/`-=` and narrow `x = x +/- integer_literal` statements directly to `add_loc`/`sub_loc`, skipping local read/dup/write/drop bytecode. Opcode tags were appended to preserve existing values. | In-process arithmetic dispatch: 1,849,052 ns to 1,444,452 ns per 50k iterations (-21.9%). Steady arithmetic: 136.248 ms to 103.115 ms (-24.3%). Function-frame microbench is 1.2% slower in the latest run; no call-path win demonstrated. See [QuickJS comparison](QUICKJS_2026.md). | Keep; targeted compiler optimization. QuickJS's optimizer fuses a broader set of equivalent bytecode patterns. |
| [Immediate truthiness check](../../src/vm.zig#L1635) | For non-pointer, non-character values, evaluate truthiness directly without searching static/dynamic strings first. | A/B/A on `znver4` and the same bytecode: 700k empty global calls about 38 ms to 27-28 ms; local calls with an argument about 52 ms to 41 ms. Empty loop stayed near 17 ms; arithmetic regressed about 2%, while array and SSR workloads showed no material regression. `perf` confirms fewer `findString` samples, but the full gain is larger than this lookup alone and may include code-layout effects. | Keep for the valid tag guard and measured call gain; reprofile after larger VM edits. See [profiling handoff](PROFILING.md). |
| [Tagged-integer addition before string coercion](../../src/vm.zig#L715) | For `+` and `add_loc`, route two tagged integers to the existing integer fast path before probing for strings. Mixed types and string operands still use the existing coercion/concatenation path. This mirrors MQuickJS `OP_add`, which checks both-int operands before `js_add_slow`. | Three interleaved same-bytecode A/B runs: arithmetic 12.71 to 7.44 ms (-41%); calls 44.25 to 28.95 ms (-35%); SSR templates 13.10 to 12.92 ms (within noise). Arithmetic moved from 0.66x to 1.13x MQuickJS/zRun; calls from 0.51x to 0.78x; SSR stayed about 0.20x. The old arithmetic profile sampled `concatenate` at 14.0% and `stringLength` at 7.8%; neither remained significant after the change. | Keep; tests pass. This is a confirmed hot-path issue, not a general claim that Zig is slower. SSR remains a separate allocation/string-indexing target. See [the differential profile](PROFILING.md#same-bytecode-profile-diff-2026-09-28). |
| [Conditional self-binding and used-only captures](../../src/compiler.zig#L94) | Emit the per-invocation self-reference closure (`fclosure8`/`put_loc`) only when a named function's body actually references its own name; capture a parent local only when the body references it, using one [`collectReferencedNames`](../../src/compiler.zig#L422) scan per unit instead of a per-local source rescan. | Named 700k-call fixture 292.9 to 45.6 ms (6.4x faster); the same body written as an anonymous function-expression 106.8 to 45.4 ms. Both land at about 1.7-2.0x MQuickJS instead of 12.8x (named) and 4.7x (anonymous). Steady-vs-QuickJS calls fell from about 15.4x to about 2.0x and arithmetic from about 4.2x to about 2.2x. Fixed-bytecode, arrays, and SSR are unchanged. | Keep; 66 tests and `verification/run.sh` pass. See the subsection below. |
| [Heap-allocated parser loop contexts](../../src/compiler.zig#L113) | The `Parser` embedded `loops: [64]LoopContext`, and each `LoopContext` held two `[256]usize` operand arrays, so every `compileUnit` (once per function) zero-initialized about 256 KiB. Moved the array out of the struct to `loops: []LoopContext = &.{}`, allocated uninitialized with `allocator.alloc(LoopContext, 64)` after parser construction, and freed on both success and error paths. | Compile-only benchmark 6-8x faster: `arithmetic` 43.6 to 6.56 us (0.10x to 0.66x), `calls` 71.1 to 11.41 us (0.08x to 0.51x), `arrays` 38.2 to 8.26 us (0.12x to 0.52x), `ssr` 75.9 to 11.17 us (0.09x to 0.66x). `gdb` showed the 265,736-byte `memset` disappear. | Keep; 66 tests and all verification suites pass. See the subsection below. |
| [Rope strings](../../src/vm/objects.zig#L341) | `StringObject` can now be an unflattened `left+right` node; `createConcat` builds an O(1) node, `flattenString` materializes bytes once (iteratively), and `stringLength`/`stringObject` read length/identity without flattening. `VM.concatenate` uses a rope fast path when both operands are strings and the total is `>= 32`; `.add`/`add_loc` and `.length` classify with `stringLength` instead of `stringBytes` so the hot path never flattens. | Source `ssr` median `0.975` ms QuickJS / `1.711` ms zRun (`0.57x`, `+75.4%`), down from about `8.29` ms (`0.16x`, `+511.5%`) — roughly 4.8x faster and now in line with the general VM gap. `ssr_big.js` (800 rounds) 1.00 s to 0.52 s; `sys` time 0.63 s to 0.22 s. | Keep; historical correctness suites passed. See the subsection below. |

## Named-Function Self-Binding and Over-Capture (2026-09-28)

This was the dominant cause of the source-level call gap against MQuickJS. It is
a **compiler** effect, not a VM-execution effect: executing the same upstream
bytecode image in zRun stayed near 1.5x MQuickJS, while zRun executing its own
compiled image of the call fixture was more than 10x slower.

### Root cause

`compileUnit` treated two compiler behaviors as unconditional:

- **Per-invocation self-binding.** For every named function declaration it
  declared a local for the function's own name and emitted `fclosure8 0;
  put_locN` at the top of the body. That prologue therefore ran on *every*
  call, even for functions that never reference themselves. Each execution
  allocated a fresh `ClosureObject`, duplicated its captures, appended to the
  store lists, and inserted into the closure index
  ([`createClosure`](../../src/vm/objects.zig#L281)).
- **Capture-all-parents.** The capture loop captured every enclosing local that
  was not shadowed, without checking whether the body used it. Unused captures
  forced the parent's loop locals to be boxed into heap `Cell`s and enlarged
  every closure, so non-call workloads paid too.

The named-vs-anonymous control isolates the self-binding: for the same body and
call count, `function addOne(v){...}` took 292.9 ms while `var addOne =
function(v){...}` took 106.8 ms, with MQuickJS at about 23 ms for both. Opcode
histograms on `../workloads/inprocess/calls.js` showed `fclosure8 = 700001` for the named
form (one allocation per call) versus `fclosure8 = 1` for the anonymous form.

### Change

- Self-binding is now emitted only when `referenced_names.contains(name)`
  ([compiler.zig:136](../../src/compiler.zig#L136)), so non-recursive named
  functions carry no per-call prologue. Recursive functions keep correct
  behavior.
- Captures are limited to referenced names
  ([compiler.zig:94](../../src/compiler.zig#L94)). Names are collected once per
  compilation unit by
  [`collectReferencedNames`](../../src/compiler.zig#L422); the scan is
  deliberately conservative (it can match inside strings/comments), which only
  keeps an unnecessary capture and never drops a needed one.

### What did not change (negative results)

- **Same-bytecode execution is untouched.** `compare`/`run.py` on a fixed
  MQuickJS image is unchanged (0.78-0.99x). The bug was in zRun's own code
  generation, so only the source path moved.
- **`arrays` and `SSR` are unchanged.** Their call counts are too low to show
  the per-call closure cost. SSR at this point was dominated by the flat-copy
  string concatenation in [`concatenate`](../../src/vm.zig#L1359) (about 6.5x
  QuickJS in steady mode), which was addressed later the same day by rope
  strings (see [Rope Strings](#rope-strings-for-concatenation-2026-09-28)).
- **Compile time did not improve from this change.** Replacing the new per-local
  reference scan with the single-pass set did not move `compile-bench`: it
  remained 0.08-0.11x (about 9-13x MQuickJS) at the time. The reference scan was
  not a compile-time factor; the real compile cost was the unrelated parser
  `memset` fixed later the same day
  (see [Parser Loop-Context Zeroing](#parser-loop-context-zeroing-2026-09-28)).
  Allocating the referenced-name set on every compilation unit also produced no
  measurable compile-time delta.
- **No regression in other call shapes.** Empty/global/local call controls and
  the feature suite re-ran cleanly; the change only removes work that was
  never semantically required.

## Parser Loop-Context Zeroing (2026-09-28)

This was the dominant cause of the compile-only gap against MQuickJS and was
found by profiling the compiler itself, not the VM.

### Root cause

`Parser` embedded `loops: [64]LoopContext` (`[compiler.zig:557](../../src/compiler.zig#L557)`),
and each `LoopContext` contained `break_operands: [256]usize` and
`continue_operands: [256]usize` (`[compiler.zig:560](../../src/compiler.zig#L560)`).
Constructing a `Parser` therefore materialized and zero-initialized about
256 KiB on **every** `compileUnit` call, i.e. once per function in the source.

The earlier removal of the array *element* defaults (`[_]usize{0} ** 256` to
`undefined`) did not help: Zig still materialized the outer `[64]LoopContext`
aggregate. `perf` on a small compilation harness attributed about 80% of cycles
to `compiler_rt.memset`, and `gdb` breakpoints on `memset` showed repeated
262-266 KiB fills. A minimal repro confirmed that an `undefined` large array
field in a struct literal still emits a full `memset` when the value is used.

### Change

- `loops` is now `[]LoopContext = &.{}` (`[compiler.zig:557](../../src/compiler.zig#L557)`),
  a 16-byte slice instead of an inline 256 KiB array.
- `compileUnit` allocates `allocator.alloc(Parser.LoopContext, 64)` after the
  parser is built (`[compiler.zig:122](../../src/compiler.zig#L122)`). Allocation
  returns uninitialized memory, so no `memset` is emitted per function.
- The storage is freed in `Parser.deinit` and on the success path
  (`[compiler.zig:583](../../src/compiler.zig#L583)`). Non-last `free` on a
  `FixedBufferAllocator` is a safe no-op; general allocators free normally.
- `LoopContext.break_operands` / `continue_operands` remain `undefined`; only
  `[0..break_count]` / `[0..continue_count]` are ever read.

### Result

`zig build compile-bench -Doptimize=ReleaseFast` moved from 0.08-0.12x to
0.51-0.66x (about 6-8x faster). `zig build test` passes 66 tests and the full
verification matrix from the original test layout passed and is
green. Source-level CLI results also improved, though those timings are noisy:
one `run_quickjs.py` run reported a +26.4% geometric mean source gap versus
QuickJS (down from prior runs around +150% in the steady harness).

### What did not change (negative results)

- **Emitted bytecode is identical.** The change only relocates compiler-internal
  scratch storage; it does not alter code generation, so fixed-bytecode
  and the source-VM check do not move for this reason.
- **Removing only the array element defaults was not enough.** It must be taken
  out of the parser struct entirely; leaving an inline `[64]LoopContext` (or any
  `undefined` large aggregate field) still emits the `memset`.
- **Steady-mode VM workloads are unaffected in principle.** Because that suite
  compiles once and repeats the workload, a one-off parser allocation cannot
  change it; the residual gap there was VM/string cost, addressed separately by
  [rope strings](#rope-strings-for-concatenation-2026-09-28).

## Rope Strings for Concatenation (2026-09-28)

This was the dominant cause of the source `ssr` gap against QuickJS. It is a
**runtime string allcation** effect: `html = html + renderItem(i)` in a loop
copied the whole accumulated string on every iteration.

### Root cause

[`VM.concatenate`](../../src/vm.zig#L1359) eagerly allocated and copied
`left.len + right.len` bytes on every `+`, so a loop that grows a string by a
small piece each iteration is O(n²) in bytes copied. Measured on
`performance/workloads/cli/ssr.js`: QuickJS `1.355` ms vs zRun `8.286` ms
(`0.16x`, `+511.5%`), roughly 4x worse than the general VM gap. `perf` on an
800-round `ssr_big.js` (~1.0 s, 0.63 s in `sys`) attributed 21.7% to
`ArenaAllocator.alloc`, 12.7% to `Store.findString`, 10.6% to `memcpy`, and the
process spent most sys time servicing page faults from the O(n²) retained
intermediates (the runtime uses an `ArenaAllocator`, so freed intermediates were
never reclaimed anyway).

### Change

- [`StringObject`](../../src/vm/objects.zig#L129) gained lazy nodes:
  `{ bytes, left, right, length, flat }`. A node is either a flat byte slice or
  an unflattened `left + right` pair.
- [`createConcat`](../../src/vm/objects.zig#L341) creates an O(1) node (overflow
  checked). [`flattenString`](../../src/vm/objects.zig#L359) materializes bytes
  once using an iterative two-list traversal (no recursion, no depth cap).
- [`stringLength`](../../src/vm/objects.zig#L388) and
  [`stringObject`](../../src/vm/objects.zig#L401) return length/identity without
  flattening; [`findString`](../../src/vm/objects.zig#L485) flattens only when
  bytes are actually requested, and consults the existing pointer cache first.
- `.add` / `.add_loc` and `.length` ([vm.zig:715](../../src/vm.zig#L715),
  [vm.zig:1021](../../src/vm.zig#L1021)) classify with `stringLength`; using
  `stringBytes` there would have flattened the accumulator on every `+` and
  defeated the rope. `concatenate` now returns `?Value` so the string/numeric
  decision and the fast path are one pass over the operands.
- Fast path threshold is 32 bytes; smaller or mixed (string+number) results
  still use the existing flatten-and-copy path, which keeps `createStringOwned`
  as the single flat-string constructor.

### Result

`run_quickjs.py` source `ssr`: QuickJS `0.975` ms / zRun `1.711` ms
(`0.57x`, `+75.4%`), versus `0.16x` before — about 4.8x faster, and now
comparable to `arithmetic` (`0.64x`) and `calls` (`0.52x`) rather than being an
outlier. The 800-round fixture dropped from 1.00 s to 0.52 s. `zig build test`
passes 66 tests and the original verification matrix is green; `ssr.js` output is
byte-identical to QuickJS.

### What did not change (negative results)

- **Eager allocation was not the only cost, and not a copied-byte cost.** Even
  with ropes, the workload still allocates a `StringObject` per node and per
  intermediate small string, so `ArenaAllocator.alloc`, `string_index` hashing
  (`wyhash`), and `Store.deinit` remain the top symbols. The fix removes the
  quadratic copying and the page-fault pressure, not allocation itself.
- **Classifying with `stringBytes` defeats ropes.** `stringBytes` calls
  `findString`, which flattens; the first version of this change kept that call
  in the `.add` decision and measured essentially no improvement until
  `stringLength` replaced it in both `.add`/`add_loc` and `.length`.
- **`get_length` also needed the non-flattening path.** `render().length` was
  flattening the result each round; `stringLength` returns the stored length
  directly.
- **No effect on non-string workloads.** `arithmetic`, `calls`, and `arrays`
  are within run noise; their values are unaffected by the string
  representation.

## Tried, No Longer Applied

These experiments were tested and reverted. Repeat only with a new, specific
hypothesis or a materially different benchmark.

| Experiment and affected code | What was tried | Result | Current state |
|---|---|---|---|
| Duplicate capacity check in `VM.push` / `ExecutionStack.push` ([current `push`](../../src/vm.zig#L776)) | Removed the second capacity check. | No measurable improvement. | Reverted. |
| [`CallFrame.init`](../../src/vm.zig#L36) / `CallFrame.deinit` | Forced frame lifecycle helpers inline. | No stable win; call timings were unchanged or worse. | Reverted. |
| Compact inline bindings ([frame storage](../../src/vm.zig#L42)) | Replaced 16-byte `{ value, captured pointer }` slots with 8-byte values plus a capture bitmap. | The repeated in-process call comparison fell to 0.60x C/Zig; restoring the prior slot layout returned it to 0.71-0.72x. The extra bitmap/overflow branches outweighed the smaller frame. | Reverted; retain the direct `Binding` representation. |
| Borrow call arguments from caller stack ([`CallFrame.init`](../../src/vm.zig#L55)) | Avoided copying bytecode-call arguments into callee bindings by temporarily pointing bindings at caller stack slots. | Two in-process call comparisons fell to 0.61-0.62x from 0.71-0.72x. The extra indirection on every argument read outweighed the entry copy. | Reverted; caller and callee keep independent frame storage. |
| One-pass inline string builder ([`concatenate`](../../src/vm.zig#L1096)) | Replaced exact sizing plus a write pass with a 128-byte inline builder and heap fallback. | In-process large SSR moved only from 0.23x to 0.25x; short SSR CLI regressed from 0.96x to 0.48x because the inline result had to be copied into owned storage. | Reverted; exact-sized single output allocation is faster for these fragments. |
| Closure lookup cache ([closure lookup](../../src/vm/objects.zig#L329)) | Added an eight-entry pointer cache before the closure hashmap. | No repeatable callback win; ordinary function-call measurements varied from 0.71x to 0.60x during the experiment. | Reverted; keep direct hashmap lookup. |
| Direct closure kind word ([`ClosureObject`](../../src/vm/objects.zig#L110), [`findClosure`](../../src/vm/objects.zig#L355)) | Temporarily removed the closure address hashmap and identified closures from a one-word tag at the start of the allocation, analogous to C's in-object class id. | Five interleaved old/new runs appeared 11-13% faster in absolute Zig time, but the paired C control shifted by about 33% across binaries and the current same-bytecode CLI call result stayed near 1.4x MQuickJS. The comparison did not isolate a causal win. | Reverted; keep the validated address index until a controlled A/B confirms a benefit. |
| Move-to-front array/object cache ([pointer cache](../../src/vm/objects.zig#L25)) | Promoted cache hits to the front to preserve repeatedly used arrays across transient results. | No measurable source-array change: 50.7 ms versus 50.4 ms in an 11-run pair. | Reverted to the simpler FIFO cache. |
| Single-frame callback dispatch ([`VM.invoke`](../../src/vm.zig#L209)) | Scanned callback bytecode for call opcodes and used one frame of storage for callbacks without nested calls. | No measurable benefit; source array performance remained about 5.5x slower than MQuickJS. | Reverted; profile before revisiting frame reservation. |
| `CallFrame.initSimple` ([current frame init](../../src/vm.zig#L36)) | Added an inline initializer for common non-capturing calls. | No stable improvement in empty-call or arithmetic-call workloads. | Reverted. |
| Frame bindings and captured locals/arguments ([current frame storage](../../src/vm.zig#L36)) | Stored nullable captured-cell pointers alongside direct values for uncaptured bindings. | Tests passed, but local arithmetic stayed around 11.7-12.1 ms and calls were similar or worse. | Reverted. |
| Closure handle encoding and O(1) lookup ([`Value`](../../src/value.zig), [`ObjectStore`](../../src/vm/objects.zig)) | Encoded closure handles and replaced owner-function scans with short-function lookup. | Tests passed, but the function-call benchmark regressed. | Reverted. |
| Monomorphic last-closure cache ([closure resolution](../../src/vm.zig#L856)) | Cached the most recently resolved closure. | No benefit; call timing worsened. | Reverted. |
| Force-inline compact-index helpers | Forced `compactIndex` / `isCompactPut` inline in the opcode loop. | Generated code got larger and local arithmetic regressed to about 13.8 ms, consistent with dispatch/register pressure. | Reverted; direct opcode cases are used instead. |
| Reorder `.call` opcode branch ([dispatch loop](../../src/vm.zig#L805)) | Moved the call handler earlier to test whether call-heavy code layout was the bottleneck. | A/B/A on 70k global empty calls improved zRun from about 3.84 ms to 2.85-3.08 ms (about 20-26%), but 700k controls regressed: empty loop 17.574 to 18.823 ms (+7.1%), global reads 19.671 to 20.320 ms (+3.3%), local-alias empty calls 28.269 to 30.197 ms (+6.8%). Global empty calls improved 38.890 to 28.604 ms (-26.5%). | Reverted: workload-sensitive code-layout tradeoff, no general net win. Details in [call isolation](CALL_ISOLATION.md). |
| Pass `VM` by pointer to `CallFrame.init` ([frame init](../../src/vm.zig#L58)) | Replaced the by-value VM argument with `*const VM`. | One A/B moved global empty calls about 39.7 to 30.2 ms and local calls with a body 51.4 to 44.7 ms, but empty loop regressed 16.1 to 19.1 ms and local empty calls 28.5 to 31.6 ms. Restoring the old code restored prior timings. | Reverted: mixed result consistent with code-layout sensitivity. |

## Compiler Baseline

`zig build compile-bench -Dcpu=native` measures compile-only medians on the four
shared source fixtures. With both compilers given preallocated 1 MiB pools, the
first profiled run had zRun `ReleaseFast` at 8.9-12.4x MQuickJS C `-O3`. The
dominant cost was not the lexer or bytecode emission: `Parser` embedded a
256 KiB `[64]LoopContext` that was zeroed once per `compileUnit` (see
[Parser Loop-Context Zeroing](#parser-loop-context-zeroing-2026-09-28)). Moving
that storage out of the struct and allocating it uninitialized brought the
benchmark to 0.51-0.66x (about 1.5-2.0x MQuickJS). The compile-only fixture
details were not retained with this project, so this result is historical and
not directly reproducible from the published tree. This does **not**
establish a Zig compiler limitation: the frontends and output bytecode differ.
Remaining code-based hypotheses, not yet isolated: linear keyword comparisons in
`Parser.advance`, byte-at-a-time `ArrayList` emission in `emitByte`, and
per-function capture analysis that rescans source text via `sourceDeclaresName`.
The capture reference check was placed in a single per-unit
[`collectReferencedNames`](../../src/compiler.zig#L422) scan (rather than one scan
per parent local); that choice did not measurably change `compile-bench` either
way, so the reference scan is not treated as a compile-time cause.

## Measurement Notes

- The comparative in-process results in [README.md](README.md) pin the
  benchmark to one CPU, warm up twice, and report the median of seven timed
  runs. They exclude process startup, image loading/relocation, and context
  creation; both engines execute the same upstream-compiled bytecode image.
- The CLI runner (`performance/scripts/run.py`) includes process startup and loading.
  It compares upstream MQuickJS `-Os` with zRun `ReleaseFast`, so this is an
  end-to-end measurement rather than a VM-only result.
- `compare-stats` reports opcode counts, not execution time. Counts matched
  for arithmetic and function-call fixtures. Statistics builds are separate
  because instrumentation perturbs the hot path.
- Timing builds use MQuickJS `-O3` and Zig `ReleaseFast`. Zig Debug
  `compare-stats` may fail to link against the host toolchain's `.sframe`
  sections; use `-Doptimize=ReleaseFast` for that diagnostic build.
- `perf` was unavailable during the earlier experiments but is now installed
  and usable with unprivileged `cycles:u`. See [the profiling handoff](PROFILING.md)
  for commands, CPU-target A/B measurements, and sampled hotspots.

## Current Read

The latest fixed-bytecode CLI run is roughly 0.70x for arithmetic, 0.65x for
calls, 0.76x for arrays, and 0.81x for short SSR. On that runner, 0.65x means
the zRun call workload takes about 1.54x MQuickJS time. Same-bytecode
in-process call controls range around 1.5-2.1x depending on call shape; there
is no basis for saying all call paths are within 20%. The larger production-like
broader feature workloads tell a different story: callback arrays are 0.19x end-to-end
and 0.50-0.54x in-process after resolving each callback closure once; lowered spread is
0.29x and SSR templates are 0.41x end-to-end. In-process execution of spread
and SSR is 0.19x and 0.24x, so those are genuine VM costs, not source
compilation. The compact-binding and one-pass-string experiments did not
solve them and were reverted. The 20% lag target is not met; spread/object
allocation remains a high-value target, and the quadratic string-accumulator
loop pattern was addressed later the same day by rope strings
(see [Rope Strings](#rope-strings-for-concatenation-2026-09-28)).

At that point, the feature suite ran 13 checksum-checked workloads through the
production source path on both engines. These end-to-end measurements include
startup and compilation; they are not substitutes for the small in-process
bytecode comparator suite. The callback-heavy array path is currently about
4.8x slower end-to-end and remains a major plugin/runtime optimization target.
See [the feature baseline](WORKLOAD_BASELINE.md).

Against official QuickJS 2026-06-04, the latest matching-source CLI suite is
106.4% slower geometrically and the repeated-in-process suite is 406.6% slower.
The steady call fixture takes 16.66x QuickJS's time, but each engine compiles the
source independently; this is not a VM-only ratio. A current same-bytecode
in-process control against MQuickJS is about 1.49x slower in zRun, with
matching opcode histograms across 70,000 calls. Isolated empty-call deltas are
about 1.9-3.0x depending on whether the callee is local or global. Thus there
is a measurable VM-side call cost, but the much larger QuickJS comparison also
includes compiler and bytecode-optimization differences. A targeted
local-update fusion improved the steady arithmetic fixture by 24.3%, but did
not improve calls. Generated code already uses indirect jump-table dispatch;
handwritten assembly is not currently justified. The branch-order experiment
was workload-sensitive and has been reverted. Frame setup, closure lookup, and
frame-stack layout remain hypotheses to isolate, not confirmed root causes.
See [call isolation](CALL_ISOLATION.md) and [QuickJS comparison](QUICKJS_2026.md).

### Update 2026-09-28: compiled-call gap largely explained

The 16.66x QuickJS steady-call figure above was measured before the compiler
change in this log. With conditional self-binding and used-only captures, the
same steady call fixture is about 2.0x QuickJS, and the named 700k-call control
is about 2.0x MQuickJS instead of 12.8x. This confirms the earlier caution that
the large QuickJS ratio included *compiler and bytecode-optimization
differences*: the per-invocation self-binding closure (plus capture-all-parents
boxing) was the single largest compiler-side contributor. The residual call
cost (about 1.5-2.0x same-bytecode) remains VM-side, as documented in
[call isolation](CALL_ISOLATION.md). The quadratic string-accumulator gap was
also addressed later the same day: rope strings removed the O(n²) copying in
`ssr` (about `0.16x` to `0.57x` QuickJS), leaving runtime allocation and VM
dispatch as the largest outstanding costs. See
[Rope Strings](#rope-strings-for-concatenation-2026-09-28).
