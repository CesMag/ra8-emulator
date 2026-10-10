//! Covers src/chip/core/cpu/exception/entry.zig.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.chip.core.cpu.regs;
const entry = ra8.chip.core.cpu.exception.entry;
const fixture = @import("ram.zig");
const memmap = ra8.chip.core.memmap;
const stkof: u32 = 1 << 20;
const usage_fault_enable: u32 = 1 << 18;
const shcsr_usage_pending: u32 = 1 << 12;
const dispatch = ra8.chip.core.cpu.exception.dispatch;
const ExceptionSource = ra8.chip.core.cpu.exception.source.Source;
const ActiveEntry = ra8.chip.core.cpu.exception.active.Entry;
const bus = ra8.chip.core.cpu.bus;

const PendingException = struct {
    pending: bool = true,
    active: bool = false,
    taken_count: u32 = 0,

    fn source(self: *PendingException) ExceptionSource {
        return .{ .ctx = self, .vtable = &.{ .winner = winner, .taken = taken, .returned = returned } };
    }

    fn winner(ctx: *anyopaque, _: bus.Bus) bus.Error!?ActiveEntry {
        const self: *PendingException = @ptrCast(@alignCast(ctx));
        return if (self.pending) .{ .number = 16, .priority = 0xFF } else null;
    }

    fn taken(ctx: *anyopaque, _: bus.Bus, number: u9) bus.Error!void {
        const self: *PendingException = @ptrCast(@alignCast(ctx));
        if (number == 16) {
            self.pending = false;
            self.active = true;
            self.taken_count += 1;
        }
    }

    fn returned(ctx: *anyopaque, _: bus.Bus, number: u9) bus.Error!void {
        const self: *PendingException = @ptrCast(@alignCast(ctx));
        if (number == 16) self.active = false;
    }
};

test "entry from Thread mode on the MSP stacks the frame and runs the handler" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[0] = 0xA0;
    cpu.regs.low[12] = 0xC0;
    cpu.regs.lr = 0x2000_0141;
    cpu.regs.xpsr |= 0x8000_0000 | (0x3 << 25) | (0x2 << 10); // N, plus IT state
    _ = try entry.take(&cpu, 11, 0x2000_0102);
    const sp = fixture.msp_top - 0x20;
    try std.testing.expectEqual(sp, cpu.regs.msp);
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF9), cpu.regs.lr);
    try std.testing.expectEqual(@as(u32, 11), cpu.regs.xpsr & regs.xpsr_bits.ipsr);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.xpsr & entry.it_bits);
    try std.testing.expect(cpu.regs.xpsr & regs.xpsr_bits.thumb != 0);
    try std.testing.expect(cpu.regs.xpsr & 0x8000_0000 != 0);
    try std.testing.expectEqual(@as(u32, 0xA0), ram.word(sp));
    try std.testing.expectEqual(@as(u32, 0xC0), ram.word(sp + 16));
    try std.testing.expectEqual(@as(u32, 0x2000_0141), ram.word(sp + 20));
    try std.testing.expectEqual(@as(u32, 0x2000_0102), ram.word(sp + 24));
    try std.testing.expect(ram.word(sp + 28) & entry.it_bits != 0);
}

test "entry from Thread mode on the PSP stacks there and switches to the MSP" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.psp = fixture.psp_top;
    cpu.regs.control |= regs.control_bits.spsel;
    _ = try entry.take(&cpu, 11, 0x2000_0102);
    try std.testing.expectEqual(fixture.psp_top - 0x20, cpu.regs.psp);
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.msp);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFD), cpu.regs.lr);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.control & regs.control_bits.spsel);
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.sp());
}

test "entry from Handler mode nests on the MSP" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.xpsr |= 14; // in PendSV
    _ = try entry.take(&cpu, 11, 0x2000_0102);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF1), cpu.regs.lr);
    try std.testing.expectEqual(@as(u32, 14), ram.word(cpu.regs.msp + 28) & regs.xpsr_bits.ipsr);
}

test "an unreadable vector leaves the registers alone" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.vtor = 0x1000_0000;
    const before = cpu.regs;
    try std.testing.expectError(error.Unmapped, entry.take(&cpu, 11, 0x2000_0102));
    try std.testing.expectEqual(before, cpu.regs);
}

test "the table the core reset from stands in while nothing answers at VTOR" {
    var ram: fixture.Ram = .{};
    const cpu = try fixture.boot(&ram);
    try std.testing.expectEqual(fixture.base, entry.vectorTable(&cpu));
}

test "entry with an FP context stacks the extended frame and clears FPCA" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.fp.context.fpccr.lspen = 0;
    cpu.regs.control |= regs.control_bits.fpca;
    for (0..16) |i| cpu.fp.bank.writeS(@intCast(i), 0x4000_0000 + @as(u32, @intCast(i)));
    cpu.fp.bank.writeS(16, 0xDEAD_BEEF);
    cpu.fp.fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr.fromBits(0x0300_0000);
    _ = try entry.take(&cpu, 11, 0x2000_0102);
    const sp = fixture.msp_top - 0x68;
    try std.testing.expectEqual(sp, cpu.regs.msp);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFE9), cpu.regs.lr);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.control & regs.control_bits.fpca);
    try std.testing.expectEqual(@as(u32, 0x2000_0102), ram.word(sp + 0x18));
    try std.testing.expectEqual(@as(u32, 0x4000_0000), ram.word(sp + 0x20));
    try std.testing.expectEqual(@as(u32, 0x4000_000F), ram.word(sp + 0x5C));
    try std.testing.expectEqual(@as(u32, 0x0300_0000), ram.word(sp + 0x60));
    // S16 is not part of this frame; the Secure extension is RA8EMU-165.
    try std.testing.expectEqual(@as(u32, 0), ram.word(sp + 0x64));
}

test "lazy entry reserves the FP space, names it in FPCAR and sets LSPACT" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.control |= regs.control_bits.fpca;
    cpu.fp.bank.writeS(0, 0x4000_0000);
    _ = try entry.take(&cpu, 11, 0x2000_0102);
    const sp = fixture.msp_top - 0x68;
    try std.testing.expectEqual(sp, cpu.regs.msp);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFE9), cpu.regs.lr);
    try std.testing.expectEqual(@as(u32, 0x2000_0102), ram.word(sp + 0x18));
    // S0 is not written yet: the first FP op in the handler does that.
    try std.testing.expectEqual(@as(u32, 0), ram.word(sp + 0x20));
    const fpccr = cpu.fp.context.fpccr;
    try std.testing.expectEqual(sp + 0x20, cpu.fp.context.fpcar);
    try std.testing.expectEqual(@as(u1, 1), fpccr.lspact);
    try std.testing.expectEqual(@as(u1, 1), fpccr.thread);
    try std.testing.expectEqual(@as(u1, 0), fpccr.user);
    try std.testing.expectEqual(@intFromBool(cpu.banked.current == .secure), fpccr.s);
}

test "entry without an FP context keeps the basic frame and FType set" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.fp.bank.writeS(0, 0x4000_0000);
    _ = try entry.take(&cpu, 11, 0x2000_0102);
    try std.testing.expectEqual(fixture.msp_top - 0x20, cpu.regs.msp);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF9), cpu.regs.lr);
}

test "an SVC inside an IT block: entry clears ITSTATE, the frame keeps it, return restores it" {
    var ram: fixture.Ram = .{};
    // itt ne ; svc #0 ; movs r0, #1 (movne inside the block)
    ram.putWord(fixture.code, 0xDF00_BF1C);
    ram.putHalf(fixture.code + 4, 0x2001);
    ram.putHalf(fixture.handler, 0x4770); // bx lr
    var cpu = try fixture.boot(&ram);
    const it_state = ra8.chip.core.cpu.it_state;
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.xpsr & entry.it_bits);
    // The SVC moved the block on: NE with one instruction left.
    try std.testing.expectEqual(@as(u8, 0x18), it_state.get(ram.word(cpu.regs.sp() + 28)));
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);
    try std.testing.expectEqual(@as(u8, 0x18), it_state.get(cpu.regs.xpsr));
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.low[0]);
    try std.testing.expectEqual(@as(u8, 0), it_state.get(cpu.regs.xpsr));
}

test "exception entry crossing PSPLIM raises derived STKOF UsageFault" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, usage_fault_enable);
    ram.putWord(memmap.scb.shpr1, 0x0000_0000);
    ram.putWord(fixture.base + 16 * 4, fixture.handler | 1);
    ram.putWord(fixture.base + 6 * 4, fixture.handler | 1);
    var cpu = try fixture.boot(&ram);
    var pending: PendingException = .{};
    cpu.source = pending.source();
    const limit = fixture.psp_top - 16;
    cpu.regs.control |= regs.control_bits.spsel;
    cpu.regs.psp = fixture.psp_top;
    cpu.regs.psplim = limit;

    try dispatch.enter(&cpu, .{ .number = 16, .priority = 0xFF }, fixture.code);
    try std.testing.expectEqual(@as(u32, 6), cpu.regs.xpsr & regs.xpsr_bits.ipsr);
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(limit, cpu.regs.psp);
    try std.testing.expectEqual(stkof, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFD), cpu.regs.lr);
    try std.testing.expectEqual(@as(usize, 1), cpu.active.depth);
    try std.testing.expectEqual(@as(u9, 6), cpu.active.running().?.number);
    try std.testing.expect(pending.pending);
    try std.testing.expect(!pending.active);
    try std.testing.expectEqual(@as(u32, 0), pending.taken_count);
}

test "exception entry crossing MSPLIM raises derived STKOF UsageFault" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, usage_fault_enable);
    ram.putWord(memmap.scb.shpr1, 0x0000_0000);
    ram.putWord(fixture.base + 16 * 4, fixture.handler | 1);
    ram.putWord(fixture.base + 6 * 4, fixture.handler | 1);
    var cpu = try fixture.boot(&ram);
    var pending: PendingException = .{};
    cpu.source = pending.source();
    const limit = fixture.msp_top - 16;
    cpu.regs.msplim = limit;

    try dispatch.enter(&cpu, .{ .number = 16, .priority = 0xFF }, fixture.code);
    try std.testing.expectEqual(@as(u32, 6), cpu.regs.xpsr & regs.xpsr_bits.ipsr);
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(limit, cpu.regs.msp);
    try std.testing.expectEqual(stkof, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF9), cpu.regs.lr);
    try std.testing.expectEqual(@as(usize, 1), cpu.active.depth);
    try std.testing.expectEqual(@as(u9, 6), cpu.active.running().?.number);
    try std.testing.expect(pending.pending);
    try std.testing.expect(!pending.active);
    try std.testing.expectEqual(@as(u32, 0), pending.taken_count);
}

test "disabled UsageFault escalates entry STKOF to HardFault and leaves IRQ pending" {
    var ram: fixture.Ram = .{};
    ram.putWord(fixture.base + 16 * 4, fixture.handler | 1);
    ram.putWord(fixture.base + 3 * 4, fixture.handler | 1);
    var cpu = try fixture.boot(&ram);
    var pending: PendingException = .{};
    cpu.source = pending.source();
    const limit = fixture.msp_top - 16;
    cpu.regs.msplim = limit;

    try dispatch.enter(&cpu, .{ .number = 16, .priority = 0xFF }, fixture.code);
    try std.testing.expectEqual(@as(u32, 3), cpu.regs.xpsr & regs.xpsr_bits.ipsr);
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(limit, cpu.regs.msp);
    try std.testing.expectEqual(stkof, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u32, 1 << 30), ram.word(memmap.scb.hfsr));
    try std.testing.expectEqual(@as(usize, 1), cpu.active.depth);
    try std.testing.expectEqual(@as(u9, 3), cpu.active.running().?.number);
    try std.testing.expect(pending.pending);
    try std.testing.expect(!pending.active);
    try std.testing.expectEqual(@as(u32, 0), pending.taken_count);
}

test "higher-priority original exception leaves STKOF UsageFault pending" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, usage_fault_enable);
    ram.putWord(memmap.scb.shpr1, 0x00FF_0000);
    ram.putWord(fixture.base + 16 * 4, fixture.handler | 1);
    ram.putWord(fixture.base + 6 * 4, fixture.handler | 1);
    var cpu = try fixture.boot(&ram);
    var pending: PendingException = .{};
    cpu.source = pending.source();
    const limit = fixture.msp_top - 16;
    cpu.regs.msplim = limit;

    try dispatch.enter(&cpu, .{ .number = 16, .priority = 0 }, fixture.code);
    try std.testing.expectEqual(@as(u32, 16), cpu.regs.xpsr & regs.xpsr_bits.ipsr);
    try std.testing.expectEqual(@as(u9, 16), cpu.active.running().?.number);
    try std.testing.expect(!pending.pending);
    try std.testing.expect(pending.active);
    try std.testing.expectEqual(@as(u32, 1), pending.taken_count);
    try std.testing.expect(ram.word(memmap.scb.shcsr) & shcsr_usage_pending != 0);
}

test "a lazy FP entry over the stack limit records SPLIMVIOL and writes no frame" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.control |= regs.control_bits.fpca;
    const limit = fixture.msp_top - 16;
    cpu.regs.msplim = limit;
    try std.testing.expect(try entry.take(&cpu, 11, 0x2000_0102));
    try std.testing.expectEqual(limit, cpu.regs.msp);
    const ctx = cpu.fp.context;
    try std.testing.expectEqual(@as(u1, 1), ctx.fpccr.lspact);
    try std.testing.expectEqual(@as(u1, 1), ctx.fpccr.splimviol);
    try std.testing.expectEqual(fixture.msp_top - 0x68 + 0x20, ctx.fpcar);
    try std.testing.expectEqual(@as(u32, 0), ram.word(fixture.msp_top - 0x68 + 0x18));
}

test "a lazy FP entry inside the limit leaves SPLIMVIOL clear" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.control |= regs.control_bits.fpca;
    cpu.fp.context.fpccr.splimviol = 1;
    try std.testing.expect(!try entry.take(&cpu, 11, 0x2000_0102));
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.context.fpccr.splimviol);
}
