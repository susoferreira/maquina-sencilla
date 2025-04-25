const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const c = @import("c/c.zig");

const fs_wrapper = @import("./emulator/file_saver.zig");
const assembler = @import("./emulator/assembler.zig");
const instruction = @import("emulator/assembler.zig").instruction;
const MS = @import("emulator/components.zig").Maquina;
const logger = std.log.scoped(.ui);
const MS_OPCODE = @import("emulator/components.zig").MS_OPCODE;
const UC_STATES = @import("emulator/components.zig").UC.UC_STATES;
const ALU_OPCODE = @import("emulator/components.zig").ALU_OPCODE;
const flowcharts = @import("emulator/flowcharts.zig");
const jit = @import("emulator/jit.zig").x86_jit;

const ini_file = @embedFile("./imgui.ini");
const example = @embedFile("./example.txt");

pub const is_native = switch (builtin.os.tag) {
    .windows, .linux => true,
    .freestanding => false,
    else => {
        @compileError("platform not supported");
    },
};

pub const is_x64 = switch (builtin.cpu.arch) {
    .x86_64 => true,
    else => false,
};

const nfd = if (is_native) @import("nfd");

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const text = std.fmt.allocPrint(log_arena.allocator(), format, args) catch unreachable;

    logs.append(.{
        .message_level = message_level,
        .scope = @tagName(scope),
        .text = text,
    }) catch unreachable;

    if (is_native) {
        std.log.defaultLog(message_level, scope, format, args);
    }
}
pub const log_level: std.log.Level = .info;
pub const std_options = .{ .logFn = logFn };

const log = struct {
    message_level: std.log.Level,
    scope: []const u8, //we need to save it as text bc else it would be comptime
    text: []const u8,
};

const State = struct {
    pass_action: c.sg_pass_action,
    main_pipeline: c.sg_pipeline,
    main_bindings: c.sg_bindings,
};

const maquina_data = struct {
    pc: *u7,
    fz: *bool,
    RAM_OUT: *u16,
    Operand_A: *u7,
    Operand_B: *u7,
};

var state: State = undefined;
var last_time: u64 = 0;
var clear_color: [3]f32 = .{ 0.2, 0.2, 0.2 };

//TODO: meter todo esto en un struct o algo que está muy guarro

var gpa = if (is_native) std.heap.GeneralPurposeAllocator(.{}){};

var alloc = if (is_native) gpa.allocator() else std.heap.c_allocator;

var maquina: *MS = undefined;
var maquina_data_inspector: maquina_data = undefined;
var assembled: assembler.assembler_result = undefined; //we give it value on init
var log_arena: std.heap.ArenaAllocator = undefined;
var logs: std.ArrayList(log) = undefined;
var need_load_ini = true;
var should_show_jit = false;
var jit_compiler: jit = undefined;

pub fn inspector_for_u16(name: []const u8, memory: *u16) void {
    c.igTableNextRow(0, 0);

    //add sentinel because C
    const sentinel_name = std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{name[0..name.len]}, 0) catch unreachable;
    defer alloc.free(sentinel_name);

    //##name uses name as id
    const label = std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{ "##", sentinel_name }, 0) catch unreachable;
    defer alloc.free(label);
    _ = c.igTableNextColumn();
    c.igText(sentinel_name);
    _ = c.igTableNextColumn();
    _ = c.igInputScalar(label, c.ImGuiDataType_U16, memory, null, null, "%04X", 0);
}

pub fn inspector_for_u7(name: []const u8, memory: *u7) void {
    c.igTableNextRow(0, 0);
    //add sentinel because C
    const sentinel_name = std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{name[0..name.len]}, 0) catch unreachable;
    defer alloc.free(sentinel_name);

    //##name uses name as id
    const label = std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{ "##", sentinel_name }, 0) catch unreachable;
    defer alloc.free(label);
    _ = c.igTableNextColumn();
    c.igText(sentinel_name);
    _ = c.igTableNextColumn();
    _ = c.igInputScalar(label, c.ImGuiDataType_U8, memory, null, null, "%02X", 0);
}

//just displays a label
pub fn const_int_inspector(name: []const u8, value: usize) void {
    c.igTableNextRow(0, 0);

    const sentinel_name = std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{name[0..name.len]}, 0) catch unreachable;
    defer alloc.free(sentinel_name);

    var value_txt = std.fmt.allocPrint(alloc, "{} (0x{X})", .{ value, value }) catch unreachable;
    defer alloc.free(value_txt);
    const sentinel_value_txt = std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{value_txt[0..value_txt.len]}, 0) catch unreachable;
    defer alloc.free(sentinel_value_txt);

    _ = c.igTableNextColumn();
    c.igText(sentinel_name);

    _ = c.igTableNextColumn();
    _ = c.igText(sentinel_value_txt);
}

pub fn inspector_for_bool(name: []const u8, memory: *bool) void {
    c.igTableNextRow(0, 0);
    //add sentinel because C
    const sentinel_name = std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{name[0..name.len]}, 0) catch unreachable;
    defer alloc.free(sentinel_name);
    //##name uses name as id
    const label = std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{ "##", sentinel_name }, 0) catch unreachable;
    defer alloc.free(label);
    _ = c.igTableNextColumn();
    c.igText(sentinel_name);
    _ = c.igTableNextColumn();
    _ = c.igCheckbox(label, memory);
}

pub fn inspector_for_enum(
    name: []const u8,
    comptime T: type,
    memory: *T,
) void {
    if (@typeInfo(T) != .Enum) {
        @compileError("inspector_for_enum solo puede recibir T = enum y memory = *enum");
    }

    const sentinel_name = std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{name[0..name.len]}, 0) catch unreachable;
    defer alloc.free(sentinel_name);

    //##name uses name as id
    const label = std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{ "##", sentinel_name }, 0) catch unreachable;
    defer alloc.free(label);

    _ = c.igTableNextColumn();
    c.igText(sentinel_name);
    _ = c.igTableNextColumn();
    if (c.igBeginCombo(label, @tagName(memory.*), 0)) {
        inline for (@typeInfo(T).Enum.fields) |field| {
            const field_name = std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{field.name}, 0) catch unreachable;
            const selected = @intFromEnum(memory.*) == field.value;
            if (c.igSelectable_Bool(field_name, selected, 0, c.ImVec2{ .x = 200, .y = 0 })) {
                memory.* = @enumFromInt(field.value);
            }
            if (selected) {
                c.igSetItemDefaultFocus();
            }
        }
        c.igEndCombo();
    }
}

pub fn inspector_labels() void {
    _ = c.igBegin("Inspector del programa", 0, 0);
    c.igSetWindowSize_Vec2(.{ .x = 200, .y = 200 }, c.ImGuiCond_FirstUseEver);

    var table_size: c.struct_ImVec2 = undefined;
    c.igGetContentRegionAvail(&table_size);
    if (c.igBeginTable("labels_inspector", 2, c.ImGuiTableFlags_Resizable, table_size, 0)) //0 means no flags
    {
        c.igTableSetupColumn("Etiqueta", 0, 0, 0);
        c.igTableSetupColumn("Valor (hex)", 0, 0, 0);
        c.igTableHeadersRow();

        for (assembled.instructions.items) |label| {
            const name = label.name orelse continue;
            if (!label.is_data)
                continue;

            inspector_for_u16(name, &maquina.system_memory.memory[label.index]);
        }
        c.igEndTable();
    }
    c.igEnd();
}

pub fn inspector_labels_jit() void {
    var table_size: c.struct_ImVec2 = undefined;
    c.igGetContentRegionAvail(&table_size);
    if (c.igBeginTable("jit_results", 2, c.ImGuiTableFlags_NoHostExtendX, table_size, 0)) {
        c.igTableSetupColumn("Etiqueta", 0, 0, 0);
        c.igTableSetupColumn("Valor (hex)", 0, 0, 0);
        c.igTableHeadersRow();

        for (jit_compiler.program.instructions.items) |ins| {
            if (ins.name) |name| {
                if (ins.is_data) {
                    const_int_inspector(name, jit_compiler.get_data_value(ins.index));
                }
            }
        }
        c.igEndTable();
    }
}

pub fn struct_inspector(comptime T: type, instance: T) void {
    c.igSetWindowSize_Vec2(.{ .x = 200, .y = 200 }, c.ImGuiCond_FirstUseEver);

    var table_size: c.struct_ImVec2 = undefined;
    c.igGetContentRegionAvail(&table_size);

    if (c.igBeginTable("maquina_inspector", 2, c.ImGuiTableFlags_Resizable, table_size, 0)) //0 means no flags
    {
        // Submit columns name with TableSetupColumn() and call TableHeadersRow() to create a row with a header in each column.
        // (Later we will show how TableSetupColumn() has other uses, optional flags, sizing weight etc.)
        c.igTableSetupColumn("Variable", 0, 0, 0);
        c.igTableSetupColumn("Valor", 0, 0, 0);
        c.igTableHeadersRow();

        inline for (@typeInfo(T).Struct.fields) |field| {
            switch (@typeInfo(field.type)) {
                .Pointer => {
                    switch (field.type) {
                        *u16 => {
                            inspector_for_u16(field.name, @field(instance, field.name));
                        },
                        *u7 => {
                            inspector_for_u7(field.name, @field(instance, field.name));
                        },
                        *bool => {
                            inspector_for_bool(field.name, @field(instance, field.name));
                        },
                        else => {
                            switch (@typeInfo(@typeInfo(field.type).Pointer.child)) {
                                .Enum => {
                                    inspector_for_enum(
                                        field.name,
                                        @typeInfo(field.type).Pointer.child,
                                        @field(instance, field.name),
                                    );
                                },
                                else => {
                                    logger.debug("Tipo no soportado: {s} es de tipo {s}", .{ field.name, @typeName(field.type) });
                                },
                            }
                        },
                    }
                },

                .Int => {
                    const_int_inspector(field.name, @field(instance, field.name));
                },

                else => {
                    logger.debug("Tipo no soportado: {s} es de tipo {s}", .{ field.name, @typeName(field.type) });
                },
            }
        }
        c.igEndTable();
    }
}

pub fn inspector_maquina() void {
    _ = c.igBegin("Inspector de la maquina", 0, 0);
    const inspector_data = .{
        .Elapsed_Cycles = maquina.cycle_counter,
        .UC_Internal_State = &maquina.control_unit.state,
        .pc = maquina.program_counter.stored_pc,
        .fz = &maquina.uc_in_flag_zero,
        .RAM_OUT = maquina.system_memory.out_data,
        .RI_enable_read = &maquina.ri_enable_read,
        .Operand_A = maquina.instruction_register.dir1,
        .Operand_B = maquina.instruction_register.dir2,
        .RI_instruction_OPCODE = maquina.instruction_register.op,
        .ALU_Enable_A = &maquina.alu_in_enableA,
        .ALU_Enable_B = &maquina.alu_in_enableB,
        .UC_ALU_OPCODE = maquina.control_unit.alu_out,
    };
    struct_inspector(@TypeOf(inspector_data), inspector_data);
    c.igEnd();
}

export fn init() void {
    maquina = MS.init(alloc) catch {
        c.slog_func("emu", 0, 1, "error al crear la máquina", 338, "main.zig", null);
        return;
    };
    assembled = assembler.assemble_program("", alloc) catch |err| switch (err) {
        else => {
            logger.err("{any}", .{err});
            return;
        },
    };

    log_arena = std.heap.ArenaAllocator.init(alloc);
    logs = std.ArrayList(log).init(log_arena.allocator());

    var desc = std.mem.zeroes(c.sg_desc);
    desc.context = c.sapp_sgcontext();
    c.sg_setup(&desc);
    c.stm_setup();
    var imgui_desc = std.mem.zeroes(c.simgui_desc_t);
    c.simgui_setup(&imgui_desc);

    const IO = c.igGetIO();

    IO.*.ConfigFlags |= c.ImGuiConfigFlags_DockingEnable;
    IO.*.FontAllowUserScaling = true;

    state.pass_action.colors[0].load_action = c.SG_LOADACTION_CLEAR;
    state.pass_action.colors[0].clear_value = c.sg_color{ .r = clear_color[0], .g = clear_color[1], .b = clear_color[2], .a = 1.0 };
    //_ = c.ImFontAtlas_AddFontFromFileTTF(IO.*.Fonts,"SpaceMono-Bold.ttf",15,null,null);
    //_ = c.ImFontAtlas_Build(IO.*.Fonts);
    c.setupAssemblyEditor();
    c.editorSetText(example);
    c.init_hex_editor();
}

fn ensamblar() void {
    var text = c.getAssemblyEditorText();
    const len = std.mem.len(text);
    if (len > 1) {
        assembled.deinit();
        assembled = assembler.assemble_program(text[0..len], alloc) catch assembler.assemble_program("", alloc) catch unreachable; //if assembling fails, we set dummy values

        if (assembled.breakpoint_lines.items.len > 0) {
            c.editorSetBreakpoints(assembled.breakpoint_lines.items.ptr, @intCast(assembled.breakpoint_lines.items.len));
        }
        maquina.load_memory(&assembled.program);
    }
}

fn save_asm() void {
    fs_wrapper.save_file_as(alloc, "MS_ASM.txt", c.getAssemblyEditorText()[0..std.mem.len(c.getAssemblyEditorText())]);
}

fn read_asm() void {
    const path = nfd.openFileDialog("*", null) catch |err| switch (err) {
        error.NfdError => {
            logger.err("error encontrado abriendo el file browser: {any}\n", .{err});
            return;
        },
    };
    if (path) |p| {
        const text = std.fs.cwd().readFileAlloc(alloc, p, 2 * 1024 * 1024) catch |err| switch (err) {
            else => {
                logger.err("error leyendo el archivo {s} -  {}", .{ p, err });
                return;
            },
        };
        //puede que no haya que liberarlo al momento?
        defer alloc.free(text);

        const text_sentinel = std.mem.concatWithSentinel(alloc, u8, &[_][]u8{text}, 0) catch unreachable;
        defer alloc.free(text_sentinel);

        c.editorSetText(text_sentinel);
    }
}

fn export_ms() void {
    var local_arena = std.heap.ArenaAllocator.init(alloc);
    defer local_arena.deinit();

    const data = ms_program(&local_arena) catch |err| switch (err) {
        else => {
            logger.err("Error al intentar exportar a .ms - {any}\n", .{err});
            return;
        },
    };
    fs_wrapper.save_file_as(alloc, "PROG1.MS", data);
}

fn ms_program(local_arena: *std.heap.ArenaAllocator) ![]u8 {
    if (assembled.instructions.items.len < 1) ensamblar();

    const instructions = assembled.instructions.items;

    var ram: [256]u8 = [_]u8{0} ** 256;
    std.mem.copyForwards(u8, &ram, std.mem.sliceAsBytes(&assembled.program));

    var tag_data_map: [128]u8 = [_]u8{0} ** 128;

    var num_tags_and_data: u32 = 0;

    for (instructions) |ins| {
        logger.debug("inspeccionando instrucción: {any}", .{ins});
        if (ins.is_data) {
            tag_data_map[ins.index] = 2;
        } else {
            tag_data_map[ins.index] = 1;
        }

        if (ins.name) |name| {
            _ = name;
            num_tags_and_data += 1;
        }
    }

    var tag_position_index: u8 = 0;
    var tag_names = try local_arena.allocator().alloc(u8, num_tags_and_data * 7);

    for (tag_names) |*byte| {
        byte.* = 0;
    }

    var tag_positions = try local_arena.allocator().alloc(u16, num_tags_and_data);

    var tag_index: u8 = 0;

    for (instructions) |ins| {
        if (!ins.is_data and ins.name == null)
            continue;

        var name = ins.name orelse {
            logger.err("No se puede exportar un dato sin nombre en la línea {}\n", .{ins.index});
            return error.NotSupported;
        };

        tag_positions[tag_position_index] = ins.index;
        tag_position_index += 1;

        std.mem.copyForwards(u8, tag_names[tag_index * 7 .. tag_names.len], name[0..@min(6, name.len)]);
        tag_index += 1;
    }

    const mem_out = std.mem.concat(local_arena.allocator(), u8, &[_][]u8{ std.mem.asBytes(&num_tags_and_data), &ram, &tag_data_map, tag_names, std.mem.sliceAsBytes(tag_positions) });

    return mem_out;
}

fn advance_instruction() void {
    maquina.update() catch unreachable;
    while (maquina.control_unit.state != UC_STATES.DECODE_OPERATION) {
        maquina.update() catch unreachable;
    }
    showPC();
}

fn run_until_breakpoint() void {
    if (assembled.breakpoint_lines.items.len < 1) {
        logger.err("No hay breakpoint, has recordado ensamblar el programa{s}", .{"?"});
        return;
    }
    while (!assembled.instructions.items[maquina.program_counter.stored_pc.* -| 1].is_breakpoint and maquina.cycle_counter < 0x10000000) {
        maquina.update() catch unreachable;
    }
    showPC();
}

fn reset_machine() void {
    alloc.destroy(maquina);
    maquina = MS.init(alloc) catch {
        c.slog_func("emu", 0, 1, "error al crear la máquina", 335, "main.zig", null);
        return;
    };

    assembled.deinit();
    assembled = assembler.assemble_program("", alloc) catch unreachable;
    showPC();
}

fn shortcuts() void {
    if (c.igShortcut(c.ImGuiMod_Ctrl | c.ImGuiKey_T, 0, 0)) {
        ensamblar();
    }
    if (is_native and c.igShortcut(c.ImGuiMod_Ctrl | c.ImGuiKey_O, 0, 0)) {
        read_asm();
    }
    if (c.igShortcut(c.ImGuiMod_Ctrl | c.ImGuiKey_S, 0, 0)) {
        save_asm();
    }
    if (c.igShortcut(c.ImGuiMod_Ctrl | c.ImGuiKey_U, 0, 0)) {
        maquina.update() catch unreachable;
        showPC();
    }
    if (c.igShortcut(c.ImGuiMod_Ctrl | c.ImGuiKey_Enter, 0, 0)) {
        advance_instruction();
    }
    if (c.igShortcut(c.ImGuiMod_Ctrl | c.ImGuiKey_B, 0, 0)) {
        run_until_breakpoint();
    }
    if (c.igShortcut(c.ImGuiMod_Ctrl | c.ImGuiKey_R, 0, 0)) {
        reset_machine();
    }
    if (is_x64 and c.igShortcut(c.ImGuiMod_Ctrl | c.ImGuiKey_J, 0, 0)) {
        run_jit();
    }
}

fn create_flowchart() void {
    const text = c.getAssemblyEditorText();
    const len = std.mem.len(text);

    if (len > 1) {
        if (assembled.instructions.items.len < 1) ensamblar();

        var diagram_arena = std.heap.ArenaAllocator.init(alloc);

        const flowchart = flowcharts.buildFlowchart(&diagram_arena, assembled) catch return;

        if (is_native) {
            const path = nfd.saveFileDialog("*", null) catch |err| switch (err) {
                error.NfdError => {
                    logger.err("error encontrado abriendo el file browser: {any}\n", .{err});
                    return;
                },
            };

            if (path) |p| {
                ensamblar();
                fs_wrapper.native_file_write(flowchart, p);
                defer nfd.freePath(p);
            }
        } else {
            const flowchart_sentinel = std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{flowchart}, 0) catch return;
            defer alloc.free(flowchart_sentinel);
            c.create_flowchart_popup(flowchart_sentinel);
        }
    }
}

fn run_jit() void {
    ensamblar();
    jit_compiler = jit.init(alloc, assembled) catch return;
    jit_compiler.jit();
    jit_compiler.run() catch return;
    should_show_jit = true;
}

fn show_jit_results() void {
    if (should_show_jit) {
        c.igSetNextWindowPos(.{ .x = @as(f32, @floatFromInt(c.sapp_width())) / 2, .y = @as(f32, @floatFromInt(c.sapp_height())) / 2 }, c.ImGuiCond_Appearing, .{ .x = 1.0, .y = 0.0 });
        if (c.igBegin("Resultados JIT", &should_show_jit, c.ImGuiWindowFlags_AlwaysAutoResize)) {
            if (c.igSmallButton("guardar Binario")) {
                fs_wrapper.save_file_as(alloc, "JIT.bin", jit_compiler.ass.code);
            }
            inspector_labels_jit();
            c.igEnd();
        }
    }
}

fn editor_window() void {

    //shorcuts here are only informative, they must be added in shortcuts()
    if (c.igBeginMenuBar()) {
        if (c.igBeginMenu("Open", true)) {
            if (is_native and c.igMenuItem_Bool("Open file", "Ctrl+O", false, true))
                read_asm();
            c.igSeparator();

            if (c.igMenuItem_Bool("Save file (text)", "Ctrl+S", false, true)) {
                save_asm();
            }
            if (c.igMenuItem_Bool("Export to MSDOS version", "", false, true)) {
                export_ms();
            }
            c.igSeparator();

            if (c.igMenuItem_Bool("Generate diagram", "", false, true)) {
                create_flowchart();
            }
            c.igEndMenu();
        }

        if (c.igBeginMenu("Assembler", true)) {
            if (c.igMenuItem_Bool("Assemble", "Ctrl+T", false, true))
                ensamblar();
            if (c.igMenuItem_Bool("Advance one clock cycle", "Ctrl+U", false, true)) {
                maquina.update() catch unreachable;
                showPC();
            }
            if (c.igMenuItem_Bool("Advance one instruction", "Ctrl+Enter", false, true)) {
                advance_instruction();
            }
            if (c.igMenuItem_Bool("Run until breakpoint", "Ctrl+B", false, true)) {
                run_until_breakpoint();
            }
            if (c.igMenuItem_Bool("Reset Machine", "Ctrl+R", false, true)) {
                reset_machine();
            }
            c.igEndMenu();
        }
        if (is_x64) {
            if (c.igBeginMenu("JIT", true)) {
                if (c.igMenuItem_Bool("Run as JIT", "CTRL+J", false, true)) {
                    run_jit();
                }
                c.igEndMenu();
            }
            c.igEndMenuBar();
        }
    }
}

export fn update() void {
    const width = c.sapp_width();
    const height = c.sapp_height();
    const dt = c.stm_sec(c.stm_laptime(&last_time));
    const dpi_scale = c.sapp_dpi_scale();
    c.simgui_new_frame(&c.simgui_frame_desc_t{
        .width = width,
        .height = height,
        .delta_time = dt,
        .dpi_scale = dpi_scale,
    });
    _ = c.igBegin("Ensamblador", 0, c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_MenuBar);
    c.igSetWindowSize_Vec2(c.ImVec2{ .x = 550, .y = 800 }, c.ImGuiCond_FirstUseEver);
    editor_window();
    inspector_labels();
    inspector_maquina();
    c.drawAssemblyEditor();
    shortcuts();
    c.igEnd();

    c.draw_hex_editor(&maquina.system_memory.memory, maquina.system_memory.memory.len);

    draw_log_viewer();
    show_jit_results();

    if (need_load_ini) {
        need_load_ini = false;
        c.igLoadIniSettingsFromMemory(ini_file, ini_file.len);
    }

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
    app_desc.enable_clipboard = true;
    app_desc.clipboard_size = 100_000;
    app_desc.width = 1280;
    app_desc.height = 720;
    app_desc.init_cb = init;
    app_desc.frame_cb = update;
    app_desc.cleanup_cb = cleanup;
    app_desc.event_cb = event;
    app_desc.enable_clipboard = true;
    app_desc.window_title = "Maquina Sencilla";
    app_desc.high_dpi = true;
    app_desc.logger = .{ .func = c.slog_func, .user_data = null };
    _ = c.sapp_run(&app_desc);
}

pub fn draw_log_viewer() void {
    _ = c.igBegin("Log Viewer", 0, 0);
    c.igSetWindowSize_Vec2(c.ImVec2{ .x = 600, .y = 600 }, c.ImGuiCond_FirstUseEver);

    var window_size: c.struct_ImVec2 = undefined;
    c.igGetContentRegionMax(&window_size);

    if (c.igButton("Borrar Logs", .{ .x = window_size.x, .y = 50 })) {
        logs.deinit();
        log_arena.deinit();
        log_arena = std.heap.ArenaAllocator.init(alloc);
        logs = std.ArrayList(log).init(log_arena.allocator());
    }

    const log_slice: []log = logs.items; //autocompletado de mierda
    var table_size: c.struct_ImVec2 = undefined;
    c.igGetContentRegionAvail(&table_size);

    if (c.igBeginTable("log_viewer", 3, c.ImGuiTableFlags_Resizable | c.ImGuiTableFlags_BordersV, table_size, 0)) {
        c.igTableSetupColumn("Importancia", 0, 0, 0);
        c.igTableSetupColumn("Contexto", 0, 0, 0);
        c.igTableSetupColumn("Valor", 0, 0, 0);
        c.igTableHeadersRow();

        for (log_slice) |l| {
            const color = switch (l.message_level) {
                .err => c.struct_ImVec4{ .x = 1, .y = 0, .z = 0, .w = 1 },
                .warn => c.struct_ImVec4{ .x = 1, .y = 0.4, .z = 0, .w = 1 },
                .info => c.struct_ImVec4{ .x = 0.4, .y = 0.6, .z = 1, .w = 1 },
                .debug => c.struct_ImVec4{ .x = 0.82, .y = 0.82, .z = 0.82, .w = 1 },
            };

            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, color);

            c.igTableNextRow(0, 0);
            _ = c.igTableNextColumn();
            const level_text = std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{@tagName(l.message_level)}, 0) catch unreachable;
            defer alloc.free(level_text);
            c.igText(level_text);

            _ = c.igTableNextColumn();
            const scope_text = std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{l.scope}, 0) catch unreachable;
            defer alloc.free(scope_text);
            c.igText(scope_text);

            _ = c.igTableNextColumn();
            const msg_text = std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{l.text}, 0) catch unreachable;
            defer alloc.free(msg_text);
            c.igTextWrapped(msg_text);

            c.igPopStyleColor(1);
        }
        c.igEndTable();
    }

    c.igEnd();
}

fn showPC() void {
    if (maquina.pc_out -| 1 < assembled.instructions.items.len) {
        c.editorSetPC(@intCast(assembled.instructions.items[maquina.pc_out -| 1].original_line));
    } else {
        c.editorSetPC(-1);
    }
}
