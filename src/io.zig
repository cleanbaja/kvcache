const builtin = @import("builtin");
const linux = @import("io/linux.zig");

/// An abstraction over a operating system's async IO
/// layer, which queues/completes IO operations.
pub const Engine = switch (builtin.target.os.tag) {
    .linux => linux.Engine,
    else => @compileError("no IO layer for platform..."),
};

/// Represents a handle to a kernel object (FDs on unix).
pub const Handle = switch (builtin.target.os.tag) {
    .linux => linux.Handle,
    else => @compileError("no IO layer for platform..."),
};

/// List of IO operations supported by the engine.
pub const IoType = switch (builtin.target.os.tag) {
    .linux => linux.IoType,
    else => @compileError("no IO layer for platform..."),
};

/// Information from the kernel on a completed operation.
pub const Result = switch (builtin.target.os.tag) {
    .linux => linux.Result,
    else => @compileError("no IO layer for platform..."),
};

/// Information associated with a queued operation, and
/// returned to the caller on completion...
pub const Context = switch (builtin.target.os.tag) {
    .linux => linux.Context,
    else => @compileError("no IO layer for platform..."),
};

/// Creates a kernel socket for networking.
pub const createSocket = switch (builtin.target.os.tag) {
    .linux => linux.createSocket,
    else => @compileError("no IO layer for platform..."),
};
