/*
 * bench/probes/zlib_level1_lz77.c
 *
 * Ground-truth fixtures for the simplest LZ77 variant: zlib at level=1
 * (Z_DEFAULT_STRATEGY, deflate_fast). Algorithm parameters:
 *   max_chain_length = 4    (walk at most 4 hash-chain entries)
 *   good_match       = 4    (early-bail if a match >= 4 is found)
 *   nice_match       = 8    (accept-immediately at 8+)
 *   max_lazy_match   = 0    (greedy — no lazy deferral)
 *   min_match        = 3
 *   max_match        = 258
 *
 * Inputs designed to exercise specific code paths:
 *   - no matches possible (single byte, all distinct)        -> all literals
 *   - exact 3-byte match boundary
 *   - 4+ byte match (triggers good_match early-bail)
 *   - long runs (overlapping matches)
 *   - input within window distance
 *
 * Build & run:
 *   nix develop -c cc -Wall -Wextra -O2 \
 *     bench/probes/zlib_level1_lz77.c -lz -o /tmp/probe_lz77
 *   /tmp/probe_lz77
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define OUT_CAP 4096

static size_t deflate_l1(const unsigned char *in, size_t in_len, unsigned char *out) {
    z_stream s = {0};
    if (deflateInit2(&s, 1, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK) return 0;
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

/* LSB-first bit reader for tearing apart the output. */
typedef struct {
    const unsigned char *bytes;
    size_t n;
    size_t bit_pos;
} BitReader;

static unsigned read_bits(BitReader *r, int nbits) {
    unsigned v = 0;
    for (int i = 0; i < nbits; i++) {
        size_t byte = r->bit_pos >> 3;
        int    bit  = r->bit_pos & 7;
        if (byte >= r->n) return v;
        v |= ((r->bytes[byte] >> bit) & 1u) << i;
        r->bit_pos++;
    }
    return v;
}

static const char *btype_name(int b) {
    switch (b) {
        case 0: return "STORED";
        case 1: return "FIXED";
        case 2: return "DYNAMIC";
        case 3: return "RESERVED";
        default: return "?";
    }
}

static void probe(const char *label, const unsigned char *in, size_t in_len) {
    unsigned char out[OUT_CAP];
    size_t out_len = deflate_l1(in, in_len, out);

    printf("\n=== %s (in_len=%zu) -> %zu B ===\n", label, in_len, out_len);
    printf("  input:  ");
    for (size_t i = 0; i < in_len && i < 64; i++) {
        if (in[i] >= 0x20 && in[i] < 0x7F) printf("%c", in[i]); else printf(".");
    }
    if (in_len > 64) printf("...");
    printf("\n");
    printf("  bytes: ");
    for (size_t i = 0; i < out_len; i++) printf("%02x ", out[i]);
    printf("\n");

    BitReader r = { out, out_len, 0 };
    unsigned bfinal = read_bits(&r, 1);
    unsigned btype  = read_bits(&r, 2);
    printf("  BFINAL=%u BTYPE=%u (%s)\n", bfinal, btype, btype_name(btype));
}

int main(void) {
    printf("zlib version: %s\n", zlibVersion());
    printf("Probe: zlib level=1 (deflate_fast, greedy), strategy=Z_DEFAULT_STRATEGY, raw DEFLATE.\n");

    /* No-match cases — should be all literals, equivalent to fixed-Huffman
     * output for the literal-only encoder. */
    probe("'A' (1 B, no match possible)",       (const unsigned char *)"A",       1);
    probe("'AB' (2 B, no match)",                (const unsigned char *)"AB",      2);
    probe("'ABC' (3 B, no repeat)",              (const unsigned char *)"ABC",     3);
    probe("'ABCD' (4 B, no repeat)",             (const unsigned char *)"ABCD",    4);
    probe("'Hello, world!' (13 B, no repeats)",  (const unsigned char *)"Hello, world!", 13);

    /* Short repeated patterns — should trigger LZ77 matches. */
    probe("'ABCABC' (6 B, one 3-byte match at distance 3)",
          (const unsigned char *)"ABCABC", 6);
    probe("'ABCDABCD' (8 B, one 4-byte match)",
          (const unsigned char *)"ABCDABCD", 8);
    probe("'AAAAAAAA' (8 A's, RLE-like via match dist=1)",
          (const unsigned char *)"AAAAAAAA", 8);
    probe("'AAAA' (4 A's, length-3 match opportunity)",
          (const unsigned char *)"AAAA", 4);
    probe("'AAA' (3 A's, smallest match-possible)",
          (const unsigned char *)"AAA", 3);

    /* Longer repeated content — should get good match savings. */
    probe("'ABCABCABCABC' (12 B, 9-byte match)",
          (const unsigned char *)"ABCABCABCABC", 12);
    probe("16x 'A' (RLE)",
          (const unsigned char *)"AAAAAAAAAAAAAAAA", 16);

    /* Mixed: literal-then-match patterns. */
    probe("'HelloHello' (10 B, 5-byte match at dist 5)",
          (const unsigned char *)"HelloHello", 10);
    probe("'The quick brown fox quick' (25 B, 'quick' repeats)",
          (const unsigned char *)"The quick brown fox quick", 25);

    return 0;
}
