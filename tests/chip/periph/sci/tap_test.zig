//! Covers src/chip/periph/sci/tap.zig through the SCI block: the tap sees
//! every byte any channel sends, with its channel, and none it drops.
const std = @import("std");
const ra8 = @import("ra8");
const sci = ra8.chip.periph.sci;

const Seen = struct {
    bytes: [32]u8 = undefined,
    channels: [32]usize = undefined,
    count: usize = 0,

    fn tap(self: *Seen) sci.Tap {
        return .{ .ctx = self, .sent = sent };
    }

    fn sent(ctx: *anyopaque, channel: usize, byte: u8) void {
        const self: *Seen = @ptrCast(@alignCast(ctx));
        self.bytes[self.count] = byte;
        self.channels[self.count] = channel;
        self.count += 1;
    }
};

fn put(unit: *sci.Sci, channel: usize, text: []const u8) void {
    for (text) |byte| unit.write(sci.regAddress(channel, sci.off_tdr), 4, byte);
}

test "the tap sees each sent byte with its channel, console or not" {
    var unit = sci.Sci.init();
    var seen = Seen{};
    unit.tap = seen.tap();
    unit.write(sci.regAddress(sci.console_channel, sci.off_ccr0), 4, sci.ccr0.te);
    unit.write(sci.regAddress(2, sci.off_ccr0), 4, sci.ccr0.te);
    put(&unit, sci.console_channel, "hi");
    put(&unit, 2, "!");
    try std.testing.expectEqualStrings("hi!", seen.bytes[0..seen.count]);
    try std.testing.expectEqualSlices(usize, &.{ sci.console_channel, sci.console_channel, 2 }, seen.channels[0..seen.count]);
    try std.testing.expectEqualStrings("", unit.line.slice());
}

test "a byte the transmitter drops never reaches the tap" {
    var unit = sci.Sci.init();
    var seen = Seen{};
    unit.tap = seen.tap();
    put(&unit, 4, "lost");
    try std.testing.expectEqual(@as(usize, 0), seen.count);
}
