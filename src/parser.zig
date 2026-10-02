//! parser.zig
//!
//! Parsing tools to interpret comptile-time flag declarations, used to build the CLI
//! and construct supported data types from string, used to construct arguments during runtime
//!
//! for the purposes of CLI arguments, optional inputs are specified using flags. These are represented as
//! a word or contiguous phrase prefixed by two dashes (long flag) - long flags can only contain alphanumeric, '-' and '_' characters, but must start with alphanumeric character
//! or an alphanumeric character prefixed by a single dash (short flag)

const std = @import("std");

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
