//! Covers src/interfaces/gui/present_gate.zig: an unchanged list presents once, a
//! change presents once more, a forced redraw presents an unchanged list,
//! presents keep to the interval when every frame changes, and an image
//! refilled in place changes the digest.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const present_gate = gui_app.present_gate;
const draw_list = ra8.render.draw_list;
const Color = draw_list.Color;

const ms: i128 = std.time.ns_per_ms;

/// Runs one frame of `digest` at `now`, returning whether it presented.
fn frame(gate: *present_gate.Gate, digest: u64, now: i128, interval: u64) bool {
    if (!gate.due(digest, now, interval)) return false;
    gate.presented(digest, now);
    return true;
}

test "an unchanged list presents once and then not again over many frames" {
    var gate = present_gate.Gate{};
    var presents: u32 = 0;
    for (0..120) |i| {
        if (frame(&gate, 7, @as(i128, @intCast(i)) * 16 * ms, 0)) presents += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), presents);
}

test "one change presents once" {
    var gate = present_gate.Gate{};
    try std.testing.expect(frame(&gate, 1, 0, 0));
    try std.testing.expect(!frame(&gate, 1, ms, 0));
    try std.testing.expect(frame(&gate, 2, 2 * ms, 0));
    try std.testing.expect(!frame(&gate, 2, 3 * ms, 0));
}

test "a forced redraw presents an unchanged list once" {
    var gate = present_gate.Gate{};
    try std.testing.expect(frame(&gate, 1, 0, 0));
    gate.force();
    try std.testing.expect(frame(&gate, 1, ms, 0));
    try std.testing.expect(!frame(&gate, 1, 2 * ms, 0));
}

test "presents keep to the interval when every frame changes" {
    var gate = present_gate.Gate{};
    var presents: u32 = 0;
    // A thousand changed frames over one second at the 60 Hz cap.
    for (0..1000) |i| {
        if (frame(&gate, i, @as(i128, @intCast(i)) * ms, present_gate.default_interval_ns)) presents += 1;
    }
    try std.testing.expect(presents >= 59 and presents <= 61);
}

test "a change held back by the interval presents once the interval passes" {
    var gate = present_gate.Gate{};
    const interval = present_gate.default_interval_ns;
    try std.testing.expect(frame(&gate, 1, 0, interval));
    try std.testing.expect(!frame(&gate, 2, ms, interval));
    try std.testing.expect(frame(&gate, 2, 17 * ms, interval));
}

test "an image refilled in place changes the digest" {
    var pixels = @as([4]Color, @splat(Color.rgb(1, 2, 3)));
    var list = draw_list.DrawList.init(std.testing.allocator, 8, 8);
    defer list.deinit();
    try list.image(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, .{ .width = 2, .height = 2, .pixels = &pixels });
    const before = present_gate.digest(&list);
    try std.testing.expectEqual(before, present_gate.digest(&list));
    pixels[3] = Color.rgb(4, 5, 6);
    try std.testing.expect(before != present_gate.digest(&list));
}

test "a moved fill or a resized list changes the digest" {
    var list = draw_list.DrawList.init(std.testing.allocator, 8, 8);
    defer list.deinit();
    try list.fill(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, Color.rgb(9, 9, 9));
    const before = present_gate.digest(&list);
    list.clear();
    try list.fill(.{ .x = 1, .y = 0, .w = 2, .h = 2 }, Color.rgb(9, 9, 9));
    try std.testing.expect(before != present_gate.digest(&list));
    var wider = draw_list.DrawList.init(std.testing.allocator, 9, 8);
    defer wider.deinit();
    try wider.fill(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, Color.rgb(9, 9, 9));
    try std.testing.expect(before != present_gate.digest(&wider));
}
