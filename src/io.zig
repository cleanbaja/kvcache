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

pub const IoResultType = switch (builtin.target.os.tag) {
    .linux => linux.IoResultType,
    else => @compileError("no IO layer for platform..."),
};

pub const Command = switch (builtin.target.os.tag) {
    .linux => linux.Command,
    else => @compileError("no IO layer for platform..."),
};

pub const UserData = switch (builtin.target.os.tag) {
    .linux => linux.UserData,
    else => @compileError("no IO layer for platform..."),
};

pub const createSocket = switch (builtin.target.os.tag) {
    .linux => linux.createSocket,
    else => @compileError("no IO layer for platform..."),
};
