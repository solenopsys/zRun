#!/usr/bin/env bash
set -euo pipefail

root=/home/alexstorm/distrib/business/next-arh/native/zRun
cd "$root"

zig build test
zig build -Doptimize=fast
compiler="$root/zig-out/bin/zrun-compile"
runtime="$root/zig-out/bin/zrun-runtime"

run_level() {
	local level="$1"
	local source expected actual artifact output status
	for source in "$root"/verification/"$level"_*/*.js; do
		[ -f "$source" ] || continue
		expected="${source%.js}.out"
		artifact=$(mktemp)
		actual=$(mktemp)
		if ! "$compiler" "$source" >"$artifact"; then
			rm -f "$artifact" "$actual"
			printf 'FAIL compile %s\n' "${source#"$root"/}" >&2
			return 1
		fi
		if [ -f "$expected" ]; then
			"$runtime" "$artifact" >"$actual"
			if ! diff -u "$expected" "$actual"; then
				rm -f "$artifact" "$actual"
				return 1
			fi
		else
			if ! output=$("$runtime" "$artifact" 2>&1); then
				rm -f "$artifact" "$actual"
				printf 'FAIL %s\n%s\n' "${source#"$root"/}" "$output" >&2
				return 1
			fi
			if [[ "$output" != *"FIXTURE_DONE "* || "$output" == *"FAIL "* || "$output" == *"UNAVAILABLE "* ]]; then
				rm -f "$artifact" "$actual"
				printf 'FAIL %s\n%s\n' "${source#"$root"/}" "$output" >&2
				return 1
			fi
		fi
		rm -f "$artifact" "$actual"
		printf 'PASS %s\n' "${source#"$root"/}"
	done
}

run_level 01
run_level 02
run_level 03

actual=$(mktemp)
errors=$(mktemp)
trap 'rm -f "$actual" "$errors"' EXIT

"$root/zig-out/bin/zrun" --bytecode "$root/src/testdata/print_42.bin" >"$actual"
if ! diff -u "$root/verification/04_bytecode/print.out" "$actual"; then
	exit 1
fi
printf 'PASS verification/04_bytecode/print.js\n'

status=0
"$root/zig-out/bin/zrun" --bytecode "$root/src/testdata/throw_42.bin" >"$actual" 2>"$errors" || status=$?
if [[ "$status" -ne 1 ]] || ! grep -q 'uncaught exception: 42' "$errors"; then
	cat "$errors" >&2
	printf 'FAIL verification/04_bytecode/exception.js\n' >&2
	exit 1
fi
printf 'PASS verification/04_bytecode/exception.js\n'
