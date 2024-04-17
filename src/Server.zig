const std = @import("std");
const net = std.net;

const Packet = @import("packet.zig").Packet;
const ArrayType = @import("packet.zig").ArrayType;
const print = std.debug.print;

const Self = @This();

allocator: std.mem.Allocator,
server: net.StreamServer,

/// Run the TCP server and handle incoming requests.
fn handleRequest(server: *net.StreamServer, allocator: std.mem.Allocator) !void {
    // Accept incoming connection.
    var client = try server.accept();
    defer client.stream.close();

    print("kvcache: connection open ={}\n", .{client.address});

    var store = std.StringHashMap([]const u8).init(allocator);
    defer store.deinit();

    while (true) {
        // Read message into buffer.
        var recv_buffer = std.mem.zeroes([512]u8);
        const len = try client.stream.read(&recv_buffer);

        if (len == 0)
            break;

        const packet = try Packet.parse(recv_buffer[0..len], allocator);
        switch (packet) {
            .simple_string => {
                if (std.mem.startsWith(u8, packet.simple_string, "PING")) {
                    try client.stream.writeAll("+PONG\r\n");
                }
            },

            .array => {
                const command = packet.array.items[0];

                // TODO: safety checks
                if (std.mem.eql(u8, command.str, "CLIENT")) {
                    // We don't support any client commands for now
                    try client.stream.writeAll("+OK\r\n");
                } else if (std.mem.eql(u8, command.str, "SET")) {
                    const value = try allocator.dupe(u8, packet.array.items[2].str);
                    try store.put(packet.array.items[1].str, value);

                    try client.stream.writeAll("+OK\r\n");
                } else if (std.mem.eql(u8, command.str, "GET")) {
                    if (store.get(packet.array.items[1].str)) |val| {
                        const out = Packet{ .bulk_string = val };

                        try client.stream.writeAll(try out.serialize(allocator));
                    } else {
                        try client.stream.writeAll("$-1\r\n");
                    }
                }
            },

            else => {},
        }
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
        try handleRequest(&self.server, self.allocator);
    }
}

pub fn deinit(self: *Self) void {
    self.server.deinit();
}
