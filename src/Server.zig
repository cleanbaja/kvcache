const std = @import("std");

const net = std.net;
const print = std.debug.print;

const Packet = @import("packet.zig").Packet;
const ArrayType = @import("packet.zig").ArrayType;
const Client = @import("Client.zig");

const Self = @This();

allocator: std.mem.Allocator,
server: net.StreamServer,

/// Run the TCP server and handle incoming requests.
fn handleRequest(self: *Self) !void {
    // Accept incoming connection.
    var conn = try self.server.accept();
    var client = Client.init(self.allocator);
    defer conn.stream.close();

    print("kvcache: connection open ={}\n", .{conn.address});

    while (true) {
        // Read message into buffer.
        var recv_buffer = std.mem.zeroes([512]u8);
        const len = try conn.stream.read(&recv_buffer);

        if (len == 0)
            break;

        try client.process(recv_buffer[0..len], &conn.stream, self.allocator);
    }

    print("kvcache: connection closed\n", .{});
}

pub fn init(alloc: std.mem.Allocator) !Self {
    const addr = try net.Address.parseIp4("127.0.0.1", 6379);

    var server = blk: {
        var stream = net.StreamServer.init(.{
            .reuse_port = true,
        });

        try stream.listen(addr);
        break :blk stream;
    };

    print("kvcache: listening on {}\n", .{addr.getPort()});

    return Self{
        .allocator = alloc,
        .server = server,
    };
}

pub fn runLoop(self: *Self) !void {
    while (true) {
        try self.handleRequest();
    }
}

pub fn deinit(self: *Self) void {
    self.server.deinit();
}
