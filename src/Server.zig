const std = @import("std");

const net = std.net;
const print = std.debug.print;

const Client = @import("Client.zig");
const io = @import("io/linux.zig");

const Self = @This();

allocator: std.mem.Allocator,
accept_data: io.UserData,
clients: std.ArrayList(*Client),
socket: io.Handle,
engine: io.Engine,

/// Run the TCP server and handle incoming requests.
fn handleRequest(self: *Self) !void {
    // sumbit all the previous IO commands, and wait for results
    _ = try self.engine.submit(1);

    // process all the results...
    for (try self.engine.getResults()) |entry| {
        switch (entry.getIoType()) {
            .accept => {
                var socket = entry.getSocket();
                var client = try Client.init(self.allocator, socket, &self.engine);
                try self.clients.append(client);

                try self.engine.add(io.Command.read(socket, client.buffer, 0, &client.userdata));
            },

            .read => {
                var client = try entry.getContext(Client);
                var bytes_read = entry.getBytesCount();

                if (bytes_read <= 0) {
                    client.deinit();
                    self.allocator.free(client.buffer);
                    self.allocator.destroy(client);
                } else {
                    try client.process(client.buffer[0..@intCast(bytes_read)], self.allocator);
                    try self.engine.add(io.Command.read(client.handle, client.buffer, 0, &client.userdata));
                }
            },

            else => {},
        }
    }
}

pub fn init(alloc: std.mem.Allocator) !Self {
    const socket = try io.createSocket(6379);

    print("kvcache: listening on localhost:6379\n", .{});

    return Self{
        .allocator = alloc,
        .socket = socket,
        .clients = std.ArrayList(*Client).init(alloc),
        .engine = try io.Engine.init(alloc),
        .accept_data = std.mem.zeroes(io.UserData),
    };
}

pub fn runLoop(self: *Self) !void {
    try self.engine.add(io.Command.accept_multishot(self.socket, &self.accept_data));

    while (true) {
        try self.handleRequest();
    }
}

pub fn deinit(self: *Self) void {
    self.engine.deinit();
    std.os.closeSocket(self.socket);

    for (self.clients.items) |client| {
        client.deinit();

        self.allocator.free(client.buffer);
        self.allocator.destroy(client);
    }
}
