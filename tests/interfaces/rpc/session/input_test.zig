//! Tests for src/interfaces/rpc/session/input.zig (RA8EMU-810) on a real
//! harness: the input request queues taps, swipes, long presses and button
//! presses on the board's input script, in virtual-time order.
const std = @import("std");
const ra8 = @import("ra8");

const server = ra8.rpc.session.server;
const input = ra8.rpc.session.input;
const proto = ra8.rpc.session.rpc;

const image = "tests/fixtures/fpu/fp_basic.elf";

fn send(context: *server.Context, args: proto.ScheduleInput) !void {
    switch (input.input(context, args)) {
        .ok => {},
        .err => |code| return if (code == .bad_args) error.BadArgs else error.Refused,
    }
}

test "a button press and a tap land on the input script in time order" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    try send(&context, .{ .core = .cpu0, .at_ns = 2_000_000, .kind = .tap, .x = 120, .y = 300 });
    try send(&context, .{ .core = .cpu0, .at_ns = 1_000_000, .kind = .button, .button = 1 });
    const script = &opened.board().input_script;
    try std.testing.expectEqual(@as(usize, 2), script.len);
    try std.testing.expectEqual(@as(u64, 1_000_000), script.events[0].at_ns);
    const pressed = script.events[0].event.button;
    try std.testing.expect(pressed.down);
    try std.testing.expectEqual(ra8.session.api.Button.sw2, pressed.button_id);
    try std.testing.expectEqual(@as(u64, 2_000_000), script.events[1].at_ns);
    const touched = script.events[1].event.tap;
    try std.testing.expectEqual(@as(u16, 120), touched.x);
    try std.testing.expectEqual(@as(u16, 300), touched.y);
}

test "a swipe and a long press carry their path and hold" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    try send(&context, .{ .core = .cpu0, .at_ns = 5, .kind = .swipe, .x = 10, .y = 20, .to_x = 400, .to_y = 20, .duration_ns = 300 });
    try send(&context, .{ .core = .cpu0, .at_ns = 9, .kind = .longpress, .x = 7, .y = 8, .duration_ns = 900 });
    const script = &opened.board().input_script;
    const swiped = script.events[0].event.swipe;
    try std.testing.expectEqual(@as(u16, 400), swiped.to.x);
    try std.testing.expectEqual(@as(u64, 300), swiped.duration_ns);
    const held = script.events[1].event.longpress;
    try std.testing.expectEqual(@as(u16, 7), held.point.x);
    try std.testing.expectEqual(@as(u64, 900), held.duration_ns);
}

test "an unknown button is bad_args and queues nothing" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    try std.testing.expectError(error.BadArgs, send(&context, .{ .core = .cpu0, .at_ns = 1, .kind = .button, .button = 2 }));
    try std.testing.expectEqual(@as(usize, 0), opened.board().input_script.len);
}

test "a session without an input script refuses cleanly" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    const session = opened.session();
    session.input_script = null;
    var context: server.Context = .{ .session = session, .scratch = &scratch };
    try std.testing.expectError(error.Refused, send(&context, .{ .core = .cpu0, .at_ns = 1, .kind = .tap }));
}
