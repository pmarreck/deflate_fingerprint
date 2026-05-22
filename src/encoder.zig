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

// ─── Phase A: canonical Huffman tree builder (zlib-faithful) ──────────────
//
// Port of zlib's `build_tree` from trees.c. Given symbol frequencies, produces
// code lengths matching what zlib emits byte-for-byte. The key invariant is
// the depth-aware tie-breaker — many valid canonical Huffman trees exist for
// the same frequencies; zlib produces a *specific* one, driven by the
// `smaller(n, m, depth) = freq[n] < freq[m] || (freq[n]==freq[m] && depth[n] <= depth[m])`
// comparator. Reproducing zlib's tree shape requires reproducing this rule.
//
// Caller passes per-symbol frequencies; we fill `out_lengths` with code-
// lengths (0 = unused). Max code length capped at `max_length` (15 bits for
// literal/distance trees, 7 for the code-length-code tree per RFC 1951).
//
// "At least 2 leaves" rule: PKZIP format requires that every Huffman tree
// have at least two codes (so at least one bit is sent even for trivial
// trees). If the frequency table has 0 or 1 non-zero entry, we synthesize
// dummy symbols with freq=1 to bring the leaf count up to 2.

/// Build canonical Huffman code lengths from `frequencies`, matching zlib's
/// build_tree exactly. Symbols with zero frequency get length 0 unless
/// promoted by the "at least 2 leaves" rule.
pub fn buildHuffmanLengths(
    allocator: std.mem.Allocator,
    frequencies: []const u16,
    max_length: u4,
    out_lengths: []u8,
) !void {
    std.debug.assert(out_lengths.len >= frequencies.len);
    @memset(out_lengths, 0);

    const n_symbols = frequencies.len;
    // Scratch space: indices and metadata for up to (n_symbols + n_internal)
    // = 2*n_symbols - 1 nodes. We reserve `2 * n_symbols + 1` for the
    // 1-indexed heap (heap[0] unused) plus internal-node indices.
    const cap: usize = 2 * n_symbols + 1;

    var heap = try allocator.alloc(u16, cap);
    defer allocator.free(heap);
    @memset(heap, 0);
    var depth = try allocator.alloc(u8, cap);
    defer allocator.free(depth);
    @memset(depth, 0);
    var parent = try allocator.alloc(u16, cap);
    defer allocator.free(parent);
    @memset(parent, 0);
    var freq = try allocator.alloc(u32, cap);
    defer allocator.free(freq);
    @memset(freq, 0);
    var lens = try allocator.alloc(u8, cap);
    defer allocator.free(lens);
    @memset(lens, 0);

    // Initial heap: add every non-zero-frequency symbol.
    var heap_len: usize = 0;
    var max_code: i32 = -1;
    for (frequencies, 0..) |f, i| {
        if (f != 0) {
            heap_len += 1;
            heap[heap_len] = @intCast(i);
            freq[i] = f;
            max_code = @intCast(i);
            depth[i] = 0;
        }
    }

    // "At least 2 leaves" rule.
    while (heap_len < 2) {
        heap_len += 1;
        const node: u16 = if (max_code < 2) blk: {
            max_code += 1;
            break :blk @intCast(max_code);
        } else 0;
        heap[heap_len] = node;
        freq[node] = 1;
        depth[node] = 0;
    }

    // Heapify.
    if (heap_len >= 2) {
        var k: usize = heap_len / 2;
        while (true) : (k -= 1) {
            pqdownheap(heap, k, heap_len, freq, depth);
            if (k == 1) break;
        }
    }

    // Combine the two least-frequent nodes until heap_len == 1.
    var heap_max: usize = cap;
    var next_internal: usize = @intCast(max_code + 1);
    while (heap_len >= 2) {
        // Remove smallest (heap[1]).
        const n = heap[1];
        heap[1] = heap[heap_len];
        heap_len -= 1;
        if (heap_len >= 1) pqdownheap(heap, 1, heap_len, freq, depth);

        const m = heap[1]; // now-smallest after the previous removal

        // Stash both for the post-order length walk later.
        heap_max -= 1;
        heap[heap_max] = n;
        heap_max -= 1;
        heap[heap_max] = m;

        // Internal node: freq = sum, depth = max(child depths) + 1.
        freq[next_internal] = freq[n] + freq[m];
        depth[next_internal] = @max(depth[n], depth[m]) + 1;
        parent[n] = @intCast(next_internal);
        parent[m] = @intCast(next_internal);

        // Replace m at the heap root with the new internal node and re-sift.
        heap[1] = @intCast(next_internal);
        pqdownheap(heap, 1, heap_len, freq, depth);

        next_internal += 1;
    }

    // The last surviving heap element is the root.
    heap_max -= 1;
    heap[heap_max] = heap[1];

    // gen_bitlen: walk the stored heap[heap_max+1..cap-1] in post-order
    // assigning Len = parent.Len + 1. The root (at heap[heap_max]) has Len=0.
    lens[heap[heap_max]] = 0;

    // bl_count[i] = number of *leaf* codes of length i. Used for overflow fixup.
    var bl_count = try allocator.alloc(u32, @as(usize, max_length) + 2);
    defer allocator.free(bl_count);
    @memset(bl_count, 0);

    var overflow: u32 = 0;
    {
        var h: usize = heap_max + 1;
        while (h < cap) : (h += 1) {
            const node = heap[h];
            var bits: u8 = lens[parent[node]] + 1;
            if (bits > max_length) {
                bits = max_length;
                overflow += 1;
            }
            lens[node] = bits;
            // Only count leaves (i.e. original symbols 0..max_code).
            if (@as(i32, node) <= max_code) {
                bl_count[bits] += 1;
            }
        }
    }

    // Overflow handling: same iterative redistribution zlib performs.
    if (overflow > 0) {
        // Move pairs of overflow leaves down to shorter codes.
        while (overflow > 0) {
            var bits: usize = @as(usize, max_length) - 1;
            while (bl_count[bits] == 0) bits -= 1;
            bl_count[bits] -= 1;
            bl_count[bits + 1] += 2;
            bl_count[max_length] -= 1;
            overflow -= 2;
        }
        // Recompute leaf lengths in increasing order of frequency. Walk
        // heap[cap-1..heap_max+1] (the order frequencies were stashed —
        // greater frequencies first in heap_max+1 direction).
        var bits: usize = max_length;
        var h: usize = cap;
        while (bits != 0) : (bits -= 1) {
            var n_at_bits = bl_count[bits];
            while (n_at_bits != 0) {
                h -= 1;
                const m = heap[h];
                if (@as(i32, m) > max_code) continue;
                lens[m] = @intCast(bits);
                n_at_bits -= 1;
            }
        }
    }

    // Copy lengths for actual symbols (0..max_code) into the caller's slice.
    if (max_code >= 0) {
        const limit: usize = @intCast(max_code);
        var i: usize = 0;
        while (i <= limit) : (i += 1) {
            out_lengths[i] = lens[i];
        }
    }
}

/// zlib's `smaller(n, m)` heap-order comparator. Returns true if `n` should
/// be ordered before `m` in the min-heap. Frequencies first, depth as
/// tie-breaker. Critically, when both frequency AND depth are equal, this
/// returns true (because `<=`) — this is the zlib quirk that determines
/// which valid canonical Huffman tree zlib actually emits.
inline fn smaller(n: u16, m: u16, freq: []const u32, depth: []const u8) bool {
    return freq[n] < freq[m] or (freq[n] == freq[m] and depth[n] <= depth[m]);
}

/// 1-indexed min-heap sift-down. Operates over `heap[1..heap_len]`.
fn pqdownheap(heap: []u16, k_in: usize, heap_len: usize, freq: []const u32, depth: []const u8) void {
    var k = k_in;
    const v = heap[k];
    var j = 2 * k;
    while (j <= heap_len) {
        // Pick the smaller of the two children.
        if (j < heap_len and smaller(heap[j + 1], heap[j], freq, depth)) j += 1;
        // If v is smaller than the chosen child, we're done.
        if (smaller(v, heap[j], freq, depth)) break;
        heap[k] = heap[j];
        k = j;
        j = 2 * k;
    }
    heap[k] = v;
}

// ─── Phase A tests ───────────────────────────────────────────────────────

test "buildHuffmanLengths: 2-symbol case (the most common DYNAMIC shape)" {
    // Frequencies for 'A'*14 input under HUFFMAN_ONLY: lit[65]=14, lit[256]=1.
    // Both should get 1-bit codes, all other symbols 0.
    var freq = [_]u16{0} ** 286;
    freq[65] = 14;
    freq[256] = 1;
    var lens = [_]u8{0} ** 286;
    try buildHuffmanLengths(testing.allocator, &freq, 15, &lens);
    try testing.expectEqual(@as(u8, 1), lens[65]);
    try testing.expectEqual(@as(u8, 1), lens[256]);
    // Spot-check that other symbols remain 0.
    try testing.expectEqual(@as(u8, 0), lens[0]);
    try testing.expectEqual(@as(u8, 0), lens[64]);
    try testing.expectEqual(@as(u8, 0), lens[66]);
    try testing.expectEqual(@as(u8, 0), lens[255]);
}

test "buildHuffmanLengths: NUL*12 case (literal at index 0)" {
    var freq = [_]u16{0} ** 286;
    freq[0] = 12;
    freq[256] = 1;
    var lens = [_]u8{0} ** 286;
    try buildHuffmanLengths(testing.allocator, &freq, 15, &lens);
    try testing.expectEqual(@as(u8, 1), lens[0]);
    try testing.expectEqual(@as(u8, 1), lens[256]);
}

test "buildHuffmanLengths: 3-symbol skewed (10/1/1) — zlib tie-breaks predictable" {
    // freq[A]=10, freq[B]=1, freq[EOB]=1. Smallest two (B, EOB) combine first
    // into a depth-1 node; that combines with A (depth-0). Expected lengths:
    //   A=1, B=2, EOB=2.
    var freq = [_]u16{0} ** 286;
    freq[65] = 10; // 'A'
    freq[66] = 1;  // 'B'
    freq[256] = 1; // EOB
    var lens = [_]u8{0} ** 286;
    try buildHuffmanLengths(testing.allocator, &freq, 15, &lens);
    try testing.expectEqual(@as(u8, 1), lens[65]);
    try testing.expectEqual(@as(u8, 2), lens[66]);
    try testing.expectEqual(@as(u8, 2), lens[256]);
}

test "buildHuffmanLengths: single-symbol input gets promoted to 2 leaves" {
    // Just freq[5] non-zero. The "at least 2 leaves" rule synthesizes a
    // second symbol (here sym 0 or sym 1 per zlib's `max_code < 2 ? ++max_code : 0`
    // rule). Both end up with length 1.
    var freq = [_]u16{0} ** 286;
    freq[5] = 3;
    var lens = [_]u8{0} ** 286;
    try buildHuffmanLengths(testing.allocator, &freq, 15, &lens);
    try testing.expectEqual(@as(u8, 1), lens[5]);
    // The synthesized dummy is sym 0 (since max_code starts at 5 which is >=2,
    // so the rule sets node=0).
    try testing.expectEqual(@as(u8, 1), lens[0]);
}

test "buildHuffmanLengths: zero-frequency input gets two dummy length-1 codes" {
    // All zero — RFC distance-tree case for HUFFMAN_ONLY (no matches).
    // Should produce dummies at symbols 0 and 1 with length 1 each.
    const freq = [_]u16{0} ** 30;
    var lens = [_]u8{0} ** 30;
    try buildHuffmanLengths(testing.allocator, &freq, 15, &lens);
    try testing.expectEqual(@as(u8, 1), lens[0]);
    try testing.expectEqual(@as(u8, 1), lens[1]);
    try testing.expectEqual(@as(u8, 0), lens[2]);
}

test "buildHuffmanLengths: alternating 'A'/0xFF * 14 frequencies" {
    // freq[65]=7, freq[255]=7, freq[256]=1.
    // Smallest is EOB (1). After heapify in symbol order, EOB at root.
    // Combine EOB+sym65 (both depth 0 — smaller(65, 255) with equal freq=7
    // gives smaller(65,255)=true since depth equal and 65 is earlier).
    // Result: internal_257 = depth-1, freq 8.
    // Combine internal_257 + sym255 = internal_258 = depth-2, freq 15.
    // Lengths: sym255 = 1, sym65 = 2, sym256 = 2.
    var freq = [_]u16{0} ** 286;
    freq[65] = 7;
    freq[255] = 7;
    freq[256] = 1;
    var lens = [_]u8{0} ** 286;
    try buildHuffmanLengths(testing.allocator, &freq, 15, &lens);
    try testing.expectEqual(@as(u8, 1), lens[255]);
    try testing.expectEqual(@as(u8, 2), lens[65]);
    try testing.expectEqual(@as(u8, 2), lens[256]);
}

// ─── Phase B+C: dynamic Huffman block encoder ─────────────────────────────
//
// Composes Phase A (tree builder) with:
//   - canonical-code assignment per RFC 1951 §3.2.2
//   - scan_tree / send_tree (zlib's RLE encoding of code-length sequences)
//   - the RFC 1951 §3.2.7 tree-of-trees emission
//
// Encodes a single DYNAMIC block (BFINAL=1, BTYPE=10) reproducing zlib
// HUFFMAN_ONLY byte-exactly for tiny inputs. No LZ77 matches — literal
// frequencies only, distance tree gets the RFC-required dummies.
//
// The RLE alphabet has 19 symbols:
//   0..15  : a literal code-length (0..15)
//   16     : "repeat previous code-length", 3..6 times, followed by 2 extra bits
//   17     : "run of 3..10 zero code-lengths", followed by 3 extra bits
//   18     : "run of 11..138 zero code-lengths", followed by 7 extra bits

const REP_3_6:     u8 = 16;
const REPZ_3_10:   u8 = 17;
const REPZ_11_138: u8 = 18;

/// RFC 1951 §3.2.7 bl_order: the permutation in which code-length-code
/// lengths are emitted, so that trailing zero entries can be elided via HCLEN.
const BL_ORDER = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// Walk a code-length sequence and accumulate the bl_freq[] table that
/// describes how often each RLE symbol (0..18) will be used by send_tree.
/// Matches zlib's `scan_tree` decisions byte-for-byte.
fn scanCodeLengths(lens: []const u8, n_codes: usize, bl_freq: *[19]u16) void {
    if (n_codes == 0) return;

    var prevlen: i32 = -1;
    var nextlen: u8 = lens[0];
    var curlen: u8 = 0;
    var count: u32 = 0;
    var max_count: u32 = 7;
    var min_count: u32 = 4;
    if (nextlen == 0) {
        max_count = 138;
        min_count = 3;
    }

    var n: usize = 0;
    while (n < n_codes) : (n += 1) {
        curlen = nextlen;
        nextlen = if (n + 1 < n_codes) lens[n + 1] else 0xff; // sentinel: forces break
        count += 1;
        if (count < max_count and curlen == nextlen) continue;

        if (count < min_count) {
            bl_freq[curlen] += @intCast(count);
        } else if (curlen != 0) {
            if (@as(i32, curlen) != prevlen) bl_freq[curlen] += 1;
            bl_freq[REP_3_6] += 1;
        } else if (count <= 10) {
            bl_freq[REPZ_3_10] += 1;
        } else {
            bl_freq[REPZ_11_138] += 1;
        }

        count = 0;
        prevlen = @intCast(curlen);
        if (nextlen == 0) {
            max_count = 138;
            min_count = 3;
        } else if (curlen == nextlen) {
            max_count = 6;
            min_count = 3;
        } else {
            max_count = 7;
            min_count = 4;
        }
    }
}

/// Emit a code-length sequence via the CL-code Huffman tree. The
/// reverse-of-scan: same control flow, but emits bits instead of counting.
fn sendCodeLengths(
    bw: *BitWriter,
    lens: []const u8,
    n_codes: usize,
    bl_codes: *const [19]u32,
    bl_lens: *const [19]u8,
) !void {
    if (n_codes == 0) return;
    var prevlen: i32 = -1;
    var nextlen: u8 = lens[0];
    var curlen: u8 = 0;
    var count: u32 = 0;
    var max_count: u32 = 7;
    var min_count: u32 = 4;
    if (nextlen == 0) {
        max_count = 138;
        min_count = 3;
    }

    var n: usize = 0;
    while (n < n_codes) : (n += 1) {
        curlen = nextlen;
        nextlen = if (n + 1 < n_codes) lens[n + 1] else 0xff;
        count += 1;
        if (count < max_count and curlen == nextlen) continue;

        if (count < min_count) {
            var c: u32 = 0;
            while (c < count) : (c += 1) {
                try emitCLSymbol(bw, curlen, bl_codes, bl_lens);
            }
        } else if (curlen != 0) {
            if (@as(i32, curlen) != prevlen) {
                try emitCLSymbol(bw, curlen, bl_codes, bl_lens);
                count -= 1;
            }
            std.debug.assert(count >= 3 and count <= 6);
            try emitCLSymbol(bw, REP_3_6, bl_codes, bl_lens);
            try bw.writeBits(count - 3, 2);
        } else if (count <= 10) {
            std.debug.assert(count >= 3);
            try emitCLSymbol(bw, REPZ_3_10, bl_codes, bl_lens);
            try bw.writeBits(count - 3, 3);
        } else {
            std.debug.assert(count >= 11 and count <= 138);
            try emitCLSymbol(bw, REPZ_11_138, bl_codes, bl_lens);
            try bw.writeBits(count - 11, 7);
        }

        count = 0;
        prevlen = @intCast(curlen);
        if (nextlen == 0) {
            max_count = 138;
            min_count = 3;
        } else if (curlen == nextlen) {
            max_count = 6;
            min_count = 3;
        } else {
            max_count = 7;
            min_count = 4;
        }
    }
}

inline fn emitCLSymbol(bw: *BitWriter, sym: u8, codes: *const [19]u32, lens: *const [19]u8) !void {
    const code = codes[sym];
    const nb: u6 = @intCast(lens[sym]);
    std.debug.assert(nb != 0);
    try bw.writeBits(reverseBits(@intCast(code), nb), nb);
}

/// Compute canonical Huffman codes from a code-length array (RFC 1951 §3.2.2).
/// Codes are assigned by walking lengths in ascending order, with symbols
/// sorted by symbol value at each length. Result codes are MSB-first; the
/// caller bit-reverses them at emission time for our LSB-first BitWriter.
fn computeCanonicalCodes(lens: []const u8, codes_out: []u32) void {
    @memset(codes_out, 0);
    var bl_count = [_]u32{0} ** 16; // max length 15
    for (lens) |l| {
        if (l != 0) bl_count[l] += 1;
    }

    // next_code[bits] = next canonical code value at that bit-length.
    var next_code = [_]u32{0} ** 16;
    var code: u32 = 0;
    for (1..16) |bits| {
        code = (code + bl_count[bits - 1]) << 1;
        next_code[bits] = code;
    }

    for (lens, 0..) |l, i| {
        if (l != 0) {
            codes_out[i] = next_code[l];
            next_code[l] += 1;
        }
    }
}

/// Encode `raw` as a single DEFLATE BFINAL=1/BTYPE=10 (dynamic Huffman) block
/// containing only literals + EOB. No LZ77 matches. The literal Huffman tree
/// is built from `raw`'s symbol histogram + EOB; the distance tree gets the
/// RFC-required two dummy length-1 codes (since no matches exist). Output
/// matches zlib HUFFMAN_ONLY byte-for-byte for inputs where zlib picks
/// DYNAMIC over FIXED/STORED — see docs/ENCODER_NOTES.md.
pub fn encodeDynamicHuffmanLiterals(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
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
        if (lit_lens[i] != 0) { max_lit = i; break; }
    }
    var max_dist: usize = 0;
    var j: usize = 29;
    while (j > 0) : (j -= 1) {
        if (dist_lens[j] != 0) { max_dist = j; break; }
    }
    const hlit_count: usize = max_lit + 1;  // 257..286
    const hdist_count: usize = max_dist + 1; // 1..30

    // 5. Scan lit+dist length sequences to build bl_freq.
    var bl_freq = [_]u16{0} ** 19;
    scanCodeLengths(&lit_lens, hlit_count, &bl_freq);
    scanCodeLengths(&dist_lens, hdist_count, &bl_freq);

    // 6. Build CL Huffman tree (max length 7 per RFC).
    var bl_lens = [_]u8{0} ** 19;
    try buildHuffmanLengths(allocator, &bl_freq, 7, &bl_lens);

    // 7. Find HCLEN — highest bl_order index whose CL length is non-zero.
    //    Always emit at least 4 entries (HCLEN field min value = 0).
    var hclen_count: usize = 4;
    var k: usize = 19;
    while (k > 4) : (k -= 1) {
        if (bl_lens[BL_ORDER[k - 1]] != 0) {
            hclen_count = k;
            break;
        }
    }

    // 8. Compute canonical codes (CL, lit, dist).
    var bl_codes: [19]u32 = undefined;
    computeCanonicalCodes(&bl_lens, &bl_codes);
    var lit_codes: [286]u32 = undefined;
    computeCanonicalCodes(&lit_lens, &lit_codes);
    var dist_codes: [30]u32 = undefined;
    computeCanonicalCodes(&dist_lens, &dist_codes);

    // 9. Emit the block.
    var bw = BitWriter.init(allocator);
    errdefer bw.deinit();

    // 3-bit header: BFINAL=1, BTYPE=10. Combined LSB-first: bit0=1, bit1=0, bit2=1 = 0b101 = 5.
    try bw.writeBits(5, 3);

    // 5-bit HLIT = hlit_count - 257, 5-bit HDIST = hdist_count - 1, 4-bit HCLEN = hclen_count - 4.
    try bw.writeBits(@intCast(hlit_count - 257), 5);
    try bw.writeBits(@intCast(hdist_count - 1), 5);
    try bw.writeBits(@intCast(hclen_count - 4), 4);

    // (HCLEN + 4) 3-bit CL code-lengths in bl_order.
    var b: usize = 0;
    while (b < hclen_count) : (b += 1) {
        try bw.writeBits(bl_lens[BL_ORDER[b]], 3);
    }

    // RLE-encoded literal and distance code-length sequences.
    try sendCodeLengths(&bw, &lit_lens, hlit_count, &bl_codes, &bl_lens);
    try sendCodeLengths(&bw, &dist_lens, hdist_count, &bl_codes, &bl_lens);

    // Literal data: for each input byte, emit its Huffman code (bit-reversed).
    for (raw) |byte| {
        const code = lit_codes[byte];
        const nbits: u6 = @intCast(lit_lens[byte]);
        std.debug.assert(nbits != 0);
        try bw.writeBits(reverseBits(@intCast(code), nbits), nbits);
    }

    // EOB symbol 256.
    const eob_code = lit_codes[256];
    const eob_nbits: u6 = @intCast(lit_lens[256]);
    std.debug.assert(eob_nbits != 0);
    try bw.writeBits(reverseBits(@intCast(eob_code), eob_nbits), eob_nbits);

    return bw.toOwnedSlice();
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
