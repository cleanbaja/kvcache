const std = @import("std");
const io = @import("io.zig");
const pr = @import("parser.zig");

const Self = @This();

const ClientList = std.SinglyLinkedList(*Client);

/// Represents a single redis client connected to the server...
const Client = struct {
    handle: io.Handle,
    contexts: [2]io.Context,
    node: ClientList.Node,
    parent: *Self,

    lib_name: ?[]const u8,
    lib_ver: ?[]const u8,
    buffer: []u8,

    /// Create a client from a socket, linking back to the parent server.
    pub fn init(allocator: std.mem.Allocator, parent: *Self, handle: io.Handle, func: anytype) !*Client {
        const client = try allocator.create(Client);
        const ctx = .{ .userptr = client, .handler = func, .type = .nop };

        client.* = .{
            .handle = handle,
            .lib_name = null,
            .lib_ver = null,
            .parent = parent,
            .buffer = try allocator.alloc(u8, 512),

            // link back to ourselves
            .contexts = [_]io.Context{ctx} ** 2,
            .node = .{ .data = client },
        };

        return client;
    }
};

allocator: std.mem.Allocator,
engine: io.Engine,
clients: ClientList,
store: std.StringHashMap([]const u8),
socket: io.Handle,
accept_ctx: io.Context,

/// Create a server with the provided allocator.
pub fn init(allocator: std.mem.Allocator) !Self {
    return Self{
        .engine = try io.Engine.init(allocator),
        .socket = try io.createSocket(6379),
        .accept_ctx = undefined,
        .allocator = allocator,
        .clients = ClientList{},
        .store = std.StringHashMap([]const u8).init(allocator),
    };
}

/// Shutdown the server, cleaning up contexts.
pub fn deinit(self: *Self) void {
    self.store.deinit();
    self.engine.deinit();

    std.posix.close(self.socket);
}

/// Destroys `client` after they disconnect (or error).
fn destroyClient(self: *Self, client: *Client) !void {
    self.clients.remove(&client.node);
    self.allocator.free(client.buffer);
    self.allocator.destroy(client);
}

/// Processes redis commands for `client`
fn process(self: *Self, client: *Client, buffer: []u8) !void {
    var parser = pr.Parser.init(self.allocator);

    const packet = try parser.execute(buffer);

    switch (packet) {
        .string => {
            if (std.mem.startsWith(u8, packet.string, "PING")) {
                try self.engine.do_write(client.handle, "+PONG\r\n", 0, &client.contexts[1]);
            }
        },

        .list => {
            const command = packet.list.items[0].string;

            // TODO: safety checks
            if (std.mem.eql(u8, command, "PING")) {
                try self.engine.do_write(client.handle, "+PONG\r\n", 0, &client.contexts[1]);
            } else if (std.mem.eql(u8, command, "CLIENT")) {
                // ignore for now, will add functionality back soon
                try self.engine.do_write(client.handle, "+OK\r\n", 0, &client.contexts[1]);
            } else if (std.mem.eql(u8, command, "SET")) {
                const value = try self.allocator.dupe(u8, packet.list.items[2].string);

                try self.store.put(packet.list.items[1].string, value);

                try self.engine.do_write(client.handle, "+OK\r\n", 0, &client.contexts[1]);
            } else if (std.mem.eql(u8, command, "GET")) {
                const store_item = self.store.get(packet.list.items[1].string);

                if (store_item) |val| {
                    const result = try std.fmt.allocPrint(self.allocator, "${}\r\n{s}\r\n", .{ val.len, val });

                    try self.engine.do_write(client.handle, result, 0, &client.contexts[1]);
                } else {
                    try self.engine.do_write(client.handle, "$-1\r\n", 0, &client.contexts[1]);
                }
            } else {
                // just pretend like we know what we are doing...
                try self.engine.do_write(client.handle, "+OK\r\n", 0, &client.contexts[1]);
            }
        },

        else => {},
    }
}

/// Run the TCP server and handle incoming requests.
fn handleRequest(kind: io.IoType, ctx: ?*anyopaque, result: io.Result) !void {
    switch (kind) {
        .accept => {
            const self: *Self = @alignCast(@ptrCast(ctx));

            var client = try Client.init(self.allocator, self, result.res, Self.handleRequest);
            self.clients.prepend(&client.node);

            try self.engine.do_recv(client.handle, 0, &client.contexts[0]);
            try self.engine.do_accept(self.socket, &self.accept_ctx);
        },

        .recv => {
            var client: *Client = @alignCast(@ptrCast(ctx));
            var self = client.parent;

            if (result.res <= 0) {
                if (result.res < 0) {
                    return;
                }
                try self.engine.do_close(client.handle, &client.contexts[1]);

                return;
            }

            try self.process(client, result.buffer.?);
            try self.engine.do_recv(client.handle, 0, &client.contexts[0]);
        },

        .close => {
            const client: *Client = @alignCast(@ptrCast(ctx));
            var self = client.parent;

            try self.destroyClient(client);
        },

        else => {},
    }
}

/// The main server runloop, which sets up remaining parts
/// of the server before entering the IO engine runloop.
pub fn runLoop(self: *Self) !void {
    self.accept_ctx = io.Context{
        .type = .nop,
        .userptr = self,
        .handler = Self.handleRequest,
    };

    try self.engine.do_accept(self.socket, &self.accept_ctx);
    try io.attachSigListener();

    // enter the IO runloop
    try self.engine.enter();
}
