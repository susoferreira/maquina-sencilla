#include <stdint.h>
#include <stdlib.h>
#include <emscripten.h>
// Zig compiles C code with -fstack-protector-strong which requires the following two symbols
// which don't seem to be provided by the emscripten toolchain(?)

uintptr_t __stack_chk_guard = 0xABBABABA;
_Noreturn void __stack_chk_fail(void) { abort(); };

void create_flowchart_popup(char* flowchart){
    EM_ASM(
        document.getElementsByClassName("mermaid-source")[0].value = UTF8ToString($0);
        drawFlowchart(UTF8ToString($0));
        var modal = document.getElementById("flowchartsModal");
        modal.style.display = "block";
    ,flowchart);

}

//calls function defined in shell.html
void em_save_file_as(const char* data,const int data_len,const char* file_name){
    EM_ASM(
        let hex_data = new Uint8Array(Module.HEAPU8.buffer,$0, $1);
        downloadBlob(hex_data,UTF8ToString($2),'application/octet-stream');
    ,data,data_len,file_name);
}