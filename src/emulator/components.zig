const std = @import("std");
const expect = @import("std").testing.expect;
const assert = std.debug.assert;
const logger = std.log.scoped(.emulator);


// pointers inside structs are used to represent cables connected to the component that struct represents
// const pointers are inputs, non-const pointers are outputs
// this has the advantage that we can "connect" the pointers to their respective input and output structs
// and then just call update each clock cycle

pub const ALU_OPCODE = enum(u2){
    SUM    = 0b00,
    XOR    = 0b01,
    ASSIGN = 0b10,
    NOOP   = 0b11, //not used
};
pub const MS_OPCODE = enum(u2){
    ADD=0b00,
    CMP=0b01,
    MOV=0b10,
    BEQ=0b11,
};

pub const MUX_CHOICES= enum(u2) {
    CHOOSE_PC      = 0b00,
    INVALID_CHOICE = 0b01,
    CHOOSE_DIR1    = 0b10, // f in the diagram
    CHOOSE_DIR2    = 0b11,
};


pub const RAM = struct {
    //inputs
    w_r: *const bool,
    data: *const u16,
    dir: *const u7,

    //outputs
    out_data: *u16,

    memory: [128]u16,
    

    fn read(self: *RAM) void {
        self.out_data.* = self.memory[self.dir.*];
    }
    fn write(self: *RAM) void {
        self.memory[self.dir.*] = self.data.*;
    }

    pub fn update(self: *RAM) void {
        if (self.w_r.*) {
            self.write();
        }
        else{
            self.read();
        }
    }
};

test "test RAM" {
    var out_data: u16 = 0;
    var dir: u7       = 100;
    var w_r           = true;
    var data: u16     = 0xCAFE;

    var mem = RAM{
        .memory = [_]u16{0} ** 128,

        .w_r      = &w_r,
        .data     = &data,
        .dir      = &dir,

        .out_data = &out_data,
    };
    //should write data to dir
    mem.update();

    //should read dir into out_data
    w_r = false;
    mem.update();

    try expect(out_data == 0xCAFE);
}



pub const ALU = struct{

    enableA:*const bool,
    enableB:*const bool,
    input_data:*const u16,
    operation:*const ALU_OPCODE,//alu1 and alu2 in the diagram

    opA:u16=0,
    opB:u16=0,
    flag_zero:*bool,
    out_data:*u16,


    pub fn update(self:*ALU)void{
        // enableA,enableB and the switch are mutually exclusive
        // but we dont want to return so we can check if they ever get the wrong values

        if (self.enableA.*){
            assert(!self.enableB.*);
            self.opA = self.input_data.*;
        }
        if (self.enableB.*){
            assert(!self.enableA.*);
            self.opB = self.input_data.*;
        }  

        switch(self.operation.*){
            //used for CMP
            ALU_OPCODE.XOR    => {self.flag_zero.* = self.opA==self.opB;},

            //used for MOV
            ALU_OPCODE.ASSIGN => {self.out_data.*=self.opB;},

            //used for ADD
            ALU_OPCODE.SUM    => {self.out_data.* = self.opA+%self.opB;},

            //used when no operation is being done
            ALU_OPCODE.NOOP   => {},
        }
    }
};

//we should really make functions to set all this values more easily
test "Test ALU"{

    //inputs
    var enableA : bool = false;
    var enableB : bool = true;
    var input_data : u16 = 77;
    var operation : ALU_OPCODE = ALU_OPCODE.NOOP;

    //outputs
    var flag_zero: bool = false;
    var out_data:u16=0;

    var unit = ALU{
        .enableA=&enableA,
        .enableB=&enableB,
        .input_data=&input_data,
        .operation=&operation,
        .flag_zero=&flag_zero,
        .out_data=&out_data,
    };
    // should read 77 into operand B
    unit.update();


    enableB = false;
    enableA = true;
    input_data = 33;
    // should read 33 into operand A
    unit.update();

    enableA = false;
    operation = ALU_OPCODE.SUM;
    //should sum a+b and put that into out_data
    unit.update();

    try expect(out_data == 110);

    operation = ALU_OPCODE.NOOP;
    enableB = true;
    input_data = 127;

    //should load 127 into B
    unit.update();

    enableB = false;
    operation = ALU_OPCODE.ASSIGN;
    //should put B into out_data
    unit.update();

    try expect(out_data==127);


    operation = ALU_OPCODE.NOOP;
    enableB = true;
    input_data = 10;
    unit.update();

    enableB = false;
    enableA = true;
    unit.update();
    

    enableA=false;// we have to deactivate all the inputs before doing operations
    operation = ALU_OPCODE.XOR;
    unit.update();

    try expect(flag_zero);


    enableB=true;
    input_data=15;
    operation=ALU_OPCODE.NOOP;
    unit.update();

    enableB=false;
    operation=ALU_OPCODE.XOR;
    unit.update();
    
    //numbers are different
    try expect(!flag_zero);
}


fn decode_instruction_internal(data:u16,op:*MS_OPCODE,dir1:*u7,dir2:*u7)void{
    op.* = @enumFromInt(data>>14);
    dir1.* = @intCast((data >> 7) & 0x7F);
    dir2.* = @intCast((data) & 0x7F);
}

pub fn decode_instruction(data:u16)struct {op : MS_OPCODE,dir1 : u7,dir2 :u7}{

    return .{
        .op = @enumFromInt(data>>14),
        .dir1 = @intCast((data >> 7) & 0x7F),
        .dir2 = @intCast((data) & 0x7F),
    };
}

pub const RI = struct{
    data:*const u16,
    enable_read:*const bool,

    op:*MS_OPCODE,

    dir1:*u7, //f in the diagram
    dir2:*u7, //d in the diagram

    pub fn update(self:*RI)void{
        if(self.enable_read.*){
            decode_instruction_internal(self.data.*,self.op,self.dir1,self.dir2);
            //logger.debug("IR - Decoded instruction - data = {X}, op = {}, dir1 = {}, dir2 = {}\n",.{self.data.*,self.op.*,self.dir1.*,self.dir2.*});
        }
        
    }
};

test "Test RI"{

    //op 2, dir1 = 120, dir2=100
    //todo: make this mess of bitwise operations and casts into a function
    var data:u16=@as(u16,@intFromEnum(MS_OPCODE.BEQ))<<14 | 120<<7 | 100;
    var enable_read:bool = true;

    var op:MS_OPCODE=undefined;
    var dir1:u7 = undefined;
    var dir2:u7 = undefined;

    var register = RI{
        .data=&data,
        .enable_read=&enable_read,
        .op=&op,
        .dir1=&dir1,
        .dir2=&dir2,
    };

    register.update();
    try expect(dir1==120 and dir2==100 and op==MS_OPCODE.BEQ);
}







pub const MUX = struct{
    choice:*const MUX_CHOICES,
    pc:*const u7,
    dir1:*const u7,
    dir2:*const u7,
    
    out_data:*u7,

    pub fn update(self:*MUX)!void{
        switch(self.choice.*){
            MUX_CHOICES.CHOOSE_PC      => {self.out_data.* = self.pc.*;},
            MUX_CHOICES.INVALID_CHOICE => {return error.invalidChoice;},
            MUX_CHOICES.CHOOSE_DIR1    => {self.out_data.* = self.dir1.*;},
            MUX_CHOICES.CHOOSE_DIR2    => {self.out_data.* = self.dir2.*;},
        }
    }
};
test "seleccion invalida en el MUX"{
    var choice:MUX_CHOICES = MUX_CHOICES.INVALID_CHOICE;
    var pc: u7 = 100;
    var dir1:u7 = 20;
    var dir2:u7 = 40;
    var out_data:u7 =0;

    var multiplex = MUX{
        .choice=&choice,
        .pc=&pc,
        .dir1=&dir1,
        .dir2=&dir2,
        .out_data=&out_data,
    };
    try std.testing.expectError(error.invalidChoice,multiplex.update());
}

test "MUX test"{
    var choice:MUX_CHOICES = MUX_CHOICES.CHOOSE_PC;
    var pc: u7 = 100;
    var dir1:u7 = 20;
    var dir2:u7 = 40;
    var out_data:u7 =0;


    var multiplex = MUX{
        .choice=&choice,
        .pc=&pc,
        .dir1=&dir1,
        .dir2=&dir2,
        .out_data=&out_data,

    };
    multiplex.update() catch unreachable; //will never error

    try expect(out_data==100);
}

//stores and increments pc (or whatever is used as memory direction)
pub const PC = struct{
    enable_assignment:*const bool,
    input_pc:*const u7,

    stored_pc:*u7,
    
    pub fn update(self:*PC)void{
        if(self.enable_assignment.*){
            //in the "real" hardware there is an adder that adds the output of the multiplexor + 1 each time enable allows it
            self.stored_pc.*=self.input_pc.*+%1;
        }
    }
};



pub const UC = struct{
    pub const UC_STATES = enum {
        LOAD_OPERATION,
        DECODE_OPERATION,
        READ_B,
        READ_A,
        MOV_OPERATION,
        ADD_OPERATION,
        CMP_OPERATION,
        BEQ_OPERATION,
    };
    state:UC_STATES=UC_STATES.LOAD_OPERATION,
    flag_jump : bool=false,//gets set when the last instruction made the program jump

    //inputs
    opcode :*const MS_OPCODE,
    flag_zero :*const bool,

    //outputs
    w_r :*bool, //false means read, true means write
    enable_add_pc:*bool,
    enable_RI:*bool,
    mux_selection :*MUX_CHOICES,
    enable_A:*bool,
    enable_B:*bool,
    alu_out : *ALU_OPCODE,

    fn load_operation(self:*UC)void{
        self.w_r.* = false;
        self.enable_add_pc.* = true;

        if(self.flag_jump){
            self.mux_selection.* = MUX_CHOICES.CHOOSE_DIR2;
            self.flag_jump = false;
        }else{

            self.mux_selection.* = MUX_CHOICES.CHOOSE_PC;
        }

        self.enable_RI.* = true;
        self.enable_A.* = false;
        self.enable_B.* = false;

        self.state = UC.UC_STATES.DECODE_OPERATION;
    }

        //we should have got a opcode to help us decide our next state
    fn decode_operation(self:*UC)void{

        self.w_r.* = false;
        self.enable_add_pc.* = false;
        self.enable_RI.* = false;
        self.enable_A.* = false;
        self.enable_B.* = false;
        
        switch(self.opcode.*){
            MS_OPCODE.ADD => {self.state = UC.UC_STATES.READ_B;},
            MS_OPCODE.CMP => {self.state = UC.UC_STATES.READ_B;},
            MS_OPCODE.MOV => {self.state = UC.UC_STATES.READ_B;},
            MS_OPCODE.BEQ => {self.state = UC.UC_STATES.BEQ_OPERATION;} // only the jump immediately finalizes
        }
    }

    fn read_b(self:*UC)void{
        self.w_r.* = false;
        self.enable_add_pc.*=false;
        self.mux_selection.*=MUX_CHOICES.CHOOSE_DIR1;
        self.enable_RI.*=false;
        self.enable_A.*=false;
        self.enable_B.*=true;

        switch(self.opcode.*){
            MS_OPCODE.ADD => {self.state = UC.UC_STATES.READ_A;},
            MS_OPCODE.CMP => {self.state = UC.UC_STATES.READ_A;},
            MS_OPCODE.MOV => {self.state = UC.UC_STATES.MOV_OPERATION;},
            MS_OPCODE.BEQ => {unreachable;},
        }
    }

    fn read_a(self:*UC)void{
        self.w_r.* = false;
        self.enable_add_pc.*=false;
        self.mux_selection.*=MUX_CHOICES.CHOOSE_DIR2;
        self.enable_RI.*=false;
        self.enable_A.*=true;
        self.enable_B.*=false;

        switch(self.opcode.*){
            MS_OPCODE.ADD => {self.state = UC.UC_STATES.ADD_OPERATION;},
            MS_OPCODE.CMP => {self.state = UC.UC_STATES.CMP_OPERATION;},
            MS_OPCODE.MOV => {unreachable;},
            MS_OPCODE.BEQ => {unreachable;},
        }
    }

    fn mov_operation(self:*UC)void{

        self.w_r.*=true;
        self.mux_selection.*=MUX_CHOICES.CHOOSE_DIR2;
        self.enable_RI.*=false;
        self.enable_A.*=false;
        self.enable_B.*=false;
        self.alu_out.*=ALU_OPCODE.ASSIGN;

        self.state=UC_STATES.LOAD_OPERATION;
    }

    fn add_operation(self:*UC)void{
        self.enable_A.*=false;

        self.w_r.*=true;
        self.mux_selection.*=MUX_CHOICES.CHOOSE_DIR2;
        self.alu_out.*=ALU_OPCODE.SUM;

        self.state=UC_STATES.LOAD_OPERATION;
    }
    
    fn cmp_operation(self:*UC)void{
        self.enable_A.*=false;

        self.w_r.*=false; //we write to flag_zero not to ram
        //technically, the ALU writes to flag_zero, not the UC, it is only an input in the UC
        self.alu_out.*=ALU_OPCODE.XOR;

        self.state= UC_STATES.LOAD_OPERATION;
    }

    
    fn beq_operation(self:*UC)void{
        self.enable_A.*=false;

        if(self.flag_zero.*){
            self.flag_jump = true;
        }

        self.state=UC_STATES.LOAD_OPERATION;
    }

    pub fn update(self:*UC)void{

        switch(self.state){
        UC.UC_STATES.LOAD_OPERATION   => {self.load_operation();},
        UC.UC_STATES.DECODE_OPERATION => {self.decode_operation();},
        UC.UC_STATES.READ_B           => {self.read_b();},
        UC.UC_STATES.READ_A           => {self.read_a();},
        UC.UC_STATES.MOV_OPERATION    => {self.mov_operation();},
        UC.UC_STATES.ADD_OPERATION    => {self.add_operation();},
        UC.UC_STATES.CMP_OPERATION    => {self.cmp_operation();},
        UC.UC_STATES.BEQ_OPERATION    => {self.beq_operation();},
        }
    }

};


pub const Maquina = struct{
    //mux inputs
    //pc in == pc_out
    cycle_counter:usize=0,
    mux_in_dir1:u7,
    mux_in_dir2:u7,
    mux_in_selection:MUX_CHOICES = MUX_CHOICES.CHOOSE_PC,


    //ram inputs
    ram_in_dir: u7,
    ram_in_w_r :bool,
    ram_in_data: u16,

    //we store only this output because it is the only output that splits into multiple inputs
    //maybe que should store all the outputs instead of all the inputs(?)
    //ram output
    ram_out: u16,

    //ALU inputs
    alu_in_enableA : bool,
    alu_in_enableB : bool,
    alu_in_operation : ALU_OPCODE = ALU_OPCODE.NOOP,
    //ALU input_data is ram_out

    //RI inputs
    //ri_data is ram_out 
    ri_enable_read:bool,

    //PC incrementer inputs
    pc_enable_assignment:bool,
    //PC input == mux output(ram_in_dir)
    pc_out:u7,
    //UC inputs
    uc_in_opcode : MS_OPCODE,
    uc_in_flag_zero : bool,


    system_memory : RAM,

    multiplex : MUX,

    arithmetic :ALU,

    program_counter :PC,

    instruction_register : RI,

    control_unit :UC,

    allocator : std.mem.Allocator,

    pub fn init(allocator : std.mem.Allocator)!*Maquina{
        var self:*Maquina = try allocator.create(Maquina);
        self.* = Maquina{
            .mux_in_dir1 = 0,
            .mux_in_dir2 = 0,
            .mux_in_selection = MUX_CHOICES.CHOOSE_PC,
            .ram_in_dir = 0,
            .ram_in_w_r= false,
            .ram_in_data= 0x0000,
            .ram_out = 0,
            .alu_in_enableA = false,
            .alu_in_enableB = false,
            .alu_in_operation= ALU_OPCODE.NOOP,
            .ri_enable_read = false,
            .pc_enable_assignment = false,
            .pc_out=0,
            .uc_in_opcode = MS_OPCODE.ADD,
            .uc_in_flag_zero  = false,
            .system_memory = undefined,
            .multiplex = undefined,
            .arithmetic = undefined,
            .program_counter = undefined,
            .instruction_register = undefined,
            .control_unit = undefined,
            .allocator=allocator,
        };

        var control_unit = UC{
            //inputs
            .opcode=&self.uc_in_opcode,
            .flag_zero=&self.uc_in_flag_zero,

            //outputs
            .w_r =&self.ram_in_w_r,
            .enable_add_pc=&self.pc_enable_assignment,
            .enable_RI=&self.ri_enable_read,
            .mux_selection=&self.mux_in_selection,
            .enable_A=&self.alu_in_enableA,
            .enable_B=&self.alu_in_enableB,
            .alu_out=&self.alu_in_operation,
        };

        var instruction_register = RI{
            .data=&self.ram_out,
            .enable_read=&self.ri_enable_read,

            .op=&self.uc_in_opcode,
            .dir1=&self.mux_in_dir1,
            .dir2=&self.mux_in_dir2,
        };

        var program_counter = PC{
            .enable_assignment=&self.pc_enable_assignment,
            .input_pc=&self.ram_in_dir,

            .stored_pc=&self.pc_out,
        };

        var arithmetic = ALU{
            .enableA=&self.alu_in_enableA,
            .enableB=&self.alu_in_enableB,
            .input_data=&self.ram_out,
            .operation=&self.alu_in_operation,

            .flag_zero=&self.uc_in_flag_zero,
            .out_data=&self.ram_in_data,
        };

        var multiplex = MUX{
            .choice=&self.mux_in_selection,
            .pc=&self.pc_out,
            .dir1=&self.mux_in_dir1,
            .dir2=&self.mux_in_dir2,

            .out_data=&self.ram_in_dir,
        };

        var system_memory = RAM{
            .memory = [_]u16{0} ** 128,
            .w_r      = &self.ram_in_w_r,
            .data     = &self.ram_in_data,
            .dir      = &self.ram_in_dir,

            .out_data = &self.ram_out,
        };

        self.control_unit= control_unit;
        self.instruction_register = instruction_register;
        self.program_counter = program_counter;
        self.arithmetic = arithmetic;
        self.multiplex = multiplex;
        self.system_memory =system_memory;


        return self;
    }

    pub fn load_memory(self:*Maquina, mem :[]const u16)void{
        if(mem.len > self.system_memory.memory.len){
            logger.warn("El programa es más grande que la memoria, no se cargará completo{s}",.{"\n"});
        }
        
        //write 0 to all memory
        for(&self.system_memory.memory) |*item|{
            item.*=0;
        }


        //safer than std.mem.copy
        for(mem,0..) |item,index| {
            self.system_memory.memory[index] = item;
        }
    }

    pub fn update(self:*Maquina)!void{
        self.cycle_counter+=1;
        self.control_unit.update();


        try self.multiplex.update();
        self.program_counter.update();

        //update for managing writes
        self.system_memory.update();
        
        self.instruction_register.update();
        self.arithmetic.update();

        //update for managing reads
        self.system_memory.update();
    }

    pub fn run(self:*Maquina,breakpoint:u7)!void{
        while(self.program_counter.stored_pc.* != breakpoint){
            try self.update();
        }
    }
    pub fn deinit(self: *Maquina)void{
        self.allocator.destroy(self);
    }
};


test "Test ejecutar instrucciones"{
    var alloc =std.testing.allocator;
    var maquina = try Maquina.init(alloc);
    
    //loading program

    //mov 1 2, moves 0xcaca to position 3
    maquina.load_memory(&[_]u16{0x8082,0xcaca,0x0000});
    try maquina.run(2);
    try expect(maquina.system_memory.memory[2]==0xcaca);

    maquina.program_counter.stored_pc.*=0;
    maquina.load_memory(&[_]u16{0x0082,0x0010,0x0020}); //add 1 2
    try maquina.run(2);
    try expect(maquina.system_memory.memory[2] == 0x0030);


    maquina.program_counter.stored_pc.*=0;
    maquina.load_memory(&[_]u16{0x4082,0x0010,0x0010}); //cmp (true)
    try maquina.run(2);
    try expect(maquina.control_unit.flag_zero.* == true);

    maquina.program_counter.stored_pc.*=0;
    maquina.load_memory(&[_]u16{0x4082,0x0010,0x0020}); //cmp (false)
    try maquina.run(2);
    try expect(maquina.control_unit.flag_zero.* == false);
    
    //cmp result result
    //beq end
    //mov zero result
    //:end beq end
    //:result 0xcafe
    //:zero 0x0000

    //result should remain unchanged
    maquina.program_counter.stored_pc.*=0;
    maquina.load_memory(&[_]u16{0x4204, 0xc003, 0x8284, 0xc003, 0xcafe, 0}); 
    try maquina.run(4);
    try expect(maquina.system_memory.memory[4]==0xcafe);

    maquina.deinit();
}