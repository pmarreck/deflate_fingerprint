#!/usr/bin/env bash
# Integration test: PNG IDAT probe reaches zlib-wrapped DEFLATE streams.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GEN_SRC="$SCRIPT_DIR/fixtures/gen_png_idat.c"

WORK="${TMPDIR:-/tmp}/dfp_png_probe_test.$$"
mkdir -p "$WORK"
trap 'command rm -rf "$WORK" 2>/dev/null' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

GEN="$WORK/gen_png_idat"
if cc -Wall -Wextra -O2 "$GEN_SRC" -lz -o "$GEN" 2>"$WORK/gen_build.log"; then
	pass "gen_png_idat helper builds"
else
	fail "gen_png_idat helper failed to build"
	cat "$WORK/gen_build.log" >&2
	echo "png_probe.sh: $PASS passed, $FAIL failed"
	exit "$FAIL"
fi

PNG="$WORK/sample.png"
if "$GEN" "$PNG" 2>"$WORK/gen.log"; then
	pass "PNG fixture generated"
else
	fail "PNG fixture generation failed"
	cat "$WORK/gen.log" >&2
	echo "png_probe.sh: $PASS passed, $FAIL failed"
	exit "$FAIL"
fi

output=$(nix develop "$REPO_ROOT" -c zig build png-probe -- "$WORK" 2>"$WORK/probe.err")
rc=$?
if [[ "$rc" -eq 0 ]]; then
	pass "png-corpus-probe runs"
else
	fail "png-corpus-probe failed"
	cat "$WORK/probe.err" >&2
	echo "png_probe.sh: $PASS passed, $FAIL failed"
	exit "$FAIL"
fi

if echo "$output" | grep -q "PNG streams:        1"; then
	pass "reports one PNG stream"
else
	fail "expected one PNG stream; output was: $output"
fi

if echo "$output" | grep -Eq "identified:[[:space:]]+1"; then
	pass "identifies generated zlib stream"
else
	fail "expected one identified stream; output was: $output"
fi

echo ""
echo "png_probe.sh: $PASS passed, $FAIL failed"
exit "$FAIL"
