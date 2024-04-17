const std = @import("std");

const net = std.net;
const print = std.debug.print;

const Server = @import("Server.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var server = try Server.init(gpa.allocator());
    defer server.deinit();

    try server.runLoop();
}
