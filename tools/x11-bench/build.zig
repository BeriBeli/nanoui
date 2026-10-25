const std = @import("std");

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, version: []const u8) void {
    const os = target.result.os.tag;
    if (os != .linux and os != .macos) return;
    const options = b.addOptions();
    options.addOption(bool, "portable", true);
    options.addOption([]const u8, "version", version);
    const nano = b.createModule(.{ .root_source_file = b.path("src/nanoui.zig"), .target = target, .optimize = .ReleaseSafe, .link_libc = true });
    nano.addOptions("build_options", options);
    if (os == .macos) {
        for ([_][]const u8{ "AppKit", "WebKit", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "CoreFoundation", "Foundation", "ImageIO", "UniformTypeIdentifiers", "CoreVideo" }) |f| nano.linkFramework(f, .{});
        nano.linkSystemLibrary("objc", .{});
    } else for ([_][]const u8{ "dl", "pthread" }) |lib| nano.linkSystemLibrary(lib, .{});
    const root = b.createModule(.{ .root_source_file = b.path("tools/x11-bench/main.zig"), .target = target, .optimize = .ReleaseSafe, .link_libc = true, .imports = &.{.{ .name = "nanoui", .module = nano }} });
    const exe = b.addExecutable(.{ .name = "nanoui-x11-bench", .root_module = root });
    b.step("x11-bench", "Build the CPU/X11 forwarding benchmark").dependOn(&b.addInstallArtifact(exe, .{}).step);
    const tests = b.addTest(.{ .root_module = root });
    b.step("test-x11-bench", "Test X11 workloads, input and bounded metrics offscreen").dependOn(&b.addRunArtifact(tests).step);
    b.step("x11-bench-test-bin", "Install benchmark tests for a Linux container").dependOn(&b.addInstallArtifact(tests, .{ .dest_sub_path = "nanoui-x11-bench-tests" }).step);
}
