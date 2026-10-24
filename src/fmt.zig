//! fmt.zig
//!
//! helpers specifically to format text to output on the screen; primarily to organize the help message
//! most helpers performed at compiletime, since most data is already known at that time
//! and avoid the need for an allocator

const std = @import("std");
const types = @import("types.zig");
const parser = @import("parser.zig");

const DESCRIPTION_WIDTH: usize = 50;
const DESCRIPTION_INDENT: usize = 2;
const DESCRIPTION_COLUMN_IDX: usize = 30;
const LONG_FLAG_COLUMN_IDX: usize = 9;

/// linewrap the provided text to fit within the specified column width
/// apply an indent to subsequent wrapped lines
/// assumes the input is constructed of space-separated words
/// hyphenate significantly long words
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

/// appends the provided multi-line string to the given single-lined string at the specified offset
/// fills in blank space after the input LHS string is exhausted
pub inline fn appendColumn(comptime line: []const u8, comptime column: []const u8, comptime idx: usize) []const u8 {
    comptime {
        var itr = std.mem.tokenizeScalar(u8, column, '\n');
        var result: []const u8 = "";
        if (line.len > idx) {
            result = result ++ line;
        } else {
            result = result ++ line ++ @as([idx - line.len]u8, @splat(' ')) ++ (itr.next() orelse "");
        }
        const spacer = @as([idx]u8, @splat(' '));
        while (itr.next()) |next_line| {
            result = result ++ "\n" ++ spacer ++ next_line;
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
    ;
    try std.testing.expectEqualStrings(expected, appendColumn(line, column, 10));
}

pub inline fn argumentHelpText(comptime idx: ?usize, comptime t: types.CliType, comptime description: []const u8) []const u8 {
    return appendColumn(
        if (idx) |i| std.fmt.comptimePrint("{d: >3}: {s: <25}", .{ i, t.hint() }) else std.fmt.comptimePrint("  *: {s: <25}", .{t.hint()}),
        columnizeComptime(description, DESCRIPTION_WIDTH, DESCRIPTION_INDENT),
        DESCRIPTION_COLUMN_IDX,
    );
}

test "argument_help_text" {
    const expected =
        \\  0: TEXT                     this is a test description for a test argument so 
        \\                                I can validate the argument help text. 
    ;
    const actual = argumentHelpText(0, .init([]const u8), "this is a test description for a test argument so I can validate the argument help text.");
    try std.testing.expectEqualStrings(expected, actual);
}

test "argument_help_text_variadic" {
    const expected =
        \\  *: TEXT                     this is a test description for a test argument so 
        \\                                I can validate the argument help text. 
    ;
    const actual = argumentHelpText(null, .init([]const u8), "this is a test description for a test argument so I can validate the argument help text.");
    try std.testing.expectEqualStrings(expected, actual);
}

pub inline fn flagHelpText(
    comptime long: ?[]const u8,
    comptime short: ?[]const u8,
    comptime description: []const u8,
) []const u8 {
    comptime {
        var short_flags: []const u8 = short orelse "";
        const long_flags = long orelse "";
        if (short_flags.len > 0 and long_flags.len > 0) short_flags = short_flags ++ ",";
        const line = appendColumn("  " ++ short_flags, long_flags, LONG_FLAG_COLUMN_IDX);
        return appendColumn(line, columnizeComptime(description, DESCRIPTION_WIDTH, DESCRIPTION_INDENT), DESCRIPTION_COLUMN_IDX);
    }
}

test "flag_help_text" {
    const cases = .{
        .{
            null,
            "-y",
            "some description",
            "  -y                          some description",
        },
        .{
            null,
            "-y/-n",
            "some description",
            "  -y/-n                       some description",
        },
        .{
            "--yes",
            "-y/-n",
            "some description",
            "  -y/-n, --yes                some description",
        },
        .{
            "--yes/--no",
            "-y/-n",
            "some description",
            "  -y/-n, --yes/--no           some description",
        },
        .{
            "--yes/--no",
            "-y",
            "some description",
            "  -y,    --yes/--no           some description",
        },
        .{
            "--yes",
            "-y",
            "some description",
            "  -y,    --yes                some description",
        },
        .{
            "--yes/--no",
            null,
            "some description",
            "         --yes/--no           some description",
        },
        .{
            "--yes",
            null,
            "some description",
            "         --yes                some description",
        },
    };
    inline for (cases) |case| {
        const long, const short, const desc, const expected = case;
        try std.testing.expectEqualStrings(expected, flagHelpText(long, short, desc));
    }
}

pub inline fn optionHelpText(
    comptime long: ?[]const u8,
    comptime short: ?[]const u8,
    comptime t: types.CliType,
    comptime description: []const u8,
) []const u8 {
    comptime {
        const line = fmt_line: {
            if (short) |s| {
                if (long) |l| {
                    break :fmt_line std.fmt.comptimePrint("  {s},    {s}={s}", .{ s, l, t.hint() });
                } else {
                    break :fmt_line std.fmt.comptimePrint("  {s} {s}", .{ s, t.hint() });
                }
            } else {
                if (long) |l| {
                    break :fmt_line std.fmt.comptimePrint("         {s}={s}", .{ l, t.hint() });
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

test "option_help_text" {
    const cases = .{
        .{
            "--option",
            null,
            usize,
            "some description",
            "         --option=SIZE        some description",
        },
        .{
            "--option",
            "-o",
            usize,
            "some description",
            "  -o,    --option=SIZE        some description",
        },
        .{
            null,
            "-o",
            usize,
            "some description",
            "  -o SIZE                     some description",
        },
    };
    inline for (cases) |case| {
        const long, const short, const t, const desc, const expected = case;
        try std.testing.expectEqualStrings(expected, optionHelpText(long, short, .init(t), desc));
    }
}

pub inline fn commandHelpText(comptime name: []const u8, comptime description: []const u8) []const u8 {
    return appendColumn(
        "  " ++ name,
        columnizeComptime(description, DESCRIPTION_WIDTH, DESCRIPTION_INDENT),
        DESCRIPTION_COLUMN_IDX,
    );
}

test "command_help_text" {
    try std.testing.expectEqualStrings("  hello                       some description", commandHelpText("hello", "some description"));
}
