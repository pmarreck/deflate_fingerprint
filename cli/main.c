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

#include <stdio.h>
#include <string.h>
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
        "  deflate-fingerprint identify FILE       Attribute DEFLATE streams in FILE\n"
        "  deflate-fingerprint reproduce ID RAW    Encode RAW using fingerprint ID\n"
        "  deflate-fingerprint list                List known fingerprints\n"
        "\n"
        "Options:\n"
        "  -h, --help     Show this help\n"
        "      --about    Print one-line version + platform\n"
        "      --json     JSON output (where applicable)\n"
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

    /* TODO: dispatch on `identify`, `reproduce`, `list`. */
    fprintf(stderr, "deflate-fingerprint: subcommand '%s' not yet implemented\n", cmd);
    return 2;
}
