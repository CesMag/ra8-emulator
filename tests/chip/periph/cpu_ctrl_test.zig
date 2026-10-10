//! Tests for src/chip/periph/cpu_ctrl.zig.
const std = @import("std");
const ra8 = @import("ra8");
const cpu_ctrl = ra8.chip.periph.cpu_ctrl;

fn at(offset: u32) u32 {
    return cpu_ctrl.win_base + offset;
}

test "a fresh page has nothing to report and the core is not running" {
    var unit = cpu_ctrl.CpuCtrl{};
    try std.testing.expect(unit.quiet());
    try std.testing.expect(!unit.running());
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(cpu_ctrl.regs.actcsr), 2));
}

test "the release sequence raises ACT so the driver's poll ends" {
    var unit = cpu_ctrl.CpuCtrl{};
    unit.write(at(cpu_ctrl.regs.initvtor), 4, 0x0202_0000);
    unit.write(at(cpu_ctrl.regs.waitcr), 1, 0);
    unit.write(at(cpu_ctrl.regs.actcsr), 2, cpu_ctrl.key.value | cpu_ctrl.bits.actreq);
    const seen = unit.read(at(cpu_ctrl.regs.actcsr), 2);
    try std.testing.expect(seen & cpu_ctrl.bits.act != 0);
    try std.testing.expect(unit.running());
    try std.testing.expectEqual(@as(u32, 1), unit.accepted);
}

test "the key is part of the write and never comes back on the readback" {
    var unit = cpu_ctrl.CpuCtrl{};
    unit.write(at(cpu_ctrl.regs.actcsr), 2, cpu_ctrl.key.value | cpu_ctrl.bits.actreq);
    try std.testing.expectEqual(
        @as(u32, 0),
        unit.read(at(cpu_ctrl.regs.actcsr), 2) & cpu_ctrl.key.mask,
    );
}

test "a store without the key is dropped and counted, and ACT stays down" {
    var unit = cpu_ctrl.CpuCtrl{};
    unit.write(at(cpu_ctrl.regs.actcsr), 2, cpu_ctrl.bits.actreq);
    unit.write(at(cpu_ctrl.regs.actcsr), 2, 0x5A00 | cpu_ctrl.bits.actreq);
    try std.testing.expectEqual(@as(u32, 2), unit.refused);
    try std.testing.expectEqual(@as(u32, 0), unit.accepted);
    try std.testing.expect(!unit.act);
    try std.testing.expect(!unit.running());
}

test "a keyed store without ACTREQ does not activate the core" {
    var unit = cpu_ctrl.CpuCtrl{};
    unit.write(at(cpu_ctrl.regs.actcsr), 2, cpu_ctrl.key.value);
    try std.testing.expectEqual(@as(u32, 1), unit.accepted);
    try std.testing.expect(!unit.act);
    try std.testing.expect(!unit.running());
}

test "CPUWAIT stalls a core that was already activated" {
    var unit = cpu_ctrl.CpuCtrl{};
    unit.write(at(cpu_ctrl.regs.actcsr), 2, cpu_ctrl.key.value | cpu_ctrl.bits.actreq);
    try std.testing.expect(unit.running());
    unit.write(at(cpu_ctrl.regs.waitcr), 1, cpu_ctrl.bits.cpuwait);
    try std.testing.expect(!unit.running());
    try std.testing.expect(unit.act);
}

test "ACT is sticky because no deactivation path is documented" {
    var unit = cpu_ctrl.CpuCtrl{};
    unit.write(at(cpu_ctrl.regs.actcsr), 2, cpu_ctrl.key.value | cpu_ctrl.bits.actreq);
    unit.write(at(cpu_ctrl.regs.actcsr), 2, cpu_ctrl.key.value);
    try std.testing.expect(unit.act);
    try std.testing.expect(!unit.actreq);
}

test "CPU1WAITCR keeps only CPUWAIT" {
    var unit = cpu_ctrl.CpuCtrl{};
    unit.write(at(cpu_ctrl.regs.waitcr), 1, 0xFF);
    try std.testing.expectEqual(
        @as(u32, cpu_ctrl.bits.cpuwait),
        unit.read(at(cpu_ctrl.regs.waitcr), 1),
    );
}

test "CPU1INITVTOR is retained whole for the report to name" {
    var unit = cpu_ctrl.CpuCtrl{};
    unit.write(at(cpu_ctrl.regs.initvtor), 4, 0x0203_0080);
    try std.testing.expectEqual(
        @as(u32, 0x0203_0080),
        unit.read(at(cpu_ctrl.regs.initvtor), 4),
    );
    try std.testing.expect(!unit.quiet());
}

test "the block covers its own three registers and no more" {
    var unit = cpu_ctrl.CpuCtrl{};
    const b = unit.block();
    try std.testing.expect(b.covers(at(cpu_ctrl.regs.initvtor)));
    try std.testing.expect(b.covers(at(cpu_ctrl.regs.actcsr)));
    try std.testing.expect(!b.covers(cpu_ctrl.win_base + cpu_ctrl.win_span));
}

test "a system reset takes the page back to its reset values" {
    var page: cpu_ctrl.CpuCtrl = .{};
    page.write(cpu_ctrl.win_base + cpu_ctrl.regs.initvtor, 4, 0x2200_0400);
    page.write(cpu_ctrl.win_base + cpu_ctrl.regs.actcsr, 2, cpu_ctrl.key.value | cpu_ctrl.bits.actreq);
    try std.testing.expect(page.running());
    page.reset();
    try std.testing.expect(!page.running());
    try std.testing.expectEqual(@as(u32, 0), page.initvtor);
    try std.testing.expectEqual(@as(u32, 0), page.status());
    try std.testing.expectEqual(@as(u32, 1), page.accepted);
}
