//! The VBATT control register file: read-back, the bits silicon owns, and the
//! flags a firmware clears rather than sets.
const std = @import("std");
const ra8 = @import("ra8");

const ctrl = ra8.chip.periph.bkup.ctrl;

test "every named register resolves to its own slot" {
    var seen = @as([ctrl.slot_count]bool, @splat(false));
    const offsets = [_]u32{
        ctrl.off.vbtber,   ctrl.off.vbtbpcr2,  ctrl.off.vbtbpsr,
        ctrl.off.vbtadsr,  ctrl.off.vbtadcr1,  ctrl.off.vbtadcr2,
        ctrl.off.vbtictlr, ctrl.off.vbtictlr2, ctrl.off.vbtimonr,
        ctrl.off.vbtncwcr, ctrl.off.vbtadcr3,
    };
    for (offsets) |offset| {
        const slot = ctrl.slotOf(offset) orelse return error.Unmapped;
        try std.testing.expect(!seen[@backingInt(slot)]);
        seen[@backingInt(slot)] = true;
    }
    for (seen) |hit| try std.testing.expect(hit);
}

test "an offset the file does not own stays unmapped" {
    try std.testing.expect(ctrl.slotOf(0x001) == null);
    try std.testing.expect(ctrl.slotOf(0x0C0) == null);
}

test "VBAE is armed out of reset" {
    var file = ctrl.Control.init();
    try std.testing.expect(file.vbaeSet());
    try std.testing.expectEqual(@as(u8, ctrl.vbtber.reset), file.read(ctrl.off.vbtber));
}

test "an untouched file stays out of the report" {
    var file = ctrl.Control.init();
    try std.testing.expect(file.quiet());
    file.write(ctrl.off.vbtncwcr, 0x03);
    try std.testing.expect(!file.quiet());
}

test "a control register reads back what was written" {
    var file = ctrl.Control.init();
    file.write(ctrl.off.vbtictlr, 0x05);
    try std.testing.expectEqual(@as(u8, 0x05), file.read(ctrl.off.vbtictlr));
    file.write(ctrl.off.vbtadcr2, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), file.read(ctrl.off.vbtadcr2));
}

test "this is the read-back that used to answer zero" {
    var file = ctrl.Control.init();
    file.write(ctrl.off.vbtictlr2, 0x07);
    try std.testing.expect(file.read(ctrl.off.vbtictlr2) != 0);
}

test "VBTBPCR2 keeps only VDETE and the level field" {
    var file = ctrl.Control.init();
    file.write(ctrl.off.vbtbpcr2, 0xFF);
    const kept = ctrl.vbtbpcr2.vdete | ctrl.vbtbpcr2.level;
    try std.testing.expectEqual(kept, file.read(ctrl.off.vbtbpcr2));
}

test "clearing VBAE closes the data array" {
    var file = ctrl.Control.init();
    file.write(ctrl.off.vbtber, 0);
    try std.testing.expect(!file.vbaeSet());
    file.write(ctrl.off.vbtber, ctrl.vbtber.vbae);
    try std.testing.expect(file.vbaeSet());
}

test "VBTIMONR refuses a store, it is a level the pins drive" {
    var file = ctrl.Control.init();
    file.write(ctrl.off.vbtimonr, 0x07);
    try std.testing.expectEqual(@as(u8, 0), file.read(ctrl.off.vbtimonr));
    try std.testing.expectEqual(@as(u32, 1), file.refused);
}

test "a monitor level the silicon raises does read back" {
    var file = ctrl.Control.init();
    file.raise(.imonr, 0x02);
    try std.testing.expectEqual(@as(u8, 0x02), file.read(ctrl.off.vbtimonr));
}

test "firmware cannot set VBPORF, only clear it" {
    var file = ctrl.Control.init();
    file.write(ctrl.off.vbtbpsr, ctrl.vbtbpsr.vbporf);
    try std.testing.expectEqual(@as(u8, 0), file.read(ctrl.off.vbtbpsr));
    try std.testing.expectEqual(@as(u32, 1), file.refused);
}

test "a write-zero clears VBPORF once the silicon raised it" {
    var file = ctrl.Control.init();
    file.raise(.bpsr, ctrl.vbtbpsr.vbporf);
    file.write(ctrl.off.vbtbpsr, 0);
    try std.testing.expectEqual(@as(u8, 0), file.read(ctrl.off.vbtbpsr));
    try std.testing.expectEqual(@as(u32, 1), file.cleared);
}

test "writing the flag back leaves it standing" {
    var file = ctrl.Control.init();
    file.raise(.bpsr, ctrl.vbtbpsr.vbporf);
    file.write(ctrl.off.vbtbpsr, ctrl.vbtbpsr.vbporf);
    try std.testing.expectEqual(ctrl.vbtbpsr.vbporf, file.read(ctrl.off.vbtbpsr));
    try std.testing.expectEqual(@as(u32, 0), file.cleared);
}

test "the read-only monitors survive a clear of the flag beside them" {
    var file = ctrl.Control.init();
    file.raise(.bpsr, ctrl.vbtbpsr.vbporf | ctrl.vbtbpsr.swm);
    file.write(ctrl.off.vbtbpsr, 0);
    try std.testing.expectEqual(ctrl.vbtbpsr.swm, file.read(ctrl.off.vbtbpsr));
}

test "one tamper flag clears without touching the other two" {
    var file = ctrl.Control.init();
    file.raise(.adsr, ctrl.vbtadsr.flags);
    file.write(ctrl.off.vbtadsr, 0x06);
    try std.testing.expectEqual(@as(u8, 0x06), file.read(ctrl.off.vbtadsr));
    try std.testing.expectEqual(@as(u32, ctrl.channels), 3);
}

test "a reset takes the file back to its reset row" {
    var file = ctrl.Control.init();
    file.write(ctrl.off.vbtictlr, 0x07);
    file.write(ctrl.off.vbtber, 0);
    file.reset();
    try std.testing.expectEqual(@as(u8, 0), file.read(ctrl.off.vbtictlr));
    try std.testing.expect(file.vbaeSet());
    try std.testing.expect(file.quiet());
}

test "every slot has a name" {
    var index: usize = 0;
    while (index < ctrl.slot_count) : (index += 1) {
        const slot: ctrl.Slot = @fromBackingInt(@intCast(index));
        try std.testing.expect(ctrl.nameOf(slot).len != 0);
    }
}
