/*
 * Extract the first method=8 local-file payload from a small ZIP archive.
 *
 * This intentionally handles only the ordinary ZIP32 central-directory shape
 * needed by integration tests. Container fidelity belongs elsewhere; this
 * helper just gives tests raw RFC 1951 bytes from a generator-oracle ZIP.
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint16_t le16(const unsigned char *p) {
	return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t le32(const unsigned char *p) {
	return (uint32_t)p[0] |
	       ((uint32_t)p[1] << 8) |
	       ((uint32_t)p[2] << 16) |
	       ((uint32_t)p[3] << 24);
}

static unsigned char *read_all(const char *path, size_t *len) {
	FILE *f = fopen(path, "rb");
	if (!f) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return NULL;
	}
	if (fseek(f, 0, SEEK_END) != 0) {
		fclose(f);
		return NULL;
	}
	long n = ftell(f);
	if (n < 0) {
		fclose(f);
		return NULL;
	}
	if (fseek(f, 0, SEEK_SET) != 0) {
		fclose(f);
		return NULL;
	}
	unsigned char *buf = (unsigned char *)malloc((size_t)n == 0 ? 1 : (size_t)n);
	if (!buf) {
		fclose(f);
		return NULL;
	}
	if (fread(buf, 1, (size_t)n, f) != (size_t)n) {
		free(buf);
		fclose(f);
		return NULL;
	}
	fclose(f);
	*len = (size_t)n;
	return buf;
}

static int write_all(const char *path, const unsigned char *buf, size_t len) {
	FILE *f = fopen(path, "wb");
	if (!f) {
		fprintf(stderr, "create %s: %s\n", path, strerror(errno));
		return -1;
	}
	size_t wrote = fwrite(buf, 1, len, f);
	fclose(f);
	return wrote == len ? 0 : -1;
}

int main(int argc, char **argv) {
	if (argc != 3) {
		fputs("usage: extract_zip_deflate <zip> <out-deflate>\n", stderr);
		return 2;
	}

	size_t len = 0;
	unsigned char *zip = read_all(argv[1], &len);
	if (!zip) return 1;

	size_t eocd = len;
	while (eocd >= 4) {
		eocd--;
		if (zip[eocd] == 0x50 && zip[eocd + 1] == 0x4b && zip[eocd + 2] == 0x05 && zip[eocd + 3] == 0x06) break;
	}
	if (eocd < 4 || eocd + 22 > len) {
		fputs("EOCD not found\n", stderr);
		free(zip);
		return 1;
	}

	uint32_t cd = le32(zip + eocd + 16);
	if (cd + 46 > len || memcmp(zip + cd, "PK\001\002", 4) != 0) {
		fputs("central directory not found\n", stderr);
		free(zip);
		return 1;
	}
	if (le16(zip + cd + 10) != 8) {
		fputs("first entry is not DEFLATE method=8\n", stderr);
		free(zip);
		return 1;
	}

	uint32_t comp_len = le32(zip + cd + 20);
	uint32_t local = le32(zip + cd + 42);
	if (local + 30 > len || memcmp(zip + local, "PK\003\004", 4) != 0) {
		fputs("local header not found\n", stderr);
		free(zip);
		return 1;
	}
	uint16_t name_len = le16(zip + local + 26);
	uint16_t extra_len = le16(zip + local + 28);
	size_t data = (size_t)local + 30 + name_len + extra_len;
	if (data + comp_len > len) {
		fputs("compressed data extends beyond archive\n", stderr);
		free(zip);
		return 1;
	}

	int rc = write_all(argv[2], zip + data, comp_len);
	free(zip);
	return rc == 0 ? 0 : 1;
}
