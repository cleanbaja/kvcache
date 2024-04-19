//!
//! Contains a parser for RESP 2.0, using code derived from 'node-redis-parser'...
//!
//! Repo: https://github.com/NodeRedis/node-redis-parser/blob/master/lib/parser.js
//!
//! Use the parser like so:
//!
//! ```
//! fn example(allocator: std.mem.Allocator) !void {
//!     const parser = Parser.init(allocator);
//!
//!     const message = "+Hello, World\r\n";
//!     const value = parser.execute(message);
//!     print("value is {}\n", .{value.string});
//!
//!     // parsers are also reusable.
//!     const value2 = parser.execute(":12345\r\n");
//!     print("second value is {}\n", .{value2.number});
//!
//!     // finally, you can switch over parser results...
//!     switch (value2) {
//!         .string => print("it's a string!\n", .{});
//!         else => print("it's not a string...\n", .{});
//!     }
//! }
//! ```
//!

const std = @import("std");

/// The different types of RESP items.
const ParseItemType = enum { string, list, number };

/// Union which contains all RESP types (minus errors)
pub const ParseItem = union(ParseItemType) {
    string: []const u8,
    list: std.ArrayList(ParseItem),
    number: i64,
};

/// Errors returned by `Parser`
const ParseError = error{
// zig fmt: off

    /// Input passed into parser is malformed.
    InvalidInput,
    
    /// Unable to allocate memory for ArrayList.resize()
    OutOfMemory

// zig fmt: on
};

///
/// A recursive, reentrant parser for RESP packets.
///
/// NOTE: This parser doesn't support chunked/incomplete input...
///
pub const Parser = struct {
    offset: usize,
    buffer: []const u8,
    allocator: std.mem.Allocator,

    /// Initialize the parser, providing `alloc` for `ArrayList` allocations.
    pub fn init(alloc: std.mem.Allocator) Parser {
        return Parser{
            .offset = 0,
            .buffer = undefined,
            .allocator = alloc,
        };
    }

    fn parseLength(self: *Parser) ParseError!usize {
        const length = self.buffer.len - 1;
        var offset = self.offset;
        var number: usize = 0;

        while (offset < length) {
            const c1 = self.buffer[offset];
            offset += 1;

            if (c1 == 13) {
                self.offset = offset + 1;
                return number;
            }

            number = (number * 10) + (c1 - 48);
        }

        return error.InvalidInput;
    }

    fn parseBulkString(self: *Parser) ParseError![]const u8 {
        const length = try self.parseLength();

        if (length < 0) {
            return error.InvalidInput;
        }

        const offset = self.offset + length;
        std.debug.assert(offset + 2 <= self.buffer.len);

        const start = self.offset;
        self.offset = offset + 2;

        return self.buffer[start..offset];
    }

    fn parseSimpleString(self: *Parser) ParseError![]const u8 {
        const start = self.offset;
        const buffer = self.buffer;
        const length = buffer.len;
        var offset = start;

        while (offset < length) {
            offset += 1;

            if (buffer[offset - 1] == 13) { // \r\n
                self.offset = offset + 1;

                return self.buffer[start..(offset - 1)];
            }
        }

        return error.InvalidInput;
    }

    fn parseArrayElements(self: *Parser, responses: *std.ArrayList(ParseItem)) ParseError!void {
        const bufferLength = self.buffer.len;

        var i: usize = 0;

        while (i < responses.items.len) {
            std.debug.assert(self.offset < bufferLength);

            self.offset += 1;
            const response = try self.parseType(self.buffer[self.offset - 1]);

            responses.items[i] = response;
            i += 1;
        }
    }

    fn parseArray(self: *Parser) ParseError!std.ArrayList(ParseItem) {
        const length = try self.parseLength();

        if (length < 0) {
            return error.InvalidInput;
        }

        var responses = std.ArrayList(ParseItem).init(self.allocator);
        try responses.resize(length);

        try self.parseArrayElements(&responses);
        return responses;
    }

    fn parseInteger(self: *Parser) ParseError!i64 {
        const length = self.buffer.len - 1;
        var offset = self.offset;
        var number: i64 = 0;
        var sign: i64 = 1;

        if (self.buffer[offset] == 45) {
            sign = -1;
            offset += 1;
        }

        while (offset < length) {
            const c1 = self.buffer[offset];
            offset += 1;

            if (c1 == 13) { // \r\n
                self.offset = offset + 1;
                return sign * number;
            }

            number = (number * 10) + (c1 - 48);
        }

        return error.InvalidInput;
    }

    fn parseType(self: *Parser, kind: u8) ParseError!ParseItem {
        switch (kind) {
            36 => return ParseItem{ .string = try self.parseBulkString() },
            43 => return ParseItem{ .string = try self.parseSimpleString() },
            42 => return ParseItem{ .list = try self.parseArray() },
            58 => return ParseItem{ .number = try self.parseInteger() },
            else => return error.InvalidInput,
        }
    }

    /// Parse the buffer located in `buffer` and return a `ParseItem` with
    /// the result, or a `ParseError` indicating the issue.
    pub fn execute(self: *Parser, buffer: []const u8) ParseError!ParseItem {
        self.buffer = buffer;
        self.offset = 0;

        while (self.offset < self.buffer.len) {
            const kind = self.buffer[self.offset];
            self.offset += 1;

            const response = try self.parseType(kind);
            self.buffer = undefined;

            return response;
        }

        return error.InvalidInput;
    }
};

test "parse bulk string" {
    const sample = "$6\r\nfoobar\r\n";

    var parser = Parser.init(std.testing.allocator);
    const packet = try parser.execute(sample);

    try std.testing.expect(@as(ParseItemType, packet) == .string);
    try std.testing.expectEqualStrings(packet.string, "foobar");
}

test "parse simple string" {
    const sample = "+PING\r\n";

    var parser = Parser.init(std.testing.allocator);
    const packet = try parser.execute(sample);

    try std.testing.expect(@as(ParseItemType, packet) == .string);
    try std.testing.expectEqualStrings(packet.string, "PING");
}

test "parse number" {
    const sample = ":-1231\r\n";

    var parser = Parser.init(std.testing.allocator);
    const packet = try parser.execute(sample);

    try std.testing.expect(@as(ParseItemType, packet) == .number);
    try std.testing.expect(packet.number == -1231);
}

test "parse array" {
    const sample = "*2\r\n$4\r\nECHO\r\n:150\r\n";

    var parser = Parser.init(std.testing.allocator);
    const packet = try parser.execute(sample);

    try std.testing.expect(@as(ParseItemType, packet) == .list);
    try std.testing.expectEqualStrings(packet.list.items[0].string, "ECHO");
    try std.testing.expect(packet.list.items[1].number == 150);

    packet.list.deinit();
}
