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

const LFH_SIG: u32 = 0x04034b50; // local file header
const CDE_SIG: u32 = 0x02014b50; // central directory entry
const EOCD_SIG: u32 = 0x06054b50; // end of central directory record
const METHOD_DEFLATE: u16 = 8;

// ─── Stats ───────────────────────────────────────────────────────────────

const Stats = struct {
    files_scanned: usize = 0,
    files_failed_parse: usize = 0,
    entries_total: usize = 0,
    entries_stored: usize = 0, // method=0, not DEFLATE
    entries_other_method: usize = 0, // method != 0 && != 8
    entries_deflate: usize = 0,
    entries_inflate_failed: usize = 0,
    entries_identified: usize = 0,
    entries_configured_identified: usize = 0,
    entries_missed: usize = 0,
    excel_experimental_attempted: usize = 0,
    excel_experimental_exact_any: usize = 0,
    excel_experimental_exact_nice35: usize = 0,
    excel_experimental_exact_nice60: usize = 0,
    excel_experimental_exact_row1024: usize = 0,
    excel_experimental_exact_observed: usize = 0,
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
        try writer.print("    configured:     {d}\n", .{self.entries_configured_identified});
        try writer.print("    missed:         {d}\n", .{self.entries_missed});
        if (self.excel_experimental_attempted != 0) {
            try writer.print("\nExperimental Excel worksheet candidates:\n", .{});
            try writer.print("  attempted:        {d}\n", .{self.excel_experimental_attempted});
            try writer.print("  byte-exact any:   {d}\n", .{self.excel_experimental_exact_any});
            try writer.print("  nice=35 exact:    {d}\n", .{self.excel_experimental_exact_nice35});
            try writer.print("  nice=60 exact:    {d}\n", .{self.excel_experimental_exact_nice60});
            try writer.print("  row1024 exact:    {d}\n", .{self.excel_experimental_exact_row1024});
            try writer.print("  observed exact:   {d}\n", .{self.excel_experimental_exact_observed});
        }
        if (self.entries_deflate > 0) {
            const attempted = self.entries_deflate - self.entries_inflate_failed;
            if (attempted > 0) {
                const total_exact = self.entries_identified + self.entries_configured_identified;
                const pct: f64 = @as(f64, @floatFromInt(total_exact)) /
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

fn firstDiff(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return i;
    }
    return n;
}

fn fastParams(nice_match: u16) dfp.encoder.LZ77Params {
    return .{
        .max_chain_length = 16,
        .good_match = 4,
        .nice_match = nice_match,
        .max_lazy_match = 4,
    };
}

fn observedFlushEvents(
    allocator: std.mem.Allocator,
    observed: dfp.inspect.ObservedFlushSchedule,
) ![]dfp.encoder.FlushEvent {
    const flushes = try allocator.alloc(dfp.encoder.FlushEvent, observed.sync_flushes.len);
    errdefer allocator.free(flushes);
    for (observed.sync_flushes, 0..) |flush, i| {
        flushes[i] = .{
            .raw_offset = flush.raw_offset,
            .empty_fixed_blocks_before = flush.empty_fixed_blocks_before,
            .empty_stored_blocks = flush.empty_stored_blocks,
        };
    }
    return flushes;
}

fn worksheetFlushOffsets(raw: []const u8) struct { offsets: [2]usize, len: usize } {
    const sheet_start = std.mem.indexOf(u8, raw, "<sheetData") orelse return .{ .offsets = undefined, .len = 0 };
    const sheet_end_start = std.mem.indexOf(u8, raw, "</sheetData>") orelse return .{ .offsets = undefined, .len = 0 };
    const sheet_end = sheet_end_start + "</sheetData>".len;
    if (sheet_start >= sheet_end or sheet_end > raw.len) return .{ .offsets = undefined, .len = 0 };
    return .{ .offsets = .{ sheet_start, sheet_end }, .len = 2 };
}

fn worksheetRowChunkFlushOffsets(allocator: std.mem.Allocator, raw: []const u8, row_chunk: u32) ![]usize {
    var offsets: std.ArrayList(usize) = .empty;
    errdefer offsets.deinit(allocator);

    const base = worksheetFlushOffsets(raw);
    if (base.len == 0) return offsets.toOwnedSlice(allocator);
    const sheet_start = base.offsets[0];
    const sheet_end = base.offsets[1];
    try offsets.append(allocator, sheet_start);

    const prefix = "<row r=\"";
    var scan = sheet_start;
    while (scan < sheet_end) {
        const rel = std.mem.indexOf(u8, raw[scan..sheet_end], prefix) orelse break;
        const row_start = scan + rel;
        const number_start = row_start + prefix.len;
        const number_end_rel = std.mem.indexOfScalar(u8, raw[number_start..sheet_end], '"') orelse break;
        const number_end = number_start + number_end_rel;
        const row_number = std.fmt.parseInt(u32, raw[number_start..number_end], 10) catch {
            scan = number_end + 1;
            continue;
        };
        if (row_number > 1 and (row_number - 1) % row_chunk == 0) {
            try offsets.append(allocator, row_start);
        }
        scan = number_end + 1;
    }

    try offsets.append(allocator, sheet_end);
    return offsets.toOwnedSlice(allocator);
}

fn encodeConfiguredCandidate(
    allocator: std.mem.Allocator,
    raw: []const u8,
    params: dfp.encoder.LZ77Params,
    mem_level: u4,
    flushes: []const dfp.encoder.FlushEvent,
    final_flush_empty_fixed_blocks_before: usize,
    final_flush_empty_stored_blocks: usize,
) ![]u8 {
    return dfp.encoder.encodeConfiguredDeflate(allocator, raw, .{
        .params = params,
        .mem_level = mem_level,
        .sync_flushes = flushes,
        .final_flush_empty_fixed_blocks_before = final_flush_empty_fixed_blocks_before,
        .final_flush_empty_stored_blocks = final_flush_empty_stored_blocks,
        .tokenization_mode = .segmented,
    });
}

fn encodeWorksheetCandidate(allocator: std.mem.Allocator, raw: []const u8, nice_match: u16) ![]u8 {
    const flushes = worksheetFlushOffsets(raw);
    var events_buf: [2]dfp.encoder.FlushEvent = undefined;
    for (flushes.offsets[0..flushes.len], 0..) |offset, i| {
        events_buf[i] = .{ .raw_offset = offset, .empty_stored_blocks = 2 };
    }
    return encodeConfiguredCandidate(allocator, raw, fastParams(nice_match), 7, events_buf[0..flushes.len], 0, 1);
}

fn encodeWorksheetRowChunkCandidate(
    allocator: std.mem.Allocator,
    raw: []const u8,
    nice_match: u16,
    row_chunk: u32,
) ![]u8 {
    const offsets = try worksheetRowChunkFlushOffsets(allocator, raw, row_chunk);
    defer allocator.free(offsets);
    const flushes = try allocator.alloc(dfp.encoder.FlushEvent, offsets.len);
    defer allocator.free(flushes);
    for (offsets, 0..) |offset, i| {
        flushes[i] = .{ .raw_offset = offset, .empty_stored_blocks = 2 };
    }
    return encodeConfiguredCandidate(allocator, raw, fastParams(nice_match), 7, flushes, 0, 1);
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
    excel_experimental: bool,
    max_streams: ?usize,
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
        if (max_streams) |lim| {
            if (stats.entries_deflate >= lim) return;
        }
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
                name,
                lfh_off,
                compressed_size,
                uncompressed_size,
                stats,
                verbose,
                excel_experimental,
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
    entry_name: []const u8,
    lfh_off: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    stats: *Stats,
    verbose: bool,
    excel_experimental: bool,
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

    var excel_experimental_label: []const u8 = "none";
    var excel_experimental_len: usize = 0;
    var excel_experimental_first_diff: usize = 0;
    if (excel_experimental and dfp.ooxml.isWorksheetPath(entry_name)) {
        stats.excel_experimental_attempted += 1;

        const observed = dfp.inspect.observeFlushSchedule(allocator, compressed) catch null;
        if (observed) |schedule| {
            defer schedule.deinit(allocator);
            if (schedule.has_empty_fixed_finish) {
                const observed_flushes = observedFlushEvents(allocator, schedule) catch null;
                if (observed_flushes) |flushes| {
                    defer allocator.free(flushes);

                    const observed_l1_candidates = [_]struct {
                        label: []const u8,
                        mem_level: u4,
                    }{
                        .{ .label = "observed-l1-mem8", .mem_level = 8 },
                        .{ .label = "observed-l1-mem7", .mem_level = 7 },
                    };
                    for (observed_l1_candidates) |candidate_spec| {
                        if (!std.mem.eql(u8, excel_experimental_label, "none")) break;
                        const got = encodeConfiguredCandidate(
                            allocator,
                            original,
                            dfp.encoder.LZ77_LEVEL_1,
                            candidate_spec.mem_level,
                            flushes,
                            schedule.final_flush_empty_fixed_blocks_before,
                            schedule.final_flush_empty_stored_blocks,
                        ) catch null;
                        if (got) |candidate| {
                            defer allocator.free(candidate);
                            excel_experimental_len = candidate.len;
                            excel_experimental_first_diff = firstDiff(candidate, compressed);
                            if (std.mem.eql(u8, candidate, compressed)) {
                                excel_experimental_label = candidate_spec.label;
                                stats.excel_experimental_exact_any += 1;
                                stats.excel_experimental_exact_observed += 1;
                            }
                        }
                    }

                    const observed_candidates = [_]struct {
                        label: []const u8,
                        nice: u16,
                    }{
                        .{ .label = "observed-nice35", .nice = 35 },
                        .{ .label = "observed-nice48", .nice = 48 },
                        .{ .label = "observed-nice60", .nice = 60 },
                    };
                    for (observed_candidates) |candidate_spec| {
                        if (!std.mem.eql(u8, excel_experimental_label, "none")) break;
                        const got = encodeConfiguredCandidate(
                            allocator,
                            original,
                            fastParams(candidate_spec.nice),
                            7,
                            flushes,
                            schedule.final_flush_empty_fixed_blocks_before,
                            schedule.final_flush_empty_stored_blocks,
                        ) catch null;
                        if (got) |candidate| {
                            defer allocator.free(candidate);
                            excel_experimental_len = candidate.len;
                            excel_experimental_first_diff = firstDiff(candidate, compressed);
                            if (std.mem.eql(u8, candidate, compressed)) {
                                excel_experimental_label = candidate_spec.label;
                                stats.excel_experimental_exact_any += 1;
                                stats.excel_experimental_exact_observed += 1;
                                if (candidate_spec.nice == 35) stats.excel_experimental_exact_nice35 += 1;
                                if (candidate_spec.nice == 60) stats.excel_experimental_exact_nice60 += 1;
                            }
                        }
                    }
                }
            }
        }

        if (std.mem.eql(u8, excel_experimental_label, "none")) {
            const got35 = encodeWorksheetCandidate(allocator, original, 35) catch null;
            if (got35) |candidate| {
                defer allocator.free(candidate);
                excel_experimental_len = candidate.len;
                excel_experimental_first_diff = firstDiff(candidate, compressed);
                if (std.mem.eql(u8, candidate, compressed)) {
                    excel_experimental_label = "nice35";
                    stats.excel_experimental_exact_any += 1;
                    stats.excel_experimental_exact_nice35 += 1;
                }
            }
        }

        if (std.mem.eql(u8, excel_experimental_label, "none")) {
            const got60 = encodeWorksheetCandidate(allocator, original, 60) catch null;
            if (got60) |candidate| {
                defer allocator.free(candidate);
                excel_experimental_len = candidate.len;
                excel_experimental_first_diff = firstDiff(candidate, compressed);
                if (std.mem.eql(u8, candidate, compressed)) {
                    excel_experimental_label = "nice60";
                    stats.excel_experimental_exact_any += 1;
                    stats.excel_experimental_exact_nice60 += 1;
                }
            }

            if (std.mem.eql(u8, excel_experimental_label, "none")) {
                const got_row = encodeWorksheetRowChunkCandidate(allocator, original, 48, 1024) catch null;
                if (got_row) |candidate| {
                    defer allocator.free(candidate);
                    excel_experimental_len = candidate.len;
                    excel_experimental_first_diff = firstDiff(candidate, compressed);
                    if (std.mem.eql(u8, candidate, compressed)) {
                        excel_experimental_label = "row1024";
                        stats.excel_experimental_exact_any += 1;
                        stats.excel_experimental_exact_row1024 += 1;
                    }
                }
            }
        }
    }

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
            std.debug.print("    hit  #{d} {s} ({d}B in, {d}B compressed", .{
                result.fingerprint_id, entry_name, original.len, compressed.len,
            });
            if (excel_experimental and dfp.ooxml.isWorksheetPath(entry_name)) {
                std.debug.print(", excel-experimental={s} len={d} first_diff={d}", .{
                    excel_experimental_label,
                    excel_experimental_len,
                    excel_experimental_first_diff,
                });
            }
            std.debug.print(")\n", .{});
        }
        return;
    }

    if (try dfp.fingerprintConfigured(allocator, original, compressed)) |configured| {
        var owned = configured;
        defer owned.deinit(allocator);
        stats.entries_configured_identified += 1;
        if (verbose) {
            std.debug.print("    config-hit {s} ({d}B in, {d}B compressed", .{
                entry_name, original.len, compressed.len,
            });
            if (excel_experimental and dfp.ooxml.isWorksheetPath(entry_name)) {
                std.debug.print(", excel-experimental={s} len={d} first_diff={d}", .{
                    excel_experimental_label,
                    excel_experimental_len,
                    excel_experimental_first_diff,
                });
            }
            std.debug.print(", memLevel={d}, flushes={d})\n", .{
                owned.config.mem_level,
                owned.config.sync_flushes.len,
            });
        }
        return;
    }

    stats.entries_missed += 1;
    if (verbose) {
        std.debug.print("    miss {s} ({d}B in, {d}B compressed", .{
            entry_name, original.len, compressed.len,
        });
        if (excel_experimental and dfp.ooxml.isWorksheetPath(entry_name)) {
            std.debug.print(", excel-experimental={s} len={d} first_diff={d}", .{
                excel_experimental_label,
                excel_experimental_len,
                excel_experimental_first_diff,
            });
        }
        std.debug.print(")\n", .{});
        printBlockSummary(allocator, compressed);
    }
}

const Args = struct {
    dir: []const u8,
    verbose: bool = false,
    limit: ?usize = null,
    max_streams: ?usize = null,
    progress_every: ?usize = null,
    excel_experimental: bool = false,
};

fn parseArgs(allocator: std.mem.Allocator, args_in: std.process.Args) !Args {
    var it = try std.process.Args.Iterator.initAllocator(args_in, allocator);
    defer it.deinit();
    _ = it.next(); // skip program name

    var dir: ?[]const u8 = null;
    var verbose = false;
    var limit: ?usize = null;
    var max_streams: ?usize = null;
    var progress_every: ?usize = null;
    var excel_experimental = false;

    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "--excel-experimental")) {
            excel_experimental = true;
        } else if (std.mem.startsWith(u8, a, "--limit=")) {
            limit = try std.fmt.parseInt(usize, a["--limit=".len..], 10);
        } else if (std.mem.eql(u8, a, "--limit")) {
            const v = it.next() orelse return error.MissingLimitValue;
            limit = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.startsWith(u8, a, "--max-streams=")) {
            max_streams = try std.fmt.parseInt(usize, a["--max-streams=".len..], 10);
        } else if (std.mem.eql(u8, a, "--max-streams")) {
            const v = it.next() orelse return error.MissingMaxStreamsValue;
            max_streams = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.startsWith(u8, a, "--progress=")) {
            progress_every = try std.fmt.parseInt(usize, a["--progress=".len..], 10);
        } else if (std.mem.eql(u8, a, "--progress")) {
            const v = it.next() orelse return error.MissingProgressValue;
            progress_every = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                \\zip-corpus-probe: identify raw-DEFLATE streams in real ZIP archives.
                \\
                \\Usage: zip-corpus-probe <dir> [--verbose] [--limit N] [--max-streams N] [--progress N] [--excel-experimental]
                \\
                \\Walks <dir> recursively, processes every .zip/.docx/.jar/.epub/.odt/
                \\.xlsx/.pptx file found, parses each archive's central directory,
                \\and runs the deflate_fingerprint identifier on every DEFLATE entry.
                \\
                \\Reports aggregate stats: how many streams were identified by which
                \\fingerprint, how many were missed, etc.
                \\
                \\--limit bounds archives scanned. --max-streams bounds DEFLATE entries
                \\processed across archives. --progress N writes aggregate progress to
                \\stderr every N archives.
                \\
                \\--excel-experimental additionally tests current unregistered
                \\Excel worksheet hypotheses: memLevel=7, chain=16, insert=4,
                \\nice=35 and nice=60 segmented at sheetData boundaries, plus
                \\nice=48 with extra 1024-row chunk sync-flush boundaries.
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
        std.debug.print("usage: zip-corpus-probe <dir> [--verbose] [--limit N] [--max-streams N] [--progress N] [--excel-experimental]\n", .{});
        std.process.exit(2);
    }
    return .{
        .dir = dir.?,
        .verbose = verbose,
        .limit = limit,
        .max_streams = max_streams,
        .progress_every = progress_every,
        .excel_experimental = excel_experimental,
    };
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
                if (al != bl) {
                    eq = false;
                    break;
                }
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
        if (args.max_streams) |lim| {
            if (stats.entries_deflate >= lim) break;
        }
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

        processArchive(allocator, path_dup, buf, &stats, args.verbose, args.excel_experimental, args.max_streams) catch |err| {
            std.debug.print("  parse error in {s}: {s}\n", .{ path_dup, @errorName(err) });
            stats.files_failed_parse += 1;
        };

        if (args.progress_every) |every| {
            if (every != 0 and stats.files_scanned % every == 0) {
                std.debug.print(
                    "progress: archives={d} deflate={d} registry={d} configured={d} missed={d}\n",
                    .{
                        stats.files_scanned,
                        stats.entries_deflate,
                        stats.entries_identified,
                        stats.entries_configured_identified,
                        stats.entries_missed,
                    },
                );
            }
        }
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    try stats.print(&stdout_writer.interface);
    try stdout_writer.interface.flush();
}
