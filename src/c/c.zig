const builtin = @import("builtin");

pub const is_native = switch(builtin.os.tag){
    .windows,.linux =>true,
    .freestanding => false,
    else => {@compileError("platform not supported");}
};

pub usingnamespace @cImport({
    @cDefine("SOKOL_GLCORE33", "");
    @cInclude("sokol/sokol_app.h");
    @cInclude("sokol/sokol_gfx.h");
    @cInclude("sokol/sokol_time.h");
    @cInclude("sokol/sokol_log.h");
    @cInclude("sokol/sokol_audio.h");
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "");
    @cInclude("cimgui/cimgui.h");
    @cInclude("sokol/util/sokol_imgui.h");
    @cInclude("sokol/sokol_glue.h");
    @cInclude("hex_editor/hex_editor_wrappers.h");
    @cInclude("ColorTextEdit/TextEditorWrappers.h");
    if(!is_native){
        @cInclude("./c/web-build.h");
    }
});