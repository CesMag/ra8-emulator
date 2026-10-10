//! Tests for src/chip/periph/itns.zig.

const std = @import("std");
const ra8 = @import("ra8");
const itns = ra8.chip.periph.nvic.itns;

/// The ITNS words as plain memory.
const Words = struct {
    word: [16]u32 = @splat(0),

    pub fn readWord(self: *Words, address: u32) !u32 {
        return self.word[(address - itns.base) / 4];
    }
};

test "ITNS spans 0xE000_E380 to 0xE000_E3BC, sixteen words" {
    try std.testing.expectEqual(@as(u32, 0xE000_E380), itns.base);
    try std.testing.expectEqual(itns.base + 4 * 15, itns.last);
}

test "this part's 96 lines reach the first three words" {
    try std.testing.expectEqual(@as(u32, 3), itns.words);
    try std.testing.expectEqual(@as(u32, 0xE000_E388), itns.wordFor(95));
}

test "every line targets Secure out of reset" {
    var words = Words{};
    try std.testing.expectEqual(itns.Target.secure, try itns.target(&words, 0));
    try std.testing.expectEqual(itns.Target.secure, try itns.target(&words, 95));
}

test "a set bit sends only its own line to Non-secure" {
    var words = Words{};
    words.word[1] = itns.bitFor(37);
    try std.testing.expectEqual(itns.Target.non_secure, try itns.target(&words, 37));
    try std.testing.expectEqual(itns.Target.secure, try itns.target(&words, 36));
    try std.testing.expectEqual(itns.Target.secure, try itns.target(&words, 5));
}

test "an exception number maps through the first external line" {
    var words = Words{};
    words.word[0] = itns.bitFor(0);
    try std.testing.expectEqual(itns.Target.non_secure, try itns.targetOf(&words, 16));
    try std.testing.expectError(itns.Error.NotAnIrq, itns.targetOf(&words, 15));
}

test "a line past this part's lines is refused" {
    var words = Words{};
    try std.testing.expectError(itns.Error.NotAnIrq, itns.target(&words, 96));
}

// RA8EMU-142: an IRQ NVIC_ITNS hands to Non-secure is taken from the
// Non-secure vector table. The exception fixture's RAM sits behind the Zig
// core's real SCS routing, so VTOR reads the bank of the core's state.
const fixture = @import("../core/cpu/exception/ram.zig");
const scs_route = ra8.chip.core.cpu.board_bus.scs_route;
const cpu_bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;

const vtor_ns: u32 = 0xE002_ED08;
const ns_table: u32 = fixture.base + 0x200;
const ns_handler: u32 = fixture.base + 0x1C0;

const Routed = struct {
    ram: fixture.Ram = .{},
    state: ?*const ra8.chip.core.banked.Banked = null,

    fn view(self: *Routed) cpu_bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) cpu_bus.Error!void {
        const self: *Routed = @ptrCast(@alignCast(ctx));
        const ram = self.ram.view();
        switch (scs_route.land(self.state, address)) {
            .res0 => @memset(into, 0),
            .at => |at| try ram.vtable.read(ram.ctx, at, into),
        }
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) cpu_bus.Error!void {
        const self: *Routed = @ptrCast(@alignCast(ctx));
        const ram = self.ram.view();
        switch (scs_route.land(self.state, address)) {
            .res0 => {},
            .at => |at| try ram.vtable.write(ram.ctx, at, from),
        }
    }
};

/// Both tables aim IRQ 0 at different handlers; ITNS0 bit 0 is `itns0`.
fn bootRouted(routed: *Routed, itns0: u32) !Cpu {
    const r = &routed.ram;
    r.putWord(fixture.base + 16 * 4, fixture.handler | 1);
    r.putWord(ns_table + 16 * 4, ns_handler | 1);
    r.putHalf(fixture.handler, 0x4770);
    r.putHalf(ns_handler, 0x4770);
    r.putWord(vtor_ns, ns_table);
    r.putWord(itns.base, itns0);
    var cpu = try fixture.boot(r);
    cpu.banked.other.msp = fixture.psp_top;
    return cpu;
}

test "an ITNS interrupt enters its handler from the Non-secure vector table" {
    var routed: Routed = .{};
    var cpu = try bootRouted(&routed, 1);
    routed.state = &cpu.banked;
    cpu.bus = routed.view();
    _ = try ra8.chip.core.cpu.exception.entry.take(&cpu, 16, fixture.code);
    try std.testing.expectEqual(.non_secure, cpu.banked.current);
    try std.testing.expectEqual(ns_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 16), cpu.regs.xpsr & 0x1FF);
}

test "a Secure interrupt still takes the Secure table with VTOR_NS set" {
    var routed: Routed = .{};
    var cpu = try bootRouted(&routed, 0);
    routed.state = &cpu.banked;
    cpu.bus = routed.view();
    _ = try ra8.chip.core.cpu.exception.entry.take(&cpu, 16, fixture.code);
    try std.testing.expectEqual(.secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 16), cpu.regs.xpsr & 0x1FF);
}
