/*
 * bench/probes/zlib_huffman_only_breakpoint.c
 *
 * Find the precise n at which zlib HUFFMAN_ONLY flips from BTYPE=01
 * (fixed Huffman) to BTYPE=00 (stored). Theory (from trees.c::_tr_flush_block):
 *
 *     stored_estimate = stored_len + 4    (bytes; LEN+NLEN only, omits BTYPE+pad)
 *     opt_estimate    = (static_len_bits + 3 + 7) >> 3   (bytes; static Huffman)
 *     if stored_estimate <= opt_estimate -> emit STORED, else emit FIXED
 *
 * Where static_len_bits = sum_of_literal_code_lengths + 7 (for the EOB symbol).
 *
 * Sweep n=1..32 for:
 *   - all-8-bit-literals (NUL or 'A')        -> static_len = n*8 + 7
 *   - all-9-bit-literals (0xFF)              -> static_len = n*9 + 7
 *   - alternating 8/9-bit literals           -> static_len = n*8.5 + 7 (avg)
 *
 * For each sample, observe the actual block type and compare to the predicted
 * breakpoint. Report a verdict.
 *
 * Build:
 *   nix develop -c cc -Wall -Wextra -O2 \
 *     bench/probes/zlib_huffman_only_breakpoint.c -lz -o /tmp/probe_bp
 *   /tmp/probe_bp
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define OUT_CAP 4096

/* Detect the BTYPE of the first block in a raw DEFLATE stream.
 *   00 = STORED, 01 = FIXED, 10 = DYNAMIC, 11 = reserved/error.
 * Returns -1 if the buffer is empty. */
static int btype_of(const unsigned char *out, size_t n) {
	if (n == 0) return -1;
	/* bits 1-2 LSB-first of byte 0 */
	return (out[0] >> 1) & 0x3;
}

static const char *btype_name(int b) {
	switch (b) {
		case 0: return "STORED";
		case 1: return "FIXED";
		case 2: return "DYNAMIC";
		case 3: return "RESERVED";
		default: return "(empty)";
	}
}

static size_t deflate_raw(const unsigned char *in, size_t in_len,
                          int strategy, unsigned char *out) {
	z_stream s = {0};
	if (deflateInit2(&s, 6, Z_DEFLATED, -15, 8, strategy) != Z_OK) return 0;
	s.next_in = (Bytef *)in;
	s.avail_in = (uInt)in_len;
	s.next_out = out;
	s.avail_out = OUT_CAP;
	int rc = deflate(&s, Z_FINISH);
	size_t out_len = OUT_CAP - s.avail_out;
	deflateEnd(&s);
	if (rc != Z_STREAM_END) return 0;
	return out_len;
}

/* For a hypothetical n-byte input where each literal costs `bits_per_lit` bits,
 * apply zlib's stored-vs-fixed decision formula. Returns 1 if STORED predicted. */
static int predict_stored(size_t n, int bits_per_lit) {
	int static_len_bits = (int)n * bits_per_lit + 7; /* +7 for EOB */
	int opt_lenb = (static_len_bits + 3 + 7) >> 3;   /* bytes */
	int stored_est = (int)n + 4;                     /* bytes */
	return stored_est <= opt_lenb;
}

static void sweep(const char *label, unsigned char filler, int expected_bits) {
	printf("\n--- %s (each literal expects %d bits) ---\n", label, expected_bits);
	printf("  n  | out_len | type    | predicted | match?\n");
	printf("  ---+---------+---------+-----------+-------\n");
	unsigned char in[64];
	unsigned char out[OUT_CAP];
	int mismatch_count = 0;
	for (size_t n = 1; n <= 32; n++) {
		memset(in, filler, n);
		size_t out_len = deflate_raw(in, n, Z_HUFFMAN_ONLY, out);
		int actual = btype_of(out, out_len);
		int predicted_stored = predict_stored(n, expected_bits);
		const char *predicted = predicted_stored ? "STORED" : "FIXED";
		int match = (actual == (predicted_stored ? 0 : 1));
		if (!match) mismatch_count++;
		printf("  %2zu | %7zu | %-7s | %-9s | %s\n",
		       n, out_len, btype_name(actual), predicted,
		       match ? "ok" : "MISMATCH");
	}
	printf("  conclusion: %s\n",
	       mismatch_count == 0 ? "formula matches zlib exactly"
	                          : "formula DIVERGES — refine model");
}

/* Alternating high/low literals: at even n the avg bits/lit = 8.5, but the
 * actual static_len = (n/2)*8 + (n/2)*9 = n*8.5 even if n is odd-ish, since
 * we alternate. We compute static_len exactly for prediction. */
static void sweep_alternating(void) {
	printf("\n--- alternating high (0xFF, 9-bit) / low (0x41 'A', 8-bit) ---\n");
	printf("  n  | out_len | type    | predicted | match?\n");
	printf("  ---+---------+---------+-----------+-------\n");
	unsigned char in[64];
	unsigned char out[OUT_CAP];
	int mismatch_count = 0;
	for (size_t n = 1; n <= 32; n++) {
		for (size_t i = 0; i < n; i++) in[i] = (i & 1) ? 0xFF : 0x41;
		size_t out_len = deflate_raw(in, n, Z_HUFFMAN_ONLY, out);
		int actual = btype_of(out, out_len);
		size_t nhigh = n / 2;       /* number of 0xFF at odd indices */
		size_t nlow  = (n + 1) / 2; /* number of 'A'  at even indices */
		int static_len_bits = (int)nhigh * 9 + (int)nlow * 8 + 7;
		int opt_lenb = (static_len_bits + 3 + 7) >> 3;
		int stored_est = (int)n + 4;
		int predicted_stored = (stored_est <= opt_lenb);
		const char *predicted = predicted_stored ? "STORED" : "FIXED";
		int match = (actual == (predicted_stored ? 0 : 1));
		if (!match) mismatch_count++;
		printf("  %2zu | %7zu | %-7s | %-9s | %s\n",
		       n, out_len, btype_name(actual), predicted,
		       match ? "ok" : "MISMATCH");
	}
	printf("  conclusion: %s\n",
	       mismatch_count == 0 ? "formula matches zlib exactly"
	                          : "formula DIVERGES — refine model");
}

int main(void) {
	printf("zlib version: %s\n", zlibVersion());
	printf("Predicting zlib HUFFMAN_ONLY stored-vs-fixed decision via:\n");
	printf("  if (n + 4) <= ((n*bits_per_lit + 7 + 3) >> 3): STORED else FIXED\n");

	sweep("all-NUL (8-bit literal)",  0x00, 8);
	sweep("all-'A'  (8-bit literal)", 'A',  8);
	sweep("all-0xFF (9-bit literal)", 0xFF, 9);
	sweep_alternating();
	return 0;
}
