const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{ .name = "window_streaming", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }), .use_llvm = true });
    exe.linkLibC();
    //exe.linkLibC();

    if (target.result.os.tag == std.Target.Os.Tag.linux) {
        exe.linkSystemLibrary("xcb");
    }
    if (target.result.os.tag == std.Target.Os.Tag.windows) {
        if (builtin.os.tag == .linux) {
            exe.addIncludePath(.{ .cwd_relative = "/usr/x86_64-w64-mingw32/include" });
            exe.addLibraryPath(.{ .cwd_relative = "/usr/x86_64-w64-mingw32/lib" });
        }
        exe.linkSystemLibrary("user32");
        exe.linkSystemLibrary("kernel32");
    }

    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");

    test_step.dependOn(&run_exe_tests.step);
}
