const std = @import("std");
const components = @import("./components.zig");
const expect = std.testing.expect;

const logger = std.log.scoped(.assembler);

fn is_number(str: []const u8) bool {
    const nums = "0123456789";
    if (str.len < 1) return false;

    for (nums) |num| {
        if (num == str[0]) {
            return true;
        }
    }
    return false;
}

//represents any type of instruction
pub const instruction = struct {
    index: u7,
    data: u16,
    //only labels have names
    name: ?[]const u8,
    is_data: bool, //raw numbers are data
    is_breakpoint: bool,
    original_text: []const u8,
    original_line: usize,
};

pub const assembler_result = struct {
    allocator: std.mem.Allocator,

    instructions: std.ArrayList(instruction),
    labels: std.StringHashMap(*instruction),

    breakpoint_indexes: std.ArrayList(u7),
    breakpoint_lines: std.ArrayList(c_int),

    program: [128]u16,

    pub fn deinit(self: *assembler_result) void {
        self.instructions.deinit();
        self.labels.deinit();
        self.breakpoint_indexes.deinit();
        self.breakpoint_lines.deinit();
    }
};

//returns label info, only valid if is_label is true
fn check_label(line: []const u8) struct { name_index: u32, is_label: bool, is_breakpoint: bool } {
    const label_index = std.mem.indexOf(u8, line, ":") orelse return .{ .name_index = 0, .is_label = false, .is_breakpoint = false };
    var split = std.mem.splitSequence(u8, line, " \t");
    return .{
        .name_index = @intCast(label_index),
        .is_label = true,
        .is_breakpoint = split.first()[0] == '*',
    };
}

fn build_breakpoints(allocator: std.mem.Allocator, instructions: []instruction) !struct { indexes: std.ArrayList(u7), lines: std.ArrayList(c_int) } {
    var breakpoint_indexes = std.ArrayList(u7).init(allocator);
    var breakpoint_lines = std.ArrayList(c_int).init(allocator);

    for (instructions) |ins| {
        if (ins.is_breakpoint) {
            try breakpoint_indexes.append(ins.index);
            try breakpoint_lines.append(@intCast(ins.original_line));
        }
    }

    return .{
        .indexes = breakpoint_indexes,
        .lines = breakpoint_lines,
    };
}

fn build_program(allocator: std.mem.Allocator, instructions: []instruction) ![128]u16 {
    _ = allocator;

    var program: [128]u16 = [_]u16{0} ** 128;
    var i: usize = 0;

    for (instructions) |ins| {
        program[i] = ins.data;
        i += 1;
    }
    return program;
}

pub fn assemble_program(program: []const u8, allocator: std.mem.Allocator) !assembler_result {
    var instructions = try std.ArrayList(instruction).initCapacity(allocator, 128); //its important to init with 128 so we dont reallocate memory
    errdefer instructions.deinit();

    var labels = std.StringHashMap(*instruction).init(allocator);
    errdefer labels.deinit();
    var lines = std.mem.splitScalar(u8, program, '\n');

    try first_pass(&lines, &instructions, &labels);
    try second_pass(instructions.items, labels);

    var breakpoint_info = try build_breakpoints(allocator, instructions.items);
    errdefer breakpoint_info.indexes.deinit();
    errdefer breakpoint_info.lines.deinit();

    const build = try build_program(allocator, instructions.items);

    return .{
        .allocator = allocator,
        .instructions = instructions,
        .labels = labels,
        .breakpoint_indexes = breakpoint_info.indexes,
        .breakpoint_lines = breakpoint_info.lines,
        .program = build,
    };
}

fn first_pass(lines: *std.mem.SplitIterator(u8, .scalar), instructions: *std.ArrayList(instruction), labels: *std.StringHashMap(*instruction)) !void {
    var line_number: usize = 1;
    var index: usize = 0;

    while (lines.next()) |line| : (line_number += 1) {
        if (index > 127) {
            logger.err("El programa excede la memoria de la maquina {} > 128", .{index + 1});
            return error.ProgramTooBig;
        }
        var words = std.mem.tokenize(u8, line, " ");

        const first_word = words.peek() orelse continue; //on empty line continue

        if (first_word[0] == ';') {
            //comment
            continue;
        }

        var name: ?[]const u8 = null; //set name (or not)

        const label_info = check_label(line);
        if (label_info.is_label) {
            if (label_info.is_breakpoint) {
                //ignore '*'
                name = std.mem.trim(u8, line[1..label_info.name_index], " ");
            } else {
                name = std.mem.trim(u8, line[0..label_info.name_index], " ");
            }

            //add to hashmap
            const status = try labels.getOrPut(name.?);
            if (status.found_existing) {
                const original = labels.get(name.?).?;
                logger.err("Redefinición de la etiqueta {s} en la linea {}, definida originalmente en la línea {}", .{ name.?, line_number, original.original_line });
                return error.LabelAlreadyExists;
            }
        }
        //first pass we dont assemble anything
        const current: instruction = .{
            .index = @intCast(index),
            .data = undefined,
            .name = name,
            .is_data = undefined,
            .original_text = line,
            .original_line = line_number,
            .is_breakpoint = label_info.is_breakpoint,
        };
        try instructions.append(current);

        if (name) |n| {
            try labels.put(n, &instructions.items[instructions.items.len - 1]);
        }

        index += 1;
    }
}

fn second_pass(instructions: []instruction, labels: std.StringHashMap(*instruction)) !void {
    for (instructions) |*current| {
        var text = current.original_text;
        if (current.is_breakpoint) {
            //messes up calculations with name length
            text = std.mem.trim(u8, text, "*");
        }

        text = std.mem.trim(u8, text, " ");
        if (current.name) |name| {
            text = text[name.len..text.len];
        }
        text = std.mem.trim(u8, text, " :");

        if (is_number(text)) {
            current.is_data = true;
            current.data = try std.fmt.parseInt(u16, text, 0);
        } else {
            current.data = try assemble_instruction(text, current.original_line, labels);
            current.is_data = false;
        }
    }
}

fn get_opcode(operation: []const u8, line_number: usize) !u2 {
    inline for (@typeInfo(components.MS_OPCODE).Enum.fields) |tag| {
        if (std.mem.eql(u8, operation, tag.name)) {
            return tag.value;
        }
    }
    logger.err("OPCODE no válido encontrado: {s} en línea {} ", .{ operation, line_number });
    return error.InvalidOperation;
}

fn get_operand(op: []const u8, line_number: usize, labels: std.StringHashMap(*instruction)) !u7 {
    if (is_number(op)) {
        return std.fmt.parseInt(u7, op, 0) catch |err| switch (err) {
            error.Overflow => {
                logger.err("Error en la línea {}, el operando {s} es mayor que el rango posible para un u7", .{ line_number, op });
                return error.Overflow;
            },
            error.InvalidCharacter => {
                logger.err("Error en la línea {}, carácter inválido al parsear un numero ({s})", .{ line_number, op });
                return error.InvalidCharacter;
            },
        };
    }
    const label = labels.get(op) orelse {
        logger.err("No se encuentra la etiqueta {s} referenciada en la línea {}", .{ op, line_number });
        return error.LabelDoesNotExist;
    };
    return label.index;
}

fn assemble_instruction(line: []const u8, line_number: usize, labels: std.StringHashMap(*instruction)) !u16 {
    var words = std.mem.tokenizeAny(u8, line, " ");

    logger.debug("ensamblando línea {s}\n", .{line});

    const word = words.next() orelse {
        logger.err("Se esperaba un código de operacion en la linea {} pero no se encontró nada\nRecordatorio: las labels tienen que ir en la misma línea que su instrucción", .{line_number});
        return error.OpcodeNotFound;
    };

    const opcode: u2 = try get_opcode(word, line_number);

    var dir1: u7 = 0;
    if (opcode != @intFromEnum(components.MS_OPCODE.BEQ)) {
        dir1 = try get_operand(words.next() orelse {
            logger.err("Error en línea {}, faltan operandos\n", .{line_number});
            return error.NotEnoughOperands;
        }, line_number, labels);
    }
    const dir2: u7 = try get_operand(words.next() orelse {
        logger.err("Error en línea {}, faltan operandos\n", .{line_number});
        return error.NotEnoughOperands;
    }, line_number, labels);

    if (words.next() != null) {
        return error.TooManyTokens;
    }

    return @as(u16, opcode) << 14 | @as(u16, dir1) << 7 | dir2;
}

test "basic instructions" {
    const test_str =
        \\ MOV 0x10 0x20
        \\ ADD 0x30 0x40
        \\ CMP 0X50 0X60
        \\ BEQ 0X70
    ;
    var result = try assemble_program(test_str, std.testing.allocator);
    defer result.deinit();

    const expected = [_]u16{ 0x8820, 0x1840, 0x6860, 0xc070 };

    for (0..4) |i| {
        try expect(result.program[i] == expected[i]);
    }
}

test "test errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    try std.testing.expectError(error.TooManyTokens, assemble_program("MOV 1 2 3 4 5 6 7", alloc));
    try std.testing.expectError(error.NotEnoughOperands, assemble_program("MOV 1", alloc));
    try std.testing.expectError(error.InvalidOperation, assemble_program("PITO 1 2", alloc));
    try std.testing.expectError(error.Overflow, assemble_program("MOV 0xFFFFF 0xcaca", alloc));
    try std.testing.expectError(error.LabelDoesNotExist, assemble_program("MOV 0 num1", alloc));
}

test "distance betweeen two numbers" {
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
        \\*found : MOV j res
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

    var results = try assemble_program(program, std.testing.allocator);
    defer results.deinit();
}

test "test labels" {
    const test_recognition =
        \\cosa : 0xcaca
        \\cosa1 : MOV 0 1
    ;

    const alloc = std.testing.allocator;

    var results = try assemble_program(test_recognition, alloc);
    defer results.deinit();

    try expect(results.labels.get("cosa").?.data == 0xcaca);
    try expect(results.labels.get("cosa").?.is_data == true);
    try expect(results.labels.get("cosa1").?.index == 1);
    try expect(results.labels.get("cosa1").?.is_breakpoint == false);
    try expect(results.labels.get("cosa1").?.is_data == false);

    const test_resolving =
        \\num1 : 0xcaca
        \\num2 : 0xbebe
        \\tmp : 0
        \\MOV num1 tmp
        \\MOV num2 num1
        \\MOV tmp num2
    ;

    var assemble = try assemble_program(test_resolving, alloc);
    defer assemble.deinit();
}
