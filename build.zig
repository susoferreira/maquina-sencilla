const std = @import("std");
const CrossTarget = @import("std").zig.CrossTarget;
const Mode = std.builtin.Mode;
const LibExeObjStep = std.build.LibExeObjStep;
const sokol = @import("src/sokol-zig/build.zig");


pub fn build(b: *std.build.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    
    const target = b.standardTargetOptions(.{});
    
    // Standard optimize options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});
    const force_gl = b.option(bool, "gl", "Force GL backend") orelse false;
    _ = force_gl;

    const exe = b.addExecutable(.{
        .name = "Maquina sencilla",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.install();
    exe.linkLibC();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);


    //sokol

    exe.addCSourceFile("../src/c/sokol_lib.c", &[_][]const u8{""}); // this contains the implementation for sokol, imported from the .h files


    if (target.isWindows()) {
        //See https://github.com/ziglang/zig/issues/8531 only matters in release mode
        exe.want_lto = false;
            exe.linkSystemLibrary("user32");
            exe.linkSystemLibrary("gdi32");
            exe.linkSystemLibrary("ole32"); // For Sokol audio
    } else if (target.isDarwin()) {
        const frameworks_dir = try macos_frameworks_dir(b);
        exe.addFrameworkDir(frameworks_dir);
        exe.linkFramework("Foundation");
        exe.linkFramework("Cocoa");
        exe.linkFramework("Quartz");
        exe.linkFramework("QuartzCore");
        exe.linkFramework("Metal");
        exe.linkFramework("MetalKit");
        exe.linkFramework("OpenGL");
        exe.linkFramework("Audiotoolbox");
        exe.linkFramework("CoreAudio");
        exe.linkSystemLibrary("c++");
    } else {
        // Not tested
        exe.linkSystemLibrary("GL");
        exe.linkSystemLibrary("GLEW");
        @panic("OS not supported. Try removing panic in build.zig if you want to test this");
    }
}
// helper function to get SDK path on Mac sourced from: https://github.com/floooh/sokol-zig
fn macos_frameworks_dir(b: *std.build.Builder) ![]u8 {
    var str = try b.exec(&[_][]const u8{ "xcrun", "--show-sdk-path" });
    const strip_newline = std.mem.lastIndexOf(u8, str, "\n");
    if (strip_newline) |index| {
        str = str[0..index];
    }
    const frameworks_dir = try std.mem.concat(b.allocator, u8, &[_][]const u8{ str, "/System/Library/Frameworks" });
    return frameworks_dir;
}