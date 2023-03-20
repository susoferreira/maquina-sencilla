const assembler = @import("assembler.zig").assembler;
const std=@import("std");
const instruction = @import("assembler.zig").instruction;

pub const log_level: std.log.Level = .debug;



// 'static' variables used for easier exporting
var arena:std.heap.ArenaAllocator = undefined; //safety checked using bool has_init
var assembler_instance:assembler = undefined;
var instructions:std.ArrayList(instruction) = undefined;
var program_hex:[]u16 = undefined;
var has_init = false;


export fn testeo()*const [22:0]u8{
    return "Testeo completado jaja";
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    std.debug.print(" |LOG| ["++@tagName(message_level)++" | " ++ @tagName(scope) ++ "]:   " ++ format,args);

}

export fn init()void{
    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    has_init=true;
}

export fn deinit()void{
    arena.deinit();
    assembler_instance.deinit();
    has_init=false;

}

export fn assemble_text(program: *[:0]u8)void{
    assembler_instance = assembler.init(program.*,&arena);
    instructions = assembler_instance.assemble_program() catch {panic();return;};
    program_hex = assembler_instance.build();
}

const interop_instruction = extern struct{
    data:u16,
    name:?*const []const u8,
    name_len:usize,
    index:u8,
};

export fn get_instruction(index:u8)interop_instruction{
    for(instructions.items) |item|{
        if (item.index==index){
            return .{
                .data=item.data.?,
                .name=&item.name.?,
                .name_len=item.name.?.len,
                .index=item.index
            };
        }
    }
    //this means instruction does not exist
    return .{
            .data=0,
            .name=null,
            .name_len=0,
            .index=0,
        };
}
fn panic()void{
    instructions=undefined;
    has_init=false;
}