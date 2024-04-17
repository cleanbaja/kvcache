const std = @import("std");
const print = std.debug.print;

pub const PacketTag = enum { simple_string, bulk_string, number, array };

pub const ArrayType = union { number: i64, str: []const u8 };

fn parseSimpleString(buffer: []const u8) ![]const u8 {
    const delim = std.mem.indexOfScalarPos(u8, buffer, 0, '\r');

    if (delim) |value| {
        return buffer[0..value];
    }

    return error.BadValue;
}

fn parseBulkString(buffer: []const u8, skip: ?*usize) ![]const u8 {
    // TODO: handle null and empty edgecases
    if (buffer[0] == '-' or buffer[0] == '0') {
        return error.Unsupported;
    }

    const num_delim = std.mem.indexOfScalarPos(u8, buffer, 0, '\r');

    if (num_delim) |value| {
        const end = try std.fmt.parseInt(usize, buffer[0..value], 10) + value + 2;

        if (skip) |sk| {
            sk.* += end + 3;
        }

        return buffer[value + 2 .. end];
    }

    return error.BadValue;
}

fn parseNumber(buffer: []const u8, skip: ?*usize) !i64 {
    var num: i64 = 0;
    var i: usize = 0;

    while (buffer[i] != '\r') : (i += 1) {
        num = (num * 10) + (buffer[i] - '0');
    }

    if (skip) |sk| {
        sk.* += i + 3;
    }

    return num;
}

fn parseArray(buffer: []const u8, allocator: std.mem.Allocator) !std.ArrayList(ArrayType) {
    var array = std.ArrayList(ArrayType).init(allocator);

    var num_delim = std.mem.indexOfScalarPos(u8, buffer, 0, '\r');

    if (num_delim) |num| {
        var count = try std.fmt.parseInt(usize, buffer[0..num], 10);
        var index = num + 2;

        while (count > 0) : (count -= 1) {
            switch (buffer[index]) {
                '+' => {
                    const str = try parseSimpleString(buffer[index + 1 ..]);
                    index += str.len + 2;

                    try array.append(ArrayType{ .str = str });
                },

                '$' => {
                    try array.append(ArrayType{ .str = try parseBulkString(buffer[index + 1 ..], &index) });
                },

                ':' => {
                    try array.append(ArrayType{ .number = try parseNumber(buffer[index + 1 ..], &index) });
                },

                else => {
                    std.log.warn("Unsupported RESP type '{c}'", .{buffer[index]});
                    return error.Unsupported;
                },
            }
        }

        return array;
    }

    return error.BadValue;
}

pub const Packet = union(PacketTag) {
    simple_string: []const u8,
    bulk_string: []const u8,
    number: i64,
    array: std.ArrayList(ArrayType),

    pub fn parse(buffer: []const u8, allocator: std.mem.Allocator) !Packet {
        switch (buffer[0]) {
            '+' => {
                return Packet{ .simple_string = try parseSimpleString(buffer[1..]) };
            },

            '$' => {
                return Packet{ .bulk_string = try parseBulkString(buffer[1..], null) };
            },

            ':' => {
                return Packet{ .number = try parseNumber(buffer[1..], null) };
            },

            '*' => {
                return Packet{ .array = try parseArray(buffer[1..], allocator) };
            },

            'P' => {
                return Packet{ .simple_string = "PING\r\n" };
            },

            else => {
                std.log.warn("Unsupported RESP type '{c}'", .{buffer[0]});
                return error.Unsupported;
            },
        }
    }

    pub fn serialize(self: Packet, allocator: std.mem.Allocator) ![]u8 {
        switch (self) {
            .number => {
                return try std.fmt.allocPrint(allocator, ":{}\r\n", .{self.number});
            },
            .simple_string => {
                return try std.fmt.allocPrint(allocator, "+{s}\r\n", .{self.simple_string});
            },
            .bulk_string => {
                return try std.fmt.allocPrint(allocator, "${}\r\n{s}\r\n", .{ self.bulk_string.len, self.bulk_string });
            },
            else => {
                return error.Unsupported;
            },
        }
    }

    pub fn deinit(self: Packet) void {
        if (@as(PacketTag, self) == PacketTag.array) {
            self.array.deinit();
        }
    }
};

test "parse simple string" {
    const sample = "+PING\r\n";

    const packet = try Packet.parse(sample, std.testing.allocator);

    try std.testing.expect(@as(PacketTag, packet) == PacketTag.simple_string);
    try std.testing.expect(std.mem.eql(u8, packet.simple_string, "PING"));
}

test "parse bulk string" {
    const sample = "$6\r\nfoobar\r\n";

    const packet = try Packet.parse(sample, std.testing.allocator);

    try std.testing.expect(@as(PacketTag, packet) == PacketTag.bulk_string);
    try std.testing.expect(std.mem.eql(u8, packet.bulk_string, "foobar"));
}

test "parse number" {
    const sample = ":2568\r\n";

    const packet = try Packet.parse(sample, std.testing.allocator);

    try std.testing.expect(@as(PacketTag, packet) == PacketTag.number);
    try std.testing.expect(packet.number == 2568);
}

test "parse array" {
    const sample = "*2\r\n:150\r\n$4\r\nECHO\r\n";

    const packet = try Packet.parse(sample, std.testing.allocator);

    try std.testing.expect(@as(PacketTag, packet) == PacketTag.array);
    try std.testing.expect(std.mem.eql(u8, packet.array.items[1].str, "ECHO"));
    try std.testing.expect(packet.array.items[0].number == 150);

    packet.deinit();
}
