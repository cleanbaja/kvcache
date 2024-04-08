const std = @import("std");
const Packet = @import("packet.zig").Packet;

const net = std.net;
const print = std.debug.print;

/// Run the TCP server and handle incoming requests.
fn handleRequest(server: *net.StreamServer, allocator: std.mem.Allocator) !void {
    // Accept incoming connection.
    var client = try server.accept();
    defer client.stream.close();

    print("kvcache: connection open ={}\n", .{client.address});

    // Read message into buffer.
    var recv_buffer = std.mem.zeroes([512]u8);
    const len = try client.stream.read(&recv_buffer);

    const packet = try Packet.parse(recv_buffer[0..len], allocator);
    switch (packet) {
        .simple_string => {
            if (std.mem.startsWith(u8, packet.simple_string, "PING")) {
                try client.stream.writeAll("+PONG\r\n");
            }
        },

        else => {},
    }

    print("kvcache: connection closed\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const addr = try net.Address.parseIp4("127.0.0.1", 6379);

    var server = blk: {
        var stream = net.StreamServer.init(.{
            .reuse_port = true,
        });

        try stream.listen(addr);
        break :blk stream;
    };
    defer server.deinit();

    print("kvcache: listening on {}\n", .{addr.getPort()});

    while (true) {
        try handleRequest(&server, allocator);
    }
}
