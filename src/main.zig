const std = @import("std");

const net = std.net;
const print = std.debug.print;

const Server = @import("Server.zig");

pub fn main() !void {
    var server = try Server.init(std.heap.c_allocator);
    defer server.deinit();

    try server.runLoop();
}
