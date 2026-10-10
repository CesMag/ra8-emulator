//! Covers src/interfaces/gui/ui/hex_entry.zig (RA8EMU-742): only hex digits are typed,
//! upper-cased and up to the width; Backspace drops one; Enter commits the
//! value or cancels when empty; Escape cancels; and the drawn field is a
//! band with the caret after the digits.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const hex_entry = gui_app.hex_entry;

test "only hex digits are typed, upper-cased, up to the width" {
    var field = hex_entry.Field.init(8);
    field.typed("de ad-be:ef99");
    try std.testing.expectEqualStrings("DEADBEEF", field.text());
    var byte = hex_entry.Field.init(2);
    byte.typed("g5a7");
    try std.testing.expectEqualStrings("5A", byte.text());
}

test "backspace drops a digit and enter commits the value" {
    var field = hex_entry.Field.init(8);
    field.typed("12345");
    try std.testing.expect(field.key(hex_entry.codes.backspace) == .typing);
    try std.testing.expect(field.key(hex_entry.codes.delete) == .typing);
    try std.testing.expectEqualStrings("123", field.text());
    try std.testing.expect(field.key('a') == .typing);
    try std.testing.expectEqual(hex_entry.Outcome{ .commit = 0x123 }, field.key(hex_entry.codes.enter));
}

test "enter on an empty field and escape both cancel" {
    var field = hex_entry.Field.init(2);
    try std.testing.expect(field.key(hex_entry.codes.backspace) == .typing);
    try std.testing.expect(field.key(hex_entry.codes.enter) == .cancel);
    field.typed("7");
    try std.testing.expect(field.key(hex_entry.codes.escape) == .cancel);
}

test "the field draws a band with the caret after the digits" {
    const w: u32 = 32;
    const h: u32 = 16;
    var list = draw_list.DrawList.init(std.testing.allocator, w, h);
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, w, h);
    defer frame.deinit(std.testing.allocator);
    var field = hex_entry.Field.init(2);
    field.typed("a");
    try hex_entry.draw(&list, 4, 4, &field);
    raster.draw(&frame, &list, font.atlas);
    const band = hex_entry.bandRect(4, 4, &field);
    try std.testing.expectEqual(hex_entry.band, frame.at(@intCast(band.x + band.w - 1), @intCast(band.y)));
    const caret = hex_entry.caretRect(4, 4, &field);
    try std.testing.expectEqual(@as(i32, 4) + @as(i32, @intCast(font.textWidth(1))), caret.x);
    try std.testing.expectEqual(hex_entry.caret, frame.at(@intCast(caret.x), @intCast(caret.y + 2)));
}
