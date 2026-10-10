//! The GPTP register window: who answers, who is refused, and at what width.
const std = @import("std");
const ra8 = @import("ra8");

const gptp = ra8.chip.periph.gptp;
const timer = ra8.chip.periph.gptp_timer;

const four_ns: u32 = 4 << timer.scale.subns_shift;

fn unitReg(unit: usize, inoff: u32) u32 {
    return gptp.win_base + gptp.unitOffset(unit) + inoff;
}

fn started(block: *gptp.Gptp, unit: usize) void {
    block.write(gptp.win_base + gptp.unit_off.ptptivc + gptp.unitOffset(unit), 4, four_ns);
    block.write(gptp.win_base + gptp.off.ptptmec, 4, @as(u32, 1) << @intCast(unit));
}

test "PTPIPV reads its nonzero reset value, the block-presence probe" {
    var block = gptp.Gptp.init();
    try std.testing.expectEqual(gptp.ipv_reset, block.read(gptp.win_base + gptp.off.ptpipv, 4));
}

test "a store into PTPIPV is refused and counted, at any byte of it" {
    var block = gptp.Gptp.init();
    block.write(gptp.win_base + gptp.off.ptpipv, 4, 0xDEAD_BEEF);
    block.write(gptp.win_base + gptp.off.ptpipv + 2, 1, 0xFF);
    try std.testing.expectEqual(gptp.ipv_reset, block.read(gptp.win_base + gptp.off.ptpipv, 4));
    try std.testing.expectEqual(@as(u32, 5), block.read_only);
}

test "PTPTMEC starts a unit and reads back the live enable mask" {
    var block = gptp.Gptp.init();
    try std.testing.expectEqual(@as(u32, 0), block.read(gptp.win_base + gptp.off.ptptmec, 4));
    block.write(gptp.win_base + gptp.off.ptptmec, 4, 0b10);
    try std.testing.expectEqual(@as(u32, 0b10), block.read(gptp.win_base + gptp.off.ptptmec, 4));
    try std.testing.expect(block.units[1].enabled);
    try std.testing.expect(!block.units[0].enabled);
    try std.testing.expectEqual(@as(u32, 1), block.starts);
}

test "PTPTMDC stops a unit and clears its count, and reads back zero" {
    var block = gptp.Gptp.init();
    started(&block, 0);
    block.tick(timer.scale.ns_per_sec);
    block.write(gptp.win_base + gptp.off.ptptmdc, 4, 0b1);
    try std.testing.expectEqual(@as(u32, 0), block.read(gptp.win_base + gptp.off.ptptmdc, 4));
    try std.testing.expectEqual(@as(u32, 0), block.read(gptp.win_base + gptp.off.ptptmec, 4));
    try std.testing.expectEqual(@as(u64, 0), block.units[0].acc_sec);
    try std.testing.expectEqual(@as(u32, 1), block.stops);
}

test "an enable bit naming a unit this part does not have is counted" {
    var block = gptp.Gptp.init();
    block.write(gptp.win_base + gptp.off.ptptmec, 4, 0xF);
    try std.testing.expectEqual(@as(u32, 0b11), block.read(gptp.win_base + gptp.off.ptptmec, 4));
    try std.testing.expectEqual(@as(u32, 2), block.unknown_unit);
}

test "a disable bit naming no unit is counted too" {
    var block = gptp.Gptp.init();
    block.write(gptp.win_base + gptp.off.ptptmdc, 4, 0x1000);
    try std.testing.expectEqual(@as(u32, 1), block.unknown_unit);
}

test "a stopped unit's monitoring registers read zero" {
    var block = gptp.Gptp.init();
    try std.testing.expectEqual(@as(u32, 0), block.read(unitReg(0, gptp.unit_off.ptpgptptml), 4));
    try std.testing.expectEqual(@as(u32, 0), block.read(unitReg(0, gptp.unit_off.ptpgptptmm), 4));
}

test "a running unit's counter advances and the L read reports nanoseconds" {
    var block = gptp.Gptp.init();
    started(&block, 0);
    block.tick(timer.scale.ns_per_sec);
    block.tick(timer.scale.ns_per_sec);
    block.write(unitReg(0, gptp.unit_off.ptptovcu), 4, 0);
    block.write(unitReg(0, gptp.unit_off.ptptovcm), 4, 100);
    block.write(unitReg(0, gptp.unit_off.ptptovcl), 4, 0);
    try std.testing.expectEqual(@as(u32, 0), block.read(unitReg(0, gptp.unit_off.ptpgptptml), 4));
    try std.testing.expectEqual(@as(u32, 102), block.read(unitReg(0, gptp.unit_off.ptpgptptmm), 4));
}

test "the timer follows virtual time at the programmed ESWCLK rate" {
    var block = gptp.Gptp.init();
    started(&block, 0);
    block.tick(timer.scale.ns_per_sec / 2);
    try std.testing.expectEqual(
        @as(u32, 500_000_000),
        block.read(unitReg(0, gptp.unit_off.ptpgptptml), 4),
    );
}

test "fractional ESWCLK cycles carry across instruction chunks" {
    var block = gptp.Gptp.init();
    started(&block, 0);
    block.tick(1);
    block.tick(3);
    try std.testing.expectEqual(
        @as(u32, 4),
        block.read(unitReg(0, gptp.unit_off.ptpgptptml), 4),
    );
    try std.testing.expectEqual(@as(u64, 0), block.ns_remainder);
}

test "reading L latches M and U, so a three-read sample is one instant" {
    var block = gptp.Gptp.init();
    started(&block, 0);
    block.tick(timer.scale.ns_per_sec);
    _ = block.read(unitReg(0, gptp.unit_off.ptpgptptml), 4);
    block.tick(timer.scale.ns_per_sec);
    block.tick(timer.scale.ns_per_sec);
    try std.testing.expectEqual(@as(u32, 1), block.read(unitReg(0, gptp.unit_off.ptpgptptmm), 4));
    _ = block.read(unitReg(0, gptp.unit_off.ptpgptptml), 4);
    try std.testing.expectEqual(@as(u32, 3), block.read(unitReg(0, gptp.unit_off.ptpgptptmm), 4));
}

test "the AVTP view is the same instant in nanoseconds" {
    var block = gptp.Gptp.init();
    started(&block, 0);
    block.tick(timer.scale.ns_per_sec);
    const low = block.read(unitReg(0, gptp.unit_off.ptpavtptml), 4);
    const high = block.read(unitReg(0, gptp.unit_off.ptpavtptmu), 4);
    const flat = (@as(u64, high) << 32) | low;
    try std.testing.expectEqual(timer.scale.ns_per_sec, flat);
}

test "a halfword read of the top of a monitoring register is served, not zero" {
    var block = gptp.Gptp.init();
    started(&block, 0);
    block.tick(timer.scale.ns_per_sec);
    block.write(unitReg(0, gptp.unit_off.ptptovcu), 4, 0);
    block.write(unitReg(0, gptp.unit_off.ptptovcm), 4, 0x1234_5678);
    block.write(unitReg(0, gptp.unit_off.ptptovcl), 4, 0);
    _ = block.read(unitReg(0, gptp.unit_off.ptpgptptml), 4);
    const high = block.read(unitReg(0, gptp.unit_off.ptpgptptmm) + 2, 2);
    try std.testing.expectEqual(@as(u32, 0x1234), high);
}

test "a byte read of a monitoring register hands back one byte" {
    var block = gptp.Gptp.init();
    started(&block, 0);
    block.write(unitReg(0, gptp.unit_off.ptptovcu), 4, 0);
    block.write(unitReg(0, gptp.unit_off.ptptovcm), 4, 0xAABB_CCDD);
    block.write(unitReg(0, gptp.unit_off.ptptovcl), 4, 0);
    _ = block.read(unitReg(0, gptp.unit_off.ptpgptptml), 4);
    try std.testing.expectEqual(
        @as(u32, 0xDD),
        block.read(unitReg(0, gptp.unit_off.ptpgptptmm), 1),
    );
}

test "a store into a monitoring register is refused and counted" {
    var block = gptp.Gptp.init();
    started(&block, 0);
    block.write(unitReg(0, gptp.unit_off.ptpgptptmm), 4, 0xFFFF_FFFF);
    block.write(unitReg(0, gptp.unit_off.ptpavtptml) + 1, 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 5), block.faked);
    _ = block.read(unitReg(0, gptp.unit_off.ptpgptptml), 4);
    try std.testing.expectEqual(@as(u32, 0), block.read(unitReg(0, gptp.unit_off.ptpgptptmm), 4));
}

test "an offset committed with more than a second of nanoseconds is carried" {
    var block = gptp.Gptp.init();
    started(&block, 0);
    block.write(unitReg(0, gptp.unit_off.ptptovcu), 4, 0);
    block.write(unitReg(0, gptp.unit_off.ptptovcm), 4, 5);
    block.write(unitReg(0, gptp.unit_off.ptptovcl), 4, 1_050_000_000);
    try std.testing.expectEqual(@as(u32, 1), block.denormal);
    try std.testing.expectEqual(
        @as(u32, 50_000_000),
        block.read(unitReg(0, gptp.unit_off.ptpgptptml), 4),
    );
    try std.testing.expectEqual(@as(u32, 6), block.read(unitReg(0, gptp.unit_off.ptpgptptmm), 4));
}

test "the offset commits once however wide the store to L" {
    var block = gptp.Gptp.init();
    started(&block, 0);
    // A four-byte store is four bytes into the shadow and one commit, so a
    // carried offset is counted once rather than once per byte.
    block.write(unitReg(0, gptp.unit_off.ptptovcl), 4, 1_050_000_000);
    try std.testing.expectEqual(@as(u32, 1), block.denormal);
}

test "the nanoseconds field is thirty bits, so a wider value is masked first" {
    var block = gptp.Gptp.init();
    started(&block, 0);
    block.write(unitReg(0, gptp.unit_off.ptptovcl), 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 1), block.denormal);
    const now = block.units[0].now();
    try std.testing.expect(now.nsec < timer.scale.ns_per_sec);
    try std.testing.expectEqual(@as(u64, 1), now.sec);
}

test "the config registers read back what was written" {
    var block = gptp.Gptp.init();
    block.write(unitReg(1, gptp.unit_off.ptptivc), 4, four_ns);
    try std.testing.expectEqual(four_ns, block.read(unitReg(1, gptp.unit_off.ptptivc), 4));
    block.write(gptp.win_base + 0x800, 4, 0xCAFE_F00D);
    try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), block.read(gptp.win_base + 0x800, 4));
}

test "a narrow store into a config register keeps the bytes around it" {
    var block = gptp.Gptp.init();
    block.write(unitReg(0, gptp.unit_off.ptptivc), 4, 0xAABB_CCDD);
    block.write(unitReg(0, gptp.unit_off.ptptivc) + 1, 1, 0x11);
    try std.testing.expectEqual(
        @as(u32, 0xAABB_11DD),
        block.read(unitReg(0, gptp.unit_off.ptptivc), 4),
    );
}

test "the two units count independently" {
    var block = gptp.Gptp.init();
    started(&block, 1);
    block.tick(timer.scale.ns_per_sec);
    block.tick(timer.scale.ns_per_sec);
    try std.testing.expectEqual(@as(u32, 0), block.read(unitReg(0, gptp.unit_off.ptpgptptml), 4));
    _ = block.read(unitReg(1, gptp.unit_off.ptpgptptml), 4);
    try std.testing.expectEqual(@as(u32, 2), block.read(unitReg(1, gptp.unit_off.ptpgptptmm), 4));
}

test "an untouched block stays quiet in the report" {
    var block = gptp.Gptp.init();
    try std.testing.expect(block.quiet());
    _ = block.read(gptp.win_base + gptp.off.ptpipv, 4);
    try std.testing.expect(block.quiet());
    started(&block, 0);
    try std.testing.expect(!block.quiet());
}

test "an access outside the window is dropped" {
    var block = gptp.Gptp.init();
    block.write(gptp.win_base + gptp.win_span, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), block.read(gptp.win_base + gptp.win_span, 4));
}

test "the block descriptor covers the whole aperture" {
    var block = gptp.Gptp.init();
    const descriptor = block.block();
    try std.testing.expectEqual(gptp.win_base, descriptor.base);
    try std.testing.expectEqual(gptp.win_span, descriptor.size);
    try std.testing.expectEqualStrings("GPTP", descriptor.name);
}

test "the tail above the unit blocks is shadow, not a third unit" {
    try std.testing.expect(gptp.decode(0xA0) == null);
    try std.testing.expect(gptp.decode(0x00) == null);
    const spot = gptp.decode(0x60).?;
    try std.testing.expectEqual(@as(usize, 1), spot.unit);
    try std.testing.expectEqual(@as(u32, 0), spot.inoff);
}
