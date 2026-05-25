# DEFLATE Encoder Dials — Comprehensive Enumeration

Every encoder choice that produces *spec-valid but byte-distinct* output for
the same uncompressed input. The fingerprint registry must cover the cross-
product of these choices, modulo the empirical collapses we discover (e.g.
zlib HUFFMAN_ONLY across (level, memLevel) → one fingerprint, see
ENCODER_NOTES.md).

Maintained alongside `ENCODER_NOTES.md`: dials live here, *empirical
observations* about specific encoders live there.

---

## RFC 1951 (DEFLATE proper)

| # | Dial | Description | Typical implementations |
|---|---    |---           |---                       |
| 1 | **Block boundary placement** | When to emit a block-final marker. NOT a simple "size > C" — many encoders use entropy-adaptive heuristics. zlib re-evaluates every 8192 symbols and forces a boundary if compression ratio is poor; libdeflate runs forward dynamic programming over candidate split points; 7-Zip evaluates multi-candidate boundaries against the cost model. | zlib's `_tr_tally` + `s->last_lit & 0x1fff` re-eval; libdeflate's `do_end_block` heuristic; 7-Zip's optimal parser |
| 2 | **Block type selection** (STORED / FIXED / DYNAMIC) | Per-block cost comparison. zlib uses bit-level formulas with the famous `stored_len + 4 <= opt_lenb` quirk (omits the BTYPE+padding byte). | zlib's `_tr_flush_block` |
| 3 | **Dynamic Huffman tree construction** | Canonical Huffman is under-specified for ties: which symbol of equal frequency gets the lower code? zlib's depth-aware heap (`smaller(n,m,depth)`) produces one specific tree out of many valid ones. | zlib's `build_tree` |
| 4 | **CL-code (tree-of-trees) Huffman tree** | Same canonical-Huffman ambiguity applied to the 19-symbol code-length alphabet. | zlib's `build_bl_tree` |
| 5 | **Code-length-sequence RLE** | The literal+distance code-length sequence is RLE-compressed using codes 16/17/18. When to RLE vs. emit literally is a heuristic — zlib's `scan_tree` defines thresholds `min_count = 3 or 4` and `max_count = 6, 7, or 138` depending on whether the run is of zeros / nonzero / equal-to-previous. | zlib's `scan_tree` + `send_tree` |
| 6 | **HCLEN trimming** | Trailing zero entries in `bl_order` permutation can be elided. Encoders agree on the principle but could in theory emit padding zeros — none do in practice. | RFC §3.2.7 |
| 7 | **Max code lengths** | Lit/dist tree capped at 15 bits, CL tree at 7 bits. When naive Huffman exceeds, encoders apply different overflow-redistribution algorithms (zlib's iterative bl_count adjustment vs. package-merge vs. others). | trees.c `gen_bitlen` |

## LZ77 (within DEFLATE)

| # | Dial | Description | zlib quirk |
|---|---    |---           |---          |
| 8 | **Hash function** | Maps a 3-byte (or 4-byte) prefix to a hash bucket. zlib uses a rolling 3-byte hash with shift+XOR; libdeflate uses a different multiplicative hash; 7-Zip uses a CRC-style. Hash collisions are encoder-specific. | `INSERT_STRING` macro, parameterized by `hash_shift` and `hash_mask` |
| 9 | **Hash table size** | Determined by `memLevel` (zlib: `2^(memLevel+7)` entries, default `memLevel=8` → 32K). Smaller tables = more collisions = different match candidates. | `hash_size = 1 << s->hash_bits` |
| 10 | **Match-finding algorithm** | Hash chain (zlib), binary tree (7-Zip, libdeflate's BT4), suffix automaton (some experimental). Choice affects which matches are visible. | zlib's hash chain via `s->prev[]` |
| 11 | **Match minimum length** | Typically 3 (RFC requires ≥3). Some encoders bump to 4 to skip marginal 3-byte matches. | `MIN_MATCH = 3` |
| 12 | **Match maximum length** | RFC max is 258. All major encoders honor this. | `MAX_MATCH = 258` |
| 13 | **Max chain length** | How far back to walk the hash chain when searching. zlib's per-level table: levels 1/2/3 use 4/8/32; level 6 uses 128; level 9 uses 4096. | `s->max_chain_length` |
| 14 | **Good match threshold** | Halve the chain walk when a match this long is found. zlib's level 6 = 8, level 9 = 32. | `s->good_match` |
| 15 | **Nice match threshold** | Accept immediately (no further search) when a match this long is found. | `s->nice_match` |
| 16 | **Lazy matching threshold** | Defer accepting current match to see if next position offers longer. zlib levels 1-3 use 0 (no lazy); level 4 uses 4; level 6 uses 16; level 9 uses 258. | `s->max_lazy_match` |
| 17 | **Match-length tie-breaking** | When two positions tie for longest match, which to prefer. zlib prefers the *first* one found while walking the chain (which is the most recent). 7-Zip prefers shortest distance (often gives smaller distance codes). | `longest_match` loop direction + tie behavior |
| 18 | **Insert-string strategy during a long match** | After emitting an N-byte match, do we hash all N positions or skip some? zlib at low levels skips (level 1-3 only hash the first position of a match); high levels hash all. | `s->level >= 4 ? hash all : hash only first` |
| 19 | **Window-slide cadence** | When to copy the second half of the window to the first half and continue. Affects which matches remain visible across the slide. | `fill_window` in deflate.c |

## RFC 1950 (zlib wrapper)

| # | Dial | Description |
|---|---    |---           |
| 20 | **CMF byte** | bits 0-3 = CM (always 8 = deflate); bits 4-7 = CINFO = log2(window_size) - 8. So `0x78` = window 32 KB, `0x18` = window 512 B. |
| 21 | **FLG byte: FCHECK** | bits 0-4, chosen so `(CMF*256 + FLG) % 31 == 0`. Determined by encoder; multiple valid values exist for any (CMF, FLEVEL, FDICT) combo. |
| 22 | **FLG byte: FDICT** | bit 5. Set when a preset dictionary precedes the stream. |
| 23 | **FLG byte: FLEVEL** | bits 6-7. 0 = fastest, 1 = fast, 2 = default, 3 = max. zlib sets this from `level`: level 0-1 → 0; level 2-5 → 1; level 6 → 2; level 7-9 → 3. Strategy-sensitive too: HUFFMAN_ONLY → 0 regardless of level. |
| 24 | **Adler32 byte order** | RFC mandates big-endian for the trailer. Universal. |

## RFC 1952 (gzip wrapper)

| # | Dial | Description | Observed |
|---|---    |---           |---        |
| 25 | **CM byte** | Compression method. Always 8 (deflate). | `0x08` |
| 26 | **FLG byte** | FTEXT (bit 0), FHCRC (1), FEXTRA (2), FNAME (3), FCOMMENT (4); reserved (5-7). | zlib defaults to 0 unless explicitly set |
| 27 | **MTIME** | LE32 modification time. Encoder choice: real-time, 0, source file mtime. | zlib gzip default is 0 |
| 28 | **XFL** | "Extra flags": 2 = max compression (level 9), 4 = fastest. zlib actually keys off both level AND strategy: HUFFMAN_ONLY → XFL=4 *regardless of level*. | Observed empirically; needs probe #13 to fully characterize |
| 29 | **OS** | Source operating system. RFC table: 0=FAT, 3=Unix, 7=Mac, etc. **Platform-dependent** — we see 0x13 on Darwin nixpkgs (not in RFC table). Likely fingerprint-significant. | Probe #13 to characterize across platforms |
| 30 | **Optional fields** | FEXTRA, FNAME, FCOMMENT, FHCRC — only present when their FLG bits are set. |
| 31 | **CRC32 / ISIZE** | LE32 each. Algorithms fixed; encoder choice only in which length to report for >4GB inputs (modulo 2^32). |

## Container-level (above DEFLATE, fingerprint-adjacent)

These don't change the DEFLATE bytes themselves but determine *which* bytes
are observable and influence fingerprint matching at the file level.

| # | Dial | Description |
|---|---    |---           |
| 32 | **ZIP local-header layout** | Version-made-by, version-needed, GP-flags, compression-method, file-time, CRC32. The DEFLATE stream sits inside an entry. |
| 33 | **ZIP CRC32 placement** | Local header vs. data descriptor (GP flag bit 3). |
| 34 | **ZIP central directory ordering** | Entries can appear in any order; tools differ. |
| 35 | **ZIP filename encoding** | CP437 default; UTF-8 with bit 11 of GP flags. |
| 36 | **PNG IDAT chunking** | Single IDAT vs. multiple chunks; chunk-boundary placement is outside RFC 1951 but required metadata for bit-exact whole-PNG restoration. |
| 37 | **PNG row filter selection** | None/Sub/Up/Average/Paeth, per row. Pre-DEFLATE, byte-affecting, and therefore must be captured by PNG adapters/tests even though the DEFLATE core only sees filtered bytes. |
| 38 | **EPUB mimetype convention** | First entry MUST be uncompressed `mimetype` per epub spec — affects expected ZIP layout. |
| 39 | **DOCX/XLSX/PPTX** | Office Open XML — ZIP with specific entry ordering: `[Content_Types].xml` typically first. |
| 40 | **PDF FlateDecode streams** | PDF stream dictionaries, object streams, predictors, and filters determine which bytes are fed to DEFLATE and how the stream is embedded. Required for corpus extraction and whole-file tests. |
| 41 | **iWork packages** | `.pages`, `.numbers`, and `.key` files may use ZIP/package internals and Apple encoders. Required corpus target; container details stay adapter-side. |
| 42 | **ZIP-container aliases** | `.jar`, `.war`, `.ear`, `.apk`, `.ipa`, `.whl`, `.xpi`, `.crx`, `.vsix`, `.odt`, `.ods`, `.odp`, `.cbz`, EPUB, OOXML, and many others are ZIP archives with method=8 entries. They should share the same ZIP DEFLATE walker, with format-specific metadata layered on only when useful. |

---

## Empirical collapses already discovered

Not every dial-combination produces unique output. Some collapse to identical
bytes:

- **zlib HUFFMAN_ONLY** across (level, memLevel) = 1 fingerprint
  (level controls match-finding effort; HUFFMAN_ONLY skips matches → all levels
  produce the same bytes)
- **zlib level=0** across (strategy, memLevel) = 1 fingerprint (no matches,
  no Huffman tree, just stored blocks)
- **zlib raw vs. zlib-wrapper windowBits magnitude** for HUFFMAN_ONLY = same
  body bytes (window unused)

More collapses will emerge as we probe DEFAULT_STRATEGY, FILTERED, RLE, FIXED
across levels 1-9.

## v0.1 attack order for LZ77

Within the LZ77-using strategies (DEFAULT, FILTERED, RLE, FIXED), zlib's level
matrix produces different `(max_chain_length, good_match, nice_match,
max_lazy_match)` tuples. Simplest first:

1. **Level 1 DEFAULT_STRATEGY** (`deflate_fast`, greedy, no lazy):
   `max_chain=4, good_match=4, nice_match=8, max_lazy=0`. Simplest LZ77 +
   dynamic Huffman (already built). One match attempt per position, greedy.
2. **Level 2-3** — also `deflate_fast`, varying chain depths.
3. **Level 4-9** (`deflate_slow`, lazy matching). Significantly more complex
   due to one-position-deferred decisions.
4. **RLE strategy** — like DEFAULT but allows only distance=1 matches
   (run-length encoding). Subset of DEFAULT's algorithm.
5. **FIXED strategy** — like DEFAULT but always emits BTYPE=01 blocks.
6. **FILTERED strategy** — like DEFAULT but disqualifies matches with
   distance > some threshold for certain input patterns.
