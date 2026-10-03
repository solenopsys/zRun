# zRun

zRun is a compact JavaScript bytecode runtime and source compiler written in Zig. It separates scriptable business logic from performance-critical host functions: business rules can run as JavaScript bytecode, while hot paths and host integrations can run as native Zig functions. Runtime capabilities are organized as plugins, so new APIs can be added without rewriting the VM core. It includes a command-line runner for source scripts and supported upstream bytecode images.

The complete engine—source compiler, bytecode runtime, VM, and built-in plugins—has a memory footprint of about 5 MB, not just the VM core. Actual process memory depends on the workload, allocator, and build configuration.

## Status

The source compiler and runtime focus on the language constructs and runtime APIs needed by their target workloads. Do not execute untrusted scripts in security-sensitive processes.

## JavaScript Support

The tables below summarize implemented source-language constructs and runtime APIs.

<details>
<summary>Values and expressions</summary>

| Area | Implemented features |
|---|---|
| Values | &bull; `undefined`, `null`, booleans<br>&bull; Integer, hexadecimal, and BigInt literals; runtime floating-point values<br>&bull; Arbitrary-precision BigInt arithmetic<br>&bull; Strings and template interpolation |
| Bindings | &bull; `var`, `let`, and `const`<br>&bull; Local assignment and closures<br>&bull; Captured mutable values |
| Expressions | &bull; Arithmetic and loose/strict comparisons<br>&bull; Short-circuit `&&`/`||`; ternary and nullish expressions<br>&bull; Increments and compound assignments<br>&bull; `typeof`, `in`, and `instanceof` |
| Bitwise operations | &bull; `&`, `|`, and `^`<br>&bull; `<<`, `>>`, and unsigned right shift `>>>` |
| Property access | &bull; Dot and computed reads/writes<br>&bull; Optional dot/computed access<br>&bull; Array and string `length` |
| Strings | &bull; Quoted literals and escapes<br>&bull; Concatenation and `${...}` interpolation |

Coverage: [values and arithmetic](verification/01_basics/), [operators and optional access](verification/02_language/).
</details>

<details>
<summary>Statements and control flow</summary>

| Area | Implemented features |
|---|---|
| Branching and loops | &bull; `if`/`else` and `switch`<br>&bull; `while`, `do`/`while`, and C-style `for`<br>&bull; Array `for`/`of` and object-key `for`/`in`<br>&bull; Labeled `break`/`continue` |
| Exceptions | &bull; `throw` and `try`/`catch`<br>&bull; Synchronous `finally`<br>&bull; Propagation through function calls |

Coverage: [language control flow](verification/02_language/loops.js), [runtime control flow](verification/03_runtime/).
</details>

<details>
<summary>Functions and classes</summary>

| Area | Implemented features |
|---|---|
| Functions | &bull; Declarations, expressions, and calls<br>&bull; Recursion and closures with captured mutable locals<br>&bull; Async declarations, function expressions, and parenthesized arrow functions suspend at `await` and resume through the embedding host<br>&bull; `this` and `arguments` |
| Arrow functions | &bull; Parenthesized parameters<br>&bull; Expression and block bodies |
| Parameters | &bull; Default values<br>&bull; Array and object destructuring<br>&bull; Object rest in bundled parameters |
| Spread | &bull; Function calls<br>&bull; Array and object literals |
| Object methods | &bull; Concise method syntax<br>&bull; Closure capture and method receiver behavior |
| Classes | &bull; Class declarations and constructors<br>&bull; `Error` subclasses |
| Function invocation | &bull; `.call()`<br>&bull; `.bind()` |

Coverage: [function syntax](verification/02_language/functions.js), [closures and call behavior](verification/03_runtime/functions.js), [class syntax](verification/02_language/class.js).
</details>

Async functions can use `await`. Embedded Zig hosts start a script with `VM.executeAsync`; when it returns `.suspended`, the host handles the awaited request and later calls `VM.resumeExecution` with the result or rejection. The continuation owns the VM frames until it completes or the host deinitializes it. Promise objects and a built-in event loop are not part of this first implementation; the command-line runners remain synchronous.

## Resident bytecode modules

Hosts can keep multiple separately compiled artifacts decoded in memory with
`module_registry.ModuleRegistry`. Loading assigns a host name to the artifact;
function calls resolve by module name and function name. The registry retains
each artifact until `remove` or `deinit`, so calls do not reread or decode the
bytecode. Removing a module invalidates pointers and execution sessions created
from its functions; release those first.

```zig
var modules = zrun.module_registry.ModuleRegistry.init(allocator);
defer modules.deinit();
try modules.load("users", users_artifact_bytes);
try modules.load("billing", billing_artifact_bytes);

var call = try zrun.execution.createModuleFunctionAsyncSession(
    allocator,
    &modules,
    "users",
    "lookupUser",
    .{},
);
defer call.deinit();

// After all calls for this module are released:
_ = modules.remove("users");
```

`load` rejects duplicate names; remove the old module before loading a
replacement under the same name. The registry and its modules are host-owned
and are not internally synchronized.

<details>
<summary>Objects, arrays, and collections</summary>

| Area | Implemented features |
|---|---|
| Arrays | &bull; Literals, indexing, mutation, and `length`<br>&bull; `Array(...)`, `Array.isArray`, and spread<br>&bull; `push`, `map`, `filter`, `find`, `flatMap`, and `reduce`<br>&bull; `includes`, `join`, `slice`, `some`, and `sort`<br>&bull; `concat`, `indexOf`, and `shift` |
| Plain objects | &bull; Object literals, shorthand fields, and concise methods<br>&bull; Computed keys and computed methods<br>&bull; Object spread<br>&bull; Property reads and writes |
| `Map` | &bull; Construction and iterable initialization<br>&bull; `set`, `get`, and `has`<br>&bull; `keys` iterator |
| `Set` | &bull; Construction and iterable initialization<br>&bull; `add` and `has`<br>&bull; `values` iterator |
| `WeakMap` | &bull; Construction<br>&bull; `set`, `get`, and `has` |
| Regular expressions | &bull; Literal patterns with `i`/`g` flags<br>&bull; `.test()`<br>&bull; String replacement operations |

Coverage: [arrays and objects](verification/02_language/arrays.js), [collections](verification/02_language/collections.js), [regular expressions](verification/02_language/regexp.js).
</details>

<details>
<summary>Built-ins and host runtime</summary>

| Area | Implemented features |
|---|---|
| String methods | &bull; `concat`, `indexOf`, `startsWith`, `slice`, and `split`<br>&bull; `replace` and `replaceAll`<br>&bull; `charCodeAt`, `localeCompare`, and `padStart`<br>&bull; `toLowerCase`, `toUpperCase`, and `trim` |
| `Number` | &bull; `toString` |
| `Object` | &bull; `assign`, `entries`, and `fromEntries`<br>&bull; `keys` and `values` |
| `Array` | &bull; `isArray` |
| `JSON` | &bull; `parse` and `stringify` |
| `Math` | &bull; `imul` and `random` |
| Conversion and encoding | &bull; `Boolean`, `String`, and `Number` conversion<br>&bull; `encodeURIComponent` |
| Host integration | &bull; `print`<br>&bull; The `__host` bridge and `--host-json` input |

Coverage: [runtime APIs](verification/02_language/apis.js), [host primitives](verification/02_language/host_runtime_primitives.js).
</details>

<details>
<summary>Bytecode runtime</summary>

| Area | Implemented features |
|---|---|
| Upstream bytecode | &bull; Loads MQuickJS bytecode images<br>&bull; Relocates bytecode for runtime execution |
| Runtime values | &bull; Object-store backed arrays, objects, and strings<br>&bull; Closures, collections, and regular-expression values |

Coverage: [bytecode fixtures](verification/04_bytecode/) and [checked-in images](src/testdata/).
</details>

## Requirements

- Zig 0.17.0 !

## Build and run

```sh
zig build -Doptimize=fast
./zig-out/bin/zrun-compile path/to/bundle.js > path/to/program.zbc
./zig-out/bin/zrun-runtime path/to/program.zbc
./zig-out/bin/zrun --bytecode path/to/program.bin
```

`zrun-compile` turns JavaScript source into the versioned zRun artifact format.
`zrun-runtime` loads and executes that artifact without linking the source
compiler. The `zrun` executable remains a development runner for source fixtures
and upstream MQuickJS bytecode.

### Remote bytecode workers (pilot)

The pilot starts one isolated zRun process per bytecode URL. Each process reads its own `ZRUN_BYTECODE_URL`, downloads a raw MQuickJS bytecode image, relocates it, and executes it:

```sh
ZRUN_WORKERS='["https://runtime.example/jobs/a.bin","https://runtime.example/jobs/b.bin"]' \
  ./zig-out/bin/zrun --workers-env
```

Run the local end-to-end pilot with two different bytecode images and URLs:

```sh
./pilot/remote_workers/run.sh
```

See [`pilot/remote_workers/README.md`](pilot/remote_workers/README.md) for limits and the pilot protocol.

Run the full verification sequence from the repository root:

```sh
./verification/run.sh
```

This runs Zig unit tests followed by the language fixtures in increasing levels of complexity, then checks the checked-in bytecode images.

## Project layout

- `src/` contains the runtime, compiler, VM, plugins, and checked-in bytecode fixtures.
- `verification/` contains the ordered correctness corpus and its single runner.
- `performance/` contains benchmark workloads and standalone runners; `performance/knolage/` contains the curated measurement record.

## Code size

| Engine | Source lines | Counted files |
|---|---:|---|
| V8 | ≈2,000,000 | Upstream engine estimate; the source is external to this repository. |
| QuickJS | 79,871 | Top-level `.c`/`.h`; excludes test runner, Unicode generator, and generated Unicode table. |
| MQuickJS | 30,950 | Top-level `.c`/`.h`; excludes the example and generated atom/opcode headers. |
| zRun | 11,375 | `src/**/*.zig`. |

## Performance

Measurements captured on 2026-09-29 on Linux x86_64, AMD Ryzen 7 8845H, Zig 0.16.0. Ratios are reference time / zRun time; below `1.00x` means zRun was slower. Suites have different workloads and timing scopes, so compare results only within each row.

Run the full benchmark set from the repository root. Set these paths to the installed MQuickJS executable, QuickJS executable, and MQuickJS source checkout. The command runs all suites represented below; it does not use V8.

```sh
set -euo pipefail

MQJS=/path/to/mquickjs/mqjs
QJS=/path/to/quickjs/qjs
MQUICKJS_DIR=/path/to/mquickjs

test -x "$MQJS"
test -x "$QJS"
test -f "$MQUICKJS_DIR/mquickjs.c"
if [ -e ../mquickjs ] || [ -L ../mquickjs ]; then
  printf 'Refusing to replace existing ../mquickjs\n' >&2
  exit 1
fi

tmpdir=$(mktemp -d)
ln -s "$MQUICKJS_DIR" ../mquickjs
cleanup() {
  unlink ../mquickjs
  for image in "$tmpdir"/*.bin; do
    [ -e "$image" ] || continue
    unlink "$image"
  done
  rmdir "$tmpdir"
}
trap cleanup EXIT

zig build bench -Doptimize=fast
for source in performance/workloads/inprocess/*.js; do
  image="$tmpdir/$(basename "${source%.js}").bin"
  "$MQJS" -o "$image" "$source"
  zig build compare -Doptimize=fast -- "$image"
done
python3 performance/scripts/run.py "$MQJS"
python3 performance/scripts/run_features.py "$MQJS"
python3 performance/scripts/run_quickjs.py --quickjs "$QJS"
zig build compile-bench -Doptimize=fast
```

| Benchmark | Cases | Result | Scope |
|---|---:|---:|---|
| zRun VM microbenchmarks | 4 | stack push/pop `0.52 ns/pair`; arithmetic `1.023 ms`; calls `0.307 ms`; native methods `2.318 ms` | Internal VM; medians of 5 samples |
| MQuickJS same-bytecode | 8 | geometric mean `0.92x` ([per-case results](performance/knolage/README.md#same-bytecode-results)) | Same compiled images; 2 warmups, 7 timed runs |
| MQuickJS CLI bytecode | 4 | geometric mean `0.87x` | Process startup and bytecode loading; 2 warmups, 9 timed runs |
| MQuickJS language features | 15 | geometric mean `0.56x` | Source compile and execution; 2 warmups, 7 timed runs |
| Official QuickJS CLI | 4 | geometric mean `0.91x` | Source compile and execution; 3 warmups, 11 timed runs |
| Compile-only comparison | 4 | geometric mean `0.60x` | MQuickJS C `-O3` vs zRun Zig `ReleaseFast`; 15 timed runs |

The internal VM microbenchmarks run with `zig build bench -Doptimize=fast`. Additional workloads and Python runners are in [`performance/`](performance/); [detailed results and methodology](performance/knolage/README.md) include historical measurements. Cross-engine comparisons require separately installed MQuickJS or QuickJS executables; the zRun build and verification suite do not depend on them.

## License

zRun is distributed under the MIT license. The translated implementation retains the original MQuickJS copyright notices; see [LICENSE](LICENSE).

## Security and Artifact Trust

zRun is not an operating-system sandbox. A script or bytecode image runs with the filesystem, network, and process privileges of the zRun process. Running workers as separate processes does not by itself remove those privileges.

### Trusted Packages

Distributed code must come from a repository the operator explicitly trusts. Package distribution must authenticate repository metadata with digital signatures and bind each package to a cryptographic digest listed by that signed metadata. The runtime or package manager must verify this chain before decompressing, parsing, caching, or executing an artifact, and must reject missing or invalid signatures. Repository keys should be scoped to their intended repositories and managed as trust roots.

Signatures establish artifact origin and integrity; they do not prove that code is harmless. Installing or running a trusted package grants its code the privileges of the process that installs or executes it. Operators must review and trust the repository and its build pipeline.

### Bytecode Provenance

A bytecode package may be distributed without its source, including publicly, while source access is restricted to subscribers or other authorized recipients. For every distributed bytecode artifact, provide a signed provenance record binding at least the source digest, bytecode digest, compiler identity and version, bytecode ABI, and relevant build inputs. Authorized recipients must be able to obtain the corresponding source and build inputs, verify the provenance signature, reproduce the build with the identified compiler, and compare the locally generated bytecode digest with the bytecode digest in the signed record. A trusted build attestation may provide additional assurance, but does not replace this independent verification path. The source need not be bundled with the public bytecode package; a source file without a verifiable binding to the artifact is not proof of correspondence.

Caches should be keyed by artifact and compiler/ABI digests. Verify signatures and provenance before decoding or relocating bytecode. When compressed artifacts are accepted, enforce limits on both compressed and decompressed size and on decompression work.

### Runtime Isolation

Run zRun with the least privileges needed. Use operating-system controls to restrict filesystem and network access and to cap memory, CPU time, process count, and output. Use a separate restricted process or stronger OS sandbox when code may be untrusted or when containing runtime vulnerabilities is required. Process separation alone is not a security boundary if workers retain the same credentials, inherited secrets, filesystem access, and network access.

### Current Implementation

The repository-signature verification, package manager, source-to-bytecode provenance verification, and operating-system sandbox described above are security requirements for a trusted distribution system; they are not implemented by the current zRun CLI. The `--bytecode` path accepts a raw MQuickJS bytecode image, and the remote-worker pilot fetches and executes raw images. Treat these inputs as trusted build artifacts only. Do not use the current CLI or worker pilot to execute bytecode from arbitrary or untrusted sources.
