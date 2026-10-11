//! Tests for src/session/unit_view.zig: firmware that programs the debug
//! units and reads them back sees on the Zig core what the stop machine
//! holds (RA8EMU-673), with the recorded stops.
const std = @import("std");
const ra8 = @import("ra8");

const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const memmap = ra8.chip.core.memmap;
const stop_machine = ra8.session.stop_machine;
const step_hook = ra8.session.step_hook;
const watch_bus = step_hook.watch.bus;
const unit_view = watch_bus.unit_view;
const zig_drive = step_hook.zig.drive;
const ZigCore = step_hook.zig.core.ZigCore;
const fpb = ra8.session.fpb;
const dwt = ra8.chip.periph.dwt;
const itm = ra8.chip.periph.itm;
const dcb = ra8.chip.periph.dcb;

const layout = struct {
    const code: u32 = memmap.sram_base;
    const data: u32 = memmap.sram_base + 0x1000;
    const stack: u32 = memmap.sram_base + 0x1F00;
    const budget: u64 = 32;
    const trace: u32 = 0xE000_0000;
    const scs: u32 = 0xE000_E000;
};

/// 8 KiB of SRAM, the ITM/DWT/FPB pages and the SCS page, all plain memory.
const Memory = struct {
    sram: [0x2000]u8 = @splat(0),
    trace: [0x3000]u8 = @splat(0),
    scs: [0x1000]u8 = @splat(0),

    fn view(self: *Memory) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn slice(self: *Memory, address: u32, len: usize) bus.Error![]u8 {
        if (within(address, len, layout.code, self.sram.len)) return self.sram[address - layout.code ..][0..len];
        if (within(address, len, layout.trace, self.trace.len)) return self.trace[address - layout.trace ..][0..len];
        if (within(address, len, layout.scs, self.scs.len)) return self.scs[address - layout.scs ..][0..len];
        return bus.Error.Unmapped;
    }

    fn within(address: u32, len: usize, from: u32, span: usize) bool {
        return address >= from and address - from + len <= span;
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        @memcpy(into, try self.slice(address, into.len));
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        @memcpy(try self.slice(address, from.len), from);
    }
};

/// A Zig core on `memory` with the debugger listening, code at sram_base.
const Rig = struct {
    memory: Memory = .{},
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,
    watching: watch_bus.WatchBus = undefined,
    cpu: Cpu = undefined,

    fn wire(self: *Rig, program: []const u8) ZigCore {
        self.driver = .{ .machine = &self.machine };
        self.watching = .{ .inner = self.memory.view(), .driver = &self.driver };
        self.cpu = .{ .bus = self.watching.view() };
        self.cpu.regs.xpsr = ra8.chip.core.cpu.regs.xpsr_bits.thumb;
        @memcpy(self.memory.sram[0..program.len], program);
        const core: ZigCore = .{ .cpu = &self.cpu };
        core.setRegister(.pc, layout.code);
        core.setRegister(.sp, layout.stack);
        return core;
    }

    fn run(self: *Rig, core: ZigCore) zig_drive.Ended {
        self.machine.begin();
        return zig_drive.runWatched(core, &self.machine, layout.budget, &self.watching);
    }
};

test "a word no debug unit owns is left as memory held it" {
    const machine: stop_machine.Machine = .{};
    try std.testing.expectEqual(@as(?u32, null), unit_view.word(&machine, layout.data, 7));
    var bytes = [_]u8{ 1, 2, 3, 4 };
    unit_view.overlay(&machine, layout.data, &bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, &bytes);
}

test "DWT_CTRL keeps what was stored but reads this core's NUMCOMP" {
    const machine: stop_machine.Machine = .{};
    const seen = unit_view.word(&machine, dwt.base, 0x0000_0001).?;
    try std.testing.expectEqual(machine.dwt.ctrlWord(0x0000_0001), seen);
}

test "a byte load of a stimulus port reads its byte of FIFO-ready" {
    const machine: stop_machine.Machine = .{};
    var byte = [_]u8{0xAA};
    unit_view.overlay(&machine, itm.base, &byte);
    try std.testing.expectEqual(@as(u8, @truncate(itm.fifo_ready)), byte[0]);
}

test "DFSR reads the bits the machine latched" {
    var machine: stop_machine.Machine = .{};
    machine.dcb.latch(dcb.dfsr_bits.bkpt);
    try std.testing.expectEqual(machine.dcb.dfsr, unit_view.word(&machine, dcb.dfsr_address, 0).?);
}

// str r1,[r0,#8] (FP_COMP0); str r2,[r0] (FP_CTRL); ldr r3,[r0]; nop; nop.
test "firmware that programs the FPB halts on its comparator and reads FP_CTRL back" {
    var rig: Rig = .{};
    const core = rig.wire(&[_]u8{ 0x81, 0x60, 0x02, 0x60, 0x03, 0x68, 0x00, 0xBF, 0x00, 0xBF });
    core.setRegister(.r0, fpb.base);
    core.setRegister(.r1, (layout.code + 8) | fpb.comp_enable);
    core.setRegister(.r2, fpb.ctrl_bits.enable | fpb.ctrl_bits.key);
    const ended = rig.run(core);
    try std.testing.expectEqual(@as(usize, 0), ended.stop.unit_break);
    try std.testing.expectEqual(layout.code + 8, core.register(.pc));
    const ctrl = core.register(.r3);
    try std.testing.expectEqual(fpb.ctrl_bits.enable, ctrl & 0x3);
    try std.testing.expectEqual(@as(u32, 1), ctrl >> 28);
}

// str r1,[r0,#0x20]; str r2,[r0,#0x28]; str r4,[r3]; ldr r5,[r0,#0x28]; nop.
test "firmware that arms a DWT write comparator halts after the store and reads MATCHED once" {
    var rig: Rig = .{};
    rig.machine.dwt.trcena = true;
    const function = dwt.match.data_write | (dwt.function_bits.action_debug << dwt.function_bits.action_shift) | (2 << dwt.function_bits.size_shift);
    const core = rig.wire(&[_]u8{ 0x01, 0x62, 0x82, 0x62, 0x1C, 0x60, 0x85, 0x6A, 0x00, 0xBF });
    core.setRegister(.r0, dwt.base);
    core.setRegister(.r1, layout.data);
    core.setRegister(.r2, function);
    core.setRegister(.r3, layout.data);
    core.setRegister(.r4, 0x77);
    try std.testing.expectEqual(@as(usize, 0), rig.run(core).stop.unit_watch);
    try std.testing.expectEqual(layout.code + 6, core.register(.pc));
    rig.machine.proceed();
    _ = zig_drive.runWatched(core, &rig.machine, 1, &rig.watching);
    const id0 = dwt.id.of(0) << dwt.function_bits.id_shift;
    try std.testing.expectEqual(id0 | function | dwt.function_bits.matched, core.register(.r5));
    try std.testing.expectEqual(id0 | function, rig.machine.dwt.peek(dwt.offsets.function0).?);
}

// str r1,[r0,#0x30] (DWT_COMP1); str r2,[r0,#0x38] (DWT_FUNCTION1); ldr r5,[r3]; nop; nop.
test "firmware that arms a DWT read Data Value comparator halts after the load that reads it" {
    var rig: Rig = .{};
    rig.machine.dwt.trcena = true;
    const function = dwt.match.data_value_read | (dwt.function_bits.action_debug << dwt.function_bits.action_shift) | (2 << dwt.function_bits.size_shift);
    const core = rig.wire(&[_]u8{ 0x01, 0x63, 0x82, 0x63, 0x1D, 0x68, 0x00, 0xBF, 0x00, 0xBF });
    @memcpy(rig.memory.sram[0x1000..0x1004], &[_]u8{ 0x34, 0x12, 0x00, 0x00 });
    core.setRegister(.r0, dwt.base);
    core.setRegister(.r1, 0x1234);
    core.setRegister(.r2, function);
    core.setRegister(.r3, layout.data);
    const ended = rig.run(core);
    try std.testing.expectEqual(@as(usize, 1), ended.stop.unit_watch);
    try std.testing.expectEqual(layout.code + 6, core.register(.pc));
    try std.testing.expectEqual(@as(u32, 0x1234), core.register(.r5));
}

// str r5,[r6] (TER); str r5,[r7] (TCR); strb r1,[r0]; strb r2,[r0]; ldr r3,[r0]; nop.
test "firmware printing through ITM port 0 leaves its text with the debug core" {
    var rig: Rig = .{};
    const core = rig.wire(&[_]u8{ 0x35, 0x60, 0x3D, 0x60, 0x01, 0x70, 0x02, 0x70, 0x03, 0x68, 0x00, 0xBF });
    core.setRegister(.r0, itm.base);
    core.setRegister(.r1, 'H');
    core.setRegister(.r2, 'i');
    core.setRegister(.r3, 0);
    core.setRegister(.r5, 1);
    core.setRegister(.r6, itm.base + itm.offsets.ter);
    core.setRegister(.r7, itm.base + itm.offsets.tcr);
    _ = try rig.machine.breaks.add(.{ .address = layout.code + 10 });
    _ = rig.run(core);
    try std.testing.expectEqual(layout.code + 10, core.register(.pc));
    try std.testing.expectEqualStrings("Hi", rig.machine.itm.output());
    try std.testing.expectEqual(itm.fifo_ready, core.register(.r3));
}

// ldr r3,[r0] (DHCSR); str r1,[r0] (keyed C_HALT); nop; nop.
test "firmware sees the debugger in DHCSR and halts itself with a keyed C_HALT" {
    var rig: Rig = .{};
    rig.machine.dcb.attachDebugger();
    const bits = dcb.dhcsr_bits;
    const core = rig.wire(&[_]u8{ 0x03, 0x68, 0x01, 0x60, 0x00, 0xBF, 0x00, 0xBF });
    core.setRegister(.r0, dcb.base);
    core.setRegister(.r1, (bits.key << bits.key_shift) | bits.c_halt | bits.c_debugen);
    const ended = rig.run(core);
    try std.testing.expect(ended.stop == .halt_requested);
    try std.testing.expectEqual(layout.code + 4, core.register(.pc));
    try std.testing.expectEqual(bits.c_debugen | bits.s_regrdy, core.register(.r3));
}

// str r1,[r0] (DEMCR, TRCENA set); strb r2,[r0] (byte 0 only); nop.
test "firmware storing DEMCR.TRCENA turns the DWT on, and a byte store elsewhere leaves it" {
    var rig: Rig = .{};
    const core = rig.wire(&[_]u8{ 0x01, 0x60, 0x02, 0x70, 0x00, 0xBF });
    core.setRegister(.r0, dcb.demcr_address);
    core.setRegister(.r1, dcb.demcr_bits.trcena);
    core.setRegister(.r2, 0);
    _ = zig_drive.runWatched(core, &rig.machine, 3, &rig.watching);
    try std.testing.expect(rig.machine.dwt.trcena);
}

// strb r2,[r0,#3] (DEMCR's top byte, TRCENA clear); nop.
test "firmware clearing DEMCR.TRCENA with a byte store turns the DWT off" {
    var rig: Rig = .{};
    rig.machine.dwt.trcena = true;
    const core = rig.wire(&[_]u8{ 0xC2, 0x70, 0x00, 0xBF });
    core.setRegister(.r0, dcb.demcr_address);
    core.setRegister(.r2, 0);
    _ = zig_drive.runWatched(core, &rig.machine, 2, &rig.watching);
    try std.testing.expect(!rig.machine.dwt.trcena);
}

// str r1,[r0,#8] (FP_COMP0); str r2,[r0] (FP_CTRL); nop x4. FPB at +6, break at +8.
test "with halting debug off and MON_EN set, an FPB match pends DebugMonitor and latches DFSR" {
    var rig: Rig = .{};
    rig.machine.halting = false;
    const core = rig.wire(&[_]u8{ 0x81, 0x60, 0x02, 0x60, 0x00, 0xBF, 0x00, 0xBF, 0x00, 0xBF, 0x00, 0xBF });
    std.mem.writeInt(u32, rig.memory.scs[dcb.demcr_address - layout.scs ..][0..4], dcb.demcr_bits.mon_en, .little);
    core.setRegister(.r0, fpb.base);
    core.setRegister(.r1, (layout.code + 6) | fpb.comp_enable);
    core.setRegister(.r2, fpb.ctrl_bits.enable | fpb.ctrl_bits.key);
    _ = try rig.machine.breaks.add(.{ .address = layout.code + 8 });
    const ended = rig.run(core);
    try std.testing.expect(ended.stop == .breakpoint);
    try std.testing.expectEqual(layout.code + 8, core.register(.pc));
    try std.testing.expect(try core.readWord(dcb.demcr_address) & dcb.demcr_bits.mon_pend != 0);
    try std.testing.expect(try core.readWord(dcb.dfsr_address) & dcb.dfsr_bits.bkpt != 0);
}
