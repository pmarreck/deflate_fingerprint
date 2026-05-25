//! Pure DEFLATE stream inspection helpers.
//!
//! These routines decode enough structure to answer fingerprinting questions
//! such as "where did the encoder place block boundaries?" without depending
//! on zlib internals or doing file I/O.

const std = @import("std");

pub const BlockType = enum(u2) {
    stored = 0,
    fixed = 1,
    dynamic = 2,
    reserved = 3,
};

pub const BlockInfo = struct {
    index: usize,
    bfinal: bool,
    block_type: BlockType,
    compressed_start_bit: usize,
    compressed_end_bit: usize,
    raw_start: usize,
    raw_end: usize,
    token_count: usize,
};

pub const InspectError = error{
    UnexpectedEndOfStream,
    BadStoredBlockLength,
    BadHuffmanCode,
    ReservedBlockType,
    UnsupportedBlockType,
};

const BitReader = struct {
    bytes: []const u8,
    bit_pos: usize = 0,

    fn readBits(self: *BitReader, nbits: u6) InspectError!u32 {
        var result: u32 = 0;
        var i: u6 = 0;
        while (i < nbits) : (i += 1) {
            if (self.bit_pos >= self.bytes.len * 8) return error.UnexpectedEndOfStream;
            const byte = self.bytes[self.bit_pos / 8];
            const bit_index: u3 = @intCast(self.bit_pos % 8);
            const bit: u32 = (byte >> bit_index) & 1;
            result |= bit << @intCast(i);
            self.bit_pos += 1;
        }
        return result;
    }

    fn alignToByte(self: *BitReader) void {
        self.bit_pos = (self.bit_pos + 7) & ~@as(usize, 7);
    }

    fn skipBytes(self: *BitReader, n: usize) InspectError!void {
        if (self.bit_pos % 8 != 0) self.alignToByte();
        const next = self.bit_pos + n * 8;
        if (next > self.bytes.len * 8) return error.UnexpectedEndOfStream;
        self.bit_pos = next;
    }

    fn readMsbCode(self: *BitReader, nbits: u6) InspectError!u16 {
        var result: u16 = 0;
        var i: u6 = 0;
        while (i < nbits) : (i += 1) {
            result = (result << 1) | @as(u16, @intCast(try self.readBits(1)));
        }
        return result;
    }
};

fn readFixedLitLen(reader: *BitReader) InspectError!u16 {
    var code = try reader.readMsbCode(7);
    if (code <= 0x17) return 256 + code;

    code = (code << 1) | @as(u16, @intCast(try reader.readBits(1)));
    if (code >= 0x30 and code <= 0xbf) return code - 0x30;
    if (code >= 0xc0 and code <= 0xc7) return 280 + (code - 0xc0);

    code = (code << 1) | @as(u16, @intCast(try reader.readBits(1)));
    if (code >= 0x190 and code <= 0x1ff) return 144 + (code - 0x190);

    return error.BadHuffmanCode;
}

fn fixedDistanceCode(reader: *BitReader) InspectError!u16 {
    return try reader.readMsbCode(5);
}

const LengthInfo = struct {
    base: u16,
    extra_bits: u6,
};

fn lengthInfo(symbol: u16) InspectError!LengthInfo {
    return switch (symbol) {
        257 => .{ .base = 3, .extra_bits = 0 },
        258 => .{ .base = 4, .extra_bits = 0 },
        259 => .{ .base = 5, .extra_bits = 0 },
        260 => .{ .base = 6, .extra_bits = 0 },
        261 => .{ .base = 7, .extra_bits = 0 },
        262 => .{ .base = 8, .extra_bits = 0 },
        263 => .{ .base = 9, .extra_bits = 0 },
        264 => .{ .base = 10, .extra_bits = 0 },
        265 => .{ .base = 11, .extra_bits = 1 },
        266 => .{ .base = 13, .extra_bits = 1 },
        267 => .{ .base = 15, .extra_bits = 1 },
        268 => .{ .base = 17, .extra_bits = 1 },
        269 => .{ .base = 19, .extra_bits = 2 },
        270 => .{ .base = 23, .extra_bits = 2 },
        271 => .{ .base = 27, .extra_bits = 2 },
        272 => .{ .base = 31, .extra_bits = 2 },
        273 => .{ .base = 35, .extra_bits = 3 },
        274 => .{ .base = 43, .extra_bits = 3 },
        275 => .{ .base = 51, .extra_bits = 3 },
        276 => .{ .base = 59, .extra_bits = 3 },
        277 => .{ .base = 67, .extra_bits = 4 },
        278 => .{ .base = 83, .extra_bits = 4 },
        279 => .{ .base = 99, .extra_bits = 4 },
        280 => .{ .base = 115, .extra_bits = 4 },
        281 => .{ .base = 131, .extra_bits = 5 },
        282 => .{ .base = 163, .extra_bits = 5 },
        283 => .{ .base = 195, .extra_bits = 5 },
        284 => .{ .base = 227, .extra_bits = 5 },
        285 => .{ .base = 258, .extra_bits = 0 },
        else => error.BadHuffmanCode,
    };
}

const DistanceInfo = struct {
    base: u16,
    extra_bits: u6,
};

fn distanceInfo(symbol: u16) InspectError!DistanceInfo {
    return switch (symbol) {
        0 => .{ .base = 1, .extra_bits = 0 },
        1 => .{ .base = 2, .extra_bits = 0 },
        2 => .{ .base = 3, .extra_bits = 0 },
        3 => .{ .base = 4, .extra_bits = 0 },
        4 => .{ .base = 5, .extra_bits = 1 },
        5 => .{ .base = 7, .extra_bits = 1 },
        6 => .{ .base = 9, .extra_bits = 2 },
        7 => .{ .base = 13, .extra_bits = 2 },
        8 => .{ .base = 17, .extra_bits = 3 },
        9 => .{ .base = 25, .extra_bits = 3 },
        10 => .{ .base = 33, .extra_bits = 4 },
        11 => .{ .base = 49, .extra_bits = 4 },
        12 => .{ .base = 65, .extra_bits = 5 },
        13 => .{ .base = 97, .extra_bits = 5 },
        14 => .{ .base = 129, .extra_bits = 6 },
        15 => .{ .base = 193, .extra_bits = 6 },
        16 => .{ .base = 257, .extra_bits = 7 },
        17 => .{ .base = 385, .extra_bits = 7 },
        18 => .{ .base = 513, .extra_bits = 8 },
        19 => .{ .base = 769, .extra_bits = 8 },
        20 => .{ .base = 1025, .extra_bits = 9 },
        21 => .{ .base = 1537, .extra_bits = 9 },
        22 => .{ .base = 2049, .extra_bits = 10 },
        23 => .{ .base = 3073, .extra_bits = 10 },
        24 => .{ .base = 4097, .extra_bits = 11 },
        25 => .{ .base = 6145, .extra_bits = 11 },
        26 => .{ .base = 8193, .extra_bits = 12 },
        27 => .{ .base = 12289, .extra_bits = 12 },
        28 => .{ .base = 16385, .extra_bits = 13 },
        29 => .{ .base = 24577, .extra_bits = 13 },
        else => error.BadHuffmanCode,
    };
}

fn inspectFixedPayload(reader: *BitReader, raw_pos: *usize) InspectError!usize {
    var token_count: usize = 0;
    while (true) {
        const symbol = try readFixedLitLen(reader);
        if (symbol < 256) {
            raw_pos.* += 1;
            token_count += 1;
        } else if (symbol == 256) {
            return token_count;
        } else {
            const len_info = try lengthInfo(symbol);
            const extra_len: u16 = @intCast(try reader.readBits(len_info.extra_bits));
            const distance_symbol = try fixedDistanceCode(reader);
            const dist_info = try distanceInfo(distance_symbol);
            _ = try reader.readBits(dist_info.extra_bits);
            raw_pos.* += @as(usize, len_info.base + extra_len);
            token_count += 1;
        }
    }
}

/// Inspect raw RFC 1951 DEFLATE blocks and return compressed/raw block ranges.
/// The first increment handles STORED blocks; Huffman block decoding follows.
pub fn inspectBlocks(allocator: std.mem.Allocator, deflate: []const u8) ![]BlockInfo {
    var reader: BitReader = .{ .bytes = deflate };
    var blocks: std.ArrayList(BlockInfo) = .empty;
    errdefer blocks.deinit(allocator);

    var raw_pos: usize = 0;
    while (true) {
        const start_bit = reader.bit_pos;
        const bfinal = (try reader.readBits(1)) != 0;
        const block_type: BlockType = @enumFromInt(try reader.readBits(2));
        const raw_start = raw_pos;
        var token_count: usize = 0;

        switch (block_type) {
            .stored => {
                reader.alignToByte();
                const len: u16 = @intCast(try reader.readBits(16));
                const nlen: u16 = @intCast(try reader.readBits(16));
                if (nlen != ~len) return error.BadStoredBlockLength;
                try reader.skipBytes(len);
                raw_pos += len;
                token_count = len;
            },
            .fixed => token_count = try inspectFixedPayload(&reader, &raw_pos),
            .dynamic => return error.UnsupportedBlockType,
            .reserved => return error.ReservedBlockType,
        }

        try blocks.append(allocator, .{
            .index = blocks.items.len,
            .bfinal = bfinal,
            .block_type = block_type,
            .compressed_start_bit = start_bit,
            .compressed_end_bit = reader.bit_pos,
            .raw_start = raw_start,
            .raw_end = raw_pos,
            .token_count = token_count,
        });

        if (bfinal) break;
    }

    return blocks.toOwnedSlice(allocator);
}

const testing = std.testing;
const encoder = @import("encoder.zig");

test "inspectBlocks reports one stored block with compressed and raw ranges" {
    const raw = "Hello, world!";
    const deflated = try encoder.encodeZlibStored(testing.allocator, raw);
    defer testing.allocator.free(deflated);

    const blocks = try inspectBlocks(testing.allocator, deflated);
    defer testing.allocator.free(blocks);

    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expectEqual(@as(usize, 0), blocks[0].index);
    try testing.expectEqual(true, blocks[0].bfinal);
    try testing.expectEqual(BlockType.stored, blocks[0].block_type);
    try testing.expectEqual(@as(usize, 0), blocks[0].compressed_start_bit);
    try testing.expectEqual(deflated.len * 8, blocks[0].compressed_end_bit);
    try testing.expectEqual(@as(usize, 0), blocks[0].raw_start);
    try testing.expectEqual(raw.len, blocks[0].raw_end);
    try testing.expectEqual(raw.len, blocks[0].token_count);
}

test "inspectBlocks reports fixed-Huffman literal block ranges" {
    const raw = "Hello, world!";
    const deflated = try encoder.encodeFixedHuffmanLiterals(testing.allocator, raw);
    defer testing.allocator.free(deflated);

    const blocks = try inspectBlocks(testing.allocator, deflated);
    defer testing.allocator.free(blocks);

    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expectEqual(true, blocks[0].bfinal);
    try testing.expectEqual(BlockType.fixed, blocks[0].block_type);
    try testing.expectEqual(@as(usize, 0), blocks[0].compressed_start_bit);
    try testing.expectEqual(@as(usize, 114), blocks[0].compressed_end_bit);
    try testing.expectEqual(@as(usize, 0), blocks[0].raw_start);
    try testing.expectEqual(raw.len, blocks[0].raw_end);
    try testing.expectEqual(raw.len, blocks[0].token_count);
}
