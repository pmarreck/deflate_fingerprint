# Session Resume Notes — 2026-05-24

This file captures all live context after an upstream Anthropic false-positive
AUP block hit a benign compression-algorithm-analysis request. Written to
disk so we don't lose direction if the conversation has to be rolled back.

## What this project is

`deflate_fingerprint` — identify which DEFLATE encoder produced a given
compressed byte stream by reproducing the exact byte stream from the
uncompressed input. Downstream consumer: `../blar` (archive format that
needs byte-identical reconstruction of embedded compressed streams).

## Current state (HEAD = qnqwxlrm 724f3a63)

- 28 fingerprints registered (zlib L0-L9 × default/HUFFMAN_ONLY/RLE/FIXED/FILTERED
  + Microsoft OOXML / Office OPC).
- Internal corpus: 100% hit rate (10 project files × 10 levels × 5 strategies = 500 streams).
- Real-world corpora:
  - ~/Downloads (936 streams):              70.9%
  - Fileserver Books / 100 ePubs (13,761):  73.4%
  - Fileserver Downloads (6,091):           85.7%
  - Fileserver Documents / 2 .xlsx (516):   66.1% with fingerprint #28
- 96 unit tests green; 5-module architecture (bitstream/huffman/match/blocks/encoder).
- `tools/zip_corpus_probe.zig` walks ZIP archives, extracts DEFLATE entries,
  reports per-fingerprint hits. Build via `zig build probe-install`.

## What we just landed (uncommitted)

**`src/match.zig` MAX_DIST fix.** zlib uses `MAX_DIST = window_size - MIN_LOOKAHEAD = 32768 - 262 = 32506`,
not `window_size = 32768`. On inputs >32KB our LZ77 was accepting matches with
distance 32506-32768 that zlib rejects via `slide_hash`, causing token-stream
divergence.

Changes already applied:
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
- Our encodeOfficeOPC: 53,419 bytes
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

Bit-decode Excel sheet2's first multi-block boundary to figure out:
- Where does Excel's block 1 end?
- Block size in tokens vs bytes
- Does Excel emit BFINAL=0 between data blocks (multi-block) or just at end?

If Excel multi-blocks at a different threshold than 16383 symbols, that explains
both the smaller-than-L1 output AND the divergence.

Tools / fixtures already on disk:
- `/tmp/excel_analysis/sheet2_comp.bin` — Excel's compressed sheet2 (52876B)
- `/tmp/excel_analysis/sheet2_orig.bin` — original sheet2 (279493B)
- `/tmp/excel_analysis/extract.zig` — Zig ZIP entry extractor (built as `extract`)
- `/tmp/excel_analysis/test_opc.c` — C tester for our OPC encoder
- `/tmp/excel_analysis/libd_compress.c` — libdeflate raw-DEFLATE compressor for comparison
- `/tmp/dfp_debug/our_encode.c` + binary — generic fingerprint encoder caller
- `/tmp/dfp_debug/gen_zlib_target.c` + binary — real zlib output generator

Real-zlib L1 default on sheet2_orig.bin gives 53413B — proves our L1 is
byte-correct after the MAX_DIST fix. So whatever Excel does, it's NOT
standard zlib L1.

## New evidence from current Codex session (2026-05-25)

Added `src/inspect.zig` and `tools/deflate_block_inspect.zig`:
- `inspectBlocks()` now parses raw RFC 1951 block boundaries for STORED,
  FIXED, and DYNAMIC blocks, including dynamic tree-of-trees and LZ77
  length/distance accounting.
- `deflate-block-inspect` prints block type, compressed bit range, raw byte
  range, and token count for a raw-DEFLATE file.
- Full suite is now 100/100 green.

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
- Next experiment: simulate level 2/3-ish parameter tables in our encoder or
  generate reference streams with adjusted zlib config and flush cadence, then
  compare first divergence/token stream.

## Outstanding gaps to close

1. **Resolve sheet2 / Excel large-entry mystery** (current focus).
2. **Re-run probe on Excel to see if remaining 175 misses dropped** with
   MAX_DIST fix. (Probably no, since the L1 fix doesn't change OPC output
   for entries where Excel is non-L1.)
3. **Re-run probe on Fileserver Books/Downloads** to see broader hit-rate
   improvement from MAX_DIST fix.
4. Apple Mac installer non-zlib family (separate investigation from earlier).

## Recent commit log (most recent first)

```
qnqwxlrm encoder: Microsoft OOXML / Office OPC fingerprint #28
trpzxvns tools: probe — skip AppleDouble sidecars; probe-install build step
mtvylxmw tools+docs: probe Downloads corpus + record findings
unkpllko encoder: multi-block default L1-L9 + Z_FIXED + Z_FILTERED
vlyzuutl tools: zip-corpus-probe — real-world raw-DEFLATE probe
owsvqpwz tests: @cImport(zlib.h) fidelity harness
nurwurmz encoder: module split — bitstream, huffman, match, blocks
qyooowtp encoder: multi-block HUFFMAN_ONLY + RLE — 100% corpus hit rate
lzqqvsoz encoder: TOO_FAR rule — reject length-3 matches with distance > 4096
xwsqsnwo encoder: Z_FILTERED strategy fingerprints #22-#27 + hit-rate >= 70%
qqlpykzq encoder: Z_RLE strategy fingerprint #21
nmzxlxpw encoder: Z_FIXED strategy fingerprints + L2/L3 max_lazy_match fix
trwwzoxk encoder: L1 dispatcher fix — switch to 3-way dynamic-over-tokens
```

## How to resume after a rollback

1. Read this file (`SESSION_RESUME.md`) first.
2. `git status` (or `jj status`) — uncommitted MAX_DIST fix should be in
   `src/match.zig`. If not, re-apply per "What we just landed" above.
3. Run `./test` — should be 96/96 green.
4. Verify the MAX_DIST fix landed:
   ```
   /tmp/dfp_debug/our_encode /tmp/dfp_debug/infozip_enc.bin out.bin 3
   /tmp/dfp_debug/gen_zlib_target /tmp/dfp_debug/infozip_enc.bin zlib.bin 1 default
   cmp out.bin zlib.bin && echo "MAX_DIST fix is live"
   ```
5. Continue with the sheet2/Excel mystery per "Specific next experiment".
