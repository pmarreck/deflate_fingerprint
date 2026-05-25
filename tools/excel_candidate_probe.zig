const std = @import("std");

const dfp = @import("deflate_fingerprint");

fn firstDiff(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return i;
    }
    return n;
}

fn absDiff(a: usize, b: usize) usize {
    return if (a >= b) a - b else b - a;
}

fn absIsize(n: isize) usize {
    return @intCast(if (n < 0) -n else n);
}

fn reportCandidate(
    allocator: std.mem.Allocator,
    name: []const u8,
    got: []const u8,
    target: []const u8,
) !void {
    std.debug.print("{s}: len={d} target={d} first_diff={d} byte_exact={}\n", .{
        name,
        got.len,
        target.len,
        firstDiff(got, target),
        std.mem.eql(u8, got, target),
    });

    const blocks = try dfp.inspect.inspectBlocks(allocator, got);
    defer allocator.free(blocks);
    std.debug.print("  blocks:", .{});
    const limit = @min(blocks.len, 12);
    for (blocks[0..limit]) |block| {
        std.debug.print(" {s}:{d}@{d}-{d}", .{
            @tagName(block.block_type),
            block.token_count,
            block.raw_start,
            block.raw_end,
        });
    }
    if (blocks.len > limit) std.debug.print(" ...+{d}", .{blocks.len - limit});
    std.debug.print("\n", .{});
}

/// Compare decoded LZ77 payload decisions, ignoring compressed-code spelling.
/// Used by the probe to separate tokenization mismatches from Huffman drift.
fn sameToken(a: dfp.inspect.DecodedToken, b: dfp.inspect.DecodedToken) bool {
    return switch (a) {
        .literal => |a_byte| switch (b) {
            .literal => |b_byte| a_byte == b_byte,
            .match => false,
        },
        .match => |a_match| switch (b) {
            .literal => false,
            .match => |b_match| a_match.length == b_match.length and a_match.distance == b_match.distance,
        },
    };
}

/// Print a compact literal/match token for human divergence triage.
/// The output includes byte values so XML punctuation and control bytes remain clear.
fn printToken(token: dfp.inspect.DecodedToken) void {
    switch (token) {
        .literal => |byte| {
            if (byte >= 0x20 and byte <= 0x7e) {
                std.debug.print("literal('{c}'/{d})", .{ byte, byte });
            } else {
                std.debug.print("literal(0x{x:0>2})", .{byte});
            }
        },
        .match => |match| std.debug.print("match(len={d},dist={d})", .{ match.length, match.distance }),
    }
}

/// Print a small printable/raw XML window around the divergent raw offset.
/// Non-printing bytes are escaped or dotted so binary data stays terminal-safe.
fn printRawContext(raw: []const u8, center: usize) void {
    const start = center -| 32;
    const end = @min(raw.len, center + 48);
    std.debug.print("  raw_context[{d}..{d}]=\"", .{ start, end });
    for (raw[start..end]) |byte| {
        if (byte >= 0x20 and byte <= 0x7e) {
            std.debug.print("{c}", .{byte});
        } else if (byte == '\n') {
            std.debug.print("\\n", .{});
        } else if (byte == '\r') {
            std.debug.print("\\r", .{});
        } else if (byte == '\t') {
            std.debug.print("\\t", .{});
        } else {
            std.debug.print(".", .{});
        }
    }
    std.debug.print("\"\n", .{});
}

/// Decode target and candidate streams, then report their first token mismatch.
/// This finds the LZ77 decision that caused a near-reproduction to diverge.
fn reportTokenDivergence(
    allocator: std.mem.Allocator,
    name: []const u8,
    got: []const u8,
    target: []const u8,
    raw: []const u8,
) !void {
    const target_tokens = try dfp.inspect.inspectTokens(allocator, target);
    defer allocator.free(target_tokens);
    const got_tokens = try dfp.inspect.inspectTokens(allocator, got);
    defer allocator.free(got_tokens);

    const n = @min(target_tokens.len, got_tokens.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const target_item = target_tokens[i];
        const got_item = got_tokens[i];
        if (target_item.block_index == got_item.block_index and
            target_item.block_type == got_item.block_type and
            target_item.raw_start == got_item.raw_start and
            target_item.raw_end == got_item.raw_end and
            sameToken(target_item.token, got_item.token))
        {
            continue;
        }

        std.debug.print("  token_divergence {s}: index={d}\n", .{ name, i });
        std.debug.print("    target block={d}/{s} raw={d}-{d} ", .{
            target_item.block_index,
            @tagName(target_item.block_type),
            target_item.raw_start,
            target_item.raw_end,
        });
        printToken(target_item.token);
        std.debug.print("\n", .{});
        std.debug.print("    got    block={d}/{s} raw={d}-{d} ", .{
            got_item.block_index,
            @tagName(got_item.block_type),
            got_item.raw_start,
            got_item.raw_end,
        });
        printToken(got_item.token);
        std.debug.print("\n", .{});
        printRawContext(raw, @min(target_item.raw_start, raw.len));
        return;
    }

    if (target_tokens.len != got_tokens.len) {
        std.debug.print("  token_divergence {s}: common_prefix={d} target_tokens={d} got_tokens={d}\n", .{
            name,
            n,
            target_tokens.len,
            got_tokens.len,
        });
    } else {
        std.debug.print("  token_divergence {s}: token streams identical\n", .{name});
    }
}

fn reportSweepCandidate(
    allocator: std.mem.Allocator,
    max_chain: u32,
    nice_match: u16,
    max_insert: u16,
    got: []const u8,
    target: []const u8,
    target_first_main_end: usize,
    target_prefix_tokens: usize,
    target_prefix_end_bit: usize,
) !void {
    const blocks = try dfp.inspect.inspectBlocks(allocator, got);
    defer allocator.free(blocks);
    const first_main_end = if (blocks.len > 3) blocks[3].raw_end else 0;
    const prefix_tokens = if (blocks.len > 0) blocks[0].token_count else 0;
    const prefix_end_bit = if (blocks.len > 0) blocks[0].compressed_end_bit else 0;
    const size_delta: isize = @as(isize, @intCast(got.len)) - @as(isize, @intCast(target.len));
    const prefix_close = absDiff(prefix_tokens, target_prefix_tokens) <= 2 and absDiff(prefix_end_bit, target_prefix_end_bit) <= 32;
    if (absIsize(size_delta) > 150 and absDiff(first_main_end, target_first_main_end) > 200 and !prefix_close) return;
    std.debug.print(
        "sweep chain={d} nice={d} insert={d}: len={d} delta={d} prefix={d}/{d} first_main_end={d} first_main_delta={d} first_diff={d} exact={}\n",
        .{
            max_chain,
            nice_match,
            max_insert,
            got.len,
            size_delta,
            prefix_tokens,
            @as(isize, @intCast(prefix_end_bit)) - @as(isize, @intCast(target_prefix_end_bit)),
            first_main_end,
            @as(isize, @intCast(first_main_end)) - @as(isize, @intCast(target_first_main_end)),
            firstDiff(got, target),
            std.mem.eql(u8, got, target),
        },
    );
}

const CandidateArgs = struct {
    chain: u32,
    nice: u16,
    insert: u16,
    history: bool,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    _ = it.next();
    const raw_path = it.next() orelse {
        std.debug.print("usage: excel-candidate-probe RAW TARGET\n", .{});
        return error.BadArgs;
    };
    const target_path = it.next() orelse {
        std.debug.print("usage: excel-candidate-probe RAW TARGET\n", .{});
        return error.BadArgs;
    };
    var run_sweep = false;
    var candidate_args: ?CandidateArgs = null;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--sweep")) {
            run_sweep = true;
        } else if (std.mem.eql(u8, arg, "--candidate")) {
            const chain_arg = it.next() orelse {
                std.debug.print("usage: excel-candidate-probe RAW TARGET [--sweep] [--candidate CHAIN NICE INSERT [--history]]\n", .{});
                return error.BadArgs;
            };
            const nice_arg = it.next() orelse {
                std.debug.print("usage: excel-candidate-probe RAW TARGET [--sweep] [--candidate CHAIN NICE INSERT [--history]]\n", .{});
                return error.BadArgs;
            };
            const insert_arg = it.next() orelse {
                std.debug.print("usage: excel-candidate-probe RAW TARGET [--sweep] [--candidate CHAIN NICE INSERT [--history]]\n", .{});
                return error.BadArgs;
            };
            candidate_args = .{
                .chain = try std.fmt.parseInt(u32, chain_arg, 10),
                .nice = try std.fmt.parseInt(u16, nice_arg, 10),
                .insert = try std.fmt.parseInt(u16, insert_arg, 10),
                .history = false,
            };
        } else if (std.mem.eql(u8, arg, "--history")) {
            if (candidate_args) |candidate| {
                candidate_args = .{
                    .chain = candidate.chain,
                    .nice = candidate.nice,
                    .insert = candidate.insert,
                    .history = true,
                };
            } else {
                std.debug.print("usage: excel-candidate-probe RAW TARGET [--sweep] [--candidate CHAIN NICE INSERT [--history]]\n", .{});
                return error.BadArgs;
            }
        } else {
            std.debug.print("usage: excel-candidate-probe RAW TARGET [--sweep] [--candidate CHAIN NICE INSERT [--history]]\n", .{});
            return error.BadArgs;
        }
    }

    var raw_file = try std.Io.Dir.cwd().openFile(io, raw_path, .{});
    defer raw_file.close(io);
    const raw_size: usize = @intCast((try raw_file.stat(io)).size);
    if (raw_size > 64 * 1024 * 1024) return error.FileTooBig;
    const raw = try allocator.alloc(u8, raw_size);
    defer allocator.free(raw);
    var raw_buf: [4096]u8 = undefined;
    var raw_reader = raw_file.reader(io, &raw_buf);
    try raw_reader.interface.readSliceAll(raw);

    var target_file = try std.Io.Dir.cwd().openFile(io, target_path, .{});
    defer target_file.close(io);
    const target_size: usize = @intCast((try target_file.stat(io)).size);
    if (target_size > 64 * 1024 * 1024) return error.FileTooBig;
    const target = try allocator.alloc(u8, target_size);
    defer allocator.free(target);
    var target_buf: [4096]u8 = undefined;
    var target_reader = target_file.reader(io, &target_buf);
    try target_reader.interface.readSliceAll(target);

    const l2 = try dfp.encoder.encodeExcelWorksheetOPCMem7Level2(allocator, raw);
    defer allocator.free(l2);
    try reportCandidate(allocator, "excel-worksheet-opc-l2-mem7", l2, target);

    const l3 = try dfp.encoder.encodeExcelWorksheetOPCMem7Level3(allocator, raw);
    defer allocator.free(l3);
    try reportCandidate(allocator, "excel-worksheet-opc-l3-mem7", l3, target);

    const best_segmented = try dfp.encoder.encodeExcelWorksheetOPCMem7FastParams(allocator, raw, 16, 35, 4);
    defer allocator.free(best_segmented);
    try reportCandidate(allocator, "best-so-far segmented chain=16 nice=35 insert=4", best_segmented, target);
    try reportTokenDivergence(allocator, "segmented chain=16 nice=35 insert=4", best_segmented, target, raw);

    const best_history = try dfp.encoder.encodeExcelWorksheetOPCMem7FastParamsHistory(allocator, raw, 16, 35, 4);
    defer allocator.free(best_history);
    try reportCandidate(allocator, "best-so-far history chain=16 nice=35 insert=4", best_history, target);
    try reportTokenDivergence(allocator, "history chain=16 nice=35 insert=4", best_history, target, raw);

    if (candidate_args) |candidate| {
        const label = if (candidate.history) "custom history" else "custom segmented";
        const custom = if (candidate.history)
            try dfp.encoder.encodeExcelWorksheetOPCMem7FastParamsHistory(allocator, raw, candidate.chain, candidate.nice, candidate.insert)
        else
            try dfp.encoder.encodeExcelWorksheetOPCMem7FastParams(allocator, raw, candidate.chain, candidate.nice, candidate.insert);
        defer allocator.free(custom);
        std.debug.print("\n", .{});
        try reportCandidate(allocator, label, custom, target);
        try reportTokenDivergence(allocator, label, custom, target, raw);
    }

    const target_blocks = try dfp.inspect.inspectBlocks(allocator, target);
    defer allocator.free(target_blocks);
    const target_first_main_end = if (target_blocks.len > 3) target_blocks[3].raw_end else 0;
    const target_prefix_tokens = if (target_blocks.len > 0) target_blocks[0].token_count else 0;
    const target_prefix_end_bit = if (target_blocks.len > 0) target_blocks[0].compressed_end_bit else 0;
    std.debug.print("target prefix={d}@bit{d} first_main_end={d}\n", .{
        target_prefix_tokens,
        target_prefix_end_bit,
        target_first_main_end,
    });

    if (!run_sweep) return;

    std.debug.print("\nsegmented sweep candidates near target:\n", .{});
    var chain: u32 = 12;
    while (chain <= 22) : (chain += 1) {
        var nice: u16 = 14;
        while (nice <= 40) : (nice += 1) {
            var insert: u16 = 4;
            while (insert <= 8) : (insert += 1) {
                const got = try dfp.encoder.encodeExcelWorksheetOPCMem7FastParams(allocator, raw, chain, nice, insert);
                try reportSweepCandidate(allocator, chain, nice, insert, got, target, target_first_main_end, target_prefix_tokens, target_prefix_end_bit);
                allocator.free(got);
            }
        }
    }

    std.debug.print("\nprefix-history sweep candidates near target:\n", .{});
    chain = 12;
    while (chain <= 22) : (chain += 1) {
        var nice: u16 = 14;
        while (nice <= 40) : (nice += 1) {
            var insert: u16 = 4;
            while (insert <= 8) : (insert += 1) {
                const got = dfp.encoder.encodeExcelWorksheetOPCMem7FastParamsHistory(allocator, raw, chain, nice, insert) catch |err| {
                    std.debug.print("history chain={d} nice={d} insert={d}: {s}\n", .{ chain, nice, insert, @errorName(err) });
                    continue;
                };
                try reportSweepCandidate(allocator, chain, nice, insert, got, target, target_first_main_end, target_prefix_tokens, target_prefix_end_bit);
                allocator.free(got);
            }
        }
    }
}
