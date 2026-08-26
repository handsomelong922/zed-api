const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // WebUI build step skipped: embedding the pre-built webui/dist/index.html
    // (avoids needing webui/node_modules for tsc + vite).

    // Main API module.
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addAnonymousImport("web_index_html", .{ .root_source_file = b.path("webui/dist/index.html") });

    const exe = b.addExecutable(.{
        .name = "zed2api",
        .root_module = mod,
    });

    // Browser-only first-run account setup helper for Docker/VPS deployments.
    const setup_mod = b.createModule(.{
        .root_source_file = b.path("src/headless_login.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const setup_exe = b.addExecutable(.{
        .name = "zed2api-setup",
        .root_module = setup_mod,
    });

    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("bcrypt", .{});
        exe.root_module.linkSystemLibrary("advapi32", .{});
        exe.root_module.linkSystemLibrary("crypt32", .{});
        exe.root_module.linkSystemLibrary("ws2_32", .{});

        setup_exe.root_module.linkSystemLibrary("bcrypt", .{});
        setup_exe.root_module.linkSystemLibrary("advapi32", .{});
        setup_exe.root_module.linkSystemLibrary("crypt32", .{});
        setup_exe.root_module.linkSystemLibrary("ws2_32", .{});
    }

    b.installArtifact(exe);
    b.installArtifact(setup_exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zed2api server");
    run_step.dependOn(&run_cmd.step);

    // Keep protocol conversion, streaming behavior, settings, and remote setup
    // parsing executable through the standard `zig build test` command.
    const providers_test_mod = b.createModule(.{
        .root_source_file = b.path("src/providers.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const providers_tests = b.addTest(.{ .root_module = providers_test_mod });
    const run_providers_tests = b.addRunArtifact(providers_tests);

    const stream_test_mod = b.createModule(.{
        .root_source_file = b.path("src/stream.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const stream_tests = b.addTest(.{ .root_module = stream_test_mod });
    if (target.result.os.tag == .windows) {
        stream_tests.root_module.linkSystemLibrary("bcrypt", .{});
        stream_tests.root_module.linkSystemLibrary("advapi32", .{});
        stream_tests.root_module.linkSystemLibrary("crypt32", .{});
        stream_tests.root_module.linkSystemLibrary("ws2_32", .{});
    }
    const run_stream_tests = b.addRunArtifact(stream_tests);

    const completion_status_test_mod = b.createModule(.{
        .root_source_file = b.path("src/completion_status.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const completion_status_tests = b.addTest(.{ .root_module = completion_status_test_mod });
    const run_completion_status_tests = b.addRunArtifact(completion_status_tests);

    const settings_test_mod = b.createModule(.{
        .root_source_file = b.path("src/settings.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const settings_tests = b.addTest(.{ .root_module = settings_test_mod });
    const run_settings_tests = b.addRunArtifact(settings_tests);

    const setup_test_mod = b.createModule(.{
        .root_source_file = b.path("src/headless_login.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const setup_tests = b.addTest(.{ .root_module = setup_test_mod });
    if (target.result.os.tag == .windows) {
        setup_tests.root_module.linkSystemLibrary("bcrypt", .{});
        setup_tests.root_module.linkSystemLibrary("advapi32", .{});
        setup_tests.root_module.linkSystemLibrary("crypt32", .{});
        setup_tests.root_module.linkSystemLibrary("ws2_32", .{});
    }
    const run_setup_tests = b.addRunArtifact(setup_tests);

    const test_step = b.step("test", "Run protocol, streaming, settings, and setup regression tests");
    test_step.dependOn(&run_providers_tests.step);
    test_step.dependOn(&run_stream_tests.step);
    test_step.dependOn(&run_completion_status_tests.step);
    test_step.dependOn(&run_settings_tests.step);
    test_step.dependOn(&run_setup_tests.step);
}
