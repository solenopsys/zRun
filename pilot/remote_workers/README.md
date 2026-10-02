# Remote Bytecode Workers

This pilot starts one zRun process per URL in `ZRUN_WORKERS`. Each worker fetches a raw MQuickJS bytecode image from `ZRUN_BYTECODE_URL`, relocates it, and executes it in its own VM and address space.

Run the local smoke test from the repository root:

```sh
./pilot/remote_workers/run.sh
```

Production invocation:

```sh
ZRUN_WORKERS='["https://runtime.example/jobs/a.bin","https://runtime.example/jobs/b.bin"]' \
  ./zig-out/bin/zrun --workers-env
```

The worker list is a JSON array of HTTP(S) URLs. Each response must be a raw bytecode image no larger than 16 MiB. Worker stdout and stderr are inherited; the supervisor waits for all workers and exits nonzero if any worker fails.
