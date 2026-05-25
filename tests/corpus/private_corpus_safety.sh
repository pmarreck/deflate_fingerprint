#!/usr/bin/env bash
# Verify local/private corpus paths cannot be accidentally committed.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0

pass() {
	PASS=$((PASS + 1))
}

fail() {
	FAIL=$((FAIL + 1))
	echo "FAIL: $1"
}

assert_ignored() {
	local path="$1"
	if git -C "$ROOT" check-ignore --quiet "$path"; then
		pass
	else
		fail "$path is not gitignored"
	fi
}

assert_ignored "corpus_local/example.bin"
assert_ignored "corpus_private/example.bin"
assert_ignored "private-corpus/example.bin"
assert_ignored "tests/corpus/corpus_local/xlsx/wild/sample.xlsx"
assert_ignored "tests/corpus/corpus_private/xlsx/wild/sample.xlsx"
assert_ignored "tests/corpus/private/sample.bin"
assert_ignored "tests/corpus/local/sample.bin"
assert_ignored ".dfp-private/manifest.tsv"

echo "$PASS passed, $FAIL failed"
exit "$FAIL"
