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
const group = @import("group.zig");
const types = @import("types.zig");

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
    command_or_group: group.CommandOrGroup,

    pub inline fn init(comptime c: anytype) CliRunner {
        return CliRunner{
            .command_or_group = group.CommandOrGroup.init(c),
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

        const ctx: context.MockedContext = try .init(io, allocator, cfg.stdin, cfg.env);
        defer ctx.deinit();

        const result = self.command_or_group.invoke(ctx.context(), itr.asTokenizer());

        const stdout, const stderr = try ctx.getOutput();
        var ret = RunResult{
            .allocator = &allocator,
            .stdout = stdout,
            .stderr = stderr,
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

const outputStream = enum {
    stdout,
    stderr,
};

const echoTestCommand = command.Command("echo_test_command", "basic test command to print out data received by the handler")
    .option(outputStream, "which stream to output to", .{ .long = "--print-to", .default = outputStream.stdout })
    .option([]const u8, "echo the contents of this flag's arguments", .{ .long = "--echo-me", .short = "-e" })
    .argument([]const u8, "command line contents to echo", .{ .kind = .Variadic })
    .handler(handler);

fn handler(ctx: context.Context, print_to: outputStream, echo_opn: ?[]const u8, echo_args: []const []const u8) !void {
    const writer = switch (print_to) {
        .stdout => ctx.stdout,
        .stderr => ctx.stderr,
    };

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
    for (echo_args) |echo_arg| if (echo_arg.len > 0) try writer.print("{s}\n", .{echo_arg});
    try writer.flush();
}

test "command_help_message" {
    const expected =
        \\basic test command to print out data received by the handler
        \\
        \\USAGE:
        \\  echo_test_command [OPTION]... [ARG]...
        \\
        \\ARGUMENTS:
        \\  *: TEXT                     command line contents to echo
        \\
        \\OPTIONS:
        \\         --print-to=outputStream
        \\                              which stream to output to
        \\  -e,    --echo-me=TEXT       echo the contents of this flag's arguments
        \\
        \\
    ;
    const runner = CliRunner.init(echoTestCommand);
    try runner.runTest(RunnerConfig{
        .args = "--help",
    }, RunResult{
        .stderr = expected,
    });
}

test "command_runner_stdin" {
    const runner = CliRunner.init(echoTestCommand);
    try runner.runTest(RunnerConfig{
        .args = "\"\"",
        .stdin = "this is stdin",
    }, RunResult{
        .stdout = "this is stdin\n",
    });
}

test "command_runner_to_stderr" {
    const runner = CliRunner.init(echoTestCommand);
    try runner.runTest(RunnerConfig{
        .args = "\"\" --print-to stderr",
        .stdin = "this goes to stderr",
    }, RunResult{
        .stderr = "this goes to stderr\n",
    });
}

test "command_runner_arg" {
    const runner = CliRunner.init(echoTestCommand);
    try runner.runTest(RunnerConfig{
        .args = "this is the argument",
    }, RunResult{
        .stdout = "this\nis\nthe\nargument\n",
    });
}

test "command_runner_opt" {
    const runner = CliRunner.init(echoTestCommand);
    try runner.runTest(RunnerConfig{
        .args = "\"\" --echo-me \"this is an option\"",
    }, RunResult{
        .stdout = "this is an option\n",
    });
}

test "command_runner_env" {
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

const foo_cmd = command.Command("foo", "echos argument prepended with 'foo'")
    .argument(types.Type.LINE, "contents to echo", .{})
    .handler(foo);
fn foo(ctx: context.Context, arg: []const u8) !void {
    try ctx.stdout.print("foo {s}", .{arg});
    try ctx.stdout.flush();
}

const bar_cmd = command.Command("bar", "echos argument prepended with 'bar'")
    .argument(types.Type.LINE, "contents to echo", .{})
    .handler(bar);
fn bar(ctx: context.Context, arg: []const u8) !void {
    try ctx.stdout.print("bar {s}", .{arg});
    try ctx.stdout.flush();
}

const baz_cmd = command.Command("baz", "echos argument prepended with 'baz'")
    .argument(types.Type.LINE, "contents to echo", .{})
    .handler(baz);
fn baz(ctx: context.Context, arg: []const u8) !void {
    try ctx.stdout.print("baz {s}", .{arg});
    try ctx.stdout.flush();
}

const nested_group = group.Group("nested-group", "a group of commands within a group of commands").subcommand(baz_cmd);

const command_group = group.Group("test-group", "a top-level group of commands")
    .subcommand(foo_cmd)
    .subcommand(bar_cmd)
    .subgroup(nested_group);

test "command_group_help_message" {
    const expected =
        \\a top-level group of commands
        \\
        \\USAGE:
        \\  test-group [COMMAND]
        \\
        \\COMMANDS:
        \\  foo                         echos argument prepended with 'foo'
        \\  bar                         echos argument prepended with 'bar'
        \\  nested-group                a group of commands within a group of commands
        \\
        \\
    ;
    const runner = CliRunner.init(command_group);
    try runner.runTest(RunnerConfig{ .args = "--help" }, RunResult{ .stderr = expected });
}

test "command_group_missing_command" {
    const expected =
        \\error: please specify a subcommand
        \\Try using '--help' to show more information
        \\
    ;
    const runner = CliRunner.init(command_group);
    try runner.runTest(RunnerConfig{ .args = "nested-group" }, RunResult{ .stderr = expected });
}

test "command_group_unknonwn_command" {
    const expected =
        \\error: unrecognized command 'baz'
        \\Try using '--help' to show more information
        \\
    ;
    const runner = CliRunner.init(command_group);
    try runner.runTest(RunnerConfig{ .args = "baz" }, RunResult{ .stderr = expected });
}

test "command_group_command_help_message" {
    const expected =
        \\echos argument prepended with 'baz'
        \\
        \\USAGE:
        \\  baz [ARG]...
        \\
        \\ARGUMENTS:
        \\  0: LINE                     contents to echo
        \\
        \\
    ;
    const runner = CliRunner.init(command_group);
    try runner.runTest(RunnerConfig{ .args = "nested-group baz \"argument\" --help" }, RunResult{ .stderr = expected });
}

test "command_group" {
    const runner = CliRunner.init(command_group);
    try runner.runTest(RunnerConfig{ .args = "foo \"hello world\"" }, RunResult{ .stdout = "foo hello world" });
    try runner.runTest(RunnerConfig{ .args = "bar \"hello world\"" }, RunResult{ .stdout = "bar hello world" });
    try runner.runTest(RunnerConfig{ .args = "nested-group baz \"hello world\"" }, RunResult{ .stdout = "baz hello world" });
}

const PrintsContextValue = command.Command("print-ctx", "prints the value help by specified keys in the shared CLI context")
    .argument(types.hintedType([]const u8, "KEY"), "the name of the key to lookup", .{})
    .handler(printContext);

fn printContext(ctx: context.Context, k: []const u8) !void {
    if (ctx.get([]const u8, k)) |v| {
        try ctx.stdout.print("key '{s}' points to value '{s}'!\n", .{ k, v });
    } else {
        try ctx.stdout.print("key '{s}' doesn't exist\n", .{k});
    }
    try ctx.stdout.flush();
}

const ContextCommandGroup = group.Group("ctx-group", "a command group which persists values to subcommands via the shared context")
    .option(types.hintedType([]const u8, "VALUE"), "writes the provided value to key 'foo' in the context", .{ .long = "--foo" })
    .subcommand(PrintsContextValue)
    .handler(setContext);

fn setContext(ctx: context.Context, foo_opt: ?[]const u8) !void {
    if (foo_opt) |v| {
        try ctx.put("foo", v);
    }
}

test "group_context" {
    const runner = CliRunner.init(ContextCommandGroup);

    try runner.runTest(.{ .args = "--foo bar print-ctx foo" }, .{ .stdout = "key 'foo' points to value 'bar'!\n" });
    try runner.runTest(.{ .args = "print-ctx foo" }, .{ .stdout = "key 'foo' doesn't exist\n" });
    try runner.runTest(.{ .args = "--foo bar print-ctx bar" }, .{ .stdout = "key 'bar' doesn't exist\n" });
}

test "group_option_help" {
    const expected =
        \\a command group which persists values to subcommands via the shared context
        \\
        \\USAGE:
        \\  ctx-group [OPTION]... [COMMAND]
        \\
        \\COMMANDS:
        \\  print-ctx                   prints the value help by specified keys in the 
        \\                                shared CLI context 
        \\
        \\OPTIONS:
        \\         --foo=VALUE          writes the provided value to key 'foo' in the 
        \\                                context 
        \\
        \\
    ;

    const runner = CliRunner.init(ContextCommandGroup);
    try runner.runTest(.{ .args = "--help" }, .{ .stderr = expected });
}
