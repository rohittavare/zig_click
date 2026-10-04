//! parser.zig
//!
//! Parsing tools to interpret comptile-time flag declarations, used to build the CLI
//! and construct supported data types from string, used to construct arguments during runtime
//!
//! for the purposes of CLI arguments, optional inputs are specified using flags. These are represented as
//! a word or contiguous phrase prefixed by two dashes (long flag) - long flags can only contain alphanumeric, '-' and '_' characters, but must start with alphanumeric character
//! or an alphanumeric character prefixed by a single dash (short flag)

const std = @import("std");
const tokenizer = @import("tokenizer.zig");

const FlagParserError = error{
    IncorrectSpecificationFormat,
    InvalidFlagName,
    MultipleFlagDeclaration,
};

const OptionFlags = struct {
    long: ?[]const u8 = null,
    short: ?u8 = null,
};

fn extract_long_flag_name(flag: []const u8) FlagParserError![]const u8 {
    if (!std.mem.startsWith(u8, flag, "--")) return FlagParserError.IncorrectSpecificationFormat;
    if (flag.len == 2) return FlagParserError.InvalidFlagName;
    switch (flag[2]) {
        'a'...'z', 'A'...'Z', '0'...'9' => {},
        else => return FlagParserError.InvalidFlagName,
    }
    for (flag[3..]) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return FlagParserError.InvalidFlagName,
    };
    return flag[2..];
}

fn extract_short_flag_name(flag: []const u8) FlagParserError!u8 {
    if (!std.mem.startsWith(u8, flag, "-")) return FlagParserError.IncorrectSpecificationFormat;
    if (std.mem.startsWith(u8, flag, "--")) return FlagParserError.IncorrectSpecificationFormat;
    if (flag.len != 2) return FlagParserError.InvalidFlagName;
    switch (flag[1]) {
        'a'...'z', 'A'...'Z', '0'...'9' => |c| return c,
        else => return FlagParserError.InvalidFlagName,
    }
}

/// option declaration parsing - return the long & short flags provided in the declaration string. Returns a `FlagParserError` on failure.
///
/// for purposes here, options represent *optional* non-boolean inputs to a command line
/// an option can be represented by a long flag, a short flag, or both, but only at most one of each
/// flags are declared for an option by listing the desired long and short flag separated by a comma
/// and include the leading dashes (`--` for long flag and `-` for short flag).
/// long and short flags can be declared in any order.
///
/// valid examples:
/// `--hello-world` - single long flag, dashes acceptable
/// `--h3ll0-w0r1d` - alphanumeric characters allowed, as long as first character is letter
/// `-c` - single short flag
/// `-A` - capital letter allowed
/// `-c,--complete` - valid long flag declared after short flag, separated by comma
/// `--always,-A` - short flag declared after long flag, separated by comma
///
/// invalid examples:
/// `-c,-b` - specifies multiple short flags
/// `--hello,--world` - declared multiple long flags
/// `-c,` - trailing comma
///
/// tricky cases:
/// `--always-A` - lack of separating comma causes short flag to fuse with long flag name (`always-A`)
/// `--hello--world` - appears to be an incorrect declaration with two long flags, but lack of comma causes both to fuse into single long flag (`hello--world`)
pub fn parseOption(declaration: []const u8) FlagParserError!OptionFlags {
    var ret = OptionFlags{};
    var flag_tokenizer = std.mem.splitScalar(u8, declaration, ',');
    while (flag_tokenizer.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "--")) {
            if (ret.long) |_| return FlagParserError.MultipleFlagDeclaration;
            ret.long = try extract_long_flag_name(flag);
        } else if (std.mem.startsWith(u8, flag, "-")) {
            if (ret.short) |_| return FlagParserError.MultipleFlagDeclaration;
            ret.short = try extract_short_flag_name(flag);
        } else {
            return FlagParserError.IncorrectSpecificationFormat;
        }
    }
    if (ret.long == null and ret.short == null) return FlagParserError.IncorrectSpecificationFormat;
    return ret;
}

test "parse_option_valid" {
    const test_cases = [_]struct { []const u8, OptionFlags }{
        .{ "--hello-world", OptionFlags{ .long = "hello-world" } },
        .{ "--h3ll0_w0r1d", OptionFlags{ .long = "h3ll0_w0r1d" } },
        .{ "-v", OptionFlags{ .short = 'v' } },
        .{ "-c,--complete", OptionFlags{ .long = "complete", .short = 'c' } },
        .{ "--always,-A", OptionFlags{ .long = "always", .short = 'A' } },
    };
    for (test_cases) |case| {
        const declaration, const expected = case;
        std.testing.expectEqualDeep(expected, try parseOption(declaration)) catch |e| {
            std.debug.print("failed test case {s}\n", .{declaration});
            return e;
        };
    }
}

test "parse_option_invalid" {
    const test_cases = [_]struct { []const u8, FlagParserError }{
        .{ "--hello,--world", FlagParserError.MultipleFlagDeclaration },
        .{ "-c,-v", FlagParserError.MultipleFlagDeclaration },
        .{ "--_flagname", FlagParserError.InvalidFlagName },
        .{ "--flag name", FlagParserError.InvalidFlagName },
        .{ "-@", FlagParserError.InvalidFlagName },
        .{ "-long", FlagParserError.InvalidFlagName },
        .{ "-s,--", FlagParserError.InvalidFlagName },
        .{ "--flag,-", FlagParserError.InvalidFlagName },
        .{ "", FlagParserError.IncorrectSpecificationFormat },
        .{ "--flag,-f,", FlagParserError.IncorrectSpecificationFormat },
        .{ "random", FlagParserError.IncorrectSpecificationFormat },
    };
    for (test_cases) |case| {
        const declaration, const err = case;
        std.testing.expectError(err, parseOption(declaration)) catch |e| {
            std.debug.print("failed test case \"{s}\" expecting {any}\n", case);
            return e;
        };
    }
}

const BoolFlags = struct {
    long_positive: ?[]const u8 = null,
    long_negative: ?[]const u8 = null,
    short_positive: ?u8 = null,
    short_negative: ?u8 = null,
};

/// boolean option declaration parsing - return the positive & negative long & short flags provided in the declaration string, returns `FlagParserError` on failure
///
/// boolean option flags are unique that they don't accept a token as input. Their presence itself encodes the argument value
/// Therefore boolean flags typically assume to have a negative (false) value by default and positive (true) value when the associated flag is present
/// However, in some cases it is use to have a 'negative' flag to explicitly specify a 'false' case. The declaration format for boolean options
/// is special to support for optionally specifying negative versions of both short and long flags.
///
/// when present, negative flags are grouped with their associated long/short positive flag, separated by a forward slash (`/`)
/// long and short flag (pairs) remain separated by comma (`,`)
///
/// valid examples:
/// <all the valid non-boolean option declaration examples>
/// `--true/--false` - pos/neg long flags only
/// `-t/-f` - pos/neg short flags only
/// `--yes/--no,-y/-n` - pos/neg short & long flags
/// `--yay,-y/-n` - pos long flag + pos/neg short flags
///
/// invalid examples:
/// `--yes/-n,-y/--no` - mixing pos/neg pairings between short & long flags
/// `--yes/,-y` - incomplete pos/neg long flag pair
///
/// tricky cases:
/// `--yes--no` - without separating forward slash, positive & negative flags get merged together
pub fn parseBoolFlag(declaration: []const u8) FlagParserError!BoolFlags {
    var ret = BoolFlags{};
    var flag_pair_tokenizer = std.mem.splitScalar(u8, declaration, ',');
    while (flag_pair_tokenizer.next()) |flag_pair| {
        var flag_tokenizer = std.mem.splitScalar(u8, flag_pair, '/');
        if (flag_tokenizer.next()) |flag| {
            if (std.mem.startsWith(u8, flag, "--")) {
                if (ret.long_positive) |_| return FlagParserError.MultipleFlagDeclaration;
                ret.long_positive = try extract_long_flag_name(flag);
                if (flag_tokenizer.next()) |second_flag| ret.long_negative = try extract_long_flag_name(second_flag);
            } else if (std.mem.startsWith(u8, flag, "-")) {
                if (ret.short_positive) |_| return FlagParserError.MultipleFlagDeclaration;
                ret.short_positive = try extract_short_flag_name(flag);
                if (flag_tokenizer.next()) |second_flag| ret.short_negative = try extract_short_flag_name(second_flag);
            } else {
                return FlagParserError.IncorrectSpecificationFormat;
            }
            if (flag_tokenizer.next()) |_| return FlagParserError.IncorrectSpecificationFormat;
        }
    }
    return ret;
}

test "parse_bool_flag_valid" {
    const test_cases = [_]struct { []const u8, BoolFlags }{
        // continue supporting normal flag declarations
        .{ "--hello-world", BoolFlags{ .long_positive = "hello-world" } },
        .{ "--h3ll0_w0r1d", BoolFlags{ .long_positive = "h3ll0_w0r1d" } },
        .{ "-v", BoolFlags{ .short_positive = 'v' } },
        .{ "-c,--complete", BoolFlags{ .long_positive = "complete", .short_positive = 'c' } },
        .{ "--always,-A", BoolFlags{ .long_positive = "always", .short_positive = 'A' } },
        // in addition, support pos/neg flag declarations
        .{ "--yes/--no", BoolFlags{ .long_positive = "yes", .long_negative = "no" } },
        .{ "-y/-n", BoolFlags{ .short_positive = 'y', .short_negative = 'n' } },
        .{ "--yes,-y/-n", BoolFlags{ .long_positive = "yes", .short_positive = 'y', .short_negative = 'n' } },
        .{ "-y,--yes/--no", BoolFlags{ .long_positive = "yes", .long_negative = "no", .short_positive = 'y' } },
        .{ "--yes/--no,-y/-n", BoolFlags{ .long_positive = "yes", .long_negative = "no", .short_positive = 'y', .short_negative = 'n' } },
    };
    for (test_cases) |case| {
        const declaration, const expected = case;
        std.testing.expectEqualDeep(expected, parseBoolFlag(declaration)) catch |e| {
            std.debug.print("failed test case {s}\n", .{declaration});
            return e;
        };
    }
}

test "parse_bool_flag_invalid" {
    const test_cases = [_]struct { []const u8, FlagParserError }{
        // support existing test cases
        .{ "--hello,--world", FlagParserError.MultipleFlagDeclaration },
        .{ "-c,-v", FlagParserError.MultipleFlagDeclaration },
        .{ "--_flagname", FlagParserError.InvalidFlagName },
        .{ "--flag name", FlagParserError.InvalidFlagName },
        .{ "-@", FlagParserError.InvalidFlagName },
        .{ "-long", FlagParserError.InvalidFlagName },
        .{ "-s,--", FlagParserError.InvalidFlagName },
        .{ "--flag,-", FlagParserError.InvalidFlagName },
        .{ "", FlagParserError.IncorrectSpecificationFormat },
        .{ "--flag,-f,", FlagParserError.IncorrectSpecificationFormat },
        .{ "random", FlagParserError.IncorrectSpecificationFormat },
        // additional test cases
        .{ "--yes/-n", FlagParserError.IncorrectSpecificationFormat },
        .{ "-y/--no", FlagParserError.IncorrectSpecificationFormat },
        .{ "/--no", FlagParserError.IncorrectSpecificationFormat },
        .{ "--yes/", FlagParserError.IncorrectSpecificationFormat },
        .{ "--yes/--no,-y/-n,--yes/--no", FlagParserError.MultipleFlagDeclaration },
        .{ "-y/-n,--yes,-y/-n", FlagParserError.MultipleFlagDeclaration },
        .{ "--yes/--no/--maybe", FlagParserError.IncorrectSpecificationFormat },
        .{ "-y/-n/-m", FlagParserError.IncorrectSpecificationFormat },
    };
    for (test_cases) |case| {
        const declaration, const err = case;
        std.testing.expectError(err, parseBoolFlag(declaration)) catch |e| {
            std.debug.print("failed test case \"{s}\" expecting {any}\n", case);
            return e;
        };
    }
}

/// parse a token to the desired data type
/// only int, float, bool and string types supported
/// does not parse null values for optional types
/// returns null when the datatype is unsupported or failure during parsing
pub fn parseToken(comptime t: type, token: []const u8) ?t {
    switch (@typeInfo(t)) {
        .optional => |o| {
            const parse_result = parseToken(o.child, token);
            if (parse_result) |res| {
                return res;
            }
            return null;
        },
        .int => return std.fmt.parseInt(t, token, 10) catch return null,
        .float => return std.fmt.parseFloat(t, token) catch return null,
        .bool => {
            if (std.mem.eql(u8, token, "true")) return true;
            if (std.mem.eql(u8, token, "false")) return false;
            return null;
        },
        .pointer => |p| {
            // currently only support strings through slice of const u8
            if (p.size == .slice and p.attrs.@"const" and p.child == u8) return token;
            return null;
        },
        else => return null,
    }
}

test "parse_token" {
    try std.testing.expectEqual(@as(i32, 10), parseToken(i32, "10").?); // int
    try std.testing.expectEqual(@as(f16, 4.5), parseToken(f16, "4.5").?); // float
    try std.testing.expectEqual(true, parseToken(bool, "true").?); // bool true
    try std.testing.expectEqual(false, parseToken(bool, "false").?); // bool false
    try std.testing.expectEqualStrings("hello", parseToken([]const u8, "hello").?); // string types
    try std.testing.expectEqual(@as(?bool, true), parseToken(?bool, "true").?); // handling optional types
}

test "parse_token_fail" {
    const test_cases = [_]struct { []const u8, type }{
        .{ "1000", u8 }, // overflow
        .{ "null", f16 }, // invalid chars
        .{ "something", bool }, // invalid bool
        .{ "hello", []u8 }, // non-const string (unsupported)
        .{ "hello", []const u16 }, // wrong int type for string (unsupported)
        .{ "10", *u8 }, // pointers unsupported
        .{ "1000", ?u8 }, // handling optional types
        .{ "10,3,8", [3]u8 }, // unsupported array type
    };
    inline for (test_cases) |case| {
        const token, const t = case;
        if (parseToken(t, token)) |v| {
            std.debug.print("failed test case: parsing \"{s}\" as type {any} yielded value {any}", .{ token, t, v });
            unreachable;
        }
    }
}

const OptionPointer = struct {
    // point this option to the tuple field index
    idx: usize,
    // if a boolean flag, what value it represents
    bool_v: ?bool = null,
};

/// provides the following information for our parser:
/// - expected output shape
/// - default values for output field
/// - registered long & short options, arguments and the field index they refer to
fn ParserConfig(comptime ouT: type) type {
    return struct {
        defaults: ouT,
        long_flags: std.StaticStringMap(OptionPointer),
        // since short flags are single alphanumeric character
        // there are only 62 possible options
        short_flags: *const [62]?OptionPointer,
        arguments: []const usize,
        // whether to consume all token
        // otherwise stop when the last argument
        // is satisfied
        exhaust: bool,

        const Self = @This();
        const empty = Self{
            .defaults = undefined,
            .long_flags = std.StaticStringMap(OptionPointer).initComptime(.{}),
            .short_flags = &@as([62]?OptionPointer, @splat(null)),
            .arguments = &[0]usize{},
            .exhaust = true,
        };
    };
}

const ArgumentParserError = error{
    UnrecognizedOption,
    UnexpectedArgument,
    MissingArgument,
    InvalidArgument,
    InvalidOption,
};

/// long flags can be expressed by themselves or with their value
/// this helps us extract the flag and optional value portions separately
fn unpackLongFlagToken(token: []const u8) struct { []const u8, ?[]const u8 } {
    if (std.mem.findScalar(u8, token, '=')) |i| {
        return .{ token[0..i], token[i + 1 ..] };
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

/// parses tokens from our tokenizer based on the provided config
/// note: there are a couple edge cases:
/// - the `--` token is ignored
/// - cannot parse negative values to arguments. the leading `-` categorizes
///   the token as a short flag (this is similar behavior if you tried with `ls` e.g. `ls -3`)
///   recommend to use options instead
/// - `--help` is a special case flag that will return `null`
fn parseArguments(comptime ouT: type, cfg: ParserConfig(ouT), itr: tokenizer.Tokenizer) !?ouT {
    var arg_idx: usize = 0;
    var tokens: [@typeInfo(ouT).@"struct".field_names.len]?[]const u8 = @splat(null);
    var result = cfg.defaults;
    if (!cfg.exhaust and arg_idx == cfg.arguments.len) return result;
    while (itr.next()) |token| {
        if (std.mem.eql(u8, token, "--")) {
            // special `--` argument - not sure what do with it yet
        } else if (std.mem.startsWith(u8, token, "--")) {
            // long flag - unpack flag name & value + validate flag name
            const flag, const maybe_value = unpackLongFlagToken(token);
            const flag_name = extract_long_flag_name(flag) catch return ArgumentParserError.InvalidOption;
            if (std.mem.eql(u8, flag_name, "help")) return null;
            if (cfg.long_flags.get(flag_name)) |ptr| {
                if (ptr.bool_v) |value| {
                    // if it is a boolean flag, we should expect no corresponding ooption argument
                    if (maybe_value) |_| return ArgumentParserError.UnexpectedArgument;
                    tokens[ptr.idx] = if (value) "true" else "false";
                } else {
                    // use the packaged value if provided, else use the next token as our option argument
                    tokens[ptr.idx] = maybe_value orelse itr.next() orelse return ArgumentParserError.MissingArgument;
                }
            } else return ArgumentParserError.UnrecognizedOption;
        } else if (std.mem.startsWith(u8, token, "-") and token.len > 1) {
            // short flag - multiple short flags can be grouped together in a single token
            for (token[1..], 1..) |c, i| {
                if (charToIdx(c)) |idx| {
                    if (cfg.short_flags[idx]) |ptr| {
                        if (ptr.bool_v) |value| {
                            tokens[ptr.idx] = if (value) "true" else "false";
                        } else {
                            // short flags requiring a parameter either
                            // - use the remaining token as the value
                            // - use the next token as the value (if at the end)
                            const value = token[i + 1 ..];
                            tokens[ptr.idx] = if (value.len > 0) value else itr.next() orelse return ArgumentParserError.MissingArgument;
                            break;
                        }
                    } else return ArgumentParserError.UnrecognizedOption;
                } else return ArgumentParserError.InvalidOption;
            }
        } else {
            // argument - find the next argument we need to supply and place to token in the appropriate index
            if (arg_idx >= cfg.arguments.len) return ArgumentParserError.UnexpectedArgument;
            tokens[cfg.arguments[arg_idx]] = token;
            arg_idx += 1;
            if (!cfg.exhaust and arg_idx == cfg.arguments.len) break;
        }
    }
    if (arg_idx < cfg.arguments.len) return ArgumentParserError.MissingArgument;
    inline for (@typeInfo(ouT).@"struct".field_names, @typeInfo(ouT).@"struct".field_types, tokens) |n, t, maybe_token| {
        if (maybe_token) |token| @field(result, n) = parseToken(t, token) orelse return ArgumentParserError.InvalidArgument;
    }
    return result;
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
    var itr = try tokenizer.StringIterator.initAllocator(allocator, "true false \"hello world\" 123 3.14");
    defer itr.deinitAllocator(allocator);

    // bool, optional, string, int, float
    const T = struct { bool, ?bool, []const u8, u8, f16 };
    var cfg = ParserConfig(T).empty;
    cfg.arguments = &[_]usize{ 0, 1, 2, 3, 4 };

    const expected: T = .{ true, false, "hello world", 123, 3.14 };
    try std.testing.expectEqualDeep(expected, (try parseArguments(T, cfg, itr.asTokenizer())).?);
}

// check that multiple args and all data types can be handled
test "arg_parser_ignore_token" {
    const allocator = std.testing.allocator;
    var itr = try tokenizer.StringIterator.initAllocator(allocator, "-- \"hello world\"");
    defer itr.deinitAllocator(allocator);

    // bool, optional, string, int, float
    const T = struct { []const u8 };
    var cfg = ParserConfig(T).empty;
    cfg.arguments = &[_]usize{0};

    const expected: T = .{"hello world"};
    try std.testing.expectEqualDeep(expected, (try parseArguments(T, cfg, itr.asTokenizer())).?);
}

test "arg_parser_help_flag" {
    const allocator = std.testing.allocator;

    const T = struct { []const u8 };
    var cfg = ParserConfig(T).empty;
    cfg.long_flags = std.StaticStringMap(OptionPointer).initComptime(.{.{ "long-flag", OptionPointer{ .idx = 0 } }});

    // test separate & conjoined value cases
    // boolean long flags tested in different case
    var itr = try tokenizer.StringIterator.initAllocator(allocator, "--long-flag value --help");
    defer itr.deinitAllocator(allocator);
    try std.testing.expectEqualDeep(null, try parseArguments(T, cfg, itr.asTokenizer()));
}

test "arg_parser_long_flag" {
    const allocator = std.testing.allocator;

    const T = struct { []const u8 };
    var cfg = ParserConfig(T).empty;
    cfg.long_flags = std.StaticStringMap(OptionPointer).initComptime(.{.{ "long-flag", OptionPointer{ .idx = 0 } }});

    // test separate & conjoined value cases
    // boolean long flags tested in different case
    var itr1 = try tokenizer.StringIterator.initAllocator(allocator, "--long-flag value");
    defer itr1.deinitAllocator(allocator);
    var itr2 = try tokenizer.StringIterator.initAllocator(allocator, "--long-flag=value");
    defer itr2.deinitAllocator(allocator);
    const expected: T = .{"value"};
    try std.testing.expectEqualDeep(expected, (try parseArguments(T, cfg, itr1.asTokenizer())).?);
    try std.testing.expectEqualDeep(expected, (try parseArguments(T, cfg, itr2.asTokenizer())).?);
}

test "arg_parser_short_flag" {
    const allocator = std.testing.allocator;

    const T = struct { []const u8 };
    var sf: [62]?OptionPointer = @splat(null);
    sf[charToIdx('t').?] = OptionPointer{ .idx = 0 };
    var cfg = ParserConfig(T).empty;
    cfg.short_flags = &sf;

    // test for separate and joined values
    // boolean short flags tested in different case
    var itr1 = try tokenizer.StringIterator.initAllocator(allocator, "-t value");
    defer itr1.deinitAllocator(allocator);
    var itr2 = try tokenizer.StringIterator.initAllocator(allocator, "-tvalue");
    defer itr2.deinitAllocator(allocator);
    const expected: T = .{"value"};
    try std.testing.expectEqualDeep(expected, (try parseArguments(T, cfg, itr1.asTokenizer())).?);
    try std.testing.expectEqualDeep(expected, (try parseArguments(T, cfg, itr2.asTokenizer())).?);
}

test "arg_parser_multi_short_flag" {
    const allocator = std.testing.allocator;

    const T = struct { bool, []const u8 };
    var sf: [62]?OptionPointer = @splat(null);
    sf[charToIdx('y').?] = OptionPointer{ .idx = 0, .bool_v = true };
    sf[charToIdx('t').?] = OptionPointer{ .idx = 1 };
    var cfg = ParserConfig(T).empty;
    cfg.short_flags = &sf;
    cfg.defaults = .{ false, "default" };

    // test different combinations of multiple short flags
    // - separate flags
    // - joined in a single token, with value in separate token
    // - flags & value in a single token
    var itr1 = try tokenizer.StringIterator.initAllocator(allocator, "-y -t value");
    defer itr1.deinitAllocator(allocator);
    var itr2 = try tokenizer.StringIterator.initAllocator(allocator, "-yt value");
    defer itr2.deinitAllocator(allocator);
    var itr3 = try tokenizer.StringIterator.initAllocator(allocator, "-ytvalue");
    defer itr3.deinitAllocator(allocator);
    const expected1: T = .{ true, "value" };
    try std.testing.expectEqualDeep(expected1, (try parseArguments(T, cfg, itr1.asTokenizer())).?);
    try std.testing.expectEqualDeep(expected1, (try parseArguments(T, cfg, itr2.asTokenizer())).?);
    try std.testing.expectEqualDeep(expected1, (try parseArguments(T, cfg, itr3.asTokenizer())).?);

    // - moving t after y should make it part of `-y` value
    var itr4 = try tokenizer.StringIterator.initAllocator(allocator, "-tyvalue");
    defer itr4.deinitAllocator(allocator);
    const expected2: T = .{ false, "yvalue" };
    try std.testing.expectEqualDeep(expected2, (try parseArguments(T, cfg, itr4.asTokenizer())).?);
}

test "arg_parser_bool_flag" {
    const allocator = std.testing.allocator;

    const T = struct { bool, bool };
    var sf: [62]?OptionPointer = @splat(null);
    sf[charToIdx('t').?] = OptionPointer{ .idx = 1, .bool_v = true };
    sf[charToIdx('f').?] = OptionPointer{ .idx = 1, .bool_v = false };
    var cfg = ParserConfig(T).empty;
    cfg.short_flags = &sf;
    cfg.long_flags = std.StaticStringMap(OptionPointer).initComptime(.{
        .{ "yes", OptionPointer{ .idx = 0, .bool_v = true } },
        .{ "no", OptionPointer{ .idx = 0, .bool_v = false } },
    });

    // check that both positive and negative flags work for short & long flags
    var itr1 = try tokenizer.StringIterator.initAllocator(allocator, "--yes -t");
    defer itr1.deinitAllocator(allocator);
    const expected1: T = .{ true, true };
    try std.testing.expectEqualDeep(expected1, (try parseArguments(T, cfg, itr1.asTokenizer())).?);

    var itr2 = try tokenizer.StringIterator.initAllocator(allocator, "--no -f");
    defer itr2.deinitAllocator(allocator);
    const expected2: T = .{ false, false };
    try std.testing.expectEqualDeep(expected2, (try parseArguments(T, cfg, itr2.asTokenizer())).?);
}

test "arg_parser_no_exhaust" {
    const allocator = std.testing.allocator;

    const T = struct { bool, []const u8 };
    var sf: [62]?OptionPointer = @splat(null);
    sf[charToIdx('y').?] = OptionPointer{ .idx = 0, .bool_v = true };
    var cfg = ParserConfig(T).empty;
    cfg.short_flags = &sf;
    cfg.defaults = .{ false, "default" };
    cfg.arguments = &[1]usize{1};
    cfg.exhaust = false;

    // even when exhast is off, we expect the option to populate because it appears before the argument
    var itr1 = try tokenizer.StringIterator.initAllocator(allocator, "\"hello world\" -y");
    defer itr1.deinitAllocator(allocator);
    const expected1: T = .{ false, "hello world" };
    try std.testing.expectEqualDeep(expected1, (try parseArguments(T, cfg, itr1.asTokenizer())).?);

    // in this case, option is ignored because arguments are populated before it
    var itr2 = try tokenizer.StringIterator.initAllocator(allocator, "-y \"hello world\"");
    defer itr2.deinitAllocator(allocator);
    const expected2: T = .{ true, "hello world" };
    try std.testing.expectEqualDeep(expected2, (try parseArguments(T, cfg, itr2.asTokenizer())).?);
}

// error test cases:
// - [x] missing positional argument
// - [x] extra positional argument
// - [x] long flags
//   - [x] invalid flag
//   - [x] unrecognized flag
//   - [x] argument for boolean flag
//   - [x] missing argument
// - [x] short flags
//   - [x] invalid flag
//   - [x] unrecognized flag
//   - [x] missing argument
// - [x] type parsing failure

test "arg_parser_missing_pos_arg" {
    const allocator = std.testing.allocator;
    var itr = try tokenizer.StringIterator.initAllocator(allocator, "hello world");
    defer itr.deinitAllocator(allocator);

    const T = struct { []const u8, []const u8, []const u8 };
    var cfg = ParserConfig(T).empty;
    cfg.arguments = &[_]usize{ 0, 1, 2 };

    try std.testing.expectError(ArgumentParserError.MissingArgument, parseArguments(T, cfg, itr.asTokenizer()));
}

test "arg_parser_unexpected_pos_arg" {
    const allocator = std.testing.allocator;
    var itr = try tokenizer.StringIterator.initAllocator(allocator, "foo bar baz");
    defer itr.deinitAllocator(allocator);

    const T = struct { []const u8, []const u8 };
    var cfg = ParserConfig(T).empty;
    cfg.arguments = &[_]usize{ 0, 1 };

    try std.testing.expectError(ArgumentParserError.UnexpectedArgument, parseArguments(T, cfg, itr.asTokenizer()));
}

test "arg_parser_invalid_long_flag" {
    const allocator = std.testing.allocator;

    const T = struct { []const u8 };
    var cfg = ParserConfig(T).empty;
    cfg.long_flags = std.StaticStringMap(OptionPointer).initComptime(.{.{ "long-flag", OptionPointer{ .idx = 0 } }});

    var itr1 = try tokenizer.StringIterator.initAllocator(allocator, "--long-fl@g value");
    defer itr1.deinitAllocator(allocator);
    var itr2 = try tokenizer.StringIterator.initAllocator(allocator, "--long-fl@g=value");
    defer itr2.deinitAllocator(allocator);
    const expected = ArgumentParserError.InvalidOption;
    try std.testing.expectError(expected, parseArguments(T, cfg, itr1.asTokenizer()));
    try std.testing.expectError(expected, parseArguments(T, cfg, itr2.asTokenizer()));
}

test "arg_parser_unrecognized_long_flag" {
    const allocator = std.testing.allocator;

    const T = struct { []const u8 };
    var cfg = ParserConfig(T).empty;
    cfg.long_flags = std.StaticStringMap(OptionPointer).initComptime(.{.{ "long-flag", OptionPointer{ .idx = 0 } }});

    var itr1 = try tokenizer.StringIterator.initAllocator(allocator, "--unknown-flag value");
    defer itr1.deinitAllocator(allocator);
    var itr2 = try tokenizer.StringIterator.initAllocator(allocator, "--unknown-flag=value");
    defer itr2.deinitAllocator(allocator);
    const expected = ArgumentParserError.UnrecognizedOption;
    try std.testing.expectError(expected, parseArguments(T, cfg, itr1.asTokenizer()));
    try std.testing.expectError(expected, parseArguments(T, cfg, itr2.asTokenizer()));
}

test "arg_parser_missing_long_flag_arg" {
    const allocator = std.testing.allocator;

    const T = struct { []const u8 };
    var cfg = ParserConfig(T).empty;
    cfg.long_flags = std.StaticStringMap(OptionPointer).initComptime(.{.{ "long-flag", OptionPointer{ .idx = 0 } }});

    var itr = try tokenizer.StringIterator.initAllocator(allocator, "--long-flag");
    defer itr.deinitAllocator(allocator);
    try std.testing.expectError(ArgumentParserError.MissingArgument, parseArguments(T, cfg, itr.asTokenizer()));
}

test "arg_parser_unexpected_long_flag_arg" {
    const allocator = std.testing.allocator;

    const T = struct { bool };
    var cfg = ParserConfig(T).empty;
    cfg.long_flags = std.StaticStringMap(OptionPointer).initComptime(.{.{ "long-flag", OptionPointer{ .idx = 0, .bool_v = true } }});

    var itr = try tokenizer.StringIterator.initAllocator(allocator, "--long-flag=value");
    defer itr.deinitAllocator(allocator);
    try std.testing.expectError(ArgumentParserError.UnexpectedArgument, parseArguments(T, cfg, itr.asTokenizer()));
}

test "arg_parser_invalid_short_flag" {
    const allocator = std.testing.allocator;

    const T = struct { []const u8 };
    var sf: [62]?OptionPointer = @splat(null);
    sf[charToIdx('t').?] = OptionPointer{ .idx = 0 };
    var cfg = ParserConfig(T).empty;
    cfg.short_flags = &sf;

    // test for separate and joined values
    var itr1 = try tokenizer.StringIterator.initAllocator(allocator, "-@ value");
    defer itr1.deinitAllocator(allocator);
    var itr2 = try tokenizer.StringIterator.initAllocator(allocator, "-@value");
    defer itr2.deinitAllocator(allocator);
    const expected = ArgumentParserError.InvalidOption;
    try std.testing.expectError(expected, parseArguments(T, cfg, itr1.asTokenizer()));
    try std.testing.expectError(expected, parseArguments(T, cfg, itr2.asTokenizer()));
}

test "arg_parser_unrecognized_short_flag" {
    const allocator = std.testing.allocator;

    const T = struct { bool };
    var sf: [62]?OptionPointer = @splat(null);
    sf[charToIdx('t').?] = OptionPointer{ .idx = 0, .bool_v = true };
    var cfg = ParserConfig(T).empty;
    cfg.short_flags = &sf;

    // test for separate and joined values
    var itr1 = try tokenizer.StringIterator.initAllocator(allocator, "-y value");
    defer itr1.deinitAllocator(allocator);
    var itr2 = try tokenizer.StringIterator.initAllocator(allocator, "-yvalue");
    defer itr2.deinitAllocator(allocator);
    // also check that `-y` gets treated as an unexpected option rather than a value for flag `-t`
    var itr3 = try tokenizer.StringIterator.initAllocator(allocator, "-tyvalue");
    defer itr3.deinitAllocator(allocator);
    const expected = ArgumentParserError.UnrecognizedOption;
    try std.testing.expectError(expected, parseArguments(T, cfg, itr1.asTokenizer()));
    try std.testing.expectError(expected, parseArguments(T, cfg, itr2.asTokenizer()));
    try std.testing.expectError(expected, parseArguments(T, cfg, itr3.asTokenizer()));
}

test "arg_parser_missing_short_flag_arg" {
    const allocator = std.testing.allocator;

    const T = struct { []const u8 };
    var sf: [62]?OptionPointer = @splat(null);
    sf[charToIdx('t').?] = OptionPointer{ .idx = 0 };
    var cfg = ParserConfig(T).empty;
    cfg.short_flags = &sf;

    var itr = try tokenizer.StringIterator.initAllocator(allocator, "-t");
    defer itr.deinitAllocator(allocator);
    const expected = ArgumentParserError.MissingArgument;
    try std.testing.expectError(expected, parseArguments(T, cfg, itr.asTokenizer()));
}

// set up cases where parsing each supported data type will fail
// expect an 'invalid argument value' error
test "arg_parser_invalid_datatypes" {
    const allocator = std.testing.allocator;
    var invalid_bool_itr = try tokenizer.StringIterator.initAllocator(allocator, "tru3 false 123 3.14");
    defer invalid_bool_itr.deinitAllocator(allocator);
    var invalid_opt_itr = try tokenizer.StringIterator.initAllocator(allocator, "true fals3 123 3.14");
    defer invalid_opt_itr.deinitAllocator(allocator);
    var invalid_int_itr = try tokenizer.StringIterator.initAllocator(allocator, "true false 1230 3.14");
    defer invalid_int_itr.deinitAllocator(allocator);
    var invalid_float_itr = try tokenizer.StringIterator.initAllocator(allocator, "true false 123 3.1.4");
    defer invalid_float_itr.deinitAllocator(allocator);

    // bool, optional, string, int, float
    const T = struct { bool, ?bool, u8, f16 };
    var cfg = ParserConfig(T).empty;
    cfg.arguments = &[_]usize{ 0, 1, 2, 3 };

    const expected = ArgumentParserError.InvalidArgument;
    try std.testing.expectError(expected, parseArguments(T, cfg, invalid_bool_itr.asTokenizer()));
    try std.testing.expectError(expected, parseArguments(T, cfg, invalid_opt_itr.asTokenizer()));
    try std.testing.expectError(expected, parseArguments(T, cfg, invalid_int_itr.asTokenizer()));
    try std.testing.expectError(expected, parseArguments(T, cfg, invalid_float_itr.asTokenizer()));
}
