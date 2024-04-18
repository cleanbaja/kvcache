const std = @import("std");

const os = std.os;
const linux = std.os.linux;

const MAX_SQE = 256;
const MAX_CQE = 128;

pub const Handle = linux.fd_t;

pub const IoResultType = enum(u64) {
    nop,
    accept,
    read,
    write,
};

pub const UserData = struct {
    type: IoResultType,
    ctx: ?*anyopaque,
};

pub const IoResult = extern struct {
    cqe: linux.io_uring_cqe,

    pub fn getIoType(self: *const IoResult) IoResultType {
        if (self.cqe.user_data == 0)
            unreachable;

        const udata: *UserData = @ptrFromInt(self.cqe.user_data);
        return udata.type;
    }

    pub fn getSocket(self: *const IoResult) Handle {
        std.debug.assert(self.getIoType() == .accept);

        return self.cqe.res;
    }

    pub fn getContext(self: *const IoResult, comptime T: type) !*T {
        if (self.cqe.user_data == 0)
            return error.NoUserData;

        const udata: *UserData = @ptrFromInt(self.cqe.user_data);

        if (udata.ctx) |ctx| {
            return @alignCast(@ptrCast(ctx));
        } else {
            return error.NoUserData;
        }
    }

    pub fn getBytesCount(self: *const IoResult) i32 {
        std.debug.assert(self.getIoType() == .read or self.getIoType() == .write);

        return self.cqe.res;
    }
};

pub const Engine = struct {
    ring: linux.IO_Uring,
    allocator: std.mem.Allocator,
    entries: []IoResult,

    pub fn init(allocator: std.mem.Allocator) !Engine {
        return Engine{
            .ring = try linux.IO_Uring.init(MAX_SQE, 0),
            .entries = try allocator.alloc(IoResult, MAX_CQE),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.ring.deinit();
        self.allocator.free(self.entries);
    }

    pub fn add(self: *Engine, command: Command) !void {
        var entry = try self.ring.get_sqe();

        entry.* = command.getRaw();
    }

    pub fn getResults(self: *Engine) ![]IoResult {
        // we do the waiting in "submit", so don't do it here
        const total = try self.ring.copy_cqes(@ptrCast(self.entries), 0);

        return self.entries[0..total];
    }

    pub fn submit(self: *Engine, wait_entry_count: u32) !u32 {
        return try self.ring.submit_and_wait(wait_entry_count);
    }
};

pub const Command = struct {
    sqe: linux.io_uring_sqe,

    pub fn nop(userdata: ?*UserData) Command {
        var cmd = std.mem.zeroes(Command);
        linux.io_uring_prep_nop(&cmd.sqe);

        if (userdata) |udata| {
            udata.type = .nop;
            cmd.sqe.user_data = @intFromPtr(udata);
        }

        return cmd;
    }

    pub fn read(handle: Handle, buffer: []u8, offset: u64, userdata: ?*UserData) Command {
        var cmd = std.mem.zeroes(Command);
        linux.io_uring_prep_read(&cmd.sqe, handle, buffer, offset);

        if (userdata) |udata| {
            udata.type = .read;
            cmd.sqe.user_data = @intFromPtr(udata);
        }

        return cmd;
    }

    pub fn write(handle: Handle, buffer: []u8, offset: u64, userdata: ?*UserData) Command {
        var cmd = std.mem.zeroes(Command);
        linux.io_uring_prep_write(&cmd.sqe, handle, buffer, offset);

        if (userdata) |udata| {
            udata.type = .write;
            cmd.sqe.user_data = @intFromPtr(udata);
        }

        return cmd;
    }

    pub fn accept_multishot(handle: Handle, userdata: ?*UserData) Command {
        var cmd = std.mem.zeroes(Command);
        linux.io_uring_prep_accept(&cmd.sqe, handle, null, null, 0);

        cmd.sqe.ioprio |= 0b1; // IO_URING_ACCEPT_MULTISHOT

        if (userdata) |udata| {
            udata.type = .accept;
            cmd.sqe.user_data = @intFromPtr(udata);
        }

        return cmd;
    }

    pub fn getRaw(self: *const Command) linux.io_uring_sqe {
        return self.sqe;
    }
};

/// Creates a server socket, bind it and listen on it.
pub fn createSocket(port: u16) !Handle {
    const sockfd = try os.socket(os.AF.INET6, os.SOCK.STREAM, 0);
    errdefer os.close(sockfd);

    // allow for multiple listeners on 1 thread
    try os.setsockopt(
        sockfd,
        os.SOL.SOCKET,
        os.SO.REUSEPORT,
        &std.mem.toBytes(@as(c_int, 1)),
    );

    // enable ipv4 as well
    try os.setsockopt(
        sockfd,
        os.IPPROTO.IPV6,
        os.linux.IPV6.V6ONLY,
        &std.mem.toBytes(@as(c_int, 0)),
    );

    const addr = try std.net.Address.parseIp6("::0", port);

    try os.bind(sockfd, &addr.any, @sizeOf(os.sockaddr.in6));
    try os.listen(sockfd, std.math.maxInt(u31));

    return sockfd;
}

test "uring nop" {
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.add(Command.nop(null));
    try engine.add(Command.nop(null));
    _ = try engine.submit(1);

    for (try engine.getResults()) |entry| {
        try std.testing.expect(entry.cqe.err() == linux.E.SUCCESS);
    }
}

test "uring read/write" {
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const raw_handle = try std.fs.cwd().createFile("testing.txt", .{ .read = true });
    const handle = raw_handle.handle;
    defer raw_handle.close();

    var write_buffer = try std.testing.allocator.alloc(u8, 512);
    var read_buffer = try std.testing.allocator.alloc(u8, 512);
    defer std.testing.allocator.free(write_buffer);
    defer std.testing.allocator.free(read_buffer);

    @memset(write_buffer, 0xE9);

    try engine.add(Command.write(handle, write_buffer, 0, null));
    try engine.add(Command.read(handle, read_buffer, 0, null));

    _ = try engine.submit(1);

    for (try engine.getResults()) |entry| {
        try std.testing.expect(entry.cqe.err() == linux.E.SUCCESS);
        try std.testing.expect(entry.cqe.res == 512); // bytes read
    }

    try std.testing.expectEqualStrings(write_buffer, read_buffer);
    try std.fs.cwd().deleteFile("testing.txt");
}

//
// Connect using socat like this:
//
// ```bash
// $ socat - TCP-CONNECT:localhost:8284
// ```
//
test "uring accept multishot" {
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    var socket = try createSocket(8284);
    defer os.closeSocket(socket);

    try engine.add(Command.accept_multishot(socket, null));
    _ = try engine.submit(1);

    for (try engine.getResults()) |entry| {
        try std.testing.expect(entry.cqe.err() == linux.E.SUCCESS);
        try std.testing.expect(entry.cqe.flags == 2); // IORING_CQE_F_MORE
    }
}
