//! Covers src/chip/periph/ssie/ssie_tap.zig and the listener hook in
//! src/chip/periph/ssie/ssie.zig.
const std = @import("std");
const ssie = @import("ra8").chip.periph.ssie;
const tap = ssie.tap;

const ch0 = ssie.channelAddress(0);

const Heard = struct {
    words: [8]u32 = undefined,
    count: usize = 0,

    fn hear(context: *anyopaque, word: u32) void {
        const self: *Heard = @ptrCast(@alignCast(context));
        self.words[self.count] = word;
        self.count += 1;
    }

    fn listener(self: *Heard) tap.Tap {
        return .{ .context = self, .sample = hear };
    }
};

fn ssicr(dwl: u32, frm: u32, right: bool) u32 {
    return (dwl << tap.dwl_shift) | (frm << tap.frm_shift) | (if (right) tap.pdta else 0);
}

test "DWL names the data word, and its prohibited encoding gives no shape" {
    const bits = [_]u6{ 8, 16, 18, 20, 22, 24, 32 };
    for (bits, 0..) |want, dwl| {
        const got = tap.shape(ssicr(@intCast(dwl), 0, false)) orelse return error.NoShape;
        try std.testing.expectEqual(want, got.data_bits);
    }
    try std.testing.expectEqual(@as(?tap.Shape, null), tap.shape(ssicr(7, 0, false)));
}

test "FRM names the words per frame: I2S two, TDM four, six, eight" {
    const words = [_]u4{ 2, 4, 6, 8 };
    for (words, 0..) |want, frm| {
        const got = tap.shape(ssicr(1, @intCast(frm), false)) orelse return error.NoShape;
        try std.testing.expectEqual(want, got.channels);
    }
}

test "PDTA picks where the sample sits in the word" {
    const left = tap.shape(ssicr(1, 0, false)).?;
    const right = tap.shape(ssicr(1, 0, true)).?;
    try std.testing.expect(!left.right_justified and right.right_justified);
    try std.testing.expectEqual(@as(u32, 0xABCD), left.value(0xABCD_1234));
    try std.testing.expectEqual(@as(u32, 0x1234), right.value(0xABCD_1234));
    const twenty = tap.shape(ssicr(3, 0, false)).?;
    try std.testing.expectEqual(@as(u32, 0xABCD1), twenty.value(0xABCD_1234));
    const full = tap.shape(ssicr(6, 0, false)).?;
    try std.testing.expectEqual(@as(u32, 0xABCD_1234), full.value(0xABCD_1234));
}

test "the listener hears each sample shifted out with TEN set, in order" {
    var block = ssie.Ssie.init();
    var heard: Heard = .{};
    block.channels[0].listener = heard.listener();
    block.write(ch0 + ssie.off_ssicr, 4, ssie.field.ten);
    block.write(ch0 + ssie.off_ssiftdr, 4, 0x1111);
    block.write(ch0 + ssie.off_ssiftdr, 4, 0x2222);
    try std.testing.expectEqualSlices(u32, &.{ 0x1111, 0x2222 }, heard.words[0..heard.count]);
}

test "staged samples reach the listener when TEN drains them, not before" {
    var block = ssie.Ssie.init();
    var heard: Heard = .{};
    block.channels[0].listener = heard.listener();
    block.write(ch0 + ssie.off_ssiftdr, 4, 0x0AAA);
    block.write(ch0 + ssie.off_ssiftdr, 4, 0x0BBB);
    try std.testing.expectEqual(@as(usize, 0), heard.count);
    block.write(ch0 + ssie.off_ssicr, 4, ssie.field.ten);
    try std.testing.expectEqualSlices(u32, &.{ 0x0AAA, 0x0BBB }, heard.words[0..heard.count]);
}

test "a store too narrow to carry a sample is never heard" {
    var block = ssie.Ssie.init();
    var heard: Heard = .{};
    block.channels[0].listener = heard.listener();
    block.write(ch0 + ssie.off_ssicr, 4, ssie.field.ten);
    block.write(ch0 + ssie.off_ssiftdr, 2, 0x7777);
    try std.testing.expectEqual(@as(usize, 0), heard.count);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].narrow_writes);
}
