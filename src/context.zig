//! context.zig
//!
//! structure to hold important utilities and interfaces while abstracting away the `std.process.Init` structure
//! allows us to execute a command in different contexts where `init` is not available e.g. testing

const std = @import("std");

fn ContextMapContainer(comptime T: type) type {
    return struct { value: T };
}

pub const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,

    arena: *std.heap.ArenaAllocator,
    environ_map: *std.process.Environ.Map,

    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,

    kv: *std.StringHashMap(*const anyopaque),

    pub fn initForProcess(init: std.process.Init, stdin_reader: *std.Io.Reader, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) Context {
        const kv = try init.arena.allocator().create(std.StringHashMap(*const anyopaque));
        kv.* = .init(init.arena.allocator());
        return Context{
            .io = init.io,
            .gpa = init.gpa,
            .arena = init.arena,
            .environ_map = init.environ_map,
            .stdin = stdin_reader,
            .stdout = stdout_writer,
            .stderr = stderr_writer,
            .kv = kv,
        };
    }

    /// register a value with the context
    /// caller is responsible for ensuring the object is properly
    /// allocated in memory and accessible to later callers
    pub fn put(self: Context, k: []const u8, v: anytype) !void {
        const ptr = try self.arena.allocator().create(ContextMapContainer(@TypeOf(v)));
        ptr.* = .{ .value = v };
        try self.kv.put(k, @ptrCast(ptr));
    }

    /// fetch a value stored in our context
    pub fn get(self: Context, comptime T: type, k: []const u8) ?T {
        const ptr = @as(*const ContextMapContainer(T), @ptrCast(@alignCast(self.kv.get(k) orelse return null)));
        return ptr.*.value;
    }
};
