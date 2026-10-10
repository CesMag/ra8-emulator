//! The `.ra8app` reader admits what ra8-firmware's loader admits.
const std = @import("std");
const ra8 = @import("ra8");
const ra8app = ra8.image.ra8app;

const code_len = 16;
const data_len = 8;
const image_len = ra8app.header_len + code_len + data_len;

fn put(bytes: []u8, index: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[index * 4 ..][0..4], value, .little);
}

/// A valid hello-world container: 16 bytes of code, 8 of data.
fn sample() [image_len]u8 {
    var bytes = @as([image_len]u8, @splat(0));
    const words = [_]u32{ ra8app.magic, ra8app.version, 4, code_len, data_len, 0x800, 1, ra8app.Capability.display };
    for (words, 0..) |value, index| put(&bytes, index, value);
    @memcpy(bytes[32..][0..9], "com.hello");
    @memcpy(bytes[64..][0..5], "Hello");
    for (bytes[ra8app.header_len..], 0..) |*byte, index| byte.* = @intCast(index + 1);
    return bytes;
}

test "the header is 160 bytes with the signature last" {
    try std.testing.expectEqual(@as(usize, 160), ra8app.header_len);
    try std.testing.expectEqual(@as(usize, 96), ra8app.signature_offset);
}

test "a valid container parses and its fields are read" {
    const bytes = sample();
    const header = try ra8app.parse(&bytes);
    try std.testing.expectEqualStrings("com.hello", header.id());
    try std.testing.expectEqualStrings("Hello", header.name());
    try std.testing.expectEqual(@as(u32, 4), header.entry_offset);
    try std.testing.expectEqual(@as(usize, image_len), header.imageLen());
    try std.testing.expectEqual(@as(u8, 1), ra8app.code(header, &bytes)[0]);
    try std.testing.expectEqual(@as(usize, data_len), ra8app.data(header, &bytes).len);
    try std.testing.expectEqual(@as(u8, code_len + 1), ra8app.data(header, &bytes)[0]);
}

test "wrong magic, revision, capability or text is a validation refusal" {
    var bytes = sample();
    put(&bytes, 0, 0x41385241);
    try std.testing.expectError(error.Validation, ra8app.parse(&bytes));
    bytes = sample();
    put(&bytes, 1, 2);
    try std.testing.expectError(error.Validation, ra8app.parse(&bytes));
    bytes = sample();
    put(&bytes, 7, 0x8);
    try std.testing.expectError(error.Validation, ra8app.parse(&bytes));
    bytes = sample();
    @memset(bytes[32..64], 'x');
    try std.testing.expectError(error.Validation, ra8app.parse(&bytes));
    bytes = sample();
    @memset(bytes[32..64], 0);
    try std.testing.expectError(error.Validation, ra8app.parse(&bytes));
}

test "an app asking for a newer API is unsupported" {
    var bytes = sample();
    put(&bytes, 6, ra8app.api_version_current + 1);
    try std.testing.expectError(error.Unsupported, ra8app.parse(&bytes));
}

test "sizes and the entry are held to their ranges" {
    const cases = [_]struct { index: usize, value: u32 }{
        .{ .index = 3, .value = 0 },
        .{ .index = 3, .value = ra8app.segment_max + 1 },
        .{ .index = 4, .value = ra8app.segment_max + 1 },
        .{ .index = 5, .value = ra8app.stack_min - 1 },
        .{ .index = 5, .value = ra8app.segment_max + 1 },
        .{ .index = 2, .value = code_len },
    };
    for (cases) |case| {
        var bytes = sample();
        put(&bytes, case.index, case.value);
        try std.testing.expectError(error.OutOfRange, ra8app.parse(&bytes));
    }
}

test "a file shorter than its header or its payload is short" {
    const bytes = sample();
    try std.testing.expectError(error.ShortImage, ra8app.parse(bytes[0 .. ra8app.header_len - 1]));
    try std.testing.expectError(error.ShortImage, ra8app.parse(bytes[0 .. image_len - 1]));
}
