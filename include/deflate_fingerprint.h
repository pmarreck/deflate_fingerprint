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

/* ── Explicit reproduction config constants ───────────────────────────── */

#define DFP_TOKENIZATION_SEGMENTED       0
#define DFP_TOKENIZATION_PREFIX_HISTORY  1

#define DFP_FINISH_EMPTY_FIXED_BLOCK     0
#define DFP_FINISH_LAST_DATA_BLOCK       1

#define DFP_PARSE_FAST                   0
#define DFP_PARSE_SLOW                   1

/* ── Identification result ────────────────────────────────────────────── */

typedef struct {
    uint16_t fingerprint_id;   /* 0 = no match in registry          */
    uint8_t  confidence;       /* DFP_CONFIDENCE_*                  */
    uint8_t  _pad;             /* reserved; always 0                */
    size_t   residual_bytes;   /* 0 iff confidence == BYTE_EXACT    */
} dfp_result_t;

/* ── Explicit DEFLATE reproduction config ─────────────────────────────── */

typedef struct {
    size_t raw_offset;
    size_t empty_fixed_blocks_before;
    size_t empty_stored_blocks;
} dfp_flush_event_t;

typedef struct {
    uint32_t max_chain_length;
    uint16_t good_match;
    uint16_t nice_match;
    uint16_t max_lazy_match;
    uint16_t max_match;
    uint8_t  min_match;
    uint8_t  mem_level;
    size_t   final_flush_empty_fixed_blocks_before;
    uint8_t  tokenization_mode;  /* DFP_TOKENIZATION_* */
    uint8_t  finish_mode;        /* DFP_FINISH_*       */
    uint8_t  parse_mode;         /* DFP_PARSE_*        */
    uint8_t  filtered;           /* 0=false, nonzero=true */
    uint8_t  _pad[6];            /* reserved; set to 0 */
    size_t   window_size;
    const dfp_flush_event_t *sync_flushes;
    size_t   sync_flushes_len;
    size_t   final_flush_empty_stored_blocks;
    const size_t *block_token_counts;
    size_t   block_token_counts_len;
    const size_t *empty_fixed_after_block_counts;
    size_t   empty_fixed_after_block_counts_len;
} dfp_deflate_config_t;

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
 * Encode `raw` using an explicit DEFLATE reproduction config instead of a
 * registry fingerprint. Sync flushes are events at raw-byte offsets into
 * `raw`; caller owns the event array and it only needs to remain valid for
 * this call.
 *
 * On success, `*out_buf` points to a heap-allocated buffer of size `*out_len`.
 * The caller must free it via `dfp_free`.
 *
 * Returns 0 on success; -1 on allocation/encoding failure; -3 if `config` is
 * invalid.
 */
int32_t dfp_encode_configured(
    const uint8_t *raw, size_t raw_len,
    const dfp_deflate_config_t *config,
    uint8_t **out_buf, size_t *out_len
);

/**
 * Free a buffer returned by `dfp_encode` or `dfp_encode_configured`.
 */
void dfp_free(uint8_t *buf, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* DEFLATE_FINGERPRINT_H */
