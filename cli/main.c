/*
 * deflate_fingerprint CLI — entry point.
 *
 * Conventions (per Mecha LLC standards):
 *   - UTF-8 everywhere
 *   - `-h`/`--help` and `--about` always work
 *   - `-` / `@stdin` / `@stdout` paths accepted where files are expected
 *   - Output about output goes to stderr; structured output goes to stdout
 *   - JSON output option for tabular/structured data
 *
 * This is a stub. The actual subcommand dispatch is TODO.
 *
 * SPDX-License-Identifier: MIT
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include "deflate_fingerprint.h"

#if defined(__aarch64__) || defined(_M_ARM64)
#define DFP_ARCH "aarch64"
#elif defined(__x86_64__) || defined(_M_X64)
#define DFP_ARCH "x86_64"
#else
#define DFP_ARCH "unknown"
#endif

#if defined(__APPLE__)
#define DFP_OS "macos"
#elif defined(__linux__)
#define DFP_OS "linux"
#elif defined(_WIN32)
#define DFP_OS "windows"
#else
#define DFP_OS "unknown"
#endif

static int print_help(void) {
    fputs(
        "deflate-fingerprint — identify which DEFLATE encoder produced a stream\n"
        "\n"
        "Usage:\n"
        "  deflate-fingerprint identify --raw RAW --target TARGET   Attribute the DEFLATE stream\n"
        "                                                            in TARGET assuming RAW is the\n"
        "                                                            uncompressed input\n"
        "  deflate-fingerprint reproduce ID --raw RAW [--out FILE]  Encode RAW with fingerprint ID (TODO)\n"
        "  deflate-fingerprint list                                  List known fingerprints (TODO)\n"
        "\n"
        "Options:\n"
        "  -h, --help     Show this help\n"
        "      --about    Print one-line version + platform\n"
        "      --json     Machine-readable JSON output (for `identify`)\n"
        "\n"
        "Exit codes:\n"
        "  0  byte-exact fingerprint match found\n"
        "  1  internal error (I/O, OOM, etc.)\n"
        "  2  usage error\n"
        "  3  no matching fingerprint in registry\n"
        "\n"
        "See DESIGN.md and GOALS.md for project intent.\n",
        stdout);
    return 0;
}

static int print_about(void) {
    printf("deflate-fingerprint %s (%s-%s)\n",
           dfp_version(), DFP_OS, DFP_ARCH);
    return 0;
}

/* Read an entire file into a heap-allocated buffer. Caller frees `*out_buf`.
 * Returns 0 on success, -1 on I/O error (with a message to stderr). */
static int read_file(const char *path, unsigned char **out_buf, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "deflate-fingerprint: cannot open '%s': %s\n", path, strerror(errno));
        return -1;
    }
    struct stat st;
    if (fstat(fileno(f), &st) != 0) {
        fprintf(stderr, "deflate-fingerprint: fstat('%s'): %s\n", path, strerror(errno));
        fclose(f);
        return -1;
    }
    size_t n = (size_t)st.st_size;
    unsigned char *buf = (unsigned char *)malloc(n == 0 ? 1 : n);
    if (!buf) {
        fprintf(stderr, "deflate-fingerprint: out of memory reading '%s'\n", path);
        fclose(f);
        return -1;
    }
    size_t got = (n > 0) ? fread(buf, 1, n, f) : 0;
    fclose(f);
    if (got != n) {
        fprintf(stderr, "deflate-fingerprint: short read on '%s' (%zu of %zu)\n", path, got, n);
        free(buf);
        return -1;
    }
    *out_buf = buf;
    *out_len = n;
    return 0;
}

static int cmd_identify(int argc, char *argv[]) {
    const char *raw_path = NULL;
    const char *target_path = NULL;
    int json_out = 0;
    for (int i = 2; i < argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "--raw") == 0 && i + 1 < argc) {
            raw_path = argv[++i];
        } else if (strcmp(a, "--target") == 0 && i + 1 < argc) {
            target_path = argv[++i];
        } else if (strcmp(a, "--json") == 0) {
            json_out = 1;
        } else {
            fprintf(stderr, "deflate-fingerprint identify: unknown or incomplete argument '%s'\n", a);
            return 2;
        }
    }
    if (!raw_path || !target_path) {
        fputs("deflate-fingerprint identify: both --raw and --target are required\n", stderr);
        return 2;
    }

    unsigned char *raw = NULL;
    size_t raw_len = 0;
    unsigned char *target = NULL;
    size_t target_len = 0;
    if (read_file(raw_path,    &raw,    &raw_len)    != 0) return 1;
    if (read_file(target_path, &target, &target_len) != 0) { free(raw); return 1; }

    dfp_result_t result;
    memset(&result, 0, sizeof(result));
    int32_t rc = dfp_identify(raw, raw_len, target, target_len, &result);
    free(raw);
    free(target);
    if (rc != 0) {
        fprintf(stderr, "deflate-fingerprint identify: internal error (rc=%d)\n", rc);
        return 1;
    }

    if (json_out) {
        printf("{\"fingerprint_id\":%u,\"confidence\":%u,\"residual_bytes\":%zu}\n",
               (unsigned)result.fingerprint_id, (unsigned)result.confidence,
               result.residual_bytes);
    } else if (result.fingerprint_id == 0) {
        fputs("no matching fingerprint in the registry\n", stdout);
    } else {
        printf("fingerprint #%u — byte-exact match\n", (unsigned)result.fingerprint_id);
    }
    return (result.fingerprint_id == 0) ? 3 : 0;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        return print_help();
    }
    const char *cmd = argv[1];
    if (strcmp(cmd, "-h") == 0 || strcmp(cmd, "--help") == 0) {
        return print_help();
    }
    if (strcmp(cmd, "--about") == 0) {
        return print_about();
    }
    if (strcmp(cmd, "identify") == 0) {
        return cmd_identify(argc, argv);
    }

    fprintf(stderr, "deflate-fingerprint: subcommand '%s' not yet implemented\n", cmd);
    return 2;
}
