const std = @import("std");
const net = std.net;

const Packet = @import("packet.zig").Packet;
const ArrayType = @import("packet.zig").ArrayType;
const print = std.debug.print;

lib_name: ?[]const u8,
lib_ver: ?[]const u8,
store: std.StringHashMap([]const u8),

const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return Self{
        .store = std.StringHashMap([]const u8).init(allocator),
        .lib_name = null,
        .lib_ver = null,
    };
}

fn handleClient(self: *Self, allocator: std.mem.Allocator, packet: Packet, stream: *net.Stream) !void {
    const cmd = packet.array.items[1].str;

    if (std.mem.eql(u8, cmd, "SETINFO")) {
        const attrib = packet.array.items[2].str;
        const value = packet.array.items[3].str;

        if (std.mem.eql(u8, attrib, "LIB-NAME")) {
            self.lib_name = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, attrib, "LIB-VER")) {
            self.lib_ver = try allocator.dupe(u8, value);
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

pub fn process(self: *Self, buffer: []const u8, stream: *std.net.Stream, allocator: std.mem.Allocator) !void {
    const packet = try Packet.parse(buffer, allocator);

    switch (packet) {
        .simple_string => {
            if (std.mem.startsWith(u8, packet.simple_string, "PING")) {
                try stream.writeAll("+PONG\r\n");
            }
        },

        .array => {
            const command = packet.array.items[0].str;

            // TODO: safety checks
            if (std.mem.eql(u8, command, "CLIENT")) {
                try self.handleClient(allocator, packet, stream);
            } else if (std.mem.eql(u8, command, "SET")) {
                const value = try allocator.dupe(u8, packet.array.items[2].str);
                try self.store.put(packet.array.items[1].str, value);

                try stream.writeAll("+OK\r\n");
            } else if (std.mem.eql(u8, command, "GET")) {
                if (self.store.get(packet.array.items[1].str)) |val| {
                    const out = Packet{ .bulk_string = val };

                    try stream.writeAll(try out.serialize(allocator));
                } else {
                    try stream.writeAll("$-1\r\n");
                }
            } else {
                // just pretend like we know what we are doing...
                try stream.writeAll("+OK\r\n");
            }
        },

        else => {},
    }
}

pub fn deinit(self: *Self) !Self {
    self.store.deinit();
}
