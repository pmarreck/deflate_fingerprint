const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // ─── Core library module (pure Zig, no I/O) ──────────────────────────
    // Exposed for downstream Zig consumers (e.g. Mecha Archiver).
    const core_mod = b.addModule("deflate_fingerprint", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = core_mod;

    // ─── Static library with C ABI (the FFI boundary) ────────────────────
    const lib = b.addLibrary(.{
        .name = "deflate_fingerprint",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(lib);

    // ─── C CLI executable (dogfoods the FFI) ─────────────────────────────
    // In Zig 0.16, linkLibrary / addCSourceFile / addIncludePath all live on
    // the *Build.Module rather than the *Step.Compile. Configure the module
    // before passing it to addExecutable.
    const cli_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_mod.addCSourceFile(.{
        .file = b.path("cli/main.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic" },
    });
    cli_mod.addIncludePath(b.path("include"));
    cli_mod.linkLibrary(lib);
    const cli = b.addExecutable(.{
        .name = "deflate-fingerprint",
        .root_module = cli_mod,
    });
    b.installArtifact(cli);

    // ─── Run step ────────────────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(cli);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the deflate-fingerprint CLI").dependOn(&run_cmd.step);

    // ─── Unit tests ──────────────────────────────────────────────────────
    const run_tests = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    }));
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
