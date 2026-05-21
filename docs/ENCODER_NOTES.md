# Encoder Notes — Empirical Findings

A living, append-only record of what we have *actually observed* about each
DEFLATE encoder we plan to fingerprint. Each finding cites the probe that
produced it (see `bench/probes/`) and the date it was captured.

Findings are durable knowledge — they survive context wipes, get amended only
with new evidence, and form the empirical foundation of the fingerprint
registry. Hypotheses go in `PLAN.md` (Open research questions); confirmed
behavior goes here.

Format per entry:
```
### <encoder> — <strategy/level/etc.>
**Date:** YYYY-MM-DD
**Probe:** bench/probes/<file>
**Reference version:** <e.g. zlib 1.3.2>

<findings, with byte fixtures if applicable>
```

---

## zlib

### zlib — HUFFMAN_ONLY (all levels 1..9)
**Date:** 2026-05-21
**Probe:** `bench/probes/zlib_huffman_only.c`
**Reference version:** zlib 1.3.2 (nixpkgs-unstable, May 2026)

**Finding 1 — Level is irrelevant for HUFFMAN_ONLY.**
Levels 1..9 produce **byte-identical output** for every input tested
(`empty`, `single_A`, `four_A`, `alphabet`, `hello`, `mixed`). This is
expected: `level` controls match-finding effort, and HUFFMAN_ONLY skips
matches entirely. The 9 (level, HUFFMAN_ONLY) cells collapse to **one
fingerprint**.

**Finding 2 — HUFFMAN_ONLY emits BTYPE=01 (fixed Huffman), not dynamic.**
First three bits of every block: BFINAL=1, BTYPE=01. Decoded from byte 0 of
each fixture LSB-first. This is RFC 1951 §3.2.6 fixed Huffman tables, no
dynamic table emitted. Even simpler than the dynamic-Huffman path.

**Finding 3 — Output is pure RFC-1951 fixed Huffman, no zlib quirks.**
Verified byte-for-byte against the RFC §3.2.6 fixed-Huffman literal table
(literals 0..143 → 8-bit codes 00110000..10111111). Meaning: this fingerprint
matches HUFFMAN_ONLY output from *any* RFC-1951-compliant encoder that picks
fixed Huffman, literals-only — not exclusively zlib.

**Byte fixtures** (raw DEFLATE, windowBits=-15, memLevel=8):

| Input           | Bytes               | Length (B) |
|---             |---                  |---         |
| `""`            | `03 00`             | 2          |
| `"A"`           | `73 04 00`          | 3          |
| `"AAAA"`        | `73 74 74 74 04 00` | 6          |
| `"ABCDEFG"`     | `73 74 72 76 71 75 73 07 00` | 9 |
| `"Hello, world!"` | `f3 48 cd c9 c9 d7 51 28 cf 2f ca 49 51 04 00` | 15 |
| `"AAAABBBBCCCCDDDD"` | `73 74 74 74 74 72 72 72 72 76 76 76 76 71 71 71 01 00` | 18 |

**Finding 4 — DEFAULT_STRATEGY L6 ≡ HUFFMAN_ONLY** on inputs with no useful
matches. For `empty`, `single_A`, `four_A`, `alphabet`, `hello`, the bytes
are identical to the HUFFMAN_ONLY output above. They diverge only when L6
finds an exploitable match (`mixed` is 13 bytes under DEFAULT_STRATEGY vs 18
bytes under HUFFMAN_ONLY). The detector will opportunistically match such
inputs under either fingerprint; ordering by prior probability decides which
gets reported first.

**Implication for v0.1 implementation:**
The encoder primitive needed for this fingerprint is:
1. Emit one DEFLATE block.
2. BFINAL=1, BTYPE=01 (3 bits, LSB-first).
3. For each input byte, emit the §3.2.6 fixed-Huffman literal code (8-bit for
   0..143, 9-bit for 144..255), MSB-first within the LSB-packed bit stream.
4. Emit end-of-block symbol 256 (7-bit code 0000000).
5. Zero-pad to byte boundary.

No LZ77 matching. No dynamic Huffman tree construction. No window
management. **EXCEPT** — zlib has a cost-model quirk that can pick a STORED
block instead of fixed Huffman for short, high-entropy inputs. See next
section.

### zlib — HUFFMAN_ONLY surprise: STORED-block fallback
**Date:** 2026-05-21
**Probe:** `bench/probes/zlib_huffman_only_expanded.c` section A
**Reference version:** zlib 1.3.2

For input `0xC0..0xCF` (16 bytes, all in the 144..255 range → all 9-bit fixed
Huffman literals), zlib emits a **STORED block**, not a fixed-Huffman block:

```
01 10 00 ef ff c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 ca cb cc cd ce cf  (21 B)
```

Decoded:
- `0x01` LSB-first: bit0=1=BFINAL, bits1-2=00=BTYPE STORED, bits3-7=zero padding
- `10 00` = LEN=16 (little-endian)
- `ef ff` = NLEN=0xFFEF = ~LEN ✓
- Then the 16 raw input bytes.

This is anti-optimal: fixed Huffman would have been 3 + 16*9 + 7 = 154 bits =
20 bytes padded — 1 byte smaller than the 21-byte stored output zlib chose.

**Root cause** (from reading `trees.c::_tr_flush_block`): zlib's stored-vs-fixed
selector compares `stored_len + 4` (bytes) against `opt_lenb = (static_len +
3 + 7) >> 3`. The `+4` only counts LEN+NLEN — it omits the BTYPE+padding
header byte that an actual stored block also costs. Net: zlib *underestimates*
stored cost by ~1 byte and prefers stored when the two are close.

For the 16-byte case: `static_len = 16*9 + 7 = 151 bits`, so `opt_lenb = (151+3+7)>>3 = 20 B`.
Stored estimate: `16 + 4 = 20 B`. Comparison `20 <= 20` → stored wins.

**Compare:** `0xFE 0xFF 0xFE 0xFF` (4 high bytes, all 9-bit codes) — zlib used
fixed Huffman (6 B output). At n=4: `static_len = 4*9 + 7 = 43`, `opt_lenb =
(43+3+7)>>3 = 6 B`. Stored estimate: `4 + 4 = 8 B`. 8 > 6 → fixed wins. ✓

**Implication for the fingerprint:** ~~our encoder must replicate this
suboptimal cost comparison, byte for byte. It is a *zlib quirk*, not RFC
behavior. The "fingerprint" function for zlib HUFFMAN_ONLY is therefore:~~

**CORRECTION 2026-05-21 (probe `zlib_huffman_only_breakpoint.c`):**
The fixed-vs-stored two-way model above was incomplete. zlib's HUFFMAN_ONLY
is a **three-way** decision: FIXED vs DYNAMIC vs STORED. The 16-byte
0xC0..0xCF case picked STORED only because 16 *distinct* symbols make
dynamic Huffman's tree description expensive (~150+ bits of tree-of-trees).
For inputs with few distinct symbols, DYNAMIC wins easily — even at modest
n. See "zlib — HUFFMAN_ONLY: full 3-way decision" below.

### zlib — HUFFMAN_ONLY: knobs that do NOT affect output
**Date:** 2026-05-21
**Probe:** `bench/probes/zlib_huffman_only_expanded.c` sections D + E

- **Level** (1..9): no effect. Confirmed in basic probe.
- **memLevel** (1..9): no effect for a 13-byte input that fits in any pending
  buffer. Larger inputs may show differences if buffer size affects block
  boundaries — separate probe needed.
- **windowBits magnitude** (8..15, with same sign): no effect on the DEFLATE
  body since HUFFMAN_ONLY doesn't use the window. Only the *sign* matters
  (raw vs. zlib vs. gzip wrapper).

So one fingerprint covers `{ zlib 1.3.2, raw DEFLATE, HUFFMAN_ONLY, level=∀, memLevel=∀ }`
plus possibly older 1.2.x versions (drift study pending).

### zlib — Wrapper formats (windowBits sign)
**Date:** 2026-05-21
**Probe:** `bench/probes/zlib_huffman_only_expanded.c` section E

Input `"Hello, world!"`, level=6, strategy=HUFFMAN_ONLY, memLevel=8.

| windowBits | Output                                                                                 | Notes |
|---         |---                                                                                     |---    |
| `-15`      | `f3 48 cd c9 c9 d7 51 28 cf 2f ca 49 51 04 00`  (15 B)                                  | Raw DEFLATE — our baseline |
| `-9`       | identical to `-15`                                                                     | Window size doesn't affect HUFFMAN_ONLY |
| `+15`      | `78 01` + raw + `20 5e 04 8a`  (21 B)                                                  | zlib wrapper |
| `+9`       | `18 19` + raw + `20 5e 04 8a`  (21 B)                                                  | zlib wrapper, smaller window declared in CMF |
| `+31`      | `1f 8b 08 00 00 00 00 00 04 13` + raw + `e6 c6 e6 eb 0d 00 00 00`  (33 B)             | gzip wrapper |

**zlib wrapper bytes:**
- `CMF` byte: bits 0-3 = CM (8 = deflate), bits 4-7 = CINFO (log2(windowSize) - 8).
  - `0x78` = CM=8, CINFO=7 → window = 2^15 = 32 KB.
  - `0x18` = CM=8, CINFO=1 → window = 2^9 = 512 B.
- `FLG` byte: chosen so `(CMF*256 + FLG) % 31 == 0` (RFC 1950 §2.2). Also
  encodes FLEVEL (bits 6-7); zlib uses FLEVEL=0 (fastest) for HUFFMAN_ONLY.
  - `0x01` → `(0x78*256 + 1) = 30721 = 31*991` ✓
  - `0x19` → `(0x18*256 + 0x19) = 6169 = 31*199` ✓
- Trailer: `20 5e 04 8a` = adler32 of `"Hello, world!"` in big-endian (`0x205E048A`).

**gzip wrapper bytes** (`1f 8b 08 00 00 00 00 00 04 13`):
- `1f 8b` = magic
- `08` = CM (deflate)
- `00` = FLG (no extras)
- `00 00 00 00` = MTIME (0 = unknown)
- `04` = XFL **(curious — XFL=4 means "fastest algorithm used", but level was 6)**.
  Likely zlib sets XFL=4 whenever strategy=HUFFMAN_ONLY regardless of level. Probe
  needed to confirm.
- `13` = OS **(0x13 = 19, not in RFC 1952's standard table)**. Likely platform-
  specific — this build is `nixpkgs-unstable` zlib 1.3.2 on macOS aarch64.
  Probe on Linux + verify OS_CODE source.
- Trailer (8 B): `e6 c6 e6 eb` = CRC32 little-endian + `0d 00 00 00` = ISIZE
  (uncompressed length mod 2^32) little-endian = 13. ✓

**Open questions on the gzip wrapper:**
1. Is XFL keyed off `level` only, or also `strategy`? Likely sensitive to both.
2. What is OS_CODE on Linux x86_64 / Linux aarch64 nixpkgs zlib? On Windows zlib?
   This may force per-OS gzip fingerprint entries — or we accept OS as a wildcard.

### zlib — HUFFMAN_ONLY on large random input (80 KB)
**Date:** 2026-05-21
**Probe:** `bench/probes/zlib_huffman_only_expanded.c` section C

80 KB of deterministic pseudorandom bytes (xorshift32 seeded `0xC0FFEE42`)
compressed to 81947 B (ratio 1.000). Slightly better than the per-byte
worst-case (8.4375 bits/byte expected for uniform random under fixed
Huffman), suggesting zlib emits multiple blocks and picks per-block the
cheaper of stored/fixed/(maybe dynamic). No `00 00 ff ff` SYNC_FLUSH marker
in the output, so no empty-stored-block separators. Multi-block walking
in the output, so no empty-stored-block separators. Multi-block walking
needed to characterize the boundary heuristic — filed as future probe.

### zlib — HUFFMAN_ONLY: full 3-way (FIXED/DYNAMIC/STORED) decision
**Date:** 2026-05-21
**Probe:** `bench/probes/zlib_huffman_only_breakpoint.c`
**Reference version:** zlib 1.3.2

Sweep n=1..32 of all-same-byte inputs under HUFFMAN_ONLY (Z_HUFFMAN_ONLY,
level=6, raw DEFLATE), observing the BTYPE zlib picks:

| Input              | FIXED for n ≤ | Then switches to |
|---                 |---            |---                |
| all-NUL (8-bit lit) | 11            | DYNAMIC (1 symbol → tiny tree) |
| all-'A' (8-bit lit) | 13            | DYNAMIC |
| all-0xFF (9-bit lit) | 10           | DYNAMIC |
| alt 'A'/0xFF (2 sym) | 13           | DYNAMIC |
| 0xC0..0xCF (16 distinct symbols) | — | STORED at n=16 (basic probe) |

**The actual zlib decision algorithm** (from `trees.c::_tr_flush_block`):

1. Build dynamic literal/length and distance Huffman trees from observed
   symbol frequencies. (HUFFMAN_ONLY means no LZ77 matches, so only literals
   0..255 + EOB 256 appear, and the distance tree has a single trivial
   symbol.)
2. Compute `opt_len` (bits used by dynamic encoding, *including* the tree
   description) and `static_len` (bits used by the RFC 1951 §3.2.6 fixed
   table). Convert to bytes:
   `opt_lenb = (opt_len + 3 + 7) >> 3`, `static_lenb = (static_len + 3 + 7) >> 3`.
3. If `static_lenb <= opt_lenb`: `opt_lenb := static_lenb` (fixed wins among
   the two Huffman options).
4. **Stored fallback:** if `stored_len + 4 <= opt_lenb` → emit STORED block.
5. **Fixed:** else if `strategy == Z_FIXED || static_lenb == opt_lenb` → emit FIXED.
6. **Dynamic:** else → emit DYNAMIC.

Key insight: the `+4` in step 4 omits the BTYPE+padding byte that an actual
stored block costs, so zlib *slightly under-counts* stored cost — but this
only triggers when stored is close to the Huffman cost. The main reason
inputs flip from FIXED to DYNAMIC (or to STORED) is the *Huffman cost
recomputation*, not the stored offset.

**Why FIXED for very small n, regardless of entropy:**
At small n, the dynamic-tree description (5+5+4 bit field counts + per-symbol
code-length codes + bit-length-tree codes) is itself ~30–150 bits — a fixed
overhead that exceeds the savings dynamic-tree gives over fixed for short
data. So zlib picks FIXED below some threshold and DYNAMIC above it. The
exact threshold depends on the symbol distribution.

**Why STORED for 16 *distinct* high-byte symbols (0xC0..0xCF):**
Many distinct symbols → dynamic tree is large (each non-zero code-length
entry must be encoded). For 16 distinct symbols at n=16 the dynamic tree
overhead alone exceeds the savings, AND fixed costs 16*9 + … bits, so neither
Huffman beats `n + 4` bytes of stored.

**Implication for `encodeZlibHuffmanOnly`:** the fingerprint must implement
the full 3-way comparison, which requires:
1. **Symbol frequency accumulation** over the input chunk.
2. **Dynamic Huffman tree construction** matching zlib's specific algorithm
   (canonical Huffman with zlib's tie-breaks; the heap-based `pqdownheap` in
   trees.c).
3. **Bit-length-tree (code-length code) construction** for the tree-of-trees
   encoding (RFC 1951 §3.2.7).
4. **The 3-way cost comparison** above, byte-for-byte equivalent to zlib's.
5. **Block-boundary placement** if the input exceeds the per-block buffer
   (default ~16 KB at memLevel=8) — probe #12 will characterize this.

Our existing `encodeFixedHuffmanLiterals` is **the correct primitive for step
5's FIXED branch**. It is, in itself, a partial zlib HUFFMAN_ONLY fingerprint
that recognizes inputs where zlib picks fixed (typically n ≤ 10..13 bytes,
depending on entropy). For *detection* purposes, a partial fingerprint is
still useful: the detector reads the first 3 bits and bails out if the block
type doesn't match. The full encoder is needed only for *reproduction*.

### zlib — level=0 (Z_NO_COMPRESSION): pure stored blocks ✅ implemented
**Date:** 2026-05-21
**Probe:** `bench/probes/zlib_level0_stored.c`
**Reference version:** zlib 1.3.2
**Encoder:** `src/encoder.zig::encodeZlibStored` — 6 tests, all green

zlib at level=0 emits one or more DEFLATE stored blocks. Each block:
- 1 header byte: bit 0 = BFINAL, bits 1-2 = BTYPE=00, bits 3-7 = zero padding
- 2 bytes: LE16 LEN
- 2 bytes: LE16 NLEN = bitwise complement of LEN
- LEN bytes of raw input data

Maximum block payload: 65535 bytes (max u16 LEN). Inputs longer than that
are split into ⌈len / 65535⌉ blocks chained — all but the last with
BFINAL=0, the last with BFINAL=1. Empty input still emits a single BFINAL=1
block with LEN=0 / NLEN=0xFFFF.

**Byte fixtures** (verified byte-exact against zlib 1.3.2):

| Input              | Bytes (5-byte header + data)                           | Total (B) |
|---                 |---                                                       |---         |
| `""`                 | `01 00 00 ff ff`                                       | 5          |
| `"A"`                | `01 01 00 fe ff 41`                                    | 6          |
| `"Hello, world!"`    | `01 0d 00 f2 ff` + 13 B of data                        | 18         |
| 0xC0..0xCF (16 B)    | `01 10 00 ef ff` + 16 B of data                        | 21         |
| 65535 B              | `01 ff ff 00 00` + 65535 B of data                     | 65540      |
| 65536 B              | `00 ff ff 00 00` + 65535 B + `01 01 00 fe ff` + 1 B    | 65546      |

**Knobs that don't affect output:** strategy (we used DEFAULT but RLE /
FIXED / HUFFMAN_ONLY all produce the same level=0 bytes), memLevel,
windowBits magnitude. Only windowBits sign affects wrapping.

**Implication:** this is the simplest non-trivial zlib fingerprint. The
encoder is ~30 lines; the corresponding fingerprint registry entry covers
`zlib level=0` across all (strategy, memLevel, windowBits magnitude)
combinations. First fingerprint to land in v0.1.

