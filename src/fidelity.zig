//! Test-time fidelity oracle: compress inputs with real zlib via @cImport(zlib.h)
//! and compare against our encoder output byte-by-byte.
//!
//! Replaces the brittle pattern of embedding zlib's expected hex bytes as test
//! fixtures. Now tests declare "encoder X must match zlib L=k strategy=S on
//! input Y" and the harness computes the ground truth at test time.
//!
//! Test-time only — pulls in libz, not used by the shipped library or CLI.

const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("zlib.h");
});

pub const Strategy = enum(c_int) {
    default = 0,        // Z_DEFAULT_STRATEGY
    filtered = 1,       // Z_FILTERED
    huffman_only = 2,   // Z_HUFFMAN_ONLY
    rle = 3,            // Z_RLE
    fixed = 4,          // Z_FIXED
};

pub const ZlibError = error{
    InitFailed,
    DeflateFailed,
    OutOfMemory,
};

/// Compress `raw` with real zlib at the given level and strategy, returning
/// raw DEFLATE bytes (windowBits=-15 → no zlib/gzip wrapper, memLevel=8).
/// Caller owns the returned slice.
pub fn compressWithZlib(
    allocator: std.mem.Allocator,
    raw: []const u8,
    level: c_int,
    strategy: Strategy,
) ![]u8 {
    // Worst-case output size per zlib's manual: input + (input>>12) + (input>>14)
    //   + (input>>25) + 13. Add slack for empty-input case.
    const cap: usize = raw.len + (raw.len >> 12) + (raw.len >> 14) + (raw.len >> 25) + 64;
    const out = try allocator.alloc(u8, cap);
    errdefer allocator.free(out);

    var s: c.z_stream = std.mem.zeroes(c.z_stream);
    const rc_init = c.deflateInit2_(
        &s,
        level,
        c.Z_DEFLATED,
        -15, // raw DEFLATE
        8, // default memLevel
        @intFromEnum(strategy),
        c.zlibVersion(),
        @sizeOf(c.z_stream),
    );
    if (rc_init != c.Z_OK) return ZlibError.InitFailed;
    defer _ = c.deflateEnd(&s);

    s.next_in = @constCast(raw.ptr);
    s.avail_in = @intCast(raw.len);
    s.next_out = out.ptr;
    s.avail_out = @intCast(cap);

    const rc = c.deflate(&s, c.Z_FINISH);
    if (rc != c.Z_STREAM_END) return ZlibError.DeflateFailed;

    const out_len = cap - @as(usize, s.avail_out);
    return allocator.realloc(out, out_len);
}

/// Assert that `our_encode_fn(raw)` produces byte-for-byte identical output
/// to real zlib at the given (level, strategy). On mismatch, prints a diff
/// summary (first diverging byte index, expected vs actual lengths).
pub fn assertByteExact(
    allocator: std.mem.Allocator,
    raw: []const u8,
    level: c_int,
    strategy: Strategy,
    our_encode_fn: *const fn (std.mem.Allocator, []const u8) anyerror![]u8,
) !void {
    const ours = try our_encode_fn(allocator, raw);
    defer allocator.free(ours);
    const expected = try compressWithZlib(allocator, raw, level, strategy);
    defer allocator.free(expected);
    try testing.expectEqualSlices(u8, expected, ours);
}

// ─── Tests ────────────────────────────────────────────────────────────────

test "compressWithZlib: empty input produces minimum-size DEFLATE block" {
    const out = try compressWithZlib(testing.allocator, "", 6, .default);
    defer testing.allocator.free(out);
    // Empty input + Z_FINISH at default level should produce a 2-byte EOB-only
    // fixed-Huffman block: 0x03 0x00 (BFINAL=1, BTYPE=01, EOB=7 zero bits).
    try testing.expectEqualSlices(u8, &.{ 0x03, 0x00 }, out);
}

test "compressWithZlib: 'A' at level 0 produces a stored block" {
    const out = try compressWithZlib(testing.allocator, "A", 0, .default);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x01, 0x00, 0xFE, 0xFF, 0x41 }, out);
}

// ─── assertByteExact: demonstrate the harness against representative fingerprints ──

const encoder = @import("encoder.zig");

test "assertByteExact: encodeZlibStored matches zlib L0 on 'Hello, world!'" {
    try assertByteExact(testing.allocator, "Hello, world!", 0, .default, encoder.encodeZlibStored);
}

test "assertByteExact: encodeZlibHuffmanOnly matches zlib L6 HUFFMAN_ONLY on 'A'*14" {
    const input = "A" ** 14;
    // Any level works for HUFFMAN_ONLY — levels don't affect output.
    try assertByteExact(testing.allocator, input, 6, .huffman_only, encoder.encodeZlibHuffmanOnly);
}

test "assertByteExact: encodeZlibLevel1 matches zlib L1 default on the 'longish' prose input" {
    const input = "The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox.";
    try assertByteExact(testing.allocator, input, 1, .default, encoder.encodeZlibLevel1);
}

test "assertByteExact: encodeZlibLevel6 matches zlib L6 default on 'longish' prose" {
    const input = "The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox.";
    try assertByteExact(testing.allocator, input, 6, .default, encoder.encodeZlibLevel6);
}

test "assertByteExact: encodeZlibRLE matches zlib Z_RLE on 'AAAAAA...'" {
    const input = "A" ** 20;
    try assertByteExact(testing.allocator, input, 6, .rle, encoder.encodeZlibRLE);
}

test "assertByteExact: encodeZlibLevel6Filtered matches zlib L6 Z_FILTERED on prose" {
    const input = "# deflate_fingerprint\n\nIdentify which DEFLATE encoder implementation produced a given compressed byt";
    try assertByteExact(testing.allocator, input, 6, .filtered, encoder.encodeZlibLevel6Filtered);
}

test "assertByteExact: encodeZlibLevel9Fixed matches zlib L9 Z_FIXED on 'A'*32" {
    const input = "A" ** 32;
    try assertByteExact(testing.allocator, input, 9, .fixed, encoder.encodeZlibLevel9Fixed);
}

// ─── Sweep: every default-strategy level against a fixed input ────────────
//
// Demonstrates the per-test cost is low enough to amortize broad coverage.
// Failures fire as unit-test failures with stack traces — much sharper signal
// than the shell-based corpus harness can give.

test "sweep: all default-strategy levels match real zlib on prose input" {
    const input = "# deflate_fingerprint\n\nIdentify which DEFLATE encoder implementation produced a given compressed byte stream.";
    const encoders = [_]struct { level: c_int, encode: *const fn (std.mem.Allocator, []const u8) anyerror![]u8 }{
        .{ .level = 0, .encode = encoder.encodeZlibStored },
        .{ .level = 1, .encode = encoder.encodeZlibLevel1 },
        .{ .level = 2, .encode = encoder.encodeZlibLevel2 },
        .{ .level = 3, .encode = encoder.encodeZlibLevel3 },
        .{ .level = 4, .encode = encoder.encodeZlibLevel4 },
        .{ .level = 5, .encode = encoder.encodeZlibLevel5 },
        .{ .level = 6, .encode = encoder.encodeZlibLevel6 },
        .{ .level = 7, .encode = encoder.encodeZlibLevel7 },
        .{ .level = 8, .encode = encoder.encodeZlibLevel8 },
        .{ .level = 9, .encode = encoder.encodeZlibLevel9 },
    };
    for (encoders) |e| {
        assertByteExact(testing.allocator, input, e.level, .default, e.encode) catch |err| {
            std.debug.print("level {d} default diverged: {s}\n", .{ e.level, @errorName(err) });
            return err;
        };
    }
}
