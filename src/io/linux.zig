const std = @import("std");
const builtin = @import("builtin");

const os = std.os;
const linux = std.os.linux;

const MAX_ENTRIES = 128;

pub const Handle = linux.fd_t;

pub const IoType = enum(u64) {
    nop = 0,
    accept,
    read,
    write,
    close,
};

pub const Result = struct {
    res: i32,
    flags: u32,
};

pub const Context = struct {
    type: IoType,
    handler: *const fn (kind: IoType, ctx: ?*anyopaque, result: Result) anyerror!void,
    userptr: ?*anyopaque,
};

pub const Engine = struct {
    ring: linux.IO_Uring,
    pending: usize,
    handles: []Handle,

    pub fn init(allocator: std.mem.Allocator) !Engine {
        var fdtable = try allocator.alloc(Handle, 512);
        @memset(fdtable, 0);

        var engine = Engine{
            .ring = try linux.IO_Uring.init(MAX_ENTRIES, 0),
            .handles = fdtable,
            .pending = 0,
        };

        try engine.ring.register_files(engine.handles);
        return engine;
    }

    pub fn deinit(self: *Engine) void {
        self.ring.deinit();
    }

    fn getEntry(self: *Engine) !*linux.io_uring_sqe {
        var entry = self.ring.get_sqe() catch |err| switch (err) {
            error.SubmissionQueueFull => blk: {
                const done = try self.ring.submit();
                self.pending -= done;

                // TODO: what if get_sqe errors out again?
                break :blk self.ring.get_sqe();
            },
            else => return err,
        };

        self.pending += 1;

        return entry;
    }

    pub fn submit(self: *Engine, wait_entry_count: u32) !u32 {
        var done = try self.ring.submit_and_wait(wait_entry_count);
        self.pending -= done;

        return done;
    }

    pub fn flush(self: *Engine) !void {
        var cqes: [128]linux.io_uring_cqe = undefined;

        while (true) {
            if (self.pending != 0) {
                var done = try self.ring.submit_and_wait(1);
                self.pending -= done;
            }

            // `error.SignalInterrupt` should be handled by the callee (just call `flush()` again)
            const len = try self.ring.copy_cqes(&cqes, 0);

            if (len == 0) {
                break;
            }

            for (cqes[0..len]) |cqe| {
                var context: *Context = @ptrFromInt(cqe.user_data);

                try context.handler(context.type, context.userptr, Result{ .res = cqe.res, .flags = cqe.flags });
            }
        }
    }

    // --------------------------------
    //            Operators
    // --------------------------------

    pub fn do_nop(self: *Engine, ctx: *Context) !void {
        var sqe = try self.getEntry();
        linux.io_uring_prep_nop(sqe);

        ctx.type = .nop;
        sqe.user_data = @intFromPtr(ctx);
    }

    pub fn do_read(self: *Engine, handle: Handle, buffer: []u8, offset: u64, ctx: *Context) !void {
        var sqe = try self.getEntry();
        linux.io_uring_prep_read(sqe, handle, buffer, offset);

        ctx.type = .read;
        sqe.user_data = @intFromPtr(ctx);
    }

    pub fn do_write(self: *Engine, handle: Handle, buffer: []const u8, offset: u64, ctx: *Context) !void {
        var sqe = try self.getEntry();
        linux.io_uring_prep_write(sqe, handle, buffer, offset);

        ctx.type = .write;
        sqe.user_data = @intFromPtr(ctx);
    }

    pub fn do_close(self: *Engine, handle: Handle, ctx: *Context) !void {
        var sqe = try self.getEntry();
        linux.io_uring_prep_close(sqe, handle);

        ctx.type = .close;
        sqe.user_data = @intFromPtr(ctx);
    }

    pub fn do_accept_multishot(self: *Engine, handle: Handle, ctx: *Context) !void {
        var sqe = try self.getEntry();
        linux.io_uring_prep_accept(sqe, handle, null, null, 0);

        sqe.ioprio |= 0b1; // IO_URING_ACCEPT_MULTISHOT

        sqe.user_data = @intFromPtr(ctx);
        ctx.type = .accept;
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

fn testingHandler(kind: IoType, ctx: ?*anyopaque, result: Result) anyerror!void {
    _ = ctx;

    if (!builtin.is_test) {
        @compileError("attempt to call 'testingHandler()' outside of zig test!");
    }

    switch (kind) {
        .nop => {
            try std.testing.expect(result.res >= 0); // res < 0 means error
        },

        .read, .write => {
            try std.testing.expect(result.res == 512); // bytes read/written
        },

        .close => {
            try std.testing.expect(result.res >= 0); // res < 0 means error
        },

        .accept => {
            try std.testing.expect(result.res >= 0); // res < 0 means error
            try std.testing.expect(result.flags == 2); // IORING_CQE_F_MORE
        },
    }
}

test "uring nop" {
    var engine = try Engine.init();
    defer engine.deinit();

    var context = Context{
        .type = undefined,
        .userptr = null,
        .handler = testingHandler,
    };

    try engine.do_nop(&context);
    _ = try engine.flush();
}

test "uring read/write/close" {
    var engine = try Engine.init();
    defer engine.deinit();

    const raw_handle = try std.fs.cwd().createFile("testing.txt", .{ .read = true });
    const handle = raw_handle.handle;

    var write_buffer = try std.testing.allocator.alloc(u8, 512);
    var read_buffer = try std.testing.allocator.alloc(u8, 512);
    defer std.testing.allocator.free(write_buffer);
    defer std.testing.allocator.free(read_buffer);

    @memset(write_buffer, 0xE9);

    var context = Context{
        .type = undefined,
        .userptr = null,
        .handler = testingHandler,
    };

    try engine.do_write(handle, write_buffer, 0, &context);
    try engine.do_read(handle, read_buffer, 0, &context);
    try engine.do_close(handle, &context);
    _ = try engine.flush();

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
    var engine = try Engine.init();
    defer engine.deinit();

    var socket = try createSocket(8284);

    var context = Context{
        .type = undefined,
        .userptr = null,
        .handler = testingHandler,
    };

    try engine.do_accept_multishot(socket, &context);
    try engine.do_close(socket, &context);
    _ = try engine.flush();
}
