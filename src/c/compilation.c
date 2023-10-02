#define SOKOL_IMPL

#if defined(_WIN32)
    #define SOKOL_WIN32_FORCE_MAIN
    #define SOKOL_D3D11
#elif defined(__APPLE__)
    #define SOKOL_METAL
#elif defined(__EMSCRIPTEN__)
    #define SOKOL_GLES2
#else
    #define SOKOL_GLCORE33
#endif

#define SOKOL_NO_ENTRY
#include "sokol/sokol_app.h"
#include "sokol/sokol_gfx.h"
#include "c/sokol_gp.h"
#include "sokol/sokol_time.h"
#include "sokol/sokol_glue.h"
#include "sokol/sokol_log.h"
#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS
// #define IMGUI_ENABLE_FREETYPE
// #define CIMGUI_FREETYPE
// #define IMGUI_FREETYPE
#include "cimgui/cimgui.h"
#define SOKOL_IMGUI_IMPL
#include "sokol/util/sokol_imgui.h"
#define STB_IMAGE_IMPLEMENTATION
#include "c/stb_image.h"