//! context.zig
//!
//! structure to hold important utilities and interfaces while abstracting away the `std.process.Init` structure
//! allows us to execute a command in different contexts where `init` is not available e.g. testing

const std = @import("std");

pub const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,

    arena: *std.heap.ArenaAllocator,
    environ_map: *std.process.Environ.Map,

    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,

    fn initForProcess(init: std.process.Init, stdin_reader: *std.Io.Reader, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) Context {
        return Context{
            .io = init.io,
            .gpa = init.gpa,
            .arena = init.arena,
            .environ_map = init.environ_map,
            .stdin = stdin_reader,
            .stdout = stdout_writer,
            .stderr = stderr_writer,
        };
    }
};
