#!/bin/bash
source "./emsdk/emsdk_env.sh"

zig build-lib src/main.zig -Lzig-out/lib/ -lc -lcimgui -Isrc/ -target wasm32-freestanding -freference-trace 

#-Doptimize=debug

mv libmain.a ./zig-out/lib/libmain.a
rm *libmain*

emcc \
    src/c/web-build.c\
    src/cimgui/imgui/imgui.cpp \
    src/cimgui/imgui/imgui_tables.cpp \
    src/cimgui/imgui/imgui_demo.cpp \
    src/cimgui/imgui/imgui_draw.cpp \
    src/cimgui/imgui/imgui_widgets.cpp \
    src/cimgui/cimgui.cpp \
    src/hex_editor/hex_editor_wrappers.cpp \
    src/ColorTextEdit/TextEditor.cpp \
    src/ColorTextEdit/TextEditorWrappers.cpp \
    src/c/compilation.c \
    -Os \
    -Isrc/ \
    -ozig-out/web/emu.html \
    -Lzig-out/lib \
    -lmain \
    -lGL \
    -sNO_FILESYSTEM=1 \
    -sASSERTIONS=1 \
    -sMALLOC='emmalloc' \
    -sEXPORTED_FUNCTIONS=['_malloc','_free','_main'] \
    -sMAX_WEBGL_VERSION=2 \
    -s TOTAL_MEMORY=2048MB \
    --shell-file ./src/shell.html
    #-g \

