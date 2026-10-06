const std = @import("std");

pub const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: std.process.Environ.Map,

    pub fn initTest() Context {
        return Context{
            .io = std.testing.io,
            .gpa = std.testing.allocator,
            .environ_map = std.testing.environ.createMap(std.testing.allocator),
        };
    }

    pub fn init(i: std.process.Init) Context {
        return Context{
            .io = i.io,
            .gpa = i.gpa,
            .environ_map = i.environ_map,
        };
    }
};
