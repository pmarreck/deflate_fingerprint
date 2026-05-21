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

/// Encode `raw` as a single DEFLATE block with BFINAL=1, BTYPE=01 (fixed
/// Huffman tables per RFC 1951 §3.2.6), containing only literal symbols
/// followed by the end-of-block symbol 256. No LZ77 match finding.
///
/// Output is raw DEFLATE bytes (no zlib / gzip wrapper). Caller owns the
/// returned slice and must free it via `allocator.free`.
pub fn encodeFixedHuffmanLiterals(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();

    // 3-bit DEFLATE block header, packed LSB-first:
    //   bit[0] = BFINAL = 1     (this is the only and final block)
    //   bit[1..2] = BTYPE = 01  (fixed Huffman, RFC 1951 §3.2.6)
    //   combined 3-bit value, LSB-first: bit0=1, bit1=1, bit2=0  =>  binary 011 = 3
    try bw.writeBits(3, 3);

    for (raw) |byte| {
        try writeFixedLiteral(&bw, byte);
    }

    // End-of-block symbol 256 — fixed-Huffman 7-bit code 0000000.
    // Reversed is also 0; writeBits emits 7 zero bits.
    try bw.writeBits(0, 7);

    return bw.toOwnedSlice();
}

// ─── BitWriter ───────────────────────────────────────────────────────────
//
// LSB-first bit writer per RFC 1951 §3.1.1: "Data elements are packed into
// bytes so that the first bit of each data element is the lowest-order bit
// of the first byte."
//
// Non-Huffman fields (block headers, LEN/NLEN, distance/length extra bits)
// are written *value-LSB-first*, so `writeBits(value, n)` does the right
// thing directly.
//
// Huffman codes per §3.1.1: "Huffman codes are packed starting with the
// most-significant bit of the code." Since this writer's primitive is
// value-LSB-first, callers feed in *bit-reversed* Huffman codes — see
// `reverseBits` and `writeFixedLiteral` below.

const BitWriter = struct {
    /// Zig 0.16's std.ArrayList(T) is unmanaged — methods take an allocator
    /// explicitly. We carry the allocator on the BitWriter struct so callers
    /// only pass it once at `init`.
    bytes: std.ArrayList(u8),
    bit_buf: u32,
    bit_count: u6,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) BitWriter {
        return .{
            .bytes = .empty,
            .bit_buf = 0,
            .bit_count = 0,
            .allocator = allocator,
        };
    }

    fn deinit(self: *BitWriter) void {
        self.bytes.deinit(self.allocator);
    }

    /// Append the low `nbits` of `value` to the bit stream, LSB first.
    /// `nbits` must be 0..32; in practice we write at most 16 at a time.
    fn writeBits(self: *BitWriter, value: u32, nbits: u6) !void {
        std.debug.assert(nbits <= 32);
        const mask: u32 = if (nbits == 32) 0xFFFF_FFFF else (@as(u32, 1) << @intCast(nbits)) - 1;
        self.bit_buf |= (value & mask) << @intCast(self.bit_count);
        self.bit_count += nbits;
        while (self.bit_count >= 8) {
            try self.bytes.append(self.allocator, @truncate(self.bit_buf & 0xFF));
            self.bit_buf >>= 8;
            self.bit_count -= 8;
        }
    }

    /// Flush any pending bits as a final zero-padded byte. Idempotent.
    fn flush(self: *BitWriter) !void {
        if (self.bit_count > 0) {
            try self.bytes.append(self.allocator, @truncate(self.bit_buf & 0xFF));
            self.bit_buf = 0;
            self.bit_count = 0;
        }
    }

    fn toOwnedSlice(self: *BitWriter) ![]u8 {
        try self.flush();
        return self.bytes.toOwnedSlice(self.allocator);
    }
};

// ─── Fixed Huffman literal codes (RFC 1951 §3.2.6) ───────────────────────
//
// Symbol ranges and codes (codes are MSB-first as defined in the RFC):
//   0..143   : 8-bit codes 0011_0000 .. 1011_1111  (= 0x30 + symbol)
//   144..255 : 9-bit codes 1_1001_0000 .. 1_1111_1111  (= 0x190 + (symbol-144))
//   256..279 : 7-bit codes 000_0000 .. 001_0111  (EOB=256 has code 0)
//   280..287 : 8-bit codes 1100_0000 .. 1100_0111
//
// For literals only (the HUFFMAN_ONLY path), we use the 0..255 ranges plus
// symbol 256 for end-of-block.

fn writeFixedLiteral(bw: *BitWriter, byte: u8) !void {
    var code: u16 = undefined;
    var nbits: u6 = undefined;
    if (byte < 144) {
        code = 0x30 + @as(u16, byte);
        nbits = 8;
    } else {
        code = 0x190 + (@as(u16, byte) - 144);
        nbits = 9;
    }
    try bw.writeBits(reverseBits(code, nbits), nbits);
}

/// Reverse the low `nbits` bits of `v`. Huffman codes are defined MSB-first
/// in the RFC but our bit writer emits LSB-first, so each emission is
/// preceded by a reversal.
fn reverseBits(v: u16, nbits: u6) u32 {
    var x: u16 = v;
    var r: u32 = 0;
    var i: u6 = 0;
    while (i < nbits) : (i += 1) {
        r = (r << 1) | (x & 1);
        x >>= 1;
    }
    return r;
}

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
