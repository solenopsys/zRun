#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmpdir=$(mktemp -d)
server_pid=

cleanup() {
	if [[ -n "$server_pid" ]]; then
		kill "$server_pid" 2>/dev/null || true
		wait "$server_pid" 2>/dev/null || true
	fi
	for file in "$tmpdir"/*; do
		[[ -e "$file" ]] || continue
		unlink "$file"
	done
	rmdir "$tmpdir"
}
trap cleanup EXIT

zig build -Doptimize=ReleaseFast
python3 "$root/pilot/remote_workers/server.py" \
	--directory "$root/src/testdata" \
	--port-file "$tmpdir/port" \
	>"$tmpdir/server.log" 2>&1 &
server_pid=$!

for _ in {1..100}; do
	[[ -s "$tmpdir/port" ]] && break
	sleep 0.05
done
[[ -s "$tmpdir/port" ]] || { printf 'bytecode test server did not start\n' >&2; exit 1; }
port=$(<"$tmpdir/port")

output=$(ZRUN_WORKERS="[\"http://127.0.0.1:$port/print_42.bin\",\"http://127.0.0.1:$port/values.bin\"]" \
	"$root/zig-out/bin/zrun" --workers-env)
expected=$(printf '%s\n' '42' '0 7 true false null undefined zscript' | sort)
actual=$(printf '%s\n' "$output" | sort)
[[ "$actual" == "$expected" ]] || {
	printf 'worker output mismatch\nexpected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
	exit 1
}

printf 'PASS remote bytecode workers (2 isolated processes, 2 URLs)\n'
