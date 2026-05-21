/*
 * bench/probes/zlib_level0_stored.c
 *
 * Probe zlib at level=0 (Z_NO_COMPRESSION) — characterize the bytes of pure
 * stored-block output. Specifically:
 *
 *   1. Does empty input still emit a header byte?
 *   2. Single-byte input: 1-byte header + LEN + NLEN + data = 6 bytes?
 *   3. 65535-byte input (= max LEN value): 1 block?
 *   4. 65536-byte input: 2 blocks chained?
 *   5. 80 KB random: how many blocks; where do boundaries fall?
 *
 * Build:
 *   nix develop -c cc -Wall -Wextra -O2 \
 *     bench/probes/zlib_level0_stored.c -lz -o /tmp/probe_l0
 *   /tmp/probe_l0
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define OUT_CAP (256 * 1024)

static size_t deflate_l0(const unsigned char *in, size_t in_len, unsigned char *out) {
	z_stream s = {0};
	if (deflateInit2(&s, 0, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
		fprintf(stderr, "deflateInit2 failed\n");
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
		fprintf(stderr, "deflate(Z_FINISH)=%d for in_len=%zu\n", rc, in_len);
		return 0;
	}
	return out_len;
}

/* Walk a raw DEFLATE stream made entirely of stored blocks. Reports each
 * block's BFINAL, BTYPE, LEN, and offset. Returns block count, or -1 on
 * the first block whose BTYPE != 0 (unexpected). Stored blocks in zlib's
 * level-0 output are byte-aligned because each stored block starts with
 * 5-bit padding after the 3-bit header. */
static int walk_stored(const unsigned char *out, size_t out_len) {
	size_t pos = 0;
	int block_idx = 0;
	while (pos < out_len) {
		if (pos + 5 > out_len) {
			printf("    [truncated stored header at offset %zu]\n", pos);
			return -1;
		}
		unsigned char hdr = out[pos];
		int bfinal = hdr & 1;
		int btype = (hdr >> 1) & 3;
		if (btype != 0) {
			printf("    [block %d at offset %zu: BFINAL=%d BTYPE=%d (NOT STORED)]\n",
			       block_idx, pos, bfinal, btype);
			return -1;
		}
		/* Stored block: 1-byte header (BFINAL+BTYPE+5 padding bits) then
		 * 2-byte LEN little-endian + 2-byte NLEN + data. */
		size_t len = (size_t)out[pos + 1] | ((size_t)out[pos + 2] << 8);
		size_t nlen = (size_t)out[pos + 3] | ((size_t)out[pos + 4] << 8);
		int len_check = ((len ^ 0xFFFF) == nlen) ? 1 : 0;
		printf("    block %d @ offset %zu: BFINAL=%d BTYPE=00 LEN=%zu NLEN=0x%04zX %s\n",
		       block_idx, pos, bfinal, len, nlen, len_check ? "(LEN^NLEN ok)" : "(LEN/NLEN MISMATCH)");
		pos += 5 + len;
		block_idx++;
		if (bfinal) break;
	}
	if (pos != out_len) {
		printf("    [walk ended at %zu, output is %zu bytes — leftover %zu B]\n",
		       pos, out_len, out_len - pos);
	}
	return block_idx;
}

static void dump_short_hex(const unsigned char *bytes, size_t n, size_t max_show) {
	size_t show = n < max_show ? n : max_show;
	for (size_t i = 0; i < show; i++) printf("%02x ", bytes[i]);
	if (n > max_show) printf("... (%zu more)", n - max_show);
}

static void probe_case(const char *name, const unsigned char *in, size_t in_len, int show_full) {
	unsigned char out[OUT_CAP];
	size_t out_len = deflate_l0(in, in_len, out);
	printf("=== %s (in_len=%zu) -> %zu B ===\n", name, in_len, out_len);
	if (show_full) {
		printf("    bytes: ");
		dump_short_hex(out, out_len, 32);
		printf("\n");
	}
	int blocks = walk_stored(out, out_len);
	printf("    total blocks: %d\n\n", blocks);
}

int main(void) {
	printf("zlib version: %s\n", zlibVersion());
	printf("Probe: level=0 (Z_NO_COMPRESSION), windowBits=-15, raw DEFLATE\n\n");

	probe_case("empty",           (const unsigned char *)"", 0, 1);
	probe_case("single 'A'",      (const unsigned char *)"A", 1, 1);
	probe_case("'Hello, world!'", (const unsigned char *)"Hello, world!", 13, 1);

	{
		unsigned char buf[16] = { 0xC0,0xC1,0xC2,0xC3,0xC4,0xC5,0xC6,0xC7,0xC8,0xC9,0xCA,0xCB,0xCC,0xCD,0xCE,0xCF };
		probe_case("0xC0..0xCF (16 B)", buf, 16, 1);
	}

	{
		/* Exactly 65535 = max LEN */
		size_t n = 65535;
		unsigned char *in = malloc(n);
		for (size_t i = 0; i < n; i++) in[i] = (unsigned char)(i & 0xFF);
		probe_case("65535 B (max LEN)", in, n, 0);
		free(in);
	}

	{
		/* 65536 = LEN+1, forces 2 blocks */
		size_t n = 65536;
		unsigned char *in = malloc(n);
		for (size_t i = 0; i < n; i++) in[i] = (unsigned char)(i & 0xFF);
		probe_case("65536 B (LEN+1, must split)", in, n, 0);
		free(in);
	}

	{
		/* 80 KB pseudorandom */
		size_t n = 80 * 1024;
		unsigned char *in = malloc(n);
		uint32_t seed = 0xC0FFEE42;
		for (size_t i = 0; i < n; i++) {
			seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
			in[i] = (unsigned char)(seed & 0xFF);
		}
		probe_case("80 KB random", in, n, 0);
		free(in);
	}

	return 0;
}
