#!/usr/bin/env bash
# Integration test: Info-ZIP-style method=8 streams with 4096-symbol flushes.
#
# Generates a deterministic public fixture, compresses it with Info-ZIP `zip -6`,
# extracts the raw DEFLATE member, and verifies the registry reports #32.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$REPO_ROOT/zig-out/bin/deflate-fingerprint"
EXTRACT_SRC="$SCRIPT_DIR/fixtures/extract_zip_deflate.c"

WORK="${TMPDIR:-/tmp}/dfp_infozip_test.$$"
mkdir -p "$WORK/in"
trap 'command rm -rf "$WORK" 2>/dev/null' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

if [[ ! -x "$CLI" ]]; then
	fail "CLI not built at $CLI; run ./build first"
	echo "infozip_roundtrip.sh: $PASS passed, $FAIL failed"
	exit "$FAIL"
fi

EXTRACT="$WORK/extract_zip_deflate"
if cc -Wall -Wextra -O2 "$EXTRACT_SRC" -o "$EXTRACT" 2>"$WORK/extract_build.log"; then
	pass "extract_zip_deflate helper builds"
else
	fail "extract_zip_deflate helper failed to build"
	cat "$WORK/extract_build.log" >&2
	echo "infozip_roundtrip.sh: $PASS passed, $FAIL failed"
	exit "$FAIL"
fi

make_pathhash_fixture() {
	local raw_path="$1"
	local random_tail_bytes="$2"
	ruby -e '
		x = 0xabcdef01
		data = String.new.b
		180.times do |i|
			h = ""
			4.times do
				x = (x * 1103515245 + 12345) & 0xffffffff
				h << "%08x" % x
			end
			data << "\t\t<key>Payload/NASA.app/Images/PlanetGallery/mission_photo_#{i}_thumbnail.png</key>\n"
			data << "\t\t<data>#{h}</data>\n"
		end
		tail = ARGV[1].to_i
		tail.times do
			x = (x * 1664525 + 1013904223) & 0xffffffff
			data << ((x >> 24) & 255)
		end
		File.binwrite(ARGV[0], data)
	' "$raw_path" "$random_tail_bytes"
}

assert_infozip_identifies_as_32() {
	local label="$1"
	local raw="$2"
	local zip_path="$3"
	local target="$4"

	if (cd "$(dirname "$raw")" && nix develop "$REPO_ROOT" -c zip -q -6 "$zip_path" "$(basename "$raw")"); then
		pass "$label: Info-ZIP fixture compressed"
	else
		fail "$label: Info-ZIP zip -6 failed"
		return
	fi

	if "$EXTRACT" "$zip_path" "$target" 2>"$WORK/extract.log"; then
		pass "$label: raw DEFLATE member extracted"
	else
		fail "$label: raw DEFLATE extraction failed"
		cat "$WORK/extract.log" >&2
		return
	fi

	json=$("$CLI" identify --json --raw "$raw" --target "$target" 2>"$WORK/identify.log")
	rc=$?
	got_id=$(echo "$json" | sed -E 's/.*"fingerprint_id":([0-9]+).*/\1/')
	got_conf=$(echo "$json" | sed -E 's/.*"confidence":([0-9]+).*/\1/')
	if [[ "$rc" -eq 0 && "$got_id" == "32" && "$got_conf" == "0" ]]; then
		pass "$label: identifies as #32"
	else
		fail "$label: expected #32 byte-exact; rc=$rc json=$json"
		cat "$WORK/identify.log" >&2
	fi
}

RAW="$WORK/in/pathhash.txt"
TARGET="$WORK/pathhash.deflate"
ZIP_PATH="$WORK/pathhash.zip"
make_pathhash_fixture "$RAW" 0
assert_infozip_identifies_as_32 "all-profitable 4096 blocks" "$RAW" "$ZIP_PATH" "$TARGET"

MIXED_RAW="$WORK/in/pathhash-random-tail.txt"
MIXED_TARGET="$WORK/pathhash-random-tail.deflate"
MIXED_ZIP="$WORK/pathhash-random-tail.zip"
make_pathhash_fixture "$MIXED_RAW" 50000
assert_infozip_identifies_as_32 "profitability checkpoint then stored fallback" "$MIXED_RAW" "$MIXED_ZIP" "$MIXED_TARGET"

echo ""
echo "infozip_roundtrip.sh: $PASS passed, $FAIL failed"
exit "$FAIL"
