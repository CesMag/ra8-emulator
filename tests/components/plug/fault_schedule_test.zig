//! Covers src/components/fault/schedule.zig: the `--faults FILE`
//! grammar, its virtual times, and refusing a bad file at the right line.
const std = @import("std");
const ra8 = @import("ra8");
const model = ra8.components.model;
const schedule = model.fault.schedule;
const Error = schedule.Error;

const s: u64 = 1_000_000_000;

fn expectRefused(text: []const u8, want: anyerror, line: u32) !void {
    var diag = schedule.Diagnostic{};
    const got = schedule.parse(std.testing.allocator, text, &diag);
    try std.testing.expectError(want, got);
    try std.testing.expectEqual(line, diag.line);
}

test "times add up their units, biggest first" {
    try std.testing.expectEqual(90 * s, try schedule.parseTime("90s"));
    try std.testing.expectEqual((3 * 86_400 + 12 * 3_600 + 5 * 60) * s, try schedule.parseTime("3d12h05m"));
    try std.testing.expectEqual(@as(u64, 250_000_000), try schedule.parseTime("250ms"));
    try std.testing.expectEqual(s + 1_500, try schedule.parseTime("1s1us500ns"));
    try std.testing.expectEqual(@as(u64, 0), try schedule.parseTime("0s"));
}

test "a malformed time is refused" {
    const bad = [_][]const u8{ "", "90", "s", "5m3h", "1s1s", "3x", "1.5s", "-1s", "99999999999d" };
    for (bad) |text| try std.testing.expectError(Error.BadTime, schedule.parseTime(text));
}

test "a good file gives every event in order with its line" {
    const text =
        \\# soak: lose the gauge for five minutes
        \\3d12h      unplug i2c:riic@0x36
        \\
        \\3d12h05m   plug   i2c:riic@0x36 max17048   # back again
        \\3d12h05m   fault  spi:spi1@ssl0 stuck:0xFF
        \\3d13h      clear  spi:spi1@ssl0
        \\3d13h      fault  i2c:riic@0x36 nack:3
    ;
    var diag = schedule.Diagnostic{};
    const got = try schedule.parse(std.testing.allocator, text, &diag);
    defer got.deinit(std.testing.allocator);
    const events = got.events;
    try std.testing.expectEqual(@as(usize, 5), events.len);
    try std.testing.expect(events[0].action == .unplug);
    try std.testing.expectEqual(@as(u32, 2), events[0].line);
    try std.testing.expectEqual((3 * 86_400 + 12 * 3_600) * s, events[0].at_ns);
    try std.testing.expectEqualStrings("max17048", events[1].action.plug);
    try std.testing.expectEqual(@as(u32, 4), events[1].line);
    try std.testing.expectEqual(@as(u8, 0xFF), events[2].action.fault.stuck);
    try std.testing.expect(events[3].action == .clear);
    try std.testing.expectEqual(@as(u32, 3), events[4].action.fault.nack_every);
    try std.testing.expectEqual(@as(u32, 0), diag.line);
}

test "an empty or comment-only file is an empty schedule" {
    var diag = schedule.Diagnostic{};
    const got = try schedule.parse(std.testing.allocator, "\n# nothing yet\n\n", &diag);
    defer got.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), got.events.len);
}

test "a bad line is refused with its line number" {
    try expectRefused("1s unplug i2c:riic@0x36\nsoon unplug i2c:riic@0x36", Error.BadTime, 2);
    try expectRefused("\n\n1s melt i2c:riic@0x36", Error.UnknownAction, 3);
    try expectRefused("1s unplug", Error.MissingField, 1);
    try expectRefused("1s", Error.MissingField, 1);
    try expectRefused("1s fault i2c:riic@0x36", Error.MissingField, 1);
    try expectRefused("1s plug i2c:riic@0x36", Error.MissingField, 1);
    try expectRefused("1s unplug i2c:riic@0x36 now", Error.ExtraField, 1);
    try expectRefused("1s plug i2c:riic@0x36 max17048 twice", Error.ExtraField, 1);
    try expectRefused("1s unplug usb:0", Error.UnknownKind, 1);
    try expectRefused("1s fault i2c:riic@0x36 melt", Error.UnknownMode, 1);
    try expectRefused("1s fault i2c:riic@0x36 nack:0", Error.BadArgument, 1);
}

test "times going backwards are refused at the later line" {
    try expectRefused("2m unplug i2c:riic@0x36\n1m plug i2c:riic@0x36 max17048", Error.TimeBackwards, 2);
}

test "what the run would refuse is refused up front" {
    try expectRefused("1s plug i2c:riic@0x36 toaster", Error.UnknownModel, 1);
    try expectRefused("1s plug uart:sci3 max17048", Error.WrongEndpoint, 1);
    try expectRefused("1s fault spi:spi1@ssl0 nack:2", Error.WrongBus, 1);
    try expectRefused("1s fault uart:sci3 bus_low", Error.WrongBus, 1);
    try expectRefused("1s fault gpio:P106 disconnected", Error.WrongBus, 1);
    try expectRefused("1s clear gpio:P106", Error.WrongBus, 1);
}
