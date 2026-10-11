//! The FPB register file: FP_CTRL's identification and keyed enable, the
//! comparators, and which comparator an instruction address matches.
const std = @import("std");
const ra8 = @import("ra8");

const fpb = ra8.session.fpb;

test "FP_CTRL reads version 2 with eight code comparators and no literals" {
    var unit = fpb.Fpb{};
    const ctrl = unit.read(fpb.offsets.ctrl).?;
    try std.testing.expectEqual(@as(u32, 1), ctrl >> 28);
    const code = ((ctrl >> 4) & 0x7) | (((ctrl >> 12) & 0x7) << 3);
    try std.testing.expectEqual(@as(u32, 8), code);
    try std.testing.expectEqual(@as(u32, 0), (ctrl >> 8) & 0xf);
    try std.testing.expectEqual(@as(u32, 0), ctrl & fpb.ctrl_bits.enable);
}

test "FP_CTRL only takes an enable written with KEY" {
    var unit = fpb.Fpb{};
    try std.testing.expect(unit.write(fpb.offsets.ctrl, fpb.ctrl_bits.enable));
    try std.testing.expect(!unit.enabled);
    _ = unit.write(fpb.offsets.ctrl, fpb.ctrl_bits.enable | fpb.ctrl_bits.key);
    try std.testing.expect(unit.enabled);
    try std.testing.expectEqual(fpb.ctrl_bits.enable, unit.read(fpb.offsets.ctrl).? & fpb.ctrl_bits.enable);
    _ = unit.write(fpb.offsets.ctrl, fpb.ctrl_bits.key);
    try std.testing.expect(!unit.enabled);
}

test "comparators read back, FP_REMAP reads zero, other offsets are unclaimed" {
    var unit = fpb.Fpb{};
    try std.testing.expect(unit.write(fpb.offsets.comp0 + 7 * 4, 0x2200_0009));
    try std.testing.expectEqual(@as(u32, 0x2200_0009), unit.read(fpb.offsets.comp0 + 7 * 4).?);
    try std.testing.expect(unit.write(fpb.offsets.remap, 0xffff_ffff));
    try std.testing.expectEqual(@as(u32, 0), unit.read(fpb.offsets.remap).?);
    try std.testing.expectEqual(null, unit.read(fpb.limits.span));
    try std.testing.expectEqual(null, unit.read(fpb.offsets.comp0 + 2));
    try std.testing.expect(!unit.write(fpb.limits.span, 1));
}

test "an enabled comparator in an enabled unit matches its address" {
    var unit = fpb.Fpb{};
    _ = unit.write(fpb.offsets.comp0 + 4, 0x2200_0008 | fpb.comp_enable);
    _ = unit.write(fpb.offsets.comp0, 0x2200_0020);
    try std.testing.expectEqual(null, unit.matches(0x2200_0008));
    _ = unit.write(fpb.offsets.ctrl, fpb.ctrl_bits.enable | fpb.ctrl_bits.key);
    try std.testing.expectEqual(@as(?usize, 1), unit.matches(0x2200_0008));
    try std.testing.expectEqual(null, unit.matches(0x2200_0020));
    try std.testing.expectEqual(null, unit.matches(0x2200_000a));
}

test {
    _ = @import("dwarf_line/dwarf_line_test.zig");
    _ = @import("source_test.zig");
    _ = @import("dwarf_line_find_test.zig");
    _ = @import("dwarf_frame_test.zig");
    _ = @import("unwind/unwind_test.zig");
    _ = @import("unwind/exception_test.zig");
}
