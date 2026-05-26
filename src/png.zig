const std = @import("std");

const PNG_SIGNATURE = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

pub const IdatStream = struct {
    zlib_bytes: []u8,
    idat_chunk_sizes: []usize,
    cmf: u8,
    flg: u8,
    adler32: u32,

    pub fn deinit(self: *IdatStream, allocator: std.mem.Allocator) void {
        allocator.free(self.zlib_bytes);
        allocator.free(self.idat_chunk_sizes);
        self.* = undefined;
    }

    pub fn rawDeflate(self: IdatStream) []const u8 {
        return self.zlib_bytes[2 .. self.zlib_bytes.len - 4];
    }
};

fn readU32BE(buf: []const u8, off: usize) u32 {
    return (@as(u32, buf[off]) << 24) |
        (@as(u32, buf[off + 1]) << 16) |
        (@as(u32, buf[off + 2]) << 8) |
        @as(u32, buf[off + 3]);
}

fn isChunkType(actual: []const u8, comptime expected: *const [4]u8) bool {
    return std.mem.eql(u8, actual, expected);
}

pub const PngMetadata = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    compression_method: u8,
    filter_method: u8,
    interlace_method: u8,

    fn channelCount(self: PngMetadata) !usize {
        return switch (self.color_type) {
            0 => 1, // grayscale
            2 => 3, // truecolor
            3 => 1, // indexed color
            4 => 2, // grayscale + alpha
            6 => 4, // truecolor + alpha
            else => error.UnsupportedPngColorType,
        };
    }

    /// Return one PNG filtered scanline length. PNG stores a leading filter
    /// byte before each packed row, so low-bit-depth rows need ceil(bit/8).
    pub fn filteredRowSize(self: PngMetadata) !usize {
        const channels = try self.channelCount();
        const bits: usize = @as(usize, self.width) * channels * @as(usize, self.bit_depth);
        return 1 + ((bits + 7) / 8);
    }
};

/// Classify PNG filenames for corpus extraction. This is adapter discovery
/// only; the DEFLATE core remains raw RFC1951-focused.
pub fn isPngFilename(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "._")) return false;
    if (name.len < 4) return false;
    return std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".png");
}

/// Parse only IHDR image metadata needed by corpus probes. CRC validation and
/// full container validation stay adapter-side; the DEFLATE core consumes only
/// raw RFC1951 bytes.
pub fn parseIhdrMetadata(png: []const u8) !PngMetadata {
    if (png.len < PNG_SIGNATURE.len or !std.mem.eql(u8, png[0..PNG_SIGNATURE.len], &PNG_SIGNATURE)) {
        return error.BadPngSignature;
    }
    if (png.len - PNG_SIGNATURE.len < 25) return error.TruncatedChunk;
    const off = PNG_SIGNATURE.len;
    const chunk_len = readU32BE(png, off);
    if (chunk_len != 13) return error.MissingIhdr;
    if (!isChunkType(png[off + 4 .. off + 8], "IHDR")) return error.MissingIhdr;
    if (chunk_len > png.len - off - 12) return error.ChunkLengthOutOfRange;

    const data = png[off + 8 .. off + 21];
    return .{
        .width = readU32BE(data, 0),
        .height = readU32BE(data, 4),
        .bit_depth = data[8],
        .color_type = data[9],
        .compression_method = data[10],
        .filter_method = data[11],
        .interlace_method = data[12],
    };
}

/// Extract concatenated PNG IDAT data and expose its RFC 1951 body.
/// PNG stores one zlib-wrapped DEFLATE stream split across IDAT chunks; this
/// parser keeps wrapper metadata while returning raw-DEFLATE bytes to DFP.
pub fn parseIdatStream(allocator: std.mem.Allocator, png: []const u8) !IdatStream {
    if (png.len < PNG_SIGNATURE.len or !std.mem.eql(u8, png[0..PNG_SIGNATURE.len], &PNG_SIGNATURE)) {
        return error.BadPngSignature;
    }

    var idat: std.ArrayListUnmanaged(u8) = .empty;
    errdefer idat.deinit(allocator);
    var chunk_sizes: std.ArrayListUnmanaged(usize) = .empty;
    errdefer chunk_sizes.deinit(allocator);

    var off: usize = PNG_SIGNATURE.len;
    var saw_iend = false;
    while (off < png.len) {
        if (png.len - off < 12) return error.TruncatedChunk;
        const chunk_len: usize = readU32BE(png, off);
        if (chunk_len > png.len - off - 12) return error.ChunkLengthOutOfRange;

        const typ = png[off + 4 .. off + 8];
        const data_start = off + 8;
        const data_end = data_start + chunk_len;
        const data = png[data_start..data_end];

        if (isChunkType(typ, "IDAT")) {
            try idat.appendSlice(allocator, data);
            try chunk_sizes.append(allocator, chunk_len);
        } else if (isChunkType(typ, "IEND")) {
            saw_iend = true;
            break;
        }

        off = data_end + 4; // skip CRC; corpus probes can validate CRC separately.
    }

    if (!saw_iend) return error.MissingIend;
    if (idat.items.len == 0) return error.MissingIdat;

    const zlib_bytes = try idat.toOwnedSlice(allocator);
    idat = .empty;
    errdefer allocator.free(zlib_bytes);
    const sizes = try chunk_sizes.toOwnedSlice(allocator);
    chunk_sizes = .empty;
    errdefer allocator.free(sizes);

    if (zlib_bytes.len < 6) return error.IdatZlibStreamTooShort;
    const cmf = zlib_bytes[0];
    const flg = zlib_bytes[1];
    if ((cmf & 0x0f) != 8) return error.BadZlibMethod;
    if ((cmf >> 4) > 7) return error.BadZlibWindow;
    if (((@as(u16, cmf) << 8) | @as(u16, flg)) % 31 != 0) return error.BadZlibHeaderCheck;
    if ((flg & 0x20) != 0) return error.PresetDictionaryUnsupported;

    return .{
        .zlib_bytes = zlib_bytes,
        .idat_chunk_sizes = sizes,
        .cmf = cmf,
        .flg = flg,
        .adler32 = readU32BE(zlib_bytes, zlib_bytes.len - 4),
    };
}

test "isPngFilename classifies PNG extensions as a set" {
    const yes = [_][]const u8{
        "a.png",
        "A.PNG",
        "photo.PnG",
        "nested.name.png",
    };
    for (yes) |name| {
        try std.testing.expect(isPngFilename(name));
    }
}

test "isPngFilename rejects sidecars and non-PNG names as a set" {
    const no = [_][]const u8{
        "._a.png",
        "a.jpg",
        "png",
        "a.png.tmp",
        "",
    };
    for (no) |name| {
        try std.testing.expect(!isPngFilename(name));
    }
}

test "parseIdatStream concatenates IDAT chunks and strips RFC1950 wrapper" {
    const png = [_]u8{
        0x89, 'P',  'N',  'G',  0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00,
        0x00, 0x00, 0x00, 0x03, 'I',  'D',  'A',  'T',
        0x78, 0x9c, 0x03,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x05, 'I',  'D',  'A',  'T',
        0x00, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 'I',  'E',  'N',  'D',
        0x00, 0x00, 0x00, 0x00,
    };

    var stream = try parseIdatStream(std.testing.allocator, &png);
    defer stream.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 }, stream.zlib_bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x03, 0x00 }, stream.rawDeflate());
    try std.testing.expectEqualSlices(usize, &[_]usize{ 3, 5 }, stream.idat_chunk_sizes);
    try std.testing.expectEqual(@as(u8, 0x78), stream.cmf);
    try std.testing.expectEqual(@as(u8, 0x9c), stream.flg);
    try std.testing.expectEqual(@as(u32, 1), stream.adler32);
}

test "parseIdatStream rejects invalid zlib header checksum" {
    const png = [_]u8{
        0x89, 'P',  'N',  'G',  0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x08, 'I',  'D',  'A',  'T',
        0x78, 0x9d, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 'I',  'E',  'N',  'D',
        0x00, 0x00, 0x00, 0x00,
    };

    try std.testing.expectError(error.BadZlibHeaderCheck, parseIdatStream(std.testing.allocator, &png));
}

test "parseIhdrMetadata exposes PNG filtered row size for truecolor data" {
    const png = [_]u8{
        0x89, 'P',  'N',  'G',  0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x02, 0xd2, 0x00, 0x00, 0x01, 0x0d,
        0x08, 0x02, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 'I',  'E',  'N',  'D',
        0x00, 0x00, 0x00, 0x00,
    };

    const meta = try parseIhdrMetadata(&png);
    try std.testing.expectEqual(@as(u32, 722), meta.width);
    try std.testing.expectEqual(@as(u32, 269), meta.height);
    try std.testing.expectEqual(@as(u8, 8), meta.bit_depth);
    try std.testing.expectEqual(@as(u8, 2), meta.color_type);
    try std.testing.expectEqual(@as(usize, 2167), meta.filteredRowSize());
}

test "parseIhdrMetadata computes packed indexed row sizes with filter byte" {
    const png = [_]u8{
        0x89, 'P',  'N',  'G',  0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x0d, 0x00, 0x00, 0x00, 0x02,
        0x01, 0x03, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 'I',  'E',  'N',  'D',
        0x00, 0x00, 0x00, 0x00,
    };

    const meta = try parseIhdrMetadata(&png);
    try std.testing.expectEqual(@as(usize, 3), meta.filteredRowSize());
}
