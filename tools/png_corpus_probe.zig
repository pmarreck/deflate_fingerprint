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
    }
};

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

fn printBlockSummary(allocator: std.mem.Allocator, compressed: []const u8) void {
    const blocks = dfp.inspect.inspectBlocks(allocator, compressed) catch |err| {
        std.debug.print("      blocks: inspect-failed({s})\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(blocks);

    std.debug.print("      blocks:", .{});
    const limit = @min(blocks.len, 8);
    for (blocks[0..limit]) |block| {
        std.debug.print(" {s}:{d}", .{ @tagName(block.block_type), block.token_count });
    }
    if (blocks.len > limit) std.debug.print(" ...", .{});
    std.debug.print("\n", .{});
}

fn processPng(
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
    stats: *Stats,
    verbose: bool,
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
    if (verbose) {
        std.debug.print("  MISS {s}: raw={d} deflate={d} zlib={x:0>2}{x:0>2}\n", .{ path, raw.len, target.len, idat.cmf, idat.flg });
        printBlockSummary(allocator, target);
    }
}

const Args = struct {
    dir: []u8,
    verbose: bool,
    limit: ?usize,
};

fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args) !Args {
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    _ = it.next();

    var dir: ?[]u8 = null;
    var verbose = false;
    var limit: ?usize = null;

    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
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
                \\Usage: png-corpus-probe <dir> [--verbose] [--limit N]
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
        std.debug.print("usage: png-corpus-probe <dir> [--verbose] [--limit N]\n", .{});
        std.process.exit(2);
    }

    return .{ .dir = dir.?, .verbose = verbose, .limit = limit };
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

        processPng(allocator, path_dup, bytes, &stats, args.verbose) catch |err| {
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
