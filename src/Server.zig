const std = @import("std");
const io = @import("io.zig");
const cmd = @import("commands.zig");

const net = std.net;
const print = std.debug.print;
const Client = cmd.Client;
const ClientList = cmd.ClientList;

const Self = @This();

const Worker = struct {
    engine: io.Engine,
    accept_data: io.UserData,
    socket: io.Handle,
    server: *Self,
    id: usize,

    pub fn init(alloc: std.mem.Allocator, parent: *Self, index: usize) !Worker {
        return Worker{
            .engine = try io.Engine.init(alloc),
            .accept_data = std.mem.zeroes(io.UserData),
            .server = parent,
            .socket = try io.createSocket(6379),
            .id = index,
        };
    }

    /// Run the TCP server and handle incoming requests.
    fn handleRequest(self: *Worker) !void {
        // sumbit all the previous IO commands, and wait for results
        _ = try self.engine.submit(1);

        // process all the results...
        for (try self.engine.getResults()) |entry| {
            switch (entry.getIoType()) {
                .accept => {
                    // print("kvcache (id {}): new connection!\n", .{self.id});
                    var socket = entry.getSocket();
                    var client = try Client.init(self.server.allocator, socket);

                    self.server.clients.prepend(&client.node);

                    // start the cycle...
                    try self.engine.add(io.Command.read(socket, client.buffer, 0, &client.userdata));
                },

                .read => {
                    var client = try entry.getContext(Client);
                    var bytes_read = entry.getBytesCount();

                    if (bytes_read <= 0) {
                        // free client
                        self.server.clients.remove(&client.node);
                        client.deinit(self.server.allocator);
                    } else {
                        // print("data (id {}): {s}\n", .{ self.id, client.buffer[0..@intCast(bytes_read)] });
                        try cmd.process(client, @intCast(bytes_read), self.server.allocator, &self.server.store, &self.server.store_mutex);

                        try self.engine.add(io.Command.read(client.handle, client.buffer, 0, &client.userdata));
                    }
                },

                else => {},
            }
        }
    }
};

clients: ClientList,
allocator: std.mem.Allocator,
store: std.StringHashMap([]const u8),
store_mutex: std.Thread.Mutex,

pub fn init(alloc: std.mem.Allocator) !Self {
    print("kvcache: listening on localhost:6379\n", .{});

    return Self{
        .allocator = alloc,
        .clients = ClientList{},
        .store = std.StringHashMap([]const u8).init(alloc),
        .store_mutex = std.Thread.Mutex{},
    };
}

fn workerEntry(worker: *Worker) !void {
    try worker.engine.add(io.Command.accept_multishot(worker.socket, &worker.accept_data));

    while (true) {
        try worker.handleRequest();
    }
}

pub fn runLoop(self: *Self) !void {
    var threads: [4]std.Thread = undefined;

    var workers: []Worker = try self.allocator.alloc(Worker, 4);
    defer self.allocator.free(workers);

    for (0..4) |idx| {
        workers[idx] = try Worker.init(self.allocator, self, idx);
        threads[idx] = try std.Thread.spawn(.{}, workerEntry, .{&workers[idx]});
    }

    for (&threads) |thread| {
        thread.join();
    }
}

pub fn deinit(self: *Self) void {
    self.store.deinit();

    {
        var it = self.clients.first;
        var index: u32 = 1;
        while (it) |node| : (it = node.next) {
            node.data.deinit(self.allocator);
            index += 1;
        }
    }
}
