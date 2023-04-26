#include "cimgui/imgui/imgui.h"
#include "hex_editor/imgui_hex_editor.hpp"

static MemoryEditor mem_edit;

extern "C"{
    void init_hex_editor(){
        mem_edit.Cols=2;
        mem_edit.OptShowAscii=false;

    }
    void draw_hex_editor(uint16_t* data, uint32_t data_size){
        mem_edit.DrawWindow("Memory Editor", data, data_size);
    }
}