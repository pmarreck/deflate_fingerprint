# deflate_fingerprint — Goals

## Mission

Identify, with cryptographic precision, **which DEFLATE encoder implementation and parameter set produced a given compressed byte stream**, by reproducing the exact byte stream from the original uncompressed data using a small set of encoder candidates.

The output is a *fingerprint*: a small (1–2 byte) identifier plus the parameters needed to reconstruct the original compressed bytes from the original data.

## Why this matters

DEFLATE (RFC 1951) defines decoding exactly, but leaves encoding largely free. Different encoders, and even the same encoder at different "levels," produce different bytes for the same input. This under-specification is responsible for a class of problems across multiple domains:

### 1. Byte-identical archive round-tripping (Mecha Archiver's use case)

ZIP-based formats (`.docx`, `.xlsx`, `.pptx`, `.epub`, `.jar`, `.odt`, plain `.zip`) are universally NON-byte-identical when decompressed and recompressed by a different DEFLATE implementation. This is a known limitation in any archiver that does container-aware compression.

`deflate_fingerprint` solves this by recovering the original encoder fingerprint, allowing reconstruction of byte-identical output even though the *content* was decomposed and recompressed.

### 2. Digital forensics

Identifying which software produced a particular ZIP / `.docx` / PNG / gzip artifact is a recurring need in digital forensics: incident response, evidence chain-of-custody, malware-tool attribution. The forensics community has dabbled in this informally; no comprehensive open implementation exists. `deflate_fingerprint` aims to fill that gap.

### 3. Build-reproducibility audits

When a binary artifact's provenance is in question ("did this `.whl` / `.jar` / `.deb` come from the toolchain we claim?"), being able to fingerprint embedded DEFLATE streams against expected encoders provides cryptographic evidence.

### 4. Format archaeology

Legacy archives from defunct tools may be hard to attribute. Encoder fingerprinting can identify "this `.zip` was made by PKZIP 2.04g in 1993" by matching against a registry of historical encoders.

### 5. Compressed-data deduplication

Two `.docx` files with identical content but different DEFLATE encoders deduplicate poorly as raw bytes. Fingerprint-aware dedup ("same content, fingerprint X" vs. "same content, fingerprint Y") improves storage efficiency.

## In scope

- A **single Zig codebase** that implements DEFLATE encoding parameterized to match the byte-exact output of each target encoder.
- A **fingerprint registry**: a versioned, human-readable list of (encoder family, version range, level, strategy, memLevel, ...) tuples that the encoder can reproduce.
- A **detection algorithm**: given an uncompressed input + a target compressed stream, find which fingerprint (if any) reproduces the target bytes exactly. Stream-compare with early bailout to keep the per-candidate cost low.
- A **CLI** (Unix conventions per Mecha's standards) for end-users and forensics workflows: identify-encoder, reproduce-stream, list-known-fingerprints, etc.
- A **Zig library** (`deflate_fingerprint` module + C FFI) for downstream consumers (Mecha Archiver, forensics tools, build-reproducibility checkers).
- **Test corpus**: 1000+ real-world DEFLATE streams (`.docx`, `.xlsx`, `.epub`, `.zip`, `.gz`, PNG IDAT, etc.) collected from the wild, with known-or-suspected encoder provenance, used as ground truth.

## Out of scope (initially)

- Reverse-engineering proprietary or in-house encoders whose source is not available. Coverage targets are publicly-documented or open-source encoders only. (Apple's CoreFoundation DEFLATE may be tractable if it's truly zlib-derived; investigate.)
- DEFLATE *variants* outside RFC 1951 (e.g. raw zlib stream with `Z_HUFFMAN_ONLY` is in scope; DEFLATE64 / DEFLATE-Stream from 7-Zip is a separate format, possibly out of scope or v2.0).
- Other compression algorithms (LZMA, bzip2, brotli, zstd) — separate projects if pursued.

## Success criteria

### v0.1 (minimal viable)
- Reproduce zlib output bit-exact for **levels 1–9 × strategies {DEFAULT, FILTERED, HUFFMAN_ONLY, RLE, FIXED}** = 45 combos.
- ≥70% hit rate on a 1000-file corpus of real-world ZIP-based documents.
- Library, CLI, basic tests, Garnix-green CI, MIT-licensed.

### v0.2
- Add **libdeflate levels 1–12**.
- Add **7-Zip DEFLATE** (5 levels, multiple memLevels).
- ≥85% hit rate on the corpus.
- Forensics CLI workflow polished (`deflate-fingerprint identify FILE` → human-readable encoder report).

### v0.3
- Add **miniz**, **Go's `compress/flate`**, **Apple's CoreFoundation DEFLATE** (or our reverse-engineered equivalent), **.NET DeflateStream**.
- ≥95% hit rate on the corpus.
- Cross-platform validated (Linux + macOS + Windows; library statically linkable).

### v1.0
- Comprehensive encoder coverage including legacy/archival encoders (PKZIP, Info-ZIP, gzip 1.x).
- Stable fingerprint registry format with backwards-compatibility guarantee.
- Integration tested with Mecha Archiver as the byte-identity backstop for ZIP-based formats.
- Forensics community feedback / case studies.

## Non-goals

- **Not a general-purpose DEFLATE encoder.** We don't compete with zlib or libdeflate on output quality or speed; our DEFLATE encoder is parameterized to mimic *other* encoders, not to be the "best" choice for fresh compression.
- **Not a Mecha LLC commercial product.** Stays fully open (MIT), like BLIP, mini_blar, and difz. The commercial value is captured downstream by Mecha Archiver as a library consumer; the foundational tool benefits the broader ecosystem.
- **Not a DEFLATE decoder.** Use zlib / libdeflate / std.compress.flate for decoding; we only encode (to match a target).
- **Not version-specific to one fingerprint database.** The fingerprint registry must be a forward-compatible append-only namespace.

## Audiences

| Audience | What they get |
|---|---|
| **Mecha Archiver** (commercial product) | Library that closes the byte-identity gap for ZIP-based formats during round-trip |
| **Digital forensics community** | CLI tool that identifies which software produced an artifact |
| **Build reproducibility researchers** | Cryptographic provenance for DEFLATE-containing artifacts (`.whl`, `.jar`, `.deb`, `.apk`, etc.) |
| **Format archaeologists / archivists** | Tool for attributing legacy archives to historical software |
| **Storage/dedup researchers** | Hint for improving dedup ratios on heterogeneously-compressed corpora |

## License philosophy

**MIT, fully open**, like BLIP, mini_blar, and difz. Foundational infrastructure; the commercial moat is downstream (Mecha Archiver consumes this as a library). Keeping it fully open serves:

- OSS-contributor flywheel — forensics-tool authors send PRs adding encoder coverage Peter would never have known about
- Academic citability and adoption
- Build-trust signal for the security/forensics communities
- Non-Mecha users benefit independently, growing the ecosystem
