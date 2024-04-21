const builtin = @import("builtin");

const linux = @import("io/linux.zig");

pub const Engine = switch (builtin.target.os.tag) {
    .linux => linux.Engine,
    else => @compileError("no IO layer for platform..."),
};

pub const Handle = switch (builtin.target.os.tag) {
    .linux => linux.Handle,
    else => @compileError("no IO layer for platform..."),
};

pub const IoType = switch (builtin.target.os.tag) {
    .linux => linux.IoType,
    else => @compileError("no IO layer for platform..."),
};

pub const Result = switch (builtin.target.os.tag) {
    .linux => linux.Result,
    else => @compileError("no IO layer for platform..."),
};

pub const Context = switch (builtin.target.os.tag) {
    .linux => linux.Context,
    else => @compileError("no IO layer for platform..."),
};

pub const createSocket = switch (builtin.target.os.tag) {
    .linux => linux.createSocket,
    else => @compileError("no IO layer for platform..."),
};
