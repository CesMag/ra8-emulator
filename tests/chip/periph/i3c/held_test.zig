//! The I3C touch line with its bus held low (`--fault ...=bus_low`,
//! RA8EMU-537): never free, and a START request goes nowhere.
const std = @import("std");
const ra8 = @import("ra8");
const flag = ra8.chip.periph.i3c_flags;
const i3c = ra8.chip.periph.i3c;

test "a held line never reads free" {
    var unit = i3c.I3c{};
    unit.devices.hold(true);
    try std.testing.expectEqual(@as(u32, 0), unit.readOffset(flag.reg.bcst));
    unit.devices.hold(false);
    try std.testing.expectEqual(flag.bcst.bfref, unit.readOffset(flag.reg.bcst));
}

test "a start on a held line opens nothing and is counted" {
    var unit = i3c.I3c{};
    unit.devices.hold(true);
    unit.writeOffset(flag.reg.cndctl, flag.cndctl.stcnd);
    try std.testing.expect(!unit.busy);
    try std.testing.expect(unit.readOffset(flag.reg.bst) & flag.bst.stcnddf == 0);
    try std.testing.expect(unit.readOffset(flag.reg.cndctl) & flag.cndctl.stcnd != 0);
    try std.testing.expectEqual(@as(u32, 1), unit.held_starts);
    try std.testing.expect(!unit.quiet());
}
