//! Covers src/chip/core/tt.zig: the TT decode and the response word built from
//! the board's SAU.
const std = @import("std");
const ra8 = @import("ra8");
const sau = ra8.chip.periph.sau;
const tt = ra8.chip.core.csel.tt;
const field = tt.field;

const enable: u32 = 1 << 0;
const both = field.r | field.rw;

/// A SAU with region `index` spanning [base, limit] and the given NSC bit.
fn program(unit: *sau.Sau, index: usize, base: u32, limit: u32, nsc: bool) void {
    const rlar = (limit & 0xFFFF_FFE0) | (if (nsc) @as(u32, 2) else 0) | 1;
    unit.table[index] = sau.Region.fromPair(base, rlar);
}

/// The boot map's shape: Non-secure SRAM in region 0, a callable veneer
/// page in region 1, everything else Secure.
fn bootMap() sau.Sau {
    var unit = sau.Sau{ .ctrl = enable };
    program(&unit, 0, 0x3210_0000, 0x3217_FFFF, false);
    program(&unit, 1, 0x0200_8000, 0x0200_8FFF, true);
    return unit;
}

test "decode reads Rn, Rd and the A and T bits of all four forms" {
    const ttat = tt.decode(0xE840, 0xF3C0).?;
    try std.testing.expectEqual(@as(u4, 0), ttat.rn);
    try std.testing.expectEqual(@as(u4, 3), ttat.rd);
    try std.testing.expect(ttat.alternate and ttat.unprivileged);
    const tta = tt.decode(0xE841, 0xF380).?;
    try std.testing.expectEqual(@as(u4, 1), tta.rn);
    try std.testing.expect(tta.alternate and !tta.unprivileged);
    const ttt = tt.decode(0xE840, 0xF340).?;
    try std.testing.expect(!ttt.alternate and ttt.unprivileged);
    const plain = tt.decode(0xE840, 0xF300).?;
    try std.testing.expect(!plain.alternate and !plain.unprivileged);
}

test "decode leaves other encodings and the UNPREDICTABLE registers alone" {
    // STREX r3, r0 shares the first halfword's top bits.
    try std.testing.expectEqual(@as(?tt.Form, null), tt.decode(0xE840, 0x3000));
    try std.testing.expectEqual(@as(?tt.Form, null), tt.decode(0xE840, 0xF301));
    try std.testing.expectEqual(@as(?tt.Form, null), tt.decode(0xE84F, 0xF300));
    try std.testing.expectEqual(@as(?tt.Form, null), tt.decode(0xE840, 0xFD00));
    try std.testing.expectEqual(@as(?tt.Form, null), tt.decode(0xE840, 0xFF00));
}

test "a Non-secure region answers S clear with NSR, NSRW and its SREGION" {
    const unit = bootMap();
    const word = tt.respond(&unit, 0x3210_8EFC, true);
    const want = both | field.nsr | field.nsrw | field.srvalid | (0 << field.sregion_shift);
    try std.testing.expectEqual(want, word);
    try std.testing.expectEqual(@as(u32, 0), word & field.s);
}

test "a callable region is Secure and still names its region" {
    const unit = bootMap();
    const word = tt.respond(&unit, 0x0200_8010, true);
    try std.testing.expectEqual(both | field.s | field.srvalid | (1 << field.sregion_shift), word);
}

test "an address in no region is Secure with SRVALID clear" {
    const unit = bootMap();
    try std.testing.expectEqual(both | field.s, tt.respond(&unit, 0x0200_0100, true));
}

test "with the SAU disabled everything is Secure, as the reset map says" {
    var unit = bootMap();
    unit.ctrl = 0;
    try std.testing.expectEqual(both | field.s, tt.respond(&unit, 0x3210_8EFC, true));
}

test "from the Non-secure state only the MPU half is reported" {
    const unit = bootMap();
    try std.testing.expectEqual(both, tt.respond(&unit, 0x0200_0100, false));
    try std.testing.expectEqual(both, tt.respond(&unit, 0x3210_8EFC, false));
}

test "the executing state follows the attribution of the TT's own address" {
    const unit = bootMap();
    try std.testing.expect(tt.executingSecure(&unit, 0x0200_26EE));
    try std.testing.expect(tt.executingSecure(&unit, 0x0200_8010));
    try std.testing.expect(!tt.executingSecure(&unit, 0x3210_0100));
}
