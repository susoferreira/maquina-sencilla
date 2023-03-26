const std = @import("std");
const init_gui = @import("gui.zig").init_gui;

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    std.debug.print(" |LOG| ["++@tagName(message_level)++" | " ++ @tagName(scope) ++ "]:   " ++ format,args);
}


pub fn main() !void {
    try init_gui();
}
