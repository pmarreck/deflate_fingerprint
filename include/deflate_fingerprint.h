/*
 * deflate_fingerprint — public C FFI header.
 *
 * Identify which DEFLATE encoder implementation produced a given compressed
 * byte stream by reproducing the exact byte stream from the original
 * uncompressed data.
 *
 * See DESIGN.md for the architectural intent and GOALS.md for the mission.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef DEFLATE_FINGERPRINT_H
#define DEFLATE_FINGERPRINT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Confidence tiers ─────────────────────────────────────────────────── */

#define DFP_CONFIDENCE_BYTE_EXACT  0  /* encoder reproduced target exactly  */
#define DFP_CONFIDENCE_NEAR_MATCH  1  /* best candidate diverged by N bytes */

/* ── Identification result ────────────────────────────────────────────── */

typedef struct {
    uint16_t fingerprint_id;   /* 0 = no match in registry          */
    uint8_t  confidence;       /* DFP_CONFIDENCE_*                  */
    uint8_t  _pad;             /* reserved; always 0                */
    size_t   residual_bytes;   /* 0 iff confidence == BYTE_EXACT    */
} dfp_result_t;

/* ── Public API ───────────────────────────────────────────────────────── */

/**
 * Return the library version as a NUL-terminated string (e.g. "0.1.0").
 * Pointer is statically allocated; do not free.
 */
const char *dfp_version(void);

/**
 * Identify which encoder (in the fingerprint registry) produced the
 * `target` compressed stream from the `raw` uncompressed source.
 *
 * Returns 0 on success; `*out` is populated with the result.
 * Returns a negative error code on failure.
 *
 * If no fingerprint matches, `out->fingerprint_id == 0`.
 */
int32_t dfp_identify(
    const uint8_t *raw, size_t raw_len,
    const uint8_t *target, size_t target_len,
    dfp_result_t *out
);

/**
 * Encode `raw` using the encoder parameterized by `fingerprint_id`.
 * On success, `*out_buf` points to a heap-allocated buffer of size
 * `*out_len`. The caller must free it via `dfp_free`.
 *
 * Returns 0 on success; negative on error (e.g. unknown fingerprint_id).
 */
int32_t dfp_encode(
    const uint8_t *raw, size_t raw_len,
    uint16_t fingerprint_id,
    uint8_t **out_buf, size_t *out_len
);

/**
 * Free a buffer returned by `dfp_encode`.
 */
void dfp_free(uint8_t *buf, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* DEFLATE_FINGERPRINT_H */
