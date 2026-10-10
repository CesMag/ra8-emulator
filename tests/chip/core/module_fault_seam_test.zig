//! A seam test for RA8EMU-54: what the module manager leans on when a
//! module strays. An unprivileged store outside the module's MPU regions
//! enters MemManage with the store's own address stacked and MMFAR
//! naming the target, and a privileged handler can abandon the module by
//! returning to a kernel recovery point instead of to the module.
//!
//! The program runs on the Zig core (RA8EMU-367) over its own store
//! (RA8EMU-607), which turns the stray store away before memory.

const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const mpu = ra8.chip.periph.mpu;
const bus = ra8.chip.core.cpu.bus;
const mpu_check = ra8.chip.core.cpu.board_bus.mpu_check;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Stop = ra8.chip.core.cpu.cpu.Stop;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const MemoryBus = ra8.chip.core.cpu.memory.memory_bus.MemoryBus;

/// The module's code, the kernel's recovery point, its stack, a span only
/// privileged code may touch, and the vector table with its handlers.
const layout = struct {
    const module: u32 = memmap.sram_base;
    const recovery: u32 = memmap.sram_base + 0x100;
    const stack: u32 = memmap.sram_base + 0x4F00;
    const kernel_only: u32 = memmap.sram_base + 0x5000;
    const table: u32 = memmap.sram_base + 0x6000;
    const handlers: u32 = memmap.sram_base + 0x7000;
};

const memmanage: u32 = 4;
const memfaultena: u32 = 1 << 16;
/// CFSR.MMARVALID with CFSR.DACCVIOL.
const data_violation: u32 = 0x82;

/// `str r2, [r1]; movs r5, #1; b .`: the stray store, then a marker the
/// module only reaches if it is resumed.
const module_code = [_]u8{ 0x0A, 0x60, 0x01, 0x25, 0xFE, 0xE7 };
/// `movs r4, #0x77; b .`, where the kernel picks up.
const recovery_code = [_]u8{ 0x77, 0x24, 0xFE, 0xE7 };
/// `movs r0, #0; msr control, r0; str r3, [sp, #24]; bx lr`: drop back to
/// privileged, point the stacked return address at the recovery point
/// held in r3, and return.
const kill_handler = [_]u8{ 0x00, 0x20, 0x80, 0xF3, 0x14, 0x88, 0x06, 0x93, 0x70, 0x47 };

fn region(base: u32, limit: u32, attributes: u32) mpu.Region {
    return mpu.Region.fromPair(base | attributes, (limit & mpu.field.address) | mpu.field.rlar_enable);
}

/// The module, kernel, vector table and handlers in `memory`, and the MPU
/// map that keeps the module out of the kernel-only span.
fn prepare(memory: Guest, unit: *mpu.Mpu) !void {
    var number: u32 = 0;
    while (number < 16) : (number += 1) {
        try memory.writeWord(layout.table + 4 * number, layout.handlers + 0x10 * number + 1);
        try memory.writeWord(layout.handlers + 0x10 * number, 0xE7FE_E7FE);
    }
    try memory.write(layout.handlers + 0x10 * memmanage, &kill_handler);
    try memory.writeWord(memmap.scb.vtor, layout.table);
    try memory.writeWord(memmap.scb.shcsr, memfaultena);
    try memory.write(layout.module, &module_code);
    try memory.write(layout.recovery, &recovery_code);
    unit.* = mpu.Mpu.init();
    const open_to_all = mpu.field.rbar_ap_unprivileged;
    unit.table[0] = region(layout.module, layout.kernel_only - 1, open_to_all);
    unit.table[1] = region(layout.kernel_only, layout.kernel_only + 0x1F, 0);
    unit.table[2] = region(layout.table, layout.table + 0x2FFF, open_to_all);
    unit.ctrl = mpu.field.ctrl_enable;
}

/// The Zig core's bus over a store with that core's MPU check in front,
/// the way BoardBus asks it.
const Guarded = struct {
    memory: MemoryBus,
    check: *mpu_check.Check,

    fn view(self: *Guarded) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }
    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Guarded = @ptrCast(@alignCast(ctx));
        if (!self.check.allows(address, .load)) return bus.Error.Unmapped;
        return self.memory.view().read(address, into);
    }
    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Guarded = @ptrCast(@alignCast(ctx));
        if (!self.check.allows(address, .store)) return bus.Error.Unmapped;
        return self.memory.view().write(address, from);
    }
};

/// One core running the module: unprivileged Thread mode on the Main
/// stack at the module, over `store`. Built in place, since the bus
/// points into it.
const Run = struct {
    unit: mpu.Mpu,
    check: mpu_check.Check,
    guarded: Guarded,
    cpu: Cpu,

    fn open(self: *Run, store: *Store) !void {
        try prepare(.{ .store = store }, &self.unit);
        self.check = .{ .unit = &self.unit };
        self.guarded = .{ .memory = .{ .store = store }, .check = &self.check };
        self.cpu = .{ .bus = self.guarded.view() };
        self.cpu.mpu = &self.check;
        try self.cpu.reset(layout.table);
        self.cpu.regs.pc = layout.module;
        self.cpu.regs.msp = layout.stack;
        self.cpu.regs.control = 1;
        self.cpu.regs.set(1, layout.kernel_only);
        self.cpu.regs.set(2, 0x5A);
        self.cpu.regs.set(3, layout.recovery);
    }
};

test "a module's stray store enters MemManage with the store stacked and never lands" {
    var store = try Store.init(null);
    defer store.deinit();
    var run: Run = undefined;
    try run.open(&store);
    const memory: Guest = .{ .store = &store };
    try memory.write(layout.handlers + 0x10 * memmanage, &[_]u8{ 0xFE, 0xE7 });
    try std.testing.expectEqual(Stop.count, run.cpu.run(1));
    try std.testing.expectEqual(memmanage, run.cpu.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(data_violation, try memory.readWord(memmap.scb.cfsr));
    try std.testing.expectEqual(layout.kernel_only, try memory.readWord(memmap.scb.mmfar));
    try std.testing.expectEqual(layout.module, try memory.readWord(run.cpu.regs.msp + 24));
    try std.testing.expectEqual(@as(u32, 0), try memory.readWord(layout.kernel_only));
}

test "the handler abandons the module and the kernel carries on privileged" {
    var store = try Store.init(null);
    defer store.deinit();
    var run: Run = undefined;
    try run.open(&store);
    const memory: Guest = .{ .store = &store };
    try std.testing.expectEqual(Stop.count, run.cpu.run(20));
    try std.testing.expectEqual(layout.recovery + 2, run.cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0x77), run.cpu.regs.get(4));
    try std.testing.expectEqual(@as(u32, 0), run.cpu.regs.get(5));
    try std.testing.expectEqual(@as(u32, 0), run.cpu.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(@as(u32, 0), run.cpu.regs.control & 1);
    try std.testing.expectEqual(data_violation, try memory.readWord(memmap.scb.cfsr));
    try std.testing.expectEqual(layout.kernel_only, try memory.readWord(memmap.scb.mmfar));
}

test "a module on CPU1 is stopped by CPU1's own MPU and CPU0 never sees the fault" {
    var cpu0 = try Store.init(null);
    defer cpu0.deinit();
    var cpu1 = try Store.init(&cpu0);
    defer cpu1.deinit();
    var run: Run = undefined;
    try run.open(&cpu1);
    try std.testing.expectEqual(Stop.count, run.cpu.run(20));
    const theirs: Guest = .{ .store = &cpu1 };
    const mine: Guest = .{ .store = &cpu0 };
    try std.testing.expectEqual(layout.recovery + 2, run.cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), run.cpu.regs.get(5));
    try std.testing.expectEqual(layout.kernel_only, try theirs.readWord(memmap.scb.mmfar));
    try std.testing.expectEqual(@as(u32, 0), try mine.readWord(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u32, 0), try mine.readWord(memmap.scb.mmfar));
}

test "a module on CPU0 is stopped by CPU0's own MPU and CPU1 never sees the fault" {
    var cpu0 = try Store.init(null);
    defer cpu0.deinit();
    var cpu1 = try Store.init(&cpu0);
    defer cpu1.deinit();
    var run: Run = undefined;
    try run.open(&cpu0);
    try std.testing.expectEqual(Stop.count, run.cpu.run(20));
    const mine: Guest = .{ .store = &cpu0 };
    const theirs: Guest = .{ .store = &cpu1 };
    try std.testing.expectEqual(layout.recovery + 2, run.cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), run.cpu.regs.get(5));
    try std.testing.expectEqual(layout.kernel_only, try mine.readWord(memmap.scb.mmfar));
    try std.testing.expectEqual(@as(u32, 0), try theirs.readWord(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u32, 0), try theirs.readWord(memmap.scb.mmfar));
}
