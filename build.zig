const std = @import("std");
const CrossTarget = @import("std").zig.CrossTarget;
const Mode = std.builtin.Mode;
const LibExeObjStep = std.build.LibExeObjStep;


pub const Config = struct {
    backend: Backend = .auto,
    force_egl: bool = false,

    enable_x11: bool = true,
    enable_wayland: bool = false
};
pub const Backend = enum {
    auto,   // Windows: D3D11, macOS/iOS: Metal, otherwise: GL
    d3d11,
    metal,
    gl,
    gles2,
    gles3,
    wgpu,
};

pub fn build(b: *std.build.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    
    const target = b.standardTargetOptions(.{});
    
    // Standard optimize options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});
    var config:Config = .{};

    const exe = b.addExecutable(.{
        .name = "Maquina sencilla",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.linkLibCpp();//imgui needs libcpp
    exe.addIncludePath("src/");



    //cimgui 
    exe.addCSourceFile("src/c/compilation.c",&[_][]u8{""});
    const cpp_args = [_][]const u8{ "-Wno-deprecated-declarations", "-Wno-return-type-c-linkage", "-fno-exceptions", "-fno-threadsafe-statics" };
    exe.addCSourceFile("src/cimgui/imgui/imgui.cpp", &cpp_args);
    // Need to add this after updating imgui to 1.80+
    exe.addCSourceFile("src/cimgui/imgui/imgui_tables.cpp", &cpp_args);
    exe.addCSourceFile("src/cimgui/imgui/imgui_demo.cpp", &cpp_args);
    exe.addCSourceFile("src/cimgui/imgui/imgui_draw.cpp", &cpp_args);
    exe.addCSourceFile("src/cimgui/imgui/imgui_widgets.cpp", &cpp_args);
    exe.addCSourceFile("src/cimgui/cimgui.cpp", &cpp_args);

    //hex editor (from imgui-club on github)
    exe.addCSourceFile("src/hex_editor/hex_editor_wrappers.cpp",&cpp_args);

    //ImGuiColorTextEdit (also from github)
    exe.addCSourceFile("src/ColorTextEdit/TextEditor.cpp",&cpp_args);
    exe.addCSourceFile("src/ColorTextEdit/TextEditorWrappers.cpp",&cpp_args);


    var _backend = config.backend;
    if (_backend == .auto) {
        if (exe.target.isDarwin()) { _backend = .metal; }
        else if (exe.target.isWindows()) { _backend = .d3d11; }
        else { _backend = .gl; }
    }

     if (target.isDarwin()) {
        exe.linkFramework("Cocoa");
        exe.linkFramework("QuartzCore");
        exe.linkFramework("AudioToolbox");
        if (.metal == _backend) {
            exe.linkFramework("MetalKit");
            exe.linkFramework("Metal");
        }
        else {
            exe.linkFramework("OpenGL");
        }
    } else {
        if (exe.target.isLinux()) {
            var link_egl = config.force_egl or config.enable_wayland;
            var egl_ensured = (config.force_egl and config.enable_x11) or config.enable_wayland;

            exe.linkSystemLibrary("asound");

            if (.gles2 == _backend) {
                exe.linkSystemLibrary("glesv2");
                if (!egl_ensured) {
                    @panic("GLES2 in Linux only available with Config.force_egl and/or Wayland");
                }
            } else {
                exe.linkSystemLibrary("GL");
            }
            if (config.enable_x11) {
                exe.linkSystemLibrary("X11");
                exe.linkSystemLibrary("Xi");
                exe.linkSystemLibrary("Xcursor");
            }
            if (config.enable_wayland) {
                exe.linkSystemLibrary("wayland-client");
                exe.linkSystemLibrary("wayland-cursor");
                exe.linkSystemLibrary("wayland-egl");
                exe.linkSystemLibrary("xkbcommon");
            }
            if (link_egl) {
                exe.linkSystemLibrary("egl");
            }
        }
        else if (exe.target.isWindows()) {
            exe.linkSystemLibraryName("kernel32");
            exe.linkSystemLibraryName("user32");
            exe.linkSystemLibraryName("gdi32");
            exe.linkSystemLibraryName("ole32");
            if (.d3d11 == _backend) {
                exe.linkSystemLibraryName("d3d11");
                exe.linkSystemLibraryName("dxgi");
            }
        }
    }


    exe.install();
    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

}