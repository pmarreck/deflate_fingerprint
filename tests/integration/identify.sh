#!/usr/bin/env bash
# Integration test: `deflate-fingerprint identify` CLI surface.
#
# Tests the end-to-end flow Zig core <- C FFI <- C CLI against ground-truth
# bytes captured from real zlib 1.3.2 in bench/probes/zlib_level0_stored.c.
#
# Per Mecha conventions: no `set -e` (it masks intended non-zero exits when
# testing error paths). `set -u` catches undefined vars without that hazard.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$REPO_ROOT/zig-out/bin/deflate-fingerprint"

if [[ ! -x "$CLI" ]]; then
	echo "FAIL: CLI not built at $CLI; run ./build first" >&2
	exit 1
fi

# Per-PID tempdir under $TMPDIR (RAM on macOS) so parallel test runs don't collide.
WORK="${TMPDIR:-/tmp}/dfp_identify_test.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# ─── Setup fixtures (ground truth from bench/probes/zlib_level0_stored.c) ───
RAW="$WORK/raw.bin"
TARGET="$WORK/target.bin"
BAD_TARGET="$WORK/bad_target.bin"

printf 'Hello, world!' > "$RAW"
# 1-byte header (0x01 = BFINAL=1, BTYPE=00), LE16 LEN=13, LE16 NLEN=~13, then data.
printf '\x01\x0d\x00\xf2\xffHello, world!' > "$TARGET"
printf 'NOPE_not_a_valid_DEFLATE_stream' > "$BAD_TARGET"

# ─── Test: byte-exact match, human-readable output ───
echo "test: byte-exact match (human output)"
output=$("$CLI" identify --raw "$RAW" --target "$TARGET" 2>&1)
rc=$?
if [[ "$rc" -eq 0 ]]; then
	pass "exit code 0 for byte-exact match"
else
	fail "exit code was $rc, expected 0"
fi
if [[ "$output" == *"fingerprint #1"* && "$output" == *"byte-exact match"* ]]; then
	pass "output names fingerprint #1 and byte-exact"
else
	fail "unexpected output: $output"
fi

# ─── Test: JSON output ───
echo "test: byte-exact match (JSON output)"
output=$("$CLI" identify --json --raw "$RAW" --target "$TARGET" 2>&1)
rc=$?
if [[ "$rc" -eq 0 ]]; then
	pass "JSON path exit code 0"
else
	fail "JSON path exit code was $rc"
fi
expected_json='{"fingerprint_id":1,"confidence":0,"residual_bytes":0}'
if [[ "$output" == "$expected_json" ]]; then
	pass "JSON output exact match"
else
	fail "JSON mismatch: got '$output', expected '$expected_json'"
fi

# ─── Test: no match -> exit code 3 ───
echo "test: no matching fingerprint (exit code 3)"
output=$("$CLI" identify --raw "$RAW" --target "$BAD_TARGET" 2>&1)
rc=$?
if [[ "$rc" -eq 3 ]]; then
	pass "exit code 3 for no match"
else
	fail "no-match exit code was $rc, expected 3"
fi
if [[ "$output" == *"no matching fingerprint"* ]]; then
	pass "no-match human output"
else
	fail "unexpected no-match output: $output"
fi

# ─── Test: missing required args -> exit code 2 ───
echo "test: usage errors (exit code 2)"
"$CLI" identify --raw "$RAW" > /dev/null 2>&1
rc=$?
if [[ "$rc" -eq 2 ]]; then
	pass "missing --target -> exit 2"
else
	fail "missing --target gave exit $rc, expected 2"
fi
"$CLI" identify --target "$TARGET" > /dev/null 2>&1
rc=$?
if [[ "$rc" -eq 2 ]]; then
	pass "missing --raw -> exit 2"
else
	fail "missing --raw gave exit $rc, expected 2"
fi

# ─── Test: unknown arg -> exit code 2 ───
"$CLI" identify --raw "$RAW" --target "$TARGET" --bogus > /dev/null 2>&1
rc=$?
if [[ "$rc" -eq 2 ]]; then
	pass "unknown arg -> exit 2"
else
	fail "unknown arg gave exit $rc, expected 2"
fi

# ─── Test: --help and --about ───
"$CLI" --help > /dev/null 2>&1
if [[ "$?" -eq 0 ]]; then pass "--help exit 0"; else fail "--help failed"; fi
output=$("$CLI" --about 2>&1)
if [[ "$output" == *"deflate-fingerprint"* && "$output" == *"0.1.0"* ]]; then
	pass "--about prints version"
else
	fail "--about output unexpected: $output"
fi

# ─── Test: paths with spaces are accepted ───
echo "test: path with spaces"
SPACED_DIR="$WORK/dir with spaces"
mkdir -p "$SPACED_DIR"
cp "$RAW" "$SPACED_DIR/raw bin"
cp "$TARGET" "$SPACED_DIR/target bin"
"$CLI" identify --raw "$SPACED_DIR/raw bin" --target "$SPACED_DIR/target bin" > /dev/null 2>&1
rc=$?
if [[ "$rc" -eq 0 ]]; then
	pass "spaces-in-path identify works"
else
	fail "spaces-in-path exit $rc"
fi

echo ""
echo "identify.sh: $PASS passed, $FAIL failed"
exit "$FAIL"
