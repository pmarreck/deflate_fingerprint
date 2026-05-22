/*
 * tests/integration/fixtures/gen_zlib_target.c
 *
 * Tiny helper used by integration tests to produce raw-DEFLATE byte streams
 * from a given input file at a specified (level, strategy). Used to feed
 * the identifier with *real* zlib output (not hand-crafted hex).
 *
 * Usage:
 *   gen_zlib_target <input_file> <output_file> <level> <strategy>
 *     level    = 0..9
 *     strategy = default | huffman_only | rle | filtered | fixed
 *
 * Always uses windowBits = -15 (raw DEFLATE, no wrapper), memLevel = 8.
 *
 * SPDX-License-Identifier: MIT
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <zlib.h>

static int read_all(const char *path, unsigned char **out_buf, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "open %s: %s\n", path, strerror(errno)); return -1; }
    struct stat st;
    if (fstat(fileno(f), &st) != 0) { fclose(f); return -1; }
    size_t n = (size_t)st.st_size;
    unsigned char *buf = (unsigned char *)malloc(n == 0 ? 1 : n);
    if (!buf) { fclose(f); return -1; }
    size_t got = (n > 0) ? fread(buf, 1, n, f) : 0;
    fclose(f);
    if (got != n) { free(buf); return -1; }
    *out_buf = buf;
    *out_len = n;
    return 0;
}

static int write_all(const char *path, const unsigned char *buf, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "create %s: %s\n", path, strerror(errno)); return -1; }
    size_t put = fwrite(buf, 1, len, f);
    fclose(f);
    return (put == len) ? 0 : -1;
}

int main(int argc, char *argv[]) {
    if (argc != 5) {
        fputs("usage: gen_zlib_target <input> <output> <level 0-9> <strategy>\n", stderr);
        return 2;
    }
    int level = atoi(argv[3]);
    if (level < 0 || level > 9) { fputs("level out of range\n", stderr); return 2; }
    int strategy = Z_DEFAULT_STRATEGY;
    if      (strcmp(argv[4], "default")      == 0) strategy = Z_DEFAULT_STRATEGY;
    else if (strcmp(argv[4], "huffman_only") == 0) strategy = Z_HUFFMAN_ONLY;
    else if (strcmp(argv[4], "rle")          == 0) strategy = Z_RLE;
    else if (strcmp(argv[4], "filtered")     == 0) strategy = Z_FILTERED;
    else if (strcmp(argv[4], "fixed")        == 0) strategy = Z_FIXED;
    else { fprintf(stderr, "unknown strategy: %s\n", argv[4]); return 2; }

    unsigned char *in = NULL; size_t in_len = 0;
    if (read_all(argv[1], &in, &in_len) != 0) return 1;

    /* Worst-case output size for DEFLATE: input + (input >> 12) + 7 (per zlib).
     * Add slack for safety. */
    size_t cap = in_len + (in_len >> 8) + 64;
    unsigned char *out = (unsigned char *)malloc(cap);
    if (!out) { free(in); return 1; }

    z_stream s; memset(&s, 0, sizeof(s));
    if (deflateInit2(&s, level, Z_DEFLATED, -15, 8, strategy) != Z_OK) {
        fprintf(stderr, "deflateInit2 failed\n"); free(in); free(out); return 1;
    }
    s.next_in = in; s.avail_in = (uInt)in_len;
    s.next_out = out; s.avail_out = (uInt)cap;
    int rc = deflate(&s, Z_FINISH);
    size_t out_len = cap - s.avail_out;
    deflateEnd(&s);
    if (rc != Z_STREAM_END) {
        fprintf(stderr, "deflate(Z_FINISH)=%d\n", rc);
        free(in); free(out); return 1;
    }

    int wr = write_all(argv[2], out, out_len);
    free(in); free(out);
    return wr;
}
