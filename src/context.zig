//! context.zig
//!
//! structure to hold important utilities and interfaces while abstracting away the `std.process.Init` structure
//! allows us to execute a command in different contexts where `init` is not available e.g. testing

const std = @import("std");
const util = @import("util.zig");

pub const MockedContext = struct {
    ctx: *Context,
    stdout_buf: *std.Io.Writer.Allocating,
    stderr_buf: *std.Io.Writer.Allocating,

    pub fn context(self: MockedContext) Context {
        return self.ctx;
    }

    pub fn initTest(env_vars: []const struct { []const u8, []const u8 }, stdin: []const u8) !MockedContext {
        return .init(std.testing.io, std.testing.allocator, env_vars, stdin);
    }

    pub fn init(io: std.Io, allocator: std.mem.Allocator, env_vars: []const struct { []const u8, []const u8 }, stdin_buf: []const u8) !MockedContext {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);

        const env = try allocator.create(std.process.Environ.Map);
        env.* = .init(allocator);
        for (env_vars) |pair| try env.put(pair.@"0", pair.@"1");

        const stdin = try allocator.create(std.Io.Reader);
        stdin.* = .fixed(stdin_buf);

        const stdout_buf = try allocator.create(std.Io.Writer.Allocating);
        stdout_buf.* = .init(allocator);

        const stderr_buf = try allocator.create(std.Io.Writer.Allocating);
        stderr_buf.* = .init(allocator);

        const ctx = try allocator.create(Context);
        ctx.* = .init(io, allocator, arena, env, stdin, &stdout_buf.writer, &stderr_buf.writer);

        return .{
            .ctx = ctx,
            .stdout_buf = stdout_buf,
            .stderr_buf = stderr_buf,
        };
    }

    pub fn getOutput(self: MockedContext, allocator: std.mem.Allocator) !struct { []const u8, []const u8 } {
        return .{
            self.stdout_buf.toOwnedSlice(allocator),
            self.stderr_buf.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: MockedContext) void {
        self.ctx.arena.deinit();
        self.ctx.gpa.destroy(self.ctx.arena);

        self.ctx.environ_map.deinit();
        self.ctx.gpa.destroy(self.ctx.environ_map);

        self.ctx.gpa.destroy(self.ctx.stdin);

        self.stdout_buf.deinit();
        self.ctx.gpa.destroy(self.stdout_buf);
        self.stderr_buf.deinit();
        self.ctx.gpa.destroy(self.stderr_buf);

        self.ctx.deinit();
        self.ctx.gpa.destroy(self.ctx);
    }
};

pub const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,

    arena: *std.heap.ArenaAllocator,
    environ_map: *const std.process.Environ.Map,

    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,

    kv: *std.StringHashMap(*const anyopaque),

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
        env: *const std.process.Environ,
        stdin_reader: *std.Io.Reader,
        stdout_writer: *std.Io.Writer,
        stderr_writer: *std.Io.Writer,
    ) !Context {
        const kv = try allocator.create(std.StringHashMap(*const anyopaque));
        kv.* = .init(allocator);

        return .{
            .io = io,
            .gpa = allocator,

            .arena = arena,
            .environ_map = env,

            .stdin = stdin_reader,
            .stdout = stdout_writer,
            .stderr = stderr_writer,
        };
    }

    pub fn initForProcess(process_init: std.process.Init, stdin_reader: *std.Io.Reader, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !Context {
        return .init(process_init.io, process_init.gpa, process_init.arena, process_init.environ_map, stdin_reader, stdout_writer, stderr_writer);
    }

    pub fn deinit(self: Context) void {
        self.kv.deinit(self.gpa);
        self.gpa.destroy(self.kv);
    }

    /// register a value with the context
    pub fn put(self: Context, k: []const u8, v: anytype) !void {
        try self.kv.put(k, util.toOpaquePtr(self.arena, v));
    }

    /// fetch a value stored in our context
    pub fn get(self: Context, comptime T: type, k: []const u8) ?T {
        return util.fromOpaquePtr(T, self.kv.get(k) orelse return null);
    }
};
