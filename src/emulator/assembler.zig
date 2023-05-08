const std= @import("std");
const expect = std.testing.expect;

const logger = std.log.scoped(.assembler);

fn is_number(str: []const u8)bool{
    var nums="0123456789";
    if (str.len < 1) return false;

    for(nums) |num|{
        if (num==str[0]){
            return true;
        }
    }
    return false;
}

fn is_label(line:[]const u8)bool{
    if (line.len > 0 and line[0]==':'){
        return true;
    }
    return false;
}


//like iterator.next() but ignores empty strings
//sometimes returns null (like iterator)
pub fn next_token(it :*std.mem.SplitIterator(u8))?[]const u8{
    var token:[]const u8="";

    while (token.len==0){
        token = it.next() orelse return null;
    }
    return token;
}

fn assert_no_more_tokens(words :*std.mem.SplitIterator(u8))!void{
    if(next_token(words) != null)
        return error.TooManyWords;
}

//represents any type of instruction
pub const instruction = struct {
    index:u7,
    data:u16,
    //only labels have names
    name:?[]const u8,
    is_data:bool, //raw numbers are data
    original_text:[]const u8,
    original_line:usize,
};


//freeing is on the caller
pub fn toUpper(str: [:0]const u8,allocator : std.mem.Allocator)[]u8{
    var lowered : []u8 = allocator.alloc(u8,str.len) catch unreachable;
    for(str,0..)|char,index|{
        lowered[index] = std.ascii.toUpper(char);
    }
    return lowered;
}

test "test lowercase"{
    var testeacion = "JaJaJaaaAAAajasdoijAAAaAaaAAaaAaAaAaa";
    try expect(std.mem.eql(u8,toUpper(testeacion,std.heap.page_allocator),"JAJAJAAAAAAAJASDOIJAAAAAAAAAAAAAAAAAA"));
}

pub const assembler = struct{
    program : []const u8,
    arena : *std.heap.ArenaAllocator,
    instructions : std.ArrayList(instruction),
    labels : std.StringHashMap(instruction),

    
    //arena must be initialized 
    pub fn init(program : [:0]const u8, arena: *std.heap.ArenaAllocator)assembler{

        return .{
            .program = toUpper(program,arena.allocator()),
            .arena = arena,
            .labels = std.StringHashMap(instruction).init(arena.allocator()),
            .instructions = std.ArrayList(instruction).init(arena.allocator()),
        };
    }



    //matches an instruction to its value
    fn match_opcode(str:[]const u8)!u2{
        //they are aligned with MS_OPCODE values 
        var opcodes=[_][:0]const u8{"ADD","CMP","MOV","BEQ"};

        for(opcodes,0..) |opcode,index|{
            if(std.mem.eql(u8,str,opcode)){
                return @truncate(u2,index);
            }

    }
    return error.invalidOperation;
    }

    //gets direction from string
    fn match_direction(self:*assembler,str:[]const u8)!u7{

        if(is_number(str)){
            var num = try std.fmt.parseInt(u7,str,0);
            return num;
        }

        //resolve label
        var lbl = self.labels.get(str) orelse return error.LabelDoesNotExist;

        logger.debug("Resolved label {s} to direction {}\n",.{str,lbl.index});
        return lbl.index;
    }

    fn parse_normal_instruction(self:*assembler,word0: []const u8, word1:[]const u8, word2:[]const u8)!u16{
        const op = try match_opcode(word0);
        const dir1 = try self.match_direction(word1);
        const dir2 = try self.match_direction(word2);
        logger.debug("{s},{s},{s} = {},{},{} aka. {X}\n",.{
            word0,word1,word2,
            op,dir1,dir2,
            @as(u16,op)<<14 | @as(u16,dir1)<<7 | dir2});
        
        return @as(u16,op)<<14 | @as(u16,dir1)<<7 | dir2;
    }

    fn parse_jump_instruction(self:*assembler,word0: []const u8, word1:[]const u8)!u16{
        return self.parse_normal_instruction(word0,"0",word1);
    }



    // does not assemble labels on its own, you should call assemble_program 
    pub fn assemble_line(self:*assembler,line:[]const u8)! struct{is_data:bool,data:u16} {

        const trimmed = std.mem.trim(u8,line," \n\t");
        var words = std.mem.split(u8,trimmed," ");
        const first = words.first();

        if(is_number(first)){
            try assert_no_more_tokens(&words);
            return .{.is_data = true,.data = try std.fmt.parseInt(u16,first,0)};
        }

        if (std.mem.eql(u8,first,"BEQ")){
            var dir1 = next_token(&words) orelse return error.NotEnoughOperands;
            try assert_no_more_tokens(&words);
            return .{.is_data = false, .data = try self.parse_jump_instruction(first,dir1)};
        }

        var dir1 = next_token(&words) orelse return error.NotEnoughOperands;
        var dir2 = next_token(&words) orelse return error.NotEnoughOperands;
        try assert_no_more_tokens(&words);
        return .{.is_data = false, .data = try self.parse_normal_instruction(first,dir1,dir2)};

    }

    //iterates over all lines and assembles all the labels
    fn assemble_all_labels(self:*assembler,lines: *std.mem.SplitIterator(u8))!void{


        var indexes = std.AutoHashMap(usize,instruction).init(self.arena.allocator()); // array to find labels faster
        defer indexes.deinit();

        var line_number:usize = 1;
        var index:u7=0;
        lines.reset();
        while(lines.next())  |line| : (line_number+=1){

            if(std.mem.trim(u8,line," \n\t").len==0 or line[0]==';'){
                continue;
            }
            //an empty line does not count as an instruction,and does not increment the index, anything alse does
            defer index+=1;
            if(!is_label(line)){
                continue;
            }

            var trimmed = std.mem.trim(u8,line," ");
            var words = std.mem.split(u8,trimmed," ");
            var first =words.first();
            var label =instruction{
                    .data=undefined, //is defined in the next loop of this function
                    .name=line[1..first.len],
                    .index=index,
                    .is_data=undefined, //is defined in the next loop of this function
                    .original_text=line,
                    .original_line=line_number,
            };


            logger.debug("found label {s} on line {} {s}\n",.{label.name.?,line_number,line});
            //put without clobbering data
            var value = self.labels.getOrPut(label.name.?) catch unreachable;
            if(!value.found_existing){
                value.value_ptr.* = label;
                indexes.put(line_number,label) catch unreachable;
            }else{
                logger.err("Error en línea {}: Redefinición de la etiqueta {s}\n",.{line_number,label.name.?});
                return error.LabelRedefinition;
            }

        }


        //we dont put data in them as we go because forward references, we put it all at the end
        lines.reset();

        index=0;
        line_number=1;


        while(lines.next())|line| :(line_number+=1){
            logger.debug("[{}] - {s}\n",.{index,line});
            var label = indexes.get(line_number) orelse continue;

            logger.debug("trying to assemble label {s} on line {s}\n",.{label.name.?,line});
            var  result = self.assemble_line(line[label.name.?.len+1..line.len]) catch |err| switch(err){
                error.InvalidCharacter  =>{logger.err("Error en la línea {}: Carácter inválido",.{line_number}); return err;},
                error.Overflow          =>{logger.err("Error en la línea {}, Overflow",.{line_number}); return err;},
                error.NotEnoughOperands =>{logger.err("Error en la línea {}, faltan operandos",.{line_number}); return err;},
                error.TooManyWords      =>{logger.err("Error en la línea {}, demasiados operandos",.{line_number}); return err;},
                error.invalidOperation  =>{logger.err("Error en la línea {}, operación inválida",.{line_number}); return err;},
                error.LabelDoesNotExist =>{logger.err("Error en la línea {}, no existe la etiqueta referenciada",.{line_number});return err;},
            };
            //only update index when instruction is actually found
            index+=1;
            label.data = result.data;
            label.is_data = result.is_data;
            self.labels.put(label.name.?,label) catch unreachable; //we're clobbering existing labels with new ones
            self.instructions.append(label) catch unreachable;
        }
        
    }

    // reads program and creates list of instructions + labels, also resolves label references
    // returns list of instructions which needs to be ordered by indices using .build()
    pub fn assemble_program(self:*assembler)!std.ArrayList(instruction){
        
        var index:u7=0;
        var line_number:usize = 1;
        var lines = std.mem.split(u8,self.program,"\n");

        try self.assemble_all_labels(&lines);


        lines.reset();
        while(lines.next()) |line| : (line_number+=1){

            if(std.mem.trim(u8,line," \n\t").len==0 or line[0]==';')
                continue;
            
            defer index+=1;
            if(is_label(line))
                continue;
            logger.debug("ensambleando línea :{} con texto {s}", .{line_number,line});

            var result =  self.assemble_line(line) catch |err| switch(err){
                error.TooManyWords =>{logger.err("Error en línea {}: Demasiadas palabras en una línea\n",.{line_number}); return err;},
                error.InvalidCharacter =>{logger.err("Error en línea {}: Carácter inválido\n",.{line_number}); return err;},
                error.Overflow =>{logger.err("Error en línea {}: Overflow\n",.{line_number}); return err;},
                error.NotEnoughOperands =>{logger.err("Error en línea {}: Faltan operandos\n",.{line_number}); return err;},
                error.invalidOperation =>{logger.err("Error en línea {}: Operación inválida\n",.{line_number}); return err;},
                error.LabelDoesNotExist =>{logger.err("Error en línea {}: No existe la etiqueta referenciada\n",.{line_number}); return err;},

                //error.NotImplemented =>{logger.err("Error en línea {}: Característica no implementada",.{index}); return err;},
            };

            self.instructions.append(
                .{
                    .name=null,
                    .data=result.data,
                    .is_data=result.is_data,
                    .index=index,
                    .original_text=line,
                    .original_line=line_number,
                })
                catch |err| switch(err){
                    error.OutOfMemory => {logger.err("Error en la línea {}: No hay suficiente memoria\n",.{index});unreachable;},
                };
        }
        return self.instructions;
    }

    //builds program from assembled instructions + indices 
    pub fn build(self:*assembler)[]u16{
        var program = self.arena.allocator().alloc(u16,self.instructions.items.len) catch unreachable;
        // we assume only one instruction points to each index,
        // if this is not true something has gone very wrong
        
        for(self.instructions.items) |line|{
            logger.debug("Building instruction {} with data {X}\n",.{line.index,line.data});
            program[line.index]= line.data;

        }
        //TODO: DEALLOCATE THIS SHIT
        return program;
    }
    
    //gets all labels that start with some character from a list of labels
    pub fn get_breakpoints(self:*assembler)std.ArrayList(c_int){
    var breaks = std.ArrayList(c_int).init(self.arena.allocator());
    for (self.instructions.items)|ins|{
        var name = ins.name orelse continue;
        if(name[0] == '*'){ //TODO: extract constant
            breaks.append(@intCast(c_int,ins.original_line)) catch unreachable;
        }
    }
    return breaks;
}

};

test "test assembler"{
     const test_str =
     \\ MOV 0X10 0X20
     \\ ADD 0X30 0X40
     \\ CMP 0X50 0X60
     \\ BEQ 0X70
 ;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var ensamblacion :assembler = assembler.init(test_str,&arena);
    _= try ensamblacion.assemble_program();
    
    const expected = [_]u16{0x8820,0x1840,0x6860,0xc070};
    for(ensamblacion.build(),0..)|line,index|{
        try expect(line==expected[index]);
    }
    arena.deinit();
}

test "test labels"{
    const test_recognition =
    \\:cosa 0xcaca
    \\:cosa1 MOV 0 1
;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var ens = assembler.init(test_recognition,&arena);
    _=try ens.assemble_program();
    _=ens.build();

    //program gets capitalized
    //TODO:UPDATE THESE TESTS
    //try expect(ens.labels.get("COSA").?.data==0xcaca);
    //try expect(ens.labels.get("COSA1").?.data == ens.assemble_line("MOV 0 1") catch unreachable);

    arena.deinit();


    const test_resolving =
    \\:num1 0xcaca
    \\:num2 0xbebe
    \\:tmp 0
    \\MOV num1 tmp
    \\MOV num2 num1
    \\MOV tmp num2
    ;
    //last arena gets deinited with the assembler
    var arena2 = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var assemble = assembler.init(test_resolving,&arena2);
    _=try assemble.assemble_program();
    var program = assemble.build();
    _ = program;

    //TODO:UPDATE THESE TESTS
    //try expect(program[3] == try assemble.assemble_line("MOV 0 2").data);
    //try expect(program[4] == try assemble.assemble_line("MOV 1 0").data);
    //try expect(program[5] == try assemble.assemble_line("MOV 2 1").data);

}


test "distance betweeen two numbers"{
        const program =
    \\MOV zero i
    \\MOV zero j
    \\MOV zero res

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
    \\BEQ found
    \\CMP zero zero
    \\BEQ distance
    \\:found MOV j res

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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var assemble = assembler.init(program,&arena);
    _=try assemble.assemble_program();
    _= assemble.build();

    //we just test for no errors when assembling
}

test "test errors"{
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

        
        var assemble = assembler.init("MOV 1 2 3 4 5 6 7",&arena);
        try std.testing.expectError(error.TooManyWords,assemble.assemble_program());
        _= assemble.build();


       assemble = assembler.init("MOV 1",&arena);
       try std.testing.expectError(error.NotEnoughOperands,assemble.assemble_program());
       _= assemble.build();

       assemble = assembler.init("PITO 1 2",&arena);
       try std.testing.expectError(error.invalidOperation,assemble.assemble_program());
       _= assemble.build();

       assemble = assembler.init("MOV 0xFFFFF 0xcaca",&arena);
       try std.testing.expectError(error.Overflow,assemble.assemble_program());
       _= assemble.build();

       assemble = assembler.init("MOV 0 num1",&arena);
       try std.testing.expectError(error.LabelDoesNotExist,assemble.assemble_program());
       _= assemble.build();

}