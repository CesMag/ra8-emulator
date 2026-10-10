//! Tests for src/chip/periph/sci/sci_peek.zig.
const std = @import("std");
const ra8 = @import("ra8");
const sci = ra8.chip.periph.sci;
const sci_peek = ra8.chip.periph.sci_peek;

const channel: usize = 3;

fn open(unit: *sci.Sci) void {
    unit.write(sci.regAddress(channel, sci.off_ccr0), 4, sci.ccr0.te | sci.ccr0.re);
}

test "a peek of RDR shows the oldest byte and leaves it for the firmware" {
    var unit = sci.Sci.init();
    open(&unit);
    unit.feed(channel, "ok");
    const rdr = sci.regAddress(channel, sci.off_rdr);
    try std.testing.expectEqual(@as(u32, 'o'), sci_peek.peek(&unit, rdr, 4));
    try std.testing.expectEqual(@as(u32, 'o'), sci_peek.peek(&unit, rdr, 1));
    try std.testing.expectEqual(@as(u32, 0), sci_peek.peek(&unit, rdr + 1, 1));
    try std.testing.expectEqual(@as(u32, 0), unit.channels[channel].received);
    try std.testing.expectEqual(@as(u32, 'o'), unit.read(rdr, 4));
    try std.testing.expectEqual(@as(u32, 'k'), sci_peek.peek(&unit, rdr, 4));
}

test "a peek of RDR with the receiver off or nothing queued is zero" {
    var unit = sci.Sci.init();
    const rdr = sci.regAddress(channel, sci.off_rdr);
    unit.feed(channel, "x");
    try std.testing.expectEqual(@as(u32, 0), sci_peek.peek(&unit, rdr, 4));
    open(&unit);
    try std.testing.expectEqual(@as(u32, 'x'), sci_peek.peek(&unit, rdr, 4));
    _ = unit.read(rdr, 4);
    try std.testing.expectEqual(@as(u32, 0), sci_peek.peek(&unit, rdr, 4));
}

test "a peek of the status words matches the read and steps nothing" {
    var unit = sci.Sci.init();
    open(&unit);
    unit.feed(channel, "z");
    for ([_]u32{ sci.off_csr, sci.off_frsr, sci.off_ccr0 }) |offset| {
        const address = sci.regAddress(channel, offset);
        try std.testing.expectEqual(unit.read(address, 4), sci_peek.peek(&unit, address, 4));
    }
    try std.testing.expectEqual(@as(u32, 'z'), unit.read(sci.regAddress(channel, sci.off_rdr), 4));
}
