#!/usr/bin/env bash
# Corpus hit-rate measurement.
#
# Compresses real project files via libz at each (level, strategy) combo,
# runs them through `deflate-fingerprint identify`, and reports the hit rate
# per fingerprint. Treats this as the v0.1 "70% hit rate on a real corpus"
# milestone from PLAN.md / GOALS.md (substituting our own source files for
# a curated .docx/.epub corpus — those are step-up-from-here once we
# implement multi-block boundaries).
#
# Single-block limit: skips inputs > 65535 bytes since our encoders don't
# yet handle multi-block DEFLATE (step C of the v0.1 plan).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$REPO_ROOT/zig-out/bin/deflate-fingerprint"
GEN_SRC="$SCRIPT_DIR/fixtures/gen_zlib_target.c"

if [[ ! -x "$CLI" ]]; then
	echo "FAIL: CLI not built at $CLI; run ./build first" >&2
	exit 1
fi

WORK="${TMPDIR:-/tmp}/dfp_corpus_test.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

GEN="$WORK/gen_zlib_target"
if ! cc -Wall -O2 "$GEN_SRC" -lz -o "$GEN" 2>"$WORK/gen_build.log"; then
	echo "FAIL: could not build gen_zlib_target" >&2
	cat "$WORK/gen_build.log" >&2
	exit 1
fi

# Pick text-heavy project files under 65535 bytes. These are real prose
# (docs) and real code (source) — representative of compressible content.
declare -a INPUTS
for f in \
	"$REPO_ROOT/README.md" \
	"$REPO_ROOT/PLAN.md" \
	"$REPO_ROOT/DESIGN.md" \
	"$REPO_ROOT/GOALS.md" \
	"$REPO_ROOT/docs/ENCODER_NOTES.md" \
	"$REPO_ROOT/docs/DEFLATE_DIALS.md" \
	"$REPO_ROOT/src/lib.zig" \
	"$REPO_ROOT/cli/main.c" \
	"$REPO_ROOT/include/deflate_fingerprint.h" \
	"$REPO_ROOT/flake.nix"
do
	if [[ -f "$f" ]]; then
		sz=$(wc -c < "$f")
		if [[ "$sz" -le 65535 ]]; then
			INPUTS+=("$f")
		fi
	fi
done

LEVELS=(0 1 2 3 4 5 6 7 8 9)
STRATEGIES=(default huffman_only rle fixed filtered)

declare -A HITS
declare -A MISSES_BY_STRATEGY
declare -A MISSES_BY_LEVEL
TOTAL=0
MATCHED=0

echo "Corpus hit-rate measurement"
echo "==========================="
echo "Inputs: ${#INPUTS[@]} project files (text + code, ≤ 65535 B)"
echo "Configs: ${#LEVELS[@]} levels × ${#STRATEGIES[@]} strategies = $((${#LEVELS[@]} * ${#STRATEGIES[@]})) configs per file"
echo ""

for input in "${INPUTS[@]}"; do
	name=$(basename "$input")
	for level in "${LEVELS[@]}"; do
		for strategy in "${STRATEGIES[@]}"; do
			target="$WORK/target.bin"
			if ! "$GEN" "$input" "$target" "$level" "$strategy" 2>"$WORK/gen_err"; then
				echo "  WARN: gen failed for $name L$level $strategy"
				continue
			fi
			TOTAL=$((TOTAL + 1))
			json=$("$CLI" identify --json --raw "$input" --target "$target" 2>/dev/null)
			id=$(echo "$json" | sed -E 's/.*"fingerprint_id":([0-9]+).*/\1/')
			if [[ "$id" != "0" ]]; then
				MATCHED=$((MATCHED + 1))
				HITS[$id]=$((${HITS[$id]:-0} + 1))
			else
				MISSES_BY_STRATEGY[$strategy]=$((${MISSES_BY_STRATEGY[$strategy]:-0} + 1))
				MISSES_BY_LEVEL[$level]=$((${MISSES_BY_LEVEL[$level]:-0} + 1))
				# Track size of missed inputs for the multi-block hypothesis.
				sz=$(wc -c < "$input")
				echo "  miss: $(basename "$input") (${sz}B) L${level} ${strategy}"
			fi
		done
	done
done

echo "Results"
echo "-------"
RATE=$(( MATCHED * 100 / TOTAL ))
echo "Total streams attributed: $MATCHED / $TOTAL ($RATE%)"
echo ""
echo "Hits per fingerprint:"
for k in $(echo "${!HITS[@]}" | tr ' ' '\n' | sort -n); do
	echo "  #$k: ${HITS[$k]}"
done

echo ""
echo "Misses by strategy:"
for k in default huffman_only rle fixed filtered; do
	echo "  $k: ${MISSES_BY_STRATEGY[$k]:-0}"
done

echo ""
echo "Misses by level:"
for k in 0 1 2 3 4 5 6 7 8 9; do
	echo "  L$k: ${MISSES_BY_LEVEL[$k]:-0}"
done

# Threshold: 70% from PLAN.md v0.1 goal. We expect to fall short because we
# don't yet cover RLE, FIXED, FILTERED strategies. But measuring shows
# where we actually are.
echo ""
if [[ "$RATE" -ge 70 ]]; then
	echo "✓ HIT RATE $RATE% >= 70% v0.1 goal"
	exit 0
else
	echo "* HIT RATE $RATE% < 70% v0.1 goal (expected; strategies RLE/FIXED/FILTERED not yet covered)"
	# Don't fail the test runner — this is a measurement, not an assertion.
	exit 0
fi
