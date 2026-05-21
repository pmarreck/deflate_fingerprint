/*
 * bench/probes/zlib_huffman_only.c
 *
 * Probe: dump real zlib's raw-DEFLATE output for strategy=Z_HUFFMAN_ONLY across
 * levels 1..9 and a small set of input shapes. The goal is to learn empirically:
 *
 *   1. What bytes does zlib actually emit for HUFFMAN_ONLY?
 *   2. Does the (level) parameter affect the output when matches are disabled?
 *      Theory: it shouldn't — level controls match-finding effort, and
 *      HUFFMAN_ONLY skips matches entirely. Verify by inspection.
 *   3. What block-type does zlib pick (00=stored, 01=fixed, 10=dynamic)?
 *   4. Are tiny inputs emitted as fixed (cheap) or dynamic (full table)?
 *
 * windowBits=-15 means RAW DEFLATE (no zlib/gzip wrapper) — that's the surface
 * we are fingerprinting. The wrapper bytes are deterministic given the format
 * and can be layered on top later.
 *
 * Build:
 *   nix develop -c cc -Wall -Wextra -O2 bench/probes/zlib_huffman_only.c -lz -o /tmp/probe_huff
 * Run:
 *   /tmp/probe_huff
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static void dump(const char *label, const unsigned char *bytes, size_t n) {
	printf("%-40s [%2zu B] ", label, n);
	for (size_t i = 0; i < n; i++) printf("%02x", bytes[i]);
	printf("  |  bits=");
	for (size_t i = 0; i < n; i++) {
		for (int b = 0; b < 8; b++) {
			/* DEFLATE is LSB-first within each byte */
			putchar((bytes[i] >> b) & 1 ? '1' : '0');
		}
		putchar(' ');
	}
	printf("\n");
}

static int probe_one(const char *desc, const unsigned char *in, size_t in_len,
                     int level, int strategy) {
	z_stream s = {0};
	if (deflateInit2(&s, level, Z_DEFLATED, -15, 8, strategy) != Z_OK) {
		fprintf(stderr, "deflateInit2 failed for %s\n", desc);
		return -1;
	}
	unsigned char out[8192];
	s.next_in = (Bytef *)in;
	s.avail_in = (uInt)in_len;
	s.next_out = out;
	s.avail_out = sizeof(out);
	int rc = deflate(&s, Z_FINISH);
	if (rc != Z_STREAM_END) {
		fprintf(stderr, "deflate(Z_FINISH)=%d for %s\n", rc, desc);
		deflateEnd(&s);
		return -1;
	}
	size_t out_len = sizeof(out) - s.avail_out;
	deflateEnd(&s);

	char label[160];
	snprintf(label, sizeof(label), "%s L%d", desc, level);
	dump(label, out, out_len);
	return 0;
}

static const struct { const char *name; const unsigned char *bytes; size_t len; } inputs[] = {
	{ "empty",       (const unsigned char *)"",                  0 },
	{ "single_A",    (const unsigned char *)"A",                 1 },
	{ "four_A",      (const unsigned char *)"AAAA",              4 },
	{ "alphabet",    (const unsigned char *)"ABCDEFG",           7 },
	{ "hello",       (const unsigned char *)"Hello, world!",     13 },
	{ "mixed",       (const unsigned char *)"AAAABBBBCCCCDDDD",  16 },
};

int main(void) {
	printf("zlib version: %s\n", zlibVersion());
	printf("Probe: raw DEFLATE (windowBits=-15), strategy=Z_HUFFMAN_ONLY, memLevel=8\n\n");

	for (size_t i = 0; i < sizeof(inputs)/sizeof(inputs[0]); i++) {
		printf("--- input: %-12s (%zu B) ---\n", inputs[i].name, inputs[i].len);
		for (int lvl = 1; lvl <= 9; lvl++) {
			probe_one(inputs[i].name, inputs[i].bytes, inputs[i].len, lvl, Z_HUFFMAN_ONLY);
		}
		printf("\n");
	}

	/* Sanity-check: same inputs under DEFAULT_STRATEGY at L6 (the workhorse)
	 * just so we can eyeball the difference for orientation. */
	printf("=== orientation: DEFAULT_STRATEGY L6 (for comparison) ===\n");
	for (size_t i = 0; i < sizeof(inputs)/sizeof(inputs[0]); i++) {
		probe_one(inputs[i].name, inputs[i].bytes, inputs[i].len, 6, Z_DEFAULT_STRATEGY);
	}
	return 0;
}
