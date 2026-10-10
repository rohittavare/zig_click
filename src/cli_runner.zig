//! cli_runner.zig
//!
//! test runner for cli commands
//! simulates stdin using a provided string, and capture stdout & stderr using dynamically allocated `ArrayList`
//! so that the caller may perform any test-time checks
//! not meant to use for shelling out CLI commands

const builtin = @import("builtin");
const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const command = @import("command.zig");
const context = @import("context.zig");

/// stored the output & potential errors of a command run
/// since output is generated at runtime & allocated by the runner
/// we have to point to the exact allocator used by runner when we deallocate
pub const RunResult = struct {
    err: ?anyerror = null,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    allocator: ?*const std.mem.Allocator = null,

    fn deinit(self: RunResult) void {
        if (self.allocator) |allocator| {
            allocator.free(self.stdout);
            allocator.free(self.stderr);
        }
    }
};

/// config is used to store command inputs
/// while supporting default values
/// supported inputs are:
/// - argument string
/// - stdin input string
/// - environment variable mappings
/// e.g. most users won't care about setting env vars
///      many may not care about stdin
pub const RunnerConfig = struct {
    args: []const u8 = "",
    stdin: []const u8 = "",
    env: []const struct { []const u8, []const u8 } = &.{},
};

/// Runs a command with provided inputs (see `RunnerConfig`)
/// captures & returns the command outputs
/// note: output capture only works on the stdout & stderr writers provided in context
///       `std.debug.print()` or any other writers (to file or stdout/err) cannot be captured (yet)
/// note: currently only supports running in a test environment
pub const CliRunner = struct {
    cmd: *const command.CommandStruct,

    pub inline fn init(comptime c: command.CommandStruct) CliRunner {
        return CliRunner{
            .cmd = &c,
        };
    }

    /// constructs the necessary inputs: stdin, argument tokenizer, allocators, env maps
    /// from user provided values in the config, and IO & allocator provided in parameters
    ///
    /// commands are run using the `invoke` hook and providing a prebuilt context and args token iterator
    /// stdin is simulated via a fixed string reader from the user-provided config
    /// stdout & stderr are captured via an allocator-backed writer, whose contents are returned as a buffer to the caller
    pub fn run(comptime self: CliRunner, io: std.Io, allocator: std.mem.Allocator, cfg: RunnerConfig) !RunResult {
        var itr = try tokenizer.StringIterator.init(allocator, cfg.args);
        defer itr.deinit(allocator);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var stdin = std.Io.Reader.fixed(cfg.stdin);
        var stdout = std.Io.Writer.Allocating.init(allocator);
        var stderr = std.Io.Writer.Allocating.init(allocator);

        var env_map = std.process.Environ.Map.init(allocator);
        defer env_map.deinit();
        for (cfg.env) |env_pair| try env_map.put(env_pair.@"0", env_pair.@"1");

        const ctx = context.Context{
            .io = io,
            .gpa = allocator,

            .arena = &arena,
            .environ_map = &env_map,

            .stdin = &stdin,
            .stdout = &stdout.writer,
            .stderr = &stderr.writer,
        };

        const result = self.cmd.invoke(ctx, itr.asTokenizer());

        var ret = RunResult{
            .allocator = &allocator,
            .stdout = try stdout.toOwnedSlice(),
            .stderr = try stderr.toOwnedSlice(),
        };
        _ = result catch |err| {
            ret.err = err;
        };
        return ret;
    }

    pub fn runTest(comptime self: CliRunner, cfg: RunnerConfig, expected: RunResult) !void {
        if (!builtin.is_test) @compileError("not testing");
        const allocator = std.testing.allocator;
        const io = std.testing.io;

        const actual = try self.run(io, allocator, cfg);
        defer actual.deinit();

        try std.testing.expectEqual(expected.err, actual.err);
        try std.testing.expectEqualStrings(expected.stdout, actual.stdout);
        try std.testing.expectEqualStrings(expected.stderr, actual.stderr);
    }
};

const echoTestCommand = command.Command("echo_test_command", "")
    .flag("--stderr/--stdout")
    .option("--echo-me,-e", ?[]const u8, null)
    .argument([]const u8)
    .handler(handler);

fn handler(ctx: context.Context, use_stderr: bool, echo_opn: ?[]const u8, echo_arg: []const u8) !void {
    const writer = if (use_stderr) ctx.stderr else ctx.stdout;

    // echo stdin
    const stdin = try ctx.stdin.allocRemaining(ctx.gpa, .unlimited);
    defer ctx.gpa.free(stdin);
    if (stdin.len > 0) try writer.print("{s}\n", .{stdin});
    // echo env vars
    for (ctx.environ_map.keys(), ctx.environ_map.values()) |k, v| {
        try writer.print("{s}={s}\n", .{ k, v });
    }
    // echo opn
    if (echo_opn) |txt| {
        try writer.print("{s}\n", .{txt});
    }
    // echo arg
    if (echo_arg.len > 0) try writer.print("{s}\n", .{echo_arg});
    try writer.flush();
}

test "test_command_runner_stdin" {
    const runner = CliRunner.init(echoTestCommand);
    try runner.runTest(RunnerConfig{
        .args = "\"\"",
        .stdin = "this is stdin",
    }, RunResult{
        .stdout = "this is stdin\n",
    });
}

test "test_command_runner_to_stderr" {
    const runner = CliRunner.init(echoTestCommand);
    try runner.runTest(RunnerConfig{
        .args = "\"\" --stderr",
        .stdin = "this goes to stderr",
    }, RunResult{
        .stderr = "this goes to stderr\n",
    });
}

test "test_command_runner_arg" {
    const runner = CliRunner.init(echoTestCommand);
    try runner.runTest(RunnerConfig{
        .args = "\"this is an argument\"",
    }, RunResult{
        .stdout = "this is an argument\n",
    });
}

test "test_command_runner_opt" {
    const runner = CliRunner.init(echoTestCommand);
    try runner.runTest(RunnerConfig{
        .args = "\"\" --echo-me \"this is an option\"",
    }, RunResult{
        .stdout = "this is an option\n",
    });
}

test "test_command_runner_env" {
    const runner = CliRunner.init(echoTestCommand);
    try runner.runTest(RunnerConfig{
        .args = "\"\"",
        .env = &.{
            .{ "HELLO", "world" },
            .{ "FOO", "bar" },
        },
    }, RunResult{
        .stdout =
        \\HELLO=world
        \\FOO=bar
        \\
        ,
    });
}
