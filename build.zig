const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addSharedLibrary("tmp", "src/maquina_sencilla.zig",b.version(0,0,1));
    exe.setBuildMode(mode);
    exe.install();

    const assembler_tests = b.addTest("src/assembler.zig");
    assembler_tests.setBuildMode(mode);
    

    const components_tests = b.addTest("src/components.zig");
    components_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&assembler_tests.step);
    test_step.dependOn(&components_tests.step);
}