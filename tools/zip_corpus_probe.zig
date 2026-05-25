//! Real-world raw-DEFLATE corpus probe.
//!
//! Walks a directory of ZIP-format archives (.zip, .docx, .jar, .epub, .odt,
//! .xlsx, .pptx, …), parses each archive's central directory, extracts every
//! entry whose compression_method is DEFLATE (8), reinflates via libz to get
//! the original bytes, then runs our identifier on the (original, compressed)
//! pair and tallies which fingerprint reproduced it (if any).
//!
//! The point isn't byte-counting accuracy — it's surfacing which encoder
//! families show up in the wild and what fraction of their streams our zlib
//! catalogue already covers. Drives v0.2 priority for the next encoder
//! family (libdeflate / 7-Zip / java.util.zip / etc.) to implement.

const std = @import("std");

const dfp = @import("deflate_fingerprint");

const c = @cImport({
    @cInclude("zlib.h");
});

// ─── ZIP format constants ────────────────────────────────────────────────

const LFH_SIG: u32 = 0x04034b50;   // local file header
const CDE_SIG: u32 = 0x02014b50;   // central directory entry
const EOCD_SIG: u32 = 0x06054b50;  // end of central directory record
const METHOD_DEFLATE: u16 = 8;

// ─── Stats ───────────────────────────────────────────────────────────────

const Stats = struct {
    files_scanned: usize = 0,
    files_failed_parse: usize = 0,
    entries_total: usize = 0,
    entries_stored: usize = 0,          // method=0, not DEFLATE
    entries_other_method: usize = 0,    // method != 0 && != 8
    entries_deflate: usize = 0,
    entries_inflate_failed: usize = 0,
    entries_identified: usize = 0,
    entries_missed: usize = 0,
    hits_per_fp: [256]usize = [_]usize{0} ** 256,

    fn print(self: Stats, writer: anytype) !void {
        try writer.print("\n─── Corpus probe results ───────────────────────────────\n", .{});
        try writer.print("Archives scanned:   {d}\n", .{self.files_scanned});
        try writer.print("Archive parse fail: {d}\n", .{self.files_failed_parse});
        try writer.print("Entries total:      {d}\n", .{self.entries_total});
        try writer.print("  STORED (skip):    {d}\n", .{self.entries_stored});
        try writer.print("  other method:     {d}\n", .{self.entries_other_method});
        try writer.print("  DEFLATE:          {d}\n", .{self.entries_deflate});
        try writer.print("    inflate failed: {d}\n", .{self.entries_inflate_failed});
        try writer.print("    identified:     {d}\n", .{self.entries_identified});
        try writer.print("    missed:         {d}\n", .{self.entries_missed});
        if (self.entries_deflate > 0) {
            const attempted = self.entries_deflate - self.entries_inflate_failed;
            if (attempted > 0) {
                const pct: f64 = @as(f64, @floatFromInt(self.entries_identified)) /
                    @as(f64, @floatFromInt(attempted)) * 100.0;
                try writer.print("\nHit rate (excluding inflate failures): {d:.1}%\n", .{pct});
            }
        }
        try writer.print("\nHits per fingerprint:\n", .{});
        var any: bool = false;
        for (self.hits_per_fp, 0..) |n, id| {
            if (n != 0) {
                try writer.print("  #{d}: {d}\n", .{ id, n });
                any = true;
            }
        }
        if (!any) try writer.print("  (none)\n", .{});
    }
};

// ─── Helpers ─────────────────────────────────────────────────────────────

fn readU16LE(buf: []const u8, off: usize) u16 {
    return @as(u16, buf[off]) | (@as(u16, buf[off + 1]) << 8);
}

fn readU32LE(buf: []const u8, off: usize) u32 {
    return @as(u32, buf[off]) |
        (@as(u32, buf[off + 1]) << 8) |
        (@as(u32, buf[off + 2]) << 16) |
        (@as(u32, buf[off + 3]) << 24);
}

/// Scan backwards from the end of `buf` to find the EOCD signature.
/// EOCD comment can be up to 65535 bytes, so we search the last 65557 bytes.
fn findEOCD(buf: []const u8) ?usize {
    const max_scan: usize = @min(buf.len, 65557);
    if (max_scan < 22) return null;
    var i: usize = buf.len - 22;
    const stop: usize = buf.len - max_scan;
    while (true) {
        if (readU32LE(buf, i) == EOCD_SIG) return i;
        if (i == stop) return null;
        i -= 1;
    }
}

/// Inflate raw-DEFLATE bytes via libz. Caller owns the returned slice.
fn inflateRaw(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    expected_size: usize,
) ![]u8 {
    // For zero-byte uncompressed entries libz still wants at least a 1-byte buffer.
    const cap: usize = if (expected_size == 0) 16 else expected_size;
    const out = try allocator.alloc(u8, cap);
    errdefer allocator.free(out);

    var s: c.z_stream = std.mem.zeroes(c.z_stream);
    const rc_init = c.inflateInit2_(&s, -15, c.zlibVersion(), @sizeOf(c.z_stream));
    if (rc_init != c.Z_OK) return error.InflateInitFailed;
    defer _ = c.inflateEnd(&s);

    s.next_in = @constCast(compressed.ptr);
    s.avail_in = @intCast(compressed.len);
    s.next_out = out.ptr;
    s.avail_out = @intCast(cap);

    const rc = c.inflate(&s, c.Z_FINISH);
    if (rc != c.Z_STREAM_END) return error.InflateFailed;

    const out_len = cap - @as(usize, s.avail_out);
    return allocator.realloc(out, out_len);
}

fn extractEntryOriginal(
    allocator: std.mem.Allocator,
    buf: []const u8,
    method: u16,
    lfh_off: u32,
    compressed_size: u32,
    uncompressed_size: u32,
) ![]u8 {
    if (compressed_size == 0xFFFFFFFF or uncompressed_size == 0xFFFFFFFF) return error.Zip64Entry;
    if (@as(usize, lfh_off) + 30 > buf.len) return error.TruncatedLFH;
    if (readU32LE(buf, lfh_off) != LFH_SIG) return error.BadLFH;

    const name_len = readU16LE(buf, @as(usize, lfh_off) + 26);
    const extra_len = readU16LE(buf, @as(usize, lfh_off) + 28);
    const data_off: usize = @as(usize, lfh_off) + 30 + @as(usize, name_len) + @as(usize, extra_len);
    if (data_off + @as(usize, compressed_size) > buf.len) return error.EntryDataOutOfRange;
    const compressed = buf[data_off .. data_off + @as(usize, compressed_size)];

    if (method == 0) return allocator.dupe(u8, compressed);
    if (method == METHOD_DEFLATE) return inflateRaw(allocator, compressed, uncompressed_size);
    return error.UnsupportedMethod;
}

/// Print a compact DEFLATE block-shape sketch for missed streams so OOXML and
/// ZIP-family producer clusters can be compared by flush cadence and block type.
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
    if (blocks.len > limit) std.debug.print(" ...+{d}", .{blocks.len - limit});
    std.debug.print("\n", .{});
}

/// Process one ZIP-format archive in memory.
fn processArchive(
    allocator: std.mem.Allocator,
    archive_path: []const u8,
    buf: []const u8,
    stats: *Stats,
    verbose: bool,
) !void {
    const eocd_off = findEOCD(buf) orelse return error.NoEOCD;
    if (eocd_off + 22 > buf.len) return error.TruncatedEOCD;

    // const total_entries = readU16LE(buf, eocd_off + 10);
    const cd_size = readU32LE(buf, eocd_off + 12);
    const cd_off = readU32LE(buf, eocd_off + 16);

    if (cd_off == 0xFFFFFFFF or cd_size == 0xFFFFFFFF) {
        // ZIP64 — skip for now.
        if (verbose) std.debug.print("  [zip64, skip] {s}\n", .{archive_path});
        return;
    }
    if (@as(usize, cd_off) + @as(usize, cd_size) > buf.len) return error.CDOutOfRange;

    var p: usize = @intCast(cd_off);
    const cd_end: usize = @intCast(@as(usize, cd_off) + @as(usize, cd_size));

    while (p < cd_end) {
        if (p + 46 > buf.len) break;
        if (readU32LE(buf, p) != CDE_SIG) break;
        const method = readU16LE(buf, p + 10);
        const compressed_size = readU32LE(buf, p + 20);
        const uncompressed_size = readU32LE(buf, p + 24);
        const name_len = readU16LE(buf, p + 28);
        const extra_len = readU16LE(buf, p + 30);
        const comment_len = readU16LE(buf, p + 32);
        const lfh_off = readU32LE(buf, p + 42);
        const cde_total: usize = 46 + @as(usize, name_len) + @as(usize, extra_len) + @as(usize, comment_len);
        const name = buf[p + 46 .. p + 46 + @as(usize, name_len)];

        if (verbose and std.mem.eql(u8, name, "docProps/app.xml")) {
            if (extractEntryOriginal(allocator, buf, method, lfh_off, compressed_size, uncompressed_size)) |xml| {
                defer allocator.free(xml);
                const meta = dfp.ooxml.parseAppMetadata(xml);
                std.debug.print("    ooxml app: application=\"{s}\" appVersion=\"{s}\"\n", .{
                    meta.application orelse "",
                    meta.app_version orelse "",
                });
            } else |_| {}
        }

        stats.entries_total += 1;
        if (method == 0) {
            stats.entries_stored += 1;
        } else if (method == METHOD_DEFLATE) {
            stats.entries_deflate += 1;
            try processDeflateEntry(
                allocator,
                buf,
                lfh_off,
                compressed_size,
                uncompressed_size,
                stats,
                verbose,
            );
        } else {
            stats.entries_other_method += 1;
        }

        p += cde_total;
    }
}

fn processDeflateEntry(
    allocator: std.mem.Allocator,
    buf: []const u8,
    lfh_off: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    stats: *Stats,
    verbose: bool,
) !void {
    // Skip ZIP64 / streaming-descriptor sentinels.
    if (compressed_size == 0xFFFFFFFF or uncompressed_size == 0xFFFFFFFF) return;
    if (@as(usize, lfh_off) + 30 > buf.len) return;
    if (readU32LE(buf, lfh_off) != LFH_SIG) return;

    const name_len = readU16LE(buf, @as(usize, lfh_off) + 26);
    const extra_len = readU16LE(buf, @as(usize, lfh_off) + 28);
    const data_off: usize = @as(usize, lfh_off) + 30 + @as(usize, name_len) + @as(usize, extra_len);

    if (data_off + @as(usize, compressed_size) > buf.len) return;
    const compressed = buf[data_off .. data_off + @as(usize, compressed_size)];

    // Inflate to ground truth.
    const original = inflateRaw(allocator, compressed, uncompressed_size) catch {
        stats.entries_inflate_failed += 1;
        return;
    };
    defer allocator.free(original);

    // Identify.
    const result = dfp.identify(allocator, original, compressed) catch {
        stats.entries_missed += 1;
        return;
    };
    if (result.fingerprint_id != 0) {
        stats.entries_identified += 1;
        if (result.fingerprint_id < stats.hits_per_fp.len) {
            stats.hits_per_fp[result.fingerprint_id] += 1;
        }
        if (verbose) {
            std.debug.print("    hit  #{d} ({d}B in, {d}B compressed)\n", .{
                result.fingerprint_id, original.len, compressed.len,
            });
        }
    } else {
        stats.entries_missed += 1;
        if (verbose) {
            std.debug.print("    miss ({d}B in, {d}B compressed)\n", .{
                original.len, compressed.len,
            });
            printBlockSummary(allocator, compressed);
        }
    }
}

const Args = struct {
    dir: []const u8,
    verbose: bool = false,
    limit: ?usize = null,
};

fn parseArgs(allocator: std.mem.Allocator, args_in: std.process.Args) !Args {
    var it = try std.process.Args.Iterator.initAllocator(args_in, allocator);
    defer it.deinit();
    _ = it.next(); // skip program name

    var dir: ?[]const u8 = null;
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
                \\zip-corpus-probe: identify raw-DEFLATE streams in real ZIP archives.
                \\
                \\Usage: zip-corpus-probe <dir> [--verbose] [--limit N]
                \\
                \\Walks <dir> recursively, processes every .zip/.docx/.jar/.epub/.odt/
                \\.xlsx/.pptx file found, parses each archive's central directory,
                \\and runs the deflate_fingerprint identifier on every DEFLATE entry.
                \\
                \\Reports aggregate stats: how many streams were identified by which
                \\fingerprint, how many were missed, etc.
                \\
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
        std.debug.print("usage: zip-corpus-probe <dir> [--verbose] [--limit N]\n", .{});
        std.process.exit(2);
    }
    return .{ .dir = dir.?, .verbose = verbose, .limit = limit };
}

fn isZipExtension(name: []const u8) bool {
    // Skip macOS AppleDouble resource-fork sidecars (._foo.zip etc.) — they
    // are NOT real archives, just metadata blobs that happen to share a name.
    if (std.mem.startsWith(u8, name, "._")) return false;
    const exts = [_][]const u8{ ".zip", ".docx", ".jar", ".epub", ".odt", ".xlsx", ".pptx", ".apk", ".war", ".ipa" };
    for (exts) |ext| {
        if (name.len >= ext.len) {
            const tail = name[name.len - ext.len ..];
            // Case-insensitive ASCII compare.
            var eq = true;
            for (tail, ext) |a, b| {
                const al = if (a >= 'A' and a <= 'Z') a + 32 else a;
                const bl = if (b >= 'A' and b <= 'Z') b + 32 else b;
                if (al != bl) { eq = false; break; }
            }
            if (eq) return true;
        }
    }
    return false;
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
        if (!isZipExtension(entry.basename)) continue;
        if (args.limit) |lim| {
            if (stats.files_scanned >= lim) break;
        }

        const path_dup = try allocator.dupe(u8, entry.path);
        defer allocator.free(path_dup);

        var f = entry.dir.openFile(io, entry.basename, .{}) catch |err| {
            std.debug.print("could not open {s}: {s}\n", .{ path_dup, @errorName(err) });
            stats.files_failed_parse += 1;
            continue;
        };
        defer f.close(io);

        const st = try f.stat(io);
        const sz: usize = @intCast(st.size);
        if (sz == 0) continue;
        const buf = try allocator.alloc(u8, sz);
        defer allocator.free(buf);

        var rbuf: [4096]u8 = undefined;
        var reader = f.reader(io, &rbuf);
        try reader.interface.readSliceAll(buf);

        stats.files_scanned += 1;
        if (args.verbose) std.debug.print("[{d}] {s} ({d}B)\n", .{ stats.files_scanned, path_dup, sz });

        processArchive(allocator, path_dup, buf, &stats, args.verbose) catch |err| {
            std.debug.print("  parse error in {s}: {s}\n", .{ path_dup, @errorName(err) });
            stats.files_failed_parse += 1;
        };
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    try stats.print(&stdout_writer.interface);
    try stdout_writer.interface.flush();
}
