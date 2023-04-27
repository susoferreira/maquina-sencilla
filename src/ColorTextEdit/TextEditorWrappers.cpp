#include <string.h>
#include "TextEditor.h"
TextEditor editor;
auto lang = TextEditor::LanguageDefinition::MaquinaSencilla();
TextEditor::Breakpoints bpts;

char* lastText;


extern "C"{




    void setupAssemblyEditor(){
        editor.SetLanguageDefinition(lang);
        editor.SetBreakpoints(bpts);
        editor.SetPalette(TextEditor::GetDarkPalette());
        lastText = new char[1];
        strncpy(lastText,"",1);
    }

    void drawAssemblyEditor(){
        
    auto cpos = editor.GetCursorPosition();

        ImGui::Text("%6d/%-6d %6d lines  | %s | %s | %s", cpos.mLine + 1, cpos.mColumn + 1, editor.GetTotalLines(),
            editor.IsOverwrite() ? "Ovr" : "Ins",
            editor.CanUndo() ? "*" : " ",
            editor.GetLanguageDefinition().mName.c_str());

        editor.Render("TextEditor");
    
    }

    void editorSetText(const char* str){
        editor.SetText(str);
    }

    void editorSetBreakpoints(int* indexes,int len_indexes){
        bpts.clear();
        for(int i =0;i<len_indexes;i++){
            bpts.insert(indexes[i]);
        }
        editor.SetBreakpoints(bpts);
    }
    const char* getAssemblyEditorText(){
        delete [] lastText; 
        std::string text = editor.GetText();
        lastText = new char[text.length()+1];
        strncpy(lastText,text.c_str(),text.length()+1);
        lastText[text.length()]=0;
        return lastText;
    }
}