const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const platform = gui_app.platform;
const shell_field = gui_app.shell_field;
const dark = &gui_app.colors.palettes.dark;

fn typed(bytes: []const u8) platform.Event {
    return .{ .text = platform.Text.of(bytes) };
}

fn key(code: u32) platform.Event {
    return .{ .key = .{ .code = code, .down = true } };
}

fn ready(field: *shell_field.Field, list: *draw_list.DrawList) !void {
    try field.init("type here");
    try field.draw(list, dark, .{ .x = 10, .y = 10, .w = 200, .h = shell_field.height });
    try std.testing.expect(field.press(20, 12));
}

test "a field ignores typing until a press focuses it" {
    var list = draw_list.DrawList.init(std.testing.allocator, 240, 40);
    defer list.deinit();
    var field: shell_field.Field = .{};
    try field.init("type here");
    try field.draw(&list, dark, .{ .x = 10, .y = 10, .w = 200, .h = shell_field.height });
    try std.testing.expect(!field.handle(typed("a")));
    try std.testing.expect(!field.press(5, 5));
    try std.testing.expect(!field.focused());
    try std.testing.expect(field.press(20, 12));
    try std.testing.expect(field.focused());
    try std.testing.expect(field.handle(typed("ab c")));
    try std.testing.expectEqualStrings("ab c", field.value());
}

test "backspace drops the last byte and enter submits once" {
    var list = draw_list.DrawList.init(std.testing.allocator, 240, 40);
    defer list.deinit();
    var field: shell_field.Field = .{};
    try ready(&field, &list);
    _ = field.handle(typed("led@gpio"));
    try std.testing.expect(field.handle(key(0x08)));
    try std.testing.expectEqualStrings("led@gpi", field.value());
    try std.testing.expect(!field.takeSubmit());
    try std.testing.expect(field.handle(key(0x0D)));
    try std.testing.expect(field.takeSubmit());
    try std.testing.expect(!field.takeSubmit());
    try std.testing.expect(!field.handle(key(0x1B)));
}

test "a press outside lets the field go and control bytes are not typed" {
    var list = draw_list.DrawList.init(std.testing.allocator, 240, 40);
    defer list.deinit();
    var field: shell_field.Field = .{};
    try ready(&field, &list);
    try std.testing.expect(!field.handle(typed("\x01\x7f")));
    try std.testing.expectEqual(@as(usize, 0), field.value().len);
    try std.testing.expect(!field.press(300, 300));
    try std.testing.expect(!field.focused());
}

test "the field stops at its capacity and clears" {
    var list = draw_list.DrawList.init(std.testing.allocator, 240, 40);
    defer list.deinit();
    var field: shell_field.Field = .{};
    try ready(&field, &list);
    for (0..shell_field.capacity + 10) |_| _ = field.handle(typed("x"));
    try std.testing.expectEqual(@as(usize, shell_field.capacity - 1), field.value().len);
    field.clear();
    try std.testing.expectEqual(@as(usize, 0), field.value().len);
    try std.testing.expect(field.focused());
}

test "the field paints its fill, its text and a caret while focused" {
    var list = draw_list.DrawList.init(std.testing.allocator, 240, 40);
    defer list.deinit();
    var field: shell_field.Field = .{};
    try ready(&field, &list);
    _ = field.handle(typed("cam"));
    list.clear();
    try field.draw(&list, dark, .{ .x = 10, .y = 10, .w = 200, .h = shell_field.height });
    var fills: usize = 0;
    var glyphs: usize = 0;
    for (list.commands.items) |command| switch (command.shape) {
        .fill => fills += 1,
        .glyph => glyphs += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 3), glyphs);
    try std.testing.expect(fills >= 2);
}

test "the field paints in the theme it is drawn with: its well behind its ink" {
    const light = &gui_app.colors.palettes.light;
    var list = draw_list.DrawList.init(std.testing.allocator, 240, 40);
    defer list.deinit();
    var field: shell_field.Field = .{};
    try field.init("type here");
    try field.draw(&list, light, .{ .x = 10, .y = 10, .w = 200, .h = shell_field.height });
    const first = list.commands.items[0].shape;
    try std.testing.expectEqual(light.well, first.fill.color);
    for (list.commands.items) |command| switch (command.shape) {
        .fill => |f| try std.testing.expect(!std.meta.eql(f.color, dark.well)),
        else => {},
    };
}
