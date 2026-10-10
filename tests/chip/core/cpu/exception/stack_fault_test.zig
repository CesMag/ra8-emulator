//! Covers derived exception-frame faults through Cpu.step: MPU and bus
//! refusals on entry and return, routing, escalation, and lockup.

const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const fake_source = @import("fake_source.zig");
const bus = ra8.chip.core.cpu.bus;
const memmap = ra8.chip.core.memmap;
const mpu = ra8.chip.periph.mpu;
const mpu_check = ra8.chip.core.cpu.board_bus.mpu_check;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Stop = ra8.chip.core.cpu.cpu.Stop;
const dispatch = ra8.chip.core.cpu.exception.dispatch;

const mem_handler: u32 = fixture.base + 0x180;
const bus_handler: u32 = fixture.base + 0x1C0;
const hard_handler: u32 = fixture.base + 0x1E0;
const memfaultena: u32 = 1 << 16;
const busfaultena: u32 = 1 << 17;
const mstkerr: u32 = 1 << 4;
const munstkerr: u32 = 1 << 3;
const stkerr: u32 = 1 << 12;
const unstkerr: u32 = 1 << 11;
const forced: u32 = 1 << 30;

const RoutedRam = struct {
    ram: *fixture.Ram,
    check: ?*mpu_check.Check = null,
    refuse_reads: bool = false,
    refuse_writes: bool = false,
    first: u32 = fixture.msp_top - 0x20,
    last: u32 = fixture.msp_top - 1,

    fn view(self: *RoutedRam) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn within(self: *const RoutedRam, address: u32, len: usize) bool {
        const end = @as(u64, address) + len;
        return address <= self.last and end > self.first;
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *RoutedRam = @ptrCast(@alignCast(ctx));
        if (self.check) |check| if (!check.allows(address, .load)) return error.Unmapped;
        if (self.refuse_reads and self.within(address, into.len)) return error.Unmapped;
        return self.ram.view().read(address, into);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *RoutedRam = @ptrCast(@alignCast(ctx));
        if (self.check) |check| if (!check.allows(address, .store)) return error.Unmapped;
        if (self.refuse_writes and self.within(address, bytes.len)) return error.Unmapped;
        return self.ram.view().write(address, bytes);
    }
};

fn putProgram(ram: *fixture.Ram) void {
    ram.putHalf(fixture.code, 0xDF00); // svc #0
    ram.putHalf(fixture.code + 2, 0xBF00); // nop
    ram.putHalf(mem_handler, 0x4770); // bx lr
    ram.putHalf(bus_handler, 0x4770);
    ram.putHalf(hard_handler, 0x4770);
    ram.putWord(fixture.base + 3 * 4, hard_handler | 1);
    ram.putWord(fixture.base + 4 * 4, mem_handler | 1);
    ram.putWord(fixture.base + 5 * 4, bus_handler | 1);
    ram.putWord(memmap.scb.shpr2, 0x8000_0000); // SVC priority 0x80
}

fn stackUnit() mpu.Mpu {
    var unit: mpu.Mpu = .{};
    unit.table[0] = mpu.Region.fromPair(
        fixture.base | mpu.field.rbar_ap_unprivileged,
        ((fixture.base + 0x3FF) & mpu.field.address) | mpu.field.rlar_enable,
    );
    unit.table[1] = mpu.Region.fromPair(
        (fixture.msp_top - 0x20) | mpu.field.rbar_ap_unprivileged | mpu.field.rbar_ap_ro,
        ((fixture.msp_top - 1) & mpu.field.address) | mpu.field.rlar_enable,
    );
    unit.ctrl = mpu.field.ctrl_enable;
    return unit;
}

fn boot(ram: *fixture.Ram, routed: *RoutedRam) !Cpu {
    putProgram(ram);
    var cpu = try fixture.boot(ram);
    cpu.bus = routed.view();
    return cpu;
}

fn ipsr(cpu: *const Cpu) u32 {
    return cpu.regs.xpsr & 0x1FF;
}

test "an MPU-refused exception push takes MemManage with MSTKERR" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, memfaultena);
    var unit = stackUnit();
    var check: mpu_check.Check = .{ .unit = &unit };
    var routed: RoutedRam = .{ .ram = &ram, .check = &check };
    var cpu = try boot(&ram, &routed);
    cpu.mpu = &check;

    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(mem_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 4), ipsr(&cpu));
    try std.testing.expectEqual(mstkerr, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(fixture.msp_top - 0x20, cpu.regs.msp);
}

test "a bus-refused exception push takes BusFault with STKERR" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, busfaultena);
    var routed: RoutedRam = .{ .ram = &ram, .refuse_writes = true };
    var cpu = try boot(&ram, &routed);

    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(bus_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 5), ipsr(&cpu));
    try std.testing.expectEqual(stkerr, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(fixture.msp_top - 0x20, cpu.regs.msp);
    try std.testing.expect(ram.word(memmap.scb.shcsr) & (1 << 15) != 0);
}

test "a disabled stacking BusFault escalates to HardFault" {
    var ram: fixture.Ram = .{};
    var routed: RoutedRam = .{ .ram = &ram, .refuse_writes = true };
    var cpu = try boot(&ram, &routed);

    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(hard_handler, cpu.regs.pc);
    try std.testing.expectEqual(stkerr, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(forced, ram.word(memmap.scb.hfsr));
}
test "a higher-priority original exception leaves stacking BusFault pending" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, busfaultena);
    var routed: RoutedRam = .{ .ram = &ram, .refuse_writes = true };
    var cpu = try boot(&ram, &routed);
    ram.putWord(memmap.scb.shpr1, 0x0000_FF00); // BusFault priority 0xFF
    ram.putWord(memmap.scb.shpr2, 0); // SVC priority 0

    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 11), ipsr(&cpu));
    try std.testing.expectEqual(stkerr, ram.word(memmap.scb.cfsr));
    try std.testing.expect(ram.word(memmap.scb.shcsr) & (1 << 14) != 0);
}

test "a polled IRQ stack failure retargets the fault and leaves the IRQ pending" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, busfaultena);
    ram.putWord(fixture.base + 16 * 4, fixture.handler | 1);
    var routed: RoutedRam = .{ .ram = &ram, .refuse_writes = true };
    var cpu = try boot(&ram, &routed);
    ram.putHalf(bus_handler, 0xBF00); // nop
    var source: fake_source.Fake = .{ .pending = .{ .number = 16, .priority = 0x80 } };
    cpu.source = source.source();

    try std.testing.expectEqual(.count, std.meta.activeTag(cpu.run(1)));
    try std.testing.expectEqual(bus_handler + 2, cpu.regs.pc);
    try std.testing.expectEqual(stkerr, ram.word(memmap.scb.cfsr));
    try std.testing.expect(source.pending != null);
    try std.testing.expectEqual(@as(u32, 0), source.taken);
}

test "a disabled pending derived fault waits until re-enabled" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, 1 << 14);
    var routed: RoutedRam = .{ .ram = &ram };
    var cpu = try boot(&ram, &routed);

    try std.testing.expect(!try dispatch.poll(&cpu));
    try std.testing.expect(ram.word(memmap.scb.shcsr) & (1 << 14) != 0);
    ram.putWord(memmap.scb.shcsr, busfaultena | (1 << 14));
    try std.testing.expect(try dispatch.poll(&cpu));
    try std.testing.expectEqual(bus_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.shcsr) & (1 << 14));
}

test "a pending fault wins equal preemption group by raw priority" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, busfaultena | (1 << 14));
    ram.putWord(memmap.scb.shpr1, 0x0000_4000);
    ram.putWord(memmap.scb.aircr, 7 << 8);
    ram.putWord(fixture.base + 16 * 4, fixture.handler | 1);
    var routed: RoutedRam = .{ .ram = &ram };
    var cpu = try boot(&ram, &routed);
    var source: fake_source.Fake = .{ .pending = .{ .number = 16, .priority = 0x60 } };
    cpu.source = source.source();

    try std.testing.expect(try dispatch.poll(&cpu));
    try std.testing.expectEqual(bus_handler, cpu.regs.pc);
    try std.testing.expect(source.pending != null);
}

test "a preserved synchronous SVC is dispatched and cleared" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, 1 << 15);
    var routed: RoutedRam = .{ .ram = &ram };
    var cpu = try boot(&ram, &routed);

    try std.testing.expect(try dispatch.poll(&cpu));
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.shcsr) & (1 << 15));
}

test "a stacking fault under FAULTMASK locks up" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, busfaultena);
    var routed: RoutedRam = .{ .ram = &ram, .refuse_writes = true };
    var cpu = try boot(&ram, &routed);
    cpu.regs.faultmask = 1;

    try std.testing.expectEqual(fixture.code, cpu.step().?.bus_fault);
}

test "HardFault stacking bypasses an MPU without HFNMIENA" {
    var ram: fixture.Ram = .{};
    var unit = stackUnit();
    var check: mpu_check.Check = .{ .unit = &unit };
    var routed: RoutedRam = .{ .ram = &ram, .check = &check };
    var cpu = try boot(&ram, &routed);
    cpu.mpu = &check;
    cpu.regs.xpsr = 0; // INVSTATE escalates because UsageFault is disabled.

    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(hard_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 3), ipsr(&cpu));
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr) & mstkerr);
}

test "HardFault wins its MPU stacking fault and leaves MemManage pending" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, memfaultena);
    var unit = stackUnit();
    unit.ctrl |= mpu.field.ctrl_hfnmiena;
    var check: mpu_check.Check = .{ .unit = &unit };
    var routed: RoutedRam = .{ .ram = &ram, .check = &check };
    var cpu = try boot(&ram, &routed);
    cpu.mpu = &check;
    cpu.regs.xpsr = 0;

    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(hard_handler, cpu.regs.pc);
    try std.testing.expectEqual(mstkerr, ram.word(memmap.scb.cfsr) & mstkerr);
    try std.testing.expect(ram.word(memmap.scb.shcsr) & (1 << 13) != 0);
}

test "a HardFault return checks the restored context MPU privilege" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, memfaultena);
    var unit = stackUnit();
    unit.table[1] = mpu.Region.fromPair(
        fixture.msp_top - 0x20,
        ((fixture.msp_top - 1) & mpu.field.address) | mpu.field.rlar_enable,
    );
    unit.ctrl = 0;
    var check: mpu_check.Check = .{ .unit = &unit };
    var routed: RoutedRam = .{ .ram = &ram, .check = &check };
    var cpu = try boot(&ram, &routed);
    cpu.mpu = &check;
    cpu.regs.control |= ra8.chip.core.cpu.regs.control_bits.npriv;
    cpu.regs.xpsr = 0;

    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(hard_handler, cpu.regs.pc);
    unit.ctrl = mpu.field.ctrl_enable;
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(mem_handler, cpu.regs.pc);
    try std.testing.expectEqual(munstkerr, ram.word(memmap.scb.cfsr) & munstkerr);
}

fn enterThenRefuse(ram: *fixture.Ram, routed: *RoutedRam) !Cpu {
    var cpu = try boot(ram, routed);
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    ram.putHalf(fixture.handler, 0x4770); // bx lr
    return cpu;
}

test "a bus-refused exception pop tail-chains BusFault with UNSTKERR" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, busfaultena);
    var routed: RoutedRam = .{ .ram = &ram };
    var cpu = try enterThenRefuse(&ram, &routed);
    routed.refuse_reads = true;

    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(bus_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 5), ipsr(&cpu));
    try std.testing.expectEqual(unstkerr, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(fixture.msp_top - 0x20, cpu.regs.msp);
    try std.testing.expectEqual(@as(usize, 1), cpu.active.depth);
}

test "an MPU-refused exception pop tail-chains MemManage with MUNSTKERR" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, memfaultena);
    var unit = stackUnit();
    unit.table[1] = mpu.Region.fromPair(
        fixture.msp_top - 0x20,
        ((fixture.msp_top - 1) & mpu.field.address) | mpu.field.rlar_enable,
    );
    unit.ctrl = 0;
    var check: mpu_check.Check = .{ .unit = &unit };
    var routed: RoutedRam = .{ .ram = &ram, .check = &check };
    var cpu = try boot(&ram, &routed);
    cpu.mpu = &check;
    cpu.regs.control |= ra8.chip.core.cpu.regs.control_bits.npriv;

    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    ram.putHalf(fixture.handler, 0x4770);
    unit.ctrl = mpu.field.ctrl_enable;

    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(mem_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 4), ipsr(&cpu));
    try std.testing.expectEqual(munstkerr, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(fixture.msp_top - 0x20, cpu.regs.msp);
}

test "a disabled unstacking BusFault tail-chains forced HardFault" {
    var ram: fixture.Ram = .{};
    var routed: RoutedRam = .{ .ram = &ram };
    var cpu = try enterThenRefuse(&ram, &routed);
    routed.refuse_reads = true;

    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(hard_handler, cpu.regs.pc);
    try std.testing.expectEqual(unstkerr, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(forced, ram.word(memmap.scb.hfsr));
}

test "exception return clears FAULTMASK before routing an unstacking fault" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, busfaultena);
    var routed: RoutedRam = .{ .ram = &ram };
    var cpu = try enterThenRefuse(&ram, &routed);
    routed.refuse_reads = true;
    cpu.regs.faultmask = 1;

    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(bus_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.faultmask);
}
