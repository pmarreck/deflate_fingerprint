# deflate_fingerprint — Design

## Architectural premise

**One Zig DEFLATE encoder, parameterized to reproduce the byte-exact output of each target encoder.** No external runtime dependencies on zlib / libdeflate / 7-Zip / etc. — those exist as references for behavior, not as runtime dependencies.

This is the critical design decision. Bundling external encoder libraries at runtime would force us to ship multiple language runtimes (zlib, libdeflate, Go's runtime for compress/flate, .NET for DeflateStream, Java for java.util.zip, etc.) and pin every version drift. By writing our own Zig DEFLATE encoder with switchable behavior, we get:

- One binary, no external runtime deps
- Full audit trail in a single readable codebase
- Deterministic forward-compat — we control what bytes our encoder produces, forever
- Forensically reproducible — anyone can read the Zig source and verify a fingerprint
- Statically linkable; cross-platform without architecture-specific quirks

## Coverage prioritization: open source first

Open-source encoders are the v0.1–v0.2 priority because their algorithms are
public, the source can be read in full, and ground-truth byte streams can be
generated on demand from the reference implementation at test time. That
makes fingerprinting tractable as a normal software task: encode the same
input through both the reference and our parameterized encoder, diff, iterate
until byte-equal.

Closed or proprietary encoders (Apple CoreFoundation DEFLATE, .NET
pre-Brotli-era DeflateStream, undocumented legacy PKZIP variants) require
empirical reverse-engineering — generating outputs, inferring algorithmic
choices, sometimes disassembling. Those slip to v0.3+, after the open-source
coverage establishes baseline fidelity and the tooling has matured.

Order of attack within v0.1–v0.2: zlib → libdeflate → 7-Zip → miniz → Go
`compress/flate`. All five are fully open, with active maintainers and
readable source.
## High-level algorithm

```
Inputs:
  raw_bytes:     []u8  — the uncompressed source
  target_bytes:  []u8  — a DEFLATE stream we want to attribute

For each candidate fingerprint F in the registry, in order of prior probability:
  1. Configure the parameterized encoder with F's settings.
  2. Stream-encode raw_bytes, emitting one DEFLATE block at a time.
  3. After each emitted byte, compare to target_bytes at the same offset.
  4. If mismatch: abort F, advance to the next candidate.
  5. If full encode matches target_bytes byte-for-byte: F is the fingerprint.

If no candidate matches: emit "unknown encoder" + a difz patch (if requested
by caller) capturing the residual difference between the best near-match and
the target.
```

### Why early bailout is the whole performance story

Most candidates diverge from the target within the first DEFLATE block (~16-32 bytes), because the choice of block-type / block-boundary / first-Huffman-tree-shape is highly encoder-specific. So 90%+ of candidates are rejected in tens of nanoseconds per stream — far less than a full encode. Average per-stream cost ≈ one "real" encode (the winner) plus thousands of trivial early-bailouts.

### Why ordering by prior probability matters

If the corpus is dominated by Microsoft Office documents, zlib-level-6-DEFAULT_STRATEGY is the most-likely first match. Ordering candidates by descending in-the-wild prevalence cuts average detection cost by an order of magnitude in practice.

## What "DEFLATE encoder freedom" actually means

The DEFLATE spec leaves these encoder choices free; they cascade deterministically from a small handful of high-level parameters:

| Choice | Determined by |
|---|---|
| Block boundary placement | Encoder's heuristic: input-length-driven, entropy-driven, fixed-size, or "until benefit threshold." Each encoder picks differently. |
| Block type (stored / fixed Huffman / dynamic Huffman) | Cost model: encoder estimates cost of each type, picks cheapest. The exact cost function varies. |
| Match search depth / strategy | (level, strategy, memLevel) tuple in zlib-family encoders. Determines how far back to look for matches, how many candidates to evaluate, when to give up. |
| Lazy matching | Whether to defer accepting a match to see if the next byte starts a better one. Threshold differs across encoders. |
| Match-length tie-breaking | When two matches are tied for length, which to prefer (closer? further? first-found?). Encoder-specific. |
| Huffman tree construction (for dynamic blocks) | Multiple valid Huffman trees encode the same symbol frequencies. Encoders use slightly different tree-building algorithms (canonical Huffman with various tie-breakers). |
| Empty-block / final-block-flag handling | Minor but observable. |
| Pre-deflate filtering (PNG-specific: row filters) | Out of DEFLATE's scope but observable when fingerprinting PNG IDAT chunks. |

Most of these cascade from `(encoder_id, level, strategy, memLevel, window_bits)`. Once you fix that tuple, the encoder is deterministic.

## Fingerprint registry

A versioned, human-readable, append-only namespace. Each entry:

```
fingerprint_id: u16          # 1-65535, assigned at registration
encoder_family: enum {       # The encoder's lineage
    zlib,
    libdeflate,
    sevenzip_deflate,
    miniz,
    go_compress_flate,
    apple_cf_deflate,
    dotnet_deflate_stream,
    java_util_zip,
    pkzip_legacy,
    info_zip,
    gzip_command,
    custom,
}
version_range: [start, end]  # Encoder version range over which this entry is valid
level: u8                    # 1-12 (encoder-dependent meaning)
strategy: enum { ... }       # zlib's 5; libdeflate's; etc.
memLevel: u8                 # 1-9 (zlib-family); 0 = N/A
window_bits: u8              # 8-15; or 0 = default
description: []u8            # Human-readable: "zlib 1.2.11 level=6 DEFAULT_STRATEGY"
prior_probability: f32       # Empirical prior (corpus-derived)
```

Registry is a versioned data file shipped with the library. Adding a new fingerprint = appending an entry. Removing a fingerprint = marking deprecated, never removing the ID (forward-compat).

## Output formats

### Identification mode (CLI: `deflate-fingerprint identify FILE`)

Human-readable report:

```
File: archive.docx
Found 18 DEFLATE streams (one per ZIP entry).

Stream 1 ([Content_Types].xml, 412 bytes deflated):
  Fingerprint: #0042 — zlib 1.2.x level=6 DEFAULT_STRATEGY
  Confidence: byte-exact match
  Prior probability: 0.31

Stream 2 (word/document.xml, 1893 bytes deflated):
  Fingerprint: #0042 — zlib 1.2.x level=6 DEFAULT_STRATEGY
  Confidence: byte-exact match

...

Aggregate: 18/18 streams attributed to zlib 1.2.x level=6 DEFAULT_STRATEGY.
Most likely producer: Microsoft Office or LibreOffice (both use zlib internally).
```

### Library mode (Zig API)

```zig
const dfp = @import("deflate_fingerprint");

const result = try dfp.identify(allocator, raw_bytes, target_bytes, .{});
// result.fingerprint_id != 0 if matched; ==0 means unknown
// result.confidence: .byte_exact, .near_match (with residual diff bytes)

// To reproduce the target:
const reproduced = try dfp.encode(allocator, raw_bytes, result.fingerprint_id);
std.debug.assert(std.mem.eql(u8, reproduced, target_bytes));
```

### C FFI (for non-Zig consumers including Mecha Archiver)

```c
typedef struct {
    uint16_t fingerprint_id;  // 0 = no match
    uint8_t  confidence;      // 0 = byte_exact, 1 = near_match
    size_t   residual_bytes;  // non-zero iff confidence != byte_exact
} dfp_result_t;

int32_t dfp_identify(
    const uint8_t *raw, size_t raw_len,
    const uint8_t *target, size_t target_len,
    dfp_result_t *out
);

int32_t dfp_encode(
    const uint8_t *raw, size_t raw_len,
    uint16_t fingerprint_id,
    uint8_t **out_buf, size_t *out_len
);

void dfp_free(uint8_t *buf, size_t len);
```

## Module breakdown

```
src/
  lib.zig                  -- C FFI surface (export fn dfp_*)
  encoder.zig              -- Parameterized DEFLATE encoder core
  encoder_zlib.zig         -- zlib-quirks behavior tables (level/strategy/memLevel matrix)
  encoder_libdeflate.zig   -- libdeflate-quirks behavior tables
  encoder_sevenzip.zig     -- 7-Zip DEFLATE behavior tables
  encoder_miniz.zig        -- miniz behavior tables
  encoder_go_flate.zig     -- Go compress/flate behavior tables
  encoder_apple_cf.zig     -- Apple CoreFoundation DEFLATE (if tractable)
  encoder_dotnet.zig       -- .NET DeflateStream behavior tables
  encoder_java.zig         -- java.util.zip behavior tables (mostly zlib-derived)
  encoder_legacy.zig       -- PKZIP, Info-ZIP, gzip 1.x legacy behaviors
  registry.zig             -- Fingerprint registry (versioned, embedded data file)
  identify.zig             -- Detection algorithm with early bailout
  bitstream.zig            -- DEFLATE bit-level writer (shared across encoder variants)
  huffman.zig              -- Canonical Huffman tree construction (parameterized)
  match.zig                -- LZ77 match finding (parameterized: hash chain depth, lazy, etc.)
  blocks.zig               -- Block boundary heuristics (parameterized)
include/
  deflate_fingerprint.h    -- Public C header
cli/
  main.c                   -- CLI entry point (calls through FFI)
tests/
  unit/                    -- Zig unit tests
  integration/             -- CLI integration tests (bash)
  corpus/                  -- Real-world DEFLATE streams + expected fingerprints
```

## Testing strategy

### Per-encoder fidelity tests

For each (encoder_family, version, level, strategy, memLevel) we claim to support:
- Generate a small corpus of inputs (random, structured, edge cases).
- Encode using the real reference encoder (zlib, libdeflate, etc.) — at *test* time, not runtime.
- Encode using our parameterized encoder with the matching fingerprint.
- Assert byte-equality.

This test suite ships with the project. CI runs it on every commit.

### Corpus regression tests

Maintain `tests/corpus/` with hundreds of real-world DEFLATE streams from various sources, each labeled with its expected fingerprint. CI verifies that our identifier correctly attributes each.

### Round-trip tests

For each fingerprint: take raw bytes, encode via fingerprint, identify the result — should round-trip to the same fingerprint.

### Fuzzing

Property-based fuzz: random input bytes + random fingerprint → encode → decode (using std.compress.flate) → assert decode matches input. Catches DEFLATE-spec violations in our encoder.

## Performance considerations

- **Detection cost**: dominated by the "winning" encode pass. Aim for the winning encoder to run at roughly the speed of the reference encoder (zlib level 6 is ~50-100 MB/s; we should be within 2x).
- **Memory**: per-stream, bounded by window size (32 KB) + match-finder hash tables (typically 32-128 KB). Cheap.
- **Streaming**: support stream-mode detection where the target arrives in chunks (for large files, ZIP streaming, etc.).

## Failure modes and graceful degradation

- **No fingerprint matches**: emit `fingerprint_id = 0`. Caller (e.g. Mecha Archiver) falls back to "store raw" or content-identical-with-disclosure.
- **Multiple fingerprints match** (theoretically possible but rare): emit the highest-prior-probability match. Future versions could surface ambiguity.
- **Partial match** (most of the stream matches one fingerprint, but a few bytes diverge): emit `confidence = near_match` + residual diff. Caller can decide whether to combine with [difz](https://github.com/pmarreck/difz) for a final byte-exact reconstruction.

## Cross-product integration

### Mecha Archiver

`deflate_fingerprint` is the byte-identity backstop for ZIP-based formats. Workflow on archive-create:

1. blar's codec expands a `.docx` / `.xlsx` / `.epub` / `.zip` etc. — gets the inner entries.
2. For each inner entry's original DEFLATE bytes, call `dfp_identify(raw, target)`.
3. If matched: store `fingerprint_id` (1-2 bytes) + raw inner content. Recompression on extract uses our parameterized encoder with that fingerprint → byte-identical inner ZIP entries → byte-identical outer `.docx`.
4. If unmatched: fall back to difz patch, or content-identical-with-disclosure.

This makes Mecha Archiver's "byte-identical roundtrip for ZIP-based formats" claim cryptographically credible.

### Forensics CLI workflow

`deflate-fingerprint identify suspicious.docx` produces an evidence-grade report attributing each inner DEFLATE stream to a known encoder. Use cases:

- "This `.docx` was produced by Microsoft Word, not LibreOffice" (or vice versa)
- "This `.jar` was repacked by an unusual tool inconsistent with the claimed build environment"
- "This `.epub` shows a mix of encoders, suggesting post-publication modification"

## Open design questions (for the next LLM to investigate)

1. **Encoder version sensitivity within a family.** Does zlib 1.2.11 vs 1.2.13 produce different bytes for the same `(level, strategy, memLevel, input)`? Empirical question; needs corpus testing. If yes, registry grows by ~5-10x.

2. **Apple's CoreFoundation DEFLATE.** Is it zlib-derived (and thus already covered by the zlib fingerprints) or does it have distinct behavior? Reverse-engineer by encoding the same input via Apple's CF and comparing to zlib variants.

3. **.NET DeflateStream version drift.** .NET Framework vs .NET Core vs .NET 5+ — different DEFLATE implementations? Pre-2018 versions were known to be slow and produce poor output; modern versions delegate to a Brotli-team-maintained library. Multiple fingerprint entries likely needed.

4. **Java's java.util.zip.** Confirmed zlib-derived; should be covered by zlib fingerprints. Verify on JDK 8 / 11 / 17 / 21 to confirm no JVM-version drift.

5. **Adversarial inputs / fingerprint forgery.** Could a malicious actor produce a DEFLATE stream that matches multiple fingerprints, or matches a fingerprint other than its true producer? Probably yes (DEFLATE has enough degrees of freedom that crafting tied outputs is feasible). For forensic use, surface this caveat.

6. **PNG IDAT chunks specifically.** PNG's pre-DEFLATE row filter choices interact with what gets fed into DEFLATE. Do we treat the filter choices as part of the fingerprint, or strictly fingerprint the DEFLATE-side only? Probably the latter, with a separate "PNG-side encoder fingerprint" extension if pursued.

7. **gzip header bytes.** gzip's outer envelope (magic, FLG, MTIME, XFL, OS bytes) is not DEFLATE proper, but it's strongly correlated with which encoder produced the gzip stream. Include in the fingerprint? Probably as a *secondary* signal that helps disambiguate when DEFLATE-only attribution is ambiguous.

8. **Registry distribution and updates.** Ships embedded in the library. How do new fingerprint entries propagate to existing deployed instances of Mecha Archiver and forensic tools? Probably a registry-version-string in the library + opt-in update mechanism.

## Naming convention notes

- Public Zig module name: `deflate_fingerprint` (underscored, per Peter's convention)
- CLI command: `deflate-fingerprint` (hyphenated)
- C FFI prefix: `dfp_` (short, two-letter standard for FFI prefixes)
- C header: `deflate_fingerprint.h`
- Static lib: `libdeflate_fingerprint.a`

## Zig version target

- **Pinned at Zig 0.16.0** ("Juicy Main", April 2026) via [`mitchellh/zig-overlay`](https://github.com/mitchellh/zig-overlay) in `flake.nix`.
- The pin insulates the project from nixpkgs jumping to a new Zig version unannounced.
- The current scaffold builds cleanly under 0.16.0.
- Relevant 0.16 idioms already applied in the scaffold:
  - `linkLibrary` / `addCSourceFile` / `addIncludePath` live on `*Build.Module`, not `*Step.Compile`. We configure the module before passing it to `addExecutable` / `addLibrary`.
  - `.link_libc = true` declared on `Module.CreateOptions` rather than imperative `linkLibC()` after creation.
- See `ZIG_RECENT_API_CHANGES.md` (symlinked at repo root) for the comprehensive API reference, including the 0.15→0.16 migration notes.
