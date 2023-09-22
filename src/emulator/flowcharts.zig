const is_native = @import("../main.zig").is_native;

const template = if (is_native) @embedFile("./flowchart-template-native.html") else @embedFile("./flowchart-template-web.html");
const std = @import("std"); 
const assembler = @import("./assembler.zig");
const decode_instruction = @import("./components.zig").decode_instruction;
const MS_OPCODE = @import("./components.zig").MS_OPCODE;
const logger = std.log.scoped(.flowcharts);


fn getCMPText(alloc:std.mem.Allocator,ins : assembler.instruction)![]const u8{
    var words = std.mem.tokenize(u8,ins.original_text," ");
    std.debug.assert(std.mem.eql(u8,words.next().?,"CMP") or std.mem.eql(u8,words.next().?,"CMP") or std.mem.eql(u8,words.next().?,"CMP"));

    return  try std.fmt.allocPrint(alloc,"{s} = {s}", .{words.next().?,words.next().?});
}


pub fn buildFlowchart(arena : *std.heap.ArenaAllocator ,assembly : assembler.assembler_result)![]const u8{

    var alloc = arena.allocator();
    var result = std.ArrayList(u8).init(alloc);
    var i : u7 = 0;
    var instructions :[]assembler.instruction = assembly.instructions.items; 

    while(i < instructions.len) : (i+=1){

        if(instructions[i].is_data){
            logger.info("datos encontrados en medio del programa: {s}", .{instructions[i].original_text});
            continue;
        }
        if(instructions[i].is_breakpoint){
            logger.info("breakpoint encontrado: {s}", .{instructions[i].original_text});
            try result.appendSlice(try std.fmt.allocPrint(alloc,"{}[{s}] --> -1[FIN]\n",.{i,instructions[i].original_text}));
            continue;
        }
        
        var ins_data = decode_instruction(instructions[i].data);
        var text :[]const u8 = undefined;
        switch (ins_data.op) {
            .ADD,.MOV => {
                var next_data = decode_instruction(instructions[i+1].data);

                switch(next_data.op){
                    .CMP =>{
                        if(next_data.dir1 == next_data.dir2){
                            //next is unconditional jump
                            text = try std.fmt.allocPrint(alloc,"{}[{s}]",.{i,instructions[i].original_text});
                        }else{
                            //conditional jump
                            text = try std.fmt.allocPrint(alloc,"{}[{s}]-->{}\n",.{i,instructions[i].original_text,i+1});
                        }
                    },
                    .BEQ => {
                        logger.info("Se ha encontrado un BEQ sin un CMP antes en la línea {}, asumiendo que es un salto incondicional",.{instructions[i].original_line});
                        text = try std.fmt.allocPrint(alloc,"{}[{s}] --> {}\n",.{i,instructions[i].original_text,next_data.dir2});
                        if(!instructions[i+1].is_breakpoint) i+=1;//we skip the beq as we have already processed it
                    },
                    else => {
                        text = try std.fmt.allocPrint(alloc,"{}[{s}] --> {}\n",.{i,instructions[i].original_text,i+1});
                    }
                }
            },

            .CMP => {
                var last_instruction_index = i-1;
                var lbl_name = if(instructions[i].name) |n| try std.mem.concat(alloc,u8,&[_][]const u8{n," : "}) else "";

                if (i+1 > instructions.len){
                    logger.err("Se ha encontrado un CMP sin ninguna instrucción despues en la linea {}",.{instructions[i].original_line});
                    return error.BadlyFormed;
                }

                var jump_data = decode_instruction(instructions[i+1].data);
                if(jump_data.op != .BEQ) {
                    logger.err("Se ha encontrado una instrucción distinta de beq después de un cmp en la línea {}, esto no está soportado", .{instructions[i+1].original_line});
                    return error.BadlyFormed;
                }
                
                if(ins_data.dir1 == ins_data.dir2){
                    //always jump
                    // last_instruction --> jump_destination
                    text = try std.fmt.allocPrint(alloc,"--> {}\n",.{jump_data.dir2});
                    i+=1; //skip the beq
                }else{
                    var cmp_info = try getCMPText(alloc, instructions[i]);
                    var no_index = blk : {
                        var next_data = decode_instruction(instructions[i+2].data);
                        if(next_data.op  == .CMP and next_data.dir1 == next_data.dir2){
                            //unconditional jump after conditional jump
                            i+=3; //skip all this instructions
                            var next_jump_data = decode_instruction(instructions[i].data);
                            break :blk next_jump_data.dir2;
                        }
                        i+=1;
                        break :blk i+1; // else continue normally
                    };

                    text = try std.fmt.allocPrint(alloc, "{}{{{s}{s}}} -->|Sí|{}\n{} -->|No| {}\n",
                        .{last_instruction_index+1,lbl_name,cmp_info,jump_data.dir2,
                        last_instruction_index+1,no_index});
                }
            },
            .BEQ => unreachable,
        }
        logger.debug("Texto insertado: {s}", .{text});
        try result.appendSlice(text);
    }

    return std.fmt.allocPrint(alloc,template,.{result.items}); // we dont need to worry about deallocation because of the arena
}



test "test diagrama"{
    const program =
    \\MOV zero i
    \\MOV zero j
    \\MOV zero res

    \\find_min : CMP i num1
    \\BEQ min_n1
    \\CMP i num2
    \\BEQ min_n2
    \\ADD one i
    \\CMP zero zero
    \\BEQ find_min

    \\min_n1 : MOV num1 min
    \\MOV num2 max
    \\CMP zero zero
    \\BEQ distance

    \\min_n2 : MOV num2 min
    \\MOV num1 max

    \\distance : ADD one i
    \\ADD one j
    \\CMP i max
    \\BEQ found
    \\CMP zero zero
    \\BEQ distance
    \\found : MOV j res

    \\num2 : 0x0000
    \\num1 : 0x0000
    \\i : 0x0000
    \\j : 0x0000
    \\zero : 0x0000
    \\one : 0x0001
    \\min : 0x0000
    \\max : 0x0000
    \\res : 0x0000
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var assembler_results = try assembler.assemble_program(program,std.testing.allocator);
    defer assembler_results.deinit();

    _ = try buildFlowchart(&arena,assembler_results);   
}

