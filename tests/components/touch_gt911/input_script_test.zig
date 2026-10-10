const std = @import("std");
const script = @import("ra8").components.input_script;
const gt911 = @import("ra8").components.gt911;
const gpio = @import("ra8").chip.periph.gpio;
const host = @import("ra8").components.touch_input;
const switches = @import("ra8").board.switches;
const sw1 = switches.user[0];

test "timed tap dispatches when virtual time reaches it" {
    var events = script.Script{};
    try events.parse("at 2s tap 300 400\n");
    var panel = gt911.Panel{};
    var pins = gpio.Gpio.init();
    var input = host.Input{};
    events.dispatch(100, &panel, &pins, &input);
    try std.testing.expectEqual(@as(usize, 0), panel.queued_len);
    events.dispatch(2_000_000_100, &panel, &pins, &input);
    try std.testing.expectEqual(@as(usize, 1), panel.queued_len);
    try std.testing.expectEqual(gt911.Contact{ .x = 300, .y = 400 }, firmwareReport(&panel).?);
    try std.testing.expectEqual(@as(u32, 1), panel.reported);
}

test "swipe emits intermediate panel reports over its duration" {
    var events = script.Script{};
    try events.parse("at 0s swipe 900 700 100 700 250ms\n");
    var panel = gt911.Panel{};
    var pins = gpio.Gpio.init();
    var input = host.Input{};
    events.dispatch(0, &panel, &pins, &input);
    events.dispatch(50_000_000, &panel, &pins, &input);
    try std.testing.expectEqual(gt911.Contact{ .x = 740, .y = 700 }, panel.queued[1]);
    events.dispatch(100_000_000, &panel, &pins, &input);
    events.dispatch(150_000_000, &panel, &pins, &input);
    events.dispatch(200_000_000, &panel, &pins, &input);
    events.dispatch(250_000_000, &panel, &pins, &input);
    try std.testing.expectEqual(gt911.Contact{ .x = 100, .y = 700 }, panel.queued[5]);
    var last: ?gt911.Contact = null;
    while (firmwareReport(&panel)) |point| last = point;
    try std.testing.expectEqual(gt911.Contact{ .x = 100, .y = 700 }, last.?);
    try std.testing.expectEqual(@as(u32, 6), panel.reported);
}

test "longpress repeats contact reports until the release time" {
    var events = script.Script{};
    try events.parse("at 0s longpress 500 500 150ms\n");
    var panel = gt911.Panel{};
    var pins = gpio.Gpio.init();
    var input = host.Input{};
    events.dispatch(0, &panel, &pins, &input);
    events.dispatch(50_000_000, &panel, &pins, &input);
    events.dispatch(100_000_000, &panel, &pins, &input);
    try std.testing.expectEqual(@as(usize, 3), panel.queued_len);
    events.dispatch(150_000_000, &panel, &pins, &input);
    try std.testing.expectEqual(@as(usize, 3), panel.queued_len);
    while (firmwareReport(&panel)) |_| {}
    try std.testing.expectEqual(@as(u32, 3), panel.reported);
    try std.testing.expectEqual(@as(u32, 3), panel.acked);
}

test "power button maps to active-low SW1" {
    var events = script.Script{};
    try events.parse("at 0s button power\n");
    var panel = gt911.Panel{};
    var pins = switches.pulled();
    var input = host.Input{ .switches = &switches.user };
    events.dispatch(0, &panel, &pins, &input);
    try std.testing.expect(!pins.pinLevel(sw1.port, sw1.pin));
    events.dispatch(100_000_000, &panel, &pins, &input);
    try std.testing.expect(pins.pinLevel(sw1.port, sw1.pin));
}

test "script rejects out-of-order event times" {
    var events = script.Script{};
    try std.testing.expectError(error.OutOfOrder, events.parse("at 2s tap 3 4\nat 1s tap 5 6\n"));
}

fn firmwareReport(panel: *gt911.Panel) ?gt911.Contact {
    var status_byte: [1]u8 = undefined;
    panel.pointer = gt911.reg.status;
    _ = panel.read(&status_byte);
    if (status_byte[0] & gt911.status.ready == 0) return null;
    var record: [gt911.record.bytes]u8 = undefined;
    panel.pointer = gt911.reg.point0;
    _ = panel.read(&record);
    panel.pointer = gt911.reg.status;
    panel.taken = gt911.pointer_bytes;
    panel.write(0);
    return .{ .x = @as(u16, record[2]) << 8 | record[1], .y = @as(u16, record[4]) << 8 | record[3] };
}
