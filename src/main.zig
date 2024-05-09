const std = @import("std");
const Server = @import("Server.zig");

pub var running = true;

pub fn main() !void {
    var server = try Server.init(std.heap.c_allocator);
    defer server.deinit();

    try server.runLoop();
}
