//! cli_runner.zig
//!
//! test runner for cli commands
//! simulates stdin using a provided string, and capture stdout & stderr using dynamically allocated `ArrayList`
//! so that the caller may perform any test-time checks
//! not meant to use for shelling out CLI commands

const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const command = @import("command.zig");
const context = @import("context.zig");

const RunResult = struct {
    allocator: std.mem.Allocator,
    stdout: []const u8,
    stderr: []const u8,
    err: ?anyerror = null,

    fn deinit(self: RunResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

const CliRunner = struct {
    cmd: *const command.CommandStruct,

    fn init(comptime c: command.CommandStruct) CliRunner {
        return CliRunner{
            .cmd = &c,
        };
    }

    fn run(comptime self: CliRunner, allocator: std.mem.Allocator, args: []const u8, input: []const u8) RunResult {
        var itr = try tokenizer.StringIterator.initAllocator(allocator, args);

        const arena = std.heap.ArenaAllocator(allocator);
        defer arena.deinit();

        var stdin = std.Io.Reader.fixed(input);
        var stdout = std.Io.Writer.Allocating.init(allocator);
        var stderr = std.Io.Writer.Allocating.init(allocator);

        const ctx = context.Context{
            .io = std.testing.io,
            .gpa = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .environ_map = std.testing.environ.createMap(allocator),
            .stdin = &stdin,
            .stdout = &stdout.writer,
            .stderr = &stderr.writer,
        };

        const result = self.cmd.invoke(ctx, itr.asTokenizer());

        var ret = RunResult{
            .allocator = allocator,
            .stdout = try stdout.toOwnedSlice(),
            .stderr = try stderr.toOwnedSlice(),
        };
        _ = try result catch |err| {
            ret.err = err;
        };
        return ret;
    }
};
