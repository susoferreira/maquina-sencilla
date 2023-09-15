const builtin = @import("builtin");
const nfd = @import("nfd");
const std = @import("std");
const c = @import("../c/c.zig");
const logger = std.log.scoped(.filesystem);



pub const is_native = switch(builtin.os.tag){
    .windows,.linux =>true,
    .freestanding => false,
    else => {@compileError("platform not supported");}
};


//name is only used on web, on native custom name is allowed
pub fn save_file_as(alloc:std.mem.Allocator, name : []const u8,data : []const u8)void{
    if(is_native){
        const path = nfd.saveFileDialog("*",null) catch |err| switch(err){
            error.NfdError => {logger.err("error encontrado abriendo el file browser: {any}\n", .{err} );return;},
        };
        if(path) |p|{
            defer nfd.freePath(p);
            native_file_write(data, p);
        }       

    }else{
        const name_sentinel = std.mem.concatWithSentinel(alloc,u8,&[_][]const u8{name},0) catch return;
        defer alloc.free(name_sentinel);

        c.em_save_file_as(data.ptr,@intCast(data.len),name_sentinel);
    }
}

pub fn native_file_write(data: []const u8, path: []const u8)void{
    var outfile = std.fs.cwd().createFile(path, .{ .read = true }) catch |err| switch(err){
            else => {logger.err("error creando el archivo {s} - {any}\n",.{path,err});return;},
        };

    defer outfile.close();
    _ = outfile.write(data) catch |err| switch(err){
            else => {logger.err("error escribiendo al archivo {s} - {any}\n", .{path,err});return;}
        };

}