//! LZ77 match-finding for DEFLATE encoders.
//!
//! Three tokenizers mirror zlib's three deflate strategies:
//!   - `lz77Tokenize`     — `deflate_fast`: greedy match acceptance,
//!                           hash-chain insertion governed by max_lazy_match
//!                           (repurposed as max_insert_length). For L1-L3.
//!   - `lz77TokenizeSlow` — `deflate_slow`: lazy match deferral, full chain
//!                           insertion inside accepted matches. For L4-L9.
//!                           Honors the TOO_FAR(>4096 dist for length-3) and
//!                           Z_FILTERED(reject length<=5) rejection rules.
//!   - `lz77TokenizeRLE`  — `deflate_rle`: distance==1 matches only. Used
//!                           by Z_RLE; collapses L1-L9 to one output.
//!
//! Hash function (shared with zlib): `h = ((h << shift) ^ byte) & mask` with
//! shift=5 and mask=(1<<15)-1 at memLevel=8. NOT a true rolling hash (loses
//! information about bytes outside the 3-byte window) but matches zlib
//! deterministically.
//!
//! **NIL=0 sentinel.** `head[hash]` is initialized to 0; the match-attempt
//! check `if (hash_head != 0)` therefore rejects position 0 as a match
//! source. So a 3-byte input like "AAA" can't match against itself —
//! reproducing this quirk is required for byte-exact agreement with zlib.

const std = @import("std");

pub const Token = union(enum) {
    literal: u8,
    match: Match,
};

pub const Match = struct {
    /// 3..258
    length: u16,
    /// 1..32768
    distance: u16,
};

pub const LZ77Params = struct {
    min_match: u8 = 3,
    max_match: u16 = 258,
    max_chain_length: u32,
    good_match: u16,
    nice_match: u16,
    max_lazy_match: u16,
    /// log2 of hash-table size. zlib default memLevel=8 -> hash_bits=15.
    hash_bits: u5 = 15,
    /// per-byte rolling-hash shift. zlib default memLevel=8 -> hash_shift=5.
    hash_shift: u5 = 5,
    /// Power-of-two LZ77 sliding-window size. zlib default = 32768.
    window_size: usize = 32768,
    /// Z_FILTERED strategy: in deflate_slow, reject matches with length <= 5
    /// (treating them as if no match were found). Has no effect on deflate_fast
    /// since deflate_fast doesn't check strategy in the match-acceptance path.
    filtered: bool = false,
};

/// zlib's `configuration_table[1]`: deflate_fast, greedy, hash-chain depth 4.
/// The `max_lazy_match` field is repurposed by deflate_fast as
/// `max_insert_length`: when an emitted match is `<= max_lazy_match`, the
/// intermediate positions inside the match get inserted into the hash table.
/// Longer matches skip insertion. Reproducing this is critical for matching
/// zlib byte-exactly on inputs with many short (3-4 byte) matches.
pub const LZ77_LEVEL_1: LZ77Params = .{
    .max_chain_length = 4,
    .good_match = 4,
    .nice_match = 8,
    .max_lazy_match = 4,
};

pub const LZ77_LEVEL_2: LZ77Params = .{ .max_chain_length = 8,    .good_match = 4,  .nice_match = 16,  .max_lazy_match = 5 };
pub const LZ77_LEVEL_3: LZ77Params = .{ .max_chain_length = 32,   .good_match = 4,  .nice_match = 32,  .max_lazy_match = 6 };
pub const LZ77_LEVEL_4: LZ77Params = .{ .max_chain_length = 16,   .good_match = 4,  .nice_match = 16,  .max_lazy_match = 4 };
pub const LZ77_LEVEL_5: LZ77Params = .{ .max_chain_length = 32,   .good_match = 8,  .nice_match = 32,  .max_lazy_match = 16 };
pub const LZ77_LEVEL_6: LZ77Params = .{ .max_chain_length = 128,  .good_match = 8,  .nice_match = 128, .max_lazy_match = 16 };
pub const LZ77_LEVEL_7: LZ77Params = .{ .max_chain_length = 256,  .good_match = 8,  .nice_match = 128, .max_lazy_match = 32 };
pub const LZ77_LEVEL_8: LZ77Params = .{ .max_chain_length = 1024, .good_match = 32, .nice_match = 258, .max_lazy_match = 128 };
pub const LZ77_LEVEL_9: LZ77Params = .{ .max_chain_length = 4096, .good_match = 32, .nice_match = 258, .max_lazy_match = 258 };

// Z_FILTERED variants: same params as the base level but with `filtered=true`.
// Only L4-L9 differ from default (deflate_fast at L1-L3 ignores strategy in
// the match-acceptance path).
pub const LZ77_LEVEL_4_FILTERED: LZ77Params = .{ .max_chain_length = 16,   .good_match = 4,  .nice_match = 16,  .max_lazy_match = 4,   .filtered = true };
pub const LZ77_LEVEL_5_FILTERED: LZ77Params = .{ .max_chain_length = 32,   .good_match = 8,  .nice_match = 32,  .max_lazy_match = 16,  .filtered = true };
pub const LZ77_LEVEL_6_FILTERED: LZ77Params = .{ .max_chain_length = 128,  .good_match = 8,  .nice_match = 128, .max_lazy_match = 16,  .filtered = true };
pub const LZ77_LEVEL_7_FILTERED: LZ77Params = .{ .max_chain_length = 256,  .good_match = 8,  .nice_match = 128, .max_lazy_match = 32,  .filtered = true };
pub const LZ77_LEVEL_8_FILTERED: LZ77Params = .{ .max_chain_length = 1024, .good_match = 32, .nice_match = 258, .max_lazy_match = 128, .filtered = true };
pub const LZ77_LEVEL_9_FILTERED: LZ77Params = .{ .max_chain_length = 4096, .good_match = 32, .nice_match = 258, .max_lazy_match = 258, .filtered = true };

/// Return zlib-style LZ77 params adjusted for `memLevel`.
/// The pending symbol buffer grows through memLevel=9, but observed raw zlib
/// output keeps the hash regime capped at 15 bits for the 32 KiB DEFLATE window.
pub fn withMemLevel(params: LZ77Params, mem_level: u4) LZ77Params {
    std.debug.assert(mem_level >= 1 and mem_level <= 9);
    var adjusted = params;
    adjusted.hash_bits = @intCast(@min(@as(u16, mem_level) + 7, 15));
    adjusted.hash_shift = @intCast((@as(u16, adjusted.hash_bits) + adjusted.min_match - 1) / adjusted.min_match);
    return adjusted;
}

/// zlib's MAX_DIST: the maximum permissible match distance.
/// = window_size - MIN_LOOKAHEAD, where MIN_LOOKAHEAD = max_match + min_match + 1.
/// For default params (window=32768, max_match=258, min_match=3):
/// MAX_DIST = 32768 - 262 = 32506. NOT 32768. Real zlib reserves the last
/// MIN_LOOKAHEAD bytes of the window as a safety buffer for sliding; matches
/// with distance > MAX_DIST are silently rejected. On inputs > 32506 bytes,
/// using the wrong limit causes hash-chain entries to be accepted that zlib
/// would reject, diverging the token stream and breaking byte-exact match.
inline fn maxDist(params: LZ77Params) usize {
    return params.window_size - (@as(usize, params.max_match) + params.min_match + 1);
}

/// Tokenize `raw` into a sequence of literal/match tokens via the LZ77
/// algorithm parameterized by `params`. Matches zlib's `deflate_fast` for
/// level=1 (and is the foundation for levels 2-3; lazy matching for 4-9
/// adds one extra position of lookbehind).
pub fn lz77Tokenize(
    allocator: std.mem.Allocator,
    raw: []const u8,
    params: LZ77Params,
) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);

    if (raw.len == 0) return tokens.toOwnedSlice(allocator);

    const hash_size: usize = @as(usize, 1) << params.hash_bits;
    const hash_mask: u32 = @intCast(hash_size - 1);
    const win_mask: usize = params.window_size - 1;

    var head = try allocator.alloc(u32, hash_size);
    defer allocator.free(head);
    @memset(head, 0); // NIL = 0
    var prev = try allocator.alloc(u32, params.window_size);
    defer allocator.free(prev);
    @memset(prev, 0);

    var strstart: usize = 0;
    var lookahead = raw.len;
    var ins_h: u32 = 0;

    // Pre-load the rolling hash with the first two bytes (zlib's
    // `if (s->lookahead >= MIN_MATCH-1) { UPDATE_HASH(...) twice }` at start).
    if (lookahead >= 2) {
        ins_h = ((@as(u32, raw[0]) << params.hash_shift) ^ @as(u32, raw[1])) & hash_mask;
    } else if (lookahead == 1) {
        ins_h = raw[0];
    }

    while (lookahead > 0) {
        var hash_head: u32 = 0; // NIL
        if (lookahead >= params.min_match) {
            ins_h = ((ins_h << params.hash_shift) ^ @as(u32, raw[strstart + params.min_match - 1])) & hash_mask;
            hash_head = head[ins_h];
            prev[strstart & win_mask] = hash_head;
            head[ins_h] = @intCast(strstart);
        }

        var match_length: u16 = 0;
        var match_distance: u16 = 0;
        if (hash_head != 0
            and strstart > hash_head
            and (strstart - hash_head) <= maxDist(params)
            and lookahead >= params.min_match)
        {
            // Greedy: `prev_length = 0` so longestMatch reports any match >= MIN_MATCH.
            const result = longestMatch(raw, strstart, hash_head, prev, params, lookahead, win_mask, params.min_match - 1);
            if (result.length >= params.min_match) {
                match_length = result.length;
                match_distance = @intCast(strstart - result.start);
            }
        }

        if (match_length >= params.min_match) {
            try tokens.append(allocator, .{ .match = .{ .length = match_length, .distance = match_distance } });
            lookahead -= match_length;

            // zlib's deflate_fast: when `match_length <= max_insert_length`
            // (which equals max_lazy_match in this struct), insert all
            // intermediate positions inside the match into the hash chain.
            if (match_length <= params.max_lazy_match and lookahead >= params.min_match) {
                var i: u16 = 1;
                while (i < match_length) : (i += 1) {
                    strstart += 1;
                    ins_h = ((ins_h << params.hash_shift) ^ @as(u32, raw[strstart + params.min_match - 1])) & hash_mask;
                    const ph = head[ins_h];
                    prev[strstart & win_mask] = ph;
                    head[ins_h] = @intCast(strstart);
                }
                strstart += 1;
            } else {
                strstart += match_length;
                if (lookahead >= 2) {
                    ins_h = ((@as(u32, raw[strstart]) << params.hash_shift) ^ @as(u32, raw[strstart + 1])) & hash_mask;
                } else if (lookahead == 1) {
                    ins_h = raw[strstart];
                }
            }
        } else {
            try tokens.append(allocator, .{ .literal = raw[strstart] });
            lookahead -= 1;
            strstart += 1;
        }
    }

    return tokens.toOwnedSlice(allocator);
}

/// LZ77 with lazy matching, matching zlib's `deflate_slow` for levels 4-9.
/// The algorithm defers each match by one position to check whether the
/// next position offers a longer match. If so, the current position is
/// emitted as a literal and we accept the longer match; otherwise the
/// deferred match is accepted.
pub fn lz77TokenizeSlow(
    allocator: std.mem.Allocator,
    raw: []const u8,
    params: LZ77Params,
) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);
    if (raw.len == 0) return tokens.toOwnedSlice(allocator);

    const hash_size: usize = @as(usize, 1) << params.hash_bits;
    const hash_mask: u32 = @intCast(hash_size - 1);
    const win_mask: usize = params.window_size - 1;

    var head = try allocator.alloc(u32, hash_size);
    defer allocator.free(head);
    @memset(head, 0);
    var prev = try allocator.alloc(u32, params.window_size);
    defer allocator.free(prev);
    @memset(prev, 0);

    var strstart: usize = 0;
    var lookahead: usize = raw.len;
    var ins_h: u32 = 0;

    if (lookahead >= 2) {
        ins_h = ((@as(u32, raw[0]) << params.hash_shift) ^ @as(u32, raw[1])) & hash_mask;
    } else if (lookahead == 1) {
        ins_h = raw[0];
    }

    // Lazy-match state.
    var prev_length: u16 = params.min_match - 1; // 2
    var prev_match: u32 = 0;
    var match_length: u16 = params.min_match - 1;
    var match_start: u32 = 0;
    var match_available: bool = false;

    while (lookahead > 0) {
        // 1. Hash + INSERT_STRING at current strstart.
        var hash_head: u32 = 0;
        if (lookahead >= params.min_match) {
            ins_h = ((ins_h << params.hash_shift) ^ @as(u32, raw[strstart + params.min_match - 1])) & hash_mask;
            hash_head = head[ins_h];
            prev[strstart & win_mask] = hash_head;
            head[ins_h] = @intCast(strstart);
        }

        // 2. Save previous match info; reset current.
        prev_length = match_length;
        prev_match = match_start;
        match_length = params.min_match - 1;

        // 3. Try a new (current-position) match if conditions allow.
        if (hash_head != 0
            and prev_length < params.max_lazy_match
            and strstart > hash_head
            and (strstart - hash_head) <= maxDist(params)
            and lookahead >= params.min_match)
        {
            const result = longestMatch(raw, strstart, hash_head, prev, params, lookahead, win_mask, prev_length);
            if (result.length >= params.min_match and result.length > prev_length) {
                match_length = result.length;
                match_start = result.start;
            }
            // zlib's deflate_slow rejects two classes of "short matches":
            //   1) Z_FILTERED strategy: any match with length <= 5.
            //   2) TOO_FAR rule (always on): length=3 match with distance > 4096.
            // Both write match_length back to the no-match sentinel.
            const dist: usize = if (match_length >= params.min_match)
                @intCast(strstart - match_start)
            else
                0;
            const too_far_reject = match_length == params.min_match and dist > 4096;
            const filtered_reject = params.filtered and match_length >= params.min_match and match_length <= 5;
            if (too_far_reject or filtered_reject) {
                match_length = params.min_match - 1;
            }
        }

        // 4. Decision tree.
        if (prev_length >= params.min_match and match_length <= prev_length) {
            // Accept the previous match (it started at strstart-1).
            const dist: u16 = @intCast((strstart - 1) - prev_match);
            try tokens.append(allocator, .{ .match = .{ .length = prev_length, .distance = dist } });

            const max_insert: usize = strstart + lookahead - params.min_match;
            lookahead -= prev_length - 1;
            var remaining: u16 = prev_length - 2;
            while (remaining != 0) : (remaining -= 1) {
                strstart += 1;
                if (strstart <= max_insert) {
                    ins_h = ((ins_h << params.hash_shift) ^ @as(u32, raw[strstart + params.min_match - 1])) & hash_mask;
                    const ph = head[ins_h];
                    prev[strstart & win_mask] = ph;
                    head[ins_h] = @intCast(strstart);
                }
            }
            match_available = false;
            match_length = params.min_match - 1;
            strstart += 1;
        } else if (match_available) {
            // No new match (or shorter than prev). Emit the deferred literal.
            try tokens.append(allocator, .{ .literal = raw[strstart - 1] });
            strstart += 1;
            lookahead -= 1;
        } else {
            // No deferred byte yet. Set the flag for next iteration.
            match_available = true;
            strstart += 1;
            lookahead -= 1;
        }
    }

    // Flush remaining lazy literal at end of input.
    if (match_available) {
        try tokens.append(allocator, .{ .literal = raw[strstart - 1] });
    }

    return tokens.toOwnedSlice(allocator);
}

/// RLE-only tokenizer for Z_RLE strategy. Looks at the previous byte (one
/// position back) and emits a `match(length, distance=1)` for any run of
/// 3+ identical bytes. Hash chains unused. Levels 1-9 + Z_RLE all collapse
/// to identical output. L0 + Z_RLE emits STORED (covered elsewhere).
pub fn lz77TokenizeRLE(allocator: std.mem.Allocator, raw: []const u8) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);
    const min_match: usize = 3;
    const max_match: usize = 258;
    var pos: usize = 0;
    while (pos < raw.len) {
        const lookahead = raw.len - pos;
        // Need a prior byte and at least MIN_MATCH bytes of lookahead.
        if (pos == 0 or lookahead < min_match) {
            try tokens.append(allocator, .{ .literal = raw[pos] });
            pos += 1;
            continue;
        }
        const prev = raw[pos - 1];
        if (raw[pos] != prev or raw[pos + 1] != prev or raw[pos + 2] != prev) {
            try tokens.append(allocator, .{ .literal = raw[pos] });
            pos += 1;
            continue;
        }
        var len: usize = 3;
        const cap = @min(max_match, lookahead);
        while (len < cap and raw[pos + len] == prev) : (len += 1) {}
        try tokens.append(allocator, .{ .match = .{
            .length = @intCast(len),
            .distance = 1,
        } });
        pos += len;
    }
    return tokens.toOwnedSlice(allocator);
}

/// Result of `longestMatch`: the longest match length found, and the
/// position (in `raw`) where it was found. Length 0 means no match
/// satisfying `>= prev_length + 1` was found at any chain entry.
const MatchResult = struct {
    length: u16,
    start: u32,
};

/// Walk the hash chain starting at `cur_match`, returning the longest
/// match length AND the position where it was found. Honors zlib's
/// optimizations:
///   - `best_len` starts at `prev_length` so we only search for strictly
///     longer matches.
///   - Chain length is halved when `prev_length >= good_match`.
///   - Loop exits when a match `>= nice_match` is found.
fn longestMatch(
    raw: []const u8,
    strstart: usize,
    cur_match_in: u32,
    prev: []const u32,
    params: LZ77Params,
    lookahead: usize,
    win_mask: usize,
    prev_length: u16,
) MatchResult {
    var chain_length: u32 = params.max_chain_length;
    if (prev_length >= params.good_match) chain_length >>= 2;

    var best_len: u16 = prev_length;
    var best_start: u32 = 0;
    const max_len: u16 = @intCast(@min(@as(usize, params.max_match), lookahead));
    var cur_match: usize = cur_match_in;

    // zlib's longest_match stops walking the chain when cur_match goes below
    // `limit = strstart - MAX_DIST` — matches with distance > MAX_DIST are
    // never considered. Without this, on inputs > 32506 bytes our chain walks
    // accept stale positions zlib already discards via slide_hash, diverging
    // the token stream.
    const md = maxDist(params);
    const limit: usize = if (strstart > md) strstart - md else 0;

    while (true) {
        if (cur_match >= strstart) break;
        if (cur_match <= limit) break;

        var n: u16 = 0;
        while (n < max_len and raw[strstart + n] == raw[cur_match + n]) : (n += 1) {}
        if (n > best_len) {
            best_len = n;
            best_start = @intCast(cur_match);
            if (n >= params.nice_match) break;
        }

        chain_length -= 1;
        if (chain_length == 0) break;

        const next = prev[cur_match & win_mask];
        if (next == 0) break;
        if (next >= cur_match) break;
        cur_match = next;
    }

    if (best_len > prev_length) {
        return .{ .length = best_len, .start = best_start };
    }
    return .{ .length = 0, .start = 0 };
}
