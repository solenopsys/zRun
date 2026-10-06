# Byte array MVP benchmark — 2026-10-06

## Workload

The churn scripts allocate 2,048 arrays of 1,024 elements. Each array gets 1,024 indexed writes and 1,024 indexed reads; the final checksum is compared across engines. The byte workload uses `Uint8Array`; the control uses `new Array`. The allocation-only workload creates 8,192 `new Array(1024)` values and reads each length without storing references.

## Command

```sh
zig build test
python3 performance/scripts/run_byte_arrays.py \
  --quickjs /home/alexstorm/distrib/business/rd/quickjs/qjs \
  --mquickjs /home/alexstorm/distrib/business/rd/mquickjs/mqjs \
  --runs 9 --warmups 2
```

The timing includes process startup. zRun compilation is measured separately. QuickJS `qjs` runs source directly, so its execution number includes parsing and compilation. RSS is the median peak `VmHWM` sampled from `/proc`.

## Results

| Workload | Engine | Compile ms | Execute ms | Peak RSS KiB | Checksum |
|---|---|---:|---:|---:|---:|
| `byte_array_churn.js` | QuickJS | n/a | 107.037 | 3,416 | 262,067,200 |
| `byte_array_churn.js` | MQuickJS | 1.928 | 138.977 | 8,484 | 262,067,200 |
| `byte_array_churn.js` | zRun | 0.749 | 162.774 | 3,632 | 262,067,200 |
| `array_churn.js` | QuickJS | n/a | 103.818 | 3,440 | 262,067,200 |
| `array_churn.js` | MQuickJS | 1.559 | 115.257 | 18,724 | 262,067,200 |
| `array_churn.js` | zRun | 0.888 | 166.746 | 17,980 | 262,067,200 |
| `array_allocate_only.js` | QuickJS | n/a | 2.728 | n/a* | 8,388,608 |
| `array_allocate_only.js` | MQuickJS | 1.064 | 8.633 | 18,736 | 8,388,608 |
| `array_allocate_only.js` | zRun | 0.661 | 19.501 | 69,468 | 8,388,608 |

\* QuickJS completed this short process before the `/proc` RSS sampler could capture it. `qjs -d` after the script reported 75,077 bytes in use and one 16-slot fast-array backing store, despite the final JS array length being 1,024.

## Memory ownership check

`zig build test` passes with a new `std.testing.allocator` test that creates 512 byte arrays of 1,024 bytes each and then tears down the `ObjectStore`. The testing allocator reports no outstanding allocations after teardown.

zRun retains unreachable arrays until `ObjectStore.deinit`; it has no per-object collection. In this workload, packed byte storage uses about 14 MiB less peak process RSS than ordinary arrays. This is retained heap, not a leak surviving `ObjectStore.deinit`.

The allocation-only test is the clearest ordinary-array failure: 8,192 length-1,024 arrays take 19.5 ms and 69.5 MiB in zRun, 8.6 ms and 18.7 MiB in MQuickJS, versus 2.7 ms in QuickJS. QuickJS reports only a 16-slot fast-array backing store after the script, despite the final JS array length being 1,024. zRun eagerly fills every slot with `undefined` and retains every object in `ObjectStore` until teardown.

## CPU profile

For the 2,048-array ordinary-array churn case, `perf stat` reported:

| Engine | User cycles | Instructions | Branches |
|---|---:|---:|---:|
| QuickJS | 440,157,940 | 1,624,480,211 | 272,517,642 |
| zRun | 700,917,061 | 2,388,141,066 | 478,954,261 |

The QuickJS source run includes parsing; the zRun profile executes a precompiled artifact. In zRun's sampled profile, 90.65% of cycles are in `VM.executeFramesImpl`; inlined `VM.pop` accounts for 17.17% of total samples and `VM.push` for 10.10%. `Store.findArray` is 5.88%. This points to interpreter dispatch and stack traffic as the broad execution gap. Typed and ordinary array churn have nearly equal zRun cycle counts, so the byte-array feature itself does not explain that gap.

The allocation-only case used 4.67 million cycles / 14.69 million instructions in QuickJS and 32.01 million cycles / 79.23 million instructions in zRun. That separate gap comes from eagerly materializing the unused `undefined` slots and retaining unreachable arrays, in addition to ordinary interpreter overhead.

## Fast array opcode path

Change: `get_array_el`, `get_array_el2`, and `put_array_el` now read and write their operands directly in `Stack.storage`. This removes per-operand `Stack.pop` / `Stack.push` calls and their length checks. `PointerCache` also checks its most recently accessed object before scanning the eight-entry ring. Compiler and bytecode format are unchanged.

Command: `python3 performance/scripts/run_byte_arrays.py --quickjs /home/alexstorm/distrib/business/rd/quickjs/qjs --baseline-zrun-runtime /tmp/zrun-runtime-before-fast-array --runs 15 --warmups 3 --case performance/workloads/array_churn.js --case performance/workloads/byte_array_churn.js`

| Workload | zRun before | zRun after | Improvement | QuickJS after |
|---|---:|---:|---:|---:|
| ordinary array churn | 168.540 ms | 126.564 ms | 24.9% | 103.404 ms |
| byte array churn | 161.806 ms | 120.423 ms | 25.6% | 106.319 ms |

All outputs matched. zRun remains 22.4% slower than QuickJS for ordinary array churn and 13.3% slower for byte array churn. Peak RSS did not change (ordinary arrays about 17,972 KiB; byte arrays about 3,624 KiB), as expected for an execution-path optimization. `zig build test` and `verification/run.sh` pass after the change.

The test does not prove that long-running sessions reclaim objects before store teardown. It does not compare alternate allocator implementations. A separate byte arena could make bulk teardown cheaper, but it would not reduce peak memory or reclaim individual arrays sooner. The runtime currently passes its arena allocator to both ordinary objects and byte storage.

## Limits

These measure a small set of focused workloads and include process startup. They do not establish broad VM performance. Current `Uint8Array` element assignment still rejects fractional values instead of applying JS byte coercion, so the benchmark stays within integer byte values.

## Lazy `new Array(length)` backing

`new Array(n)` now stores `n` as a logical length and leaves element storage empty. Indexed reads from unmaterialized positions return `undefined`; the first write grows storage and fills any skipped positions with `undefined`. Array methods that operate on dense storage materialize the backing first. The bytecode and compiler are unchanged.

Validation: `zig build test` and `./verification/run.sh` passed. The array-constructor fixture checks length, initial `undefined` reads, and writes. A VM object-store unit test confirms that a length-1,024 array has zero allocated element slots until written.

Focused before/after benchmark, 25 samples / 4 warmups, using `/tmp/zrun-runtime-before-last-cache` as the old runtime and the current ReleaseFast runtime:

| Workload | zRun before | zRun after | Peak RSS before | Peak RSS after |
|---|---:|---:|---:|---:|
| 8,192 × `new Array(1024)` | 18.403 ms | 2.742 ms | 69,008 KiB | 2,640 KiB |

The same full benchmark run showed ordinary-array churn at 132.298 → 130.861 ms and byte-array churn at 126.727 → 121.758 ms; output checksums matched QuickJS and MQuickJS. The allocation-only case now runs at roughly QuickJS's 2.743 ms in this process-startup-inclusive test. These measurements isolate array creation behavior well, but do not imply equivalent GC: zRun still retains array objects until object-store teardown.
