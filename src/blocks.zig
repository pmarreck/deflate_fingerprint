//! Block-level DEFLATE emission and 3-way (STORED/FIXED/DYNAMIC) dispatch.
//!
//! This module sits one layer above the bit/huffman/match primitives and
//! handles:
//!   - the length-code (3..258 → 257..285 + extra bits) and distance-code
//!     (1..32768 → 0..29 + extra bits) lookup tables from RFC 1951 §3.2.5;
//!   - emit primitives for each block type (FIXED, DYNAMIC, STORED) that
//!     take an external BitWriter + BFINAL bit so multi-block streams can
//!     share bit-stream state across chunks;
//!   - the 3-way cost-based dispatch that mirrors zlib's _tr_flush_block.

const std = @import("std");

const bitstream = @import("bitstream.zig");
const BitWriter = bitstream.BitWriter;
const reverseBits = bitstream.reverseBits;
const writeFixedLiteral = bitstream.writeFixedLiteral;
const writeFixedLengthCode = bitstream.writeFixedLengthCode;
const writeFixedDistanceCode = bitstream.writeFixedDistanceCode;

const huffman = @import("huffman.zig");
const buildHuffmanLengths = huffman.buildHuffmanLengths;
const computeCanonicalCodes = huffman.computeCanonicalCodes;
const scanCodeLengths = huffman.scanCodeLengths;
const sendCodeLengths = huffman.sendCodeLengths;
const BL_ORDER = huffman.BL_ORDER;

const match_mod = @import("match.zig");
const Token = match_mod.Token;

// ─── Fixed-Huffman length and distance code tables (RFC 1951 §3.2.5) ─────

/// Length code lookup: length (3..258) → (code in 257..285, num_extra_bits, extra_bits).
pub fn lengthCode(length: u16) struct { code: u16, extra_bits: u8, extra_val: u16 } {
    std.debug.assert(length >= 3 and length <= 258);
    if (length <= 10) return .{ .code = @as(u16, 257) + length - 3, .extra_bits = 0, .extra_val = 0 };
    if (length == 258) return .{ .code = 285, .extra_bits = 0, .extra_val = 0 };
    const table = [_]struct { base: u16, extra: u8, code: u16 }{
        .{ .base = 11,  .extra = 1, .code = 265 },
        .{ .base = 13,  .extra = 1, .code = 266 },
        .{ .base = 15,  .extra = 1, .code = 267 },
        .{ .base = 17,  .extra = 1, .code = 268 },
        .{ .base = 19,  .extra = 2, .code = 269 },
        .{ .base = 23,  .extra = 2, .code = 270 },
        .{ .base = 27,  .extra = 2, .code = 271 },
        .{ .base = 31,  .extra = 2, .code = 272 },
        .{ .base = 35,  .extra = 3, .code = 273 },
        .{ .base = 43,  .extra = 3, .code = 274 },
        .{ .base = 51,  .extra = 3, .code = 275 },
        .{ .base = 59,  .extra = 3, .code = 276 },
        .{ .base = 67,  .extra = 4, .code = 277 },
        .{ .base = 83,  .extra = 4, .code = 278 },
        .{ .base = 99,  .extra = 4, .code = 279 },
        .{ .base = 115, .extra = 4, .code = 280 },
        .{ .base = 131, .extra = 5, .code = 281 },
        .{ .base = 163, .extra = 5, .code = 282 },
        .{ .base = 195, .extra = 5, .code = 283 },
        .{ .base = 227, .extra = 5, .code = 284 },
    };
    var i: usize = table.len - 1;
    while (true) : (i -= 1) {
        if (length >= table[i].base) {
            return .{ .code = table[i].code, .extra_bits = table[i].extra, .extra_val = length - table[i].base };
        }
        if (i == 0) unreachable;
    }
}

/// Distance code lookup: distance (1..32768) → (code in 0..29, num_extra_bits, extra_bits).
pub fn distanceCode(distance: u16) struct { code: u8, extra_bits: u8, extra_val: u16 } {
    std.debug.assert(distance >= 1 and distance <= 32768);
    const table = [_]struct { base: u16, extra: u8, code: u8 }{
        .{ .base = 1,     .extra = 0,  .code = 0 },
        .{ .base = 2,     .extra = 0,  .code = 1 },
        .{ .base = 3,     .extra = 0,  .code = 2 },
        .{ .base = 4,     .extra = 0,  .code = 3 },
        .{ .base = 5,     .extra = 1,  .code = 4 },
        .{ .base = 7,     .extra = 1,  .code = 5 },
        .{ .base = 9,     .extra = 2,  .code = 6 },
        .{ .base = 13,    .extra = 2,  .code = 7 },
        .{ .base = 17,    .extra = 3,  .code = 8 },
        .{ .base = 25,    .extra = 3,  .code = 9 },
        .{ .base = 33,    .extra = 4,  .code = 10 },
        .{ .base = 49,    .extra = 4,  .code = 11 },
        .{ .base = 65,    .extra = 5,  .code = 12 },
        .{ .base = 97,    .extra = 5,  .code = 13 },
        .{ .base = 129,   .extra = 6,  .code = 14 },
        .{ .base = 193,   .extra = 6,  .code = 15 },
        .{ .base = 257,   .extra = 7,  .code = 16 },
        .{ .base = 385,   .extra = 7,  .code = 17 },
        .{ .base = 513,   .extra = 8,  .code = 18 },
        .{ .base = 769,   .extra = 8,  .code = 19 },
        .{ .base = 1025,  .extra = 9,  .code = 20 },
        .{ .base = 1537,  .extra = 9,  .code = 21 },
        .{ .base = 2049,  .extra = 10, .code = 22 },
        .{ .base = 3073,  .extra = 10, .code = 23 },
        .{ .base = 4097,  .extra = 11, .code = 24 },
        .{ .base = 6145,  .extra = 11, .code = 25 },
        .{ .base = 8193,  .extra = 12, .code = 26 },
        .{ .base = 12289, .extra = 12, .code = 27 },
        .{ .base = 16385, .extra = 13, .code = 28 },
        .{ .base = 24577, .extra = 13, .code = 29 },
    };
    var i: usize = table.len - 1;
    while (true) : (i -= 1) {
        if (distance >= table[i].base) {
            return .{ .code = table[i].code, .extra_bits = table[i].extra, .extra_val = distance - table[i].base };
        }
        if (i == 0) unreachable;
    }
}

// ─── Token utilities ─────────────────────────────────────────────────────

/// Sum of fixed-Huffman bit costs for a token sequence (excluding the 3-bit
/// BFINAL/BTYPE header and the EOB symbol).
pub fn staticTokenBitsCost(tokens: []const Token) u32 {
    var bits: u32 = 0;
    for (tokens) |t| switch (t) {
        .literal => |b| bits += if (b < 144) @as(u32, 8) else 9,
        .match => |m| {
            const lc = lengthCode(m.length);
            // Length-code Huffman: 7 bits if code <= 279, else 8.
            bits += if (lc.code <= 279) @as(u32, 7) else 8;
            bits += lc.extra_bits;
            // Distance-code: 5 bits fixed (under fixed Huffman).
            const dc = distanceCode(m.distance);
            bits += 5;
            bits += dc.extra_bits;
        },
    };
    return bits;
}

/// Total uncompressed byte count represented by a token sequence — needed
/// for the stored-block cost comparison.
pub fn tokenStreamRawLen(tokens: []const Token) usize {
    var n: usize = 0;
    for (tokens) |t| switch (t) {
        .literal => n += 1,
        .match => |m| n += m.length,
    };
    return n;
}

/// Reconstruct raw bytes from a token sequence — needed when we want to
/// emit a STORED block as the winner of the 3-way comparison.
pub fn reconstructFromTokens(allocator: std.mem.Allocator, tokens: []const Token) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, tokenStreamRawLen(tokens));
    for (tokens) |t| switch (t) {
        .literal => |b| try out.append(allocator, b),
        .match => |m| {
            // Length-distance "byte copy" — standard DEFLATE semantics: for
            // distance < length (RLE-style), bytes generated by the copy are
            // visible to subsequent copies.
            const start = out.items.len - m.distance;
            var k: u16 = 0;
            while (k < m.length) : (k += 1) {
                try out.append(allocator, out.items[start + k]);
            }
        },
    };
    return out.toOwnedSlice(allocator);
}

// ─── Block emit primitives ───────────────────────────────────────────────

/// Emit one BTYPE=00 (stored) block into `bw` with the given BFINAL bit. The
/// chunk MUST fit in u16 LEN (raw.len <= 65535). zlib aligns to byte boundary
/// before writing LEN/NLEN, so we flush the BitWriter's partial byte first.
pub fn emitStoredBlock(bw: *BitWriter, raw: []const u8, bfinal: u1) !void {
    std.debug.assert(raw.len <= 0xFFFF);
    try bw.writeBits(@as(u32, bfinal), 3);
    try bw.flush(); // align to byte boundary (zlib's bi_windup)
    const len: u16 = @intCast(raw.len);
    try bw.bytes.append(bw.allocator, @truncate(len & 0xFF));
    try bw.bytes.append(bw.allocator, @truncate((len >> 8) & 0xFF));
    const nlen: u16 = ~len;
    try bw.bytes.append(bw.allocator, @truncate(nlen & 0xFF));
    try bw.bytes.append(bw.allocator, @truncate((nlen >> 8) & 0xFF));
    try bw.bytes.appendSlice(bw.allocator, raw);
}

/// Emit one BTYPE=01 (fixed Huffman) block over a Token stream into `bw`.
pub fn emitFixedHuffmanFromTokensBlock(bw: *BitWriter, tokens: []const Token, bfinal: u1) !void {
    const header: u32 = @as(u32, bfinal) | (@as(u32, 1) << 1);
    try bw.writeBits(header, 3);
    for (tokens) |t| switch (t) {
        .literal => |b| try writeFixedLiteral(bw, b),
        .match => |m| {
            const lc = lengthCode(m.length);
            try writeFixedLengthCode(bw, lc.code);
            if (lc.extra_bits > 0) try bw.writeBits(lc.extra_val, @intCast(lc.extra_bits));
            const dc = distanceCode(m.distance);
            try writeFixedDistanceCode(bw, dc.code);
            if (dc.extra_bits > 0) try bw.writeBits(dc.extra_val, @intCast(dc.extra_bits));
        },
    };
    // EOB (fixed code for symbol 256 = 7-bit 0).
    try bw.writeBits(0, 7);
}

/// Emit one BTYPE=10 (dynamic Huffman) block over a Token stream into `bw`.
pub fn emitDynamicHuffmanFromTokensBlock(
    bw: *BitWriter,
    allocator: std.mem.Allocator,
    tokens: []const Token,
    bfinal: u1,
) !void {
    // 1. Frequencies.
    var lit_freq = [_]u16{0} ** 286;
    var dist_freq = [_]u16{0} ** 30;
    for (tokens) |t| switch (t) {
        .literal => |b| lit_freq[b] += 1,
        .match => |m| {
            const lc = lengthCode(m.length);
            lit_freq[lc.code] += 1;
            const dc = distanceCode(m.distance);
            dist_freq[dc.code] += 1;
        },
    };
    lit_freq[256] = 1; // EOB

    // 2. Build literal/length tree.
    var lit_lens = [_]u8{0} ** 286;
    try buildHuffmanLengths(allocator, &lit_freq, 15, &lit_lens);
    // 3. Build distance tree.
    var dist_lens = [_]u8{0} ** 30;
    try buildHuffmanLengths(allocator, &dist_freq, 15, &dist_lens);

    // 4. Determine HLIT/HDIST.
    var max_lit: usize = 256;
    var i: usize = 285;
    while (i > 256) : (i -= 1) {
        if (lit_lens[i] != 0) { max_lit = i; break; }
    }
    var max_dist: usize = 0;
    var j: usize = 29;
    while (j > 0) : (j -= 1) {
        if (dist_lens[j] != 0) { max_dist = j; break; }
    }
    const hlit_count: usize = max_lit + 1;
    const hdist_count: usize = max_dist + 1;

    // 5. scan_tree -> bl_freq.
    var bl_freq = [_]u16{0} ** 19;
    scanCodeLengths(&lit_lens, hlit_count, &bl_freq);
    scanCodeLengths(&dist_lens, hdist_count, &bl_freq);

    // 6. CL Huffman tree (max length 7).
    var bl_lens = [_]u8{0} ** 19;
    try buildHuffmanLengths(allocator, &bl_freq, 7, &bl_lens);

    // 7. HCLEN trimming.
    var hclen_count: usize = 4;
    var k: usize = 19;
    while (k > 4) : (k -= 1) {
        if (bl_lens[BL_ORDER[k - 1]] != 0) {
            hclen_count = k;
            break;
        }
    }

    // 8. Canonical codes.
    var bl_codes: [19]u32 = undefined;
    computeCanonicalCodes(&bl_lens, &bl_codes);
    var lit_codes: [286]u32 = undefined;
    computeCanonicalCodes(&lit_lens, &lit_codes);
    var dist_codes: [30]u32 = undefined;
    computeCanonicalCodes(&dist_lens, &dist_codes);

    // 9. Emit block header.
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

    // Emit each token through the dynamic trees.
    for (tokens) |t| switch (t) {
        .literal => |byte| {
            const code = lit_codes[byte];
            const nbits: u6 = @intCast(lit_lens[byte]);
            std.debug.assert(nbits != 0);
            try bw.writeBits(reverseBits(@intCast(code), nbits), nbits);
        },
        .match => |m| {
            const lc = lengthCode(m.length);
            const lcode = lit_codes[lc.code];
            const lnbits: u6 = @intCast(lit_lens[lc.code]);
            std.debug.assert(lnbits != 0);
            try bw.writeBits(reverseBits(@intCast(lcode), lnbits), lnbits);
            if (lc.extra_bits > 0) try bw.writeBits(lc.extra_val, @intCast(lc.extra_bits));

            const dc = distanceCode(m.distance);
            const dcode = dist_codes[dc.code];
            const dnbits: u6 = @intCast(dist_lens[dc.code]);
            std.debug.assert(dnbits != 0);
            try bw.writeBits(reverseBits(@intCast(dcode), dnbits), dnbits);
            if (dc.extra_bits > 0) try bw.writeBits(dc.extra_val, @intCast(dc.extra_bits));
        },
    };

    // EOB.
    const eob_code = lit_codes[256];
    const eob_nbits: u6 = @intCast(lit_lens[256]);
    std.debug.assert(eob_nbits != 0);
    try bw.writeBits(reverseBits(@intCast(eob_code), eob_nbits), eob_nbits);
}

// ─── Single-block wrappers (BFINAL=1) ────────────────────────────────────

/// Encode tokens as a single BFINAL=1/BTYPE=01 fixed-Huffman block.
pub fn encodeFixedHuffmanFromTokens(allocator: std.mem.Allocator, tokens: []const Token) ![]u8 {
    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();
    try emitFixedHuffmanFromTokensBlock(&bw, tokens, 1);
    return bw.toOwnedSlice();
}

/// Encode tokens as a single BFINAL=1/BTYPE=10 dynamic-Huffman block.
pub fn encodeDynamicHuffmanFromTokens(allocator: std.mem.Allocator, tokens: []const Token) ![]u8 {
    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();
    try emitDynamicHuffmanFromTokensBlock(&bw, allocator, tokens, 1);
    return bw.toOwnedSlice();
}

// ─── 3-way (STORED / FIXED / DYNAMIC) dispatch over Token streams ────────

/// 2-way (STORED / FIXED) dispatch over a Token stream. Used by Z_FIXED
/// strategy fingerprints — DYNAMIC is forbidden. STORED comparison uses
/// only the static cost (zlib uses min(static, dyn) but for the small
/// inputs where Z_FIXED matters the two usually agree).
pub fn encodeBlockFromTokens(allocator: std.mem.Allocator, tokens: []const Token) ![]u8 {
    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();
    try emitBlockFromTokensInto(&bw, allocator, tokens, 1);
    return bw.toOwnedSlice();
}

/// 2-way (STORED / FIXED) dispatch over a Token stream, emitted into `bw`
/// with the given BFINAL bit. Used by Z_FIXED multi-block drivers.
pub fn emitBlockFromTokensInto(
    bw: *BitWriter,
    allocator: std.mem.Allocator,
    tokens: []const Token,
    bfinal: u1,
) !void {
    const static_len_bits: u32 = staticTokenBitsCost(tokens) + 7;
    const static_lenb: u32 = (static_len_bits + 3 + 7) >> 3;
    const raw_len: u32 = @intCast(tokenStreamRawLen(tokens));
    const stored_est: u32 = raw_len + 4;

    if (stored_est <= static_lenb) {
        const raw = try reconstructFromTokens(allocator, tokens);
        defer allocator.free(raw);
        std.debug.assert(raw.len <= 0xFFFF);
        try emitStoredBlock(bw, raw, bfinal);
        return;
    }
    try emitFixedHuffmanFromTokensBlock(bw, tokens, bfinal);
}

/// Full zlib 3-way (STORED / FIXED / DYNAMIC) dispatch over a Token stream,
/// returning a single-block byte slice (BFINAL=1).
pub fn encodeBlockFromTokensWithDynamic(allocator: std.mem.Allocator, tokens: []const Token) ![]u8 {
    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();
    try emitBlockFromTokensWithDynamicInto(&bw, allocator, tokens, 1);
    return bw.toOwnedSlice();
}

/// 3-way dispatch over a Token stream, emitted into `bw` with the given
/// BFINAL bit. Used by RLE / default-strategy multi-block drivers.
pub fn emitBlockFromTokensWithDynamicInto(
    bw: *BitWriter,
    allocator: std.mem.Allocator,
    tokens: []const Token,
    bfinal: u1,
) !void {
    const raw = try reconstructFromTokens(allocator, tokens);
    defer allocator.free(raw);
    return emitBlockFromTokensWithDynamicIntoRaw(bw, allocator, tokens, raw, bfinal);
}

pub fn emitBlockFromTokensWithDynamicIntoRaw(
    bw: *BitWriter,
    allocator: std.mem.Allocator,
    tokens: []const Token,
    raw: []const u8,
    bfinal: u1,
) !void {
    const static_len_bits: u32 = staticTokenBitsCost(tokens) + 7;
    const static_lenb: u32 = (static_len_bits + 3 + 7) >> 3;

    // Build DYNAMIC candidate into a scratch BitWriter to measure opt_lenb.
    // If DYNAMIC wins we re-emit into `bw` (deterministic; tree-build is cheap).
    var dyn_bw = BitWriter.init(allocator);
    defer dyn_bw.deinit();
    try emitDynamicHuffmanFromTokensBlock(&dyn_bw, allocator, tokens, bfinal);
    const dyn_bytes_len: u32 = @intCast(dyn_bw.bytes.items.len + (if (dyn_bw.bit_count > 0) @as(usize, 1) else 0));
    var opt_lenb: u32 = dyn_bytes_len;
    if (static_lenb <= opt_lenb) opt_lenb = static_lenb;

    const raw_len: u32 = @intCast(tokenStreamRawLen(tokens));
    std.debug.assert(raw.len == raw_len);
    const stored_est: u32 = raw_len + 4;

    if (stored_est <= opt_lenb) {
        std.debug.assert(raw.len <= 0xFFFF);
        try emitStoredBlock(bw, raw, bfinal);
        return;
    }
    if (static_lenb == opt_lenb) {
        try emitFixedHuffmanFromTokensBlock(bw, tokens, bfinal);
        return;
    }
    // DYNAMIC wins — re-emit (second tree build is cheap).
    try emitDynamicHuffmanFromTokensBlock(bw, allocator, tokens, bfinal);
}

// ─── Multi-block drivers ─────────────────────────────────────────────────
//
// zlib flushes a block when its symbol buffer fills, i.e. every
// (lit_bufsize-1) = 16383 symbols at memLevel=8. Each chunk picks its own
// block type via the same cost dispatch as a single-block stream.
// Only the final block has BFINAL=1; intermediate blocks share the
// BitWriter so bits flow continuously.

/// Symbol-count boundary for multi-block flushes at zlib's default memLevel=8.
pub const MULTI_BLOCK_CHUNK_SYMBOLS: usize = 16383;

/// zlib's pending literal/match buffer holds `1 << (memLevel + 6)` symbols
/// and flushes when `last_lit == lit_bufsize - 1`.
pub fn chunkSymbolsForMemLevel(mem_level: u4) usize {
    std.debug.assert(mem_level >= 1 and mem_level <= 9);
    return (@as(usize, 1) << @intCast(mem_level + 6)) - 1;
}

/// Multi-block driver using the 3-way (STORED/FIXED/DYNAMIC) per-chunk
/// dispatch. Used by default-strategy / Z_RLE / Z_FILTERED encoders.
pub fn encodeMultiBlock3Way(allocator: std.mem.Allocator, tokens: []const Token) ![]u8 {
    return encodeMultiBlock3WayChunked(allocator, tokens, MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeMultiBlock3WayChunked(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    chunk_symbols: usize,
) ![]u8 {
    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();

    if (tokens.len == 0) {
        try emitFixedHuffmanFromTokensBlock(&bw, tokens, 1);
        return bw.toOwnedSlice();
    }

    var i: usize = 0;
    while (i < tokens.len) {
        const end = @min(i + chunk_symbols, tokens.len);
        const is_last: u1 = if (end == tokens.len) 1 else 0;
        try emitBlockFromTokensWithDynamicInto(&bw, allocator, tokens[i..end], is_last);
        i = end;
    }
    return bw.toOwnedSlice();
}

pub fn encodeMultiBlock3WayChunkedFromRaw(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    raw: []const u8,
    chunk_symbols: usize,
) ![]u8 {
    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();

    if (tokens.len == 0) {
        try emitFixedHuffmanFromTokensBlock(&bw, tokens, 1);
        return bw.toOwnedSlice();
    }

    var i: usize = 0;
    var raw_pos: usize = 0;
    while (i < tokens.len) {
        const end = @min(i + chunk_symbols, tokens.len);
        const raw_end = raw_pos + tokenStreamRawLen(tokens[i..end]);
        const is_last: u1 = if (end == tokens.len) 1 else 0;
        try emitBlockFromTokensWithDynamicIntoRaw(&bw, allocator, tokens[i..end], raw[raw_pos..raw_end], is_last);
        raw_pos = raw_end;
        i = end;
    }
    std.debug.assert(raw_pos == raw.len);
    return bw.toOwnedSlice();
}

/// Multi-block driver using the 2-way (STORED/FIXED) per-chunk dispatch.
/// Used by Z_FIXED-strategy encoders.
pub fn encodeMultiBlock2Way(allocator: std.mem.Allocator, tokens: []const Token) ![]u8 {
    return encodeMultiBlock2WayChunked(allocator, tokens, MULTI_BLOCK_CHUNK_SYMBOLS);
}

pub fn encodeMultiBlock2WayChunked(
    allocator: std.mem.Allocator,
    tokens: []const Token,
    chunk_symbols: usize,
) ![]u8 {
    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();

    if (tokens.len == 0) {
        try emitFixedHuffmanFromTokensBlock(&bw, tokens, 1);
        return bw.toOwnedSlice();
    }

    var i: usize = 0;
    while (i < tokens.len) {
        const end = @min(i + chunk_symbols, tokens.len);
        const is_last: u1 = if (end == tokens.len) 1 else 0;
        try emitBlockFromTokensInto(&bw, allocator, tokens[i..end], is_last);
        i = end;
    }
    return bw.toOwnedSlice();
}
