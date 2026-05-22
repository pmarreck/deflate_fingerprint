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
    // (core_mod is consumed below by the zip-corpus-probe build target.)

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

    // ─── ZIP corpus probe (tools/zip_corpus_probe.zig) ───────────────────
    // Walks a directory of real ZIP-format archives, parses central
    // directories, runs the identifier on every DEFLATE entry. Links libC
    // + system zlib for the inflate oracle.
    const probe_mod = b.createModule(.{
        .root_source_file = b.path("tools/zip_corpus_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    probe_mod.addImport("deflate_fingerprint", core_mod);
    probe_mod.linkSystemLibrary("z", .{});
    const probe = b.addExecutable(.{
        .name = "zip-corpus-probe",
        .root_module = probe_mod,
    });
    // Not part of the default install (nix build sandbox doesn't have zlib).
    // `nix develop -c zig build probe -- /path` runs it in the dev shell.
    // `nix develop -c zig build probe-install` installs the binary to zig-out/bin.
    const probe_run = b.addRunArtifact(probe);
    if (b.args) |args| probe_run.addArgs(args);
    b.step("probe", "Run the ZIP corpus probe (dev shell only)").dependOn(&probe_run.step);
    const probe_install = b.addInstallArtifact(probe, .{});
    b.step("probe-install", "Install zip-corpus-probe to zig-out/bin").dependOn(&probe_install.step);

    // ─── Unit tests ──────────────────────────────────────────────────────
    // The test binary links libC + system zlib so tests can `@cImport(zlib.h)`
    // and assert byte-exact equality against real zlib output directly,
    // without going through external C helper binaries.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.linkSystemLibrary("z", .{});
    const run_tests = b.addRunArtifact(b.addTest(.{
        .root_module = test_mod,
    }));
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
