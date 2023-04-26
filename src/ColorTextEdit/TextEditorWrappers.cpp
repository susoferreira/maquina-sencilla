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
        if (ImGui::BeginMenuBar())
            {
                if (ImGui::BeginMenu("Edit"))
                {
                    bool ro = editor.IsReadOnly();
                    if (ImGui::MenuItem("Read-only mode", nullptr, &ro))
                        editor.SetReadOnly(ro);
                    ImGui::Separator();

                    if (ImGui::MenuItem("Undo", "ALT-Backspace", nullptr, !ro && editor.CanUndo()))
                        editor.Undo();
                    if (ImGui::MenuItem("Redo", "Ctrl-Y", nullptr, !ro && editor.CanRedo()))
                        editor.Redo();

                    ImGui::Separator();

                    if (ImGui::MenuItem("Copy", "Ctrl-C", nullptr, editor.HasSelection()))
                        editor.Copy();
                    if (ImGui::MenuItem("Cut", "Ctrl-X", nullptr, !ro && editor.HasSelection()))
                        editor.Cut();
                    if (ImGui::MenuItem("Delete", "Del", nullptr, !ro && editor.HasSelection()))
                        editor.Delete();
                    if (ImGui::MenuItem("Paste", "Ctrl-V", nullptr, !ro && ImGui::GetClipboardText() != nullptr))
                        editor.Paste();

                    ImGui::Separator();

                    if (ImGui::MenuItem("Select all", nullptr, nullptr))
                        editor.SetSelection(TextEditor::Coordinates(), TextEditor::Coordinates(editor.GetTotalLines(), 0));

                    ImGui::EndMenu();
                }

                if (ImGui::BeginMenu("View"))
                {
                    if (ImGui::MenuItem("Dark palette"))
                        editor.SetPalette(TextEditor::GetDarkPalette());
                    if (ImGui::MenuItem("Light palette"))
                        editor.SetPalette(TextEditor::GetLightPalette());
                    if (ImGui::MenuItem("Retro blue palette"))
                        editor.SetPalette(TextEditor::GetRetroBluePalette());
                    ImGui::EndMenu();
                }
                ImGui::EndMenuBar();
            }

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