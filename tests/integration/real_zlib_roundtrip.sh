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
trap 'command rm -rf "$WORK" 2>/dev/null' EXIT

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

# ─── Fingerprints #4/#5: zlib L6/L9 DEFAULT_STRATEGY (lazy matching) ──────
echo ""
echo "test: fingerprint #4 (zlib level=6 DEFAULT_STRATEGY, lazy LZ77)"
# 16×A: same RLE-style match shape as L1 — byte-equivalent. Either #3, #4, or #5
# is a valid attribution (zlib uses the same match logic for trivial RLE input).
assert_identifies_as "16×A L6 default"          "$A16"     6 default       "3,4,5"
# 'ABCABCABCABC' similarly converges across levels.
assert_identifies_as "'ABCABCABCABC' L6 default" "$ABCREP" 6 default       "3,4,5"
# "Hello, world!" — no useful matches, falls through to HUFFMAN_ONLY-equivalent.
assert_identifies_as "'Hello' L6 default"       "$HELLO"   6 default       "2,3,4,5"

echo ""
echo "test: fingerprint #5 (zlib level=9 DEFAULT_STRATEGY)"
assert_identifies_as "16×A L9 default"          "$A16"     9 default       "3,4,5"
assert_identifies_as "'ABCABCABCABC' L9 default" "$ABCREP" 9 default       "3,4,5"
assert_identifies_as "'Hello' L9 default"       "$HELLO"   9 default       "2,3,4,5"

# A longer, more compressible input. For this particular phrase, L1/L6/L9
# all produce byte-IDENTICAL output (the matches are easy enough that
# chain-depth and lazy-matching don't change the choices). Verified
# empirically: L1==L6==L9 == 50 bytes for this 110-char input. So any of
# #3/#4/#5 is a valid attribution; detector returns the first registered
# match (#3). Finding inputs where L6 and L9 actually differ from L1 is
# a follow-up — they need pathological patterns where lazy matching or
# chain depth changes the chosen tokens.
echo ""
echo "test: longish input — L1==L6==L9 byte-equivalence"
LONG_TXT="$WORK/longish.txt"
printf 'The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox.' > "$LONG_TXT"
assert_identifies_as "longish L6 default"       "$LONG_TXT" 6 default      "3,4,5"
assert_identifies_as "longish L9 default"       "$LONG_TXT" 9 default      "3,4,5"

echo ""
echo "real_zlib_roundtrip.sh: $PASS passed, $FAIL failed"
exit "$FAIL"
