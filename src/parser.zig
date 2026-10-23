//! parser.zig
//!
//! Parsing tools to interpret comptile-time flag declarations, used to build the CLI
//! and construct supported data types from string, used to construct arguments during runtime
//!
//! ## Understanding the Supported Inputs
//!
//! for the purposes of CLI arguments, optional inputs are specified using flags. These are represented as
//! a word or contiguous phrase prefixed by two dashes (long flag) - long flags can only contain alphanumeric, '-' and '_' characters
//! or an alphanumeric character prefixed by a single dash (short flag)
//!
//! arguments are positional - not specified by a flag, and are processed in the order declared
//! but can be mixed between options
//!
//! much of the behaviors of command processing is mostly based on [this blog post](https://nullprogram.com/blog/2020/08/01/)
//! (with the exception of optional argument options, which are not supported as of now).
//!
//! ## Understanding the Parser design and implementation
//!
//! In order to understand why the parser is built this way, we need to understand the purpose of this library. The goal is in three parts:
//! 1. command multiplexer - more than just being able to query inputs supplied to the CLI, we want to make it easy to construct CLI tools by automatically invoking the appropriate logic and routing inputs correctly
//! 2. functional interface - similar to python's `click` library, enable us to build a parser definition step by step. each group/command is constructed separately with their own args/options defined
//! 3. validate as much as possible at compiletime
//!
//! In python `click`, all commands/groups are automatically bound to a function by virtue of the interface built off function decorators.
//! This becomes the mechanism for `click` to know which logic to invoke when a (sub)command is specified and CLI inputs are routed through
//! the decorated function's parameters. Python allows us to invoke arbitrary functions using programmatically determined inputs by unpacking
//! a dict/tuple/list of keywords or values.
//!
//! Zig doesn't support function decorators, so in order to achieve (2) we take a functional approach, chaining methods together to one-by-one
//! regiser inputs from the command line, each method returning an updated `Parser` object. In Zig, return values which are not yet written
//! to a variable are `const`. When we chain a methods, parsers returned at each stem are `const` and cannot be manipulated. We need to
//! return a new parser based on the previous parser we built
//!
//! In order to achieve (1) we will need to invoke functions (which may be known at compile-time) but not known at the time of writing this library.
//! Python allows us to invoke arbitrary functions using programmatically determined inputs by unpacking a dict/tuple/list of keywords or values.
//! Thankfully zig allows us to invoke function pointers using the `@call()` builtin. In order to use this we need to supply our inputs as a tuple.
//!
//! How do we write code to call a function using a tuple, when we don't know what tuple we need to build, and the exact steps/values to build this tuple
//! may only be known at runtime? Our target tuple type is dependent on our function's signature, which is dependent on the registered CLI args/opts.
//! Since type data is only available at compile-time, it means we need our CLI args/opts to also be compile-time known. This give us a few nice synergies:
//! - functional-style chaining operates on `const` intermediate values, which avoid our users from declaring their CLI builders as `comptime var` or performing this work at runtime instead. Then can just assign the final value to `const` variable
//! - having the CLI fully defined at comptime allows us to validate the choice of features & settings at compile-time as well, allowing us to build for (3)
//!
//! However, working mostly in comptime provides a few challenges: the order of arguments supplied in the CLI is only runtime-known. How do we parse and build
//! the correct types when typing data is compile-time known, but input order (and what subcommands to invoke) is runtime known?
//!
//! We need to break down the parsing process into two steps:
//! 1. perform all type conversions and building in compile-time known blocks purely from the function signature i.e. `inline for`
//! 2. perform runtime work to identify supplied inputs and organize them into a deterministic shape as per (1)
//!
//! The `Field` class is responsible for holding type data and other associated option/argument characteristics in a compile-time known shape
//! These generate `FieldCaptureGroup`s which can freely be used and interacted at runtime to store raw un-parsed string tokens from the CLI
//! Since args & options can be specified in any order, and options can map to multiple flags we use 'Pointers' to map each flag & positional argument to its corresponding field
//! The ordering of `Field`s, `FieldCaptureGroup`s and Arg/Opt 'Pointers' all need to be consistent with each other to work at both compile-time and runtime.

const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const util = @import("util.zig");
const types = @import("types.zig");
const context = @import("context.zig");

/// function pointer for argument handlers
/// accepts Context and string inputs and returns the desired type
/// (or null if cannot be parsed)
fn arg_handler_t(comptime t: type) type {
    return *const fn (context.Context, []const u8) anyerror!?t;
}
/// slice of a particular type
fn arg_choice_t(comptime t: type) type {
    return []const t;
}
/// opaque pointer type
/// used to store values of known/mixed types
/// without needing generics/type embeded in the parent type
const any_t = *const anyopaque;

// ========== command and flag name validations ==========
/// command names are allowed alphanumeric characters, `-` and `_`
pub fn validCommandName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

test "valid_command_name" {
    const cases = .{
        .{ "h3llo-world_", true },
        .{ "", false },
        .{ "hello world", false },
    };
    for (cases) |case| {
        const input, const expected = case;
        try std.testing.expectEqual(expected, validCommandName(input));
    }
}

/// long flag name are specified using a decl that contains the long flag (with leading `--`)
/// a 'negative' flag can also be specified by specifying a second long flag separated by `/`
/// no other flags can be specified by the decl
///
/// this function parses the decl to retunr the flag (and negative flag if supplied)
/// returns null for incorrectly decl/flag name
///
/// not all parser options support a negative flag, but this helper does not differentiate
/// it is the caller's responsibility to validate the presence of a negative flag
fn parseLongOptDecl(decl: []const u8) ?struct { []const u8, ?[]const u8 } {
    var positive_flag: ?[]const u8 = null;
    var negative_flag: ?[]const u8 = null;
    var tokenized_flags = std.mem.splitScalar(u8, decl, '/');
    while (tokenized_flags.next()) |flag_decl| {
        // if our negative flag is already defined, it means we are looking at
        // a third supplied flag, whic is not allowed
        if (negative_flag) |_| return null;
        if (!std.mem.startsWith(u8, flag_decl, "--")) return null;
        if (flag_decl.len == 2) return null;
        for (flag_decl[3..]) |c| switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
            else => return null,
        };
        if (positive_flag) |_| {
            negative_flag = flag_decl;
        } else {
            positive_flag = flag_decl;
        }
    }
    return if (positive_flag) |flag| .{ flag, negative_flag } else null;
}

/// short flags are also specified using a decl similar to long flag, with the leading `-` included
/// same general behaviors and stipulations hold as `parseLongOptDecl`
fn parseShortOptDecl(decl: []const u8) ?struct { u8, ?u8 } {
    var positive_flag: ?u8 = null;
    var negative_flag: ?u8 = null;
    var tokenized_flags = std.mem.splitScalar(u8, decl, '/');
    while (tokenized_flags.next()) |flag_decl| {
        if (negative_flag) |_| return null;
        if (!std.mem.startsWith(u8, flag_decl, "-")) return null;
        if (flag_decl.len != 2) return null;
        switch (flag_decl[1]) {
            'a'...'z', 'A'...'Z', '0'...'9' => {},
            else => return null,
        }
        if (positive_flag) |_| {
            negative_flag = flag_decl[1];
        } else {
            positive_flag = flag_decl[1];
        }
    }
    return if (positive_flag) |flag| .{ flag, negative_flag } else null;
}

test "parse_long_flag_decl" {
    const cases = .{
        .{ "--hello-world", .{ "hello-world", null } },
        .{ "--h3ll0_w0rld", .{ "h3ll0_w0rld", null } },
        .{ "--yes/--no", .{ "yes", "no" } },
        .{ "", null },
        .{ "--yes --no", null },
        .{ "--yes/--no/--maybe", null },
        .{ "--yes/-no", null },
        .{ "--yes/--", null },
        .{ "--yes/", null },
        .{ "yes", null },
    };
    for (cases) |case| {
        const input, const expected = case;
        try std.testing.expectEqualDeep(expected, parseLongOptDecl(input));
    }
}

test "parse_short_flag_decl" {
    const cases = .{
        .{ "-o", .{ 'o', null } },
        .{ "-y/-n", .{ 'y', 'n' } },
        .{ "", null },
        .{ "-y -n", null },
        .{ "-y/-n/-m", null },
        .{ "-@", null },
        .{ "-y/-no", null },
        .{ "--y", null },
        .{ "-", null },
        .{ "-y/", null },
        .{ "y", null },
    };
    for (cases) |case| {
        const input, const expected = case;
        try std.testing.expectEqualDeep(expected, parseLongOptDecl(input));
    }
}

// ========== end command and flag name validations ==========

/// parse a token to the desired data type
/// only int, float, bool and string types supported natively
/// otherwise a custom handler is required to parse the data type
/// does not parse null values for optional types
/// returns null when the datatype is unsupported or failure during parsing
fn parseTokenNative(comptime t: type, token: []const u8) ?t {
    return switch (@typeInfo(t)) {
        .optional => |o| try parseTokenNative(o.child, token) orelse null,
        .int => std.fmt.parseInt(t, token, 10) catch null,
        .float => std.fmt.parseFloat(t, token) catch null,
        .bool => if (std.mem.eql(u8, token, "true")) true else if (std.mem.eql(u8, token, "false")) false else null,
        // currently only support strings through slice of const u8
        .pointer => |p| if (p.size == .slice and p.attrs.@"const" and p.child == u8) token else null,
        .@"enum" => std.meta.stringToEnum(t, token),
        else => null,
    };
}

/// when parsing a token, users may specify a choice of legal values as well as a custom parsing function
/// the parsing function may accept a context object to do any necessary memory allocations
/// if no parsing function is provided, tokens will be parsed using `parseTokenNative` and unsupported types will automatically return null
fn parseToken(comptime t: type, ctx: context.Context, token: []const u8, choice: ?arg_choice_t(t), handler: ?arg_handler_t(t)) !?t {
    // check the token is within the choices
    const val: t = if (handler) |h| try h(ctx, token) else parseTokenNative(t, token);
    return if (choice) |c| if (std.mem.findScalar(t, c, val)) val else null;
}

const testEnum = enum {
    foo,
    bar,
};

fn split_str(ctx: context.Context, token: []const u8) !?[]const []const u8 {
    const n_commas = std.mem.countScalar(u8, token, ',');
    const elements = try ctx.arena.allocator().alloc([]const u8, n_commas + 1);
    var itr = std.mem.splitScalar(u8, token, ',');
    var i: usize = 0;
    while (itr.next()) |e| {
        elements[i] = e;
        i += 1;
    }
    return elements;
}

test "parse_token" {
    const cases = .{
        .{ i32, "10", null, null, @as(i32, 10) },
        .{ f16, "4.5", null, null, @as(f16, 4.5) },
        .{ bool, "true", null, null, true },
        .{ bool, "false", null, null, false },
        .{ []const u8, "hello", null, null, "hello" },
        // handle optional type
        .{ ?bool, "true", null, null, true },
        .{ ?u8, "1000", null, null, null },
        // enum
        .{ testEnum, "foo", null, null, testEnum.foo },
        .{ testEnum, "baz", null, null, null }, // no match
        // fail parsing native types
        .{ u8, "1000", null, null, null },
        .{ f16, "null", null, null, null },
        .{ bool, "foo", null, null, null },
        // choices
        .{ []const u8, "foo", &.{ "foo", "bar" }, null, "foo" },
        .{ []const u8, "baz", &.{ "foo", "bar" }, null, null }, // invalid choice
        // handler
        .{ []const []const u8, "hello,world", null, &split_str, &.{ "hello", "world" } },
    };

    const ctx: context.MockedContext = .initTest(.{}, "");
    defer ctx.deinit();

    inline for (cases) |case| {
        const t: type = case.@"0";
        _, const token: []const u8, const choice: ?[]const t, const handler: ?fn (context.Context, []const u8) anyerror!?t, const expected: t = case;
        try std.testing.expectEqualDeep(expected, try parseToken(t, ctx.context(), token, choice, handler));
    }
}

// ========== Begin Parser ==========

/// We need the following information about each parser element:
/// +------------------------------------------------------------------------------------+
/// |          | parameters |                         config                             |
/// |==========+============+============================================================|
/// |  flag    | - decl     | - help:    []const u8 ......................... = ""       | is there already long or short flag specified
/// |----------+------------+------------------------------------------------------------|
/// | option   | - decl     | - help:    []const u8 ......................... = ""       | is there already
/// |          | - type     | - default: ?T ................................. = null     | - long or short flag specified
/// |          |            | - handler: ?*const fn (Context, []const u8) !?T = null     | possible kinds: count,
/// |          |            | - choices: ?[]const []const u8 ................ = null     |
/// |----------+------------+------------------------------------------------------------|
/// | argument | - type     | - help:    []const u8 ......................... = ""       | is there already a...
/// |          |            | - kind:    ArgumentKind ....................... = .regular | - regular, passthrough, command, variadic types
/// |          |            | - handler: ?*const fn (Context, []const u8) !?T = null     | - variadic
/// |          |            | - choices: ?[]const []const u8 ................ = null     | - passthrough
/// +------------------------------------------------------------------------------------+
///
/// When building the output:
/// Construct the tuple:
/// - iterate over (tuple fields, tokens, sources, choices, handlers)
///   - if we have a supplied source
///     - variadic argument -> process variadic arr through handler & generate owned slice
///     - passthrough argument -> generated owned slice of strings
///   - otherwise: valdiate token against choices, process through handler
///   - set field to value
///   - if error at any point of this process, if it's due to an invalid argument. need to supply:
///     - flag/arg
///     - token
///     - expected type (stringified)
///     - allowed choices
///
/// lists need defining at compile-time
/// - field types (specifically the variadic base type, where the tuple will have a list version) (maybe we can extract this in the inline loop instead)
/// - default values (tuple)
/// - per-field handlers
/// - per-field choices
/// need to define at compile-time
/// - static map from long flag -> {field idx, ?insert token}
/// - static map from short flag -> {field idx, ?insert token}
/// - arr/slice for each positional arg -> {field idx, kind, name}
/// source data needs to include:
/// - the long/short option or positional arg name/index
/// - the raw token
///
/// to get the stringified type:
/// - know the raw type
/// our custom return type that integrates a successful parse, error and help-message states
///

//  Parser Result and Error Types

/// the parser's result
/// - result: the tuple containing parsed values (shape is defined by parser & registered args/opts)
/// - err: custom error type specifiying additional error information
/// - help: special result state for indicating printing out the help message
pub fn ParserResult(comptime T: type) type {
    return union(enum) {
        result: T,
        err: ParserError,
        help: void,
    };
}
/// a custom error class to work around limitations in error unions in zig
/// we don't want to output formatted error messages to the screen from directly within the Parser
/// i.e. we don't want to circumvent the traditional error-handling process
/// BUT errors themselves cannot store any contextual information e.g. the flag/token being parsed
///
/// In order to carry this information back to the caller, we use our own enum
/// at the expense that `try` and `catch` keywords will not work for these errors
/// we will need to access the errors using a union/switch statement on our `ParserResult` struct.
///
/// we also include a helper for writing the error message to the screen
pub const ParserError = union(enum) {
    UnrecognizedLongOption: []const u8,
    UnrecognizedShortOption: u8,

    UnexpectedPositionalArgument: []const u8,
    UnexpectedLongOptionArgument: struct { []const u8, []const u8 },

    MissingCommand: void,
    UnrecognizedCommand: []const u8,
    // tuple format: { option/arg identifier, expected type}
    MissingLongOptionArgument: []const u8,
    MissingShortOptionArgument: u8,
    MissingPositionalArgument: usize,
    // tuple format: { found value, option/arg identifier}
    InvalidLongOptionArgument: struct { []const u8, []const u8 },
    InvalidShortOptionArgument: struct { []const u8, u8 },
    InvalidPositionalArgument: struct { []const u8, usize },

    pub fn print(self: ParserError, writer: *std.Io.Writer) !void {
        try writer.print("error: ", .{});
        const print_stmt = print_err_msg: switch (self) {
            .UnrecognizedLongOption => |flag| writer.print("unrecognized option: '--{s}'", .{flag}),
            .UnrecognizedShortOption => |flag| writer.print("unrecognized option -- '{c}'", .{flag}),
            .UnrecognizedCommand => |cmd| writer.print("unrecognized command: '{s}'", .{cmd}),

            .UnexpectedPositionalArgument => |value| writer.print("unexpected positional argument: '{s}'", .{value}),
            .UnexpectedLongOptionArgument => |err| {
                const value, const flag = err;
                break :print_err_msg writer.print("option '--{s}' doesn't accept an argument; found: '{s}'", .{ flag, value });
            },

            .MissingLongOptionArgument => |flag| writer.print("option '--{s}' requires an argument", .{flag}),
            .MissingShortOptionArgument => |flag| writer.print("option requires an argument -- '{c}'", .{flag}),
            .MissingPositionalArgument => |idx| writer.print("missing positional argument at index {d}", .{idx}),
            .MissingCommand => writer.print("please specify a command"),

            .InvalidLongOptionArgument => |err| {
                const value, const flag = err;
                break :print_err_msg writer.print("invalid argument '{s}' for option '--{s}", .{ value, flag });
            },
            .InvalidShortOptionArgument => |err| {
                const value, const flag = err;
                break :print_err_msg writer.print("invalid argument '{s}' for option -- '{c}'", .{ value, flag });
            },
            .InvalidPositionalArgument => |err| {
                const value, const idx = err;
                break :print_err_msg writer.print("invalid positional argument '{s}' at index {d}", .{ value, idx });
            },
        };
        _ = try print_stmt;
        try writer.print("\n", .{});
        try writer.flush();
    }
};

test "error_formatting" {
    const allocator = std.testing.allocator;
    const cases = .{
        .{ ParserError{ .UnrecognizedLongOption = "--option" }, "unrecognized option: '--option'" },
        .{ ParserError{ .UnrecognizedShortOption = 'o' }, "unrecognized option -- 'o'" },
        .{ ParserError{ .UnexpectedPositionalArgument = "hello" }, "unexpected positional argument: 'hello'" },
        .{ ParserError{ .UnexpectedLongOptionArgument = .{ "bar", "--foo" } }, "option '--foo' doesn't accept an argument; found: 'bar'" },
        .{ ParserError{ .MissingLongOptionArgument = "--foo" }, "option '--foo' requires an argument" },
        .{ ParserError{ .MissingShortOptionArgument = 'o' }, "option requires an argument -- 'o'" },
        .{ ParserError{ .MissingPositionalArgument = 0 }, "missing positional argument at index 0" },
        .{ ParserError{ .InvalidLongOptionArgument = .{ "hello", "--option" } }, "invalid argument 'hello' for option '--option'" },
        .{ ParserError{ .InvalidShortOptionArgument = .{ "hello", 'o' } }, "invalid argument 'hello' for option -- 'o'" },
        .{ ParserError{ .InvalidPositionalArgument = .{ "hello", 0 } }, "invalid positional argument 'hello' at index 0" },
        .{ ParserError{ .UnrecognizedCommand = "hello" }, "unrecognized command: 'hello'" },
        .{ ParserError{ .MissingCommand = undefined }, "please specify a command" },
    };
    inline for (cases) |case| {
        const err, const expected = case;
        var writer = std.Io.Writer.Allocating.init(allocator);
        defer writer.deinit();
        try err.print(&writer.writer);
        const actual = try writer.toOwnedSlice();
        defer allocator.free(actual);
        try std.testing.expectEqualStrings("error: " ++ expected ++ "\n", actual);
    }
}

//  Parser Configs
//  Configs are a common Zig pattern to specify optional function parameters
//  and define default values without cluttering the function signature.

/// Sepcify optional parameters to customize argument behavior
pub fn ArgumentConfig(comptime arg_t: type) type {
    return struct {
        /// determines the argument's parsing behavior. see `ArgumentKind` for more info
        kind: ArgumentKind = .Positional,
        /// a descriptive string for understanding argument usage
        ///
        /// not applicable for passthrough arguments
        help: []const u8 = "",
        /// function used to parse raw tokens into the intended argument type e.g. to perform validation, post-processing, deserialize complex structures
        ///
        /// not applicable for passthrough arguments
        handler: ?arg_handler_t(arg_t) = null,
        /// specify a finite list of acceptable argument values
        ///
        /// not applicable for passthrough arguments
        choice: ?arg_choice_t(arg_t) = null,
    };
}
/// Determines the argument's parsing behavior
pub const ArgumentKind = enum {
    /// accepts a single command line token
    Positional,
    /// supports arbitrarily many command line tokens; will consume all remaining positional tokens. Must be placed after any `Positional` arguments
    ///
    /// resulting argument type is a const slice of the original type
    Variadic,
    /// used for capturing arbitrarily many raw tokens e.g. for passing to a subprocess. captures all tokens following `--`. Must be placed after any `Positional` and `Variadic` arguments
    Passthrough,
    /// a special internal type used to indicate test arguments specifying a subcommand to run
    Command,
};

/// Sepcify optional parameters to customize option behavior.
///
/// applies specifically to options with *required* arguments. See `FlagConfig` for non-argumentative options
pub fn OptionConfig(comptime op_t: type) type {
    return struct {
        /// a long flag (regex: `--[a-zA-Z0-9_\-]+`) to represent this option
        long: ?[]const u8 = null,
        /// a short flag (regex: `-[a-zA-Z0-9]`) to represent this option
        short: ?[]const u8 = null,
        /// a default value when option is not specific.
        /// automatically `null` for optional (`?..`) types.
        /// required for non-optional types
        ///
        /// not applicable for variadic options
        default: ?op_t = null,
        /// a descriptive string for understanding option usage
        help: []const u8 = "",
        /// function used to parse raw tokens into the intended type e.g. to perform validation, post-processing, deserialize complex structures
        handler: ?arg_handler_t(op_t) = null,
        /// specify a finite list of acceptable values
        choice: ?arg_choice_t(op_t) = null,
        /// whether to accept arbitrarily many values.
        /// the resulting type is a const slice of the original type
        variadic: bool = false,
    };
}

/// Sepcify optional parameters to customize option behavior.
///
/// applies specifically to non-argumentative options. See `OptionConfig` for options requiring arguments
pub const FlagConfig = struct {
    /// specify the flag's behavior. See `FlagKind` for more info
    kind: FlagKind = .Boolean,
    /// a long flag (regex: `--[a-zA-Z0-9_\-]+`) to represent this option.
    /// for boolean options, represents the `true` value
    ///
    /// optionally include a *negative* flag separated by forward slash (`/`) for boolean options to represent the `false` value
    /// e.g. `--yes/--no`
    long: ?[]const u8 = null,
    /// a short flag (regex: `-[a-zA-Z0-9]`) to represent this option.
    /// for boolean options, represents the `true` value
    ///
    /// optionally include a *negative* flag separated by forward slash (`/`) for boolean options to represent the `false` value
    /// e.g. `-y/-n`
    short: ?[]const u8 = null,
    /// a descriptive string for understanding option usage
    help: []const u8 = "",
};
/// Determines the behavior fo non-argumentative options
pub const FlagKind = enum {
    /// the presence of the flag should indicate a `true` or `false` value.
    /// the resulting option type is `bool`
    Boolean,
    /// the option's value should be based on the number of times the flag appears on the command line.
    /// the resulting option type is `usize`
    Count,
};

// Internal Representations
// Structures used to enable the desired functionality & interface for our parser
// not intended for external use.
//
// see `Parser` and `Parser.parse(...)` for more information

const FlagPtr = struct {
    field_idx: usize,
    value: ?any_t,
};
const ArgPtr = struct {
    field_idx: usize,
    kind: ArgumentKind,
};

/// The main data structure powering the `Parser`
///
/// It is responsible for holding information about each output field and
/// defines the logic of how string tokens collected at runtime should be used
/// to produce the final value.
const Field = union(enum) {
    scalar: ScalarFieldInfo,
    variadic: VariadicFieldInfo,
    count: void,

    fn initCount() Field {
        return .count;
    }
    fn initScalar(comptime t: type, comptime default: ?t, comptime handler: ?arg_handler_t(t), comptime choice: ?arg_choice_t(t)) Field {
        return .{
            .scalar = .{
                .t = t,
                .default = if (default) |d| util.toOpaquePtrComptime(d) else null,
                .handler = if (handler) |h| util.toOpaquePtrComptime(h) else null,
                .choice = if (choice) |c| util.toOpaquePtrComptime(c) else null,
            },
        };
    }
    fn initVariadic(comptime t: type, handler: ?arg_handler_t(t), choice: ?arg_choice_t(t)) Field {
        return .{ .variadic = .{
            .t = t,
            .handler = if (handler) |h| util.toOpaquePtrComptime(h) else null,
            .choice = if (choice) |c| util.toOpaquePtrComptime(c) else null,
        } };
    }

    const ScalarFieldInfo = struct {
        t: type,
        // expect to be type `t`
        default: ?any_t,
        // expect to be type `*const fn(Context, []const u8) !?t`
        hander: ?any_t,
        // expect to be type `[]const t`
        choice: ?any_t,
    };
    const VariadicFieldInfo = struct {
        t: type,
        // expect to be type `*const fn(Context, []const u8) !?t`
        handler: ?any_t,
        // expect to be type `[]const t`
        choice: ?any_t,
    };

    inline fn getFieldType(comptime self: Field) type {
        return switch (self.field_type) {
            .scalar => |t| t.@"0",
            .variadic => |t| []const t,
            .count => usize,
        };
    }
    inline fn getTokenType(comptime self: Field) ?type {
        return switch (self.field_type) {
            .scalar => |t| t.@"0",
            .variadic => |t| t,
            .count => null,
        };
    }

    inline fn getHanlderComptime(comptime self: Field) ?fn (context.Context, []const u8) anyerror!?self.getTokenType() {
        return comptime self.getHandler(self.getTokenType());
    }
    inline fn getChoiceComptime(comptime self: Field) ?[]const self.getTokenType() {
        return comptime self.getChoice(self.getTokenType());
    }

    fn getHandler(self: Field, comptime t: type) ?fn (context.Context, []const u8) anyerror!?t {
        return if (self.handler) |handler| util.fromOpaquePtr(fn (context.Context, []const u8) anyerror!?t, handler);
    }
    fn getChoice(self: Field, comptime t: type) ?[]const t {
        return if (self.choice) |choice| util.fromOpaquePtr([]const t, choice) else null;
    }

    fn getDefault(comptime self: Field) self.getFieldType() {
        return switch (self.field_type) {
            .scalar => |t| if (t.@"1") |d| util.fromOpaquePtr(t.@"0", d) else undefined,
            .variadic, .count => unreachable,
        };
    }

    fn getFieldCaptureGroup(self: Field) FieldCaptureGroup {
        return switch (self) {
            .scalar => .{ .scalar = null },
            .variadic => .{ .variadic = .empty },
            .count => .{ .count = .empty },
        };
    }

    fn build(comptime self: Field, ctx: context.Context, capture_group: FieldCaptureGroup) !BuildResult(self.getFieldType()) {
        switch (self) {
            .scalar => |info| {
                if (capture_group.scalar) |capture| return .{ .result = try capture.as(info.t, ctx, util.fromOpaquePtrMaybe(arg_choice_t(info.t), info.choice), util.fromOpaquePtrMaybe(arg_handler_t(info.t), info.hander)) orelse return .{ .err = capture.invalidArgument() } };
                return .{ .result = util.fromOpaquePtrMaybe(info.t, info.default) orelse undefined };
            },
            .variadic => |info| {
                var values: std.ArrayList(info.t) = .empty;
                defer values.deinit(ctx.gpa);
                for (capture_group.variadic.items) |capture| try values.append(capture.as(ctx.gpa, try capture.as(info.t, ctx, util.fromOpaquePtrMaybe(arg_choice_t(info.t), info.choice), util.fromOpaquePtrMaybe(arg_handler_t(info.t), info.handler)) orelse return .{ .err = capture.invalidArgument() }));
                return .{ .result = values.toOwnedSlice(ctx.arena.allocator()) };
            },
            .count => return .{ .result = capture_group.count.items.len },
        }
    }

    fn BuildResult(comptime t: type) type {
        return union(enum) {
            result: t,
            err: ParserError,
        };
    }

    const FieldCaptureGroup = union(enum) {
        scalar: ?Capture,
        variadic: std.ArrayList(Capture),
        count: std.ArrayList(CommandLineSource),

        fn deinit(self: FieldCaptureGroup, allocator: std.mem.Allocator) void {
            switch (self) {
                .variadic => |v| v.deinit(allocator),
                .count => |v| v.deinit(allocator),
                .scalar => {},
            }
        }

        fn deinitSlice(slice: []const FieldCaptureGroup, allocator: std.mem.Allocator) void {
            for (slice) |capture| capture.deinit(allocator);
        }

        fn accept(self: *FieldCaptureGroup, allocator: std.mem.Allocator, source: anytype, capture: ?Capture.Inner) !void {
            const src: CommandLineSource = .init(source);
            switch (self) {
                .scalar => self.scalar = .{ .source = src, .inner = capture.? },
                .variadic => try self.variadic.append(allocator, .{ .source = src, .inner = capture.? }),
                .count => if (capture) |_| unreachable else try self.count.append(allocator, src),
            }
        }

        const Capture = struct {
            inner: Inner,
            source: CommandLineSource,

            const Inner = union(enum) {
                token: []const u8,
                value: any_t,

                fn initValue(v: any_t) Inner {
                    return .{ .value = v };
                }

                fn initToken(t: []const u8) Inner {
                    return .{ .token = t };
                }
            };

            fn as(self: Capture, comptime t: type, ctx: context.Context, choice: ?arg_choice_t(t), handler: ?arg_handler_t(t)) !?t {
                return switch (self.inner) {
                    .token => |token| try parseToken(t, ctx, token, choice, handler),
                    .value => |value| util.fromOpaquePtr(t, value),
                };
            }

            fn invalidArgument(self: Capture) ParserError {
                return switch (self.source) {
                    .long_flag => |flag| .{ .InvalidShortOptionArgument = .{ self.token, flag } },
                    .short_flag => |flag| .{ .InvalidShortOptionArgument = .{ self.token, flag } },
                    .positional => |idx| .{ .InvalidPositionalArgument = .{ self.token, idx } },
                    .command => .{ .UnrecognizedCommand = self.token },
                };
            }
        };
        const CommandLineSource = union(enum) {
            long_flag: []const u8,
            short_flag: u8,
            positional: usize,
            command: void,

            fn initCommand() CommandLineSource {
                return .command;
            }
            fn init(source: anytype) CommandLineSource {
                return switch (@TypeOf(source)) {
                    usize => .{ .positional = source },
                    u8 => .{ .short_flag = source },
                    []const u8 => .{ .long_flag = source },
                    else => unreachable,
                };
            }
        };
    };
};

/// drives the construction and execution of command line argument processing
pub const Parser = struct {
    fields: []const Field = &.{},

    long_flags: std.StaticStringMap(FlagPtr) = .initComptime(.{}),
    short_flags: *const [62]?FlagPtr = &@splat(null),
    arguments: []const ArgPtr = &.{},

    exhaustive: bool = true,

    inline fn initExhaustive() Parser {
        return .{ .exhaustive = true };
    }

    inline fn initNonExhaustive() Parser {
        return .{ .exhaustive = false };
    }

    pub inline fn n(self: Parser) usize {
        return self.fields.len;
    }

    pub inline fn t(comptime self: Parser) type {
        comptime {
            var field_types: [self.n()]type = undefined;
            for (self.fields, 0..) |field, i| {
                field_types[i] = switch (field.field_type) {
                    .scalar => |typ| typ,
                    .variadic => |typ| []const typ,
                    .count => usize,
                };
            }
            return @Tuple(field_types);
        }
    }

    pub inline fn addFlag(comptime self: Parser, comptime cfg: FlagConfig) Parser {
        comptime {
            const idx = self.n();
            var result = self;
            switch (cfg.kind) {
                .Boolean => {
                    result.fields = util.extendSliceComptime(Field, result.fields, .{ .scalar = .{ .t = bool, .default = util.toOpaquePtrComptime(false) } });
                    const pos_ptr: FlagPtr = .{ .field_idx = idx, .value = util.toOpaquePtrComptime(true) };
                    const neg_ptr: FlagPtr = .{ .field_idx = idx, .value = util.toOpaquePtrComptime(false) };
                    if (cfg.long) |decl| {
                        const long_positive, const long_negative = parseLongOptDecl(decl) orelse @compileError("invalid long flag decl: " ++ decl);
                        if (self.long_flags.has(long_positive)) @compileError("redeclaration of flag: --" ++ long_positive);
                        result.long_flags = util.insertStaticStringMapComptime(FlagPtr, result.long_flags, .{ long_positive, pos_ptr });
                        if (long_negative) |negative_flag| {
                            if (self.long_flags.has(negative_flag)) @compileError("redeclaration of flag: --" ++ negative_flag);
                            result.long_flags = util.insertStaticStringMapComptime(FlagPtr, result.long_flags, .{ negative_flag, neg_ptr });
                        }
                    }
                    if (cfg.short) |decl| {
                        const short_positive, const short_negative = parseShortOptDecl(decl) orelse @compileError("invalid short flag decl: " ++ decl);
                        if (self.short_flags[charToIdx(short_positive).?]) |_| @compileError("redeclaration of flag: -" ++ [_]u8{short_positive});
                        result.short_flags = util.setArrComptime(?FlagPtr, 62, result.short_flags, charToIdx(short_positive).?, pos_ptr);
                        if (short_negative) |negative_flag| {
                            if (self.short_flags[charToIdx(negative_flag).?]) |_| @compileError("redeclaration of flag: -" ++ [_]u8{negative_flag});
                            result.short_flags = util.setArrComptime(?FlagPtr, 62, result.short_flags, charToIdx(negative_flag).?, neg_ptr);
                        }
                    }
                },
                .Count => {
                    result.fields = util.extendSliceComptime(Field, result.fields, .count);
                    const ptr: FlagPtr = .{ .field_idx = idx };
                    if (cfg.long) |decl| {
                        const long_positive, const long_negative = parseLongOptDecl(decl) orelse @compileError("invalid long flag decl: " ++ decl);
                        if (long_negative) |negative_flag| @compileError("count flags do not support negative flags: " ++ negative_flag ++ " supplied decl: " ++ decl);
                        if (self.long_flags.has(long_positive)) @compileError("redeclaration of flag: --" ++ long_positive);
                        result.long_flags = util.insertStaticStringMapComptime(FlagPtr, result.long_flags, .{ long_positive, ptr });
                    }
                    if (cfg.short) |decl| {
                        const short_positive, const short_negative = parseShortOptDecl(decl) orelse @compileError("invalid short flag decl: " ++ decl);
                        if (short_negative) |negative_flag| @compileError("count flags do not support negative flags: " ++ [_]u8{negative_flag} ++ " supplied decl: " ++ decl);
                        if (self.short_flags[charToIdx(short_positive).?]) |_| @compileError("redeclaration of flag: -" ++ [_]u8{short_positive});
                        result.short_flags = util.setArrComptime(?FlagPtr, 62, result.short_flags, charToIdx(short_positive).?, ptr);
                    }
                },
            }
            return result;
        }
    }

    pub inline fn addOption(comptime self: Parser, comptime op_t: type, comptime cfg: OptionConfig(op_t)) Parser {
        comptime {
            const idx = self.n();
            var result = self;
            const field: Field = resolve_field: {
                if (!types.is_supported_option_type(op_t) and cfg.handler == null) @compileError("option handler function is required for parsing non-native option type: " ++ @typeName(op_t));
                if (cfg.variadic) {
                    if (cfg.default) |_| @compileError("variadic options do not support default types");
                    switch (@typeInfo(op_t)) {
                        .optional => @compileError("variadic options do not support optional types"),
                        else => {},
                    }
                    break :resolve_field .{ .variadic = .{
                        .t = op_t,
                        .handler = if (cfg.handler) |handler| util.toOpaquePtrComptime(handler) else null,
                        .choice = if (cfg.choice) |choice| util.toOpaquePtrComptime(choice) else null,
                    } };
                } else {
                    switch (@typeInfo(op_t)) {
                        .optional => if (cfg.default) |_| @compileError("options with default values should be changed to non-optional type"),
                        else => if (cfg.default == null) @compileError("non-optional types require a default value, or should be changed to an optional type"),
                    }
                    if (cfg.default != null and cfg.choice != null and !std.mem.containsAtLeastScalar(op_t, cfg.choice.?, cfg.default.?, 1)) @compileError("default value '" ++ cfg.default.? ++ "' is not one of specified choices: " ++ cfg.choice.?);
                    break :resolve_field .{ .scalar = .{
                        .t = op_t,
                        .default = if (cfg.default) |default| util.toOpaquePtrComptime(default) else null,
                        .handler = if (cfg.handler) |handler| util.toOpaquePtrComptime(handler) else null,
                        .choice = if (cfg.choice) |choice| util.toOpaquePtrComptime(choice) else null,
                    } };
                }
            };
            result.fields = util.extendSliceComptime(Field, result.fields, field);

            const ptr: FlagPtr = .{ .field_idx = idx };
            if (cfg.long) |decl| {
                const long_positive, const long_negative = parseLongOptDecl(decl) orelse @compileError("invalid long flag decl: " ++ decl);
                if (long_negative) |negative_flag| @compileError("non-bool options do not support negative flags: " ++ negative_flag ++ " supplied decl: " ++ decl);
                if (self.long_flags.has(long_positive)) @compileError("redeclaration of flag: --" ++ long_positive);
                result.long_flags = util.insertStaticStringMapComptime(FlagPtr, result.long_flags, .{ long_positive, ptr });
            }
            if (cfg.short) |decl| {
                const short_positive, const short_negative = parseShortOptDecl(decl) orelse @compileError("invalid short flag decl: " ++ decl);
                if (short_negative) |negative_flag| @compileError("non-bool options do not support negative flags: " ++ [_]u8{negative_flag} ++ " supplied decl: " ++ decl);
                if (self.short_flags[charToIdx(short_positive).?]) |_| @compileError("redeclaration of flag: -" ++ [_]u8{short_positive});
                result.short_flags = util.setArrComptime(?FlagPtr, 62, result.short_flags, charToIdx(short_positive).?, ptr);
            }
            return result;
        }
    }

    pub inline fn addArgument(comptime self: Parser, comptime arg_t: type, comptime cfg: ArgumentConfig(arg_t)) Parser {
        comptime {
            const idx = self.n();
            var result = self;
            switch (cfg.kind) {
                .Positional => {
                    if (!types.is_supported_option_type(arg_t) and cfg.handler == null) @compileError("argument handler function is required for parsing non-native option type: " ++ @typeName(arg_t));
                },
                .Command => {
                    if (arg_t != []const u8) @compileError("'command' arguments expect type `[]const u8`; found: " ++ @typeName(arg_t));
                    if (cfg.handler) |_| @compileError("'command' arguments do not accept argument handlers");
                    if (cfg.choice == null) @compileError("'command' arguments require a list of choices");
                },
                .Variadic => {
                    if (!types.is_supported_argument_type(arg_t) and cfg.handler == null) @compileError("argument handler function is required for parsing non-native option type: " ++ @typeName(arg_t));
                    switch (@typeInfo(arg_t)) {
                        .optional => @compileError("variadic arguments do not support optional types"),
                        else => {},
                    }
                },
                .Passthrough => {
                    if (arg_t != []const u8) @compileError("passthrough arguments expect type `[]const u8`; found: " ++ @typeName(arg_t));
                    if (cfg.choice) |_| @compileError("passthrough arguments do not accept value choices");
                    if (cfg.handler) |_| @compileError("passthrough arguments do not accept argument handlers");
                },
            }
            const opaque_handler = if (cfg.handler) |handler| util.toOpaquePtrComptime(handler) else null;
            const opaque_choice = if (cfg.choice) |choice| util.toOpaquePtrComptime(choice) else null;
            const field: Field = switch (cfg.kind) {
                .Positional, .Command => .{ .scalar = .{ .t = arg_t, .default = null, .handler = opaque_handler, .choice = opaque_choice } },
                .Variadic, .Passthrough => .{ .variadic = .{ .t = arg_t, .handler = opaque_handler, .choice = opaque_choice } },
            };

            result.fields = util.extendSliceComptime(Field, result.fields, field);
            result.arguments = util.extendSliceComptime(ArgPtr, result.arguments, .{ .field_idx = idx, .kind = cfg.kind });

            return result;
        }
    }

    /// parses tokens from our tokenizer based on the provided config
    /// note: there are a couple edge cases:
    /// - the `--` token is ignored
    /// - cannot parse negative values to arguments. the leading `-` categorizes
    ///   the token as a short flag (this is similar behavior if you tried with `ls` e.g. `ls -3`)
    ///   recommend to use options instead
    /// - `--help` is a special case flag that will return `null`
    ///
    /// currently doesn't output helpful error messages e.g. which option/argument caused the error
    pub fn parse(comptime self: Parser, ctx: context.Context, itr: tokenizer.Tokenizer) !ParserResult(self.t()) {
        const arg_idx: usize = 0;

        var capture_groups: [self.n()]Field.FieldCaptureGroup = undefined;
        inline for (self.fields, 0..) |field_info, i| capture_groups[i] = field_info.getFieldCaptureGroup();
        defer Field.FieldCaptureGroup.deinitSlice(capture_groups, ctx.gpa);

        // if (!self.exhaust and arg_idx == self.arguments.len) return .{ .result = result };
        while (itr.next()) |token| {
            if (std.mem.eql(u8, token, "--")) {
                // special `--` argument - not sure what do with it yet
            } else if (std.mem.startsWith(u8, token, "--")) {
                // long flag - unpack flag name & value + validate flag name
                const flag_name, const maybe_value = unpackLongFlagToken(token).?;
                const src: Field.FieldCaptureGroup.CommandLineSource = .init(flag_name);
                if (std.mem.eql(u8, flag_name, "help")) return .help;
                if (self.long_flags.get(flag_name)) |ptr| {
                    switch (self.fields[ptr.field_idx]) {
                        .count => {
                            if (maybe_value) |token_value| return .{ .err = .{ .UnexpectedLongOptionArgument = .{ token_value, flag_name } } };
                            try capture_groups[ptr.field_idx].acceptCount(ctx.gpa, src);
                        },
                        .scalar, .variadic => {
                            if (ptr.value) |value| {
                                if (maybe_value) |token_value| return .{ .err = .{ .UnexpectedLongOptionArgument = .{ token_value, flag_name } } };
                                try capture_groups[ptr.field_idx].acceptValue(ctx.gpa, src, value);
                            } else {
                                const value = maybe_value orelse return .{ .err = .{ .MissingLongOptionArgument = flag_name } };
                                try capture_groups[ptr.field_idx].acceptToken(ctx.gpa, src, value);
                            }
                        },
                    }
                } else {
                    return .{ .err = .{ .UnrecognizedLongOption = flag_name } };
                }
            } else if (std.mem.startsWith(u8, token, "-") and token.len > 1) {
                // short flag - multiple short flags can be grouped together in a single token
                for (token[1..], 1..) |c, i| {
                    const src: Field.FieldCaptureGroup.CommandLineSource = .init(c);
                    if (charToIdx(c)) |idx| {
                        if (self.short_flags[idx]) |ptr| {
                            switch (self.fields[ptr.field_idx]) {
                                .count => try capture_groups[ptr.field_idx].acceptCount(ctx.gpa, src),
                                .scalar, .variadic => {
                                    if (ptr.value) |value| {
                                        try capture_groups[ptr.field_idx].acceptValue(ctx.gpa, src, value);
                                    } else {
                                        const value = if (token.len - i > 1) token[i + 1 ..] else itr.next() orelse return .{ .err = .{ .MissingShortOptionArgument = c } };
                                        try capture_groups[ptr.field_idx].acceptToken(ctx.gpa, src, value);
                                        break;
                                    }
                                },
                            }
                            continue;
                        }
                    }
                    return .{ .err = .{ .UnrecognizedShortOption = c } };
                }
            } else {
                // argument - find the next argument we need to supply and place to token in the appropriate index
                if (arg_idx >= self.arguments.len) return .{ .err = .{ .UnexpectedPositionalArgument = token } };
                const value = token;
                const ptr = self.arguments[arg_idx];
                const src: Field.FieldCaptureGroup.CommandLineSource = if (ptr.kind == .Command) .initCommand() else .init(arg_idx);
                try capture_groups[ptr.field_idx].acceptToken(ctx.gpa, src, value);
                if (!self.exhaust and arg_idx == self.arguments.len) break;
            }
        }
        if (arg_idx < self.arguments.len) switch (self.arguments[arg_idx].kind) {
            .Positional => return .{ .err = .{ .MissingPositionalArgument = arg_idx } },
            .Command => return .{ .err = .{ .MissingCommand = self.fields[self.arguments[arg_idx].field_idx].choice.? } },
            else => {},
        };
        var result: self.t() = undefined;
        inline for (@typeInfo(self.t()).@"struct".field_names, self.fields, 0..) |name, field, i| {
            @field(result, name) = switch (try field.build(ctx, capture_groups[i])) {
                .result => |value| value,
                .err => |err| return .{ .err = err },
            };
        }
        return .{ .result = result };
    }
};

/// long flags can be expressed by themselves or with their value
/// this helps us extract the flag and optional value portions separately
fn unpackLongFlagToken(token: []const u8) ?struct { []const u8, ?[]const u8 } {
    if (!std.mem.startsWith(u8, token, "--")) return null;
    if (token.len < 3) return null;
    if (std.mem.findScalar(u8, token, '=')) |i| {
        return .{ token[2..i], token[i + 1 ..] };
    }
    return .{ token, null };
}

/// helps us pack our 62 possible short flag names
/// into indices of a 62 element array
fn charToIdx(c: u8) ?usize {
    switch (c) {
        'a'...'z' => return @intCast(c - 'a'),
        'A'...'Z' => return @intCast(c - 'A' + 26),
        '0'...'9' => return @intCast(c - '0' + 52),
        else => return null,
    }
}

// success test cases:
// - [x] parsing each data type
// - [x] handling multiple positional arguments
// - [x] long flags
//   - [x] separate & joined values
// - [x] short flags
//   - [x] multiple flags expressed separately & together
//   - [x] separate and joined flag values
// - [x] handling positive & negative bool flags
// - [x] default values
// - [x] no-exhaust setting
// - [x] ignores `--` token
// - [x] `--help` flag

// check that multiple args and all data types can be handled
test "arg_parser_datatypes" {
    const allocator = std.testing.allocator;
    var itr = try tokenizer.StringIterator.init(allocator, "true false \"hello world\" 123 3.14");
    defer itr.deinit(allocator);

    // bool, optional, string, int, float
    const parser = ExhaustiveParser()
        .addArgument(bool)
        .addArgument(?bool)
        .addArgument([]const u8)
        .addArgument(u8)
        .addArgument(f16);

    const expected: parser.outputType() = .{ true, false, "hello world", 123, 3.14 };
    try std.testing.expectEqualDeep(expected, parser.parse(itr.asTokenizer()).result);
}

// check that multiple args and all data types can be handled
test "arg_parser_ignore_token" {
    const allocator = std.testing.allocator;
    var itr = try tokenizer.StringIterator.init(allocator, "-- \"hello world\"");
    defer itr.deinit(allocator);

    // bool, optional, string, int, float
    const parser = ExhaustiveParser().addArgument([]const u8);

    const expected: parser.outputType() = .{"hello world"};
    try std.testing.expectEqualDeep(expected, parser.parse(itr.asTokenizer()).result);
}

test "arg_parser_help_flag" {
    const allocator = std.testing.allocator;

    const parser = ExhaustiveParser().addOption("--long-flag", []const u8, "default");

    // test separate & conjoined value cases
    // boolean long flags tested in different case
    var itr = try tokenizer.StringIterator.init(allocator, "--long-flag value --help");
    defer itr.deinit(allocator);
    switch (parser.parse(itr.asTokenizer())) {
        .help => {},
        else => unreachable,
    }
}

test "arg_parser_option_arg" {
    const allocator = std.testing.allocator;

    const parser = ExhaustiveParser().addOption("--long-flag,-l", []const u8, "default");

    // test separate & conjoined value cases
    // boolean long flags tested in different case
    var itr1 = try tokenizer.StringIterator.init(allocator, "--long-flag value");
    defer itr1.deinit(allocator);
    var itr2 = try tokenizer.StringIterator.init(allocator, "--long-flag=value");
    defer itr2.deinit(allocator);
    var itr3 = try tokenizer.StringIterator.init(allocator, "-l value");
    defer itr3.deinit(allocator);
    var itr4 = try tokenizer.StringIterator.init(allocator, "-lvalue");
    defer itr4.deinit(allocator);
    const expected: parser.outputType() = .{"value"};
    try std.testing.expectEqualDeep(expected, parser.parse(itr1.asTokenizer()).result);
    try std.testing.expectEqualDeep(expected, parser.parse(itr2.asTokenizer()).result);
    try std.testing.expectEqualDeep(expected, parser.parse(itr3.asTokenizer()).result);
    try std.testing.expectEqualDeep(expected, parser.parse(itr4.asTokenizer()).result);
}

test "arg_parser_multi_short_flag" {
    const allocator = std.testing.allocator;

    const parser = ExhaustiveParser().addFlag("-y").addOption("-t", []const u8, "default");

    // test different combinations of multiple short flags
    // - separate flags
    // - joined in a single token, with value in separate token
    // - flags & value in a single token
    var itr1 = try tokenizer.StringIterator.init(allocator, "-y -t value");
    defer itr1.deinit(allocator);
    var itr2 = try tokenizer.StringIterator.init(allocator, "-yt value");
    defer itr2.deinit(allocator);
    var itr3 = try tokenizer.StringIterator.init(allocator, "-ytvalue");
    defer itr3.deinit(allocator);
    const expected1: parser.outputType() = .{ true, "value" };
    try std.testing.expectEqualDeep(expected1, parser.parse(itr1.asTokenizer()).result);
    try std.testing.expectEqualDeep(expected1, parser.parse(itr2.asTokenizer()).result);
    try std.testing.expectEqualDeep(expected1, parser.parse(itr3.asTokenizer()).result);

    // - moving t after y should make it part of `-y` value
    var itr4 = try tokenizer.StringIterator.init(allocator, "-tyvalue");
    defer itr4.deinit(allocator);
    const expected2: parser.outputType() = .{ false, "yvalue" };
    try std.testing.expectEqualDeep(expected2, parser.parse(itr4.asTokenizer()).result);
}

test "arg_parser_bool_flag" {
    const allocator = std.testing.allocator;

    const parser = ExhaustiveParser().addFlag("--yes/--no,-y/-n");

    // check that both positive and negative flags work for short & long flags
    var itr1 = try tokenizer.StringIterator.init(allocator, "--yes");
    defer itr1.deinit(allocator);
    var itr2 = try tokenizer.StringIterator.init(allocator, "-y");
    defer itr2.deinit(allocator);
    try std.testing.expectEqualDeep(.{true}, parser.parse(itr1.asTokenizer()).result);
    try std.testing.expectEqualDeep(.{true}, parser.parse(itr2.asTokenizer()).result);

    var itr3 = try tokenizer.StringIterator.init(allocator, "--no");
    defer itr3.deinit(allocator);
    var itr4 = try tokenizer.StringIterator.init(allocator, "-n");
    defer itr4.deinit(allocator);
    try std.testing.expectEqualDeep(.{false}, parser.parse(itr3.asTokenizer()).result);
    try std.testing.expectEqualDeep(.{false}, parser.parse(itr4.asTokenizer()).result);
}

test "arg_parser_no_exhaust" {
    const allocator = std.testing.allocator;

    const parser = NonExhaustiveParser().addFlag("-y").addArgument([]const u8);

    // even when exhast is off, we expect the option to populate because it appears before the argument
    var itr1 = try tokenizer.StringIterator.init(allocator, "\"hello world\" -y");
    defer itr1.deinit(allocator);
    const expected1: parser.outputType() = .{ false, "hello world" };
    try std.testing.expectEqualDeep(expected1, parser.parse(itr1.asTokenizer()).result);

    // in this case, option is ignored because arguments are populated before it
    var itr2 = try tokenizer.StringIterator.init(allocator, "-y \"hello world\"");
    defer itr2.deinit(allocator);
    const expected2: parser.outputType() = .{ true, "hello world" };
    try std.testing.expectEqualDeep(expected2, parser.parse(itr2.asTokenizer()).result);
}

// error test cases:
// - [x] missing positional argument
// - [x] extra positional argument
// - [x] long flags
//   - [x] unrecognized flag
//   - [x] argument for boolean flag
//   - [x] missing argument
// - [x] short flags
//   - [x] invalid flag
//   - [x] unrecognized flag
//   - [x] missing argument
// - [x] type parsing failure
//   - [x] positional arguments
//   - [x] long flags
//   - [x] short flags

test "arg_parser_missing_pos_arg" {
    const allocator = std.testing.allocator;
    var itr = try tokenizer.StringIterator.init(allocator, "hello world --foo baz");
    defer itr.deinit(allocator);

    const expected: ParserError = .{ .MissingPositionalArgument = .{ 2, "TEXT" } };

    const parser = ExhaustiveParser()
        .addArgument([]const u8)
        .addArgument([]const u8)
        .addArgument([]const u8)
        .addOption("--foo", []const u8, "bar");

    try std.testing.expectEqualDeep(expected, parser.parse((itr.asTokenizer())).err);
}

test "arg_parser_unexpected_pos_arg" {
    const allocator = std.testing.allocator;
    var itr = try tokenizer.StringIterator.init(allocator, "foo bar --hello baz");
    defer itr.deinit(allocator);

    const expected: ParserError = .{ .UnexpectedPositionalArgument = "baz" };

    const parser = ExhaustiveParser()
        .addArgument([]const u8)
        .addArgument([]const u8)
        .addFlag("--hello");

    try std.testing.expectEqualDeep(expected, parser.parse(itr.asTokenizer()).err);
}

test "arg_parser_unrecognized_long_flag" {
    const allocator = std.testing.allocator;

    const parser = ExhaustiveParser().addOption("--long-flag,-l", []const u8, "default");

    var itr1 = try tokenizer.StringIterator.init(allocator, "--unknown-flag value");
    defer itr1.deinit(allocator);
    var itr2 = try tokenizer.StringIterator.init(allocator, "--unknown-flag=value");
    defer itr2.deinit(allocator);

    const expected: ParserError = .{ .UnrecognizedLongOption = "--unknown-flag" };

    try std.testing.expectEqualDeep(expected, parser.parse(itr1.asTokenizer()).err);
    try std.testing.expectEqualDeep(expected, parser.parse(itr2.asTokenizer()).err);
}

test "arg_parser_missing_long_flag_arg" {
    const allocator = std.testing.allocator;

    const expected: ParserError = .{ .MissingLongOptionArgument = .{ "--long-flag", "TEXT" } };

    const parser = ExhaustiveParser().addOption("--long-flag,-l", []const u8, "default");

    var itr = try tokenizer.StringIterator.init(allocator, "--long-flag");
    defer itr.deinit(allocator);

    try std.testing.expectEqualDeep(expected, parser.parse(itr.asTokenizer()).err);
}

test "arg_parser_unexpected_long_flag_arg" {
    const allocator = std.testing.allocator;

    const expected: ParserError = .{ .UnexpectedLongOptionArgument = .{ "value", "--long-flag" } };

    const parser = ExhaustiveParser().addFlag("--long-flag,-l");

    var itr = try tokenizer.StringIterator.init(allocator, "--long-flag=value");
    defer itr.deinit(allocator);

    try std.testing.expectEqualDeep(expected, parser.parse(itr.asTokenizer()).err);
}

test "arg_parser_invalid_short_flag" {
    const allocator = std.testing.allocator;

    const parser = ExhaustiveParser().addOption("--long-flag,-l", []const u8, "default");

    // test for separate and joined values
    var itr1 = try tokenizer.StringIterator.init(allocator, "-@ value");
    defer itr1.deinit(allocator);
    var itr2 = try tokenizer.StringIterator.init(allocator, "-@value");
    defer itr2.deinit(allocator);
    const expected: ParserError = .{ .UnrecognizedShortOption = '@' };

    try std.testing.expectEqualDeep(expected, parser.parse(itr1.asTokenizer()).err);
    try std.testing.expectEqualDeep(expected, parser.parse(itr2.asTokenizer()).err);
}

test "arg_parser_unrecognized_short_flag" {
    const allocator = std.testing.allocator;

    const parser = ExhaustiveParser().addFlag("-t/-f");

    // test for separate and joined values
    var itr1 = try tokenizer.StringIterator.init(allocator, "-y value");
    defer itr1.deinit(allocator);
    var itr2 = try tokenizer.StringIterator.init(allocator, "-yvalue");
    defer itr2.deinit(allocator);
    // also check that `-y` gets treated as an unexpected option rather than swallowed as a value of flag `-t`
    var itr3 = try tokenizer.StringIterator.init(allocator, "-tyvalue");
    defer itr3.deinit(allocator);
    const expected: ParserError = .{ .UnrecognizedShortOption = 'y' };

    try std.testing.expectEqualDeep(expected, parser.parse(itr1.asTokenizer()).err);
    try std.testing.expectEqualDeep(expected, parser.parse(itr2.asTokenizer()).err);
    try std.testing.expectEqualDeep(expected, parser.parse(itr3.asTokenizer()).err);
}

test "arg_parser_missing_short_flag_arg" {
    const allocator = std.testing.allocator;

    const parser = ExhaustiveParser().addOption("--long-flag,-l", []const u8, "default");

    var itr = try tokenizer.StringIterator.init(allocator, "-l");
    defer itr.deinit(allocator);
    const expected: ParserError = .{ .MissingShortOptionArgument = .{ 'l', "TEXT" } };

    try std.testing.expectEqualDeep(expected, parser.parse(itr.asTokenizer()).err);
}

// set up cases where parsing each supported data type will fail
test "arg_parser_invalid_pos_arg_value" {
    const allocator = std.testing.allocator;

    var invalid_bool_itr = try tokenizer.StringIterator.init(allocator, "tru3 false 123 3.14");
    defer invalid_bool_itr.deinit(allocator);
    var invalid_opt_itr = try tokenizer.StringIterator.init(allocator, "true fals3 123 3.14");
    defer invalid_opt_itr.deinit(allocator);
    var invalid_int_itr = try tokenizer.StringIterator.init(allocator, "true false 123o 3.14");
    defer invalid_int_itr.deinit(allocator);
    var invalid_float_itr = try tokenizer.StringIterator.init(allocator, "true false 123 3.1.4");
    defer invalid_float_itr.deinit(allocator);

    const cases = .{
        .{ &invalid_bool_itr, ParserError{ .InvalidPositionalArgument = .{ "tru3", 0, "BOOL" } } },
        .{ &invalid_opt_itr, ParserError{ .InvalidPositionalArgument = .{ "fals3", 1, "BOOL" } } },
        .{ &invalid_int_itr, ParserError{ .InvalidPositionalArgument = .{ "123o", 2, "INT" } } },
        .{ &invalid_float_itr, ParserError{ .InvalidPositionalArgument = .{ "3.1.4", 3, "FLOAT" } } },
    };

    // bool, optional, string, int, float
    const parser = ExhaustiveParser()
        .addArgument(bool)
        .addArgument(?bool)
        .addArgument(u8)
        .addArgument(f16);

    inline for (cases) |case| {
        const itr, const expected = case;
        try std.testing.expectEqualDeep(expected, parser.parse(itr.asTokenizer()).err);
    }
}

test "arg_parser_invalid_long_opt_arg_value" {
    const allocator = std.testing.allocator;

    var invalid_opt_itr = try tokenizer.StringIterator.init(allocator, "--opt1 123o");
    defer invalid_opt_itr.deinit(allocator);
    var invalid_int_itr = try tokenizer.StringIterator.init(allocator, "--opt2 123o");
    defer invalid_int_itr.deinit(allocator);
    var invalid_float_itr = try tokenizer.StringIterator.init(allocator, "--opt3 3.1.4");
    defer invalid_float_itr.deinit(allocator);

    const cases = .{
        .{ &invalid_opt_itr, ParserError{ .InvalidLongOptionArgument = .{ "123o", "--opt1", "INT" } } },
        .{ &invalid_int_itr, ParserError{ .InvalidLongOptionArgument = .{ "123o", "--opt2", "INT" } } },
        .{ &invalid_float_itr, ParserError{ .InvalidLongOptionArgument = .{ "3.1.4", "--opt3", "FLOAT" } } },
    };

    // bool, optional, string, int, float
    const parser = ExhaustiveParser()
        .addOption("--opt1,-1", ?u8, null)
        .addOption("--opt2,-2", u8, 0)
        .addOption("--opt3,-3", f16, 1.0);

    inline for (cases) |case| {
        const itr, const expected = case;
        try std.testing.expectEqualDeep(expected, parser.parse(itr.asTokenizer()).err);
    }
}

test "arg_parser_invalid_short_opt_arg_value" {
    const allocator = std.testing.allocator;

    var invalid_opt_itr = try tokenizer.StringIterator.init(allocator, "-1 123o");
    defer invalid_opt_itr.deinit(allocator);
    var invalid_int_itr = try tokenizer.StringIterator.init(allocator, "-2 123o");
    defer invalid_int_itr.deinit(allocator);
    var invalid_float_itr = try tokenizer.StringIterator.init(allocator, "-3 3.1.4");
    defer invalid_float_itr.deinit(allocator);

    const cases = .{
        .{ &invalid_opt_itr, ParserError{ .InvalidShortOptionArgument = .{ "123o", '1', "INT" } } },
        .{ &invalid_int_itr, ParserError{ .InvalidShortOptionArgument = .{ "123o", '2', "INT" } } },
        .{ &invalid_float_itr, ParserError{ .InvalidShortOptionArgument = .{ "3.1.4", '3', "FLOAT" } } },
    };

    // bool, optional, string, int, float
    const parser = ExhaustiveParser()
        .addOption("--opt1,-1", ?u8, null)
        .addOption("--opt2,-2", u8, 0)
        .addOption("--opt3,-3", f16, 1.0);

    inline for (cases) |case| {
        const itr, const expected = case;
        try std.testing.expectEqualDeep(expected, parser.parse(itr.asTokenizer()).err);
    }
}
