//! Huffman tree construction + canonical-code assignment + RLE-encoded
//! code-length sequences (the tree-of-trees machinery from RFC 1951 §3.2.7).
//!
//! `buildHuffmanLengths` is a faithful port of zlib's `build_tree`: depth-aware
//! min-heap with the specific tie-break (`smaller` returns true for equal
//! freq + equal-or-lower depth) that determines which of the many valid
//! canonical Huffman trees zlib actually emits. Includes the 15-bit overflow
//! redistribution.
//!
//! `scanCodeLengths` / `sendCodeLengths` are zlib's `scan_tree` / `send_tree`
//! — RLE over code-length sequences using the 19-symbol CL alphabet (literal
//! codelengths 0..15, REP_3_6=16, REPZ_3_10=17, REPZ_11_138=18).

const std = @import("std");
const bitstream = @import("bitstream.zig");
const BitWriter = bitstream.BitWriter;
const reverseBits = bitstream.reverseBits;
const testing = std.testing;

// ─── Phase A: Huffman tree builder ───────────────────────────────────────

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
        while (overflow > 0) {
            var bits: usize = @as(usize, max_length) - 1;
            while (bl_count[bits] == 0) bits -= 1;
            bl_count[bits] -= 1;
            bl_count[bits + 1] += 2;
            bl_count[max_length] -= 1;
            overflow -= 2;
        }
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
        if (j < heap_len and smaller(heap[j + 1], heap[j], freq, depth)) j += 1;
        if (smaller(v, heap[j], freq, depth)) break;
        heap[k] = heap[j];
        k = j;
        j = 2 * k;
    }
    heap[k] = v;
}

// ─── Phase B+C: code-length RLE (scan_tree / send_tree) ──────────────────

pub const REP_3_6:     u8 = 16;
pub const REPZ_3_10:   u8 = 17;
pub const REPZ_11_138: u8 = 18;

/// RFC 1951 §3.2.7 bl_order: the permutation in which code-length-code
/// lengths are emitted, so that trailing zero entries can be elided via HCLEN.
pub const BL_ORDER = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// Walk a code-length sequence and accumulate the bl_freq[] table that
/// describes how often each RLE symbol (0..18) will be used by send_tree.
/// Matches zlib's `scan_tree` decisions byte-for-byte.
pub fn scanCodeLengths(lens: []const u8, n_codes: usize, bl_freq: *[19]u16) void {
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
pub fn sendCodeLengths(
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
pub fn computeCanonicalCodes(lens: []const u8, codes_out: []u32) void {
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

// ─── Tests ────────────────────────────────────────────────────────────────

test "buildHuffmanLengths: 2-symbol case (the most common DYNAMIC shape)" {
    var freq = [_]u16{0} ** 286;
    freq[65] = 14;
    freq[256] = 1;
    var lens = [_]u8{0} ** 286;
    try buildHuffmanLengths(testing.allocator, &freq, 15, &lens);
    try testing.expectEqual(@as(u8, 1), lens[65]);
    try testing.expectEqual(@as(u8, 1), lens[256]);
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
    var freq = [_]u16{0} ** 286;
    freq[65] = 10;
    freq[66] = 1;
    freq[256] = 1;
    var lens = [_]u8{0} ** 286;
    try buildHuffmanLengths(testing.allocator, &freq, 15, &lens);
    try testing.expectEqual(@as(u8, 1), lens[65]);
    try testing.expectEqual(@as(u8, 2), lens[66]);
    try testing.expectEqual(@as(u8, 2), lens[256]);
}

test "buildHuffmanLengths: single-symbol input gets promoted to 2 leaves" {
    var freq = [_]u16{0} ** 286;
    freq[5] = 3;
    var lens = [_]u8{0} ** 286;
    try buildHuffmanLengths(testing.allocator, &freq, 15, &lens);
    try testing.expectEqual(@as(u8, 1), lens[5]);
    try testing.expectEqual(@as(u8, 1), lens[0]);
}

test "buildHuffmanLengths: zero-frequency input gets two dummy length-1 codes" {
    const freq = [_]u16{0} ** 30;
    var lens = [_]u8{0} ** 30;
    try buildHuffmanLengths(testing.allocator, &freq, 15, &lens);
    try testing.expectEqual(@as(u8, 1), lens[0]);
    try testing.expectEqual(@as(u8, 1), lens[1]);
    try testing.expectEqual(@as(u8, 0), lens[2]);
}

test "buildHuffmanLengths: alternating 'A'/0xFF * 14 frequencies" {
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
