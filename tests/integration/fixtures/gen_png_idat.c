/*
 * Generate a tiny PNG-like fixture with one zlib-wrapped IDAT stream.
 * The PNG CRC fields are zero because deflate_fingerprint's PNG probe only
 * needs deterministic chunk walking to reach the embedded DEFLATE stream.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static void write_be32(FILE *f, uint32_t v) {
    fputc((int)((v >> 24) & 0xff), f);
    fputc((int)((v >> 16) & 0xff), f);
    fputc((int)((v >> 8) & 0xff), f);
    fputc((int)(v & 0xff), f);
}

static void write_chunk(FILE *f, const char type[4], const uint8_t *data, uint32_t len) {
    write_be32(f, len);
    fwrite(type, 1, 4, f);
    if (len != 0) fwrite(data, 1, len, f);
    write_be32(f, 0);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fputs("usage: gen_png_idat <out.png>\n", stderr);
        return 2;
    }

    const uint8_t filtered_pixels[] = {
        0, 1, 2, 3,
        0, 1, 2, 3,
        0, 1, 2, 3,
        0, 1, 2, 3,
    };
    uLongf zcap = compressBound(sizeof(filtered_pixels));
    uint8_t *zbuf = (uint8_t *)malloc(zcap);
    if (!zbuf) return 1;
    if (compress2(zbuf, &zcap, filtered_pixels, sizeof(filtered_pixels), 6) != Z_OK) {
        free(zbuf);
        return 1;
    }

    FILE *f = fopen(argv[1], "wb");
    if (!f) {
        free(zbuf);
        return 1;
    }

    static const uint8_t sig[] = { 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
    fwrite(sig, 1, sizeof(sig), f);
    const uint8_t ihdr[] = {
        0, 0, 0, 4,
        0, 0, 0, 4,
        8, 0, 0, 0, 0,
    };
    write_chunk(f, "IHDR", ihdr, sizeof(ihdr));
    write_chunk(f, "IDAT", zbuf, (uint32_t)zcap);
    write_chunk(f, "IEND", NULL, 0);
    fclose(f);
    free(zbuf);
    return 0;
}
