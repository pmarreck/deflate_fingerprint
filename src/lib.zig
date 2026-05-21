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

// TODO: import sibling modules once they exist.
// const encoder = @import("encoder.zig");
// const identify_mod = @import("identify.zig");
// const registry = @import("registry.zig");

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

// TODO: implement these in identify.zig + encoder.zig + registry.zig
//
// pub fn identify(
//     allocator: std.mem.Allocator,
//     raw: []const u8,
//     target: []const u8,
//     options: IdentifyOptions,
// ) !IdentifyResult { ... }
//
// pub fn encode(
//     allocator: std.mem.Allocator,
//     raw: []const u8,
//     fingerprint_id: u16,
// ) ![]u8 { ... }

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

/// Identify the encoder that produced `target` from `raw`.
/// Returns 0 on success (out is populated); negative on error.
/// TODO: implement.
export fn dfp_identify(
    raw: [*]const u8,
    raw_len: usize,
    target: [*]const u8,
    target_len: usize,
    out: *CIdentifyResult,
) callconv(.c) i32 {
    _ = raw;
    _ = raw_len;
    _ = target;
    _ = target_len;
    out.* = .{
        .fingerprint_id = 0,
        .confidence = @intFromEnum(Confidence.near_match),
        .residual_bytes = 0,
    };
    return -1; // not yet implemented
}

/// Encode `raw` using the encoder parameterized by `fingerprint_id`.
/// On success, `*out_buf` points to a heap-allocated buffer of size `*out_len`
/// that the caller must free with `dfp_free`.
/// Returns 0 on success; negative on error.
/// TODO: implement.
export fn dfp_encode(
    raw: [*]const u8,
    raw_len: usize,
    fingerprint_id: u16,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    _ = raw;
    _ = raw_len;
    _ = fingerprint_id;
    _ = out_buf;
    _ = out_len;
    return -1; // not yet implemented
}

/// Free a buffer returned by `dfp_encode`.
export fn dfp_free(buf: [*]u8, len: usize) callconv(.c) void {
    _ = buf;
    _ = len;
    // TODO: free via the allocator used in dfp_encode.
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

test "dfp_identify returns not-yet-implemented" {
    var out: CIdentifyResult = undefined;
    const raw = [_]u8{ 0, 1, 2 };
    const target = [_]u8{ 0, 1, 2 };
    const rc = dfp_identify(&raw, raw.len, &target, target.len, &out);
    try std.testing.expectEqual(@as(i32, -1), rc);
}
