# Session Resume Notes — 2026-05-25

This file captures all live context after an upstream Anthropic false-positive
AUP block hit a benign compression-algorithm-analysis request. Written to
disk so we don't lose direction if the conversation has to be rolled back.

## What this project is

`deflate_fingerprint` — identify which DEFLATE encoder produced a given
compressed byte stream by reproducing the exact byte stream from the
uncompressed input. Downstream consumer: `../blar` (archive format that
needs byte-identical reconstruction of embedded compressed streams).

## Current state (parent = wlkkmnkw a0af9f8b)

- 28 fingerprints registered (zlib L0-L9 × default/HUFFMAN_ONLY/RLE/FIXED/FILTERED
  + zlib L1 explicit `SYNC_FLUSH` + empty finish).
- Internal corpus: 100% hit rate (10 project files × 10 levels × 5 strategies = 500 streams).
- Real-world corpora:
  - ~/Downloads (936 streams):              70.9%
  - Fileserver Books / 100 ePubs (13,761):  73.4%
  - Fileserver Downloads (6,091):           85.7%
  - Fileserver Documents / 2 .xlsx (516):   66.1% with fingerprint #28
- 114 full-suite tests green; current module architecture includes
  bitstream/huffman/match/blocks/encoder/fidelity/inspect/ooxml/lib.
- `tools/zip_corpus_probe.zig` walks ZIP archives, extracts DEFLATE entries,
  reports per-fingerprint hits, and in verbose mode prints OOXML producer
  metadata plus compact block summaries for misses. Build via
  `nix develop -c zig build probe-install`. Use `--excel-experimental` to
  count the current probe-only worksheet candidates against worksheet XML
  entries. Worksheet/producer inference is intentionally tool-side.
- `tools/excel_candidate_probe.zig` compares worksheet-specific candidate
  encoders against a raw worksheet and target DEFLATE stream. Build/run via
  `nix develop -c zig build excel-probe -- RAW TARGET [--sweep]`.
  Use `--candidate CHAIN NICE INSERT [--history]` to inspect arbitrary
  fast-parameter hypotheses with token-divergence reporting.

## Recently landed

**`src/match.zig` MAX_DIST fix.** zlib uses `MAX_DIST = window_size - MIN_LOOKAHEAD = 32768 - 262 = 32506`,
not `window_size = 32768`. On inputs >32KB our LZ77 was accepting matches with
distance 32506-32768 that zlib rejects via `slide_hash`, causing token-stream
divergence.

Changes applied and committed:
- Added `inline fn maxDist(params)` helper returning `params.window_size - (max_match + min_match + 1)`.
- `lz77Tokenize`: changed `<= params.window_size` to `<= maxDist(params)`.
- `lz77TokenizeSlow`: same change.
- `longestMatch`: added `limit = strstart > md ? strstart - md : 0` and
  `if (cur_match <= limit) break;` to stop chain walk at MAX_DIST.

**Verified:** 46KB info-zip src/encoder.zig case (previously diverged at byte
10035 on 35530-byte threshold) now **byte-exact** matches zlib L1.

## What we're investigating right now

Excel `.xlsx` `xl/worksheets/sheet2.xml` entry:
- Original: 279,493 bytes
- Excel compressed: 52,876 bytes (BFINAL=0, BTYPE=DYNAMIC, trails with `00 00 ff ff 03 00`)
- Registered v0.1 flush/finish encoder: 53,419 bytes
- **Mystery:** Excel's stripped data block is **smaller than any zlib level
  (1-9)**:
    - L1: 53413B
    - L6: 40415B
    - L7: 39936B (smallest L)
    - Excel-stripped-flipped: 52870B
  None match.

## Open hypothesis tree

1. **Excel uses different zlib LEVEL for large entries than small ones.**
   - Small entries (wb 896B, rels 588B, ct 3470B): match L1 exactly + OPC trailer.
   - Large entries (sheet2 280KB): don't match ANY zlib level.
   - Maybe Excel has a size-based heuristic? "Use L1 for small, L6 for large"?

2. **Excel uses a different memLevel.** memLevel=8 is default (16K symbol buffer).
   memLevel=9 (32K), memLevel=7 (8K) etc. would change multi-block boundaries
   and thus the token stream slightly.

3. **Excel uses a non-zlib encoder entirely for large entries.** Could be
   libdeflate, .NET DeflateStream, or Microsoft's own implementation.

4. **Excel's compression is something between L1 and L6.** 52870 < L1 (53413)
   but >> L6 (40415). The pattern suggests aggressive matching within
   smaller-than-default blocks, OR a non-standard match-finding algorithm.

## Specific next experiment to run

The first block-boundary question is answered for the CPI workbook: large
worksheet streams use an 8,191-token cadence with explicit empty STORED flush
markers. The next experiment should compare candidate encoders against that
shape rather than only against final byte size:

- Simulate zlib memLevel=7 with level-2/level-3-adjacent fast parameters.
- Preserve the observed sync-flush cut points around worksheet XML structure
  (`<sheetData>` start/end).
- Compare first divergence by token stream and block boundary, not just total
  compressed size.

The old `/tmp/excel_analysis/*` fixtures from a prior session are not present
in this shell session. Current recreated CPI fixtures live under
`/tmp/dfp_excel_probe/`, and the broader workbook probe directory is
`/tmp/dfp_xlsx_probe_dir/`.

## New evidence from current Codex session (2026-05-25)

Added `src/inspect.zig`, `tools/deflate_block_inspect.zig`, and memLevel=7
zlib encoder paths:
- `inspectBlocks()` now parses raw RFC 1951 block boundaries for STORED,
  FIXED, and DYNAMIC blocks, including dynamic tree-of-trees and LZ77
  length/distance accounting.
- `deflate-block-inspect` prints block type, compressed bit range, raw byte
  range, and token count for a raw-DEFLATE file.
- `encodeZlibLevel1Mem7`, `encodeZlibLevel2Mem7`, and `encodeZlibLevel3Mem7`
  are byte-exact against real zlib on multi-block tests. They are not
  registered fingerprints yet.
- The block emit path now has raw-slice-aware STORED fallback for chunked
  streams. This fixes a real bug exposed by memLevel=7: a token chunk can start
  with a match whose distance points into a previous block, so a block cannot
  always reconstruct its raw bytes from its local token slice alone.
- Token-only multi-block helpers now reconstruct the full raw stream once and
  delegate into raw-slice-aware per-chunk emission. A regression test covers a
  chunk beginning with a match whose distance reaches into the previous chunk.
- The registered v0.1 flush/finish wrapper now uses raw-slice-aware chunk emission too; this is pinned
  by a small cross-chunk-match regression test.
- Full suite is now 114/114 green after moving worksheet-specific core tests
  into generic configuration coverage, adding C FFI config coverage, and
  adding target-derived flush schedule coverage.

The original `/tmp/excel_analysis` fixtures were not present, so a similar
local workbook was probed:
`/Users/pmarreck/Downloads/CPI2023_Global_Results__Trends.xlsx`,
entry `xl/worksheets/sheet2.xml`.

Extracted fixtures:
- `/tmp/dfp_excel_probe/sheet2_orig.bin` — 286,197 bytes
- `/tmp/dfp_excel_probe/sheet2_comp.bin` — 50,183 bytes

Observed block structure:

```
idx final type    raw_start raw_end tokens
0   false dynamic 0         3442    701
1   false stored  3442      3442    0
2   false stored  3442      3442    0
3   false dynamic 3442      88655   8191
4   false dynamic 88655     180477  8191
5   false dynamic 180477    274682  8191
6   false dynamic 274682    285412  954
7   false stored  285412    285412  0
8   false stored  285412    285412  0
9   false dynamic 285412    286197  494
10  false stored  286197    286197  0
11  true  fixed   286197    286197  0
```

Immediate implications:
- The large worksheet stream uses an 8,191-token block cadence, strongly
  suggesting zlib `memLevel=7`-style pending buffers (default memLevel=8 gives
  16,383-token blocks).
- The stream contains explicit empty STORED blocks mid-stream and at the end,
  consistent with one or more `Z_SYNC_FLUSH` calls before final finish.
- It is not just "standard zlib L1 with a different trailer."

Real zlib level/memLevel sweep on the CPI sheet2 raw bytes:

```
L1 mem7: 55634 bytes
L2 mem7: 51932 bytes
L3 mem7: 49058 bytes
L4 mem7: 46610 bytes
L5 mem7: 42710 bytes
L6 mem7: 41045 bytes
L7 mem7: 40404 bytes
L8 mem7: 39609 bytes
L9 mem7: 39609 bytes
```

CPI sheet2's 50,183 bytes falls between zlib L2 and L3 at memLevel=7. Its
raw block boundaries after the initial flush are also between L2 and L3:
- L2 mem7 first main block after a 3442-byte sync flush ended raw at 85,085.
- CPI ended raw at 88,655.
- L3 mem7 first main block after a 3442-byte sync flush ended raw at 93,260.

Updated hypothesis:
- Excel / the producer may be using zlib-compatible `memLevel=7` plus
  streaming sync flushes, with match parameters between zlib levels 2 and 3,
  or a non-zlib/Java encoder with similar 8K pending-buffer behavior.
- Candidate encoders now simulate the worksheet flush topology and sweep
  level-2/level-3-adjacent fast parameters. Initial best CPI candidate
  `chain=16 nice=28 insert=4`, memLevel=7, segmented at `<sheetData>` and
  `</sheetData>`, matched the prefix block exactly and matched through
  compressed byte 10,529, but was 50,182 bytes vs target 50,183.
- Token-stream diffing then showed the first wrong LZ77 decision at token
  index 6143 / raw offset 58,863: target `match(len=29, dist=15399)` vs
  candidate `match(len=28, dist=14276)`. Raising `nice_match` past that
  early-exit point moved the divergence later; `nice=32` matched the body block
  boundaries but still missed at token index 18,729 (`len=35` target vs
  `len=33` candidate).
- Current CPI sheet2 result: segmented `chain=16 nice=35 insert=4`, memLevel=7,
  with inferred sheetData sync flushes, reproduces
  `/tmp/dfp_excel_probe/sheet2_comp.bin` byte-exact (`50,183` bytes) from
  `/tmp/dfp_excel_probe/sheet2_orig.bin`. Its token stream is identical to the
  target. Prefix-history mode with the same params is not exact.
- `zip-corpus-probe --excel-experimental /tmp/dfp_xlsx_probe_dir --verbose`
  currently reports 6/8 worksheet XML entries exact across three unregistered
  CPI clusters:
  - `nice=35`: CPI `sheet1.xml`, `sheet2.xml`, `sheet4.xml`
  - `nice=60`: CPI `sheet3.xml`, `sheet5.xml`
  - `row1024`: CPI `sheet6.xml`
  LibreOffice `scorely` and Excel 14 sample worksheet entries are not exact.
  This supports Peter's concern: worksheet behavior should be clustered
  by byte-reproduction behavior, not labeled as one universal Excel encoder.
- Follow-up parameter checks on extracted CPI false negatives:
  - `sheet3.xml` and `sheet5.xml` reproduce byte-exact with segmented
    `chain=16 nice=60 insert=4`, memLevel=7, same sheetData flush topology.
  - `sheet6.xml` reproduces byte-exact with segmented `chain=16 nice=48
    insert=4`, memLevel=7, plus extra sync flushes at 1024-row boundaries.
    The key clue was that the previous best candidate over-matched across raw
    offset 859,844, exactly where the target stream has two empty STORED flush
    blocks before row 1025.

Current abstraction boundary:
- Core encoder code is producer-agnostic. New reproduction behavior should be
  represented as `DeflateReproductionConfig` values: LZ77 params, memLevel,
  tokenization mode, `FlushEvent` schedules, final flush count, and finish mode.
- `inspect.observeFlushSchedule()` derives the sync-flush topology from the
  target DEFLATE stream itself by grouping consecutive empty STORED blocks at
  the same raw offset. This is deterministic and does not need AI or
  producer/container naming.
- The C FFI now exposes the same abstraction as `dfp_encode_configured()` using
  `dfp_deflate_config_t`, so non-Zig callers can reproduce config-discovered
  streams without depending on a registry ID.
- Producer/container knowledge such as "worksheet XML", `<sheetData>` parsing,
  1024-row chunk boundaries, and labels like "Excel 16.0300" belongs in
  tests, corpus probes, or future fingerprinting heuristics that emit generic
  configs. It should not become application-named main encoder logic.

## Producer/version variance concern (Peter, 2026-05-25)

Do **not** assume there is one universal "Excel" DEFLATE fingerprint. Different
Excel versions, platforms, OOXML packaging layers, Java/.NET libraries, or zlib
versions may use different compression parameters or even different deflate
implementations.

Local metadata already shows why this matters:
- CPI workbook: `Application=Microsoft Excel`, `AppVersion=16.0300`, ZIP
  version-made-by 4.5, deflate subtype `superfast`.
- Small sample workbook: `Application=Microsoft Excel`, `AppVersion=14.0300`,
  ZIP version-made-by 4.5, deflate subtype `superfast`.
- LibreOffice template: `Application=LibreOffice/6.1.0.3...`, ZIP
  version-made-by 2.0, deflate subtype `normal`.

Project stance:
- Stable fingerprint IDs should represent byte-reproduction behavior, not a
  marketing/application label.
- Producer labels like "Microsoft Excel 16.0300" should be evidence attached to
  a corpus observation or registry entry, with version/platform ranges only
  after repeated confirmation.
- The next probe should cluster OOXML streams by observable DEFLATE behavior
  (block cadence, flush markers, zlib level/memLevel match, byte-exact ID),
  while also recording producer metadata from `docProps/app.xml` and ZIP
  central-directory fields.

Implemented first response:
- Added `src/ooxml.zig` with tested `parseAppMetadata()` for `Application` and
  `AppVersion`.
- `zip_corpus_probe --verbose` now prints OOXML app metadata when
  `docProps/app.xml` is present.
- `zip_corpus_probe --verbose` now prints compact block summaries on misses,
  e.g. `blocks: dynamic:701 stored:0 stored:0 dynamic:8191 ...`.
- Local probe examples:
  - CPI workbook: `Microsoft Excel`, `AppVersion=16.0300`
  - sample workbook: `Microsoft Excel`, `AppVersion=14.0300`
  - scorely template: `LibreOffice/6.1.0.3...`

Current probe check:
- `/tmp/dfp_xlsx_probe_dir --verbose` completes without crashing.
- CPI workbook remains mostly missed: small entries hit fingerprint #28, while
  large worksheet streams miss with memLevel=7-like block cadence and explicit
  empty stored flush markers.
- `zip-corpus-probe --excel-experimental /tmp/dfp_xlsx_probe_dir --verbose`
  now uses target-derived observed flush schedules first and reports 7/8
  worksheet entries exact:
  - CPI sheets 1/2/4: `observed-nice35`
  - CPI sheets 3/6: `observed-nice48`
  - CPI sheet5: `observed-nice60`
  - Excel 14 sample sheet1: `observed-l1-mem7`
  - LibreOffice scorely sheet1: not an experimental worksheet match because
    it is plain registered zlib L6 (`#4`) with no explicit flush/finish shape.

## Outstanding gaps to close

1. **Generalize the probe-only worksheet clusters into abstract configs** and
   decide when they are mature enough for stable fingerprint IDs.
2. **Validate the exact CPI worksheet hypotheses on more producer/version corpora**:
   Cluster A: `chain=16 nice=35 insert=4` covers CPI sheets 1/2/4. Cluster B:
   `chain=16 nice=60 insert=4` covers CPI sheets 3/5. Cluster C:
   `chain=16 nice=48 insert=4 row_chunk=1024` covers CPI sheet6. Do not promote
   any cluster as "Excel" until multiple producer versions/platforms agree.
3. **Re-run probe on Excel to see if remaining 175 misses dropped** with
   MAX_DIST fix. (Probably no, since the L1 fix doesn't change OPC output
   for entries where Excel is non-L1.)
4. **Re-run probe on Fileserver Books/Downloads** to see broader hit-rate
   improvement from MAX_DIST fix.
5. Apple Mac installer non-zlib family (separate investigation from earlier).
6. **Broaden format coverage beyond ZIP/OOXML**:
   PNG IDAT, PDF FlateDecode, gzip, iWork (`.pages` / `.numbers` / `.key`),
   and the wider ZIP-container family (`.jar`, `.war`, `.ear`, `.apk`, `.ipa`,
   `.whl`, `.xpi`, `.crx`, `.vsix`, OpenDocument, EPUB, CBZ, etc.) are all
   in scope for bit-exact embedded DEFLATE reproduction. Core stays RFC 1951;
   adapters/tests capture container metadata, PNG filters/chunking, PDF object
   details, ZIP directories, and other wrapper bytes needed by blar.
7. **External encoder families are explicit targets**:
   libdeflate, 7-Zip, miniz, Go `compress/flate`, .NET DeflateStream, Java
   `java.util.zip`, Apple/CoreFoundation, and zlib version drift. It is OK to
   add these as development-only `flake.nix` dependencies or platform-SDK
   probes when implementing their corpus generators.

## Recent commit log (most recent first)

```
mrzxkyku tools: report OOXML producer metadata
uwysrsmz encoder: add zlib memLevel 7 fast profiles
mnvnmutw tools: add deflate block inspector probe
zoplssqr inspect: decode dynamic deflate block ranges
vxmkryvy inspect: decode fixed deflate block ranges
xkztuvlm inspect: report stored deflate block ranges
zzvvlnuv encoder/docs: fix zlib max distance and refresh status
```

## How to resume after a rollback

1. Read this file (`SESSION_RESUME.md`) first.
2. `jj status` — current uncommitted work, if any, should be limited to the
   active probe/fix being worked.
3. Run `./test` — should be 114/114 green.
4. Continue with abstract stream-divergence analysis; named producer details
   should remain in probes/tests unless Peter explicitly approves otherwise.
