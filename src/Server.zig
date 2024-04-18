const std = @import("std");
const io = @import("io.zig");
const cmd = @import("commands.zig");

const net = std.net;
const print = std.debug.print;
const Client = cmd.Client;
const ClientList = cmd.ClientList;

const Self = @This();

clients: ClientList,
allocator: std.mem.Allocator,
store: std.StringHashMap([]const u8),
accept_data: io.UserData,
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
                var client = try Client.init(self.allocator, socket);

                self.clients.prepend(&client.node);

                // start the cycle...
                try self.engine.add(io.Command.read(socket, client.buffer, 0, &client.userdata));
            },

            .read => {
                var client = try entry.getContext(Client);
                var bytes_read = entry.getBytesCount();

                if (bytes_read <= 0) {
                    // free client
                    self.clients.remove(&client.node);
                    client.deinit(self.allocator);
                } else {
                    // print("data: {s}\n", .{client.buffer[0..@intCast(bytes_read)]});
                    try cmd.process(client, @intCast(bytes_read), self.allocator, &self.store);

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
        .clients = ClientList{},
        .engine = try io.Engine.init(alloc),
        .store = std.StringHashMap([]const u8).init(alloc),
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
    self.store.deinit();
    std.os.closeSocket(self.socket);

    {
        var it = self.clients.first;
        var index: u32 = 1;
        while (it) |node| : (it = node.next) {
            node.data.deinit(self.allocator);
            index += 1;
        }
    }
}
