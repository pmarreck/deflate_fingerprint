#!/usr/bin/env bash
# Test the local corpus sampler against a tiny fake NAS tree.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SAMPLER="$ROOT/tests/corpus/scripts/sample_local"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dfp_sample_local.XXXXXX")"
NAS="$TMP_ROOT/fake nas"
DEST="$TMP_ROOT/corpus local"
PASS=0
FAIL=0

pass() {
	PASS=$((PASS + 1))
}

fail() {
	FAIL=$((FAIL + 1))
	echo "FAIL: $1"
}

capture_cmd() {
	local prefix="$1"
	shift
	"$@" > "$TMP_ROOT/$prefix.out" 2> "$TMP_ROOT/$prefix.err"
	return $?
}

mkdir -p "$NAS/Office Docs" "$NAS/Other"
printf 'fake xlsx one' > "$NAS/Office Docs/budget one.xlsx"
printf 'fake xlsx two' > "$NAS/Other/budget two.xlsx"
printf 'fake zip' > "$NAS/Other/archive.zip"

capture_cmd help "$SAMPLER" --help
rc=$?
if [[ "$rc" -eq 0 ]] && grep -q -- "--dest-root" "$TMP_ROOT/help.out" && grep -q -- "--inventory" "$TMP_ROOT/help.out"; then
	pass
else
	fail "help should document --dest-root and --inventory"
fi
if [[ -s "$TMP_ROOT/help.err" ]]; then
	fail "help should not write stderr"
else
	pass
fi

capture_cmd missing "$SAMPLER" --nas-root "$TMP_ROOT/missing" --format xlsx
rc=$?
if [[ "$rc" -eq 1 ]] && grep -q "not mounted" "$TMP_ROOT/missing.err"; then
	pass
else
	fail "missing NAS root should fail cleanly"
fi

capture_cmd dry "$SAMPLER" --nas-root "$NAS" --dest-root "$DEST" --format xlsx --n 1 --seed 7 --dry-run
rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "xlsx: selected 1 files" "$TMP_ROOT/dry.out"; then
	pass
else
	fail "dry-run should select one xlsx"
fi
if [[ ! -d "$DEST/xlsx/wild" ]]; then
	pass
else
	fail "dry-run should not create destination files"
fi

capture_cmd copy "$SAMPLER" --nas-root "$NAS" --dest-root "$DEST" --format xlsx --n 1 --seed 7
rc=$?
copied=$(find "$DEST/xlsx/wild" -type f 2>/dev/null | wc -l | awk '{print $1}')
if [[ "$rc" -eq 0 && "$copied" -eq 1 ]]; then
	pass
else
	fail "copy mode should copy exactly one xlsx"
fi
if find "$DEST/xlsx/wild" -type f -name '*budget*one.xlsx' -o -name '*budget*two.xlsx' | grep -q .; then
	pass
else
	fail "copied path should preserve basename with spaces"
fi
if [[ -s "$TMP_ROOT/copy.err" ]]; then
	fail "copy mode should not write stderr"
else
	pass
fi

INV="$TMP_ROOT/private-inventory.txt"
DEST2="$TMP_ROOT/corpus from inventory"
capture_cmd inventory "$SAMPLER" --nas-root "$NAS" --dest-root "$DEST2" --inventory "$INV" --n 1 --seed 7
rc=$?
xlsx_count=$(find "$DEST2/xlsx/wild" -type f 2>/dev/null | wc -l | awk '{print $1}')
zip_count=$(find "$DEST2/zip/wild" -type f 2>/dev/null | wc -l | awk '{print $1}')
if [[ "$rc" -eq 0 && -s "$INV" && "$xlsx_count" -eq 1 && "$zip_count" -eq 1 ]]; then
	pass
else
	fail "inventory mode should scan once and sample multiple formats"
fi
if grep -q "archive.zip" "$INV" && grep -q "budget one.xlsx\\|budget two.xlsx" "$INV"; then
	pass
else
	fail "inventory should contain matching candidate paths"
fi

echo "$PASS passed, $FAIL failed"
exit "$FAIL"
