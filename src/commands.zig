const std = @import("std");
const io = @import("io.zig");
const pr = @import("parser.zig");

const print = std.debug.print;

pub const ClientList = std.SinglyLinkedList(*Client);

const BUFFER_SIZE = 512;

/// Represents a single connection to the server
pub const Client = struct {
    userdata: io.UserData,
    node: ClientList.Node,
    handle: io.Handle,
    lib_name: ?[]const u8,
    lib_ver: ?[]const u8,
    buffer: []u8,

    pub fn init(allocator: std.mem.Allocator, handle: io.Handle) !*Client {
        var client = try allocator.create(Client);

        client.* = .{
            .handle = handle,
            .lib_name = null,
            .lib_ver = null,
            .buffer = try allocator.alloc(u8, BUFFER_SIZE),

            // link back to ourselves
            .userdata = .{ .ctx = client, .type = .nop },
            .node = .{ .data = client },
        };

        return client;
    }

    pub fn deinit(self: *Client, allocator: std.mem.Allocator) void {
        std.os.closeSocket(self.handle);
        allocator.free(self.buffer);

        if (self.lib_name) |lib_name| {
            allocator.free(lib_name);
        }

        if (self.lib_ver) |lib_ver| {
            allocator.free(lib_ver);
        }

        allocator.destroy(self);
    }
};

fn handleClient(client: *Client, allocator: std.mem.Allocator, packet: pr.ParseItem, stream: *std.net.Stream) !void {
    const cmd = packet.list.items[1].string;

    if (std.mem.eql(u8, cmd, "SETINFO")) {
        const attrib = packet.list.items[2].string;
        const value = packet.list.items[3].string;

        if (std.mem.eql(u8, attrib, "LIB-NAME")) {
            client.lib_name = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, attrib, "LIB-VER")) {
            client.lib_ver = try allocator.dupe(u8, value);
        } else {
            try stream.writeAll("-ERR unknown SETINFO param '");
            try stream.writeAll(attrib);
            try stream.writeAll("'\r\n");
        }
    } else {
        // ignore unsupported commands
    }

    try stream.writeAll("+OK\r\n");
}

pub fn process(client: *Client, len: usize, alloc: std.mem.Allocator, store: *std.StringHashMap([]const u8), store_mutex: *std.Thread.Mutex) !void {
    var parser = pr.Parser.init(alloc);

    const packet = try parser.execute(client.buffer[0..len]);

    // TODO: super hacky, use async io instead
    var stream = std.net.Stream{ .handle = client.handle };

    switch (packet) {
        .string => {
            if (std.mem.startsWith(u8, packet.string, "PING")) {
                try stream.writeAll("+PONG\r\n");
            }
        },

        .list => {
            const command = packet.list.items[0].string;

            // TODO: safety checks
            if (std.mem.eql(u8, command, "PING")) {
                try stream.writeAll("+PONG\r\n");
            } else if (std.mem.eql(u8, command, "CLIENT")) {
                try handleClient(client, alloc, packet, &stream);
            } else if (std.mem.eql(u8, command, "SET")) {
                const value = try alloc.dupe(u8, packet.list.items[2].string);

                {
                    store_mutex.lock();
                    defer store_mutex.unlock();

                    try store.put(packet.list.items[1].string, value);
                }

                try stream.writeAll("+OK\r\n");
            } else if (std.mem.eql(u8, command, "GET")) {
                var store_item = blk: {
                    store_mutex.lock();
                    defer store_mutex.unlock();

                    break :blk store.get(packet.list.items[1].string);
                };

                if (store_item) |val| {
                    const result = try std.fmt.allocPrint(alloc, "${}\r\n{s}\r\n", .{ val.len, val });

                    try stream.writeAll(result);
                    alloc.free(result);
                } else {
                    try stream.writeAll("$-1\r\n");
                }
            } else {
                // just pretend like we know what we are doing...
                try stream.writeAll("+PONG\r\n");
            }
        },

        else => {},
    }
}
