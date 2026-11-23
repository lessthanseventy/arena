const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Optimized unless asked otherwise: a debug libghostty-vt checks every page on every write,
    // and a window pouring out text falls minutes behind.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "debug, safe (the default), fast or small") orelse .safe;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ghostty = b.dependency("ghostty", .{ .target = target, .optimize = optimize });
    exe_mod.addImport("ghostty-vt", ghostty.module("ghostty-vt"));

    // what a report says arena was; a checkout with no git says "unknown"
    var git_code: u8 = 0;
    const described = b.runAllowFail(&.{ "git", "describe", "--always", "--dirty" }, &git_code, .ignore) catch "unknown";
    const options = b.addOptions();
    options.addOption([]const u8, "commit", std.mem.trim(u8, described, " \n"));
    exe_mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{ .name = "arena", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run arena").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
