//! fmt.zig
//!
//!

const std = @import("std");
const types = @import("types.zig");
const parser = @import("parser.zig");

const DESCRIPTION_WIDTH: usize = 50;
const DESCRIPTION_INDENT: usize = 2;
const DESCRIPTION_COLUMN_IDX: usize = 30;
const LONG_FLAG_COLUMN_IDX: usize = 9;

pub inline fn columnizeComptime(comptime text: []const u8, comptime width: usize, comptime indent: usize) []const u8 {
    if (text.len < width) return text;
    comptime {
        const indent_str: []const u8 = &@as([indent]u8, @splat(' '));
        var result: []const u8 = "";
        var pos: usize = 0;
        var itr = std.mem.tokenizeScalar(u8, text, ' ');
        var maybe_token = itr.next();
        while (maybe_token) |token| {
            if (pos + token.len < width) {
                result = result ++ token ++ " ";
                pos += token.len + 1;
            } else if (pos + token.len == width) {
                result = result ++ token ++ "\n" ++ indent_str;
                pos = indent;
            } else if (width - pos < 5) {
                result = result ++ "\n" ++ indent_str;
                pos = indent;
                continue;
            } else if (token.len - (width - pos) < 5) {
                result = result ++ token ++ "\n" ++ indent_str;
                pos = indent;
            } else {
                result = result ++ token[0..(width - pos - 1)] ++ "-" ++ "\n" ++ indent_str;
                maybe_token = "-" ++ token[(width - pos - 1)..];
                pos = indent;
                continue;
            }
            maybe_token = itr.next();
        }
        return result;
    }
}

test "columnize" {
    const input = "hello world foo bar baz the quick brown fox jumped over the lazy dog";
    const expected =
        \\hello world foo
        \\  bar baz the 
        \\  quick brown 
        \\  fox jumped 
        \\  over the lazy
        \\  dog 
    ;
    try std.testing.expectEqualStrings(expected, columnizeComptime(input, 15, 2));
}

test "columnize_long" {
    const input = "supercalifragilisticexpialidocious";
    const expected =
        \\supercalifragi-
        \\  -listicexpia-
        \\  -lidocious 
    ;
    try std.testing.expectEqualStrings(expected, columnizeComptime(input, 15, 2));
}

pub inline fn appendColumn(comptime line: []const u8, comptime column: []const u8, comptime idx: usize) []const u8 {
    comptime {
        var itr = std.mem.tokenizeScalar(u8, column, '\n');
        var result: []const u8 = "";
        if (line.len > idx) {
            result = result ++ line ++ "\n";
        } else {
            result = result ++ line ++ @as([idx - line.len]u8, @splat(' ')) ++ (itr.next() orelse "") ++ "\n";
        }
        const spacer = @as([idx]u8, @splat(' '));
        while (itr.next()) |next_line| {
            result = result ++ spacer ++ next_line ++ "\n";
        }
        return result;
    }
}

test "append_column" {
    const line = "hello world";
    const column =
        \\this is a
        \\piece of 
        \\text that
        \\is column
    ;
    const expected =
        \\hello world this is a
        \\            piece of 
        \\            text that
        \\            is column
        \\
    ;
    try std.testing.expectEqualStrings(expected, appendColumn(line, column, 12));
}

test "append_column_long_line" {
    const line = "hello world";
    const column =
        \\this is a
        \\piece of 
        \\text that
        \\is column
    ;
    const expected =
        \\hello world
        \\          this is a
        \\          piece of 
        \\          text that
        \\          is column
        \\
    ;
    try std.testing.expectEqualStrings(expected, appendColumn(line, column, 10));
}

pub inline fn argumentHelpText(comptime idx: usize, comptime t: type, comptime description: []const u8) []const u8 {
    return appendColumn(
        std.fmt.comptimePrint("{d: >3}: {s: <25}", .{ idx, types.type_to_name(t) }),
        columnizeComptime(description, DESCRIPTION_WIDTH, DESCRIPTION_INDENT),
        DESCRIPTION_COLUMN_IDX,
    );
}

pub inline fn flagHelpText(
    comptime declaration: []const u8,
    comptime description: []const u8,
) []const u8 {
    comptime {
        const flags = parser.parseBoolFlag(declaration) catch unreachable;
        var short_flags = short_flag_str: {
            if (flags.short_positive) |flag| {
                if (flags.short_negative) |negative_flag| {
                    break :short_flag_str std.fmt.comptimePrint("-{c}/-{c}", .{ flag, negative_flag });
                } else {
                    break :short_flag_str std.fmt.comptimePrint("-{c}", .{flag});
                }
            }
            break :short_flag_str "";
        };
        const long_flags = long_flag_str: {
            if (flags.long_positive) |flag| {
                if (flags.long_negative) |negative_flag| {
                    break :long_flag_str std.fmt.comptimePrint("--{s}/--{s}", .{ flag, negative_flag });
                } else {
                    break :long_flag_str std.fmt.comptimePrint("--{s}", .{flag});
                }
            }
            break :long_flag_str "";
        };
        if (short_flags.len > 0 and long_flags.len > 0) short_flags = short_flags ++ ",";
        const line = appendColumn("  " ++ short_flags, long_flags, LONG_FLAG_COLUMN_IDX);
        return appendColumn(line, columnizeComptime(description, DESCRIPTION_WIDTH, DESCRIPTION_INDENT), DESCRIPTION_COLUMN_IDX);
    }
}

pub inline fn optionHelpText(
    comptime declaration: []const u8,
    comptime t: type,
    comptime description: []const u8,
) []const u8 {
    comptime {
        const flags = parser.parseOption(declaration) catch unreachable;
        const line = fmt_line: {
            if (flags.short) |short| {
                if (flags.long) |long| {
                    break :fmt_line std.fmt.comptimePrint("  -{c},    --{s}={s}", .{ short, long, types.type_to_name(t) });
                } else {
                    break :fmt_line std.fmt.comptimePrint("  -{c} {s}", .{ short, types.type_to_name(t) });
                }
            } else {
                if (flags.long) |long| {
                    break :fmt_line std.fmt.comptimePrint("         --{s}={s}", .{ long, types.type_to_name(t) });
                }
                unreachable;
            }
        };
        return appendColumn(
            line,
            columnizeComptime(description, DESCRIPTION_WIDTH, DESCRIPTION_INDENT),
            DESCRIPTION_COLUMN_IDX,
        );
    }
}

pub inline fn commandHelpText(comptime name: []const u8, comptime description: []const u8) []const u8 {
    return appendColumn(
        "  " ++ name,
        columnizeComptime(description, DESCRIPTION_WIDTH, DESCRIPTION_INDENT),
        DESCRIPTION_COLUMN_IDX,
    );
}
