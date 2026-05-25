//! Pure DEFLATE stream inspection helpers.
//!
//! These routines decode enough structure to answer fingerprinting questions
//! such as "where did the encoder place block boundaries?" without depending
//! on zlib internals or doing file I/O.

const std = @import("std");
const huffman = @import("huffman.zig");

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

pub const MatchToken = struct {
    length: u16,
    distance: u16,
};

pub const DecodedToken = union(enum) {
    literal: u8,
    match: MatchToken,
};

pub const TokenTraceItem = struct {
    block_index: usize,
    block_type: BlockType,
    raw_start: usize,
    raw_end: usize,
    token: DecodedToken,
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

    fn readAlignedByte(self: *BitReader) InspectError!u8 {
        if (self.bit_pos % 8 != 0) self.alignToByte();
        return @intCast(try self.readBits(8));
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

fn decodeSymbol(
    reader: *BitReader,
    lens: []const u8,
    codes: []const u32,
    max_bits: u8,
) InspectError!u16 {
    var code: u32 = 0;
    var bits: u8 = 1;
    while (bits <= max_bits) : (bits += 1) {
        code = (code << 1) | try reader.readBits(1);
        for (lens, 0..) |len, symbol| {
            if (len == bits and codes[symbol] == code) return @intCast(symbol);
        }
    }
    return error.BadHuffmanCode;
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

fn appendLiteralToken(
    tokens: ?*std.ArrayList(TokenTraceItem),
    allocator: std.mem.Allocator,
    block_index: usize,
    block_type: BlockType,
    raw_start: usize,
    byte: u8,
) !void {
    if (tokens) |items| {
        try items.append(allocator, .{
            .block_index = block_index,
            .block_type = block_type,
            .raw_start = raw_start,
            .raw_end = raw_start + 1,
            .token = .{ .literal = byte },
        });
    }
}

fn appendMatchToken(
    tokens: ?*std.ArrayList(TokenTraceItem),
    allocator: std.mem.Allocator,
    block_index: usize,
    block_type: BlockType,
    raw_start: usize,
    length: u16,
    distance: u16,
) !void {
    if (tokens) |items| {
        try items.append(allocator, .{
            .block_index = block_index,
            .block_type = block_type,
            .raw_start = raw_start,
            .raw_end = raw_start + length,
            .token = .{ .match = .{ .length = length, .distance = distance } },
        });
    }
}

fn inspectFixedPayload(
    allocator: std.mem.Allocator,
    reader: *BitReader,
    raw_pos: *usize,
    block_index: usize,
    tokens: ?*std.ArrayList(TokenTraceItem),
) !usize {
    var token_count: usize = 0;
    while (true) {
        const symbol = try readFixedLitLen(reader);
        if (symbol < 256) {
            const raw_start = raw_pos.*;
            try appendLiteralToken(tokens, allocator, block_index, .fixed, raw_start, @intCast(symbol));
            raw_pos.* += 1;
            token_count += 1;
        } else if (symbol == 256) {
            return token_count;
        } else {
            const len_info = try lengthInfo(symbol);
            const extra_len: u16 = @intCast(try reader.readBits(len_info.extra_bits));
            const distance_symbol = try fixedDistanceCode(reader);
            const dist_info = try distanceInfo(distance_symbol);
            const extra_dist: u16 = @intCast(try reader.readBits(dist_info.extra_bits));
            const length = len_info.base + extra_len;
            const distance = dist_info.base + extra_dist;
            const raw_start = raw_pos.*;
            try appendMatchToken(tokens, allocator, block_index, .fixed, raw_start, length, distance);
            raw_pos.* += @as(usize, length);
            token_count += 1;
        }
    }
}

fn repeatCodeLength(lens: []u8, index: *usize, repeat: usize, value: u8) InspectError!void {
    if (index.* + repeat > lens.len) return error.BadHuffmanCode;
    @memset(lens[index.* .. index.* + repeat], value);
    index.* += repeat;
}

fn inspectDynamicPayload(
    allocator: std.mem.Allocator,
    reader: *BitReader,
    raw_pos: *usize,
    block_index: usize,
    tokens: ?*std.ArrayList(TokenTraceItem),
) !usize {
    const hlit_count: usize = @as(usize, try reader.readBits(5)) + 257;
    const hdist_count: usize = @as(usize, try reader.readBits(5)) + 1;
    const hclen_count: usize = @as(usize, try reader.readBits(4)) + 4;

    var bl_lens = [_]u8{0} ** 19;
    var i: usize = 0;
    while (i < hclen_count) : (i += 1) {
        bl_lens[huffman.BL_ORDER[i]] = @intCast(try reader.readBits(3));
    }

    var bl_codes: [19]u32 = undefined;
    huffman.computeCanonicalCodes(&bl_lens, &bl_codes);

    var combined_lens = [_]u8{0} ** 316;
    const total_lens = hlit_count + hdist_count;
    var lens_index: usize = 0;
    var prev_len: u8 = 0;
    while (lens_index < total_lens) {
        const symbol = try decodeSymbol(reader, &bl_lens, &bl_codes, 7);
        if (symbol <= 15) {
            combined_lens[lens_index] = @intCast(symbol);
            prev_len = @intCast(symbol);
            lens_index += 1;
        } else if (symbol == 16) {
            if (lens_index == 0) return error.BadHuffmanCode;
            const repeat: usize = @as(usize, try reader.readBits(2)) + 3;
            try repeatCodeLength(combined_lens[0..total_lens], &lens_index, repeat, prev_len);
        } else if (symbol == 17) {
            const repeat: usize = @as(usize, try reader.readBits(3)) + 3;
            try repeatCodeLength(combined_lens[0..total_lens], &lens_index, repeat, 0);
            prev_len = 0;
        } else if (symbol == 18) {
            const repeat: usize = @as(usize, try reader.readBits(7)) + 11;
            try repeatCodeLength(combined_lens[0..total_lens], &lens_index, repeat, 0);
            prev_len = 0;
        } else {
            return error.BadHuffmanCode;
        }
    }

    var lit_lens = [_]u8{0} ** 286;
    @memcpy(lit_lens[0..hlit_count], combined_lens[0..hlit_count]);
    var dist_lens = [_]u8{0} ** 30;
    @memcpy(dist_lens[0..hdist_count], combined_lens[hlit_count..total_lens]);

    var lit_codes: [286]u32 = undefined;
    huffman.computeCanonicalCodes(&lit_lens, &lit_codes);
    var dist_codes: [30]u32 = undefined;
    huffman.computeCanonicalCodes(&dist_lens, &dist_codes);

    var token_count: usize = 0;
    while (true) {
        const symbol = try decodeSymbol(reader, lit_lens[0..hlit_count], lit_codes[0..hlit_count], 15);
        if (symbol < 256) {
            const raw_start = raw_pos.*;
            try appendLiteralToken(tokens, allocator, block_index, .dynamic, raw_start, @intCast(symbol));
            raw_pos.* += 1;
            token_count += 1;
        } else if (symbol == 256) {
            return token_count;
        } else {
            const len_info = try lengthInfo(symbol);
            const extra_len: u16 = @intCast(try reader.readBits(len_info.extra_bits));
            const distance_symbol = try decodeSymbol(reader, dist_lens[0..hdist_count], dist_codes[0..hdist_count], 15);
            const dist_info = try distanceInfo(distance_symbol);
            const extra_dist: u16 = @intCast(try reader.readBits(dist_info.extra_bits));
            const length = len_info.base + extra_len;
            const distance = dist_info.base + extra_dist;
            const raw_start = raw_pos.*;
            try appendMatchToken(tokens, allocator, block_index, .dynamic, raw_start, length, distance);
            raw_pos.* += @as(usize, length);
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
            .fixed => token_count = try inspectFixedPayload(allocator, &reader, &raw_pos, blocks.items.len, null),
            .dynamic => token_count = try inspectDynamicPayload(allocator, &reader, &raw_pos, blocks.items.len, null),
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

/// Decode raw RFC 1951 DEFLATE into a flat literal/match trace for forensics.
/// This exposes LZ77 decisions so candidate encoders can be diffed by token.
pub fn inspectTokens(allocator: std.mem.Allocator, deflate: []const u8) ![]TokenTraceItem {
    var reader: BitReader = .{ .bytes = deflate };
    var tokens: std.ArrayList(TokenTraceItem) = .empty;
    errdefer tokens.deinit(allocator);

    var raw_pos: usize = 0;
    var block_index: usize = 0;
    while (true) : (block_index += 1) {
        const bfinal = (try reader.readBits(1)) != 0;
        const block_type: BlockType = @enumFromInt(try reader.readBits(2));

        switch (block_type) {
            .stored => {
                reader.alignToByte();
                const len: u16 = @intCast(try reader.readBits(16));
                const nlen: u16 = @intCast(try reader.readBits(16));
                if (nlen != ~len) return error.BadStoredBlockLength;
                var i: u16 = 0;
                while (i < len) : (i += 1) {
                    const raw_start = raw_pos;
                    const byte = try reader.readAlignedByte();
                    try appendLiteralToken(&tokens, allocator, block_index, .stored, raw_start, byte);
                    raw_pos += 1;
                }
            },
            .fixed => _ = try inspectFixedPayload(allocator, &reader, &raw_pos, block_index, &tokens),
            .dynamic => _ = try inspectDynamicPayload(allocator, &reader, &raw_pos, block_index, &tokens),
            .reserved => return error.ReservedBlockType,
        }

        if (bfinal) break;
    }

    return tokens.toOwnedSlice(allocator);
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

test "inspectBlocks reports dynamic-Huffman literal block ranges" {
    const raw = "A" ** 14;
    const deflated = try encoder.encodeDynamicHuffmanLiterals(testing.allocator, raw);
    defer testing.allocator.free(deflated);

    const blocks = try inspectBlocks(testing.allocator, deflated);
    defer testing.allocator.free(blocks);

    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expectEqual(true, blocks[0].bfinal);
    try testing.expectEqual(BlockType.dynamic, blocks[0].block_type);
    try testing.expectEqual(@as(usize, 0), blocks[0].compressed_start_bit);
    try testing.expectEqual(@as(usize, 114), blocks[0].compressed_end_bit);
    try testing.expectEqual(@as(usize, 0), blocks[0].raw_start);
    try testing.expectEqual(raw.len, blocks[0].raw_end);
    try testing.expectEqual(raw.len, blocks[0].token_count);
}

test "inspectBlocks reports dynamic-Huffman match block raw range" {
    const chunk =
        "# deflate_fingerprint\n\nIdentify which DEFLATE encoder implementation produced a ";
    const raw = chunk ++ chunk;
    const deflated = try encoder.encodeZlibLevel1(testing.allocator, raw);
    defer testing.allocator.free(deflated);

    const blocks = try inspectBlocks(testing.allocator, deflated);
    defer testing.allocator.free(blocks);

    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expectEqual(true, blocks[0].bfinal);
    try testing.expectEqual(BlockType.dynamic, blocks[0].block_type);
    try testing.expectEqual(@as(usize, 0), blocks[0].raw_start);
    try testing.expectEqual(raw.len, blocks[0].raw_end);
    try testing.expect(blocks[0].token_count < raw.len);
}

test "inspectTokens emits fixed-Huffman literal tokens with raw offsets" {
    const raw = "ABC";
    const deflated = try encoder.encodeFixedHuffmanLiterals(testing.allocator, raw);
    defer testing.allocator.free(deflated);

    const tokens = try inspectTokens(testing.allocator, deflated);
    defer testing.allocator.free(tokens);

    try testing.expectEqual(@as(usize, 3), tokens.len);
    try testing.expectEqual(BlockType.fixed, tokens[0].block_type);
    try testing.expectEqual(@as(usize, 0), tokens[0].raw_start);
    try testing.expectEqual(@as(usize, 1), tokens[0].raw_end);
    try testing.expectEqual(@as(u8, 'A'), tokens[0].token.literal);
    try testing.expectEqual(@as(usize, 2), tokens[2].raw_start);
    try testing.expectEqual(@as(usize, 3), tokens[2].raw_end);
    try testing.expectEqual(@as(u8, 'C'), tokens[2].token.literal);
}

test "inspectTokens emits stored block bytes as literal tokens" {
    const raw = "stored bytes";
    const deflated = try encoder.encodeZlibStored(testing.allocator, raw);
    defer testing.allocator.free(deflated);

    const tokens = try inspectTokens(testing.allocator, deflated);
    defer testing.allocator.free(tokens);

    try testing.expectEqual(raw.len, tokens.len);
    for (raw, 0..) |byte, i| {
        try testing.expectEqual(BlockType.stored, tokens[i].block_type);
        try testing.expectEqual(i, tokens[i].raw_start);
        try testing.expectEqual(i + 1, tokens[i].raw_end);
        try testing.expectEqual(byte, tokens[i].token.literal);
    }
}

test "inspectTokens emits dynamic-Huffman match length and distance" {
    const raw = "ABCABCABCABC";
    const deflated = try encoder.encodeZlibLevel1(testing.allocator, raw);
    defer testing.allocator.free(deflated);

    const tokens = try inspectTokens(testing.allocator, deflated);
    defer testing.allocator.free(tokens);

    try testing.expectEqual(@as(usize, 5), tokens.len);
    try testing.expectEqual(@as(u8, 'A'), tokens[0].token.literal);
    try testing.expectEqual(@as(u8, 'B'), tokens[1].token.literal);
    try testing.expectEqual(@as(u8, 'C'), tokens[2].token.literal);
    try testing.expectEqual(@as(u8, 'A'), tokens[3].token.literal);
    try testing.expectEqual(@as(usize, 4), tokens[4].raw_start);
    try testing.expectEqual(@as(usize, 12), tokens[4].raw_end);
    try testing.expectEqual(@as(u16, 8), tokens[4].token.match.length);
    try testing.expectEqual(@as(u16, 3), tokens[4].token.match.distance);
}
