/*
 * bench/probes/zlib_huffman_only_dynamic.c
 *
 * Ground-truth fixtures for the dynamic-Huffman encoder we're about to build.
 * Targets tiny inputs at which the breakpoint probe showed zlib HUFFMAN_ONLY
 * picks DYNAMIC blocks. For each, we dump:
 *
 *   - the raw bytes
 *   - a bit-level decode of the DYNAMIC block header (BFINAL, BTYPE, HLIT,
 *     HDIST, HCLEN, the code-length-code lengths in bl_order)
 *
 * The point: by reading these bytes by hand we learn the exact tree shape
 * and RLE choices zlib makes for trivial input distributions. Those shapes
 * become the failing-test fixtures for `encodeDynamicHuffmanLiterals`.
 *
 * Build & run:
 *   nix develop -c cc -Wall -Wextra -O2 \
 *     bench/probes/zlib_huffman_only_dynamic.c -lz -o /tmp/probe_dyn
 *   /tmp/probe_dyn
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define OUT_CAP 1024

/* zlib's bl_order permutation (per RFC 1951 §3.2.7). Code-length codes are
 * emitted in this order so trailing zero-length ones can be elided. */
static const int bl_order[19] = {
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
};

/* LSB-first bit reader over a byte array. read_bits(reader, n) returns the
 * next n bits packed little-endian (bit 0 of value = first bit emitted). */
typedef struct {
    const unsigned char *bytes;
    size_t n;
    size_t bit_pos; /* next bit to read (0-based across the whole stream) */
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

static size_t deflate_huff_only(const unsigned char *in, size_t in_len, unsigned char *out) {
    z_stream s = {0};
    if (deflateInit2(&s, 6, Z_DEFLATED, -15, 8, Z_HUFFMAN_ONLY) != Z_OK) return 0;
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

static void probe(const char *label, const unsigned char *in, size_t in_len) {
    unsigned char out[OUT_CAP];
    size_t out_len = deflate_huff_only(in, in_len, out);

    printf("\n=== %s (in_len=%zu) -> %zu B ===\n", label, in_len, out_len);
    printf("  raw bytes: ");
    for (size_t i = 0; i < out_len; i++) printf("%02x ", out[i]);
    printf("\n");

    BitReader r = { out, out_len, 0 };
    unsigned bfinal = read_bits(&r, 1);
    unsigned btype  = read_bits(&r, 2);
    printf("  BFINAL=%u BTYPE=%u (%s)\n", bfinal, btype,
           btype == 0 ? "STORED" :
           btype == 1 ? "FIXED" :
           btype == 2 ? "DYNAMIC" : "RESERVED");
    if (btype != 2) {
        printf("  (not a dynamic block; skipping tree-of-trees decode)\n");
        return;
    }
    unsigned hlit  = read_bits(&r, 5);  /* # of lit/length codes - 257 */
    unsigned hdist = read_bits(&r, 5);  /* # of distance codes      - 1 */
    unsigned hclen = read_bits(&r, 4);  /* # of code-length codes   - 4 */
    printf("  HLIT=%u (%u lit/len codes)  HDIST=%u (%u dist codes)  HCLEN=%u (%u CL codes)\n",
           hlit, hlit + 257, hdist, hdist + 1, hclen, hclen + 4);

    printf("  CL-code lengths (in bl_order, %u entries):\n", hclen + 4);
    int cl_lens[19] = {0};
    for (unsigned i = 0; i < hclen + 4; i++) {
        unsigned len = read_bits(&r, 3);
        cl_lens[bl_order[i]] = (int)len;
        printf("    bl_order[%2u]=%2d  len=%u\n", i, bl_order[i], len);
    }
    printf("  CL-code lengths (indexed by symbol 0..18):\n   ");
    for (int i = 0; i < 19; i++) printf(" sym%d=%d", i, cl_lens[i]);
    printf("\n");

    printf("  Bit offset after CL-code-lengths: %zu of %zu (%zu bits remain for trees + data)\n",
           r.bit_pos, (size_t)(out_len * 8), (size_t)(out_len * 8) - r.bit_pos);
}

int main(void) {
    printf("zlib version: %s\n", zlibVersion());
    printf("Probe: HUFFMAN_ONLY (Z_HUFFMAN_ONLY, level=6, raw DEFLATE), tiny inputs zlib picks DYNAMIC for.\n");

    {
        unsigned char buf[14];
        memset(buf, 'A', sizeof(buf));
        probe("'A' x 14 (1 distinct lit + EOB)", buf, sizeof(buf));
    }
    {
        unsigned char buf[12];
        memset(buf, 0x00, sizeof(buf));
        probe("NUL x 12", buf, sizeof(buf));
    }
    {
        unsigned char buf[11];
        memset(buf, 0xFF, sizeof(buf));
        probe("0xFF x 11 (9-bit-branch literal)", buf, sizeof(buf));
    }
    {
        unsigned char buf[14];
        for (int i = 0; i < 14; i++) buf[i] = (i & 1) ? 0xFF : 'A';
        probe("alt 'A'/0xFF x 14 (2 distinct lits)", buf, sizeof(buf));
    }
    {
        const unsigned char buf[15] = "ABCABCABCABCABC";
        probe("'ABC' x 5 (3 distinct lits)", buf, sizeof(buf));
    }

    return 0;
}
