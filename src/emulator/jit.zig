const builtin = @import("builtin");
const assembler = @import("assembler.zig");
const std = @import("std");
const logger = std.log.scoped(.jit);
const decode_instruction = @import("./components.zig").decode_instruction;
const ADDRESS_SIZE_OVERRIDE: u8 = 0x66;
const OPERAND_SIZE_OVERRIDE: u8 = 0x67;
const register = enum(u4) {
    AX,
    CX,
    DX,
    BX,
    SP,
    BP,
    SI,
    DI,
    R8,
    R9,
    R10,
    R11,
    R12,
    R13,
    R14,
    R15,
};
const usable_registers_x86 = []register{
    register.AX,
    register.CX,
    register.DX,
    register.BX,
    register.SI,
    register.DI,
};
const REX64 = 0x48;
const MODRM_reg_reg: u8 = 0xc0;
const MODRM_RSI_PLUS_DISP32: u8 = 0b10000110; //10 + ... + 100, the middle bits are for the register used

const x86_assembler = struct {
    code: []align(std.mem.page_size) u8,
    alloc: std.mem.Allocator,
    cursor: u16 = 0,

    pub fn init(alloc: std.mem.Allocator) !x86_assembler {
        const code: []align(std.mem.page_size) u8 = try alloc.alignedAlloc(u8, std.mem.page_size, std.mem.page_size);
        return .{ .code = code, .alloc = alloc };
    }

    fn deinit(self: *x86_assembler) void {
        self.alloc.free(self.code);
    }

    fn prologue(self: *x86_assembler) void {
        self.push_64(.AX);
        self.push_64(.CX);
        self.push_64(.BP);
        const point = @intFromPtr(self.code.ptr);
        self.mov_reg_imm64(.SI, point);
    }

    fn epilogue(self: *x86_assembler) void {
        self.pop_64(.BP);
        self.pop_64(.CX);
        self.pop_64(.AX);
        self.ret();
    }

    fn emit8(self: *x86_assembler, byte: u8) void {
        self.code[self.cursor] = byte;
        self.cursor += 1;
    }

    fn emit16(self: *x86_assembler, data: u16) void {
        self.emit8(@truncate(data));
        self.emit8(@truncate(data >> 8));
    }

    fn emit32(self: *x86_assembler, data: u32) void {
        self.emit8(@truncate(data));
        self.emit8(@truncate(data >> 8));
        self.emit8(@truncate(data >> 16));
        self.emit8(@truncate(data >> 24));
    }

    fn emit64(self: *x86_assembler, data: u64) void {
        self.emit8(@truncate(data));
        self.emit8(@truncate(data >> 8));
        self.emit8(@truncate(data >> 16));
        self.emit8(@truncate(data >> 24));
        self.emit8(@truncate(data >> 32));
        self.emit8(@truncate(data >> 40));
        self.emit8(@truncate(data >> 48));
        self.emit8(@truncate(data >> 56));
    }

    fn emit8_signed(self: *x86_assembler, byte: i8) void {
        self.code[self.cursor] = @bitCast(byte);
        self.cursor += 1;
    }

    // https://www.felixcloutier.com
    // https://software.intel.com/en-us/download/intel-64-and-ia-32-architectures-sdm-combined-volumes-1-2a-2b-2c-2d-3a-3b-3c-3d-and-4 pagina 594

    // B8+ rw iw 	MOV r16, imm16
    fn mov_reg_imm16(self: *x86_assembler, r1: register, immediate: u16) void {
        self.emit8(ADDRESS_SIZE_OVERRIDE);
        self.emit8(0xB8 | @as(u8, @intFromEnum(r1)));
        self.emit16(immediate);
    }

    //REX.W + B8+ rd io 	MOV r64, imm64
    fn mov_reg_imm64(self: *x86_assembler, r1: register, immediate: u64) void {
        self.emit8(REX64);
        self.emit8(0xB8 | @as(u8, @intFromEnum(r1)));
        self.emit64(immediate);
    }

    // 01 /r 	ADD r/m16, r16
    fn add_reg_reg(self: *x86_assembler, r1: register, r2: register) void {
        self.emit8(ADDRESS_SIZE_OVERRIDE);
        self.emit8(0x01);
        self.emit8(MODRM_reg_reg | @intFromEnum(r1) << 3 | @intFromEnum(r2)); // modR/M
    }

    // 8B /r 	MOV r16, r/m16
    fn mov_reg_reg(self: *x86_assembler, r1: register, r2: register) void {
        self.emit8(ADDRESS_SIZE_OVERRIDE);
        self.emit8(0x8b);
        self.emit8(MODRM_reg_reg | @intFromEnum(r1) << 3 | @intFromEnum(r2));
    }

    // 89 /r 	MOV r/m16, r16
    fn mov_si_plus_m32_reg(self: *x86_assembler, disp: u32, reg: register) void {
        self.emit8(ADDRESS_SIZE_OVERRIDE);
        self.emit8(0x89);
        self.emit8(MODRM_RSI_PLUS_DISP32 | @intFromEnum(reg) << 3);
        self.emit32(disp);
    }

    // 8B /r 	MOV r16, r/m16
    fn mov_reg_si_plus_m32(self: *x86_assembler, r1: register, disp: u32) void {
        self.emit8(ADDRESS_SIZE_OVERRIDE);
        self.emit8(0x8B);

        //MOD R/M
        self.emit8(MODRM_RSI_PLUS_DISP32 | @as(u8, @intFromEnum(r1) << 3));
        self.emit32(disp);
    }

    // 39 /r 	CMP r/m16, r16
    fn cmp_reg_reg(self: *x86_assembler, r1: register, r2: register) void {
        self.emit8(ADDRESS_SIZE_OVERRIDE);
        self.emit8(0x39);
        self.emit8(MODRM_reg_reg | @intFromEnum(r1) << 3 | @intFromEnum(r2));
    }

    //74 cb 	JE rel8 Jump short if equal (ZF=1).
    fn jump_equal_rel8(self: *x86_assembler, position: i8) void {
        self.emit8(0x74);
        self.emit8_signed(position);
    }

    //rel16 not supported on 64 bits

    //0F 84 cd 	JZ rel32 Jump near if 0 (ZF=1).
    fn jump_equal_rel32(self: *x86_assembler, position: i32) void {
        self.emit8(0x0F);
        self.emit8(0x84);
        self.emit32(@bitCast(position));
    }

    fn lea_for_adding(self: *x86_assembler, dst: register, op1: register, op2: i16) void {
        self.emit8(ADDRESS_SIZE_OVERRIDE);
        self.emit8(OPERAND_SIZE_OVERRIDE);
        self.emit8(0x8D);
        //MODRM for [r/m + disp32], using dst as \r (reg in MODRM) and op1 as r/m
        self.emit8(0b1000_0000 | @as(u8, @intFromEnum(dst)) << 3 | @as(u8, @intFromEnum(op1)));
        self.emit32(@bitCast(@as(i32, op2)));
    }

    // 50+rd 	PUSH r64 	O 	Valid 	N.E. 	Push r64.
    fn push_64(self: *x86_assembler, r: register) void {
        self.emit8(0x50 | @as(u8, @intFromEnum(r)));
    }

    fn pushf(self: *x86_assembler) void {
        self.emit8(0x9C);
    }

    fn popf(self: *x86_assembler) void {
        self.emit8(0x9D);
    }

    fn pop_64(self: *x86_assembler, r: register) void {
        self.emit8(0x58 | @as(u8, @intFromEnum(r)));
    }

    fn ret(self: *x86_assembler) void {
        self.emit8(0xC3);
    }

    fn run(self: *x86_assembler) !void {
        try x86_assembler.setRwx(self.code);
        @as(*const fn () void, @ptrCast(self.code))();
    }

    fn setRwx(slice: []align(std.mem.page_size) u8) !void {
        const value = std.os.linux.mprotect(slice.ptr, slice.len, std.os.linux.PROT.EXEC | std.os.linux.PROT.WRITE | std.os.linux.PROT.READ);
        if (value == -1) {
            logger.err("Error creando región de memoria ejecutable");
            return error.FailedMprotect;
        }
    }
};

test "assembler test" {
    var jit = try x86_assembler.init(std.testing.allocator);
    defer jit.deinit();

    jit.prologue();
    jit.mov_reg_imm16(.AX, 0xabcd);
    jit.mov_reg_imm16(.CX, 0xaabb);
    jit.add_reg_reg(.AX, .CX);
    jit.cmp_reg_reg(.BX, .SP);
    jit.mov_reg_si_plus_m32(.AX, 0);
    jit.mov_si_plus_m32_reg(0, .BX);
    jit.lea_for_adding(.AX, .BX, -0xab);
    jit.jump_equal_rel8(1);
    jit.jump_equal_rel32(2);

    jit.epilogue();

    var file = try std.fs.cwd().createFile("assembly_test", .{});
    _ = try file.write(jit.code[0..jit.cursor]);
    defer file.close();
    try jit.run();
}

pub const x86_jit = struct {
    ass: x86_assembler,
    program: assembler.assembler_result,

    symbols: [128]u16 = undefined, //maps each of the 128 ms's memory positions to the offset it has when jitted
    symbols_cursor: usize = 0,

    pub fn init(alloc: std.mem.Allocator, program: assembler.assembler_result) !x86_jit {
        return .{ .ass = try x86_assembler.init(alloc), .program = program };
    }

    pub fn deinit(self: *x86_jit) void {
        self.ass.deinit();
    }

    fn record_symbol_pos(self: *x86_jit) void {
        self.symbols[self.symbols_cursor] = self.ass.cursor;
        self.symbols_cursor += 1;
    }

    fn get_symbol_pos(self: *x86_jit, ms_index: u7) ?u16 {
        if (self.symbols_cursor > ms_index) {
            return self.symbols[ms_index];
        }
        return null;
    }

    pub fn jit(self: *x86_jit) void {
        for (0..2) |i| {
            self.ass.prologue();
            for (self.program.instructions.items) |ins| {
                const decoded = decode_instruction(ins.data);
                self.record_symbol_pos();

                if (ins.is_breakpoint and decoded.op == .BEQ) {
                    // we do not execute BEQ when it is a breakpoint bc it could easily cause infinite loops
                    // example: *end: BEQ end
                    logger.info("breakpoint sin ejecutar instruccion\n", .{});
                    self.ass.epilogue();
                }

                if (ins.is_data) {
                    self.compile_data(ins.data);
                } else {
                    switch (decoded.op) {
                        .ADD => {
                            self.compile_add(decoded.dir1, decoded.dir2);
                        },
                        .MOV => {
                            self.compile_mov(decoded.dir1, decoded.dir2);
                        },
                        .CMP => {
                            self.compile_cmp(decoded.dir1, decoded.dir2);
                        },
                        .BEQ => {
                            self.compile_beq(decoded.dir2);
                        },
                    }
                }

                if (ins.is_breakpoint and decoded.op != .BEQ) {
                    // when instruction is not a jump, we execute it and then return
                    logger.info("breakpoint ejecutando instruccion\n", .{});
                    self.ass.epilogue();
                }
            }
            self.ass.epilogue();
            if (i == 0) { // ahora que ya sabemos las posiciones de todo se vuelve a empezar
                self.ass.cursor = 0; // TODO: usar dos funciones en vez de este bucle guarro
            }
        }
    }

    fn compile_data(self: *x86_jit, data: u16) void {
        self.ass.emit16(data);
    }

    fn compile_add(self: *x86_jit, src: u7, dst: u7) void {
        const op1 = self.get_symbol_pos(src) orelse 0x4242;
        const op2 = self.get_symbol_pos(dst) orelse 0x4242;

        self.ass.mov_reg_si_plus_m32(.AX, op1);
        self.ass.mov_reg_si_plus_m32(.CX, op2);
        self.ass.pushf();
        self.ass.add_reg_reg(.AX, .CX);
        self.ass.popf();
        self.ass.mov_si_plus_m32_reg(op2, .CX);
    }

    fn compile_mov(self: *x86_jit, src: u7, dst: u7) void {
        const op1 = self.get_symbol_pos(src) orelse 0x4242;
        const op2 = self.get_symbol_pos(dst) orelse 0x4242;

        self.ass.mov_reg_si_plus_m32(.AX, op1);
        self.ass.mov_si_plus_m32_reg(op2, .AX);
    }

    fn compile_cmp(self: *x86_jit, src: u7, dst: u7) void {
        const op1 = self.get_symbol_pos(src) orelse 0x4242;
        const op2 = self.get_symbol_pos(dst) orelse 0x4242;

        self.ass.mov_reg_si_plus_m32(.AX, op1);
        self.ass.mov_reg_si_plus_m32(.CX, op2);
        self.ass.cmp_reg_reg(.AX, .CX);
        // we use the computer's zero flag as zero flag for the ms too,
        // this means we have to be careful to not accidentally change it,
        // for example doing an ADD
    }

    // A relative offset (rel16 or rel32) is generally specified as a label in assembly code. But at the machine code level, it
    // is encoded as a signed, 16- or 32-bit immediate value. This value is added to the value in the EIP(RIP) register. In
    // 64-bit mode the relative offset is always a 32-bit immediate value which is sign extended to 64-bits before it is
    // added to the value in the RIP register for the target calculation. As with absolute offsets, the operand-size attribute
    // determines the size of the target operand (16, 32, or 64 bits). In 64-bit mode the target operand will always be 64-
    // bits because the operand size is forced to 64-bits for near branches
    // intel manual page 732

    fn compile_beq(self: *x86_jit, dst: u7) void {
        const index = self.get_symbol_pos(dst) orelse 0x4242;

        const offset: i32 = @as(i32, index) - self.ass.cursor - 0x6; //instruction itself is 6 bytes
        self.ass.jump_equal_rel32(@intCast(offset));
    }

    pub fn run(self: *x86_jit) !void {
        try self.ass.run();
    }

    // given an index for a variable in MS returns its value in the current jitted code
    // only really makes sense for data, as instructions will be different (and have different lengths) than their MS counterparts
    pub fn get_data_value(self: *x86_jit, index: u7) u16 {
        const pos = self.get_symbol_pos(index) orelse unreachable;
        return (@as(u16, self.ass.code[pos + 1]) << 8) | self.ass.code[pos];
    }

    pub fn debug(self: *x86_jit) void {
        for (self.program.instructions.items) |i| {
            if (i.name) |name| {
                if (i.is_data) {
                    std.debug.print("La variable {s} tiene valor {x}\n", .{ name, self.get_data_value(i.index) });
                }
            }
        }
    }
};

test "jit_test" {
    const dist_between_two_numbers =
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
        \\*found :MOV j res
        \\num2 : 0xabcd
        \\num1 : 0x4321
        \\i : 0x0000
        \\j : 0x0000
        \\zero : 0x0000
        \\one : 0x0001
        \\min : 0x0000
        \\max : 0x0000
        \\res : 0x0000
    ;
    var ass = try assembler.assemble_program(dist_between_two_numbers, std.testing.allocator);
    defer ass.deinit();

    var jit = try x86_jit.init(std.testing.allocator, ass);
    defer jit.deinit();

    jit.jit();

    // var file = try std.fs.cwd().createFile("assembly_test", .{});
    // _ = try file.write(jit.ass.code[0..jit.ass.cursor]);
    // defer file.close();

    try jit.run();
    jit.debug();
}
