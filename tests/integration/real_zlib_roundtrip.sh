#!/usr/bin/env bash
# Integration test: identify real zlib output across known (level, strategy)
# configs. Generates raw DEFLATE bytes via a tiny C helper (libz linked) then
# feeds them through the deflate-fingerprint CLI and asserts the registry
# returns the expected fingerprint ID.
#
# This proves the v0.1 fingerprints work on *actual* zlib output, not just
# hand-crafted hex fixtures.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$REPO_ROOT/zig-out/bin/deflate-fingerprint"
GEN_SRC="$SCRIPT_DIR/fixtures/gen_zlib_target.c"

if [[ ! -x "$CLI" ]]; then
	echo "FAIL: CLI not built at $CLI; run ./build first" >&2
	exit 1
fi
if [[ ! -f "$GEN_SRC" ]]; then
	echo "FAIL: missing gen_zlib_target.c source" >&2
	exit 1
fi

WORK="${TMPDIR:-/tmp}/dfp_real_zlib_test.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# Build the generator (needs libz from the nix devshell).
GEN="$WORK/gen_zlib_target"
if ! cc -Wall -Wextra -O2 "$GEN_SRC" -lz -o "$GEN" 2>"$WORK/gen_build.log"; then
	echo "FAIL: could not build gen_zlib_target — see $WORK/gen_build.log" >&2
	cat "$WORK/gen_build.log" >&2
	exit 1
fi

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# Assert that for a given input + (level, strategy), identify returns the
# expected fingerprint_id. Uses the CLI's JSON output so we don't need a
# regex parser for the human form.
assert_identifies_as() {
	local label="$1"      # human-readable label
	local input="$2"      # path to uncompressed raw
	local level="$3"
	local strategy="$4"
	local expected_id="$5"

	local target="$WORK/target.bin"
	if ! "$GEN" "$input" "$target" "$level" "$strategy" 2>"$WORK/gen_err"; then
		fail "$label: gen_zlib_target failed"
		cat "$WORK/gen_err" >&2
		return
	fi

	local json
	json=$("$CLI" identify --json --raw "$input" --target "$target" 2>"$WORK/id_err")
	local rc=$?

	# Extract fingerprint_id from JSON via grep/sed (no jq dependency).
	local got_id
	got_id=$(echo "$json" | sed -E 's/.*"fingerprint_id":([0-9]+).*/\1/')
	# Extract confidence too (0 = byte_exact).
	local got_conf
	got_conf=$(echo "$json" | sed -E 's/.*"confidence":([0-9]+).*/\1/')

	# Accept ANY of the comma-separated expected_id values. Multiple
	# fingerprints can match a single byte stream when encoder configs
	# happen to converge (e.g. HUFFMAN_ONLY-STORED produces the same
	# bytes as level=0 always does for the same input).
	if [[ ",$expected_id," == *",$got_id,"* ]]; then
		if [[ "$got_conf" == "0" ]]; then
			pass "$label: identified as #$got_id (byte-exact, expected $expected_id)"
		else
			fail "$label: identified as #$got_id but confidence=$got_conf (expected 0=byte_exact)"
		fi
	else
		fail "$label: expected fingerprint #{$expected_id}, got #$got_id (json: $json)"
	fi
}

# ─── Fixture inputs ────────────────────────────────────────────────────────

# Tiny input — "Hello, world!" — exercises fixed-Huffman path.
HELLO="$WORK/hello.txt"
printf 'Hello, world!' > "$HELLO"

# Single-distinct-literal input — exercises DYNAMIC dispatch in HUFFMAN_ONLY.
AAA14="$WORK/a14.txt"
printf 'AAAAAAAAAAAAAA' > "$AAA14"

# 16 distinct high-byte literals — exercises STORED dispatch in HUFFMAN_ONLY.
HIGH16="$WORK/high16.bin"
printf '\xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xcb\xcc\xcd\xce\xcf' > "$HIGH16"

# LZ77-friendly input — exercises level=1 match emission.
ABCREP="$WORK/abcrep.txt"
printf 'ABCABCABCABC' > "$ABCREP"

# RLE-style input — match(N, dist=1) at level 1.
A16="$WORK/a16.txt"
printf 'AAAAAAAAAAAAAAAA' > "$A16"

# Empty input.
EMPTY="$WORK/empty.bin"
: > "$EMPTY"

# ─── Fingerprint #1: zlib Z_NO_COMPRESSION (level=0) ───────────────────────
echo ""
echo "test: fingerprint #1 (zlib level=0 / Z_NO_COMPRESSION)"
assert_identifies_as "empty L0 default"        "$EMPTY"  0 default       1
assert_identifies_as "'Hello' L0 default"      "$HELLO"  0 default       1
assert_identifies_as "16 high bytes L0 default" "$HIGH16" 0 default       1
# Strategy doesn't matter at level 0:
assert_identifies_as "'Hello' L0 huffman_only" "$HELLO"  0 huffman_only  1
assert_identifies_as "'Hello' L0 rle"          "$HELLO"  0 rle           1
assert_identifies_as "'Hello' L0 fixed"        "$HELLO"  0 fixed         1

# ─── Fingerprint #2: zlib Z_HUFFMAN_ONLY (any level) ───────────────────────
echo ""
echo "test: fingerprint #2 (zlib HUFFMAN_ONLY, FIXED branch)"
assert_identifies_as "empty L6 huffman_only"   "$EMPTY"  6 huffman_only  2
assert_identifies_as "'Hello' L6 huffman_only" "$HELLO"  6 huffman_only  2
# Level should not matter for HUFFMAN_ONLY:
assert_identifies_as "'Hello' L1 huffman_only" "$HELLO"  1 huffman_only  2
assert_identifies_as "'Hello' L9 huffman_only" "$HELLO"  9 huffman_only  2

echo ""
echo "test: fingerprint #2 (zlib HUFFMAN_ONLY, DYNAMIC branch)"
assert_identifies_as "14×A L6 huffman_only"    "$AAA14"  6 huffman_only  2

echo ""
echo "test: fingerprint #2 (zlib HUFFMAN_ONLY, STORED branch)"
# NOTE: HUFFMAN_ONLY-STORED produces the same bytes as level=0 always does
# for the same input. Either #1 (zlib L0) or #2 (HUFFMAN_ONLY) is a valid
# attribution. Detector reports the first registered match (#1).
assert_identifies_as "high16 L6 huffman_only"  "$HIGH16" 6 huffman_only  "1,2"

# ─── Fingerprint #3: zlib level=1 DEFAULT_STRATEGY ─────────────────────────
echo ""
echo "test: fingerprint #3 (zlib level=1 DEFAULT_STRATEGY, no LZ77 trigger)"
# NOTE: "Hello, world!" has no useful LZ77 matches, so L1 falls through to
# fixed-Huffman literals — same bytes as HUFFMAN_ONLY. #2 or #3 valid.
assert_identifies_as "'Hello' L1 default"      "$HELLO"  1 default       "2,3"

echo ""
echo "test: fingerprint #3 (zlib level=1, LZ77 RLE-style match)"
# Match emission distinguishes from HUFFMAN_ONLY → must be #3.
assert_identifies_as "16×A L1 default"         "$A16"    1 default       3

echo ""
echo "test: fingerprint #3 (zlib level=1, LZ77 inter-position match)"
assert_identifies_as "'ABCABCABCABC' L1 default" "$ABCREP" 1 default     3

# ─── Byte-equivalence: L6 DEFAULT_STRATEGY of low-entropy inputs ─────────
echo ""
echo "test: byte-equivalence — L6 default of LZ77-trigger input is NOT covered yet"
# 16×A at L6 DEFAULT should pick up matches more aggressively than L1 (max_chain=128),
# producing bytes DIFFERENT from any current fingerprint -> should return id=0.
"$GEN" "$A16" "$WORK/l6_a16.bin" 6 default 2>/dev/null
json=$("$CLI" identify --json --raw "$A16" --target "$WORK/l6_a16.bin" 2>/dev/null)
got_id=$(echo "$json" | sed -E 's/.*"fingerprint_id":([0-9]+).*/\1/')
# Could match #3 if L6's output happens to equal L1's for this input.
# Otherwise should be id=0. Either is reasonable for v0.1.
if [[ "$got_id" == "0" || "$got_id" == "3" ]]; then
	pass "L6 DEFAULT on 16×A returns id=$got_id (expected 0 or 3 for v0.1 coverage)"
else
	fail "L6 DEFAULT on 16×A: unexpected id=$got_id (json: $json)"
fi

echo ""
echo "real_zlib_roundtrip.sh: $PASS passed, $FAIL failed"
exit "$FAIL"
