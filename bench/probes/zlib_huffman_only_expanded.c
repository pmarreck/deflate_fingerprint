/*
 * bench/probes/zlib_huffman_only_expanded.c
 *
 * Expanded HUFFMAN_ONLY probe — explores knobs and edge cases beyond the
 * basic level sweep. Specifically:
 *
 *   A. High-byte literals (0xC0..0xFF) — these use the 9-bit branch of the
 *      RFC 1951 §3.2.6 fixed-Huffman table (codes 110010000..111111111).
 *      We need to confirm the 9-bit codes round-trip correctly.
 *   B. NUL bytes (0x00, 8-bit code 00110000) — easy literal but worth a
 *      separate eyeball.
 *   C. Input crossing the 64 KB sliding window — zlib emits one or more
 *      blocks; we want to know how block boundaries are placed for
 *      HUFFMAN_ONLY (which has no matches, so no window constraint really).
 *   D. memLevel sweep (1..9) — should NOT affect HUFFMAN_ONLY output;
 *      memLevel controls the hash table size, which matters only for
 *      match-finding.
 *   E. Wrapper variants — windowBits=-15 (raw, baseline), +15 (zlib wrapper:
 *      2-byte header + 4-byte adler32 trailer), +31 (gzip wrapper: 10-byte
 *      header + 8-byte trailer).
 *
 * Build & run:
 *   nix develop -c cc -Wall -Wextra -O2 \
 *     bench/probes/zlib_huffman_only_expanded.c -lz -o /tmp/probe_huff_ex
 *   /tmp/probe_huff_ex
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define OUT_CAP (256 * 1024)

/* Compress `in_len` bytes from `in` with the given parameters and write the
 * resulting raw / wrapped DEFLATE stream into `out` (capacity OUT_CAP).
 * Returns output length, or 0 on failure. */
static size_t deflate_to(const unsigned char *in, size_t in_len,
                         int level, int windowBits, int memLevel, int strategy,
                         unsigned char *out) {
	z_stream s = {0};
	if (deflateInit2(&s, level, Z_DEFLATED, windowBits, memLevel, strategy) != Z_OK) {
		fprintf(stderr, "deflateInit2 failed (wb=%d ml=%d str=%d)\n",
		        windowBits, memLevel, strategy);
		return 0;
	}
	s.next_in = (Bytef *)in;
	s.avail_in = (uInt)in_len;
	s.next_out = out;
	s.avail_out = OUT_CAP;
	int rc = deflate(&s, Z_FINISH);
	size_t out_len = OUT_CAP - s.avail_out;
	deflateEnd(&s);
	if (rc != Z_STREAM_END) {
		fprintf(stderr, "deflate(Z_FINISH)=%d for in_len=%zu wb=%d\n",
		        rc, in_len, windowBits);
		return 0;
	}
	return out_len;
}

static void print_hex_truncated(const unsigned char *bytes, size_t n, size_t max_show) {
	size_t show = n < max_show ? n : max_show;
	for (size_t i = 0; i < show; i++) printf("%02x", bytes[i]);
	if (n > max_show) printf("...(%zu more bytes)", n - max_show);
}

/* ─────────────────────────────────────────────────────────────────────────
 * A. High-byte literals
 * ───────────────────────────────────────────────────────────────────────── */
static void probe_high_byte_literals(void) {
	printf("=== A. High-byte literals (use 9-bit branch of fixed Huffman) ===\n");

	/* 4 high-byte literals in a row: 0xFE 0xFF 0xFE 0xFF (no useful match) */
	const unsigned char hi4[4] = { 0xFE, 0xFF, 0xFE, 0xFF };
	/* Single 0xFF */
	const unsigned char one_ff[1] = { 0xFF };
	/* Single 0xC0 (boundary of 8-bit/9-bit branches) */
	const unsigned char one_c0[1] = { 0xC0 };
	/* All 16 high bytes ascending */
	unsigned char hi16[16];
	for (int i = 0; i < 16; i++) hi16[i] = (unsigned char)(0xC0 + i);

	const struct { const char *name; const unsigned char *bytes; size_t len; } cases[] = {
		{ "single_0xC0", one_c0, 1 },
		{ "single_0xFF", one_ff, 1 },
		{ "0xFE,0xFF,0xFE,0xFF", hi4, 4 },
		{ "0xC0..0xCF", hi16, 16 },
	};
	unsigned char out[OUT_CAP];
	for (size_t i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
		size_t n = deflate_to(cases[i].bytes, cases[i].len,
		                     6, -15, 8, Z_HUFFMAN_ONLY, out);
		printf("  %-22s in_len=%2zu -> %zu B: ", cases[i].name, cases[i].len, n);
		for (size_t j = 0; j < n; j++) printf("%02x ", out[j]);
		printf("\n");
	}
	printf("\n");
}

/* ─────────────────────────────────────────────────────────────────────────
 * B. NUL bytes
 * ───────────────────────────────────────────────────────────────────────── */
static void probe_nul_bytes(void) {
	printf("=== B. NUL bytes ===\n");
	const unsigned char one_nul[1] = { 0x00 };
	const unsigned char four_nul[4] = { 0x00, 0x00, 0x00, 0x00 };
	const unsigned char nul_and_a[2] = { 0x00, 'A' };

	const struct { const char *name; const unsigned char *bytes; size_t len; } cases[] = {
		{ "single_NUL",   one_nul,   1 },
		{ "four_NUL",     four_nul,  4 },
		{ "NUL_then_A",   nul_and_a, 2 },
	};
	unsigned char out[OUT_CAP];
	for (size_t i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
		size_t n = deflate_to(cases[i].bytes, cases[i].len,
		                     6, -15, 8, Z_HUFFMAN_ONLY, out);
		printf("  %-14s in_len=%2zu -> %zu B: ", cases[i].name, cases[i].len, n);
		for (size_t j = 0; j < n; j++) printf("%02x ", out[j]);
		printf("\n");
	}
	printf("\n");
}

/* ─────────────────────────────────────────────────────────────────────────
 * C. Large input — crosses 64 KB window
 * ───────────────────────────────────────────────────────────────────────── */
static void probe_large_input(void) {
	printf("=== C. Large input crossing 64 KB window ===\n");
	const size_t in_len = 80 * 1024; /* > 64 KB */
	unsigned char *in = malloc(in_len);
	if (!in) { fprintf(stderr, "OOM\n"); return; }
	/* Deterministic pseudorandom so the result is reproducible. xorshift32. */
	uint32_t seed = 0xC0FFEE42;
	for (size_t i = 0; i < in_len; i++) {
		seed ^= seed << 13;
		seed ^= seed >> 17;
		seed ^= seed << 5;
		in[i] = (unsigned char)(seed & 0xFF);
	}
	unsigned char *out = malloc(OUT_CAP);
	if (!out) { free(in); fprintf(stderr, "OOM\n"); return; }
	size_t n = deflate_to(in, in_len, 6, -15, 8, Z_HUFFMAN_ONLY, out);
	printf("  random_80KB -> %zu B (ratio: %.3f)\n", n, (double)n / in_len);
	printf("  first 32 bytes: ");
	print_hex_truncated(out, n, 32);
	printf("\n  last 32 bytes:  ");
	if (n > 32) {
		for (size_t i = n - 32; i < n; i++) printf("%02x", out[i]);
	}
	printf("\n");
	/* Look for any 00 00 FF FF marker (would indicate a stored block insertion)
	 * or a fresh BFINAL=0 block header — both would tell us about block
	 * boundary insertion. */
	int found_stored = 0;
	for (size_t i = 0; i + 4 <= n; i++) {
		if (out[i] == 0x00 && out[i+1] == 0x00 && out[i+2] == 0xFF && out[i+3] == 0xFF) {
			found_stored = 1; break;
		}
	}
	printf("  stored-block marker (00 00 ff ff) present: %s\n",
	       found_stored ? "YES" : "no");
	free(in);
	free(out);
	printf("\n");
}

/* ─────────────────────────────────────────────────────────────────────────
 * D. memLevel sweep
 * ───────────────────────────────────────────────────────────────────────── */
static void probe_memlevel(void) {
	printf("=== D. memLevel 1..9 (should not affect HUFFMAN_ONLY) ===\n");
	const unsigned char in[] = "Hello, world!";
	const size_t in_len = sizeof(in) - 1;
	unsigned char out_ref[OUT_CAP];
	size_t n_ref = deflate_to(in, in_len, 6, -15, 8, Z_HUFFMAN_ONLY, out_ref);
	printf("  reference (memLevel=8) -> %zu B: ", n_ref);
	for (size_t i = 0; i < n_ref; i++) printf("%02x", out_ref[i]);
	printf("\n");
	int all_identical = 1;
	for (int ml = 1; ml <= 9; ml++) {
		unsigned char out[OUT_CAP];
		size_t n = deflate_to(in, in_len, 6, -15, ml, Z_HUFFMAN_ONLY, out);
		int identical = (n == n_ref) && (memcmp(out, out_ref, n) == 0);
		if (!identical) all_identical = 0;
		printf("  memLevel=%d -> %zu B: %s\n", ml, n,
		       identical ? "identical to ref" : "DIFFERS");
	}
	printf("  conclusion: %s\n",
	       all_identical ? "memLevel does not affect HUFFMAN_ONLY"
	                    : "memLevel DOES affect HUFFMAN_ONLY — investigate");
	printf("\n");
}

/* ─────────────────────────────────────────────────────────────────────────
 * E. Wrapper variants
 * ───────────────────────────────────────────────────────────────────────── */
static void probe_wrappers(void) {
	printf("=== E. Wrapper variants ===\n");
	const unsigned char in[] = "Hello, world!";
	const size_t in_len = sizeof(in) - 1;
	unsigned char out[OUT_CAP];

	struct { const char *name; int wb; } variants[] = {
		{ "raw DEFLATE (windowBits=-15)",        -15 },
		{ "raw DEFLATE smaller win (wb=-9)",      -9 },
		{ "zlib wrapper (windowBits=+15)",        15 },
		{ "zlib wrapper smaller win (wb=+9)",      9 },
		{ "gzip wrapper (windowBits=+31)",        31 },
	};
	for (size_t i = 0; i < sizeof(variants)/sizeof(variants[0]); i++) {
		size_t n = deflate_to(in, in_len, 6, variants[i].wb, 8, Z_HUFFMAN_ONLY, out);
		printf("  %-35s -> %zu B: ", variants[i].name, n);
		for (size_t j = 0; j < n; j++) printf("%02x ", out[j]);
		printf("\n");
	}
	printf("\n");
	printf("  Notes:\n");
	printf("    - zlib wrapper = 2-byte header (CMF, FLG) + raw DEFLATE + 4-byte adler32 trailer\n");
	printf("    - gzip wrapper = 10-byte header + raw DEFLATE + 8-byte trailer (crc32 + isize)\n");
	printf("    - windowBits sign chooses framing; magnitude is the LZ77 window log2 (8..15 = 256..32KB)\n");
}

int main(void) {
	printf("zlib version: %s\n\n", zlibVersion());
	probe_high_byte_literals();
	probe_nul_bytes();
	probe_large_input();
	probe_memlevel();
	probe_wrappers();
	return 0;
}
