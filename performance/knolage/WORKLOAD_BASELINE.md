# Feature Workload Performance Baseline

Captured on 2026-09-27 with MQuickJS and zRun `ReleaseFast`; two warmups and
seven alternating source-CLI runs per engine. Each source validates a checksum
and prints a matching `PASS` marker. Ratios are MQuickJS/zRun, so below 1.00x
means zRun is slower.

| Workload | MQuickJS median | zRun median | C/Zig |
|---|---:|---:|---:|
| Arrays and callbacks | 10,237,097 ns | 77,258,902 ns | 0.13x |
| String operations | 47,072,395 ns | 72,308,460 ns | 0.65x |
| Function calls | 3,407,289 ns | 15,723,452 ns | 0.22x |
| Plain objects | 9,075,102 ns | 20,434,410 ns | 0.44x |
| Collections | 24,436,172 ns | 34,291,111 ns | 0.71x |
| Control flow | 1,612,531 ns | 2,904,748 ns | 0.56x |
| Regular expressions | 3,993,507 ns | 5,029,779 ns | 0.79x |
| Numeric operators | 8,010,427 ns | 12,977,591 ns | 0.62x |
| JSON | 16,684,546 ns | 16,341,970 ns | 1.02x |
| Constructors and `this` | 2,373,363 ns | 8,430,175 ns | 0.28x |
| Optional access | 9,120,687 ns | 18,558,912 ns | 0.49x |
| Spread operations | 7,944,325 ns | 31,137,211 ns | 0.26x |
| SSR templates | 6,758,336 ns | 17,464,041 ns | 0.39x |
| Object methods | 6,499,154 ns | 16,173,708 ns | 0.40x |
| String/array methods | 5,316,050 ns | 10,962,363 ns | 0.48x |

All 15 workloads measured, with zero blocked. These are end-to-end CLI numbers:
they include process startup and source compilation, and must not be read as
VM-only ratios. The callback-heavy array case remains the largest gap: zRun
takes about 5.3x as long. A per-method callback closure lookup optimization
improved the same bytecode in the in-process comparator from about 0.41x to
0.50-0.54x, although the source-CLI ratio remains near 0.19x. An O(n^2)
closure lookup was removed after this workload created a fresh inline callback on every outer iteration;
the zRun median fell from 482 ms to 51 ms. RegExp is about 13% faster and
JSON about 6% faster in this run. The new object-method SSR case is 0.42x
end-to-end and 0.24x in the in-process comparator, so its gap is in VM work,
not just startup or parsing.

The source programs deliberately use the common syntax subset accepted by both
engines; language-feature correctness is covered separately by the verification
suite.
Several cases benchmark equivalent lowerings rather than unsupported source
syntax, so the timing suite does not conflate parser gaps with runtime speed.
The new array `concat`/`indexOf`/`shift` stress workload is 0.47x end-to-end;
an in-process ReleaseFast benchmark of 20,000 calls across those methods plus
string `concat`/`indexOf`/`startsWith` measured 2,451,307 ns median. MQuickJS
does not expose `String.prototype.startsWith`, so that method is covered by
the zRun in-process benchmark and correctness fixture, not a cross-engine
comparison.
