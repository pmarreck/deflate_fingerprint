//! PNG IDAT corpus probe.
//!
//! Walks a directory of PNG files, concatenates IDAT chunks, strips the RFC1950
//! zlib wrapper to expose the embedded RFC1951 stream, inflates the zlib stream
//! to PNG-filtered bytes, then runs the DEFLATE fingerprint registry.

const std = @import("std");

const dfp = @import("deflate_fingerprint");

const c = @cImport({
    @cInclude("zlib.h");
});

const Stats = struct {
    files_scanned: usize = 0,
    files_failed_parse: usize = 0,
    streams_png: usize = 0,
    streams_inflate_failed: usize = 0,
    streams_identified: usize = 0,
    streams_configured_identified: usize = 0,
    streams_missed: usize = 0,
    miss_inspect_failed: usize = 0,
    miss_with_dynamic: usize = 0,
    miss_with_dynamic_4096: usize = 0,
    miss_with_fixed: usize = 0,
    miss_with_empty_fixed_marker: usize = 0,
    miss_with_stored: usize = 0,
    miss_with_empty_stored_marker: usize = 0,
    hits_per_fp: [256]usize = [_]usize{0} ** 256,

    fn print(self: Stats, writer: anytype) !void {
        try writer.print("\n--- PNG IDAT probe results -------------------------------\n", .{});
        try writer.print("Files scanned:      {d}\n", .{self.files_scanned});
        try writer.print("Parse failed:       {d}\n", .{self.files_failed_parse});
        try writer.print("PNG streams:        {d}\n", .{self.streams_png});
        try writer.print("  inflate failed:   {d}\n", .{self.streams_inflate_failed});
        try writer.print("  identified:       {d}\n", .{self.streams_identified});
        try writer.print("  configured:       {d}\n", .{self.streams_configured_identified});
        try writer.print("  missed:           {d}\n", .{self.streams_missed});

        const attempted = self.streams_png - self.streams_inflate_failed;
        if (attempted != 0) {
            const total_exact = self.streams_identified + self.streams_configured_identified;
            const pct: f64 = @as(f64, @floatFromInt(total_exact)) /
                @as(f64, @floatFromInt(attempted)) * 100.0;
            try writer.print("\nHit rate (excluding inflate failures): {d:.1}%\n", .{pct});
        }

        try writer.print("\nHits per fingerprint:\n", .{});
        var any = false;
        for (self.hits_per_fp, 0..) |n, id| {
            if (n != 0) {
                try writer.print("  #{d}: {d}\n", .{ id, n });
                any = true;
            }
        }
        if (!any) try writer.print("  (none)\n", .{});

        if (self.streams_missed != 0) {
            try writer.print("\nMiss features:\n", .{});
            try writer.print("  inspect failed:       {d}\n", .{self.miss_inspect_failed});
            try writer.print("  dynamic blocks:       {d}\n", .{self.miss_with_dynamic});
            try writer.print("  dynamic 4096 tokens:  {d}\n", .{self.miss_with_dynamic_4096});
            try writer.print("  fixed blocks:         {d}\n", .{self.miss_with_fixed});
            try writer.print("  empty fixed markers:  {d}\n", .{self.miss_with_empty_fixed_marker});
            try writer.print("  stored blocks:        {d}\n", .{self.miss_with_stored});
            try writer.print("  empty stored markers: {d}\n", .{self.miss_with_empty_stored_marker});
        }
    }
};

const DiagnoseFlushMode = enum(c_int) {
    partial = 1, // Z_PARTIAL_FLUSH
    sync = 2,    // Z_SYNC_FLUSH
    block = 5,   // Z_BLOCK

    fn name(self: DiagnoseFlushMode) []const u8 {
        return switch (self) {
            .partial => "partial",
            .sync => "sync",
            .block => "block",
        };
    }
};

fn firstDiff(a: []const u8, b: []const u8) ?usize {
    const n = @min(a.len, b.len);
    for (0..n) |i| {
        if (a[i] != b[i]) return i;
    }
    if (a.len != b.len) return n;
    return null;
}

fn printByteWindow(label: []const u8, bytes: []const u8, center: usize) void {
    const start = center -| 8;
    const end = @min(bytes.len, center + 8);
    std.debug.print("      {s}[{d}..{d}):", .{ label, start, end });
    for (bytes[start..end]) |b| std.debug.print(" {x:0>2}", .{b});
    std.debug.print("\n", .{});
}

fn sameDecodedToken(a: dfp.inspect.DecodedToken, b: dfp.inspect.DecodedToken) bool {
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

fn printDecodedToken(token: dfp.inspect.DecodedToken) void {
    switch (token) {
        .literal => |byte| {
            if (byte >= 0x20 and byte <= 0x7e) {
                std.debug.print("lit('{c}'/{d})", .{ byte, byte });
            } else {
                std.debug.print("lit(0x{x:0>2})", .{byte});
            }
        },
        .match => |m| std.debug.print("match(len={d},dist={d})", .{ m.length, m.distance }),
    }
}

fn reportFirstTokenDivergence(
    allocator: std.mem.Allocator,
    candidate: []const u8,
    target: []const u8,
) void {
    const target_tokens = dfp.inspect.inspectTokens(allocator, target) catch |err| {
        std.debug.print("      token-divergence: target inspect failed({s})\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(target_tokens);
    const candidate_tokens = dfp.inspect.inspectTokens(allocator, candidate) catch |err| {
        std.debug.print("      token-divergence: candidate inspect failed({s})\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(candidate_tokens);

    const n = @min(target_tokens.len, candidate_tokens.len);
    for (0..n) |i| {
        const target_item = target_tokens[i];
        const candidate_item = candidate_tokens[i];
        if (target_item.block_index == candidate_item.block_index and
            target_item.block_type == candidate_item.block_type and
            target_item.raw_start == candidate_item.raw_start and
            target_item.raw_end == candidate_item.raw_end and
            sameDecodedToken(target_item.token, candidate_item.token))
        {
            continue;
        }

        std.debug.print("      token-divergence: index={d}\n", .{i});
        std.debug.print(
            "        target block={d}/{s} raw={d}-{d} ",
            .{ target_item.block_index, @tagName(target_item.block_type), target_item.raw_start, target_item.raw_end },
        );
        printDecodedToken(target_item.token);
        std.debug.print("\n", .{});
        std.debug.print(
            "        zlib   block={d}/{s} raw={d}-{d} ",
            .{ candidate_item.block_index, @tagName(candidate_item.block_type), candidate_item.raw_start, candidate_item.raw_end },
        );
        printDecodedToken(candidate_item.token);
        std.debug.print("\n", .{});
        return;
    }

    std.debug.print(
        "      token-divergence: common_prefix={d} target_tokens={d} zlib_tokens={d}\n",
        .{ n, target_tokens.len, candidate_tokens.len },
    );
}

/// Inflate one PNG IDAT zlib stream to PNG-filtered bytes. The probe only needs
/// the exact bytes that were fed into DEFLATE; PNG filter reversal is upstream.
fn inflateZlib(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    if (compressed.len > std.math.maxInt(c_uint)) return error.StreamTooLarge;
    var cap: usize = @max(@as(usize, 1024), compressed.len * 4);
    var out = try allocator.alloc(u8, cap);
    errdefer allocator.free(out);

    var s: c.z_stream = std.mem.zeroes(c.z_stream);
    const rc_init = c.inflateInit2_(&s, 15, c.zlibVersion(), @sizeOf(c.z_stream));
    if (rc_init != c.Z_OK) return error.InflateInitFailed;
    defer _ = c.inflateEnd(&s);

    s.next_in = @constCast(compressed.ptr);
    s.avail_in = @intCast(compressed.len);

    var used: usize = 0;
    while (true) {
        if (used == out.len) {
            cap *= 2;
            out = try allocator.realloc(out, cap);
        }

        s.next_out = out.ptr + used;
        s.avail_out = @intCast(out.len - used);

        const rc = c.inflate(&s, c.Z_NO_FLUSH);
        used = out.len - @as(usize, s.avail_out);

        if (rc == c.Z_STREAM_END) return allocator.realloc(out, used);
        if (rc == c.Z_OK) {
            if (s.avail_out == 0) continue;
            if (s.avail_in == 0) return error.InflateFailed;
            continue;
        }
        if (rc == c.Z_BUF_ERROR) continue;
        return error.InflateFailed;
    }
}

fn deflateRowsWithZlib(
    allocator: std.mem.Allocator,
    raw: []const u8,
    row_size: usize,
    level: c_int,
    strategy: c_int,
    mem_level: c_int,
    flush_mode: DiagnoseFlushMode,
) ![]u8 {
    if (row_size == 0) return error.InvalidRowSize;

    var cap: usize = raw.len + (raw.len >> 4) + ((raw.len / row_size) + 2) * 32 + 4096;
    var out = try allocator.alloc(u8, cap);
    errdefer allocator.free(out);

    var s: c.z_stream = std.mem.zeroes(c.z_stream);
    const rc_init = c.deflateInit2_(
        &s,
        level,
        c.Z_DEFLATED,
        -15,
        mem_level,
        strategy,
        c.zlibVersion(),
        @sizeOf(c.z_stream),
    );
    if (rc_init != c.Z_OK) return error.DeflateInitFailed;
    defer _ = c.deflateEnd(&s);

    var used: usize = 0;
    var off: usize = 0;
    while (off < raw.len) {
        const end = @min(raw.len, off + row_size);
        s.next_in = @constCast(raw.ptr + off);
        s.avail_in = @intCast(end - off);
        while (true) {
            if (used == out.len) {
                cap *= 2;
                out = try allocator.realloc(out, cap);
            }
            s.next_out = out.ptr + used;
            s.avail_out = @intCast(out.len - used);
            const rc = c.deflate(&s, @intFromEnum(flush_mode));
            used = out.len - @as(usize, s.avail_out);
            if (rc != c.Z_OK and rc != c.Z_BUF_ERROR) return error.DeflateFailed;
            if (s.avail_in == 0) break;
        }
        off = end;
    }

    s.next_in = @constCast(raw.ptr + raw.len);
    s.avail_in = 0;
    while (true) {
        if (used == out.len) {
            cap *= 2;
            out = try allocator.realloc(out, cap);
        }
        s.next_out = out.ptr + used;
        s.avail_out = @intCast(out.len - used);
        const rc = c.deflate(&s, c.Z_FINISH);
        used = out.len - @as(usize, s.avail_out);
        if (rc == c.Z_STREAM_END) return allocator.realloc(out, used);
        if (rc != c.Z_OK and rc != c.Z_BUF_ERROR) return error.DeflateFailed;
    }
}

fn deflateOnceWithZlib(
    allocator: std.mem.Allocator,
    raw: []const u8,
    level: c_int,
    strategy: c_int,
    mem_level: c_int,
    window_bits: c_int,
) ![]u8 {
    var cap: usize = raw.len + (raw.len >> 4) + 4096;
    var out = try allocator.alloc(u8, cap);
    errdefer allocator.free(out);

    var s: c.z_stream = std.mem.zeroes(c.z_stream);
    const rc_init = c.deflateInit2_(
        &s,
        level,
        c.Z_DEFLATED,
        -window_bits,
        mem_level,
        strategy,
        c.zlibVersion(),
        @sizeOf(c.z_stream),
    );
    if (rc_init != c.Z_OK) return error.DeflateInitFailed;
    defer _ = c.deflateEnd(&s);

    s.next_in = @constCast(raw.ptr);
    s.avail_in = @intCast(raw.len);
    var used: usize = 0;
    while (true) {
        if (used == out.len) {
            cap *= 2;
            out = try allocator.realloc(out, cap);
        }
        s.next_out = out.ptr + used;
        s.avail_out = @intCast(out.len - used);
        const rc = c.deflate(&s, c.Z_FINISH);
        used = out.len - @as(usize, s.avail_out);
        if (rc == c.Z_STREAM_END) return allocator.realloc(out, used);
        if (rc != c.Z_OK and rc != c.Z_BUF_ERROR) return error.DeflateFailed;
    }
}

fn printOneShotDiagnostics(
    allocator: std.mem.Allocator,
    raw: []const u8,
    target: []const u8,
    window_bits: c_int,
) void {
    const levels = [_]c_int{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const mem_levels = [_]c_int{ 5, 6, 7, 8, 9 };
    const strategies = [_]struct { name: []const u8, value: c_int }{
        .{ .name = "default", .value = c.Z_DEFAULT_STRATEGY },
        .{ .name = "filtered", .value = c.Z_FILTERED },
        .{ .name = "fixed", .value = c.Z_FIXED },
    };
    var best: ?struct {
        level: c_int,
        mem_level: c_int,
        strategy: []const u8,
        len: usize,
        diff: usize,
    } = null;
    for (levels) |level| {
        for (mem_levels) |mem_level| {
            for (strategies) |strategy| {
                const candidate = deflateOnceWithZlib(allocator, raw, level, strategy.value, mem_level, window_bits) catch continue;
                defer allocator.free(candidate);
                const diff = firstDiff(candidate, target);
                if (diff == null) {
                    std.debug.print(
                        "      oneshot-zlib EXACT window={d} L{d} mem{d} {s} len={d}\n",
                        .{ window_bits, level, mem_level, strategy.name, candidate.len },
                    );
                    return;
                }
                if (best == null or diff.? > best.?.diff) {
                    best = .{ .level = level, .mem_level = mem_level, .strategy = strategy.name, .len = candidate.len, .diff = diff.? };
                }
            }
        }
    }
    if (best) |b| {
        std.debug.print(
            "      oneshot-zlib best-prefix window={d} L{d} mem{d} {s}: len={d} first_diff={d} target_len={d}\n",
            .{ window_bits, b.level, b.mem_level, b.strategy, b.len, b.diff, target.len },
        );
    }
}

fn printRowFlushDiagnostics(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    raw: []const u8,
    target: []const u8,
    window_bits: c_int,
) void {
    printOneShotDiagnostics(allocator, raw, target, window_bits);

    const meta = dfp.png.parseIhdrMetadata(bytes) catch |err| {
        std.debug.print("      row-diagnose: ihdr-failed({s})\n", .{@errorName(err)});
        return;
    };
    const row_size = meta.filteredRowSize() catch |err| {
        std.debug.print("      row-diagnose: row-size-failed({s})\n", .{@errorName(err)});
        return;
    };
    const expected_raw_len = row_size * @as(usize, meta.height);
    std.debug.print(
        "      ihdr: {d}x{d} depth={d} color={d} interlace={d} row={d} rows-fit={any}\n",
        .{ meta.width, meta.height, meta.bit_depth, meta.color_type, meta.interlace_method, row_size, expected_raw_len == raw.len },
    );
    if (expected_raw_len != raw.len or meta.interlace_method != 0) return;

    const levels = [_]c_int{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const mem_levels = [_]c_int{ 5, 6, 7, 8, 9 };
    const strategies = [_]struct { name: []const u8, value: c_int }{
        .{ .name = "default", .value = c.Z_DEFAULT_STRATEGY },
        .{ .name = "filtered", .value = c.Z_FILTERED },
        .{ .name = "fixed", .value = c.Z_FIXED },
    };
    const flushes = [_]DiagnoseFlushMode{ .partial, .sync, .block };

    var best_desc: ?struct {
        level: c_int,
        mem_level: c_int,
        strategy: []const u8,
        strategy_value: c_int,
        flush: DiagnoseFlushMode,
        len: usize,
        diff: usize,
    } = null;

    for (levels) |level| {
        for (mem_levels) |mem_level| {
            for (strategies) |strategy| {
                for (flushes) |flush| {
                    const candidate = deflateRowsWithZlib(
                        allocator,
                        raw,
                        row_size,
                        level,
                        strategy.value,
                        mem_level,
                        flush,
                    ) catch |err| {
                        std.debug.print(
                            "      row-zlib L{d} mem{d} {s} {s}: failed({s})\n",
                            .{ level, mem_level, strategy.name, flush.name(), @errorName(err) },
                        );
                        continue;
                    };
                    defer allocator.free(candidate);

                    const diff = firstDiff(candidate, target);
                    if (diff == null) {
                        std.debug.print(
                            "      row-zlib EXACT L{d} mem{d} {s} {s} len={d}\n",
                            .{ level, mem_level, strategy.name, flush.name(), candidate.len },
                        );
                        printBlockSummary(allocator, candidate);
                        return;
                    }
                    const d = diff.?;
                    if (best_desc == null or d > best_desc.?.diff) {
                        best_desc = .{
                            .level = level,
                            .mem_level = mem_level,
                            .strategy = strategy.name,
                            .strategy_value = strategy.value,
                            .flush = flush,
                            .len = candidate.len,
                            .diff = d,
                        };
                    }
                }
            }
        }
    }

    if (best_desc) |best| {
        std.debug.print(
            "      row-zlib best-prefix L{d} mem{d} {s} {s}: len={d} first_diff={d} target_len={d}\n",
            .{ best.level, best.mem_level, best.strategy, best.flush.name(), best.len, best.diff, target.len },
        );
        if (best.diff < target.len) printByteWindow("target", target, best.diff);
        const candidate = deflateRowsWithZlib(
            allocator,
            raw,
            row_size,
            best.level,
            best.strategy_value,
            best.mem_level,
            best.flush,
        ) catch return;
        defer allocator.free(candidate);
        if (best.diff < candidate.len) printByteWindow("zlib  ", candidate, best.diff);
        printBlockSummary(allocator, candidate);
        reportFirstTokenDivergence(allocator, candidate, target);
    }
}

fn printBlockSummary(allocator: std.mem.Allocator, compressed: []const u8) void {
    const blocks = dfp.inspect.inspectBlocks(allocator, compressed) catch |err| {
        std.debug.print("      blocks: inspect-failed({s})\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(blocks);

	std.debug.print("      blocks:", .{});
	const limit = @min(blocks.len, 64);
	for (blocks[0..limit]) |block| {
		std.debug.print(
			" {s}:{d}[{d}..{d}]",
			.{ @tagName(block.block_type), block.token_count, block.raw_start, block.raw_end },
		);
	}
    if (blocks.len > limit) std.debug.print(" ...", .{});
    std.debug.print("\n", .{});
}

fn recordMissFeatures(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    stats: *Stats,
) void {
    const blocks = dfp.inspect.inspectBlocks(allocator, compressed) catch {
        stats.miss_inspect_failed += 1;
        return;
    };
    defer allocator.free(blocks);

    const summary = dfp.inspect.summarizeBlockFeatures(blocks);
    if (summary.has_dynamic) stats.miss_with_dynamic += 1;
    if (summary.has_dynamic_4096) stats.miss_with_dynamic_4096 += 1;
    if (summary.has_fixed) stats.miss_with_fixed += 1;
    if (summary.has_empty_fixed_marker) stats.miss_with_empty_fixed_marker += 1;
    if (summary.has_stored) stats.miss_with_stored += 1;
    if (summary.has_empty_stored_marker) stats.miss_with_empty_stored_marker += 1;
}

fn processPng(
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
    stats: *Stats,
    verbose: bool,
    diagnose_row_flush: bool,
) !void {
    var idat = try dfp.png.parseIdatStream(allocator, bytes);
    defer idat.deinit(allocator);

    stats.streams_png += 1;

    const raw = inflateZlib(allocator, idat.zlib_bytes) catch |err| {
        stats.streams_inflate_failed += 1;
        if (verbose) std.debug.print("  inflate failed in {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };
    defer allocator.free(raw);

    const target = idat.rawDeflate();
    const result = try dfp.identify(allocator, raw, target);
    if (result.fingerprint_id != 0) {
        stats.streams_identified += 1;
        if (result.fingerprint_id < stats.hits_per_fp.len) stats.hits_per_fp[result.fingerprint_id] += 1;
        if (verbose) {
            std.debug.print(
                "  IDAT raw={d} deflate={d} zlib={x:0>2}{x:0>2} fp=#{d}\n",
                .{ raw.len, target.len, idat.cmf, idat.flg, result.fingerprint_id },
            );
        }
        return;
    }

    if (try dfp.fingerprintConfigured(allocator, raw, target)) |configured| {
        var owned = configured;
        defer owned.deinit(allocator);
        stats.streams_configured_identified += 1;
        if (verbose) std.debug.print("  IDAT configured exact raw={d} deflate={d}\n", .{ raw.len, target.len });
        return;
    }

    stats.streams_missed += 1;
    recordMissFeatures(allocator, target, stats);
    if (verbose) {
        std.debug.print("  MISS {s}: raw={d} deflate={d} zlib={x:0>2}{x:0>2}\n", .{ path, raw.len, target.len, idat.cmf, idat.flg });
        printBlockSummary(allocator, target);
        if (diagnose_row_flush) {
            const window_bits: c_int = @intCast((idat.cmf >> 4) + 8);
            printRowFlushDiagnostics(allocator, bytes, raw, target, window_bits);
        }
    }
}

const Args = struct {
    dir: []u8,
    verbose: bool,
    diagnose_row_flush: bool,
    limit: ?usize,
};

fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args) !Args {
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    _ = it.next();

    var dir: ?[]u8 = null;
    var verbose = false;
    var diagnose_row_flush = false;
    var limit: ?usize = null;

    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "--diagnose-row-flush")) {
            diagnose_row_flush = true;
            verbose = true;
        } else if (std.mem.startsWith(u8, a, "--limit=")) {
            limit = try std.fmt.parseInt(usize, a["--limit=".len..], 10);
        } else if (std.mem.eql(u8, a, "--limit")) {
            const v = it.next() orelse return error.MissingLimitValue;
            limit = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                \\png-corpus-probe: identify raw-DEFLATE streams inside PNG IDAT data.
                \\
                \\Usage: png-corpus-probe <dir> [--verbose] [--diagnose-row-flush] [--limit N]
                \\
            , .{});
            std.process.exit(0);
        } else if (dir == null) {
            dir = try allocator.dupe(u8, a);
        } else {
            std.debug.print("unexpected argument: {s}\n", .{a});
            std.process.exit(2);
        }
    }

    if (dir == null) {
        std.debug.print("usage: png-corpus-probe <dir> [--verbose] [--diagnose-row-flush] [--limit N]\n", .{});
        std.process.exit(2);
    }

    return .{ .dir = dir.?, .verbose = verbose, .diagnose_row_flush = diagnose_row_flush, .limit = limit };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try parseArgs(allocator, init.minimal.args);
    defer allocator.free(args.dir);

    var stats: Stats = .{};

    var dir = std.Io.Dir.cwd().openDir(io, args.dir, .{ .iterate = true }) catch |err| {
        std.debug.print("could not open dir '{s}': {s}\n", .{ args.dir, @errorName(err) });
        std.process.exit(1);
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!dfp.png.isPngFilename(entry.basename)) continue;
        if (args.limit) |lim| {
            if (stats.files_scanned >= lim) break;
        }

        const path_dup = try allocator.dupe(u8, entry.path);
        defer allocator.free(path_dup);

        var file = entry.dir.openFile(io, entry.basename, .{}) catch |err| {
            std.debug.print("could not open {s}: {s}\n", .{ path_dup, @errorName(err) });
            stats.files_failed_parse += 1;
            continue;
        };
        defer file.close(io);

        const st = try file.stat(io);
        const size: usize = @intCast(st.size);
        if (size == 0) continue;
        const bytes = try allocator.alloc(u8, size);
        defer allocator.free(bytes);

        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        try reader.interface.readSliceAll(bytes);

        stats.files_scanned += 1;
        if (args.verbose) std.debug.print("[{d}] {s} ({d}B)\n", .{ stats.files_scanned, path_dup, size });

        processPng(allocator, path_dup, bytes, &stats, args.verbose, args.diagnose_row_flush) catch |err| {
            stats.files_failed_parse += 1;
            if (args.verbose) std.debug.print("  parse error in {s}: {s}\n", .{ path_dup, @errorName(err) });
        };
    }

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(io, &out_buf);
    const stdout = &out_writer.interface;
    try stats.print(stdout);
    try stdout.flush();
}
