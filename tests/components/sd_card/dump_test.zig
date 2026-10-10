const std = @import("std");
const ra8 = @import("ra8");
const sd_dump = ra8.components.sd_card.dump;

test "a row carries its offset, the bytes as hex, and the bytes as text" {
    var buf: sd_dump.Buffer = undefined;
    const bytes = [_]u8{ 'R', 'A', 'E', 'P', 'U', 'B', ' ', ' ', 'E', 'P', 'B', 0x20, 0, 0, 0, 0 };
    try std.testing.expectEqualStrings(
        "  0000  52 41 45 50 55 42 20 20 45 50 42 20 00 00 00 00  |RAEPUB  EPB ....|",
        sd_dump.row(&buf, 0, &bytes),
    );
}

test "the offset is where the row sits in the block" {
    var buf: sd_dump.Buffer = undefined;
    const out = sd_dump.row(&buf, 0x1E0, &[_]u8{0xAA});
    try std.testing.expect(std.mem.startsWith(u8, out, "  01E0  AA "));
}

test "a short final row pads its hex so the text column still lines up" {
    var buf: sd_dump.Buffer = undefined;
    var full: sd_dump.Buffer = undefined;
    const short = sd_dump.row(&buf, 0, &[_]u8{'A'});
    const whole = sd_dump.row(&full, 0, &(@as([sd_dump.row_bytes]u8, @splat('A'))));
    const bar_short = std.mem.indexOfScalar(u8, short, '|').?;
    const bar_whole = std.mem.indexOfScalar(u8, whole, '|').?;
    try std.testing.expectEqual(bar_whole, bar_short);
}

test "a byte that is not printable text shows as a dot" {
    var buf: sd_dump.Buffer = undefined;
    const out = sd_dump.row(&buf, 0, &[_]u8{ 0x00, 0x7F, 0xFF, '~' });
    try std.testing.expectEqualStrings("...~", out[out.len - 5 .. out.len - 1]);
}

test "a row of zeros is blank and anything else is not" {
    try std.testing.expect(sd_dump.blank(&(@as([sd_dump.row_bytes]u8, @splat(0)))));
    try std.testing.expect(!sd_dump.blank(&[_]u8{ 0, 0, 1, 0 }));
    try std.testing.expect(sd_dump.blank(&[_]u8{}));
}

test "the widest row still fits the buffer" {
    var buf: sd_dump.Buffer = undefined;
    const out = sd_dump.row(&buf, 0xFFFF, &(@as([sd_dump.row_bytes]u8, @splat(0xFF))));
    try std.testing.expect(out.len > 0);
    try std.testing.expect(out.len <= sd_dump.width);
}
