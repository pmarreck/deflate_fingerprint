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
};

pub const InspectError = error{
    UnexpectedEndOfStream,
    BadStoredBlockLength,
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
};

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

        switch (block_type) {
            .stored => {
                reader.alignToByte();
                const len: u16 = @intCast(try reader.readBits(16));
                const nlen: u16 = @intCast(try reader.readBits(16));
                if (nlen != ~len) return error.BadStoredBlockLength;
                try reader.skipBytes(len);
                raw_pos += len;
            },
            .fixed, .dynamic => return error.UnsupportedBlockType,
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
}
