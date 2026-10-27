const std = @import("std");
const click = @import("zig_click");

const encode = click.Command("encode", "encode a string in base 64 encoding")
    .argument(click.hintedType([]const u8, "PLAINTEXT"), "text to encode. otherwise reads from stdin", .{})
    .handler(encode_handler);
fn encode_handler(ctx: click.Context, plaintext: []const u8) !void {
    const b64: Base64 = .init();
    const ciphertext = try b64.encodeString(ctx.gpa, plaintext);
    defer ctx.gpa.free(ciphertext);
    try ctx.stdout.print("{s}\n", .{ciphertext});
    try ctx.stdout.flush();
}

const decode = click.Command("decode", "decode a base 64 encoded string")
    .argument(click.hintedType([]const u8, "CIPHERTEXT"), "text to decode. otherwise reads from stdin", .{})
    .handler(decode_handler);
fn decode_handler(ctx: click.Context, ciphertext: []const u8) !void {
    const b64: Base64 = .init();
    const plaintext = try b64.decodeString(ctx.gpa, ciphertext);
    defer ctx.gpa.free(plaintext);
    try ctx.stdout.print("{s}\n", .{plaintext});
    try ctx.stdout.flush();
}

pub const base_64 = click.Group("base-64", "tools to encode & decode strings in base 64 encoding")
    .subcommand(encode)
    .subcommand(decode);

// ---------- library implementation ----------

pub const Base64EncodeError = error{
    InvalidEncodeByte,
};
pub const Base64DecodeError = error{
    InvalidDecodeByte,
    InvalidCyphertext,
};

pub const Base64 = struct {
    _mapping: *const [64]u8,

    pub fn init() Base64 {
        const upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        const lower = "abcdefghijklmnopqrstuvwxyz";
        const sym = "0123456789+/";
        const mapping = upper ++ lower ++ sym;

        return Base64{ ._mapping = mapping };
    }

    fn encodeByte(self: Base64, c: ?u8) Base64EncodeError!u8 {
        if (c) |cn| {
            return if (cn < 64) self._mapping[cn] else Base64EncodeError.InvalidEncodeByte;
        } else {
            return '=';
        }
    }

    fn decodeByte(_: Base64, c: u8) Base64DecodeError!?u8 {
        return switch (c) {
            'A'...'Z' => (c - 'A'),
            'a'...'z' => (c - 'a') + 26,
            '0'...'9' => (c - '0') + 52,
            '+' => 62,
            '/' => 63,
            '=' => null,
            else => Base64DecodeError.InvalidDecodeByte,
        };
    }

    pub fn encodeString(self: Base64, allocator: std.mem.Allocator, plaintext: []const u8) ![]u8 {
        const u6_mask = 0b111111;
        const ciphertext_len = try std.math.divCeil(usize, plaintext.len, 3) * 4;
        var ciphertext = try allocator.alloc(u8, ciphertext_len);
        errdefer allocator.free(ciphertext);
        @memset(ciphertext, 0);

        var j: usize = undefined;
        for (plaintext, 0..) |c, i| {
            switch (i % 3) {
                0 => {
                    j = i / 3 * 4;
                    ciphertext[j] = c >> 2;
                    ciphertext[j + 1] = c << 4;
                },
                1 => {
                    ciphertext[j + 1] |= c >> 4;
                    ciphertext[j + 2] = c << 2;
                },
                2 => {
                    ciphertext[j + 2] |= c >> 6;
                    ciphertext[j + 3] = c;
                },
                else => unreachable,
            }
        }
        for (0..ciphertext_len) |i| {
            ciphertext[i] = try self.encodeByte(u6_mask & ciphertext[i]);
        }
        // encode the padding character (=)
        switch (plaintext.len % 3) {
            1 => {
                ciphertext[ciphertext_len - 2] = '=';
                ciphertext[ciphertext_len - 1] = '=';
            },
            2 => {
                ciphertext[ciphertext_len - 1] = '=';
            },
            else => {},
        }
        return ciphertext;
    }

    fn _validateCyphertext(_: Base64, ciphertext: []const u8) Base64DecodeError!void {
        if (ciphertext.len % 4 != 0) return Base64DecodeError.InvalidCyphertext;
        var pad_bytes: usize = 0;
        for (ciphertext) |c| {
            switch (c) {
                'A'...'Z', 'a'...'z', '0'...'9', '+', '/' => {
                    if (pad_bytes > 0) return Base64DecodeError.InvalidCyphertext;
                },
                '=' => {
                    pad_bytes += 1;
                    if (pad_bytes > 2) return Base64DecodeError.InvalidCyphertext;
                },
                else => return Base64DecodeError.InvalidCyphertext,
            }
        }
    }

    pub fn decodeString(self: Base64, allocator: std.mem.Allocator, ciphertext: []const u8) ![]u8 {
        try self._validateCyphertext(ciphertext);
        const plaintext_len = p_len: {
            var pl = ciphertext.len / 4 * 3;
            if (ciphertext[ciphertext.len - 2] == '=') pl -= 1;
            if (ciphertext[ciphertext.len - 1] == '=') pl -= 1;
            break :p_len pl;
        };
        var plaintext = try allocator.alloc(u8, plaintext_len);
        errdefer allocator.free(plaintext);
        @memset(plaintext, 0);

        var j: usize = undefined;
        var holdover: u8 = undefined;
        for (ciphertext, 0..) |c, i| {
            const b = try self.decodeByte(c) orelse break;
            switch (i % 4) {
                0 => {
                    j = i / 4 * 3;
                    holdover = b << 2;
                },
                1 => {
                    plaintext[j] = holdover | (b >> 4);
                    holdover = b << 4;
                },
                2 => {
                    plaintext[j + 1] = holdover | (b >> 2);
                    holdover = b << 6;
                },
                3 => plaintext[j + 2] = holdover | b,
                else => unreachable,
            }
        }
        return plaintext;
    }
};
