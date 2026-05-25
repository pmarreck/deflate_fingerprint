const std = @import("std");
const dfp = @import("deflate_fingerprint");

fn usage() noreturn {
    std.debug.print(
        \\deflate-block-inspect: print raw-DEFLATE block boundaries.
        \\
        \\Usage: deflate-block-inspect RAW_DEFLATE_FILE
        \\
    , .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    _ = it.next();
    const path = it.next() orelse usage();
    if (it.next() != null) usage();

    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        std.debug.print("could not open '{s}': {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    defer file.close(io);

    const st = try file.stat(io);
    const size: usize = @intCast(st.size);
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    try reader.interface.readSliceAll(bytes);

    const blocks = dfp.inspect.inspectBlocks(allocator, bytes) catch |err| {
        std.debug.print("inspect failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(blocks);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("idx\tfinal\ttype\tbit_start\tbit_end\tbyte_end\traw_start\traw_end\ttokens\n");
    for (blocks) |block| {
        try stdout.print(
            "{d}\t{}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
            .{
                block.index,
                block.bfinal,
                @tagName(block.block_type),
                block.compressed_start_bit,
                block.compressed_end_bit,
                (block.compressed_end_bit + 7) / 8,
                block.raw_start,
                block.raw_end,
                block.token_count,
            },
        );
    }
    try stdout.flush();
}
