# deflate_fingerprint — Plan

## In Progress
- [x] Initialize git and push to the public `pmarreck/deflate_fingerprint` GitHub repo (remote tracking `origin/yolo` confirmed 2026-10-14)
- [x] Fix Nix sandbox builds: `checks.test` and `packages.default` fail (prebuilt Zig falls back to musl; CLI `fileno` under strict C11); switch to nixpkgs `zig_0_16` + `_POSIX_C_SOURCE`; also add ruby to dev shell for Info-ZIP fixtures and fix ./test failure-count misparse (done 2026-10-14 16:30 EDT)
- [ ] Owner decision pending (walking id `deflate_fingerprint-zlib-wrapper-representation` r1): keep, factory-ize, or table-ize zlib wrappers (context: docs/plan_context/zlib_wrapper_representation.md)

## Fleet code review triage (2026-06-01)
- [x] WARN: `identify` total-miss returns `confidence=no_match` + `residual_bytes=target.len`; FFI, C header and tests updated (2026-06-01)
- [x] WARN: Exhaustive RFC 1951 §3.2.5 tests for `lengthCode`/`distanceCode` via independent table reconstruction (2026-06-01)
- [x] WARN: bitstream.zig gained 6 tests (bit packing, straddle, flush, mixed-width round-trip) (2026-06-01)
- [x] WARN: match.zig token-stream reconstruction oracle for greedy/lazy tokenizers plus MAX_DIST boundary test (2026-06-01)

## v0.1 — Minimal viable (zlib coverage)

- [ ] Implement the detection algorithm (`src/identify.zig`) with early-bailout stream-comparison
- [ ] Implement registry data file format (`src/registry.zig`)
- [ ] C CLI completion (`cli/main.c`): `reproduce`, `list`, richer reports
- [ ] Corpus harvest: collect 1000+ real-world `.docx` / `.xlsx` / `.pptx` / `.pages` / `.numbers` / `.key` / `.epub` / `.pdf` / `.png` / `.zip` / `.jar` / `.war` / `.ear` / `.apk` / `.ipa` / `.whl` / `.xpi` / `.crx` / `.vsix` / `.odt` / `.ods` / `.odp` / `.cbz` / `.gz` files from public sources; verify ≥70% hit rate
- [ ] Expand `zip-corpus-probe` extension/classification coverage for the full ZIP-container family: JAR/WAR/EAR, APK, IPA, Python wheels, browser extensions, VSIX, OpenDocument, EPUB, CBZ, OOXML, and plain ZIP
- [ ] Add development-only generator oracles via `flake.nix` as needed for libdeflate, 7-Zip, miniz, Go flate, .NET DeflateStream, Java `java.util.zip`, Apple/CoreFoundation, and zlib version drift probes
- [ ] Extend PNG IDAT metadata capture follow-up: optionally validate chunk CRCs and report IDAT chunk-size topology for upstream whole-file restoration tests
- [ ] Add PDF FlateDecode probe: walk PDF object streams/streams with `/FlateDecode`, extract raw DEFLATE payloads, and preserve object-level metadata for byte-exact integration tests
- [ ] Add iWork probe: inspect `.pages` / `.numbers` / `.key` package structure and extract embedded DEFLATE streams for the same fingerprint/config path
- [x] Mechatron Prime CI: manifest, webhook and badge; first build of b40c247 PASSING on `packages.default` + `checks.test` (done 2026-10-14 19:21 EDT)
- [ ] Cross-compile for 5 OS/arch combos (Mac aarch64, Linux aarch64/x86_64, Windows aarch64/x86_64)
- [ ] Initial release v0.1.0

## Corpus / Fingerprint Pipeline

- [ ] Define a source manifest format for corpus streams: source file path/URL, container type, entry/object path, raw length, compressed length, wrapper/container metadata, known producer, and expected reproduction config/fingerprint if known
- [ ] Build generator-oracle fixtures for known encoders before reverse-engineering: zlib versions, libdeflate, 7-Zip, miniz, Go flate, .NET DeflateStream, Java `java.util.zip`, Apple/CoreFoundation, Info-ZIP/PKZIP/gzip where practical
- [ ] For each generator oracle, produce the same seeded input set across all exposed levels/strategies/window/mem settings, then record raw DEFLATE bytes and observed block/flush/token summaries
- [ ] For in-the-wild corpora, extract embedded DEFLATE streams from ZIP-family, PNG, PDF, gzip, iWork, Office, EPUB, APK/JAR/WHL/XPI/VSIX, and public sample files; keep enough surrounding metadata for whole-file round-trip tests
- [ ] Classify every miss mechanically by observed features: block type sequence, memLevel-like token cadence, flush schedule, first token divergence, Huffman header shape, and compressed-size neighborhood
- [ ] Promote a behavior to registry/config only when the project can reproduce the stream byte-exactly from raw input and the config is expressed without producer-specific names in core code
- [ ] Keep near-matches as corpus evidence for future work; do not rely on difz as a substitute for pursuing a real fingerprint unless the stream is genuinely outside the supported model
- [ ] Define the event-level correction stream format: residuals over parsed DEFLATE decisions (LZ77 literals/matches, match-candidate hops, block splits, block types, Huffman tree choices, flush/finish markers), explicitly avoiding raw packed-byte diffs as the primary residual layer
- [ ] Add per-stream storage economics scoring: compare `strong_compress(raw) + fingerprint/config + correction` against storing the original DEFLATE blob, and record the decision in corpus probe reports
- [ ] Define a DFP surrogate container schema, preferably BLIP/BLAR-shaped: raw bytes, reproduction config, optional event correction, optional stored-original fallback, mode, sizes, and hashes
- [ ] Add `pack(deflate) -> dfp-container` and `unpack(dfp-container) -> deflate` tests for exact-config streams, stored-original fallback, and later event-corrected streams
- [ ] Add corpus report dimensions that prior art does not emphasize: attribution confidence, competing candidates, producer/container grouping, correction overhead histograms, exact/corrected/stored-original outcomes, and miss taxonomy

## v0.2 — libdeflate + 7-Zip

- [ ] Implement libdeflate-quirks behavior tables (12 levels)
- [ ] Implement 7-Zip DEFLATE behavior tables (5 levels × memLevels)
- [ ] Land first PNG/PDF/iWork corpus adapters with fixtures and expected reproduction configs
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
- [ ] Expand Office/macOS Office/iWork/EPUB/PDF/PNG/gzip corpus coverage and classify every miss by observed block/flush/token behavior
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
- [ ] Office/OOXML producer variance follow-up: cluster streams by byte-reproduction behavior and record `docProps/app.xml` metadata (`Application`, `AppVersion`) plus ZIP version/subtype fields; do not assume one Excel fingerprint covers all Excel versions/platforms.
- [ ] Excel worksheet follow-up: validate `chain=16 nice=35 insert=4`, memLevel=7, segmented sheetData sync-flush topology across more Excel versions/platforms before promoting it from probe hypothesis to a stable fingerprint.
- [ ] Apple CF DEFLATE: zlib-derived or distinct?
- [ ] .NET DeflateStream version coverage strategy
- [ ] Adversarial inputs / fingerprint forgery — security model for forensic use
- [ ] PNG IDAT-specific coverage: DEFLATE reproduction is required; PNG row filters and IDAT chunking are adapter/upstream metadata, but must be captured in tests for whole-file bit-exact restoration
- [ ] PNG IDAT miss follow-up: model exact row partial-flush semantics for row-sized fixed/dynamic blocks with empty fixed markers; remaining sampled row-like misses have raw block spans equal to PNG filtered scanline sizes (`ceil(width * channels * bit_depth / 8) + 1`). Real zlib L6/default `Z_PARTIAL_FLUSH` per scanline matches block topology but diverges on individual LZ77 choices, so this likely needs either a parser-variant knob or token-level correction.
- [x] Extend candidate-rank diagnostics from all legal raw matches to zlib-style hash-chain-visible candidates; diagnostic now reports both continuous-prefix and row-chunked visibility for PNG row misses (2026-05-26 EDT).
- [x] Close the zlib row-flush state-model gap: row-chunked replay now models zlib's delayed `insert` carry across `Z_PARTIAL_FLUSH`, so both target and real-zlib choices are visible at the remaining PNG row divergences (2026-05-26 EDT).
- [ ] PNG row-partial-flush residual: both remaining target choices are legal and row-visible but lower-ranked than zlib's default lazy-parser choices, so investigate parser-choice knobs or token-level correction rather than more block/flush state.
- [x] PNG IDAT miss follow-up: resolve the single dynamic 59x32 16-bit RGBA stream; exact real-zlib oracle is `windowBits=14`, level 7, memLevel 7, `Z_FILTERED`, now represented as a generic configured candidate. Private 25-PNG sample improved from 88.0% to 92.0% exact (23/25) (2026-05-26 EDT).
- [ ] PDF FlateDecode coverage: distinguish DEFLATE reproduction from PDF object/container reconstruction, but test both enough to support blar integration
- [ ] macOS/iWork coverage: determine whether Pages/Numbers/Keynote use ZIP, protobuf/snappy-like package internals, Apple/CoreFoundation DEFLATE, zlib, or mixed encoders across versions
- [ ] gzip header bytes as secondary attribution signal
- [ ] Registry distribution and update mechanism for deployed library instances
- [ ] Promote probe-only worksheet clusters into stable generic fingerprints only after they are expressed as configurations and validated across multiple producer/version corpora; do not add core functions named after a specific application.

## Cross-product coordination

- [ ] Mecha Archiver (Phase 3a of [Mecha LLC release plan](../mecha_llc_website/docs/MECHA_RELEASE_PLAN.md)) integrates this library as the byte-identity backstop for ZIP-based formats
- [ ] difz integration: after DEFLATE event-level correction is defined, decide where `../difz` fits: wrapper/container residuals, already-realigned payloads, or a generic fallback when event correction is unavailable
- [ ] Evaluate shared encoder-quirk finding names and a validate integration with jpegz (context: docs/plan_context/jpegz_quirk_catalog.md)
- [ ] BLIP/blar maintain their fully-open license posture (MIT/similar); deflate_fingerprint follows suit


