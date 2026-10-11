//! Tests for src/session/run/soak_fault.zig.
const std = @import("std");
const ra8 = @import("ra8");
const clocks = ra8.chip.periph.clocks;
const time_policy = ra8.session.run;
const soak_fault = time_policy.soak_fault;
const status = ra8.chip.periph.fault_status;
const Kind = time_policy.soak.Kind;

test "clear words are no event" {
    try std.testing.expect(soak_fault.kind(.{}) == null);
}

test "a stack-limit overflow is named before its UsageFault and HardFault" {
    const words: status.Words = .{ .cfsr = status.Cause.stkof.bit() | status.Cause.undefinstr.bit(), .hfsr = status.Hard.forced.bit() };
    try std.testing.expectEqual(Kind.stack_overflow, soak_fault.kind(words).?);
}

test "each configurable fault is named before the HardFault it escalated to" {
    const forced = status.Hard.forced.bit();
    try std.testing.expectEqual(Kind.mem_manage, soak_fault.kind(.{ .cfsr = status.Cause.daccviol.bit(), .hfsr = forced }).?);
    try std.testing.expectEqual(Kind.bus_fault, soak_fault.kind(.{ .cfsr = status.Cause.preciserr.bit(), .hfsr = forced }).?);
    try std.testing.expectEqual(Kind.usage_fault, soak_fault.kind(.{ .cfsr = status.Cause.divbyzero.bit(), .hfsr = forced }).?);
    try std.testing.expectEqual(Kind.secure_fault, soak_fault.kind(.{ .sfsr = 1, .hfsr = forced }).?);
    try std.testing.expectEqual(Kind.hard_fault, soak_fault.kind(.{ .hfsr = status.Hard.vecttbl.bit() }).?);
}

const Fake = struct {
    cfsr: u32 = 0,
    cfsr_ns: u32 = 0,
    hfsr: u32 = 0,

    pub fn readWord(self: *const Fake, address: u32) error{Unmapped}!u32 {
        return switch (address) {
            ra8.chip.core.memmap.scb.cfsr => self.cfsr,
            ra8.chip.core.memmap.scb.cfsr + soak_fault.ns_offset => self.cfsr_ns,
            ra8.chip.core.memmap.scb.hfsr => self.hfsr,
            else => error.Unmapped,
        };
    }
};

fn same(address: u32) ?u32 {
    return address;
}

test "the words fold in a Non-secure fault's banked bits and read the unreadable as clear" {
    const memory: Fake = .{ .cfsr = status.Cause.preciserr.bit(), .cfsr_ns = status.Cause.stkof.bit() | status.Cause.preciserr.bit(), .hfsr = status.Hard.forced.bit() };
    const words = soak_fault.words(&memory, &same);
    try std.testing.expectEqual(status.Cause.preciserr.bit() | status.Cause.stkof.bit(), words.cfsr);
    try std.testing.expectEqual(status.Hard.forced.bit(), words.hfsr);
    try std.testing.expectEqual(@as(u32, 0), words.sfsr);
    try std.testing.expectEqual(Kind.stack_overflow, soak_fault.kind(words).?);
}

test "an armed soak stops on a fault and names it" {
    var state = time_policy.soak.Soak{ .armed = true };
    state.note(soak_fault.kind(.{ .cfsr = status.Cause.stkof.bit() }).?, 7_200_000_000_000);
    var buffer: [96]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buffer);
    try state.line(&stream);
    try std.testing.expectEqualStrings("soak: stopped on stack overflow (UsageFault STKOF) at 7200.000000000 s virtual, core 0\n", stream.buffered());
}
