//! # Linux IO Interface
//!
//! The linux IO interface for kvcache uses IO Uring,
//! which is a relatively standardized method of
//! Async IO (designed to replace linux AIO).
//!
//! ## Features
//!
//! This implementation takes advantage of a few
//! extensions to IO Uring, which is why the minimum
//! kernel verison supported is around ~5.19. However,
//! I recommend you use kernel 6.1 or higher for some
//! key improvements/features introduced to IO Uring.
//!
//! The required features are as follows:
//!  - IORING_FEAT_CQE_SKIP: Don't generate CQEs for
//!    certain SQE calls, saves space on the CQE.
//!    (available since kernel 5.17)
//!
//!  - IORING_FEAT_NODROP: The kernel will *almost* never
//!    drop CQEs, instead queueing them internally and
//!    returning -EBUSY when the internal buffer is full.
//!    (available since kernel 5.19)
//!
//!  - Ring Mapped Buffers: This is not a new feature
//!    per se, but rather a improvement on an already
//!    existing feature (registered buffers). It adds
//!    an ring abstraction which makes buffer management
//!    *very* seamless...
//!    (available since kernel 5.19)
//!
//! ## Docs
//!
//! Below are some great resources on IO Uring, which I
//! recommend you take a look at before reading this code...
//!
//! (ofcourse, the best resource are the manpages)
//!
//! - [Unixism IO Uring guide](https://unixism.net/loti/)
//! - [Awesome IO Uring](https://github.com/noteflakes/awesome-io_uring)
//!

const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const linux = std.os.linux;

const MAX_ENTRIES = 64;

pub const Handle = linux.fd_t;

pub const IoType = enum(u64) {
    nop = 0,
    accept,
    read,
    write,
    close,
    recv,
};

pub const Result = struct {
    res: i32,
    flags: u32,
    buffer: ?[]u8,
};

pub const Context = struct {
    type: IoType,
    handler: *const fn (kind: IoType, ctx: ?*anyopaque, result: Result) anyerror!void,
    userptr: ?*anyopaque,
};

pub const Engine = struct {
    ring: linux.IoUring,
    buffers: linux.IoUring.BufferGroup,
    allocator: std.mem.Allocator,
    rawbufs: []u8,
    pending: usize,

    /// Setup a IO Engine, creating internal structures
    /// and registering them with the kernel.
    pub fn init(allocator: std.mem.Allocator) !Engine {
        ensureKernelVersion(.{ .major = 5, .minor = 19, .patch = 0 }) catch {
            std.debug.panic("kvcache: kernel is too old (min kernel supported is 6.1)\n", .{});
        };

        const flags: u32 = linux.IORING_SETUP_DEFER_TASKRUN | linux.IORING_SETUP_SINGLE_ISSUER;

        var engine = Engine{
            .ring = try linux.IoUring.init(MAX_ENTRIES, flags),
            .buffers = undefined,
            .rawbufs = try allocator.alloc(u8, 512 * 1024),
            .allocator = allocator,
            .pending = 0,
        };

        engine.buffers = try linux.IoUring.BufferGroup.init(
            &engine.ring,
            0,
            engine.rawbufs,
            512,
            1024,
        );

        return engine;
    }

    /// Shutdown and destroy the IO Engine, freeing contexts.
    pub fn deinit(self: *Engine) void {
        self.ring.deinit();
        self.buffers.deinit();

        self.allocator.free(self.rawbufs);
    }

    /// Internal helper function for ensuring kernel is
    /// newer than the `min` version specified.
    fn ensureKernelVersion(min: std.SemanticVersion) !void {
        var uts: linux.utsname = undefined;
        const res = linux.uname(&uts);
        switch (linux.E.init(res)) {
            .SUCCESS => {},
            else => |errno| return posix.unexpectedErrno(errno),
        }

        const release = std.mem.sliceTo(&uts.release, 0);
        var current = try std.SemanticVersion.parse(release);
        current.pre = null; // don't check pre field

        if (min.order(current) == .gt) return error.SystemOutdated;
    }

    /// Internal helper for getting SQE entries, flushing the
    /// SQE queue until we are able to nab a entry.
    fn getEntry(self: *Engine) !*linux.io_uring_sqe {
        const entry = self.ring.get_sqe() catch |err| retry: {
            if (err != error.SubmissionQueueFull)
                return err;

            _ = try self.ring.submit();
            self.pending = 0;

            var sqe = self.ring.get_sqe();

            while (sqe == error.SubmissionQueueFull) {
                _ = try self.ring.submit();
                self.pending = 0;

                sqe = self.ring.get_sqe();
            }

            break :retry sqe;
        };

        self.pending += 1;

        return entry;
    }

    /// Flushes the SQE queue by entering the kernel
    pub fn flush(self: *Engine, comptime wait: bool) !void {
        if (wait) {
            self.pending -= try self.ring.submit_and_wait(1);
        } else {
            self.pending -= try self.ring.submit();
        }
    }

    /// Enters the main runloop for the IO Uring, which looks
    /// like this:
    ///
    ///   Enter kernel to flush -> loop over completions -> start over
    ///
    /// Exits only on errors thrown, otherwise waits in-kernel for ops
    /// to complete...
    ///
    pub fn enter(self: *Engine) !void {
        while (true) {
            try self.flush(true);

            while (self.ring.cq_ready() > 0) {
                const cqe = try self.ring.copy_cqe();

                if (cqe.user_data > 0) {
                    var context: *Context = @ptrFromInt(cqe.user_data);

                    if (context.type == .recv) {
                        try context.handler(context.type, context.userptr, Result{
                            .res = cqe.res,
                            .flags = cqe.flags,
                            .buffer = self.buffers.get_cqe(cqe) catch null,
                        });

                        self.buffers.put_cqe(cqe) catch {};
                    } else {
                        try context.handler(context.type, context.userptr, Result{
                            .res = cqe.res,
                            .flags = cqe.flags,
                            .buffer = null,
                        });
                    }
                }
            }
        }
    }

    // --------------------------------
    //            Operators
    // --------------------------------

    pub fn do_nop(self: *Engine, ctx: ?*Context) !void {
        var sqe = try self.getEntry();
        sqe.prep_nop();

        // don't generate CQEs on success
        sqe.flags |= linux.IOSQE_CQE_SKIP_SUCCESS;

        if (ctx) |c| {
            c.type = .nop;
            sqe.user_data = @intFromPtr(c);
        }
    }

    pub fn do_read(self: *Engine, handle: Handle, buffer: []u8, offset: u64, ctx: *Context) !void {
        var sqe = try self.getEntry();
        sqe.prep_read(handle, buffer, offset);

        ctx.type = .read;
        sqe.user_data = @intFromPtr(ctx);
    }

    pub fn do_recv(self: *Engine, handle: Handle, flags: u32, ctx: *Context) !void {
        var sqe = try self.getEntry();
        sqe.prep_rw(.RECV, handle, 0, 0, 0);

        sqe.rw_flags = flags;
        sqe.flags |= linux.IOSQE_BUFFER_SELECT;
        sqe.buf_index = self.buffers.group_id;

        ctx.type = .recv;
        sqe.user_data = @intFromPtr(ctx);
    }

    pub fn do_write(self: *Engine, handle: Handle, buffer: []const u8, offset: u64, ctx: ?*Context) !void {
        var sqe = try self.getEntry();
        sqe.prep_write(handle, buffer, offset);

        // don't generate CQEs on success
        sqe.flags |= linux.IOSQE_CQE_SKIP_SUCCESS;

        if (ctx) |c| {
            c.type = .write;
            sqe.user_data = @intFromPtr(c);
        }
    }

    pub fn do_close(self: *Engine, handle: Handle, ctx: ?*Context) !void {
        var sqe = try self.getEntry();
        sqe.prep_close(@intCast(handle));

        // don't generate CQEs on success
        sqe.flags |= linux.IOSQE_CQE_SKIP_SUCCESS;

        if (ctx) |c| {
            c.type = .close;
            sqe.user_data = @intFromPtr(c);
        }
    }

    pub fn do_accept(self: *Engine, handle: Handle, ctx: *Context) !void {
        var sqe = try self.getEntry();
        sqe.prep_accept(handle, null, null, 0);

        sqe.user_data = @intFromPtr(ctx);
        ctx.type = .accept;
    }
};

/// Creates a server socket, bind it and listen on it.
pub fn createSocket(port: u16) !Handle {
    const sockfd = try posix.socket(posix.AF.INET6, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
    errdefer posix.close(sockfd);

    // allow for multiple listeners on 1 thread
    try posix.setsockopt(
        sockfd,
        posix.SOL.SOCKET,
        posix.SO.REUSEPORT,
        &std.mem.toBytes(@as(c_int, 1)),
    );

    // enable ipv4 as well
    try posix.setsockopt(
        sockfd,
        posix.IPPROTO.IPV6,
        linux.IPV6.V6ONLY,
        &std.mem.toBytes(@as(c_int, 0)),
    );

    const addr = try std.net.Address.parseIp6("::0", port);

    try posix.bind(sockfd, &addr.any, @sizeOf(posix.sockaddr.in6));
    try posix.listen(sockfd, std.math.maxInt(u31));

    return sockfd;
}

fn testingHandler(kind: IoType, ctx: ?*anyopaque, result: Result) anyerror!void {
    _ = ctx;

    if (!builtin.is_test) {
        @compileError("attempt to call 'testingHandler()' outside of zig test!");
    }

    switch (kind) {
        .read, .write => {
            try std.testing.expect(result.res == 512); // bytes read/written
        },

        .accept => {
            try std.testing.expect(result.res >= 0); // res < 0 means error
            try std.testing.expect(result.flags == 2); // IORING_CQE_F_MORE
        },

        else => unreachable, // CQEs shouldn't be generated (and when they are, its an error regardless)
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

    // don't wait for a CQE since nop doesn't generate them...
    try engine.flush(false);
}

test "uring read/write/close" {
    var engine = try Engine.init();
    defer engine.deinit();

    const raw_handle = try std.fs.cwd().createFile("testing.txt", .{ .read = true });
    const handle = raw_handle.handle;

    const write_buffer = try std.testing.allocator.alloc(u8, 512);
    const read_buffer = try std.testing.allocator.alloc(u8, 512);
    defer std.testing.allocator.free(write_buffer);
    defer std.testing.allocator.free(read_buffer);

    @memset(write_buffer, 0xE9);

    var read_context = Context{
        .type = undefined,
        .userptr = null,
        .handler = testingHandler,
    };

    try engine.do_write(handle, write_buffer, 0, null);
    try engine.do_read(handle, read_buffer, 0, &read_context);
    try engine.do_close(handle, null);

    try engine.enter();

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

    const socket = try createSocket(8284);

    var context = Context{
        .type = undefined,
        .userptr = null,
        .handler = testingHandler,
    };

    try engine.do_accept(socket, &context);
    try engine.do_close(socket, null);

    try engine.enter();
}
