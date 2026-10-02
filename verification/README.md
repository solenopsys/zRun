# Verification

`run.sh` is the single test entry point. It runs Zig unit tests, then checks source fixtures from the smallest language cases through runtime behavior, and finally executes checked-in bytecode images.

```sh
./verification/run.sh
```

The ordered fixture groups are:

1. `01_basics`: values and arithmetic.
2. `02_language`: statements, functions, collections, operators, and supported syntax.
3. `03_runtime`: VM behavior and composed runtime cases.
4. `04_bytecode`: source examples corresponding to the checked-in images under `src/testdata/`.

Fixtures with a matching `.out` file are compared byte-for-byte. Feature fixtures without an `.out` file must finish with their `FIXTURE_DONE` marker and may not report a failed or unavailable capability. Bytecode exception behavior is checked for both its exit status and error message.
