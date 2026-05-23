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
