# deflate_fingerprint — Plan

## In Progress

- [x] Initial scaffolding committed; project handed to next LLM for implementation (2026-05-20)
- [x] Pinned to Zig 0.16.0 via mitchellh/zig-overlay; scaffold builds + tests pass under 0.16
- [x] Test harness counts passes correctly (`zig build test --summary all`); fixed scaffold bug where Garnix `checks` were nested at `checks.<sys>.<sys>` and silently skipped; added `pkgs.zlib` to flake devShell + test derivation as test-time oracle (2026-05-21)
- [ ] Initialize git, push to `pmarreck/deflate_fingerprint` GitHub repo (public, MIT, Garnix will auto-evaluate `packages.default` + `checks.{build,test}`)

## v0.1 — Minimal viable (zlib coverage)

- [x] First DEFLATE primitive landed: `encodeFixedHuffmanLiterals` in `src/encoder.zig` — RFC 1951 §3.2.6 fixed-Huffman block with literals only. LSB-first `BitWriter`, 9 byte-exact tests vs real zlib 1.3.2. Note: this is the FIXED branch of the eventual `encodeZlibHuffmanOnly` dispatcher — a partial fingerprint useful for *detection*, not yet sufficient for full HUFFMAN_ONLY reproduction (see ENCODER_NOTES.md for the corrected 3-way model). 2026-05-21
- [x] First COMPLETE fingerprint landed: `encodeZlibStored` for zlib level=0 / Z_NO_COMPRESSION. Handles all input sizes including multi-block chaining past the 65535 B LEN limit. 6 byte-exact tests vs real zlib 1.3.2. Covers `(level=0, strategy=∀, memLevel=∀, windowBits-magnitude=∀)` in one fingerprint. 2026-05-21
- [ ] Wire end-to-end: `src/registry.zig` + `src/identify.zig` + C FFI + CLI surface using `encodeZlibStored` as fingerprint #0001 so we have a working (single-fingerprint) detector. Lays down the architecture; subsequent fingerprints just register more entries.
- [ ] Layer zlib-specific HUFFMAN_ONLY dispatch (full 3-way FIXED/DYNAMIC/STORED): requires dynamic Huffman tree construction + bit-length tree + tree-of-trees emission (RFC 1951 §3.2.7). Substantial effort; defer until end-to-end is working.
- [ ] Split into separate `src/bitstream.zig`, `src/huffman.zig`, `src/match.zig`, `src/blocks.zig` modules when a second consumer justifies it (currently all in `src/encoder.zig` to avoid premature abstraction)
- [ ] Implement zlib-quirks behavior tables (`src/encoder_zlib.zig`): 9 levels × 5 strategies, less the collapses we've already discovered (HUFFMAN_ONLY across all (level, memLevel) = 1 fingerprint)
- [ ] Build a per-fingerprint fidelity test suite: at *test* time, encode N inputs with real zlib (via `@cImport`), verify our encoder produces byte-equal output for each fingerprint
- [ ] Implement the detection algorithm (`src/identify.zig`) with early-bailout stream-comparison
- [ ] Implement registry data file format (`src/registry.zig`)
- [ ] C FFI surface (`src/lib.zig` + `include/deflate_fingerprint.h`)
- [ ] C CLI (`cli/main.c`): `identify`, `reproduce`, `list`, `--help`, `--about`
- [ ] Corpus harvest: collect 1000+ real-world `.docx` / `.xlsx` / `.epub` / `.zip` / `.jar` files from public sources; verify ≥70% hit rate
- [ ] Garnix CI green on `packages.default` + `checks.test`
- [ ] Cross-compile for 5 OS/arch combos (Mac aarch64, Linux aarch64/x86_64, Windows aarch64/x86_64)
- [ ] Initial release v0.1.0

## v0.2 — libdeflate + 7-Zip

- [ ] Implement libdeflate-quirks behavior tables (12 levels)
- [ ] Implement 7-Zip DEFLATE behavior tables (5 levels × memLevels)
- [ ] Forensics CLI workflow polish: human-readable encoder report
- [ ] Aggregate confidence scoring (multi-stream attribution: "all 18 streams in this `.docx` match zlib level=6 → likely produced by Microsoft Office or LibreOffice")
- [ ] ≥85% hit rate on the corpus
- [ ] v0.2.0 release

## v0.3 — Coverage expansion

- [ ] miniz behavior tables
- [ ] Go `compress/flate` behavior tables
- [ ] Apple CoreFoundation DEFLATE (or our reverse-engineered equivalent)
- [ ] .NET DeflateStream (multi-version: pre-Brotli-team era and post)
- [ ] java.util.zip verification (likely zlib-derived; confirm on JDK 8/11/17/21)
- [ ] ≥95% hit rate on the corpus
- [ ] v0.3.0 release

## v1.0 — Stable production release

- [ ] Comprehensive legacy encoder coverage (PKZIP, Info-ZIP, gzip 1.x)
- [ ] Stable fingerprint registry format with backwards-compatibility guarantee documented
- [ ] Mecha Archiver integration validated end-to-end as the ZIP-based byte-identity backstop
- [ ] Documentation: API reference, encoder-registry-as-a-resource doc, forensics case studies
- [ ] Hyperfine-tracked performance benchmarks vs reference encoders
- [ ] Cross-product integration test: produce ZIP via Microsoft Office → expand via Mecha Archiver → identify fingerprint → reproduce → byte-identical to original
- [ ] v1.0.0 release

## Open research questions (track here, address as discovered)

- [ ] zlib version drift: does 1.2.11 vs 1.2.13 byte-output differ? Corpus study.
- [ ] Apple CF DEFLATE: zlib-derived or distinct?
- [ ] .NET DeflateStream version coverage strategy
- [ ] Adversarial inputs / fingerprint forgery — security model for forensic use
- [ ] PNG IDAT-specific extension (DEFLATE-level vs filter-level fingerprinting separation)
- [ ] gzip header bytes as secondary attribution signal
- [ ] Registry distribution and update mechanism for deployed library instances

## Cross-product coordination

- [ ] Mecha Archiver (Phase 3a of [Mecha LLC release plan](../mecha_llc_website/docs/MECHA_RELEASE_PLAN.md)) integrates this library as the byte-identity backstop for ZIP-based formats
- [ ] difz integration: when fingerprint detection produces a near-match instead of byte-exact, the residual is captured as a difz patch
- [ ] BLIP/blar maintain their fully-open license posture (MIT/similar); deflate_fingerprint follows suit

## Completed

(none yet — project just scaffolded)
