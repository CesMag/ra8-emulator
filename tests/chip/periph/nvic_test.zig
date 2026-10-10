//! Tests for src/chip/periph/nvic.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const mod = ra8.chip.periph.nvic;

const Error = mod.Error;
const Nvic = mod.Nvic;
const exc_return_handler_msp = mod.exc_return_handler_msp;
const exc_return_thread_msp = mod.exc_return_thread_msp;
const first_irq = mod.first_irq;
const frame_bytes = mod.frame_bytes;
const icsr_pendstclr = mod.icsr_pendstclr;
const icsr_pendstset = mod.icsr_pendstset;
const ipsr_mask = mod.ipsr_mask;
const isExceptionReturn = mod.isExceptionReturn;
const primask_pm = mod.primask_pm;
const systick = mod.systick;
const xpsr_stack_align = mod.xpsr_stack_align;

/// A core-shaped stand-in: PPB words in a map, registers in an array, so the
/// controller can be tested without a CPU underneath it.
const FakeCore = struct {
    const Name = enum { pc, sp, lr, r0, r1, r2, r3, r12, xpsr, primask, psp };

    words: std.AutoHashMap(u32, u32),
    registers: std.EnumArray(Name, u32) = std.EnumArray(Name, u32).initFill(0),
    /// The rule for an unprivileged thread: a PSP write from Thread
    /// mode is dropped, so only one made from Handler mode lands.
    unprivileged: bool = false,

    fn init(allocator: std.mem.Allocator) FakeCore {
        return .{ .words = std.AutoHashMap(u32, u32).init(allocator) };
    }

    fn deinit(self: *FakeCore) void {
        self.words.deinit();
    }

    pub fn readWord(self: *FakeCore, address: u32) !u32 {
        return self.words.get(address) orelse 0;
    }

    pub fn writeWord(self: *FakeCore, address: u32, value: u32) !void {
        try self.words.put(address, value);
    }

    pub fn register(self: *FakeCore, which: Name) !u32 {
        return self.registers.get(which);
    }

    pub fn setRegister(self: *FakeCore, which: Name, value: u32) !void {
        const thread = self.registers.get(.xpsr) & ipsr_mask == 0;
        if (which == .psp and self.unprivileged and thread) return;
        self.registers.set(which, value);
    }

    /// A vector table at 0x22000000 whose every handler is `base + 0x100 * n`.
    fn plantVectorTable(self: *FakeCore) !void {
        try self.writeWord(memmap.scb.vtor, 0x2200_0000);
        var number: u32 = 0;
        while (number < 48) : (number += 1) {
            try self.writeWord(0x2200_0000 + 4 * number, 0x2200_1000 + 0x100 * number + 1);
        }
    }

    fn handlerFor(number: u32) u32 {
        return 0x2200_1000 + 0x100 * number;
    }
};
test "a pended SysTick is entered with a stacked frame and an EXC_RETURN" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_8000);
    try core.setRegister(.pc, 0x2200_0400);
    try core.setRegister(.r0, 0xAAAA_AAAA);
    try core.setRegister(.lr, 0x2200_0500);
    try core.writeWord(memmap.scb.icsr, icsr_pendstset);

    var irqs = Nvic{};
    try std.testing.expectEqual(@as(?u16, systick), try irqs.dispatch(&core));
    try std.testing.expectEqual(FakeCore.handlerFor(systick), try core.register(.pc));
    try std.testing.expectEqual(exc_return_thread_msp, try core.register(.lr));
    try std.testing.expectEqual(@as(u32, systick), (try core.register(.xpsr)) & ipsr_mask);
    try std.testing.expectEqual(@as(u32, 0x2200_8000 - frame_bytes), try core.register(.sp));
    try std.testing.expectEqual(@as(u32, 0xAAAA_AAAA), try core.readWord(0x2200_8000 - frame_bytes));
    try std.testing.expectEqual(@as(u32, 0x2200_0400), try core.readWord(0x2200_8000 - 8));
    // Taking it consumed the pend: it is not taken twice.
    try std.testing.expectEqual(@as(?u16, null), try irqs.dispatch(&core));
}

test "returning restores the frame and lands back where the exception hit" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_8000);
    try core.setRegister(.pc, 0x2200_0400);
    try core.setRegister(.r2, 0x1234_5678);
    try core.writeWord(memmap.scb.icsr, icsr_pendstset);

    var irqs = Nvic{};
    _ = try irqs.dispatch(&core);
    // The handler clobbers what it is allowed to clobber.
    try core.setRegister(.r2, 0);
    try core.setRegister(.pc, exc_return_thread_msp);
    try irqs.exit(&core, exc_return_thread_msp);

    try std.testing.expectEqual(@as(u32, 0x2200_0400), try core.register(.pc));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), try core.register(.r2));
    try std.testing.expectEqual(@as(u32, 0x2200_8000), try core.register(.sp));
    try std.testing.expectEqual(@as(u32, 0), (try core.register(.xpsr)) & ipsr_mask);
    try std.testing.expectEqual(@as(u64, 1), irqs.returned);
    try std.testing.expectEqual(@as(usize, 0), irqs.depth);
}

test "an unaligned stack pointer is padded and the pad is given back" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_7FFC);
    try core.writeWord(memmap.scb.icsr, icsr_pendstset);

    var irqs = Nvic{};
    _ = try irqs.dispatch(&core);
    try std.testing.expectEqual(@as(u32, 0x2200_7FF8 - frame_bytes), try core.register(.sp));
    try std.testing.expect(try core.readWord(0x2200_7FF8 - 4) & xpsr_stack_align != 0);

    try core.setRegister(.pc, exc_return_thread_msp);
    try irqs.exit(&core, exc_return_thread_msp);
    try std.testing.expectEqual(@as(u32, 0x2200_7FFC), try core.register(.sp));
}

test "cpsid i holds a pend instead of losing it" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_8000);
    try core.setRegister(.primask, primask_pm);
    try core.writeWord(memmap.scb.icsr, icsr_pendstset);

    var irqs = Nvic{};
    try std.testing.expectEqual(@as(?u16, null), try irqs.dispatch(&core));
    try std.testing.expectEqual(@as(u64, 1), irqs.held);

    // cpsie i, and the exception that was waiting is taken.
    try core.setRegister(.primask, 0);
    try std.testing.expectEqual(@as(?u16, systick), try irqs.dispatch(&core));
}

test "an enabled line is taken, a disabled one is not" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_8000);
    // Line 5 pending but not enabled.
    try core.writeWord(memmap.nvic.ispr, 1 << 5);

    var irqs = Nvic{};
    try std.testing.expectEqual(@as(?u16, null), try irqs.dispatch(&core));

    try core.writeWord(memmap.nvic.iser, 1 << 5);
    try std.testing.expectEqual(@as(?u16, first_irq + 5), try irqs.dispatch(&core));
    try std.testing.expect(try core.readWord(memmap.nvic.iabr) & (1 << 5) != 0);
    try core.setRegister(.pc, exc_return_thread_msp);
    try irqs.exit(&core, exc_return_thread_msp);
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.nvic.iabr));
}

test "a write to ICER disables the line it names" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_8000);
    try core.writeWord(memmap.nvic.iser, (1 << 5) | (1 << 9));
    try core.writeWord(memmap.nvic.ispr, 1 << 5);
    try core.writeWord(memmap.nvic.icer, 1 << 5);

    var irqs = Nvic{};
    try std.testing.expectEqual(@as(?u16, null), try irqs.dispatch(&core));
    try std.testing.expectEqual(@as(u32, 1 << 9), try core.readWord(memmap.nvic.iser));
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.nvic.icer));
}

test "ICSR's clear bit unpends SysTick before it is ever entered" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_8000);
    try core.writeWord(memmap.scb.icsr, icsr_pendstset | icsr_pendstclr);

    var irqs = Nvic{};
    try std.testing.expectEqual(@as(?u16, null), try irqs.dispatch(&core));
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.scb.icsr));
}

test "the more urgent line wins, and ties go to the lower exception number" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_8000);
    try core.writeWord(memmap.nvic.iser, (1 << 2) | (1 << 3));
    try core.writeWord(memmap.nvic.ispr, (1 << 2) | (1 << 3));
    // IPR byte per line: line 2 at 0x80, line 3 at 0x20 (more urgent).
    try core.writeWord(memmap.nvic.ipr, (0x80 << 16) | (0x20 << 24));

    var irqs = Nvic{};
    try std.testing.expectEqual(@as(?u16, first_irq + 3), try irqs.dispatch(&core));
    try core.setRegister(.pc, exc_return_thread_msp);
    try irqs.exit(&core, exc_return_thread_msp);
    try std.testing.expectEqual(@as(?u16, first_irq + 2), try irqs.dispatch(&core));

    // Same priority now, so the lower number goes first.
    try core.setRegister(.pc, exc_return_thread_msp);
    try irqs.exit(&core, exc_return_thread_msp);
    try core.writeWord(memmap.nvic.ipr, 0);
    try core.writeWord(memmap.nvic.ispr, (1 << 2) | (1 << 3));
    try std.testing.expectEqual(@as(?u16, first_irq + 2), try irqs.dispatch(&core));
}

test "a running handler is only preempted by something more urgent" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_8000);
    try core.writeWord(memmap.nvic.iser, (1 << 2) | (1 << 3));
    try core.writeWord(memmap.nvic.ispr, 1 << 2);
    try core.writeWord(memmap.nvic.ipr, (0x40 << 16) | (0x40 << 24));

    var irqs = Nvic{};
    try std.testing.expectEqual(@as(?u16, first_irq + 2), try irqs.dispatch(&core));

    // Equal priority does not preempt.
    try core.writeWord(memmap.nvic.ispr, 1 << 3);
    try std.testing.expectEqual(@as(?u16, null), try irqs.dispatch(&core));
    try std.testing.expectEqual(@as(u64, 1), irqs.held);

    // More urgent does, and nests: LR says the return is into a handler.
    try core.writeWord(memmap.nvic.ipr, (0x40 << 16) | (0x10 << 24));
    try std.testing.expectEqual(@as(?u16, first_irq + 3), try irqs.dispatch(&core));
    try std.testing.expectEqual(exc_return_handler_msp, try core.register(.lr));
    try std.testing.expectEqual(@as(usize, 2), irqs.depth);
}

test "EXC_RETURN is recognised and ordinary addresses are not" {
    try std.testing.expect(isExceptionReturn(exc_return_thread_msp));
    try std.testing.expect(isExceptionReturn(exc_return_handler_msp));
    try std.testing.expect(!isExceptionReturn(0x2200_0400));
    try std.testing.expect(!isExceptionReturn(memmap.ppb_base));
}

test "returning with nothing active is an error, not a silent unwind" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var irqs = Nvic{};
    try std.testing.expectError(Error.NotInHandler, irqs.exit(&core, exc_return_thread_msp));
}

test "a pend with no handler in the table is held, not jumped to" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.setRegister(.sp, 0x2200_8000);
    try core.writeWord(memmap.scb.icsr, icsr_pendstset);

    // No VTOR, no fallback base, so nothing to enter.
    var irqs = Nvic{};
    try std.testing.expectEqual(@as(?u16, null), try irqs.dispatch(&core));
    try std.testing.expectEqual(@as(u64, 1), irqs.held);
    try std.testing.expect(try core.readWord(memmap.scb.icsr) & icsr_pendstset != 0);
}

test "with VTOR still zero the reset vector base is where the table is" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    // The image never relocated the table: VTOR reads as it resets.
    try core.writeWord(memmap.scb.vtor, 0);
    try core.setRegister(.sp, 0x2200_8000);
    try core.writeWord(memmap.scb.icsr, icsr_pendstset);

    var irqs = Nvic{ .vector_base = 0x2200_0000 };
    try std.testing.expectEqual(@as(?u16, systick), try irqs.dispatch(&core));
    try std.testing.expectEqual(FakeCore.handlerFor(systick), try core.register(.pc));
}

test "running is null in Thread mode and the innermost handler's priority inside one" {
    var unit = Nvic{};
    try std.testing.expect(unit.running() == null);
    unit.active[0] = .{ .number = 16, .priority = 0x80 };
    unit.active[1] = .{ .number = 17, .priority = 0x40 };
    unit.depth = 2;
    try std.testing.expectEqual(@as(?u8, 0x40), unit.running());
    unit.depth = 1;
    try std.testing.expectEqual(@as(?u8, 0x80), unit.running());
}

test "DHCSR.C_MASKINTS holds SysTick and external lines back while debug is on" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_8000);
    try core.writeWord(memmap.nvic.ispr, 1 << 5);
    try core.writeWord(memmap.nvic.iser, 1 << 5);
    try core.writeWord(memmap.scb.icsr, icsr_pendstset);
    const dhcsr = ra8.chip.periph.dcb;
    try core.writeWord(dhcsr.base, dhcsr.dhcsr_bits.c_debugen | dhcsr.dhcsr_bits.c_maskints);

    var irqs = Nvic{};
    try std.testing.expectEqual(@as(?u16, null), try irqs.dispatch(&core));
    try core.writeWord(dhcsr.base, dhcsr.dhcsr_bits.c_debugen);
    try std.testing.expectEqual(@as(?u16, systick), try irqs.dispatch(&core));
}

test "an unprivileged thread on the Process stack has its frame left in PSP" {
    var core = FakeCore{ .words = std.AutoHashMap(u32, u32).init(std.testing.allocator), .unprivileged = true };
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2219_0CF0);
    try core.setRegister(.pc, 0x020C_1442);
    try core.writeWord(memmap.scb.icsr, icsr_pendstset);

    var irqs = Nvic{ .on_process = true, .main_sp = 0x2219_FFE0 };
    try std.testing.expectEqual(@as(?u16, systick), try irqs.dispatch(&core));
    // A module thread's SVC handler reads its frame through PSP; a dropped
    // write left it on whatever the last switch-in had put there.
    const frame = 0x2219_0CF0 - frame_bytes;
    try std.testing.expectEqual(@as(u32, frame), try core.register(.psp));
    try std.testing.expectEqual(@as(u32, 0x020C_1442), try core.readWord(frame + 24));
    try std.testing.expectEqual(@as(u32, 0x2219_FFE0), try core.register(.sp));
}
