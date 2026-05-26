# deflate_fingerprint — Plan

## In Progress
- [x] Initial scaffolding committed; project handed to next LLM for implementation (2026-05-20)
- [x] Pinned to Zig 0.16.0 via mitchellh/zig-overlay; scaffold builds + tests pass under 0.16
- [x] Test harness counts passes correctly (`zig build test --summary all`); fixed scaffold bug where Garnix `checks` were nested at `checks.<sys>.<sys>` and silently skipped; added `pkgs.zlib` to flake devShell + test derivation as test-time oracle (2026-05-21)
- [ ] Initialize git, push to `pmarreck/deflate_fingerprint` GitHub repo (public, MIT, Garnix will auto-evaluate `packages.default` + `checks.{build,test}`)

## v0.1 — Minimal viable (zlib coverage)

- [x] First DEFLATE primitive landed: `encodeFixedHuffmanLiterals` in `src/encoder.zig` — RFC 1951 §3.2.6 fixed-Huffman block with literals only. LSB-first `BitWriter`, 9 byte-exact tests vs real zlib 1.3.2. Note: this is the FIXED branch of the eventual `encodeZlibHuffmanOnly` dispatcher — a partial fingerprint useful for *detection*, not yet sufficient for full HUFFMAN_ONLY reproduction (see ENCODER_NOTES.md for the corrected 3-way model). 2026-05-21
- [x] First COMPLETE fingerprint landed: `encodeZlibStored` for zlib level=0 / Z_NO_COMPRESSION. Handles all input sizes including multi-block chaining past the 65535 B LEN limit. 6 byte-exact tests vs real zlib 1.3.2. Covers `(level=0, strategy=∀, memLevel=∀, windowBits-magnitude=∀)` in one fingerprint. 2026-05-21
- [x] Wired end-to-end (yolo @ 285cbbee, 2026-05-21): inline `FINGERPRINTS[]` registry + `identify()`/`encode()` Zig API + `dfp_identify`/`dfp_encode`/`dfp_free` FFI + `deflate-fingerprint identify --raw R --target T [--json]` CLI + 12-test integration suite. Architecture is now load-bearing — new fingerprints just append a row.
- [x] **HUFFMAN_ONLY fingerprint COMPLETE (yolo @ TODO, 2026-05-22):** `encodeZlibHuffmanOnly` does zlib's 3-way FIXED/DYNAMIC/STORED dispatch using the bit-level `(static_len + 3 + 7) >> 3` and `stored_len + 4 <= opt_lenb` formulas from trees.c::_tr_flush_block. Composes `encodeFixedHuffmanLiterals` + new `encodeDynamicHuffmanLiterals` + `encodeZlibStored`. The dynamic encoder is a complete port of zlib's tree builder (depth-aware heap), tree-of-trees emission (RFC §3.2.7), and scan_tree/send_tree RLE. Registered as fingerprint #2; covers `(any level, strategy=HUFFMAN_ONLY, any memLevel, any windowBits magnitude)` for single-block inputs.
- [x] **L1 DYNAMIC dispatch fix (2026-05-22):** `encodeZlibLevel1` was wired to the 2-way `encodeBlockFromTokens` (FIXED/STORED only) as a Phase E leftover from before dynamic-over-tokens existed. L2-L9 already used the 3-way `encodeBlockFromTokensWithDynamic`; switching L1 to match restored byte-exact agreement with real zlib on prose inputs (80B+ where DYNAMIC beats FIXED). Corpus hit rate 35% → 37%; L1 default misses 10 → 0.
- [x] **Z_FIXED strategy fingerprints #12-#20 + L2/L3 max_lazy_match bug fix (2026-05-22):** Added encodeZlibLevel{1..9}Fixed wrappers; LZ77_LEVEL_2/L3 max_lazy_match corrected 0->5 and 0->6 per zlib's configuration_table (same class of bug Peter fixed for L1). Hit rate 37% -> 55%.
- [x] **Z_RLE strategy fingerprint #21 (2026-05-22):** lz77TokenizeRLE limits matches to distance=1, going through standard 3-way Huffman dispatch. L1-L9 collapse to one fingerprint. Hit rate 55% -> 67%.
- [x] **Z_FILTERED strategy fingerprints #22-#27 (2026-05-22):** Added `filtered: bool` to LZ77Params and the deflate_slow `match_length<=5` rejection rule. L1-L3 + Z_FILTERED collapse to default. **v0.1 hit rate goal (≥70%) achieved at 79%.**
- [x] **TOO_FAR rule (2026-05-22):** zlib's deflate_slow rejects length-3 matches with distance > 4096 (folded into the FILTERED reject conditional since zlib shares the path in trees.c). We were accepting them, leading to divergent LZ77 token streams on inputs > ~5KB. Corpus hit rate: 79% → **96%**. All default/fixed/filtered misses eliminated; remaining 18 misses are HUFFMAN_ONLY + RLE on the single corpus file > 16KB (multi-block).
- [x] **Multi-block HUFFMAN_ONLY + RLE (2026-05-22):** Refactored block emitters (`encodeFixedHuffmanLiterals`, `encodeDynamicHuffmanLiterals`, `encodeFixedHuffmanFromTokens`, `encodeDynamicHuffmanFromTokens`, `encodeBlockFromTokensWithDynamic`) to have `emit*Block(bw, ..., bfinal)` variants that take a shared BitWriter; existing public functions are thin wrappers. Added `emitStoredBlock` for byte-aligned STORED chunks within a shared bit stream. HUFFMAN_ONLY splits input at 16383 bytes per chunk with per-chunk 3-way FIXED/DYNAMIC/STORED dispatch; RLE splits at 16383 tokens. **Corpus hit rate: 96% → 100% — all 500 streams identified byte-exact.**
- [x] **Module split (2026-05-22):** Extracted `src/bitstream.zig` (BitWriter + fixed-Huffman emit primitives), `src/huffman.zig` (tree builder + canonical codes + scan/send_tree RLE), `src/match.zig` (Token/Match/LZ77Params + greedy/lazy/RLE tokenizers + longestMatch), `src/blocks.zig` (length/distance code tables + token utilities + emit*Block primitives + 3-way dispatchers). `src/encoder.zig` retained for top-level fingerprint functions only (encodeZlibStored/HuffmanOnly/Level*/Fixed/Filtered/RLE). Size: encoder.zig 2360 → 1027 lines (~56% reduction). All 86 tests still green.
- [ ] Decide whether to keep the current inline zlib registry/encoder functions through v0.1 or promote them into `src/encoder_zlib.zig` behavior tables before release
- [x] **`@cImport(zlib.h)` fidelity harness (2026-05-22):** `src/fidelity.zig` exposes `compressWithZlib(allocator, raw, level, strategy)` and `assertByteExact(allocator, raw, level, strategy, our_encode_fn)`. Tests now declare "encoder X must match zlib L=k strategy=S on input Y" and the harness computes ground truth at test time via @cImport — eliminating brittle embedded hex-byte fixtures. `build.zig` updated to link libC + system zlib for the test target. 10 new fidelity tests (7 direct + 1 sweep covering 10 levels). Suite: 86 → 96 tests passing.
- [x] **Multi-block generalization to default + Z_FIXED + Z_FILTERED (2026-05-22):** Added `encodeMultiBlock3Way` and `encodeMultiBlock2Way` helpers in `blocks.zig`; all `encodeZlibLevel{1..9}` / `*Fixed` / `*Filtered` / `RLE` now route through them. Internal corpus stays at 100%; exposed a separate L1 divergence on 46KB-class inputs (token-stream divergence, NOT multi-block — both ours and zlib emit single block at this size).
- [x] **`tools/zip_corpus_probe.zig` real-world probe (2026-05-22):** Walks a directory of ZIP-format archives (.zip/.docx/.jar/.epub/.odt/.xlsx/.pptx/.apk/...), parses central directories, extracts raw-DEFLATE payloads of every method=8 entry, inflates via libz for ground truth, runs identifier, tallies hits per fingerprint. Runs via `nix develop -c zig build probe -- /path` (not installed by default; needs zlib).
  - **First real-world signal: 70.9% hit rate on ~/Downloads (936 DEFLATE streams across 10 archives).** Fingerprint #4 (L6 default) alone covers 77% of hits — confirms L6 default is the dominant config in the wild. Remaining ~30% misses are mostly an Apple Mac installer (likely Apple's encoder family) plus a few large inputs hitting the L1 divergence.
- [ ] Implement the detection algorithm (`src/identify.zig`) with early-bailout stream-comparison
- [ ] Implement registry data file format (`src/registry.zig`)
- [x] Start pure DEFLATE block-boundary inspector (`src/inspect.zig`) with tested STORED-block range reporting for Excel boundary analysis (2026-05-25 00:00 EDT)
- [x] Extend DEFLATE block-boundary inspector to fixed-Huffman literal/match decoding with semantic compressed-end bit reporting before final padding (2026-05-25 00:08 EDT)
- [x] Extend DEFLATE block-boundary inspector to dynamic-Huffman blocks, including tree-of-trees parsing and LZ77 match range accounting (2026-05-25 00:17 EDT)
- [x] Add `deflate-block-inspect` dev tool and use it on local CPI `.xlsx` sheet2 stream; observed 8,191-token cadence plus explicit empty stored flush blocks (2026-05-25 00:24 EDT)
- [x] Add tested zlib memLevel=7 encoding path for levels 1-3, including hash table sizing and 8,191-symbol block chunks with raw-slice-aware STORED fallback (2026-05-25 00:36 EDT)
- [x] Add OOXML `docProps/app.xml` producer metadata parsing and verbose ZIP-probe reporting for Application/AppVersion clustering (2026-05-25)
- [x] Fix chunked token-only block helpers so cross-block match references reconstruct from the full raw stream before per-block STORED fallback decisions; added regression test and verified CPI `.xlsx` verbose probe no longer crashes (2026-05-25 09:10 EDT)
- [x] Add worksheet-specific Excel candidate encoders and `excel-candidate-probe`; initial CPI candidate (`chain=16 nice=28 insert=4`, memLevel=7, sheetData flushes) matched the prefix block and first 10,529 compressed bytes but was still not byte-exact (2026-05-25 09:45 EDT)
- [x] Add token-level DEFLATE trace inspection and use it to resolve the CPI sheet2 divergence: the first miss was a too-low `nice_match` early exit; segmented `chain=16 nice=35 insert=4`, memLevel=7, with sheetData sync flushes reproduces the CPI worksheet stream byte-exact (2026-05-25 10:35 EDT)
- [x] Add `zip-corpus-probe --excel-experimental` to count unregistered worksheet candidate coverage across OOXML corpora; local `/tmp/dfp_xlsx_probe_dir` result: 6/8 worksheet XML entries exact across three Excel 16 CPI clusters (`nice=35`: sheets 1/2/4, `nice=60`: sheets 3/5, `row1024`: sheet6) (2026-05-25 11:20 EDT)
- [x] Move worksheet/producer-specific reproduction details out of the core encoder path: `src/encoder.zig` now exposes abstract `DeflateReproductionConfig` with generic sync-flush schedules, while Excel/worksheet inference lives in probes/tests (2026-05-25 11:24 EDT)
- [x] Expose explicit config-driven compression through the C FFI via `dfp_encode_configured`, including `FlushEvent` schedules and LZ77/memLevel/tokenization settings (2026-05-25 11:31 EDT)
- [x] Generalize sync-flush topology to per-offset `FlushEvent` counts and add deterministic target-derived `observeFlushSchedule()` extraction; local worksheet probe now captures 7/8 worksheet entries exactly, including Excel 14 sample via observed final-flush-only schedule + L1/mem7 (2026-05-25 12:06 EDT)
- [x] Add core `fingerprintConfigured` API for target-derived generic flush/finish configs and count configured exact hits separately in ZIP corpus probes; private sampled results: xlsx 79.5%, docx 100%, pptx 99.0%, epub 99.4% (2026-05-25 14:20 EDT)
- [x] Add `zip-corpus-probe --max-streams` and `--progress` so mixed private corpora can be bounded and observable; first 200 mixed local DEFLATE streams: 47.5% exact, mostly zlib #4 hits with many non-OOXML misses (2026-05-25 14:35 EDT)
- [x] Add abstract empty-fixed-before-stored flush markers to `FlushEvent` and final flush config; private sampled `.xlsx` exact coverage improved 79.5% -> 83.6%, observed worksheet exacts 31 -> 49, mixed first-200 unchanged at 47.5% (2026-05-25 15:00 EDT)
- [x] Add zlib L6 memLevel=9 fingerprint #29 after empirically finding ZIP-family streams use a 32767-symbol pending buffer while keeping hash behavior capped at 15 bits; mixed first-200 local ZIP-family coverage improved 47.5% -> 97.0% with #29 covering 131/200 streams (2026-05-25 16:10 EDT)
- [x] Add oracle-backed zlib L6 memLevel=6/#31 and memLevel=7/#30 fingerprints for smaller pending-buffer variants; first-200 mixed corpus did not hit them yet, but they are byte-exact against the zlib oracle and keep the registry generic (2026-05-25 16:25 EDT)
- [x] Add generic Info-ZIP-style 4096-symbol profitability flush fingerprint #32 with public generator-oracle integration coverage; mixed first-200 local ZIP-family coverage improved 97.0% -> 100.0% with #32 covering the remaining 6 iOS app payload streams (2026-05-25 17:10 EDT)
- [x] Move ZIP-family extension classification into tested core helper and cover `.war`, `.ear`, `.whl`, `.xpi`, `.crx`, `.vsix`, `.ods`, `.odp`, and `.cbz` in `zip-corpus-probe` discovery (2026-05-25 15:10 EDT)
- [x] Info-ZIP/Apple ZIP family: public generator-oracle test now covers `/nix/store` Info-ZIP `zip -6` output with 4096-symbol profitability flushes and dynamic-then-stored fallback shapes; core fingerprint #32 is producer-agnostic (2026-05-25 17:10 EDT)
- [x] C FFI surface (`src/lib.zig` + `include/deflate_fingerprint.h`) exposes `dfp_identify`, `dfp_encode`, `dfp_free`, and versioning
- [x] C CLI foundation (`cli/main.c`): `identify --raw --target [--json]`, `--help`, `--about`
- [ ] C CLI completion (`cli/main.c`): `reproduce`, `list`, richer reports
- [ ] Corpus harvest: collect 1000+ real-world `.docx` / `.xlsx` / `.pptx` / `.pages` / `.numbers` / `.key` / `.epub` / `.pdf` / `.png` / `.zip` / `.jar` / `.war` / `.ear` / `.apk` / `.ipa` / `.whl` / `.xpi` / `.crx` / `.vsix` / `.odt` / `.ods` / `.odp` / `.cbz` / `.gz` files from public sources; verify ≥70% hit rate
- [ ] Expand `zip-corpus-probe` extension/classification coverage for the full ZIP-container family: JAR/WAR/EAR, APK, IPA, Python wheels, browser extensions, VSIX, OpenDocument, EPUB, CBZ, OOXML, and plain ZIP
- [ ] Add development-only generator oracles via `flake.nix` as needed for libdeflate, 7-Zip, miniz, Go flate, .NET DeflateStream, Java `java.util.zip`, Apple/CoreFoundation, and zlib version drift probes
- [x] Add first PNG IDAT probe: extract concatenated IDAT zlib stream, strip to raw RFC 1951 body, inflate to PNG-filtered bytes, run registry/config identification, and cover with generated PNG integration fixture (2026-05-26 EDT)
- [x] Add sanitized PNG miss-feature aggregation for private corpus runs: classify missed IDAT streams by dynamic/fixed/stored block presence, 4096-token dynamic blocks, and empty marker blocks without reporting private filenames (2026-05-26 EDT)
- [x] Add abstract target-derived block-token-count reproduction configs with explicit LZ77 parse mode and C FFI coverage; private sampled PNG exact coverage improved 76.0% -> 88.0% by closing the 4096-token dynamic cluster and one empty-fixed-finish cluster (2026-05-26 EDT)
- [x] Add explicit per-block type choices and raw-end block plans (segmented and continuous-history) as generic config arrays; manual PNG exception inspection showed remaining row-like misses split exactly at PNG filtered scanline sizes but still need a more exact partial-flush/tokenization model (2026-05-26 EDT)
- [ ] Extend PNG IDAT metadata capture: parse IHDR enough to expose row filter-byte offsets/counts, optionally validate chunk CRCs, and report IDAT chunk-size topology for upstream whole-file restoration tests
- [ ] Add PDF FlateDecode probe: walk PDF object streams/streams with `/FlateDecode`, extract raw DEFLATE payloads, and preserve object-level metadata for byte-exact integration tests
- [ ] Add iWork probe: inspect `.pages` / `.numbers` / `.key` package structure and extract embedded DEFLATE streams for the same fingerprint/config path
- [ ] Garnix CI green on `packages.default` + `checks.test`
- [ ] Fix `checks.test` zlib link path: direct `nix build .#checks.<system>.test` currently cannot find dynamic library `z`, while `./test` passes through the dev shell
- [ ] Cross-compile for 5 OS/arch combos (Mac aarch64, Linux aarch64/x86_64, Windows aarch64/x86_64)
- [ ] Initial release v0.1.0

## Corpus / Fingerprint Pipeline

- [x] Mirror blar's public-vs-local corpus safety model: committed public fixtures, gitignored local/private NAS samples, documented promotion rules, and a tested local sampler with inventory caching (2026-05-25 13:10 EDT)
- [ ] Define a source manifest format for corpus streams: source file path/URL, container type, entry/object path, raw length, compressed length, wrapper/container metadata, known producer, and expected reproduction config/fingerprint if known
- [ ] Build generator-oracle fixtures for known encoders before reverse-engineering: zlib versions, libdeflate, 7-Zip, miniz, Go flate, .NET DeflateStream, Java `java.util.zip`, Apple/CoreFoundation, Info-ZIP/PKZIP/gzip where practical
- [ ] For each generator oracle, produce the same seeded input set across all exposed levels/strategies/window/mem settings, then record raw DEFLATE bytes and observed block/flush/token summaries
- [ ] For in-the-wild corpora, extract embedded DEFLATE streams from ZIP-family, PNG, PDF, gzip, iWork, Office, EPUB, APK/JAR/WHL/XPI/VSIX, and public sample files; keep enough surrounding metadata for whole-file round-trip tests
- [ ] Classify every miss mechanically by observed features: block type sequence, memLevel-like token cadence, flush schedule, first token divergence, Huffman header shape, and compressed-size neighborhood
- [ ] Promote a behavior to registry/config only when the project can reproduce the stream byte-exactly from raw input and the config is expressed without producer-specific names in core code
- [ ] Keep near-matches as corpus evidence for future work; do not rely on difz as a substitute for pursuing a real fingerprint unless the stream is genuinely outside the supported model
- [ ] Define the event-level correction stream format: residuals over parsed DEFLATE decisions (LZ77 literals/matches, match-candidate hops, block splits, block types, Huffman tree choices, flush/finish markers), explicitly avoiding raw packed-byte diffs as the primary residual layer
- [ ] Add per-stream storage economics scoring: compare `strong_compress(raw) + fingerprint/config + correction` against storing the original DEFLATE blob, and record the decision in corpus probe reports
- [x] Study precomp/preflate/preflate-rs/grittibanzli/reflate behavior and document which correction-stream ideas are compatible with this project's RFC 1951-only core and C FFI; see `docs/PRIOR_ART.md` (2026-05-26 EDT)
- [x] Define how DFP must exceed prior art: forensic attribution, transparent registry, embeddable Zig/C FFI, measured corpus coverage, container-agnostic RFC 1951 core, native fallback economics, and explainable evidence trail (2026-05-26 EDT)
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
- [x] Office/OOXML producer variance noted and initial metadata capture added:
  ZIP probe now reports `Application` and `AppVersion` in verbose mode.
- [ ] Office/OOXML producer variance follow-up: cluster streams by byte-reproduction
  behavior and record `docProps/app.xml` metadata (`Application`, `AppVersion`)
  plus ZIP version/subtype fields; do not assume one Excel fingerprint covers
  all Excel versions/platforms.
- [x] Excel worksheet next step: add token-stream diffing around the first CPI
  divergence at compressed byte 10,529 for the best-so-far candidate. Completed
  with `inspectTokens()`; the corrected CPI candidate is byte-exact.
- [ ] Excel worksheet follow-up: validate `chain=16 nice=35 insert=4`,
  memLevel=7, segmented sheetData sync-flush topology across more Excel
  versions/platforms before promoting it from probe hypothesis to a stable
  fingerprint.
- [x] Excel worksheet follow-up: parameter-sweep CPI `sheet3` and `sheet5`;
  both reproduce byte-exact with segmented `chain=16 nice=60 insert=4`,
  memLevel=7, so the Excel 16 CPI workbook has at least two worksheet
  parameter clusters (`nice=35` and `nice=60`) (2026-05-25 11:20 EDT)
- [x] Excel worksheet follow-up: resolve CPI `sheet6`; byte-exact with
  segmented `chain=16 nice=48 insert=4`, memLevel=7, plus additional sync
  flushes at 1024-row boundaries (`row1024` cluster) (2026-05-25 11:20 EDT)
- [ ] Apple CF DEFLATE: zlib-derived or distinct?
- [x] Apple/iOS app payload DEFLATE cluster: remaining first-200 mixed misses showed `dynamic:4096` and dynamic-then-stored fallbacks; closed by generic Info-ZIP-style 4096-symbol profitability flush fingerprint #32 after `/usr/bin/zip -6` and Nix `zip -6` reproduced the sampled stream byte-exact (2026-05-25 17:10 EDT)
- [ ] .NET DeflateStream version coverage strategy
- [ ] Adversarial inputs / fingerprint forgery — security model for forensic use
- [ ] PNG IDAT-specific coverage: DEFLATE reproduction is required; PNG row filters and IDAT chunking are adapter/upstream metadata, but must be captured in tests for whole-file bit-exact restoration
- [ ] PNG IDAT miss follow-up: model exact row partial-flush semantics for row-sized fixed/dynamic blocks with empty fixed markers; remaining sampled row-like misses have raw block spans equal to PNG filtered scanline sizes (`width * bytes_per_pixel + 1`).
- [ ] PNG IDAT miss follow-up: investigate the unresolved single dynamic 59x32 16-bit RGBA stream; the whole stream is one dynamic block over 32 filtered scanlines and did not match current 16 KiB-window candidates.
- [ ] PDF FlateDecode coverage: distinguish DEFLATE reproduction from PDF object/container reconstruction, but test both enough to support blar integration
- [ ] macOS/iWork coverage: determine whether Pages/Numbers/Keynote use ZIP, protobuf/snappy-like package internals, Apple/CoreFoundation DEFLATE, zlib, or mixed encoders across versions
- [ ] gzip header bytes as secondary attribution signal
- [ ] Registry distribution and update mechanism for deployed library instances
- [ ] Promote probe-only worksheet clusters into stable generic fingerprints only after they are expressed as configurations and validated across multiple producer/version corpora; do not add core functions named after a specific application.

## Cross-product coordination

- [ ] Mecha Archiver (Phase 3a of [Mecha LLC release plan](../mecha_llc_website/docs/MECHA_RELEASE_PLAN.md)) integrates this library as the byte-identity backstop for ZIP-based formats
- [ ] difz integration: after DEFLATE event-level correction is defined, decide where `../difz` fits: wrapper/container residuals, already-realigned payloads, or a generic fallback when event correction is unavailable
- [ ] BLIP/blar maintain their fully-open license posture (MIT/similar); deflate_fingerprint follows suit

## Completed

- [x] Refresh stale public/status docs and add `dirtree` annotations to reflect current 28-fingerprint state, blar/difz integration role, and active Excel large-entry investigation (2026-05-24 23:50 EDT)
