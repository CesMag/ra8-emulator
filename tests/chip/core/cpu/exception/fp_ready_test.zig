const std = @import("std");
const ra8 = @import("ra8");
const fp_ready = ra8.chip.core.cpu.exception.fp_ready;
const entry = ra8.chip.core.cpu.exception.entry;
const regs = ra8.chip.core.cpu.regs;
const memmap = ra8.chip.core.memmap;
const fixture = @import("ram.zig");

const memfaultena: u32 = 1 << 16;
const busfaultena: u32 = 1 << 17;
const usgfaultena: u32 = 1 << 18;
const securefaultena: u32 = 1 << 19;
const all_enabled = memfaultena | busfaultena | usgfaultena | securefaultena;
const mon_en: u32 = 1 << 16;
const thread_level: i16 = 256;

test "Thread mode with every fault enabled: every bit is ready" {
    const now = fp_ready.ready(all_enabled, 0, 0, mon_en, thread_level);
    try std.testing.expect(now.hf and now.mm and now.bf and now.sf and now.mon and now.uf);
}

test "a disabled fault, or the monitor without MON_EN, is not ready" {
    const now = fp_ready.ready(usgfaultena, 0, 0, 0, thread_level);
    try std.testing.expect(now.hf and now.uf);
    try std.testing.expect(!now.mm and !now.bf and !now.sf and !now.mon);
}

test "a fault whose priority cannot preempt the running level is not ready" {
    // MemManage 0x40, BusFault 0x80, UsageFault 0x20, SecureFault 0x60.
    const shpr1: u32 = 0x6020_8040;
    const now = fp_ready.ready(all_enabled, shpr1, 0x90, mon_en, 0x60);
    try std.testing.expect(now.mm and now.uf);
    try std.testing.expect(!now.bf and !now.sf and !now.mon);
}

test "FAULTMASK leaves nothing ready, HardFault included" {
    const now = fp_ready.ready(all_enabled, 0, 0, mon_en, -1);
    try std.testing.expect(!now.hf and !now.mm and !now.bf and !now.sf and !now.mon and !now.uf);
}

test "PRIMASK: HardFault is ready, the configurable faults are not" {
    const now = fp_ready.ready(all_enabled, 0, 0, mon_en, 0);
    try std.testing.expect(now.hf);
    try std.testing.expect(!now.mm and !now.uf and !now.mon);
}

test "a lazy entry records the readiness the interrupted code had" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, usgfaultena | busfaultena);
    var cpu = try fixture.boot(&ram);
    cpu.regs.control |= regs.control_bits.fpca;
    _ = try entry.take(&cpu, 11, 0x2000_0102);
    const fpccr = cpu.fp.context.fpccr;
    try std.testing.expectEqual(@as(u1, 1), fpccr.lspact);
    try std.testing.expectEqual(@as(u1, 1), fpccr.hfrdy);
    try std.testing.expectEqual(@as(u1, 1), fpccr.ufrdy);
    try std.testing.expectEqual(@as(u1, 1), fpccr.bfrdy);
    try std.testing.expectEqual(@as(u1, 0), fpccr.mmrdy);
    try std.testing.expectEqual(@as(u1, 0), fpccr.monrdy);
}

test "an eager entry leaves the readiness bits alone" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, usgfaultena);
    var cpu = try fixture.boot(&ram);
    cpu.fp.context.fpccr.lspen = 0;
    cpu.regs.control |= regs.control_bits.fpca;
    _ = try entry.take(&cpu, 11, 0x2000_0102);
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.context.fpccr.ufrdy);
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.context.fpccr.hfrdy);
}
