const std = @import("std");
const builtin = @import("builtin");
const Server = @import("Server.zig");

pub var running = true;

pub fn main() !void {
    var server: Server = undefined;

    //
    // For some reason, even though the test runner doesn't
    // actually run this function, the zig compiler wants me
    // to link with LibC, which isn't even used!
    //
    // So I've decided to stub with the page allocator until
    // this bug gets fixed...
    //
    if (builtin.is_test) {
        server = try Server.init(std.heap.page_allocator);
    } else {
        server = try Server.init(std.heap.c_allocator);
    }

    defer server.deinit();
    try server.runLoop();
}

test {
    // To run nested container tests, either, call `refAllDecls` which will
    // reference all declarations located in the given argument.
    // `@This()` is a builtin function that returns the innermost container it is called from.
    // In this example, the innermost container is this file (implicitly a struct).
    std.testing.refAllDecls(@This());
}
