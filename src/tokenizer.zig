//! tokenizer.zig
//!
//! an interface around the Args iterator which allows us to supply our own arg string for testing purposes

const std = @import("std");

/// Iterates over the input string and exposes individual tokens via the `next()` method
/// - in most shells tokens are separated by space ' ' characters.
/// - quotes are used to group multiple space-separated tokens into a single
///   command line arg, while the quotations themselves are stripped from the arguments.
///   *note: this tokenizer only supports this behavior for double quotes*
/// - However, for quotations that must exist within the argument token are preseded by the forward slash '\'
/// As a consequence of above rules, we cannot use std.mem.Tokenizer or pull tokens directly from the input string
/// instead we construct the proper tokens in a second buffer character-by-character.
/// Since the returned tokens could be used at any point during the program's lifetime, we cannot overwrite
/// tokens we previously returned, so we have no choice but to maintain all tokens side by side until deconstruction-time
pub const StringIterator = struct {
    str: []const u8,
    buf: []u8,
    pos: usize = 0,
    buf_pos: usize = 0,

    pub fn init(allocator: std.mem.Allocator, string: []const u8) !StringIterator {
        const buf = try allocator.alloc(u8, string.len);
        return StringIterator{ .str = string, .buf = buf };
    }

    pub fn deinit(self: *StringIterator, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
    }

    pub fn asTokenizer(self: *StringIterator) Tokenizer {
        return Tokenizer{ .stringIterator = self };
    }

    pub fn next(self: *StringIterator) ?[]const u8 {
        if (self.pos == self.str.len) return null;
        const token_start = self.buf_pos;
        var has_token = false;
        var quoted = false;
        var escaped = false;
        self.pos = next_token_start: {
            for (self.pos..self.str.len) |i| {
                const c = self.str[i];
                if (escaped) {
                    switch (c) {
                        '"', '\\' => {
                            self.buf[self.buf_pos] = c;
                            self.buf_pos += 1;
                        },
                        else => {
                            self.buf[self.buf_pos] = '\\';
                            self.buf[self.buf_pos + 1] = c;
                            self.buf_pos += 2;
                        },
                    }
                    escaped = false;
                } else if (quoted) switch (c) {
                    '\\' => escaped = true,
                    '"' => quoted = false,
                    else => {
                        self.buf[self.buf_pos] = c;
                        self.buf_pos += 1;
                    },
                } else switch (c) {
                    '\\' => {
                        has_token = true;
                        escaped = true;
                    },
                    '"' => {
                        has_token = true;
                        quoted = true;
                    },
                    ' ', '\n' => {
                        if (!has_token) continue;
                        break :next_token_start (i + 1);
                    },
                    else => {
                        has_token = true;
                        self.buf[self.buf_pos] = c;
                        self.buf_pos += 1;
                    },
                }
            }
            break :next_token_start self.str.len;
        };
        return if (has_token) self.buf[token_start..self.buf_pos] else null;
    }
};

/// Interface to abstract the actual source of command line argument tokens
/// we can either supply this from `std.process.Init.minimal` or from a string e.g. during testing
pub const Tokenizer = union(enum) {
    argsIterator: *std.process.Args.Iterator,
    stringIterator: *StringIterator,

    pub fn next(self: Tokenizer) ?[]const u8 {
        switch (self) {
            .argsIterator => |itr| return itr.next(),
            .stringIterator => |itr| return itr.next(),
        }
    }
};

test "test_string_tokenizer" {
    const allocator = std.testing.allocator;
    const input = "hello world \"hello world\" \"s/^\\(.*\\)\\\\(.*)$/\\1/g\"   --print=\"hello world\"  \"\"  ";
    const expected_tokens = [_][]const u8{
        "hello",
        "world",
        "hello world",
        // example `sed` program. uses quotations and a lot of escape sequences
        "s/^\\(.*\\)\\(.*)$/\\1/g",
        // example flag with quoted argument conjoined using `=` character
        "--print=hello world",
        "",
    };
    var string_tokenizer = try StringIterator.init(allocator, input);
    defer string_tokenizer.deinit(allocator);

    const tokenizer = Tokenizer{ .stringIterator = &string_tokenizer };
    for (expected_tokens) |expected| {
        try std.testing.expectEqualStrings(expected, tokenizer.next().?);
    }
    try std.testing.expect(tokenizer.next() == null);
}
