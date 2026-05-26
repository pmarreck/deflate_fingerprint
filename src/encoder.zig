//! Parameterized DEFLATE encoder core.
//!
//! This file hosts the small, RFC-1951-spec primitives that compose into each
//! fingerprint we need to reproduce. Each primitive is a *pure* function of
//! its input — no I/O, no globals, no allocator-of-convenience tricks.
//!
//! Primitives so far:
//!   - encodeFixedHuffmanLiterals — single block, BTYPE=01, no LZ77 matches.
//!     This is the RFC 1951 §3.2.6 fixed-Huffman path with literals only.
//!     Used by zlib HUFFMAN_ONLY when its cost model picks fixed over stored
//!     (see docs/ENCODER_NOTES.md for the cost-model quirk).
//!
//! Higher-level fingerprint functions (e.g. encodeZlibHuffmanOnly) compose
//! these primitives plus the encoder's specific decision logic.

const std = @import("std");

const bitstream = @import("bitstream.zig");
const BitWriter = bitstream.BitWriter;
const reverseBits = bitstream.reverseBits;
const writeFixedLiteral = bitstream.writeFixedLiteral;
const writeFixedLengthCode = bitstream.writeFixedLengthCode;
const writeFixedDistanceCode = bitstream.writeFixedDistanceCode;

const huffman = @import("huffman.zig");
pub const buildHuffmanLengths = huffman.buildHuffmanLengths;
const computeCanonicalCodes = huffman.computeCanonicalCodes;
const scanCodeLengths = huffman.scanCodeLengths;
const sendCodeLengths = huffman.sendCodeLengths;
const BL_ORDER = huffman.BL_ORDER;

const inspect = @import("inspect.zig");

const match_mod = @import("match.zig");
pub const Token = match_mod.Token;
pub const Match = match_mod.Match;
pub const LZ77Params = match_mod.LZ77Params;
pub const LZ77_LEVEL_1 = match_mod.LZ77_LEVEL_1;
pub const LZ77_LEVEL_2 = match_mod.LZ77_LEVEL_2;
pub const LZ77_LEVEL_3 = match_mod.LZ77_LEVEL_3;
pub const LZ77_LEVEL_4 = match_mod.LZ77_LEVEL_4;
pub const LZ77_LEVEL_5 = match_mod.LZ77_LEVEL_5;
pub const LZ77_LEVEL_6 = match_mod.LZ77_LEVEL_6;
pub const LZ77_LEVEL_7 = match_mod.LZ77_LEVEL_7;
pub const LZ77_LEVEL_8 = match_mod.LZ77_LEVEL_8;
pub const LZ77_LEVEL_9 = match_mod.LZ77_LEVEL_9;
pub const LZ77_LEVEL_4_FILTERED = match_mod.LZ77_LEVEL_4_FILTERED;
pub const LZ77_LEVEL_5_FILTERED = match_mod.LZ77_LEVEL_5_FILTERED;
pub const LZ77_LEVEL_6_FILTERED = match_mod.LZ77_LEVEL_6_FILTERED;
pub const LZ77_LEVEL_7_FILTERED = match_mod.LZ77_LEVEL_7_FILTERED;
pub const LZ77_LEVEL_8_FILTERED = match_mod.LZ77_LEVEL_8_FILTERED;
pub const LZ77_LEVEL_9_FILTERED = match_mod.LZ77_LEVEL_9_FILTERED;
pub const lz77Tokenize = match_mod.lz77Tokenize;
pub const lz77TokenizeSlow = match_mod.lz77TokenizeSlow;
pub const lz77TokenizeRLE = match_mod.lz77TokenizeRLE;
pub const withMemLevel = match_mod.withMemLevel;

const blocks = @import("blocks.zig");
const lengthCode = blocks.lengthCode;
const distanceCode = blocks.distanceCode;
const staticTokenBitsCost = blocks.staticTokenBitsCost;
const tokenStreamRawLen = blocks.tokenStreamRawLen;
const reconstructFromTokens = blocks.reconstructFromTokens;
const emitStoredBlock = blocks.emitStoredBlock;
const emitFixedHuffmanFromTokensBlock = blocks.emitFixedHuffmanFromTokensBlock;
const emitDynamicHuffmanFromTokensBlock = blocks.emitDynamicHuffmanFromTokensBlock;
const encodeFixedHuffmanFromTokens = blocks.encodeFixedHuffmanFromTokens;
const encodeDynamicHuffmanFromTokens = blocks.encodeDynamicHuffmanFromTokens;
pub const encodeBlockFromTokens = blocks.encodeBlockFromTokens;
pub const encodeBlockFromTokensWithDynamic = blocks.encodeBlockFromTokensWithDynamic;
const emitBlockFromTokensWithDynamicInto = blocks.emitBlockFromTokensWithDynamicInto;
const encodeMultiBlock3Way = blocks.encodeMultiBlock3Way;
const encodeMultiBlock2Way = blocks.encodeMultiBlock2Way;
const encodeMultiBlock3WayChunked = blocks.encodeMultiBlock3WayChunked;
const encodeMultiBlock3WayChunkedFromRaw = blocks.encodeMultiBlock3WayChunkedFromRaw;
const encodeMultiBlock2WayChunkedFromRaw = blocks.encodeMultiBlock2WayChunkedFromRaw;
const chunkSymbolsForMemLevel = blocks.chunkSymbolsForMemLevel;

pub const TokenizationMode = enum {
    segmented,
    prefix_history,
};

pub const FinishMode = enum {
    empty_fixed_block,
};

pub const FlushEvent = extern struct {
    raw_offset: usize,
    empty_fixed_blocks_before: usize = 0,
    empty_stored_blocks: usize = 1,
};

pub const DeflateReproductionConfig = struct {
    params: LZ77Params,
    mem_level: u4 = 8,
    sync_flushes: []const FlushEvent = &.{},
    final_flush_empty_fixed_blocks_before: usize = 0,
    final_flush_empty_stored_blocks: usize = 0,
    /// Currently supported stream terminator: an empty BFINAL=1 fixed-Huffman
    /// block, matching DEFLATE streams that call finish after explicit flushes.
    finish_mode: FinishMode = .empty_fixed_block,
    tokenization_mode: TokenizationMode = .segmented,
};

/// Encode `raw` as a single DEFLATE block with BFINAL=1, BTYPE=01 (fixed
/// Huffman tables per RFC 1951 §3.2.6), containing only literal symbols
/// followed by the end-of-block symbol 256. No LZ77 match finding.
///
/// Output is raw DEFLATE bytes (no zlib / gzip wrapper). Caller owns the
/// returned slice and must free it via `allocator.free`.
pub fn encodeFixedHuffmanLiterals(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();
    try emitFixedHuffmanLiteralsBlock(&bw, raw, 1);
    return bw.toOwnedSlice();
}

/// Emit one BTYPE=01 (fixed Huffman) literals-only block into `bw` with the
/// given BFINAL bit. Caller manages bw lifecycle and may chain multiple
/// blocks (for multi-block streams beyond zlib's lit_bufsize-1 threshold).
fn emitFixedHuffmanLiteralsBlock(bw: *BitWriter, raw: []const u8, bfinal: u1) !void {
    // 3-bit DEFLATE block header, packed LSB-first:
    //   bit[0] = BFINAL
    //   bit[1..2] = BTYPE = 01 (fixed Huffman)
    const header: u32 = @as(u32, bfinal) | (@as(u32, 1) << 1);
    try bw.writeBits(header, 3);

    for (raw) |byte| {
        try writeFixedLiteral(bw, byte);
    }

    // End-of-block symbol 256 — fixed-Huffman 7-bit code 0000000.
    try bw.writeBits(0, 7);
}

// BitWriter, reverseBits, writeFixedLiteral, writeFixedLengthCode, and
// writeFixedDistanceCode live in src/bitstream.zig — see the imports at the
// top of this file.

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

// Ground truth captured from real zlib 1.3.2 via bench/probes/zlib_huffman_only.c.
// Inputs chosen so that zlib HUFFMAN_ONLY emits a fixed-Huffman block (not its
// STORED-block fallback — that path is exercised by a separate test once the
// zlib-level dispatch lands).

test "encodeFixedHuffmanLiterals: empty input -> 0x03 0x00 (just BFINAL+BTYPE+EOB)" {
    const got = try encodeFixedHuffmanLiterals(testing.allocator, "");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &.{ 0x03, 0x00 }, got);
}

test "encodeFixedHuffmanLiterals: single 'A' -> 0x73 0x04 0x00" {
    const got = try encodeFixedHuffmanLiterals(testing.allocator, "A");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &.{ 0x73, 0x04, 0x00 }, got);
}

test "encodeFixedHuffmanLiterals: 'AAAA' -> four 'A' literals" {
    const got = try encodeFixedHuffmanLiterals(testing.allocator, "AAAA");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &.{ 0x73, 0x74, 0x74, 0x74, 0x04, 0x00 }, got);
}

test "encodeFixedHuffmanLiterals: 'ABCDEFG' -> ascending literals" {
    const got = try encodeFixedHuffmanLiterals(testing.allocator, "ABCDEFG");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x73, 0x74, 0x72, 0x76, 0x71, 0x75, 0x73, 0x07, 0x00 },
        got,
    );
}

test "encodeFixedHuffmanLiterals: 'Hello, world!' -> zlib reference" {
    const got = try encodeFixedHuffmanLiterals(testing.allocator, "Hello, world!");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(
        u8,
        &.{ 0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0xd7, 0x51, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0x51, 0x04, 0x00 },
        got,
    );
}

test "encodeFixedHuffmanLiterals: 'AAAABBBBCCCCDDDD' -> mixed literals" {
    const got = try encodeFixedHuffmanLiterals(testing.allocator, "AAAABBBBCCCCDDDD");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x73, 0x74, 0x74, 0x74, 0x74, 0x72, 0x72, 0x72, 0x72, 0x76, 0x76, 0x76, 0x76, 0x71, 0x71, 0x71, 0x01, 0x00 },
        got,
    );
}

test "encodeFixedHuffmanLiterals: NUL bytes use the 8-bit branch" {
    // 1 NUL: 3-bit header + 8-bit code (00110000) + 7-bit EOB = 18 bits -> 3 B.
    const got1 = try encodeFixedHuffmanLiterals(testing.allocator, "\x00");
    defer testing.allocator.free(got1);
    try testing.expectEqualSlices(u8, &.{ 0x63, 0x00, 0x00 }, got1);

    // 4 NULs: 3 + 4*8 + 7 = 42 bits -> 6 B.
    const got4 = try encodeFixedHuffmanLiterals(testing.allocator, "\x00\x00\x00\x00");
    defer testing.allocator.free(got4);
    try testing.expectEqualSlices(u8, &.{ 0x63, 0x60, 0x60, 0x60, 0x00, 0x00 }, got4);
}

test "encodeFixedHuffmanLiterals: single 0xFF uses the 9-bit branch" {
    // 1 high-byte literal: 3-bit header + 9-bit code + 7-bit EOB = 19 bits -> 3 B.
    const got = try encodeFixedHuffmanLiterals(testing.allocator, "\xFF");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &.{ 0xfb, 0x0f, 0x00 }, got);
}

test "encodeFixedHuffmanLiterals: 0xFE,0xFF,0xFE,0xFF -> all 9-bit branch" {
    const got = try encodeFixedHuffmanLiterals(testing.allocator, "\xFE\xFF\xFE\xFF");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &.{ 0xfb, 0xf7, 0xff, 0xdf, 0x7f, 0x00 }, got);
}

// ─── encodeZlibStored ─────────────────────────────────────────────────────
//
// zlib at level=0 (Z_NO_COMPRESSION) emits one or more DEFLATE stored blocks:
// each block is 1 header byte (BFINAL bit + BTYPE=00 + 5 zero pad bits) + LE16
// LEN + LE16 NLEN + LEN raw input bytes. LEN is capped at 65535 (max u16), so
// inputs larger than 65535 bytes are split into multiple chained blocks. Only
// the final block has BFINAL=1.
//
// Empty input still emits one BFINAL=1 stored block with LEN=0.
//
// See docs/ENCODER_NOTES.md "zlib — level=0" and bench/probes/zlib_level0_stored.c.

/// Max LEN field value for a DEFLATE stored block (= 2^16 - 1).
pub const STORED_BLOCK_MAX_LEN: usize = 0xFFFF;

/// Encode `raw` as a sequence of DEFLATE stored blocks matching zlib at
/// level=0 / Z_NO_COMPRESSION. Output is raw DEFLATE (no zlib/gzip wrapper).
/// Caller owns the returned slice.
pub fn encodeZlibStored(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const block_overhead: usize = 5;
    const n_blocks: usize = if (raw.len == 0)
        1
    else
        (raw.len + STORED_BLOCK_MAX_LEN - 1) / STORED_BLOCK_MAX_LEN;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, raw.len + n_blocks * block_overhead);

    if (raw.len == 0) {
        // BFINAL=1, BTYPE=00, 5 padding bits = byte 0x01.
        try out.appendSlice(allocator, &.{ 0x01, 0x00, 0x00, 0xFF, 0xFF });
        return out.toOwnedSlice(allocator);
    }

    var offset: usize = 0;
    while (offset < raw.len) {
        const remaining = raw.len - offset;
        const chunk = @min(remaining, STORED_BLOCK_MAX_LEN);
        const bfinal: u8 = if (remaining == chunk) 1 else 0;
        // Header byte: low bit = BFINAL, next 2 bits = BTYPE=00, top 5 bits = pad zeros.
        try out.append(allocator, bfinal);
        // LEN (LE16) and NLEN (LE16) = ~LEN.
        try out.append(allocator, @truncate(chunk & 0xFF));
        try out.append(allocator, @truncate((chunk >> 8) & 0xFF));
        const nlen: u16 = ~@as(u16, @intCast(chunk));
        try out.append(allocator, @truncate(nlen & 0xFF));
        try out.append(allocator, @truncate((nlen >> 8) & 0xFF));
        try out.appendSlice(allocator, raw[offset .. offset + chunk]);
        offset += chunk;
    }
    return out.toOwnedSlice(allocator);
}

// emitStoredBlock lives in src/blocks.zig — imported at the top of this file.
// Ground truth fixtures captured from bench/probes/zlib_level0_stored.c

test "encodeZlibStored: empty -> single BFINAL=1 block with LEN=0" {
    const got = try encodeZlibStored(testing.allocator, "");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x00, 0xFF, 0xFF }, got);
}

test "encodeZlibStored: single 'A' -> 6 bytes" {
    const got = try encodeZlibStored(testing.allocator, "A");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x01, 0x00, 0xFE, 0xFF, 0x41 }, got);
}

test "encodeZlibStored: 'Hello, world!' -> 18 bytes" {
    const got = try encodeZlibStored(testing.allocator, "Hello, world!");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x01, 0x0d, 0x00, 0xf2, 0xff, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x2c, 0x20, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0x21 },
        got,
    );
}

test "encodeZlibStored: 0xC0..0xCF -> 21 bytes (the input that fooled my earlier model)" {
    const input = [_]u8{ 0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF };
    const got = try encodeZlibStored(testing.allocator, &input);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x01, 0x10, 0x00, 0xef, 0xff, 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xcb, 0xcc, 0xcd, 0xce, 0xcf },
        got,
    );
}

test "encodeZlibStored: 65535 B (max LEN) -> single block, 65540 B out" {
    const n: usize = 65535;
    const input = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(input);
    for (input, 0..) |*b, i| b.* = @truncate(i & 0xFF);

    const got = try encodeZlibStored(testing.allocator, input);
    defer testing.allocator.free(got);

    try testing.expectEqual(@as(usize, n + 5), got.len);
    // Header: BFINAL=1, BTYPE=00.
    try testing.expectEqual(@as(u8, 0x01), got[0]);
    // LEN = 65535, NLEN = 0x0000.
    try testing.expectEqual(@as(u8, 0xFF), got[1]);
    try testing.expectEqual(@as(u8, 0xFF), got[2]);
    try testing.expectEqual(@as(u8, 0x00), got[3]);
    try testing.expectEqual(@as(u8, 0x00), got[4]);
    try testing.expectEqualSlices(u8, input, got[5..]);
}

test "encodeZlibStored: 65536 B (max LEN + 1) -> 2 blocks" {
    const n: usize = 65536;
    const input = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(input);
    for (input, 0..) |*b, i| b.* = @truncate(i & 0xFF);

    const got = try encodeZlibStored(testing.allocator, input);
    defer testing.allocator.free(got);

    // Block 1: BFINAL=0 (more to come), LEN=65535, then 65535 bytes of data.
    try testing.expectEqual(@as(u8, 0x00), got[0]);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0x00, 0x00 }, got[1..5]);
    try testing.expectEqualSlices(u8, input[0..65535], got[5 .. 5 + 65535]);

    // Block 2 starts at offset 5 + 65535 = 65540.
    const b2 = got[65540..];
    // BFINAL=1, LEN=1, NLEN=0xFFFE, then the one remaining byte.
    try testing.expectEqual(@as(u8, 0x01), b2[0]);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0xFE, 0xFF }, b2[1..5]);
    try testing.expectEqual(input[65535], b2[5]);
    try testing.expectEqual(@as(usize, 65540 + 6), got.len);
}

// Phase A (Huffman tree builder + zlib's depth-aware tie-break), Phase B/C
// (canonical codes + scan_tree/send_tree RLE), and the bl_order/REP* constants
// all live in src/huffman.zig — see the imports at the top of this file.

/// Encode `raw` as a single DEFLATE BFINAL=1/BTYPE=10 (dynamic Huffman) block
/// containing only literals + EOB. No LZ77 matches. The literal Huffman tree
/// is built from `raw`'s symbol histogram + EOB; the distance tree gets the
/// RFC-required two dummy length-1 codes (since no matches exist). Output
/// matches zlib HUFFMAN_ONLY byte-for-byte for inputs where zlib picks
/// DYNAMIC over FIXED/STORED — see docs/ENCODER_NOTES.md.
pub fn encodeDynamicHuffmanLiterals(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();
    try emitDynamicHuffmanLiteralsBlock(&bw, allocator, raw, 1);
    return bw.toOwnedSlice();
}

/// Emit one BTYPE=10 (dynamic Huffman) literals-only block into `bw` with
/// the given BFINAL bit. Builds its own literal/distance/CL trees from the
/// chunk's histogram, then emits the tree-of-trees header + literal data + EOB.
fn emitDynamicHuffmanLiteralsBlock(
    bw: *BitWriter,
    allocator: std.mem.Allocator,
    raw: []const u8,
    bfinal: u1,
) !void {
    // 1. Literal/length frequencies. EOB (256) always emitted once.
    var lit_freq = [_]u16{0} ** 286;
    for (raw) |b| lit_freq[b] += 1;
    lit_freq[256] = 1;

    // 2. Build literal tree (Phase A).
    var lit_lens = [_]u8{0} ** 286;
    try buildHuffmanLengths(allocator, &lit_freq, 15, &lit_lens);

    // 3. Distance tree — all zero frequencies; Phase A's "at least 2 leaves"
    //    rule synthesizes two length-1 dummies at symbols 0 and 1.
    const dist_freq = [_]u16{0} ** 30;
    var dist_lens = [_]u8{0} ** 30;
    try buildHuffmanLengths(allocator, &dist_freq, 15, &dist_lens);

    // 4. Find max non-zero indices (clamped to mandatory minimums).
    var max_lit: usize = 256; // EOB always non-zero
    var i: usize = 285;
    while (i > 256) : (i -= 1) {
        if (lit_lens[i] != 0) {
            max_lit = i;
            break;
        }
    }
    var max_dist: usize = 0;
    var j: usize = 29;
    while (j > 0) : (j -= 1) {
        if (dist_lens[j] != 0) {
            max_dist = j;
            break;
        }
    }
    const hlit_count: usize = max_lit + 1; // 257..286
    const hdist_count: usize = max_dist + 1; // 1..30

    // 5. Scan lit+dist length sequences to build bl_freq.
    var bl_freq = [_]u16{0} ** 19;
    scanCodeLengths(&lit_lens, hlit_count, &bl_freq);
    scanCodeLengths(&dist_lens, hdist_count, &bl_freq);

    // 6. Build CL Huffman tree (max length 7 per RFC).
    var bl_lens = [_]u8{0} ** 19;
    try buildHuffmanLengths(allocator, &bl_freq, 7, &bl_lens);

    // 7. Find HCLEN.
    var hclen_count: usize = 4;
    var k: usize = 19;
    while (k > 4) : (k -= 1) {
        if (bl_lens[BL_ORDER[k - 1]] != 0) {
            hclen_count = k;
            break;
        }
    }

    // 8. Compute canonical codes.
    var bl_codes: [19]u32 = undefined;
    computeCanonicalCodes(&bl_lens, &bl_codes);
    var lit_codes: [286]u32 = undefined;
    computeCanonicalCodes(&lit_lens, &lit_codes);
    var dist_codes: [30]u32 = undefined;
    computeCanonicalCodes(&dist_lens, &dist_codes);

    // 9. Emit the block.
    // 3-bit header: BFINAL | (BTYPE=10 << 1).
    const header: u32 = @as(u32, bfinal) | (@as(u32, 2) << 1);
    try bw.writeBits(header, 3);

    try bw.writeBits(@intCast(hlit_count - 257), 5);
    try bw.writeBits(@intCast(hdist_count - 1), 5);
    try bw.writeBits(@intCast(hclen_count - 4), 4);

    var b: usize = 0;
    while (b < hclen_count) : (b += 1) {
        try bw.writeBits(bl_lens[BL_ORDER[b]], 3);
    }

    try sendCodeLengths(bw, &lit_lens, hlit_count, &bl_codes, &bl_lens);
    try sendCodeLengths(bw, &dist_lens, hdist_count, &bl_codes, &bl_lens);

    for (raw) |byte| {
        const code = lit_codes[byte];
        const nbits: u6 = @intCast(lit_lens[byte]);
        std.debug.assert(nbits != 0);
        try bw.writeBits(reverseBits(@intCast(code), nbits), nbits);
    }

    const eob_code = lit_codes[256];
    const eob_nbits: u6 = @intCast(lit_lens[256]);
    std.debug.assert(eob_nbits != 0);
    try bw.writeBits(reverseBits(@intCast(eob_code), eob_nbits), eob_nbits);
}

// ─── Phase B+C tests: byte-exact match vs zlib HUFFMAN_ONLY DYNAMIC ─────

test "encodeDynamicHuffmanLiterals: 'A' * 14 matches zlib byte-exact" {
    const input = "A" ** 14;
    const got = try encodeDynamicHuffmanLiterals(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x05, 0xc1, 0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x90, 0x36, 0xff, 0x53, 0x00, 0x00, 0x02 },
        got,
    );
}

test "encodeDynamicHuffmanLiterals: NUL * 12 matches zlib byte-exact" {
    const input = ("\x00") ** 12;
    const got = try encodeDynamicHuffmanLiterals(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x05, 0xc1, 0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0xff, 0xd5, 0x00, 0x80 },
        got,
    );
}

test "encodeDynamicHuffmanLiterals: 0xFF * 11 (9-bit-branch literal) matches zlib" {
    const input = "\xFF" ** 11;
    const got = try encodeDynamicHuffmanLiterals(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x05, 0xc1, 0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x90, 0xff, 0x6a, 0x00, 0x40 },
        got,
    );
}

test "encodeDynamicHuffmanLiterals: alt 'A'/0xFF * 14 (2 distinct lits) matches zlib" {
    var input: [14]u8 = undefined;
    for (&input, 0..) |*b, idx| b.* = if (idx & 1 == 1) 0xFF else 'A';
    const got = try encodeDynamicHuffmanLiterals(testing.allocator, &input);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x05, 0xc1, 0x01, 0x01, 0x00, 0x00, 0x00, 0x80, 0x90, 0x6d, 0xfd, 0x1f, 0x25, 0x92, 0x24, 0xc9 },
        got,
    );
}

// ─── Phase D: encodeZlibHuffmanOnly (3-way FIXED / DYNAMIC / STORED) ─────
//
// Full zlib HUFFMAN_ONLY fingerprint. Mirrors the decision in trees.c::
// _tr_flush_block, restricted to single-block inputs (≤ ~16 KB; multi-block
// boundary heuristic is probe #12 territory).
//
// The comparison uses zlib's *bit-level* formulas, not raw byte counts.
// This matters at sub-byte tie points — notably the 0xC0..0xCF case where
// stored is actually 21 B but zlib's `stored_len + 4 <= opt_lenb` test
// (which omits the BTYPE+padding header byte from the stored estimate)
// considers them tied and prefers STORED.
//
//   static_len_bits = sum over input bytes of fixed Huffman length
//                     + 7 for EOB (fixed code for symbol 256 is 7 bits)
//   static_lenb     = (static_len_bits + 3 + 7) >> 3      // bytes, with +3 BFINAL/BTYPE
//   opt_lenb        = byte length of the dynamic encoding (matches zlib's
//                     own formula since dynamic emits the same way zlib does)
//
//   opt_lenb := min(opt_lenb, static_lenb)                // fixed beats dynamic on tie
//   if (raw.len + 4) <= opt_lenb        -> STORED         // zlib's specific +4 estimate
//   else if static_lenb == opt_lenb     -> FIXED          // after step 1's tie collapse
//   else                                -> DYNAMIC

/// Encode `raw` as one or more DEFLATE blocks matching zlib HUFFMAN_ONLY.
/// Splits the input at zlib's lit_bufsize-1 (16383 at memLevel=8) symbol
/// boundary so each chunk is one block. Per chunk, runs the 3-way
/// FIXED / DYNAMIC / STORED cost-minimizing dispatch. Only the final block
/// has BFINAL=1; intermediate blocks have BFINAL=0 and share the BitWriter
/// so bits flow continuously (STORED chunks align to byte boundary first).
pub fn encodeZlibHuffmanOnly(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    // zlib's _tr_tally returns 1 when sym_next == sym_end = (lit_bufsize-1)*3,
    // i.e. after 16383 symbols at memLevel=8. For HUFFMAN_ONLY every byte is
    // one literal symbol, so the chunk boundary in bytes matches the symbol
    // boundary.
    const chunk_size: usize = 16383;

    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();

    if (raw.len == 0) {
        // Empty input: single FIXED block (matches existing primitive).
        try emitFixedHuffmanLiteralsBlock(&bw, raw, 1);
        return bw.toOwnedSlice();
    }

    var offset: usize = 0;
    while (offset < raw.len) {
        const remaining = raw.len - offset;
        const this_chunk = @min(chunk_size, remaining);
        const chunk = raw[offset .. offset + this_chunk];
        const is_last: u1 = if (offset + this_chunk == raw.len) 1 else 0;

        try emitHuffmanOnlyBestBlock(&bw, allocator, chunk, is_last);

        offset += this_chunk;
    }
    return bw.toOwnedSlice();
}

/// Pick the cheapest of FIXED / DYNAMIC / STORED for this chunk and emit it.
/// Mirrors zlib trees.c::_tr_flush_block's decision but reordered to avoid
/// emitting two blocks. We build the DYNAMIC candidate first (it's the only
/// branch whose byte cost requires actually constructing the trees), use its
/// byte length as opt_lenb, then pick the cheapest of all three.
fn emitHuffmanOnlyBestBlock(
    bw: *BitWriter,
    allocator: std.mem.Allocator,
    raw: []const u8,
    bfinal: u1,
) !void {
    // Static cost: 7 bits for EOB + 8 or 9 bits per literal, then +3+7 padding.
    var static_len_bits: u32 = 7;
    for (raw) |b| static_len_bits += if (b < 144) @as(u32, 8) else 9;
    const static_lenb: u32 = (static_len_bits + 3 + 7) >> 3;

    // Build the DYNAMIC candidate up-front into a scratch BitWriter so we can
    // measure its byte length, then either emit those bytes (if DYNAMIC wins)
    // or discard. We then pick the cheapest path.
    var dyn_bw = BitWriter.init(allocator);
    defer dyn_bw.deinit();
    try emitDynamicHuffmanLiteralsBlock(&dyn_bw, allocator, raw, bfinal);
    // The bit count of the dynamic block = bytes*8 - trailing_zero_pad. For
    // cost comparison we need the byte length (zlib's opt_lenb).
    // To get the bit length, we need bw state — but we used a fresh
    // dyn_bw so bit_count tells us how many bits of the LAST byte are unused.
    // dyn_bw.bytes contains complete bytes; bit_buf holds partial.
    // Total bytes = bytes.items.len + (1 if bit_count>0 else 0).
    const dyn_bytes_len: u32 = @intCast(dyn_bw.bytes.items.len + (if (dyn_bw.bit_count > 0) @as(usize, 1) else 0));
    var opt_lenb: u32 = dyn_bytes_len;
    if (static_lenb <= opt_lenb) opt_lenb = static_lenb;

    const stored_est: u32 = @intCast(raw.len + 4);

    if (stored_est <= opt_lenb) {
        try emitStoredBlock(bw, raw, bfinal);
        return;
    }
    if (static_lenb == opt_lenb) {
        try emitFixedHuffmanLiteralsBlock(bw, raw, bfinal);
        return;
    }
    // DYNAMIC wins. Re-emit into bw (we can't transplant dyn_bw's partial bits
    // across BitWriter boundaries — but emitting again with the same input
    // produces the same bytes deterministically and is the simplest correct
    // option. Tree construction is O(n) so the extra pass is negligible.)
    try emitDynamicHuffmanLiteralsBlock(bw, allocator, raw, bfinal);
}

// ─── Phase D tests: full HUFFMAN_ONLY fingerprint across the decision tree ─

test "encodeZlibHuffmanOnly: empty input -> FIXED (3-byte minimum, matches existing primitive)" {
    const got = try encodeZlibHuffmanOnly(testing.allocator, "");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &.{ 0x03, 0x00 }, got);
}

test "encodeZlibHuffmanOnly: small input -> FIXED branch (n=1, 8-bit literal)" {
    const got = try encodeZlibHuffmanOnly(testing.allocator, "A");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &.{ 0x73, 0x04, 0x00 }, got);
}

test "encodeZlibHuffmanOnly: 'Hello, world!' -> FIXED branch" {
    const got = try encodeZlibHuffmanOnly(testing.allocator, "Hello, world!");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(
        u8,
        &.{ 0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0xd7, 0x51, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0x51, 0x04, 0x00 },
        got,
    );
}

test "encodeZlibHuffmanOnly: 'A' * 14 -> DYNAMIC branch (zlib's actual choice)" {
    const input = "A" ** 14;
    const got = try encodeZlibHuffmanOnly(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x05, 0xc1, 0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x90, 0x36, 0xff, 0x53, 0x00, 0x00, 0x02 },
        got,
    );
}

test "encodeZlibHuffmanOnly: 0xC0..0xCF -> STORED branch (the surprise from the original probe)" {
    const input = [_]u8{ 0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF };
    const got = try encodeZlibHuffmanOnly(testing.allocator, &input);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x01, 0x10, 0x00, 0xef, 0xff, 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xcb, 0xcc, 0xcd, 0xce, 0xcf },
        got,
    );
}

test "encodeZlibHuffmanOnly: alternating 'A'/0xFF * 14 -> DYNAMIC branch" {
    var input: [14]u8 = undefined;
    for (&input, 0..) |*b, idx| b.* = if (idx & 1 == 1) 0xFF else 'A';
    const got = try encodeZlibHuffmanOnly(testing.allocator, &input);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x05, 0xc1, 0x01, 0x01, 0x00, 0x00, 0x00, 0x80, 0x90, 0x6d, 0xfd, 0x1f, 0x25, 0x92, 0x24, 0xc9 },
        got,
    );
}

// Token, Match, LZ77Params, lz77Tokenize, longestMatch all live in
// src/match.zig — see the imports at the top of this file.

// lengthCode, distanceCode, staticTokenBitsCost, tokenStreamRawLen,
// reconstructFromTokens, encodeFixedHuffmanFromTokens, encodeBlockFromTokens
// all live in src/blocks.zig — see the imports at the top of this file.

/// zlib level=1 DEFAULT_STRATEGY: LZ77-tokenize with `LZ77_LEVEL_1` params
/// then dispatch via the 3-way block-type cost comparison.
pub fn encodeZlibLevel1(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77Tokenize(allocator, raw, LZ77_LEVEL_1);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

fn encodeZlibFastMemLevel(
    allocator: std.mem.Allocator,
    raw: []const u8,
    params: LZ77Params,
    mem_level: u4,
) ![]u8 {
    const adjusted = withMemLevel(params, mem_level);
    const tokens = try lz77Tokenize(allocator, raw, adjusted);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, chunkSymbolsForMemLevel(mem_level));
}

fn encodeZlibSlowMemLevel(
    allocator: std.mem.Allocator,
    raw: []const u8,
    params: LZ77Params,
    mem_level: u4,
) ![]u8 {
    const adjusted = withMemLevel(params, mem_level);
    const tokens = try lz77TokenizeSlow(allocator, raw, adjusted);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, chunkSymbolsForMemLevel(mem_level));
}

pub fn encodeZlibLevel1Mem7(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return encodeZlibFastMemLevel(allocator, raw, LZ77_LEVEL_1, 7);
}

pub fn encodeZlibLevel2Mem7(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return encodeZlibFastMemLevel(allocator, raw, LZ77_LEVEL_2, 7);
}

pub fn encodeZlibLevel3Mem7(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return encodeZlibFastMemLevel(allocator, raw, LZ77_LEVEL_3, 7);
}

/// zlib level=6 with memLevel=7: smaller pending/hash buffers than the default
/// memLevel=8, observed in some embedded ZIP-family payloads.
pub fn encodeZlibLevel6Mem7(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return encodeZlibSlowMemLevel(allocator, raw, LZ77_LEVEL_6, 7);
}

/// zlib level=6 with memLevel=6: 4095-symbol pending-buffer cadence, useful
/// for reproducing small-buffer embedded DEFLATE streams.
pub fn encodeZlibLevel6Mem6(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return encodeZlibSlowMemLevel(allocator, raw, LZ77_LEVEL_6, 6);
}

/// zlib level=6 with memLevel=9: same lazy LZ77 parameters as normal L6, but
/// with a 32767-symbol pending buffer and the observed 15-bit hash cap.
pub fn encodeZlibLevel6Mem9(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return encodeZlibSlowMemLevel(allocator, raw, LZ77_LEVEL_6, 9);
}

// ─── Phase E tests ────────────────────────────────────────────────────────

test "encodeZlibLevel1: no-match cases match the fixed-Huffman literal path" {
    // 'A' — single literal, no match possible.
    {
        const got = try encodeZlibLevel1(testing.allocator, "A");
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, &.{ 0x73, 0x04, 0x00 }, got);
    }
    // 'ABC' — three literals, no repeat.
    {
        const got = try encodeZlibLevel1(testing.allocator, "ABC");
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, &.{ 0x73, 0x74, 0x72, 0x06, 0x00 }, got);
    }
    // 'Hello, world!' — 13 literals, no useful repeats.
    {
        const got = try encodeZlibLevel1(testing.allocator, "Hello, world!");
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(
            u8,
            &.{ 0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0xd7, 0x51, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0x51, 0x04, 0x00 },
            got,
        );
    }
}

test "encodeZlibLevel1: 'AAAA' emits 4 literals (NIL=0 quirk prevents matching position 0)" {
    const got = try encodeZlibLevel1(testing.allocator, "AAAA");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &.{ 0x73, 0x74, 0x74, 0x74, 0x04, 0x00 }, got);
}

test "encodeZlibLevel1: 'AAAAAAAA' emits 2 literals + match(6, dist=1) — RLE" {
    const got = try encodeZlibLevel1(testing.allocator, "AAAAAAAA");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &.{ 0x73, 0x74, 0x84, 0x00, 0x00 }, got);
}

test "encodeZlibLevel1: 'ABCABCABCABC' -> 4 literals + match(8, dist=3)" {
    const got = try encodeZlibLevel1(testing.allocator, "ABCABCABCABC");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &.{ 0x73, 0x74, 0x72, 0x76, 0x84, 0x21, 0x00 }, got);
}

test "encodeZlibLevel1: 'ABCABC' emits 6 literals (NIL=0 prevents matching the ABC at pos 0)" {
    const got = try encodeZlibLevel1(testing.allocator, "ABCABC");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &.{ 0x73, 0x74, 0x72, 0x76, 0x74, 0x72, 0x06, 0x00 }, got);
}

test "encodeZlibLevel1: 16x 'A' -> 2 literals + match(14, dist=1)" {
    const input = "A" ** 16;
    const got = try encodeZlibLevel1(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &.{ 0x73, 0x74, 0x44, 0x05, 0x00 }, got);
}

test "encodeZlibLevel1: prose input picks DYNAMIC Huffman like real zlib" {
    // First 80 bytes of README.md. At this size, zlib's deflate_fast cost
    // model picks DYNAMIC (BTYPE=10) over FIXED (BTYPE=01) because the
    // skewed literal frequency distribution makes a custom Huffman tree
    // cheaper than the static one, despite the tree-of-trees overhead.
    //
    // Captured via: head -c 80 README.md | gen_zlib_target ... 1 default
    const input =
        "# deflate_fingerprint\n\nIdentify which DEFLATE encoder implementation produced a ";
    const expected = [_]u8{
        0x0d, 0xca, 0x41, 0x0a, 0x80, 0x20, 0x10, 0x05, 0xd0, 0xbd, 0xa7, 0x18,
        0xe8, 0x24, 0x41, 0x06, 0x41, 0xcb, 0xf6, 0x21, 0xce, 0x37, 0x07, 0x74,
        0x14, 0x99, 0x88, 0x6e, 0x5f, 0x6f, 0xfd, 0x26, 0x62, 0xa4, 0x12, 0x0c,
        0x67, 0x12, 0xbd, 0x30, 0xfa, 0x10, 0x35, 0xe7, 0x36, 0x86, 0x9a, 0xa4,
        0x97, 0x9e, 0x2c, 0x31, 0xd3, 0xe2, 0xd7, 0x7d, 0x3e, 0x3c, 0x41, 0x63,
        0x63, 0x0c, 0x92, 0xda, 0x0b, 0xea, 0x5f, 0x82, 0x49, 0x53, 0xea, 0xa3,
        0xf1, 0x1d, 0xc1, 0x14, 0xe8, 0x03,
    };
    try testing.expectEqual(@as(usize, 80), input.len);
    const got = try encodeZlibLevel1(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &expected, got);
}

test "encodeZlibLevel1Mem7 matches real zlib with memLevel=7 on multi-block literal-heavy input" {
    const fidelity = @import("fidelity.zig");
    const input = try testing.allocator.alloc(u8, 20_000);
    defer testing.allocator.free(input);
    var x: u32 = 0x1234_5678;
    for (input) |*b| {
        x = x *% 1664525 +% 1013904223;
        b.* = @truncate(x >> 24);
    }

    const got = try encodeZlibLevel1Mem7(testing.allocator, input);
    defer testing.allocator.free(got);
    const expected = try fidelity.compressWithZlibMemLevel(testing.allocator, input, 1, .default, 7);
    defer testing.allocator.free(expected);
    try testing.expectEqualSlices(u8, expected, got);
}

test "encodeZlibLevel2/3Mem7 match real zlib with memLevel=7 on multi-block input" {
    const fidelity = @import("fidelity.zig");
    const input = try testing.allocator.alloc(u8, 20_000);
    defer testing.allocator.free(input);
    var x: u32 = 0x8765_4321;
    for (input) |*b| {
        x = x *% 1103515245 +% 12345;
        b.* = @truncate(x >> 23);
    }

    {
        const got = try encodeZlibLevel2Mem7(testing.allocator, input);
        defer testing.allocator.free(got);
        const expected = try fidelity.compressWithZlibMemLevel(testing.allocator, input, 2, .default, 7);
        defer testing.allocator.free(expected);
        try testing.expectEqualSlices(u8, expected, got);
    }
    {
        const got = try encodeZlibLevel3Mem7(testing.allocator, input);
        defer testing.allocator.free(got);
        const expected = try fidelity.compressWithZlibMemLevel(testing.allocator, input, 3, .default, 7);
        defer testing.allocator.free(expected);
        try testing.expectEqualSlices(u8, expected, got);
    }
}

test "encodeZlibLevel6 matches real zlib memLevel=8 on incompressible multi-block input" {
    const fidelity = @import("fidelity.zig");
    const input = try testing.allocator.alloc(u8, 80_000);
    defer testing.allocator.free(input);
    var x: u32 = 0x1234_5678;
    for (input) |*b| {
        x = x *% 1664525 +% 1013904223;
        b.* = @truncate(x >> 24);
    }

    const got = try encodeZlibLevel6(testing.allocator, input);
    defer testing.allocator.free(got);
    const expected = try fidelity.compressWithZlibMemLevel(testing.allocator, input, 6, .default, 8);
    defer testing.allocator.free(expected);
    try testing.expectEqualSlices(u8, expected, got);
}

test "encodeZlibLevel6Mem9 matches real zlib memLevel=9 on incompressible multi-block input" {
    const fidelity = @import("fidelity.zig");
    const input = try testing.allocator.alloc(u8, 80_000);
    defer testing.allocator.free(input);
    var x: u32 = 0x1234_5678;
    for (input) |*b| {
        x = x *% 1664525 +% 1013904223;
        b.* = @truncate(x >> 24);
    }

    const got = try encodeZlibLevel6Mem9(testing.allocator, input);
    defer testing.allocator.free(got);
    const expected = try fidelity.compressWithZlibMemLevel(testing.allocator, input, 6, .default, 9);
    defer testing.allocator.free(expected);
    try testing.expectEqualSlices(u8, expected, got);
}

test "encodeZlibLevel6Mem7 matches real zlib memLevel=7 on incompressible multi-block input" {
    const fidelity = @import("fidelity.zig");
    const input = try testing.allocator.alloc(u8, 80_000);
    defer testing.allocator.free(input);
    var x: u32 = 0x1234_5678;
    for (input) |*b| {
        x = x *% 1664525 +% 1013904223;
        b.* = @truncate(x >> 24);
    }

    const got = try encodeZlibLevel6Mem7(testing.allocator, input);
    defer testing.allocator.free(got);
    const expected = try fidelity.compressWithZlibMemLevel(testing.allocator, input, 6, .default, 7);
    defer testing.allocator.free(expected);
    try testing.expectEqualSlices(u8, expected, got);
}

test "encodeZlibLevel6Mem6 matches real zlib memLevel=6 on incompressible multi-block input" {
    const fidelity = @import("fidelity.zig");
    const input = try testing.allocator.alloc(u8, 80_000);
    defer testing.allocator.free(input);
    var x: u32 = 0x1234_5678;
    for (input) |*b| {
        x = x *% 1664525 +% 1013904223;
        b.* = @truncate(x >> 24);
    }

    const got = try encodeZlibLevel6Mem6(testing.allocator, input);
    defer testing.allocator.free(got);
    const expected = try fidelity.compressWithZlibMemLevel(testing.allocator, input, 6, .default, 6);
    defer testing.allocator.free(expected);
    try testing.expectEqualSlices(u8, expected, got);
}

// Token-side dispatchers + emit primitives (encodeBlockFromTokensWithDynamic,
// emitDynamicHuffmanFromTokensBlock, etc.) live in src/blocks.zig — see the
// imports at the top of this file.

// LZ77_LEVEL_* params, lz77Tokenize, lz77TokenizeSlow, lz77TokenizeRLE, and
// longestMatch all live in src/match.zig — see the imports at the top of this file.

// Level wrappers — each picks the appropriate LZ77 tokenizer (greedy
// `deflate_fast` for L1-3, lazy `deflate_slow` for L4-9) and runs the
// resulting tokens through the 3-way Huffman block-type dispatch.

pub fn encodeZlibLevel2(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77Tokenize(allocator, raw, LZ77_LEVEL_2);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel3(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77Tokenize(allocator, raw, LZ77_LEVEL_3);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel4(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_4);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel5(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_5);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

/// zlib level=6 DEFAULT_STRATEGY: lazy LZ77 (chain depth 128, lazy threshold 16)
/// + 3-way Huffman dispatch. The most-common zlib config in real-world archives.
pub fn encodeZlibLevel6(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_6);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel7(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_7);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel8(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_8);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

/// zlib level=9: deepest chain (4096), lazy threshold 258 (always lazy).
pub fn encodeZlibLevel9(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_9);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

// ─── Z_FILTERED strategy: reject matches with length <= 5 (deflate_slow). ──

pub fn encodeZlibLevel4Filtered(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_4_FILTERED);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel5Filtered(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_5_FILTERED);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel6Filtered(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_6_FILTERED);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel7Filtered(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_7_FILTERED);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel8Filtered(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_8_FILTERED);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel9Filtered(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_9_FILTERED);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

/// zlib Z_RLE strategy (any level 1-9). Tokens are produced by RLE-only
/// match finding, then encoded via the standard 3-way Huffman dispatcher.
/// Multi-block: splits the token stream at zlib's lit_bufsize-1 (16383 at
/// memLevel=8) symbol boundary so each block is one chunk. BFINAL=1 on the
/// last block; intermediate blocks share the BitWriter.
pub fn encodeZlibRLE(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeRLE(allocator, raw);
    defer allocator.free(tokens);
    return encodeMultiBlock3WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

// ─── Flush/finish-compatible DEFLATE encoder ──────────────────────────────
//
// Some producer APIs expose flush and finish as separate operations. One common
// resulting stream shape wraps zlib-compatible data blocks with this pattern:
//
//   <data block, BFINAL=0, BTYPE=10 DYNAMIC or 01 FIXED>
//   <SYNC_FLUSH marker: empty BFINAL=0 STORED block>   = 5 bytes "00 00 00 ff ff"
//                                                        (or 4 bytes "00 00 ff ff"
//                                                        if the data block already
//                                                        ended at a byte boundary)
//   <FINISH: empty BFINAL=1 FIXED block>                = 2 bytes "03 00"
//
/// Registered v0.1 behavior: zlib level-1 default data followed by explicit
/// flush and finish markers. Prefer `encodeConfiguredDeflate` for new callers.
pub fn encodeZlibLevel1FlushFinish(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return encodeFlushFinishChunked(allocator, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

fn encodeFlushFinishChunked(allocator: std.mem.Allocator, raw: []const u8, chunk_symbols: usize) ![]u8 {
    const tokens = try lz77Tokenize(allocator, raw, LZ77_LEVEL_1);
    defer allocator.free(tokens);

    return encodeFlushFinishFromTokens(allocator, raw, tokens, chunk_symbols, &.{}, 1);
}

fn tokenRawLen(token: Token) usize {
    return switch (token) {
        .literal => 1,
        .match => |m| m.length,
    };
}

fn writeEmptyStoredBlocks(bw: *BitWriter, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try emitStoredBlock(bw, &.{}, 0);
    }
}

fn writeEmptyFixedBlocks(bw: *BitWriter, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try emitFixedHuffmanFromTokensBlock(bw, &.{}, 0);
    }
}

fn writeFlushEvent(bw: *BitWriter, flush: FlushEvent) !void {
    try writeEmptyFixedBlocks(bw, flush.empty_fixed_blocks_before);
    try writeEmptyStoredBlocks(bw, flush.empty_stored_blocks);
}

fn encodeFlushFinishFromTokens(
    allocator: std.mem.Allocator,
    raw: []const u8,
    tokens: []const Token,
    chunk_symbols: usize,
    flushes: []const FlushEvent,
    final_flush_count: usize,
) ![]u8 {
    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();

    var i: usize = 0;
    var raw_pos: usize = 0;
    var next_flush_index: usize = 0;
    while (i < tokens.len) {
        while (next_flush_index < flushes.len and flushes[next_flush_index].raw_offset <= raw_pos) : (next_flush_index += 1) {
            if (flushes[next_flush_index].raw_offset == raw_pos) try writeFlushEvent(&bw, flushes[next_flush_index]);
        }

        const next_flush = if (next_flush_index < flushes.len) flushes[next_flush_index].raw_offset else raw.len;
        const start_i = i;
        const start_raw = raw_pos;
        var symbols: usize = 0;
        while (i < tokens.len and symbols < chunk_symbols) {
            const len = tokenRawLen(tokens[i]);
            if (raw_pos < next_flush and raw_pos + len > next_flush and i != start_i) break;
            raw_pos += len;
            i += 1;
            symbols += 1;
            if (raw_pos >= next_flush) break;
        }

        if (i == start_i) {
            const len = tokenRawLen(tokens[i]);
            raw_pos += len;
            i += 1;
        }

        try blocks.emitBlockFromTokensWithDynamicIntoRaw(&bw, allocator, tokens[start_i..i], raw[start_raw..raw_pos], 0);
    }
    while (next_flush_index < flushes.len) : (next_flush_index += 1) {
        if (flushes[next_flush_index].raw_offset == raw_pos) try writeFlushEvent(&bw, flushes[next_flush_index]);
    }
    std.debug.assert(raw_pos == raw.len);
    // (Empty input: no data blocks emitted; SYNC_FLUSH + FINISH alone produce
    // valid DEFLATE that inflates to nothing.)
    // SYNC_FLUSH: empty BFINAL=0 STORED block (byte-aligns + 00 00 ff ff).
    try writeEmptyStoredBlocks(&bw, final_flush_count);
    // FINISH: empty BFINAL=1 FIXED block (3-bit header + 7-bit EOB).
    try emitFixedHuffmanFromTokensBlock(&bw, &.{}, 1);

    return bw.toOwnedSlice();
}

fn emitChunkedTokenBlocks(
    bw: *BitWriter,
    allocator: std.mem.Allocator,
    raw: []const u8,
    params: LZ77Params,
    chunk_symbols: usize,
) !void {
    const tokens = try lz77Tokenize(allocator, raw, params);
    defer allocator.free(tokens);

    var i: usize = 0;
    var raw_pos: usize = 0;
    while (i < tokens.len) {
        const end = @min(i + chunk_symbols, tokens.len);
        const raw_end = raw_pos + tokenStreamRawLen(tokens[i..end]);
        try blocks.emitBlockFromTokensWithDynamicIntoRaw(&bw.*, allocator, tokens[i..end], raw[raw_pos..raw_end], 0);
        raw_pos = raw_end;
        i = end;
    }
    std.debug.assert(raw_pos == raw.len);
}

fn tokenIndexAtRawOffset(tokens: []const Token, offset: usize) ?usize {
    var raw_pos: usize = 0;
    for (tokens, 0..) |token, i| {
        if (raw_pos == offset) return i;
        raw_pos += tokenRawLen(token);
        if (raw_pos > offset) return null;
    }
    return if (raw_pos == offset) tokens.len else null;
}

fn emitChunkedTokenBlocksFromPrefix(
    bw: *BitWriter,
    allocator: std.mem.Allocator,
    raw: []const u8,
    segment_start: usize,
    segment_end: usize,
    params: LZ77Params,
    chunk_symbols: usize,
) !void {
    const tokens = try lz77Tokenize(allocator, raw[0..segment_end], params);
    defer allocator.free(tokens);

    var i = tokenIndexAtRawOffset(tokens, segment_start) orelse return error.FlushBoundaryInsideToken;
    const stop = tokenIndexAtRawOffset(tokens, segment_end) orelse return error.FlushBoundaryInsideToken;
    var raw_pos = segment_start;
    while (i < stop) {
        const end = @min(i + chunk_symbols, stop);
        const raw_end = raw_pos + tokenStreamRawLen(tokens[i..end]);
        try blocks.emitBlockFromTokensWithDynamicIntoRaw(&bw.*, allocator, tokens[i..end], raw[raw_pos..raw_end], 0);
        raw_pos = raw_end;
        i = end;
    }
    std.debug.assert(raw_pos == segment_end);
}

fn encodeSegmentedConfiguredDeflate(
    allocator: std.mem.Allocator,
    raw: []const u8,
    params: LZ77Params,
    mem_level: u4,
    flushes: []const FlushEvent,
    final_flush_fixed_before_count: usize,
    final_flush_count: usize,
) ![]u8 {
    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();

    const adjusted = withMemLevel(params, mem_level);
    const chunk_symbols = chunkSymbolsForMemLevel(mem_level);
    var segment_start: usize = 0;
    for (flushes) |flush| {
        const flush_offset = flush.raw_offset;
        if (flush_offset < segment_start or flush_offset > raw.len) continue;
        try emitChunkedTokenBlocks(&bw, allocator, raw[segment_start..flush_offset], adjusted, chunk_symbols);
        try writeFlushEvent(&bw, flush);
        segment_start = flush_offset;
    }

    try emitChunkedTokenBlocks(&bw, allocator, raw[segment_start..], adjusted, chunk_symbols);
    try writeEmptyFixedBlocks(&bw, final_flush_fixed_before_count);
    try writeEmptyStoredBlocks(&bw, final_flush_count);
    try emitFixedHuffmanFromTokensBlock(&bw, &.{}, 1);

    return bw.toOwnedSlice();
}

fn encodePrefixHistoryConfiguredDeflate(
    allocator: std.mem.Allocator,
    raw: []const u8,
    params: LZ77Params,
    mem_level: u4,
    flushes: []const FlushEvent,
    final_flush_fixed_before_count: usize,
    final_flush_count: usize,
) ![]u8 {
    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();

    const adjusted = withMemLevel(params, mem_level);
    const chunk_symbols = chunkSymbolsForMemLevel(mem_level);
    var segment_start: usize = 0;
    for (flushes) |flush| {
        const flush_offset = flush.raw_offset;
        if (flush_offset < segment_start or flush_offset > raw.len) continue;
        emitChunkedTokenBlocksFromPrefix(&bw, allocator, raw, segment_start, flush_offset, adjusted, chunk_symbols) catch |err| switch (err) {
            error.FlushBoundaryInsideToken => try emitChunkedTokenBlocks(&bw, allocator, raw[segment_start..flush_offset], adjusted, chunk_symbols),
            else => |e| return e,
        };
        try writeFlushEvent(&bw, flush);
        segment_start = flush_offset;
    }

    emitChunkedTokenBlocksFromPrefix(&bw, allocator, raw, segment_start, raw.len, adjusted, chunk_symbols) catch |err| switch (err) {
        error.FlushBoundaryInsideToken => try emitChunkedTokenBlocks(&bw, allocator, raw[segment_start..], adjusted, chunk_symbols),
        else => |e| return e,
    };
    try writeEmptyFixedBlocks(&bw, final_flush_fixed_before_count);
    try writeEmptyStoredBlocks(&bw, final_flush_count);
    try emitFixedHuffmanFromTokensBlock(&bw, &.{}, 1);

    return bw.toOwnedSlice();
}

/// Encode raw RFC 1951 DEFLATE from an explicit reproduction configuration.
/// Flush behavior is modeled as raw offsets; format-specific code lives outside.
pub fn encodeConfiguredDeflate(
    allocator: std.mem.Allocator,
    raw: []const u8,
    config: DeflateReproductionConfig,
) ![]u8 {
    switch (config.finish_mode) {
        .empty_fixed_block => {},
    }

    return switch (config.tokenization_mode) {
        .segmented => encodeSegmentedConfiguredDeflate(
            allocator,
            raw,
            config.params,
            config.mem_level,
            config.sync_flushes,
            config.final_flush_empty_fixed_blocks_before,
            config.final_flush_empty_stored_blocks,
        ),
        .prefix_history => encodePrefixHistoryConfiguredDeflate(
            allocator,
            raw,
            config.params,
            config.mem_level,
            config.sync_flushes,
            config.final_flush_empty_fixed_blocks_before,
            config.final_flush_empty_stored_blocks,
        ),
    };
}

test "flush-finish chunking tolerates matches that reference prior chunks" {
    const got = try encodeFlushFinishChunked(testing.allocator, "XABCABC", 4);
    defer testing.allocator.free(got);
    try testing.expect(got.len > 0);
}

test "encodeConfiguredDeflate emits configured raw-offset sync flush markers" {
    const raw = "alpha beta alpha beta";
    const flushes = [_]FlushEvent{.{ .raw_offset = 6, .empty_stored_blocks = 2 }};
    const got = try encodeConfiguredDeflate(testing.allocator, raw, .{
        .params = LZ77_LEVEL_1,
        .mem_level = 7,
        .sync_flushes = &flushes,
        .final_flush_empty_stored_blocks = 1,
        .tokenization_mode = .segmented,
    });
    defer testing.allocator.free(got);

    const blocks_seen = try inspect.inspectBlocks(testing.allocator, got);
    defer testing.allocator.free(blocks_seen);

    var configured_flushes: usize = 0;
    var final_flushes: usize = 0;
    for (blocks_seen) |block| {
        if (block.block_type != .stored or block.raw_start != block.raw_end) continue;
        if (block.raw_start == flushes[0].raw_offset) configured_flushes += 1;
        if (block.raw_start == raw.len) final_flushes += 1;
    }

    try testing.expectEqual(@as(usize, 2), configured_flushes);
    try testing.expectEqual(@as(usize, 1), final_flushes);
}

test "encodeConfiguredDeflate supports per-offset empty stored counts" {
    const raw = "alpha beta gamma delta";
    const flushes = [_]FlushEvent{
        .{ .raw_offset = 6, .empty_stored_blocks = 1 },
        .{ .raw_offset = 11, .empty_stored_blocks = 3 },
    };
    const got = try encodeConfiguredDeflate(testing.allocator, raw, .{
        .params = LZ77_LEVEL_1,
        .mem_level = 7,
        .sync_flushes = &flushes,
        .final_flush_empty_stored_blocks = 0,
        .tokenization_mode = .segmented,
    });
    defer testing.allocator.free(got);

    const blocks_seen = try inspect.inspectBlocks(testing.allocator, got);
    defer testing.allocator.free(blocks_seen);

    var first_count: usize = 0;
    var second_count: usize = 0;
    for (blocks_seen) |block| {
        if (block.block_type != .stored or block.raw_start != block.raw_end) continue;
        if (block.raw_start == flushes[0].raw_offset) first_count += 1;
        if (block.raw_start == flushes[1].raw_offset) second_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), first_count);
    try testing.expectEqual(@as(usize, 3), second_count);
}

test "encodeConfiguredDeflate supports empty fixed markers before stored flushes" {
    const raw = "alpha beta gamma";
    const flushes = [_]FlushEvent{.{
        .raw_offset = 6,
        .empty_fixed_blocks_before = 1,
        .empty_stored_blocks = 1,
    }};
    const got = try encodeConfiguredDeflate(testing.allocator, raw, .{
        .params = LZ77_LEVEL_1,
        .mem_level = 7,
        .sync_flushes = &flushes,
        .final_flush_empty_fixed_blocks_before = 1,
        .final_flush_empty_stored_blocks = 1,
        .tokenization_mode = .segmented,
    });
    defer testing.allocator.free(got);

    const blocks_seen = try inspect.inspectBlocks(testing.allocator, got);
    defer testing.allocator.free(blocks_seen);

    var sync_fixed: usize = 0;
    var sync_stored: usize = 0;
    var final_fixed_before: usize = 0;
    var final_stored: usize = 0;
    var final_finish: usize = 0;
    for (blocks_seen) |block| {
        if (block.raw_start != block.raw_end or block.token_count != 0) continue;
        if (block.raw_start == flushes[0].raw_offset and block.block_type == .fixed and !block.bfinal) sync_fixed += 1;
        if (block.raw_start == flushes[0].raw_offset and block.block_type == .stored) sync_stored += 1;
        if (block.raw_start == raw.len and block.block_type == .fixed and !block.bfinal) final_fixed_before += 1;
        if (block.raw_start == raw.len and block.block_type == .stored) final_stored += 1;
        if (block.raw_start == raw.len and block.block_type == .fixed and block.bfinal) final_finish += 1;
    }

    try testing.expectEqual(@as(usize, 1), sync_fixed);
    try testing.expectEqual(@as(usize, 1), sync_stored);
    try testing.expectEqual(@as(usize, 1), final_fixed_before);
    try testing.expectEqual(@as(usize, 1), final_stored);
    try testing.expectEqual(@as(usize, 1), final_finish);
}

// ─── Phase F debug tests ──────────────────────────────────────────────────

test "encodeZlibLevel6: 'longish' input matches zlib L6 byte-exact (DIAGNOSTIC)" {
    const input = "The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox.";
    const got = try encodeZlibLevel6(testing.allocator, input);
    defer testing.allocator.free(got);
    // Ground truth captured from real zlib 1.3.2 level=6, raw DEFLATE.
    const expected = [_]u8{
        0x0b, 0xc9, 0x48, 0x55, 0x28, 0x2c, 0xcd, 0x4c, 0xce, 0x56, 0x48, 0x2a, 0xca, 0x2f, 0xcf, 0x53,
        0x48, 0xcb, 0xaf, 0x50, 0xc8, 0x2a, 0xcd, 0x2d, 0x28, 0x56, 0xc8, 0x2f, 0x4b, 0x2d, 0x52, 0x28,
        0x01, 0x4a, 0xe7, 0x24, 0x56, 0x55, 0x2a, 0xa4, 0xe4, 0xa7, 0xeb, 0x29, 0x84, 0x50, 0xa8, 0x58,
        0x0f, 0x00,
    };
    try testing.expectEqualSlices(u8, &expected, got);
}

// ─── Phase H: Z_FIXED strategy fingerprints ───────────────────────────────
//
// Z_FIXED forces BTYPE=01 (fixed Huffman) for every block. STORED can still
// win when (stored_len + 4) is small enough. zlib's exact rule:
//   opt_lenb = min(static_lenb, dyn_lenb)
//   if stored_len + 4 <= opt_lenb -> STORED, else FIXED
//
// We approximate using static_lenb only (skipping dyn_lenb computation). This
// can diverge in the narrow case where dyn_lenb < stored_est <= static_lenb,
// i.e. small inputs where DYNAMIC would beat STORED beats FIXED. Real-world
// inputs rarely hit this case; if corpus shows it, replace `encodeBlockFromTokens`
// here with a Z_FIXED-specific dispatcher that computes dyn_lenb.

pub fn encodeZlibLevel1Fixed(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77Tokenize(allocator, raw, LZ77_LEVEL_1);
    defer allocator.free(tokens);
    return encodeMultiBlock2WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel2Fixed(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77Tokenize(allocator, raw, LZ77_LEVEL_2);
    defer allocator.free(tokens);
    return encodeMultiBlock2WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel3Fixed(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77Tokenize(allocator, raw, LZ77_LEVEL_3);
    defer allocator.free(tokens);
    return encodeMultiBlock2WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel4Fixed(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_4);
    defer allocator.free(tokens);
    return encodeMultiBlock2WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel5Fixed(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_5);
    defer allocator.free(tokens);
    return encodeMultiBlock2WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel6Fixed(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_6);
    defer allocator.free(tokens);
    return encodeMultiBlock2WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel7Fixed(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_7);
    defer allocator.free(tokens);
    return encodeMultiBlock2WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel8Fixed(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_8);
    defer allocator.free(tokens);
    return encodeMultiBlock2WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeZlibLevel9Fixed(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const tokens = try lz77TokenizeSlow(allocator, raw, LZ77_LEVEL_9);
    defer allocator.free(tokens);
    return encodeMultiBlock2WayChunkedFromRaw(allocator, tokens, raw, blocks.MULTI_BLOCK_CHUNK_SYMBOLS);
}

test "encodeZlibLevel1Fixed: 80B prose matches zlib Z_FIXED byte-exact" {
    const input =
        "# deflate_fingerprint\n\nIdentify which DEFLATE encoder implementation produced a ";
    const expected = [_]u8{
        0x53, 0x56, 0x48, 0x49, 0x4d, 0xcb, 0x49, 0x2c, 0x49, 0x8d, 0x4f, 0xcb,
        0xcc, 0x4b, 0x4f, 0x2d, 0x2a, 0x28, 0xca, 0xcc, 0x2b, 0xe1, 0xe2, 0xf2,
        0x4c, 0x49, 0xcd, 0x2b, 0xc9, 0x4c, 0xab, 0x54, 0x28, 0xcf, 0xc8, 0x4c,
        0xce, 0x50, 0x70, 0x71, 0x75, 0xf3, 0x71, 0x0c, 0x71, 0x55, 0x48, 0xcd,
        0x4b, 0xce, 0x4f, 0x49, 0x2d, 0x52, 0xc8, 0xcc, 0x2d, 0xc8, 0x49, 0xcd,
        0x05, 0x2a, 0x49, 0x2c, 0xc9, 0xcc, 0xcf, 0x53, 0x28, 0x28, 0xca, 0x4f,
        0x29, 0x4d, 0x4e, 0x4d, 0x51, 0x48, 0x54, 0x00, 0x00,
    };
    const got = try encodeZlibLevel1Fixed(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &expected, got);
}

test "LZ77_LEVEL_2 and LZ77_LEVEL_3 max_lazy_match match zlib config table" {
    // zlib's configuration_table (deflate.c): the `lazy_match` field acts as
    // `max_insert_length` for deflate_fast (levels 1-3), controlling whether
    // intermediate hash-chain positions are inserted for short matches.
    //   L1: lazy=4   L2: lazy=5   L3: lazy=6
    // Setting it to 0 (the historical bug) means matches never trigger hash
    // insertion, breaking subsequent match-finding and diverging from zlib.
    try testing.expectEqual(@as(u16, 4), LZ77_LEVEL_1.max_lazy_match);
    try testing.expectEqual(@as(u16, 5), LZ77_LEVEL_2.max_lazy_match);
    try testing.expectEqual(@as(u16, 6), LZ77_LEVEL_3.max_lazy_match);
}

test "encodeZlibRLE: 80B prose matches zlib Z_RLE byte-exact" {
    // zlib Z_RLE limits LZ77 matches to distance=1 (run-length only). The
    // resulting tokens go through the standard 3-way Huffman dispatch.
    // L1-L9 + Z_RLE all collapse to identical output (chain depth/lazy
    // don't matter when distance is fixed to 1).
    const input =
        "# deflate_fingerprint\n\nIdentify which DEFLATE encoder implementation produced a ";
    const expected = [_]u8{
        0x05, 0xc1, 0x41, 0x0a, 0x80, 0x30, 0x0c, 0x04, 0xc0, 0xbb, 0xaf, 0x08,
        0xf8, 0x12, 0xc1, 0x0a, 0x82, 0x47, 0xef, 0x52, 0x9a, 0xad, 0x0d, 0xb4,
        0x69, 0x09, 0x11, 0xf1, 0xf7, 0xce, 0xcc, 0xc4, 0xc8, 0x35, 0x3a, 0xae,
        0x2c, 0x7a, 0xc3, 0x86, 0x89, 0xfa, 0x34, 0xed, 0x0c, 0x75, 0xc9, 0x1f,
        0xbd, 0x45, 0x52, 0xa1, 0x35, 0x6c, 0xc7, 0x72, 0x06, 0x82, 0xa6, 0xce,
        0x30, 0x92, 0x36, 0x2a, 0x1a, 0xd4, 0xa3, 0x4b, 0x57, 0x1a, 0xd6, 0xf9,
        0x49, 0x60, 0x8a, 0xf4, 0x03,
    };
    const got = try encodeZlibRLE(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &expected, got);
}

test "encodeZlibLevel4Filtered: 100B prose matches zlib Z_FILTERED byte-exact" {
    // zlib Z_FILTERED in deflate_slow (L4-L9) rejects matches with
    // length <= 5. L1-L3 + Z_FILTERED collapse to default since deflate_fast
    // has no FILTERED-specific logic. Captured via:
    //   head -c 100 README.md | gen_zlib_target ... 4 filtered
    const input =
        "# deflate_fingerprint\n\nIdentify which DEFLATE encoder implementation produced a given compressed byt";
    const expected = [_]u8{
        0x05, 0xc1, 0x41, 0x0a, 0x83, 0x30, 0x10, 0x05, 0xd0, 0xbd, 0xa7, 0xf8,
        0xd0, 0x93, 0x14, 0x6a, 0x41, 0x70, 0xd9, 0x7d, 0x89, 0x99, 0x1f, 0x1d,
        0x30, 0x93, 0x30, 0x8e, 0x2d, 0xde, 0xde, 0xf7, 0x1e, 0x10, 0x96, 0x3d,
        0x05, 0xbf, 0x45, 0x6d, 0xa5, 0x77, 0x57, 0x8b, 0x61, 0x98, 0x84, 0x16,
        0x5a, 0x2e, 0xfc, 0x37, 0xcd, 0x1b, 0x5e, 0xe3, 0x7b, 0x7e, 0x7e, 0x46,
        0xd0, 0x72, 0x13, 0x3a, 0xb4, 0xf6, 0x9d, 0x95, 0x16, 0x29, 0xb4, 0x19,
        0xba, 0x37, 0x39, 0x33, 0x05, 0x09, 0xab, 0xfe, 0x68, 0xc8, 0xad, 0x76,
        0xe7, 0x71, 0x50, 0xb0, 0x5c, 0x71, 0x03,
    };
    try testing.expectEqual(@as(usize, 100), input.len);
    const got = try encodeZlibLevel4Filtered(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &expected, got);
}
