//! Tests for GUI action script parsing (RA8EMU-1120).
const std = @import("std");
const script = @import("gui_app").script;

test "parse timing variants: ms, s, and frames" {
    const text =
        \\# comment line
        \\at 500ms click 100 200
        \\// another comment
        \\at 1.5s click 150 250
        \\at frame 30 click 300 400
        \\at 0ms quit
    ;

    var parsed = try script.parser.parse(std.testing.allocator, text);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 4), parsed.items.items.len);

    const item0 = parsed.items.items[0];
    try std.testing.expectEqual(script.action.TimeSpec{ .time_ns = 500 * std.time.ns_per_ms }, item0.at);
    try std.testing.expectEqual(100, item0.action.click.coord.x);
    try std.testing.expectEqual(200, item0.action.click.coord.y);

    const item1 = parsed.items.items[1];
    try std.testing.expectEqual(script.action.TimeSpec{ .time_ns = 1500 * std.time.ns_per_ms }, item1.at);
    try std.testing.expectEqual(150, item1.action.click.coord.x);
    try std.testing.expectEqual(250, item1.action.click.coord.y);

    const item2 = parsed.items.items[2];
    try std.testing.expectEqual(script.action.TimeSpec{ .frame = 30 }, item2.at);
    try std.testing.expectEqual(300, item2.action.click.coord.x);
    try std.testing.expectEqual(400, item2.action.click.coord.y);

    const item3 = parsed.items.items[3];
    try std.testing.expectEqual(script.action.Action.quit, item3.action);
}

test "parse virtual and wall timing" {
    const text =
        \\at virtual 850ms quit
        \\at emulated 1.2s quit
        \\at wall 2000ms quit
        \\at real 5s quit
    ;

    var parsed = try script.parser.parse(std.testing.allocator, text);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 4), parsed.items.items.len);
    try std.testing.expectEqual(script.action.TimeSpec{ .virtual_ns = 850 * std.time.ns_per_ms }, parsed.items.items[0].at);
    try std.testing.expectEqual(script.action.TimeSpec{ .virtual_ns = 1200 * std.time.ns_per_ms }, parsed.items.items[1].at);
    try std.testing.expectEqual(script.action.TimeSpec{ .wall_ns = 2000 * std.time.ns_per_ms }, parsed.items.items[2].at);
    try std.testing.expectEqual(script.action.TimeSpec{ .wall_ns = 5000 * std.time.ns_per_ms }, parsed.items.items[3].at);
}

test "parse named click targets" {
    const text =
        \\at 1s click bar:run
        \\at 2s click bar:pause
        \\at 3s click bar:step
        \\at 4s click bar:speed
        \\at 5s click camera:allow_once
        \\at 6s click camera:always
        \\at 7s click camera:cam
        \\at 8s click camera:grd
        \\at 9s click board:sw1
        \\at 10s click board:sw2
        \\at 11s click board:touch 120 240
        \\at 12s click banner:confirm
        \\at 13s click banner:cancel
    ;

    var parsed = try script.parser.parse(std.testing.allocator, text);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 13), parsed.items.items.len);
    try std.testing.expectEqual(script.action.NamedTarget.bar_run, parsed.items.items[0].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.bar_pause, parsed.items.items[1].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.bar_step, parsed.items.items[2].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.bar_speed, parsed.items.items[3].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.camera_allow_once, parsed.items.items[4].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.camera_always, parsed.items.items[5].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.camera_cam, parsed.items.items[6].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.camera_grd, parsed.items.items[7].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.board_sw1, parsed.items.items[8].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.board_sw2, parsed.items.items[9].action.click.named);
    try std.testing.expectEqual(@as(u16, 120), parsed.items.items[10].action.click.touch.x);
    try std.testing.expectEqual(@as(u16, 240), parsed.items.items[10].action.click.touch.y);
    try std.testing.expectEqual(script.action.NamedTarget.banner_confirm, parsed.items.items[11].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.banner_cancel, parsed.items.items[12].action.click.named);
}

test "parse drag, type, and keys" {
    const text =
        \\at 500ms drag 10 20 110 220 300
        \\at 1s type "hello world"
        \\at 1.5s key Return
        \\at 2s key Escape
        \\at 2.5s key Space
    ;

    var parsed = try script.parser.parse(std.testing.allocator, text);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 5), parsed.items.items.len);

    const d = parsed.items.items[0].action.drag;
    try std.testing.expectEqual(10, d.from_x);
    try std.testing.expectEqual(20, d.from_y);
    try std.testing.expectEqual(110, d.to_x);
    try std.testing.expectEqual(220, d.to_y);
    try std.testing.expectEqual(300, d.duration_ms);

    try std.testing.expectEqualStrings("hello world", parsed.items.items[1].action.type_text);
    try std.testing.expectEqual(@as(u32, 13), parsed.items.items[2].action.key.code);
    try std.testing.expectEqual(@as(u32, 27), parsed.items.items[3].action.key.code);
    try std.testing.expectEqual(@as(u32, 32), parsed.items.items[4].action.key.code);
}

test "parse error conditions" {
    try std.testing.expectError(error.BadTiming, script.parser.parse(std.testing.allocator, "at abc click 1 2"));
    try std.testing.expectError(error.BadAction, script.parser.parse(std.testing.allocator, "at 1s dance"));
    try std.testing.expectError(error.BadTarget, script.parser.parse(std.testing.allocator, "at 1s click nonexistent:target"));
    try std.testing.expectError(error.BadCoordinates, script.parser.parse(std.testing.allocator, "at 1s click"));
}

test "parse named and modified keys" {
    const text =
        \\at 1s key shift+f5
        \\at 2s key ctrl+shift+f11
        \\at 3s key Home
        \\at 4s key End
        \\at 5s key Left
        \\at 6s key Right
        \\at 7s key ctrl+f11
    ;

    var parsed = try script.parser.parse(std.testing.allocator, text);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 7), parsed.items.items.len);
    const keys = parsed.items.items;

    try std.testing.expectEqual(script.action.KeyCode.f5, keys[0].action.key.code);
    try std.testing.expectEqual(true, keys[0].action.key.shift);
    try std.testing.expectEqual(false, keys[0].action.key.primary);

    try std.testing.expectEqual(script.action.KeyCode.f11, keys[1].action.key.code);
    try std.testing.expectEqual(true, keys[1].action.key.shift);
    try std.testing.expectEqual(true, keys[1].action.key.primary);

    try std.testing.expectEqual(script.action.KeyCode.home, keys[2].action.key.code);
    try std.testing.expectEqual(script.action.KeyCode.end, keys[3].action.key.code);
    try std.testing.expectEqual(script.action.KeyCode.left, keys[4].action.key.code);
    try std.testing.expectEqual(script.action.KeyCode.right, keys[5].action.key.code);

    try std.testing.expectEqual(script.action.KeyCode.f11, keys[6].action.key.code);
    try std.testing.expectEqual(true, keys[6].action.key.primary);
    try std.testing.expectEqual(false, keys[6].action.key.shift);
}

test "parse an unknown key modifier is a bad target" {
    try std.testing.expectError(error.BadTarget, script.parser.parse(std.testing.allocator, "at 1s key alt+f5"));
    try std.testing.expectError(error.BadTarget, script.parser.parse(std.testing.allocator, "at 1s key shift+"));
}

test "parse the seek and track click targets" {
    const text =
        \\at 1s click bar:seek
        \\at 2s click bar:track
    ;

    var parsed = try script.parser.parse(std.testing.allocator, text);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.items.items.len);
    try std.testing.expectEqual(script.action.NamedTarget.bar_seek, parsed.items.items[0].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.bar_track, parsed.items.items[1].action.click.named);
}

test "branch tree and diff targets parse" {
    var parsed = try script.parser.parse(std.testing.allocator, "at 1s click tree:node1\nat 2s click diff:earlier\n");
    defer parsed.deinit();
    try std.testing.expectEqual(script.action.NamedTarget.tree_node_1, parsed.items.items[0].action.click.named);
    try std.testing.expectEqual(script.action.NamedTarget.diff_earlier, parsed.items.items[1].action.click.named);
}
