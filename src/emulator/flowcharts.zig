const std = @import("std");
const assembler = @import("./assembler.zig");
const decode_instruction =@import("./components.zig").decode_instruction;
const instruction = assembler.instruction;
const toUpper = assembler.toUpper;
const logger = std.log.scoped(.assembler);
const OPCODE =@import("./components.zig").MS_OPCODE;
const template = @import("./flowchart_template.html.zig").template;


const DiagramNode = struct{
    own:instruction,
    next:?*DiagramNode,
    //alternate only exists for jumps
    alternate:?u7=null,

};


const Diagram = struct{
    arena:std.heap.ArenaAllocator,
    head:*DiagramNode,
    tail:*DiagramNode,
    cursor:*DiagramNode,
    has_elements:bool=false,


    pub fn init(arena:std.heap.ArenaAllocator)Diagram{
        return .{
            .arena=arena,
            .head=undefined,
            .tail=undefined,
            .cursor=undefined,
        };
    }

    //add to tail
    pub fn push(self:*Diagram,own:instruction,alternate:?u7)void{
        var node = self.arena.allocator().create(DiagramNode) catch unreachable;
        node.own=own;
        node.alternate=alternate;
        node.next=null;

        if(!self.has_elements){
            //first push
            self.head = node;
            self.tail = self.head;
            self.cursor = self.head;
            self.has_elements=true;
        }else{
            self.cursor.next=node;
            self.cursor=self.cursor.next orelse unreachable;
        }
    }

    pub fn reset(self:*Diagram)void{
        self.cursor=self.head;
    }

    pub fn next(self:*Diagram)?*DiagramNode{
        self.cursor = self.cursor.next orelse return null;
        return self.cursor;
    }

    pub fn debugPrint(self:Diagram)void{
        //we create our own cursor because we dont want to modify the structure's internal state

        var cursor:*DiagramNode = self.head;
        var i:usize=0;
        while(true): (i+=1) {
            
            if (cursor.alternate == null){

                std.debug.print("Elemento {}:label({s}) {s}\n",
                .{i+1,cursor.own.name orelse "",cursor.own.original_text});
            }else{

                std.debug.print("Elemento {}:label({s}) {s}, alternativo: {}\n",
                .{i+1,cursor.own.name orelse "",cursor.own.original_text,cursor.alternate.?});
            }

            cursor=cursor.next orelse break;
        }

    }
};



fn cmpByIndex(context: void, a: instruction, b: instruction) bool {
    _ = context;
    return a.index<b.index;
}

fn getCMPText(alloc:std.mem.Allocator,ins : instruction)![]const u8{
    var words = std.mem.tokenize(u8,ins.original_text," ");


    std.debug.assert(std.mem.eql(u8,words.next().?,"CMP") or std.mem.eql(u8,words.next().?,"CMP"));

    return  try std.fmt.allocPrint(alloc,"{s} = {s}", .{words.next().?,words.next().?});
}



pub fn buildDiagram(alloc:std.mem.Allocator,instructions:[]instruction)!Diagram{
    var arena = std.heap.ArenaAllocator.init(alloc);

    var diagram = Diagram.init(arena);
    diagram.push(.{.index=std.math.maxInt(u7),.data=0,.original_text="sentinel node",.name=null,.is_data=false,.original_line=0},null);

    std.sort.sort(instruction,instructions,{},cmpByIndex);

    var i:usize=0;
    while(i<instructions.len) : (i+=1){
        //we dont care about data
        if (instructions[i].is_data)
            continue;
        
        var op1 : u7 = 0;
        var op2 : u7 = 0;
        var opcode:OPCODE =OPCODE.ADD;
        decode_instruction(instructions[i].data,&opcode,&op1,&op2);
        
        switch(opcode){
            .ADD,.MOV, =>
            {
                diagram.push(instructions[i],null);
            },
            .CMP =>
            {
                //adding cmp
                diagram.push(instructions[i],null);
                i+=1;
                //adding beq
                decode_instruction(instructions[i].data,&opcode,&op1,&op2);

                if(opcode != .BEQ){
                    logger.err("se ha encontrado una instrucción distina a un BEQ después de un CMP en la línea \"{s}\",esto no está soportado",
                           .{instructions[i].original_text});
                    return error.WrongProgramStructure;
                }
                diagram.push(instructions[i],op2);
            },

            .BEQ =>
            {
                logger.err("Se ha encontrado un BEQ sin un CMP antes en la línea \"{s}\", esto no está soportado",
                        .{instructions[i].original_text});
                return error.WrongProgramStructure;
            }
        }
    }
    return diagram;
}


pub fn diagramToMermaid(alloc:std.mem.Allocator, diagram :*Diagram)![]const u8{
    var arena = std.heap.ArenaAllocator.init(alloc);
    var mermaid = std.ArrayList([]const u8).init(arena.allocator());
    //list of strings

    diagram.reset();
    while(diagram.next())|node|{



        var op1 : u7 = 0;
        var op2 : u7 = 0;
        var opcode:OPCODE =OPCODE.ADD;
        decode_instruction(node.own.data,&opcode,&op1,&op2);

        switch(opcode){

            .ADD , .MOV =>
            {
                var next_index:isize=undefined;
                if(node.next != null){
                    next_index = node.next.?.own.index; 
                }
                else{
                    next_index = -1;
                }
                
                var text = try std.fmt.allocPrint(arena.allocator(),"{}[{s}] --> {}\n",
                .{node.own.index,node.own.original_text,next_index});
                try mermaid.append(text);
            },

            .CMP =>
            {
                const format = 
                \\{}{{ {s} }} -->|Sí|{}
                \\{} -->|No|{}
                \\
                ;
                const next = diagram.next() orelse {
                    logger.err("Se ha encontrado un CMP sin ninguna instrucción despues en la linea {s}",.{node.own.original_text});
                    return error.WrongProgramStructure;
                };

                var cmp_text = try getCMPText(arena.allocator(),node.own);
                var next_op1 : u7 = 0;
                var next_op2 : u7 = 0;
                var next_opcode:OPCODE =OPCODE.ADD;
                decode_instruction(next.own.data,&next_opcode,&next_op1,&next_op2);

               if(next_opcode != .BEQ){
                    logger.err("se ha encontrado una instrucción distina a un BEQ después de un CMP en la línea \"{s}\",esto no está soportado",
                           .{next.own.original_text});
                    return error.WrongProgramStructure;
                }

                var text = try std.fmt.allocPrint(arena.allocator(),format,
                .{node.own.index,cmp_text,next.alternate.?,
                        node.own.index,next.next.?.own.index});
                try mermaid.append(text);
            },

            .BEQ => {logger.err("Se ha encontrado un BEQ sin un CMP antes en la línea \"{s}\", esto no está soportado",.{node.own.original_text});},
        }
    }
    return std.mem.concat(arena.allocator(),u8,mermaid.items);

}

pub fn createDiagramFile(arena:*std.heap.ArenaAllocator,program:[:0]const u8,path:[]const u8)!void{


    var ass = assembler.assembler.init(program,arena);
    var instructions = try ass.assemble_program();


    var diagram = try buildDiagram(arena.allocator(),instructions.items);

    const mermaid =try diagramToMermaid(arena.allocator(),&diagram);

    
    var outfile = try std.fs.cwd().createFile(path, .{ .read = true });
    defer outfile.close();
    _ = try outfile.write(try std.fmt.allocPrint(arena.allocator(),template, .{mermaid}));


    
}

test "test crear linked list"{
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    
    try createDiagramFile(&arena, program,"./test_diagram.html");

    
}