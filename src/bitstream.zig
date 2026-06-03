//! Low-level bit emission for DEFLATE streams.
//!
//! LSB-first bit writer per RFC 1951 §3.1.1: "Data elements are packed into
//! bytes so that the first bit of each data element is the lowest-order bit
//! of the first byte."
//!
//! Non-Huffman fields (block headers, LEN/NLEN, distance/length extra bits)
//! are written *value-LSB-first*, so `writeBits(value, n)` does the right
//! thing directly.
//!
//! Huffman codes per §3.1.1: "Huffman codes are packed starting with the
//! most-significant bit of the code." Since this writer's primitive is
//! value-LSB-first, callers feed in *bit-reversed* Huffman codes — see
//! `reverseBits` and the fixed-Huffman emitters below.

const std = @import("std");

pub const BitWriter = struct {
    /// Zig 0.16's std.ArrayList(T) is unmanaged — methods take an allocator
    /// explicitly. We carry the allocator on the BitWriter struct so callers
    /// only pass it once at `init`.
    bytes: std.ArrayList(u8),
    bit_buf: u32,
    bit_count: u6,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BitWriter {
        return .{
            .bytes = .empty,
            .bit_buf = 0,
            .bit_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BitWriter) void {
        self.bytes.deinit(self.allocator);
    }

    /// Append the low `nbits` of `value` to the bit stream, LSB first.
    /// `nbits` must be 0..32; in practice we write at most 16 at a time.
    pub fn writeBits(self: *BitWriter, value: u32, nbits: u6) !void {
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
    pub fn flush(self: *BitWriter) !void {
        if (self.bit_count > 0) {
            try self.bytes.append(self.allocator, @truncate(self.bit_buf & 0xFF));
            self.bit_buf = 0;
            self.bit_count = 0;
        }
    }

    pub fn toOwnedSlice(self: *BitWriter) ![]u8 {
        try self.flush();
        return self.bytes.toOwnedSlice(self.allocator);
    }
};

/// Reverse the low `nbits` bits of `v`. Huffman codes are defined MSB-first
/// in the RFC but our bit writer emits LSB-first, so each emission is
/// preceded by a reversal.
pub fn reverseBits(v: u16, nbits: u6) u32 {
    var x: u16 = v;
    var r: u32 = 0;
    var i: u6 = 0;
    while (i < nbits) : (i += 1) {
        r = (r << 1) | (x & 1);
        x >>= 1;
    }
    return r;
}

// ─── Fixed Huffman literal codes (RFC 1951 §3.2.6) ───────────────────────
//
// Symbol ranges and codes (codes are MSB-first as defined in the RFC):
//   0..143   : 8-bit codes 0011_0000 .. 1011_1111  (= 0x30 + symbol)
//   144..255 : 9-bit codes 1_1001_0000 .. 1_1111_1111  (= 0x190 + (symbol-144))
//   256..279 : 7-bit codes 000_0000 .. 001_0111  (EOB=256 has code 0)
//   280..287 : 8-bit codes 1100_0000 .. 1100_0111

/// Emit one fixed-Huffman literal byte (0..255) MSB-first into `bw`.
pub fn writeFixedLiteral(bw: *BitWriter, byte: u8) !void {
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

/// Emit one fixed-Huffman length-code symbol (257..285) MSB-first into `bw`.
/// 7-bit codes for 257..279, 8-bit codes for 280..285.
pub fn writeFixedLengthCode(bw: *BitWriter, code: u16) !void {
    if (code <= 279) {
        const value: u16 = code - 256; // 1..23
        try bw.writeBits(reverseBits(value, 7), 7);
    } else {
        const value: u16 = 0xC0 + (code - 280); // 0xC0..0xC5
        try bw.writeBits(reverseBits(value, 8), 8);
    }
}

/// Emit one fixed-Huffman distance-code symbol (0..29). All 5 bits.
pub fn writeFixedDistanceCode(bw: *BitWriter, code: u8) !void {
    try bw.writeBits(reverseBits(code, 5), 5);
}

test "bitstream: single bits pack LSB-first" {
    var bw = BitWriter.init(std.testing.allocator);
    defer bw.deinit();
    try bw.writeBits(1, 1);
    try bw.writeBits(0, 1);
    try bw.writeBits(1, 1);
    try bw.flush();
    try std.testing.expectEqualSlices(u8, &[_]u8{0x05}, bw.bytes.items);
}

test "bitstream: flush zero-pads the final partial byte" {
    var bw = BitWriter.init(std.testing.allocator);
    defer bw.deinit();
    try bw.writeBits(0b111, 3);
    try bw.flush();
    try std.testing.expectEqualSlices(u8, &[_]u8{0x07}, bw.bytes.items);
}

test "bitstream: a value wider than a byte splits across byte boundaries LSB-first" {
    var bw = BitWriter.init(std.testing.allocator);
    defer bw.deinit();
    try bw.writeBits(0xABC, 12);
    try bw.flush();
    // low 8 bits (0xBC) land in the first byte, the remaining 4 bits (0xA) in
    // the low nibble of the next, zero-padded.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xBC, 0x0A }, bw.bytes.items);
}

test "bitstream: small writes straddle a byte boundary" {
    var bw = BitWriter.init(std.testing.allocator);
    defer bw.deinit();
    try bw.writeBits(1, 1);
    try bw.writeBits(0xFF, 8);
    try bw.flush();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0x01 }, bw.bytes.items);
}

test "bitstream: flush is idempotent and a no-op when no bits are pending" {
    var bw = BitWriter.init(std.testing.allocator);
    defer bw.deinit();
    try bw.flush(); // nothing pending
    try std.testing.expectEqual(@as(usize, 0), bw.bytes.items.len);
    try bw.writeBits(1, 1);
    try bw.flush();
    try bw.flush(); // idempotent: second flush adds nothing
    try std.testing.expectEqualSlices(u8, &[_]u8{0x01}, bw.bytes.items);
}

test "bitstream: mixed-width writes round-trip through an LSB-first reader" {
    const Pair = struct { value: u32, nbits: u6 };
    const pairs = [_]Pair{
        .{ .value = 0, .nbits = 1 },
        .{ .value = 1, .nbits = 1 },
        .{ .value = 0b11, .nbits = 2 },
        .{ .value = 0xABC, .nbits = 12 },
        .{ .value = 1, .nbits = 1 },
        .{ .value = 0xFF, .nbits = 8 },
        .{ .value = 0x5A5, .nbits = 11 },
        .{ .value = 0, .nbits = 5 },
    };
    var bw = BitWriter.init(std.testing.allocator);
    defer bw.deinit();
    for (pairs) |p| try bw.writeBits(p.value, p.nbits);
    const out = try bw.toOwnedSlice();
    defer std.testing.allocator.free(out);

    var bit_pos: usize = 0;
    for (pairs) |p| {
        var got: u32 = 0;
        var i: u6 = 0;
        while (i < p.nbits) : (i += 1) {
            const byte = out[bit_pos >> 3];
            const bit: u32 = (byte >> @as(u3, @intCast(bit_pos & 7))) & 1;
            got |= bit << @as(u5, @intCast(i));
            bit_pos += 1;
        }
        const mask: u32 = if (p.nbits == 32) 0xFFFF_FFFF else (@as(u32, 1) << @as(u5, @intCast(p.nbits))) - 1;
        try std.testing.expectEqual(p.value & mask, got);
    }
}
