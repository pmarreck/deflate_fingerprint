//! deflate_fingerprint — C FFI surface for the deflate_fingerprint library.
//!
//! Public C entry points are defined here as `export fn`. The actual algorithm
//! and parameterized DEFLATE encoder live in the sibling modules:
//!
//!   - encoder.zig        — parameterized DEFLATE encoder core
//!   - encoder_zlib.zig   — zlib-quirks behavior tables (and one per supported family)
//!   - identify.zig       — detection algorithm with early bailout
//!   - registry.zig       — fingerprint registry (versioned data file)
//!
//! See DESIGN.md for the architectural intent.

const std = @import("std");

// Sibling modules. Imported here so their tests are reachable from the
// `zig build test` root (`src/lib.zig`). A top-level `pub const` import is
// not sufficient for test discovery — Zig's test runner only collects `test`
// blocks reachable from the root file, so we explicitly ref them in a `test`
// block below.
pub const encoder = @import("encoder.zig");
pub const bitstream = @import("bitstream.zig");
pub const huffman = @import("huffman.zig");
pub const match = @import("match.zig");
pub const blocks = @import("blocks.zig");
// const identify_mod = @import("identify.zig");  // TODO when written
// const registry = @import("registry.zig");      // TODO when written

test {
    // Pull tests from sibling modules into the `zig build test` run.
    std.testing.refAllDecls(@This());
    _ = encoder;
    _ = bitstream;
    _ = huffman;
    _ = match;
    _ = blocks;
}

// ─── Public Zig API ──────────────────────────────────────────────────────

pub const Version = struct {
    pub const major: u8 = 0;
    pub const minor: u8 = 1;
    pub const patch: u8 = 0;
    pub const string: [:0]const u8 = "0.1.0";
};

/// Identification result returned by `identify`.
pub const IdentifyResult = struct {
    /// Registry fingerprint ID. 0 means no candidate matched.
    fingerprint_id: u16,
    /// Confidence tier.
    confidence: Confidence,
    /// For `near_match`: number of bytes that differed between our best-
    /// candidate reproduction and the target. 0 for `byte_exact`.
    residual_bytes: usize,
};

pub const Confidence = enum(u8) {
    byte_exact = 0,
    near_match = 1,
};

/// One entry in the fingerprint registry. As more encoders land, append
/// to `FINGERPRINTS` below. The registry is intentionally just data —
/// no separate registry.zig until the table grows enough to justify it.
pub const Fingerprint = struct {
    /// Stable u16 ID assigned at registration. 0 is reserved for "no match".
    id: u16,
    /// Human-readable description; appears in CLI output and forensic reports.
    description: []const u8,
    /// Byte-exact encoder that reproduces this fingerprint's output from
    /// the same uncompressed input. Returned slice is owned by the caller.
    encode: *const fn (std.mem.Allocator, []const u8) anyerror![]u8,
};

/// Registered fingerprints, in descending order of expected prior probability.
/// The identifier walks the table top-down; the first byte-exact match wins.
/// This ordering currently doesn't matter (one entry) but will once we add
/// more — the most common (e.g. zlib DEFAULT_STRATEGY L6) should be first.
pub const FINGERPRINTS = [_]Fingerprint{
    .{
        .id = 1,
        .description = "zlib Z_NO_COMPRESSION (level=0, raw DEFLATE stored blocks)",
        .encode = encoder.encodeZlibStored,
    },
    .{
        .id = 2,
        .description = "zlib Z_HUFFMAN_ONLY (any level, any memLevel; 3-way FIXED/DYNAMIC/STORED dispatch)",
        .encode = encoder.encodeZlibHuffmanOnly,
    },
    .{
        .id = 3,
        .description = "zlib level=1 DEFAULT_STRATEGY (deflate_fast, greedy LZ77, hash-chain depth 4)",
        .encode = encoder.encodeZlibLevel1,
    },
    .{
        .id = 4,
        .description = "zlib level=6 DEFAULT_STRATEGY (deflate_slow, lazy LZ77, chain depth 128, lazy threshold 16)",
        .encode = encoder.encodeZlibLevel6,
    },
    .{
        .id = 5,
        .description = "zlib level=9 DEFAULT_STRATEGY (deflate_slow, max-effort lazy LZ77, chain depth 4096)",
        .encode = encoder.encodeZlibLevel9,
    },
    // Levels 2-5 and 7-8 — appended in registration order (IDs are stable
    // forever per DESIGN.md). Most produce byte-equivalent output to L1
    // (greedy) or L6/L9 (lazy) for typical inputs; they're here to cover
    // the configs that DO produce distinct bytes for specific input
    // patterns (e.g. inputs where chain depth or lazy threshold flips the
    // chosen match).
    .{ .id = 6,  .description = "zlib level=2 DEFAULT_STRATEGY (deflate_fast, chain 8)",     .encode = encoder.encodeZlibLevel2 },
    .{ .id = 7,  .description = "zlib level=3 DEFAULT_STRATEGY (deflate_fast, chain 32)",    .encode = encoder.encodeZlibLevel3 },
    .{ .id = 8,  .description = "zlib level=4 DEFAULT_STRATEGY (deflate_slow, lazy 4)",      .encode = encoder.encodeZlibLevel4 },
    .{ .id = 9,  .description = "zlib level=5 DEFAULT_STRATEGY (deflate_slow, lazy 16)",     .encode = encoder.encodeZlibLevel5 },
    .{ .id = 10, .description = "zlib level=7 DEFAULT_STRATEGY (deflate_slow, lazy 32)",     .encode = encoder.encodeZlibLevel7 },
    .{ .id = 11, .description = "zlib level=8 DEFAULT_STRATEGY (deflate_slow, lazy 128)",    .encode = encoder.encodeZlibLevel8 },

    // ─── Z_FIXED strategy: forces BTYPE=01 (fixed Huffman) per block. ───
    // STORED can still win on small inputs. L0 + Z_FIXED collapses to
    // fingerprint #1 (zlib emits STORED at level=0 regardless of strategy).
    .{ .id = 12, .description = "zlib level=1 Z_FIXED (greedy LZ77, force fixed Huffman)",    .encode = encoder.encodeZlibLevel1Fixed },
    .{ .id = 13, .description = "zlib level=2 Z_FIXED",                                       .encode = encoder.encodeZlibLevel2Fixed },
    .{ .id = 14, .description = "zlib level=3 Z_FIXED",                                       .encode = encoder.encodeZlibLevel3Fixed },
    .{ .id = 15, .description = "zlib level=4 Z_FIXED (lazy LZ77, force fixed Huffman)",      .encode = encoder.encodeZlibLevel4Fixed },
    .{ .id = 16, .description = "zlib level=5 Z_FIXED",                                       .encode = encoder.encodeZlibLevel5Fixed },
    .{ .id = 17, .description = "zlib level=6 Z_FIXED",                                       .encode = encoder.encodeZlibLevel6Fixed },
    .{ .id = 18, .description = "zlib level=7 Z_FIXED",                                       .encode = encoder.encodeZlibLevel7Fixed },
    .{ .id = 19, .description = "zlib level=8 Z_FIXED",                                       .encode = encoder.encodeZlibLevel8Fixed },
    .{ .id = 20, .description = "zlib level=9 Z_FIXED",                                       .encode = encoder.encodeZlibLevel9Fixed },

    // ─── Z_RLE strategy: matches limited to distance=1 (run-length only). ──
    // Levels 1-9 collapse to identical output (chain/lazy params irrelevant).
    // L0 + Z_RLE emits STORED (covered by fingerprint #1).
    .{ .id = 21, .description = "zlib Z_RLE (any level 1-9; distance-1 matches only, 3-way Huffman)", .encode = encoder.encodeZlibRLE },

    // ─── Z_FILTERED strategy: deflate_slow rejects matches with length <= 5. ──
    // L1-L3 + Z_FILTERED collapse to L1-L3 default (deflate_fast ignores
    // strategy in match acceptance). L0 + Z_FILTERED -> STORED via #1.
    .{ .id = 22, .description = "zlib level=4 Z_FILTERED (lazy LZ77, reject len<=5)",                .encode = encoder.encodeZlibLevel4Filtered },
    .{ .id = 23, .description = "zlib level=5 Z_FILTERED",                                          .encode = encoder.encodeZlibLevel5Filtered },
    .{ .id = 24, .description = "zlib level=6 Z_FILTERED",                                          .encode = encoder.encodeZlibLevel6Filtered },
    .{ .id = 25, .description = "zlib level=7 Z_FILTERED",                                          .encode = encoder.encodeZlibLevel7Filtered },
    .{ .id = 26, .description = "zlib level=8 Z_FILTERED",                                          .encode = encoder.encodeZlibLevel8Filtered },
    .{ .id = 27, .description = "zlib level=9 Z_FILTERED",                                          .encode = encoder.encodeZlibLevel9Filtered },
};

/// Identify which registered fingerprint reproduces `target` from `raw`.
/// Iterates `FINGERPRINTS` and returns the first byte-exact match.
///
/// If no fingerprint matches, returns `{ id=0, confidence=near_match,
/// residual_bytes=<bytes of `target` we couldn't reproduce with any
/// candidate's output of the same length, summed over candidates>` — for
/// v0.1 we just report 0; richer residual scoring lives behind a future
/// option struct.
pub fn identify(
    allocator: std.mem.Allocator,
    raw: []const u8,
    target: []const u8,
) !IdentifyResult {
    for (FINGERPRINTS) |fp| {
        const candidate = try fp.encode(allocator, raw);
        defer allocator.free(candidate);
        if (std.mem.eql(u8, candidate, target)) {
            return .{
                .fingerprint_id = fp.id,
                .confidence = .byte_exact,
                .residual_bytes = 0,
            };
        }
    }
    return .{
        .fingerprint_id = 0,
        .confidence = .near_match,
        .residual_bytes = 0,
    };
}

/// Encode `raw` using the encoder for `fingerprint_id`. Returns
/// `error.UnknownFingerprint` if the ID isn't registered. Returned slice
/// is owned by the caller.
pub fn encode(
    allocator: std.mem.Allocator,
    raw: []const u8,
    fingerprint_id: u16,
) ![]u8 {
    for (FINGERPRINTS) |fp| {
        if (fp.id == fingerprint_id) return fp.encode(allocator, raw);
    }
    return error.UnknownFingerprint;
}

// ─── C FFI exports ───────────────────────────────────────────────────────

/// Return the library version as a NUL-terminated string. Stable forever.
export fn dfp_version() callconv(.c) [*:0]const u8 {
    return Version.string.ptr;
}

/// C-side mirror of IdentifyResult.
const CIdentifyResult = extern struct {
    fingerprint_id: u16,
    confidence: u8,
    _pad: u8 = 0,
    residual_bytes: usize,
};

/// Identify the encoder that produced `target` from `raw`. Returns 0 on
/// success with `*out` populated; negative on internal error (e.g. OOM).
/// `out.fingerprint_id == 0` means no candidate in the registry reproduced
/// `target` byte-exactly.
export fn dfp_identify(
    raw: [*]const u8,
    raw_len: usize,
    target: [*]const u8,
    target_len: usize,
    out: *CIdentifyResult,
) callconv(.c) i32 {
    const result = identify(
        std.heap.c_allocator,
        raw[0..raw_len],
        target[0..target_len],
    ) catch return -1;
    out.* = .{
        .fingerprint_id = result.fingerprint_id,
        .confidence = @intFromEnum(result.confidence),
        .residual_bytes = result.residual_bytes,
    };
    return 0;
}

/// Encode `raw` using the encoder parameterized by `fingerprint_id`. On
/// success, `*out_buf` points to a heap-allocated buffer of size `*out_len`;
/// caller must free via `dfp_free`. Returns 0 on success, -1 on OOM, -2 if
/// `fingerprint_id` is not registered.
export fn dfp_encode(
    raw: [*]const u8,
    raw_len: usize,
    fingerprint_id: u16,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const bytes = encode(std.heap.c_allocator, raw[0..raw_len], fingerprint_id) catch |err| switch (err) {
        error.UnknownFingerprint => return -2,
        else => return -1,
    };
    out_buf.* = bytes.ptr;
    out_len.* = bytes.len;
    return 0;
}

/// Free a buffer previously returned by `dfp_encode`. Uses `std.heap.c_allocator`
/// (the same allocator `dfp_encode` allocates from).
export fn dfp_free(buf: [*]u8, len: usize) callconv(.c) void {
    std.heap.c_allocator.free(buf[0..len]);
}

// ─── Tests ───────────────────────────────────────────────────────────────

test "version is well-formed" {
    const v = std.mem.sliceTo(dfp_version(), 0);
    try std.testing.expectEqualStrings("0.1.0", v);
    try std.testing.expectEqual(@as(u8, 0), Version.major);
    try std.testing.expectEqual(@as(u8, 1), Version.minor);
    try std.testing.expectEqual(@as(u8, 0), Version.patch);
}

test "Confidence enum values are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Confidence.byte_exact));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Confidence.near_match));
}

test "dfp_identify: garbage raw/target reports id=0 (no match)" {
    var out: CIdentifyResult = undefined;
    const raw = [_]u8{ 0, 1, 2 };
    const target = [_]u8{ 0, 1, 2 };
    const rc = dfp_identify(&raw, raw.len, &target, target.len, &out);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expectEqual(@as(u16, 0), out.fingerprint_id);
    try std.testing.expectEqual(@intFromEnum(Confidence.near_match), out.confidence);
}

test "dfp_identify: 'Hello, world!' compressed at level=0 is identified as fingerprint #1" {
    const raw = "Hello, world!";
    // Exact bytes that zlib level=0 emits for "Hello, world!" — from
    // bench/probes/zlib_level0_stored.c.
    const target = [_]u8{
        0x01, 0x0d, 0x00, 0xf2, 0xff,
        0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x2c, 0x20, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0x21,
    };
    var out: CIdentifyResult = undefined;
    const rc = dfp_identify(raw.ptr, raw.len, &target, target.len, &out);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expectEqual(@as(u16, 1), out.fingerprint_id);
    try std.testing.expectEqual(@intFromEnum(Confidence.byte_exact), out.confidence);
    try std.testing.expectEqual(@as(usize, 0), out.residual_bytes);
}

test "dfp_encode: fingerprint #1 reproduces target bytes from raw" {
    const raw = "A";
    var out_buf: [*]u8 = undefined;
    var out_len: usize = 0;
    const rc = dfp_encode(raw.ptr, raw.len, 1, &out_buf, &out_len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    defer dfp_free(out_buf, out_len);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x01, 0x01, 0x00, 0xFE, 0xFF, 0x41 },
        out_buf[0..out_len],
    );
}

test "dfp_encode: unknown fingerprint_id returns -2" {
    var out_buf: [*]u8 = undefined;
    var out_len: usize = 0;
    const rc = dfp_encode("X", 1, 9999, &out_buf, &out_len);
    try std.testing.expectEqual(@as(i32, -2), rc);
}

test "identify: round-trip via Zig API matches the FFI path" {
    const raw = "Hello, world!";
    const target = try encoder.encodeZlibStored(std.testing.allocator, raw);
    defer std.testing.allocator.free(target);
    const result = try identify(std.testing.allocator, raw, target);
    try std.testing.expectEqual(@as(u16, 1), result.fingerprint_id);
    try std.testing.expectEqual(Confidence.byte_exact, result.confidence);
}
