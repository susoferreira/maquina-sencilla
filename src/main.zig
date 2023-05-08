pub const log_level: std.log.Level = .err;



const std = @import("std");
const c = @import("c/c.zig");
const assembler = @import("./emulator/assembler.zig").assembler;
const instruction = @import("emulator/assembler.zig").instruction;
const MS = @import("emulator/components.zig").Maquina;
const logger = std.log.scoped(.ui);
const decode_instruction =@import("emulator/components.zig").decode_instruction;
const MS_OPCODE= @import("emulator/components.zig").MS_OPCODE;
const UC_STATES = @import("emulator/components.zig").UC.UC_STATES;
const ALU_OPCODE =@import("emulator/components.zig").ALU_OPCODE;
const diagrams = @import("emulator/flowcharts.zig");
const nfd = @import("nfd");

const example =     \\MOV zero i
    \\MOV zero j
    \\MOV zero res
    \\;esto es un comentario
    \\;las labels se escriben asi -> :<nombre>
    \\;por ejemplo :etiqueta1

    \\:find_min CMP i num1
    \\BEQ min_n1
    \\CMP i num2
    \\BEQ min_n2
    \\ADD one i
    \\CMP zero zero
    \\BEQ find_min

    \\:min_n1 MOV num1 min
    \\MOV num2 max
    \\CMP zero zero
    \\BEQ distance

    \\:min_n2 MOV num2 min
    \\MOV num1 max

    \\:distance ADD one i
    \\ADD one j
    \\CMP i max
    \\BEQ *found
    \\CMP zero zero
    \\BEQ distance
    \\;para crear un breakpoint se hace una label con * como primera letra del nombre
    \\;por ejemplo :*end
    \\;hay que recordar usar *end siempre al referirse a esa label, y no end
    \\:*found MOV j res

    \\:num2 0x0000
    \\:num1 0x0000
    \\:i 0x0000
    \\:j 0x0000
    \\:zero 0x0000
    \\:one 0x0001
    \\:min 0x0000
    \\:max 0x0000
    \\:res 0x0000
;
const State = struct {
    pass_action: c.sg_pass_action,
    main_pipeline: c.sg_pipeline,
    main_bindings: c.sg_bindings,
};


const maquina_data= struct{
    pc:*u7,
    fz:*bool,
    RAM_OUT:*u16,
    Operand_A:*u7,
    Operand_B:*u7,

};

var state: State = undefined;
var last_time: u64 = 0;
var show_test_window: bool = false;
var show_another_window: bool = false;
var display_menu: bool = false;
var f: f32 = 0.0;
var clear_color: [3]f32 = .{ 0.2, 0.2, 0.2 };


var arena =std.heap.ArenaAllocator.init(std.heap.page_allocator);
var ass:assembler=assembler.init("",&arena);
var alloc =std.heap.page_allocator;
var maquina:*MS = undefined;
var maquina_data_inspector :maquina_data =undefined;
var breakpoints:[]c_int=&[_]c_int{};



pub fn inspector_for_u16(name:[]const u8,memory:*u16)void{
    c.igTableNextRow(0,0);
    //add sentinel because C
    var sentinel_name = std.mem.concatWithSentinel(alloc,u8,&[_][]const u8{name[0..name.len]},0) catch unreachable;
    defer alloc.free(sentinel_name);

    //##name uses name as id
    var label = std.mem.concatWithSentinel(alloc,u8,&[_][]const u8{"##",sentinel_name},0) catch unreachable;
    defer alloc.free(label);
    _ = c.igTableNextColumn();
    c.igText(sentinel_name);
    _ = c.igTableNextColumn();
    _ = c.igInputScalar(label,c.ImGuiDataType_U16,memory,null,null,"%04X",0);

}



pub fn inspector_for_u7(name:[]const u8,memory:*u7)void{
    c.igTableNextRow(0,0);
    //add sentinel because C
    var sentinel_name = std.mem.concatWithSentinel(alloc,u8,&[_][]const u8{name[0..name.len]},0) catch unreachable;
    defer alloc.free(sentinel_name);

    //##name uses name as id
    var label = std.mem.concatWithSentinel(alloc,u8,&[_][]const u8{"##",sentinel_name},0) catch unreachable;
    defer alloc.free(label);
    _ = c.igTableNextColumn();
    c.igText(sentinel_name);
    _ = c.igTableNextColumn();
    _ = c.igInputScalar(label,c.ImGuiDataType_U8,memory,null,null,"%02X",0);

}


//just displays a label
pub fn const_int_inspector(name:[]const u8, value:usize)void{
    c.igTableNextRow(0,0);

    var sentinel_name = std.mem.concatWithSentinel(alloc,u8,&[_][]const u8{name[0..name.len]},0) catch unreachable;
    defer alloc.free(sentinel_name);
   
    var value_txt = std.fmt.allocPrint(alloc,"{} (0x{X})",.{value,value}) catch unreachable;
    defer alloc.free(value_txt);
    var sentinel_value_txt = std.mem.concatWithSentinel(alloc,u8,&[_][]const u8{value_txt[0..value_txt.len]},0) catch unreachable;
    defer alloc.free(sentinel_value_txt);

    _ = c.igTableNextColumn();
    c.igText(sentinel_name);

    _ = c.igTableNextColumn();
    _ = c.igText(sentinel_value_txt);

    }

pub fn inspector_for_bool(name:[]const u8,memory:*bool)void{
    c.igTableNextRow(0,0);
    //add sentinel because C
    var sentinel_name = std.mem.concatWithSentinel(alloc,u8,&[_][]const u8{name[0..name.len]},0) catch unreachable;
    defer alloc.free(sentinel_name);
    //##name uses name as id
    var label = std.mem.concatWithSentinel(alloc,u8,&[_][]const u8{"##",sentinel_name},0) catch unreachable;
    defer alloc.free(label);
    _ = c.igTableNextColumn();
    c.igText(sentinel_name);
    _ = c.igTableNextColumn();
    _ = c.igCheckbox(label,memory);

}

pub fn inspector_for_enum(name:[]const u8,comptime T:type,memory:*T,)void{


    if(@typeInfo(T) != .Enum){
        @compileError("inspector_for_enum solo puede recibir T = enum y memory = *enum");
    }
    
    var sentinel_name = std.mem.concatWithSentinel(alloc,u8,&[_][]const u8{name[0..name.len]},0) catch unreachable;
    defer alloc.free(sentinel_name);

    //##name uses name as id
    var label = std.mem.concatWithSentinel(alloc,u8,&[_][]const u8{"##",sentinel_name},0) catch unreachable;
    defer alloc.free(label);


    _ = c.igTableNextColumn();
    c.igText(sentinel_name);
    _ = c.igTableNextColumn();
    if(c.igBeginCombo(label,@tagName(memory.*),0)){
        inline for(@typeInfo(T).Enum.fields)|field|{
            var field_name = std.mem.concatWithSentinel(alloc,u8,&[_][]const u8{field.name}, 0) catch unreachable;
            var selected = @enumToInt(memory.*) == field.value;
            if(c.igSelectable_Bool(field_name,selected,0,c.ImVec2{.x=200,.y=0})){
                memory.* = @intToEnum(T,field.value);
            }
            if(selected){
                c.igSetItemDefaultFocus();
            }

         }
        c.igEndCombo();
     }




}


pub fn inspector_labels()void{
    _ = c.igBegin("Inspector del programa",0,0);
    if (c.igBeginTable("labels_inspector",2, 0,c.ImVec2{.x=200,.y=200},0)) //0 means no flags
    {
        
        // Submit columns name with TableSetupColumn() and call TableHeadersRow() to create a row with a header in each column.
        // (Later we will show how TableSetupColumn() has other uses, optional flags, sizing weight etc.)
        c.igTableSetupColumn("Etiqueta",0,0,0);
        c.igTableSetupColumn("Valor (hex)",0,0,0);
        c.igTableHeadersRow();
        

        for(ass.instructions.items) |label|
        {
            var name = label.name orelse continue;
            if (!label.is_data)
                continue;

            inspector_for_u16(name,&maquina.system_memory.memory[label.index]);
        }
        c.igEndTable();
    }
    c.igEnd();
}



pub fn struct_inspector(comptime T :type, instance:T)void{
    if (c.igBeginTable("maquina_inspector",2, 0,c.ImVec2{.x=200,.y=200},0)) //0 means no flags
    {
        
        // Submit columns name with TableSetupColumn() and call TableHeadersRow() to create a row with a header in each column.
        // (Later we will show how TableSetupColumn() has other uses, optional flags, sizing weight etc.)
        c.igTableSetupColumn("Variable",0,0,0);
        c.igTableSetupColumn("Valor",0,0,0);
        c.igTableHeadersRow();

        inline for(@typeInfo(T).Struct.fields) |field|
        {
            switch(@typeInfo(field.type)){

                .Pointer =>{
                    switch(field.type){

                        *u16 =>{inspector_for_u16(field.name,@field(instance, field.name)); },
                        *u7 =>{inspector_for_u7(field.name,@field(instance, field.name)); },
                        *bool =>{inspector_for_bool(field.name,@field(instance,field.name));},
                        else =>{
                            switch (@typeInfo(@typeInfo(field.type).Pointer.child)){
                                .Enum =>{inspector_for_enum(
                                    field.name,
                                    @typeInfo(field.type).Pointer.child,
                                    @field(instance,field.name),
                                );},
                                else =>{
                                    logger.debug("Tipo no soportado: {s} es de tipo {s}",.{field.name,@typeName(field.type)});
                                }
                            }
                            
                        },
                    }
                },

                .Int => {const_int_inspector(field.name,@field(instance,field.name));},

                else => {logger.debug("fields of struct_inspector should be all pointers but field {s} is a {s}",.{field.name,@typeName(field.type)});}
            }


            
        }
        c.igEndTable();
    }
}



pub fn inspector_maquina()void{

    _ = c.igBegin("Inspector de la maquina",0,0);
    var inspector_data =.{
        .Elapsed_Cycles = maquina.cycle_counter,
        .UC_Internal_State=&maquina.control_unit.state,
        .pc = maquina.program_counter.stored_pc,
        .fz = &maquina.uc_in_flag_zero,
        .RAM_OUT = maquina.system_memory.out_data,
        .RI_enable_read = &maquina.ri_enable_read,
        .Operand_A=maquina.instruction_register.dir1,
        .Operand_B=maquina.instruction_register.dir2,
        .RI_instruction_OPCODE=maquina.instruction_register.op,
        .ALU_Enable_A=&maquina.alu_in_enableA,
        .ALU_Enable_B=&maquina.alu_in_enableB,
        .UC_ALU_OPCODE=maquina.control_unit.alu_out,

    };
    struct_inspector(@TypeOf(inspector_data),inspector_data);


    c.igEnd();
}


export fn init() void {
    maquina=MS.init(&alloc);


    var desc = std.mem.zeroes(c.sg_desc);
    desc.context = c.sapp_sgcontext();
    c.sg_setup(&desc);
    c.stm_setup();
    var imgui_desc = std.mem.zeroes(c.simgui_desc_t);
    c.simgui_setup(&imgui_desc);

    var IO =c.igGetIO();

    IO.*.ConfigFlags |= c.ImGuiConfigFlags_DockingEnable;
    IO.*.FontAllowUserScaling=true;

    state.pass_action.colors[0].action = c.SG_ACTION_CLEAR;
    state.pass_action.colors[0].value = c.sg_color{ .r = clear_color[0], .g = clear_color[1], .b = clear_color[2], .a = 1.0 };
    //_ = c.ImFontAtlas_AddFontFromFileTTF(IO.*.Fonts,"SpaceMono-Bold.ttf",15,null,null);
    //_ = c.ImFontAtlas_Build(IO.*.Fonts);
    c.setupAssemblyEditor();
    c.editorSetText(example);
    c.init_hex_editor();
}


fn ensamblar()void{
    var text = c.getAssemblyEditorText();
    var len = std.mem.len(text);
    if(len > 1){
        //arena.allocator().destroy(ass);
        ass = assembler.init(text[0..len:0], &arena);
        _ = ass.assemble_program() catch return;

        breakpoints = ass.get_breakpoints().items;
        if (breakpoints.len > 0 ){
            c.editorSetBreakpoints(breakpoints.ptr,@intCast(c_int,breakpoints.len));
        }

        maquina.load_memory(ass.build());
    }
}

fn save_asm()void{

    const path = nfd.saveFileDialog("*",null) catch |err| switch(err){
    error.NfdError => {logger.err("error encontrado abriendo el file browser: {any}\n", .{err} );return;},
    };

    //null check
    if (path) |p| {
        save_to_file(c.getAssemblyEditorText()[0..std.mem.len(c.getAssemblyEditorText())], p);
        defer nfd.freePath(p);
    }
}

fn read_asm()void {
    const path = nfd.openFileDialog("*",null) catch |err| switch(err){
    error.NfdError => {logger.err("error encontrado abriendo el file browser: {any}\n", .{err} );return;},
    };
    if (path) |p|{
        var text = std.fs.cwd().readFileAlloc(alloc,p,2*1024*1024) catch |err| switch(err){
            else => {logger.err("error leyendo el archivo {s} -  {}",.{p,err});return;}
        };
        //puede que no haya que liberarlo al momento?
        defer alloc.free(text);
        
        var text_sentinel = std.mem.concatWithSentinel(alloc,u8,&[_][]u8{text},0) catch unreachable;
        defer alloc.free(text_sentinel);

        c.editorSetText(text_sentinel);

    }
}

fn save_to_file(data: []const u8, path: []const u8)void{
    var outfile = std.fs.cwd().createFile(path, .{ .read = true }) catch |err| switch(err){
            else => {logger.err("error creando el archivo {s} - {any}\n",.{path,err});return;},
        };

    defer outfile.close();
    _ = outfile.write(data) catch |err| switch(err){
            else => {logger.err("error escribiendo al archivo {s} - {any}\n", .{path,err});return;}
        };

}
fn export_ms()void{
    const path = nfd.saveFileDialog("*",null) catch |err| switch(err){
    error.NfdError => {logger.err("error encontrado abriendo el file browser: {any}\n", .{err} );return;},
    };

    //null check
    if (path) |p| {
        var local_arena = std.heap.ArenaAllocator.init(alloc);
        defer local_arena.deinit();
        defer nfd.freePath(p);
        var data = ms_program(&local_arena) catch |err| switch(err){
            else =>{logger.err("Error al intentar exportar a .ms - {any}\n", .{err});return;}
        };
        save_to_file(data, p);
    }
}

fn ms_program(local_arena : *std.heap.ArenaAllocator)![]u8{
    
    var asss = assembler.init(c.getAssemblyEditorText()[0..std.mem.len(c.getAssemblyEditorText()):0],local_arena);

    var instructions = try asss.assemble_program();
    //instructions are not sorted

    
    var ram :[256]u8 =[_]u8{0}**256;
    std.mem.copy(u8,&ram,std.mem.sliceAsBytes(asss.build()));
    
    
    var tag_data_map:[128]u8 = [_]u8{0}**128;

    var num_tags_and_data : u32 = 0;

    for(instructions.items) |ins| {

        if(ins.is_data){
            tag_data_map[ins.index]= 2;
        }else{
            tag_data_map[ins.index] = 1;
        }

        if(ins.name) |name| {
            _=name;
            num_tags_and_data+=1;
        }
    }

    var tag_position_index :u8 = 0;
    var tag_names = try local_arena.allocator().alloc(u8,num_tags_and_data*7);
    

    for(tag_names)|*byte|{
        byte.*=0;
    }


    var tag_positions = try local_arena.allocator().alloc(u16,num_tags_and_data);


    //index but only for tags
    var tag_index:u8 = 0;

    for(instructions.items)|ins|{
        if(!ins.is_data and ins.name==null)
            continue;
        
        var name = ins.name orelse {logger.err("No se puede exportar un dato sin nombre en la línea {}\n",.{ins.index});return error.NotSupported;};

        tag_positions[tag_position_index] = ins.index;
        tag_position_index+=1;

        std.mem.copy(u8, tag_names[tag_index*7..tag_names.len],name[0..std.math.min(6,name.len)]);
        tag_index+=1;
    }

    var mem_out = std.mem.concat(local_arena.allocator(),u8,&[_][]u8{
        std.mem.asBytes(&num_tags_and_data) ,
        &ram,
        &tag_data_map,
        tag_names,
        std.mem.sliceAsBytes(tag_positions)
        });

    return mem_out;
}

fn advance_instruction()void{
    maquina.update() catch unreachable;
    while(maquina.control_unit.state != UC_STATES.DECODE_OPERATION){
        maquina.update() catch unreachable;
    }
}

fn run_until_breakpoint()void{
    while(!std.mem.containsAtLeast(c_int,breakpoints,1,&[_]c_int{maquina.program_counter.stored_pc.*})){
        maquina.update() catch unreachable;
    }
}

fn reset_machine()void{
    alloc.destroy(maquina);
    maquina=MS.init(&alloc);
}

fn shortcuts()void{
    if (c.igShortcut(c.ImGuiMod_Ctrl | c.ImGuiKey_T, 0 , 0)){
        ensamblar();
    }if (c.igShortcut(c.ImGuiMod_Ctrl | c.ImGuiKey_O, 0 , 0)){
        read_asm();
    }if (c.igShortcut(c.ImGuiMod_Ctrl | c.ImGuiKey_S, 0 , 0)){
        save_asm();
    }if (c.igShortcut(c.ImGuiMod_Ctrl | c.ImGuiKey_U, 0 , 0)){
        maquina.update() catch unreachable;
    }if (c.igShortcut(c.ImGuiMod_Ctrl | c.ImGuiKey_Enter, 0 , 0)){
        advance_instruction();
    }if (c.igShortcut(c.ImGuiMod_Ctrl | c.ImGuiKey_B, 0 , 0)){
        run_until_breakpoint();
    }if (c.igShortcut(c.ImGuiMod_Ctrl | c.ImGuiKey_R, 0 , 0)){
        reset_machine();
    }
}

fn create_diagram()void{
    var text =c.getAssemblyEditorText();
    var len = std.mem.len(text);
    if(len > 1){
        var diagram_arena = std.heap.ArenaAllocator.init(alloc);

        const path = nfd.saveFileDialog("*",null) catch |err| switch(err){
            error.NfdError => {logger.err("error encontrado abriendo el file browser: {any}\n", .{err} );return;},
            };

        //null check
        if (path) |p| {
            diagrams.createDiagramFile(&diagram_arena,text[0..len:0],p) catch |err| switch(err){
                else => {logger.err("error creando diagrama: {any}",.{err});},
            };
            defer nfd.freePath(p);
        }
    }
}
fn editor_window()void{

        //shorcuts here are only informative, they must be added in shortcuts()
    if (c.igBeginMenuBar())
    {
        if (c.igBeginMenu("Open",true))
        { 
            if (c.igMenuItem_Bool("Open file","Ctrl+O",false,true))
                read_asm();
            c.igSeparator();

            if (c.igMenuItem_Bool("Save file (text)", "Ctrl+S", false,true)){
                save_asm();
            }
            if (c.igMenuItem_Bool("Export to MSDOS version", "", false,true)){
                export_ms();
            }
            c.igSeparator();
            
            if(c.igMenuItem_Bool("Generate diagram","",false,true)){
                    create_diagram();
                }
            c.igEndMenu();
            }
    
        

        if(c.igBeginMenu("Assembler",true)){
            if (c.igMenuItem_Bool("Assemble","Ctrl+T",false,true))
                ensamblar();
            if(c.igMenuItem_Bool("Advance one clock cycle","Ctrl+U",false,true))
                maquina.update() catch unreachable;
            
            if(c.igMenuItem_Bool("Advance one instruction","Ctrl+Enter",false,true)){
                advance_instruction();
            }
            if(c.igMenuItem_Bool("Run until breakpoint","Ctrl+B",false,true)){
                run_until_breakpoint();
            }
            if(c.igMenuItem_Bool("Reset Machine","Ctrl+R",false,true)){
                reset_machine();
            }
            c.igEndMenu();
        }
        c.igEndMenuBar();
    }
}


export fn update() void {

    const width = c.sapp_width();
    const height = c.sapp_height();
    const dt = c.stm_sec(c.stm_laptime(&last_time));
    const dpi_scale =c.sapp_dpi_scale();
    c.simgui_new_frame(&c.simgui_frame_desc_t{
        .width = width,
        .height = height,
        .delta_time = dt,
        .dpi_scale = dpi_scale,
    });
    _=c.igBegin("Ensamblador",0,c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_MenuBar);
    c.igSetWindowSize_Vec2(c.ImVec2{.x=550,.y= 800}, c.ImGuiCond_FirstUseEver);
    editor_window();
    inspector_labels();
    inspector_maquina();
    c.drawAssemblyEditor();
    shortcuts();
    c.igEnd();

    c.draw_hex_editor(&maquina.system_memory.memory,maquina.system_memory.memory.len);

    //render stuff
    c.sg_begin_default_pass(&state.pass_action, width, height);
    c.simgui_render();
    c.sg_end_pass();
    c.sg_commit();
}

export fn cleanup() void {
    c.simgui_shutdown();
    c.sg_shutdown();

}

export fn event(e: [*c]const c.sapp_event) void {
    _ = c.simgui_handle_event(e);
}

pub fn main() void {
    var app_desc = std.mem.zeroes(c.sapp_desc);
    app_desc.enable_clipboard=true;
    app_desc.clipboard_size = 100_000_000;
    app_desc.width = 1280;
    app_desc.height = 720;
    app_desc.init_cb = init;
    app_desc.frame_cb = update;
    app_desc.cleanup_cb = cleanup;
    app_desc.event_cb = event;
    app_desc.enable_clipboard = true;
    app_desc.window_title = "Maquina Sencilla";
    app_desc.high_dpi=true;
    _ = c.sapp_run(&app_desc);
}
