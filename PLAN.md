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
- [x] C FFI surface (`src/lib.zig` + `include/deflate_fingerprint.h`) exposes `dfp_identify`, `dfp_encode`, `dfp_free`, and versioning
- [x] C CLI foundation (`cli/main.c`): `identify --raw --target [--json]`, `--help`, `--about`
- [ ] C CLI completion (`cli/main.c`): `reproduce`, `list`, richer reports
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

- [x] Refresh stale public/status docs and add `dirtree` annotations to reflect current 28-fingerprint state, blar/difz integration role, and active Excel large-entry investigation (2026-05-24 23:50 EDT)
