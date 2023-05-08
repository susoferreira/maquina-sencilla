# maquina-sencilla
Emulador sencillo de una hipotética máquina con 256bytes de memoria, sin registros, con 4 instrucciones ```ADD```,```JMP```,```CMP``` y ```BEQ``` y una sola flag
```FZ```, se ha creado con objetivos educativos (tanto para mi como para quién pueda leer el código,ya que en su mayoría es muy legible y fácil de entender (```src/components.zig```))

## Instrucciones de uso
- Descargar el emulador de [Releases](https://github.com/susoferreira/maquina-sencilla/releases), Es un ejecutable tanto para windows como para linux. En el futuro se creará una release para macos y posiblemente para web
- El ejecutable tiene docking activado, lo que significa que las ventanas se pueden acoplar entre ellas como prefiera el usuario.
- El programa de ejemplo que viene precargado demuestra como funciona la sintaxis del assembler, usando ```:label```, ```:*breakpoint``` y ```;comentario```
- En el menu se pueden ver las opciones que ofrece el programa: Guardar y cargar archivos (texto plano), exportar a .ms (versión de msdos de la maquina sencilla) y generar diagrama. tambien las opciones de ejecucción del código (ensamblar, ejecutar instruccion...)

### Logs y errores

Los logs y errores del programa **por el momento** se muestran por la consola.
Si encuentras algún bug en el programa por favor reportalo en issues

### Generación de diagramas
Los diagramas se generan analizando las instrucciones y usando mermaid. El resultado inicial no es perfecto pero es fácilmente modificable al editar el html o incluso al editar el código del html en un editor de mermaid

### Avanzado 
- El inspector de variables internas de la máquina permite modificar su estado, aunque modificar algunas de estas variables (como ALU_ENABLE_A la mayoría del tiempo no afectará a la ejecución, porque son inmediatamente sobreescritas según el estado de  ```UC_INTERNAL_STATE```)

## Librerías usadas

- [Sokol](https://github.com/floooh/sokol) (graphics backend)
- [cimgui](https://github.com/cimgui/cimgui) (gui)
- [nfd-zig](https://github.com/fabioarnold/nfd-zig) (file dialogs)
- [ImGuiColorTextEdit](https://github.com/BalazsJako/ImGuiColorTextEdit) (Text editor)
- [Imgui Club](https://github.com/ocornut/imgui_club) (Hex editor)

