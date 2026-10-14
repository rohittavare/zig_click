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
const util = @import("util.zig");
const types = @import("types.zig");

/// command names are allowed alphanumeric characters, `-` and `_`
pub fn validCommandName(name: []const u8) bool {
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

const FlagParserError = error{
    IncorrectSpecificationFormat,
    InvalidFlagName,
    MultipleFlagDeclaration,
};

const OptionFlags = struct {
    long: ?[]const u8 = null,
    short: ?u8 = null,
};

fn extract_long_flag_name(flag: []const u8) []const u8 {
    return flag[2..];
}

fn valid_long_flag_name(flag: []const u8) bool {
    if (flag.len == 0) return false;
    for (flag) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

fn extract_short_flag_name(flag: []const u8) u8 {
    return flag[1];
}

fn valid_short_flag_name(flag: u8) bool {
    return switch (flag) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        else => false,
    };
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
            ret.long = extract_long_flag_name(flag);
            if (!valid_long_flag_name(ret.long.?)) return FlagParserError.InvalidFlagName;
        } else if (std.mem.startsWith(u8, flag, "-")) {
            if (flag.len != 2) return FlagParserError.InvalidFlagName;
            if (ret.short) |_| return FlagParserError.MultipleFlagDeclaration;
            ret.short = extract_short_flag_name(flag);
            if (!valid_short_flag_name(ret.short.?)) return FlagParserError.InvalidFlagName;
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
                ret.long_positive = extract_long_flag_name(flag);
                if (!valid_long_flag_name(ret.long_positive.?)) return FlagParserError.InvalidFlagName;
                if (flag_tokenizer.next()) |second_flag| {
                    if (!std.mem.startsWith(u8, second_flag, "--")) return FlagParserError.IncorrectSpecificationFormat;
                    ret.long_negative = extract_long_flag_name(second_flag);
                    if (!valid_long_flag_name(ret.long_negative.?)) return FlagParserError.InvalidFlagName;
                }
            } else if (std.mem.startsWith(u8, flag, "-")) {
                if (flag.len != 2) return FlagParserError.InvalidFlagName;
                if (ret.short_positive) |_| return FlagParserError.MultipleFlagDeclaration;
                ret.short_positive = extract_short_flag_name(flag);
                if (!valid_short_flag_name(ret.short_positive.?)) return FlagParserError.InvalidFlagName;
                if (flag_tokenizer.next()) |second_flag| {
                    if (second_flag.len != 2) {
                        if (second_flag.len < 2 or second_flag[0] == '-') return FlagParserError.IncorrectSpecificationFormat;
                        return FlagParserError.InvalidFlagName;
                    }
                    ret.short_negative = extract_short_flag_name(second_flag);
                    if (!valid_short_flag_name(ret.short_negative.?)) return FlagParserError.InvalidFlagName;
                }
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

// /// our parser class
// /// tracks the arguments and short+long flags and the field index on the output type
// /// provides helper methods used to build the parser at compile-time (since type data is required)
// pub fn Parser(comptime ouT: type) type {
//     return struct {
//         defaults: ouT,
//         long_flags: std.StaticStringMap(OptionPointer),
//         // since short flags are single alphanumeric character
//         // there are only 62 possible options
//         short_flags: *const [62]?OptionPointer,
//         arguments: []const usize,
//         // whether to consume all token
//         // otherwise stop when the last argument
//         // is satisfied
//         exhaust: bool,
//
//         const T = ouT;
//         const N = @typeInfo(ouT).@"struct".field_names.len;
//         const Self = @This();
//         const empty = Self{
//             .defaults = undefined,
//             .long_flags = std.StaticStringMap(OptionPointer).initComptime(.{}),
//             .short_flags = &@as([62]?OptionPointer, @splat(null)),
//             .arguments = &[0]usize{},
//             .exhaust = true,
//         };
//
//         pub inline fn setExhaust(comptime self: Self, comptime val: bool) Self {
//             return if (val == self.exhaust) self else Self{
//                 .defaults = self.defaults,
//                 .arguments = self.arguments,
//                 .long_flags = self.long_flags,
//                 .short_flags = self.short_flags,
//                 .exhaust = val,
//             };
//         }
//
//         pub inline fn addArgument(comptime self: Self, comptime argT: type) Parser(util.extendTupleType(ouT, argT)) {
//             comptime {
//                 if (!types.is_supported_argument_type(argT)) @compileError("type " ++ @typeName(argT) ++ " is not one of (or optional variant of) the supported argument types: bool, []const u8, u.., i.., f..");
//                 const t = util.extendTupleType(ouT, argT);
//                 return Parser(t){
//                     .defaults = util.extendTuple(ouT, argT, self.defaults, null),
//                     .long_flags = self.long_flags,
//                     .short_flags = self.short_flags,
//                     .arguments = util.extendSliceComptime(usize, self.arguments, N),
//                     .exhaust = self.exhaust,
//                 };
//             }
//         }
//
//         pub inline fn addOption(comptime self: Self, comptime declaration: []const u8, comptime opT: type, comptime def: opT) Parser(util.extendTupleType(ouT, opT)) {
//             comptime {
//                 if (!types.is_supported_option_type(opT)) @compileError("type " ++ @typeName(opT) ++ " is not one of (or optional variant of) the supported types for options: []const u8, u.., i.., f.. (register bool options as flag)");
//                 const ptr = OptionPointer{ .idx = N };
//
//                 const parsed_flags = parseOption(declaration) catch |e| @compileError("error parsing flag declaration (" ++ declaration ++ "): " ++ @errorName(e));
//                 var long_flags = self.long_flags;
//                 var short_flags = self.short_flags;
//                 if (parsed_flags.long) |flag| {
//                     if (long_flags.has(flag)) @compileError("flag --" ++ flag ++ " is already registered");
//                     long_flags = util.insertStaticStringMapComptime(OptionPointer, long_flags, .{ flag, ptr });
//                 }
//                 if (parsed_flags.short) |flag| {
//                     const idx = charToIdx(flag).?;
//                     if (short_flags[idx]) |_| @compileError("flag -" ++ [_]u8{flag} ++ " is already registered");
//                     short_flags = util.setArrComptime(?OptionPointer, 62, short_flags, idx, ptr);
//                 }
//
//                 const t = util.extendTupleType(ouT, opT);
//                 return Parser(t){
//                     .defaults = util.extendTuple(ouT, opT, self.defaults, def),
//                     .long_flags = long_flags,
//                     .short_flags = short_flags,
//                     .arguments = self.arguments,
//                     .exhaust = self.exhaust,
//                 };
//             }
//         }
//
//         pub inline fn addFlag(comptime self: Self, comptime declaration: []const u8) Parser(util.extendTupleType(ouT, bool)) {
//             comptime {
//                 const positive_ptr = OptionPointer{ .idx = N, .bool_v = true };
//                 const negative_ptr = OptionPointer{ .idx = N, .bool_v = false };
//
//                 const parsed_flags = parseBoolFlag(declaration) catch |e| @compileError("error parsing flag declaration `" ++ declaration ++ "`: " ++ @errorName(e));
//                 var long_flags = self.long_flags;
//                 var short_flags = self.short_flags;
//                 if (parsed_flags.long_positive) |flag| {
//                     if (long_flags.has(flag)) @compileError("flag --" ++ flag ++ " is already registered");
//                     long_flags = util.insertStaticStringMapComptime(OptionPointer, long_flags, .{ flag, positive_ptr });
//                 }
//                 if (parsed_flags.long_negative) |flag| {
//                     if (long_flags.has(flag)) @compileError("flag --" ++ flag ++ " is already registered");
//                     long_flags = util.insertStaticStringMapComptime(OptionPointer, long_flags, .{ flag, negative_ptr });
//                 }
//                 if (parsed_flags.short_positive) |flag| {
//                     const idx = charToIdx(flag).?;
//                     if (short_flags[idx]) |_| @compileError("flag -" ++ [_]u8{flag} ++ " is already registered");
//                     short_flags = util.setArrComptime(?OptionPointer, 62, short_flags, idx, positive_ptr);
//                 }
//                 if (parsed_flags.short_negative) |flag| {
//                     const idx = charToIdx(flag).?;
//                     if (short_flags[idx]) |_| @compileError("flag -" ++ [_]u8{flag} ++ " is already registered");
//                     short_flags = util.setArrComptime(?OptionPointer, 62, short_flags, idx, negative_ptr);
//                 }
//
//                 const t = util.extendTupleType(ouT, bool);
//                 return Parser(t){
//                     .defaults = util.extendTuple(ouT, bool, self.defaults, false),
//                     .long_flags = long_flags,
//                     .short_flags = short_flags,
//                     .arguments = self.arguments,
//                     .exhaust = self.exhaust,
//                 };
//             }
//         }
//
//         pub inline fn outputType(comptime _: Self) type {
//             return T;
//         }
//
//         /// parses tokens from our tokenizer based on the provided config
//         /// note: there are a couple edge cases:
//         /// - the `--` token is ignored
//         /// - cannot parse negative values to arguments. the leading `-` categorizes
//         ///   the token as a short flag (this is similar behavior if you tried with `ls` e.g. `ls -3`)
//         ///   recommend to use options instead
//         /// - `--help` is a special case flag that will return `null`
//         ///
//         /// currently doesn't output helpful error messages e.g. which option/argument caused the error
//         pub fn parse(comptime self: Self, itr: tokenizer.Tokenizer) !?ouT {
//             var arg_idx: usize = 0;
//             var tokens: [N]?[]const u8 = @splat(null);
//             var result = self.defaults;
//             if (!self.exhaust and arg_idx == self.arguments.len) return result;
//             while (itr.next()) |token| {
//                 if (std.mem.eql(u8, token, "--")) {
//                     // special `--` argument - not sure what do with it yet
//                 } else if (std.mem.startsWith(u8, token, "--")) {
//                     // long flag - unpack flag name & value + validate flag name
//                     const flag, const maybe_value = unpackLongFlagToken(token);
//                     const flag_name = extract_long_flag_name(flag) catch return ParserError.InvalidOption;
//                     if (std.mem.eql(u8, flag_name, "help")) return null;
//                     if (self.long_flags.get(flag_name)) |ptr| {
//                         if (ptr.bool_v) |value| {
//                             // if it is a boolean flag, we should expect no corresponding ooption argument
//                             if (maybe_value) |_| return ParserError.UnexpectedArgument;
//                             tokens[ptr.idx] = if (value) "true" else "false";
//                         } else {
//                             // use the packaged value if provided, else use the next token as our option argument
//                             tokens[ptr.idx] = maybe_value orelse itr.next() orelse return ParserError.MissingArgument;
//                         }
//                     } else return ParserError.UnrecognizedOption;
//                 } else if (std.mem.startsWith(u8, token, "-") and token.len > 1) {
//                     // short flag - multiple short flags can be grouped together in a single token
//                     for (token[1..], 1..) |c, i| {
//                         if (charToIdx(c)) |idx| {
//                             if (self.short_flags[idx]) |ptr| {
//                                 if (ptr.bool_v) |value| {
//                                     tokens[ptr.idx] = if (value) "true" else "false";
//                                 } else {
//                                     // short flags requiring a parameter either
//                                     // - use the remaining token as the value
//                                     // - use the next token as the value (if at the end)
//                                     const value = token[i + 1 ..];
//                                     tokens[ptr.idx] = if (value.len > 0) value else itr.next() orelse return ParserError.MissingArgument;
//                                     break;
//                                 }
//                             } else return ParserError.UnrecognizedOption;
//                         } else return ParserError.InvalidOption;
//                     }
//                 } else {
//                     // argument - find the next argument we need to supply and place to token in the appropriate index
//                     if (arg_idx >= self.arguments.len) return ParserError.UnexpectedArgument;
//                     tokens[self.arguments[arg_idx]] = token;
//                     arg_idx += 1;
//                     if (!self.exhaust and arg_idx == self.arguments.len) break;
//                 }
//             }
//             if (arg_idx < self.arguments.len) return ParserError.MissingArgument;
//             inline for (@typeInfo(ouT).@"struct".field_names, @typeInfo(ouT).@"struct".field_types, tokens) |n, t, maybe_token| {
//                 if (maybe_token) |token| @field(result, n) = parseToken(t, token) orelse return ParserError.InvalidArgument;
//             }
//             return result;
//         }
//     };
// }

const ValueSource = union(enum) {
    long_flag: []const u8,
    short_flag: u8,
    positional: usize,
};

pub const ParserError = union(enum) {
    UnrecognizedLongOption: []const u8,
    UnrecognizedShortOption: u8,

    UnexpectedPositionalArgument: []const u8,
    UnexpectedLongOptionArgument: struct { []const u8, []const u8 },
    // tuple format: { option/arg identifier, expected type}
    MissingLongOptionArgument: struct { []const u8, []const u8 },
    MissingShortOptionArgument: struct { u8, []const u8 },
    MissingPositionalArgument: struct { usize, []const u8 },
    // tuple format: { found value, option/arg identifier, expected type}
    InvalidLongOptionArgument: struct { []const u8, []const u8, []const u8 },
    InvalidShortOptionArgument: struct { []const u8, u8, []const u8 },
    InvalidPositionalArgument: struct { []const u8, usize, []const u8 },

    pub fn print(self: ParserError, writer: *std.Io.Writer) !void {
        try writer.print("error: ", .{});
        const print_stmt = print_err_msg: switch (self) {
            .UnrecognizedLongOption => |flag| writer.print("unrecognized option: '{s}'", .{flag}),
            .UnrecognizedShortOption => |flag| writer.print("unrecognized option -- '{c}'", .{flag}),

            .UnexpectedPositionalArgument => |value| writer.print("unexpected positional argument: '{s}'", .{value}),
            .UnexpectedLongOptionArgument => |err| {
                const value, const flag = err;
                break :print_err_msg writer.print("option '{s}' doesn't accept an argument; found: '{s}'", .{ flag, value });
            },

            .MissingLongOptionArgument => |err| {
                const flag, const t = err;
                break :print_err_msg writer.print("option '{s}' requires argument of type {s}", .{ flag, t });
            },
            .MissingShortOptionArgument => |err| {
                const flag, const t = err;
                break :print_err_msg writer.print("option requires argument of type {s} -- '{c}'", .{ t, flag });
            },
            .MissingPositionalArgument => |err| {
                const idx, const t = err;
                break :print_err_msg writer.print("missing positional argument {s} at index {d}", .{ t, idx });
            },

            .InvalidLongOptionArgument => |err| {
                const value, const flag, const t = err;
                break :print_err_msg writer.print("option '{s}' expects argument of type {s}; found: '{s}'", .{ flag, t, value });
            },
            .InvalidShortOptionArgument => |err| {
                const value, const flag, const t = err;
                break :print_err_msg writer.print("option expects argument of type {s} -- '{c}'; found: '{s}'", .{ t, flag, value });
            },
            .InvalidPositionalArgument => |err| {
                const value, const idx, const t = err;
                break :print_err_msg writer.print("expected positional argument {s} at index {d}; found: '{s}'", .{ t, idx, value });
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
        .{ ParserError{ .MissingLongOptionArgument = .{ "--foo", "TEXT" } }, "option '--foo' requires argument of type TEXT" },
        .{ ParserError{ .MissingShortOptionArgument = .{ 'o', "TEXT" } }, "option requires argument of type TEXT -- 'o'" },
        .{ ParserError{ .MissingPositionalArgument = .{ 0, "TEXT" } }, "missing positional argument TEXT at index 0" },
        .{ ParserError{ .InvalidLongOptionArgument = .{ "hello", "--option", "INT" } }, "option '--option' expects argument of type INT; found: 'hello'" },
        .{ ParserError{ .InvalidShortOptionArgument = .{ "hello", 'o', "INT" } }, "option expects argument of type INT -- 'o'; found: 'hello'" },
        .{ ParserError{ .InvalidPositionalArgument = .{ "hello", 0, "INT" } }, "expected positional argument INT at index 0; found: 'hello'" },
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

pub fn ParserResult(comptime T: type) type {
    return union(enum) {
        result: T,
        err: ParserError,
        help: void,
    };
}

/// our parser class
/// tracks the arguments and short+long flags and the field index on the output type
/// provides helper methods used to build the parser at compile-time (since type data is required)
pub const Parser = struct {
    t: type,
    defaults: *const anyopaque,
    long_flags: std.StaticStringMap(OptionPointer),
    // since short flags are single alphanumeric character
    // there are only 62 possible options
    short_flags: *const [62]?OptionPointer,
    arguments: []const usize,
    // whether to consume all token
    // otherwise stop when the last argument
    // is satisfied
    exhaust: bool,
    has_options: bool,
    has_args: bool,

    const Self = @This();
    inline fn n(comptime self: Self) usize {
        return @typeInfo(self.t).@"struct".field_names.len;
    }
    const empty = Self{
        .t = struct {},
        .defaults = @ptrCast(&.{}),
        .long_flags = std.StaticStringMap(OptionPointer).initComptime(.{}),
        .short_flags = &@as([62]?OptionPointer, @splat(null)),
        .arguments = &[0]usize{},
        .exhaust = true,
        .has_options = false,
        .has_args = false,
    };

    pub inline fn setExhaust(comptime self: Self, comptime val: bool) Self {
        return if (val == self.exhaust) self else Self{
            .t = self.t,
            .defaults = self.defaults,
            .arguments = self.arguments,
            .long_flags = self.long_flags,
            .short_flags = self.short_flags,
            .exhaust = val,
            .has_options = self.has_options,
            .has_args = self.has_args,
        };
    }

    pub inline fn addArgument(comptime self: Self, comptime argT: type) Self {
        comptime {
            if (!types.is_supported_argument_type(argT)) @compileError("type " ++ @typeName(argT) ++ " is not one of (or optional variant of) the supported argument types: bool, []const u8, u.., i.., f..");
            return Self{
                .t = util.extendTupleType(self.t, argT),
                .defaults = &util.extendTuple(self.t, argT, @as(*const self.t, @ptrCast(@alignCast(self.defaults))).*, null),
                .long_flags = self.long_flags,
                .short_flags = self.short_flags,
                .arguments = util.extendSliceComptime(usize, self.arguments, self.n()),
                .exhaust = self.exhaust,
                .has_options = self.has_options,
                .has_args = true,
            };
        }
    }

    pub inline fn addOption(comptime self: Self, comptime declaration: []const u8, comptime opT: type, comptime def: opT) Self {
        comptime {
            if (!types.is_supported_option_type(opT)) @compileError("type " ++ @typeName(opT) ++ " is not one of (or optional variant of) the supported types for options: []const u8, u.., i.., f.. (register bool options as flag)");
            const ptr = OptionPointer{ .idx = self.n() };

            const parsed_flags = parseOption(declaration) catch |e| @compileError("error parsing flag declaration (" ++ declaration ++ "): " ++ @errorName(e));
            var long_flags = self.long_flags;
            var short_flags = self.short_flags;
            if (parsed_flags.long) |flag| {
                if (long_flags.has(flag)) @compileError("flag --" ++ flag ++ " is already registered");
                long_flags = util.insertStaticStringMapComptime(OptionPointer, long_flags, .{ flag, ptr });
            }
            if (parsed_flags.short) |flag| {
                const idx = charToIdx(flag).?;
                if (short_flags[idx]) |_| @compileError("flag -" ++ [_]u8{flag} ++ " is already registered");
                short_flags = util.setArrComptime(?OptionPointer, 62, short_flags, idx, ptr);
            }

            return Self{
                .t = util.extendTupleType(self.t, opT),
                .defaults = &util.extendTuple(self.t, opT, @as(*const self.t, @ptrCast(@alignCast(self.defaults))).*, def),
                .long_flags = long_flags,
                .short_flags = short_flags,
                .arguments = self.arguments,
                .exhaust = self.exhaust,
                .has_options = true,
                .has_args = self.has_args,
            };
        }
    }

    pub inline fn addFlag(comptime self: Self, comptime declaration: []const u8) Self {
        comptime {
            const positive_ptr = OptionPointer{ .idx = self.n(), .bool_v = true };
            const negative_ptr = OptionPointer{ .idx = self.n(), .bool_v = false };

            const parsed_flags = parseBoolFlag(declaration) catch |e| @compileError("error parsing flag declaration `" ++ declaration ++ "`: " ++ @errorName(e));
            var long_flags = self.long_flags;
            var short_flags = self.short_flags;
            if (parsed_flags.long_positive) |flag| {
                if (long_flags.has(flag)) @compileError("flag --" ++ flag ++ " is already registered");
                long_flags = util.insertStaticStringMapComptime(OptionPointer, long_flags, .{ flag, positive_ptr });
            }
            if (parsed_flags.long_negative) |flag| {
                if (long_flags.has(flag)) @compileError("flag --" ++ flag ++ " is already registered");
                long_flags = util.insertStaticStringMapComptime(OptionPointer, long_flags, .{ flag, negative_ptr });
            }
            if (parsed_flags.short_positive) |flag| {
                const idx = charToIdx(flag).?;
                if (short_flags[idx]) |_| @compileError("flag -" ++ [_]u8{flag} ++ " is already registered");
                short_flags = util.setArrComptime(?OptionPointer, 62, short_flags, idx, positive_ptr);
            }
            if (parsed_flags.short_negative) |flag| {
                const idx = charToIdx(flag).?;
                if (short_flags[idx]) |_| @compileError("flag -" ++ [_]u8{flag} ++ " is already registered");
                short_flags = util.setArrComptime(?OptionPointer, 62, short_flags, idx, negative_ptr);
            }

            return Self{
                .t = util.extendTupleType(self.t, bool),
                .defaults = &util.extendTuple(self.t, bool, @as(*const self.t, @ptrCast(@alignCast(self.defaults))).*, false),
                .long_flags = long_flags,
                .short_flags = short_flags,
                .arguments = self.arguments,
                .exhaust = self.exhaust,
                .has_options = true,
                .has_args = self.has_args,
            };
        }
    }

    pub inline fn outputType(comptime self: Self) type {
        return self.t;
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
    pub fn parse(comptime self: Self, itr: tokenizer.Tokenizer) ParserResult(self.t) {
        var arg_idx: usize = 0;
        var tokens: [self.n()]?[]const u8 = @splat(null);
        var readable_types: [self.n()][]const u8 = undefined;
        inline for (@typeInfo(self.t).@"struct".field_types, 0..) |field_type, i| {
            readable_types[i] = types.type_to_name(field_type);
        }
        var source: [self.n()]?ValueSource = @splat(null);
        var result = @as(*const self.t, @ptrCast(@alignCast(self.defaults))).*;
        if (!self.exhaust and arg_idx == self.arguments.len) return .{ .result = result };
        while (itr.next()) |token| {
            if (std.mem.eql(u8, token, "--")) {
                // special `--` argument - not sure what do with it yet
            } else if (std.mem.startsWith(u8, token, "--")) {
                // long flag - unpack flag name & value + validate flag name
                const flag, const maybe_value = unpackLongFlagToken(token);
                const flag_name = extract_long_flag_name(flag);
                if (std.mem.eql(u8, flag_name, "help")) return .{ .help = undefined };
                if (self.long_flags.get(flag_name)) |ptr| {
                    if (ptr.bool_v) |value| {
                        // if it is a boolean flag, we should expect no corresponding ooption argument
                        if (maybe_value) |token_value| return .{ .err = .{ .UnexpectedLongOptionArgument = .{ token_value, flag } } };
                        tokens[ptr.idx] = if (value) "true" else "false";
                    } else {
                        // use the packaged value if provided, else use the next token as our option argument
                        tokens[ptr.idx] = maybe_value orelse itr.next() orelse return .{ .err = .{ .MissingLongOptionArgument = .{ flag, readable_types[ptr.idx] } } };
                        source[ptr.idx] = .{ .long_flag = flag };
                    }
                } else {
                    return .{ .err = .{ .UnrecognizedLongOption = flag } };
                }
            } else if (std.mem.startsWith(u8, token, "-") and token.len > 1) {
                // short flag - multiple short flags can be grouped together in a single token
                for (token[1..], 1..) |c, i| {
                    if (charToIdx(c)) |idx| {
                        if (self.short_flags[idx]) |ptr| {
                            if (ptr.bool_v) |value| {
                                tokens[ptr.idx] = if (value) "true" else "false";
                                source[ptr.idx] = .{ .short_flag = c };
                            } else {
                                // short flags requiring a parameter either
                                // - use the remaining token as the value
                                // - use the next token as the value (if at the end)
                                const value = token[i + 1 ..];
                                tokens[ptr.idx] = if (value.len > 0) value else itr.next() orelse return .{ .err = .{ .MissingShortOptionArgument = .{ c, readable_types[ptr.idx] } } };
                                source[ptr.idx] = .{ .short_flag = c };
                                break;
                            }
                        } else {
                            return .{ .err = .{ .UnrecognizedShortOption = c } };
                        }
                    } else {
                        return .{ .err = .{ .UnrecognizedShortOption = c } };
                    }
                }
            } else {
                // argument - find the next argument we need to supply and place to token in the appropriate index
                if (arg_idx >= self.arguments.len) return .{ .err = .{ .UnexpectedPositionalArgument = token } };
                tokens[self.arguments[arg_idx]] = token;
                source[self.arguments[arg_idx]] = .{ .positional = self.arguments[arg_idx] };
                arg_idx += 1;
                if (!self.exhaust and arg_idx == self.arguments.len) break;
            }
        }
        if (arg_idx < self.arguments.len) return .{ .err = .{ .MissingPositionalArgument = .{ arg_idx, readable_types[self.arguments[arg_idx]] } } };
        inline for (@typeInfo(self.t).@"struct".field_names, @typeInfo(self.t).@"struct".field_types, tokens, 0..) |name, t, maybe_token, i| {
            if (maybe_token) |token| @field(result, name) = parseToken(t, token) orelse {
                return switch (source[i] orelse unreachable) {
                    .long_flag => |flag| .{ .err = .{ .InvalidLongOptionArgument = .{ token, flag, readable_types[i] } } },
                    .short_flag => |flag| .{ .err = .{ .InvalidShortOptionArgument = .{ token, flag, readable_types[i] } } },
                    .positional => |idx| .{ .err = .{ .InvalidPositionalArgument = .{ token, idx, readable_types[i] } } },
                };
            };
        }
        return .{ .result = result };
    }
};

pub fn ExhaustiveParser() Parser {
    return Parser.empty.setExhaust(true);
}
pub fn NonExhaustiveParser() Parser {
    return Parser.empty.setExhaust(false);
}

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
