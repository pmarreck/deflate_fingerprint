# deflate_fingerprint — Goals

## Mission

Identify, with cryptographic precision, **which DEFLATE encoder implementation and parameter set produced a given compressed byte stream**, by reproducing the exact byte stream from the original uncompressed data using a small set of encoder candidates.

The output is a *fingerprint*: a small identifier plus the parameters needed to
reconstruct the original compressed bytes from the original data. When no
finite parameter set reproduces a stream exactly, the output may also include a
compact DEFLATE-aware correction stream over token/block/Huffman decisions.

## Why this matters

DEFLATE (RFC 1951) defines decoding exactly, but leaves encoding largely free. Different encoders, and even the same encoder at different "levels," produce different bytes for the same input. This under-specification is responsible for a class of problems across multiple domains:

### 1. Byte-identical archive round-tripping (Mecha Archiver's use case)

DEFLATE-bearing formats (`.docx`, `.xlsx`, `.pptx`, `.epub`, `.jar`, `.apk`, `.ipa`, `.whl`, `.xpi`, `.odt`, `.ods`, `.odp`, `.cbz`, plain `.zip`, `.pages`, `.numbers`, `.key`, `.pdf`, `.png`, gzip, and similar containers) are often NON-byte-identical when decompressed and recompressed by a different DEFLATE implementation. This is a known limitation in any archiver that does container-aware compression.

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
- A **correction model** for near-matches: encode residuals at the DEFLATE
  decision layer (LZ77 tokens, block splits, block types, Huffman tree choices,
  flush/finish markers), not as a naive byte diff after bit packing.
- A **per-stream economics rule**: store recompressed raw data plus
  fingerprint/config/correction only when that representation is smaller than
  storing the original DEFLATE blob.
- A **CLI** (Unix conventions per Mecha's standards) for end-users and forensics workflows: identify-encoder, reproduce-stream, list-known-fingerprints, etc.
- A **Zig library** (`deflate_fingerprint` module + C FFI) for downstream consumers (Mecha Archiver, forensics tools, build-reproducibility checkers).
- **Format adapters for testing/corpus extraction**: ZIP-family/OOXML/EPUB/iWork/PDF/PNG/gzip walkers that extract embedded RFC 1951 streams and enough adjacent metadata to validate byte-exact round-tripping. The core encoder remains DEFLATE-focused, but the project must prove coverage against real container formats.
- **ZIP-container family coverage**: `.zip`, `.jar`, `.war`, `.ear`, `.apk`, `.ipa`, `.whl`, `.xpi`, `.crx`, `.vsix`, `.docx`, `.xlsx`, `.pptx`, `.odt`, `.ods`, `.odp`, `.epub`, `.cbz`, and any other format whose payload is a ZIP archive with method=8 entries should flow through the same generic ZIP entry walker before format-specific metadata is considered.
- **Test corpus**: 1000+ real-world DEFLATE streams (`.docx`, `.xlsx`, `.pptx`, `.pages`, `.numbers`, `.key`, `.epub`, `.pdf`, `.png` IDAT, `.jar`, `.apk`, `.whl`, `.zip`, `.gz`, etc.) collected from the wild or generated from known implementations, with known-or-suspected encoder provenance, used as ground truth.
- **Development-only producer oracles**: use `flake.nix`/platform SDKs to obtain zlib, libdeflate, 7-Zip, miniz, Go `compress/flate`, .NET DeflateStream, Java `java.util.zip`, Apple/CoreFoundation, and other available encoders so their outputs can be generated reproducibly for fingerprint tests. These tools may be dev/test dependencies without becoming runtime dependencies.

## Scope boundaries

- Proprietary or platform encoders are in scope when their outputs can be obtained legally and reproducibly for testing, for example Apple/CoreFoundation on macOS. We do not need to ship those encoders; we need to reproduce their RFC 1951 output.
- DEFLATE *variants* outside RFC 1951 (e.g. raw zlib stream with `Z_HUFFMAN_ONLY` is in scope; DEFLATE64 / DEFLATE-Stream from 7-Zip is a separate format, possibly out of scope or v2.0).
- Other compression algorithms (LZMA, bzip2, brotli, zstd) — separate projects if pursued.
- Container bytes, wrappers, PNG filters, PDF object syntax, ZIP central directories, and iWork/OOXML/package structure are not the core encoder's responsibility. They are still in scope for corpus extraction and bit-exact integration tests so upstream tools such as blar can round-trip whole files.
- Byte-level diffs of packed DEFLATE output are not the preferred correction
  representation. They may still apply to wrappers/containers or already
  realigned payloads, but the core DEFLATE residual should be token/event
  aware to avoid bit-shift cascade bloat.

## Success criteria

### v0.1 (minimal viable)
- Reproduce zlib output bit-exact for **levels 1–9 × strategies {DEFAULT, FILTERED, HUFFMAN_ONLY, RLE, FIXED}** = 45 combos.
- ≥70% hit rate on a 1000-file corpus of real-world ZIP-based documents.
- Library, CLI, basic tests, Garnix-green CI, MIT-licensed.

### v0.2
- Add **libdeflate levels 1–12**.
- Add **7-Zip DEFLATE** (5 levels, multiple memLevels).
- Add initial PNG IDAT, PDF FlateDecode, and iWork/Office corpus extraction probes.
- ≥85% hit rate on the corpus.
- Forensics CLI workflow polished (`deflate-fingerprint identify FILE` → human-readable encoder report).

### v0.3
- Add **miniz**, **Go's `compress/flate`**, **Apple's CoreFoundation DEFLATE** (or our reverse-engineered equivalent), **.NET DeflateStream**, and Java `java.util.zip` version checks.
- Expand corpus coverage across Office variants, macOS/iWork (`.pages`, `.numbers`, `.key`), EPUB, PDF, PNG, gzip, ZIP-container formats (`.zip`, `.jar`, `.war`, `.ear`, `.apk`, `.ipa`, `.whl`, `.xpi`, `.crx`, `.vsix`, `.odt`, `.ods`, `.odp`, `.cbz`), and public files collected from the wild.
- ≥95% hit rate on the corpus.
- Cross-platform validated (Linux + macOS + Windows; library statically linkable).

### v1.0
- Comprehensive encoder coverage including legacy/archival encoders (PKZIP, Info-ZIP, gzip 1.x).
- Stable fingerprint registry format with backwards-compatibility guarantee.
- Integration tested with Mecha Archiver/blar as the byte-identity backstop for major DEFLATE-bearing formats, including ZIP-family files, PNG, PDF, gzip, and iWork/Office documents.
- Forensics community feedback / case studies.

## Non-goals

- **Not a general-purpose DEFLATE encoder.** We don't compete with zlib or libdeflate on output quality or speed; our DEFLATE encoder is parameterized to mimic *other* encoders, not to be the "best" choice for fresh compression.
- **Not a Mecha LLC commercial product.** Stays fully open (MIT), like BLIP, mini_blar, and difz. The commercial value is captured downstream by Mecha Archiver as a library consumer; the foundational tool benefits the broader ecosystem.
- **Not version-specific to one fingerprint database.** The fingerprint registry must be a forward-compatible append-only namespace.

## Audiences

| Audience | What they get |
|---|---|
| **Mecha Archiver** (commercial product) | Library that closes the byte-identity gap for DEFLATE-bearing formats during round-trip |
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
