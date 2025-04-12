const std = @import("std");
const CrossTarget = @import("std").zig.CrossTarget;
const Mode = std.builtin.Mode;
const LibExeObjStep = std.build.LibExeObjStep;

pub const Config = struct { backend: Backend = .auto, force_egl: bool = false, enable_x11: bool = true, enable_wayland: bool = false };
pub const Backend = enum {
    auto, // Windows: D3D11, macOS/iOS: Metal, otherwise: GL
    d3d11,
    metal,
    gl,
    gles2,
    gles3,
    wgpu,
};
pub fn web_build(b: *std.Build, config: Config, optimize: std.builtin.Mode, target: std.Build.ResolvedTarget) !void {
    if (b.sysroot == null) {
        std.log.err("Please build with 'zig build -Dtarget=wasm32-emscripten --sysroot [path/to/emsdk]/upstream/emscripten/cache/sysroot", .{});
        return error.SysRootExpected;
    }

    const options = b.addOptions();
    options.addOption(bool, "use_nfd", false);

    // sokol must be built with wasm32-emscripten
    var wasm32_emscripten_target = target;
    wasm32_emscripten_target.query.os_tag = .emscripten;
    const libsokol = try lib_sokol_cimgui(b, config, optimize, wasm32_emscripten_target);

    const include_path = try std.fs.path.join(b.allocator, &.{ b.sysroot.?, "include" });
    defer b.allocator.free(include_path);

    libsokol.defineCMacro("__EMSCRIPTEN__", "1");
    libsokol.addIncludePath(b.path(include_path));

    const cpp_args = [_][]const u8{ "-Wno-deprecated-declarations", "-Wno-return-type-c-linkage", "-fno-exceptions", "-fno-threadsafe-statics" };
    _ = cpp_args;

    //we have to compile the rest of the code as a library with wasm32-freestanding
    var wasm32_freestanding_target = target;
    wasm32_freestanding_target.query.os_tag = .freestanding;

    b.installArtifact(libsokol);
}

pub fn lib_sokol_cimgui(b: *std.Build, config: Config, optimize: std.builtin.Mode, target: std.Build.ResolvedTarget) !*std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{ .name = "sokol", .target = target, .optimize = optimize, .link_libc = true });
    lib.linkLibC();
    lib.setVerboseLink(true);
    lib.addIncludePath(b.path("src/"));
    lib.addCSourceFile(.{ .file = b.path("src/c/compilation.c") });
    var _backend = config.backend;
    if (_backend == .auto) {
        if (target.query.os_tag == .macos) {
            _backend = .metal;
        } else if (target.query.os_tag == .windows) {
            _backend = .d3d11;
        } else {
            _backend = .gl;
        }
    }

    if (target.result.os.tag.isDarwin()) {
        lib.linkFramework("Cocoa");
        lib.linkFramework("QuartzCore");
        lib.linkFramework("AudioToolbox");
        if (.metal == _backend) {
            lib.linkFramework("MetalKit");
            lib.linkFramework("Metal");
        } else {
            lib.linkFramework("OpenGL");
        }
    } else {
        if (target.result.os.tag == .linux) {
            const link_egl = config.force_egl or config.enable_wayland;
            const egl_ensured = (config.force_egl and config.enable_x11) or config.enable_wayland;
            lib.linkSystemLibrary("asound");

            if (.gles2 == _backend) {
                lib.linkSystemLibrary("glesv2");
                if (!egl_ensured) {
                    @panic("GLES2 in Linux only available with Config.force_egl and/or Wayland");
                }
            } else {
                lib.linkSystemLibrary("GL");
            }
            if (config.enable_x11) {
                lib.linkSystemLibrary("X11");
                lib.linkSystemLibrary("Xi");
                lib.linkSystemLibrary("Xcursor");
            }
            if (config.enable_wayland) {
                lib.linkSystemLibrary("wayland-client");
                lib.linkSystemLibrary("wayland-cursor");
                lib.linkSystemLibrary("wayland-egl");
                lib.linkSystemLibrary("xkbcommon");
            }
            if (link_egl) {
                lib.linkSystemLibrary("egl");
            }
        } else if (target.result.os.tag == .windows) {
            // we need to disable lto to build release on windows
            // because of https://github.com/ziglang/zig/issues/8531
            lib.want_lto = false;
            lib.linkSystemLibrary("kernel32");
            lib.linkSystemLibrary("user32");
            lib.linkSystemLibrary("gdi32");
            lib.linkSystemLibrary("ole32");
            if (.d3d11 == _backend) {
                lib.linkSystemLibrary("d3d11");
                lib.linkSystemLibrary("dxgi");
            }
        }
    }
    return lib;
}

pub fn native_build(b: *std.Build, config: Config, optimize: std.builtin.Mode, target: std.Build.ResolvedTarget) !void {
    const options = b.addOptions();
    options.addOption(bool, "use_nfd", false);

    const exe = b.addExecutable(.{
        .name = "Maquina sencilla",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.query.os_tag == .windows) {
        exe.want_lto = false;
    }
    exe.linkLibC();
    exe.linkLibCpp(); //imgui needs libcpp
    exe.addIncludePath(b.path("src/"));

    //native file dialog
    const nfd = b.dependency("nfd", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("nfd", nfd.module("nfd"));
    // exe.linkLibrary(nfd.artifact("nfd"));

    //cimgui + sokol
    const lib_sokol = try lib_sokol_cimgui(b, config, optimize, target);
    exe.linkLibrary(lib_sokol);

    const cpp_args = [_][]const u8{ "-Wno-deprecated-declarations", "-Wno-return-type-c-linkage", "-fno-exceptions", "-fno-threadsafe-statics" };
    exe.addCSourceFile(.{ .file = b.path("src/cimgui/imgui/imgui.cpp"), .flags = &cpp_args });
    // Need to add this after updating imgui to 1.80+
    exe.addCSourceFile(.{ .file = b.path("src/cimgui/imgui/imgui_tables.cpp"), .flags = &cpp_args });
    exe.addCSourceFile(.{ .file = b.path("src/cimgui/imgui/imgui_demo.cpp"), .flags = &cpp_args });
    exe.addCSourceFile(.{ .file = b.path("src/cimgui/imgui/imgui_draw.cpp"), .flags = &cpp_args });
    exe.addCSourceFile(.{ .file = b.path("src/cimgui/imgui/imgui_widgets.cpp"), .flags = &cpp_args });
    exe.addCSourceFile(.{ .file = b.path("src/cimgui/cimgui.cpp"), .flags = &cpp_args });

    //hex editor (from imgui-club on github)
    exe.addCSourceFile(.{ .file = b.path("src/hex_editor/hex_editor_wrappers.cpp"), .flags = &cpp_args });

    //ImGuiColorTextEdit (also from github)
    exe.addCSourceFile(.{ .file = b.path("src/ColorTextEdit/TextEditor.cpp"), .flags = &cpp_args });
    exe.addCSourceFile(.{ .file = b.path("src/ColorTextEdit/TextEditorWrappers.cpp"), .flags = &cpp_args });

    b.installArtifact(exe);
    var run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const config: Config = .{};
    std.debug.print("target: {any}\n", .{target});
    if (target.result.cpu.arch != .wasm32) {
        native_build(b, config, optimize, target) catch unreachable;
    } else {
        web_build(b, config, optimize, target) catch |err| {
            std.log.err("buildeando web ha habido un errorsito: {}", .{err});
        };
    }
}
