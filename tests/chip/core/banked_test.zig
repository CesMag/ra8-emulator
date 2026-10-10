//! Tests for src/chip/core/banked.zig: the Secure/Non-secure register banks.
const std = @import("std");
const ra8 = @import("ra8");
const banked = ra8.chip.core.banked;
const regs = ra8.chip.core.cpu.regs;
const Regs = regs.Regs;

test "a state switch swaps the banked registers and keeps the shared ones" {
    const secure_control = regs.control_bits.spsel | regs.control_bits.fpca |
        regs.control_bits.pac_en | regs.control_bits.upac_en;
    const non_secure_control = regs.control_bits.npriv | regs.control_bits.bti_en |
        regs.control_bits.ubti_en;
    var r = Regs{ .msp = 0x2000_1000, .psp = 0x2000_2000, .primask = 1, .basepri = 0x40, .control = secure_control, .lr = 0xFFFF_FFF9, .msplim = 0x2000_0800 };
    r.low[0] = 7;
    var b = banked.Banked{};
    b.other = .{ .msp = 0x3000_1000, .psp = 0x3000_2000, .msplim = 0x3000_0000, .control = non_secure_control };
    b.switchTo(&r, .non_secure);
    try std.testing.expectEqual(banked.State.non_secure, b.current);
    try std.testing.expectEqual(@as(u32, 0x3000_1000), r.msp);
    try std.testing.expectEqual(@as(u32, 0x3000_2000), r.psp);
    try std.testing.expectEqual(@as(u32, 0x3000_0000), r.msplim);
    try std.testing.expectEqual(@as(u32, 0), r.primask);
    // nPRIV/SPSEL and PACBTI enables are banked; FPCA/SFPA stay shared.
    try std.testing.expectEqual(non_secure_control | regs.control_bits.fpca, r.control);
    try std.testing.expectEqual(@as(u32, 7), r.low[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF9), r.lr);
    try std.testing.expectEqual(banked.Bank{ .msp = 0x2000_1000, .psp = 0x2000_2000, .msplim = 0x2000_0800, .primask = 1, .basepri = 0x40, .control = regs.control_bits.spsel | regs.control_bits.pac_en | regs.control_bits.upac_en }, b.other);
    b.switchTo(&r, .secure);
    try std.testing.expectEqual(@as(u32, 0x2000_1000), r.msp);
    try std.testing.expectEqual(secure_control, r.control);
    try std.testing.expectEqual(@as(u32, 0x40), r.basepri);
}

test "switching to the running state changes nothing" {
    var r = Regs{ .msp = 0x10 };
    var b = banked.Banked{};
    b.other.msp = 0x20;
    b.switchTo(&r, .secure);
    try std.testing.expectEqual(@as(u32, 0x10), r.msp);
    try std.testing.expectEqual(@as(u32, 0x20), b.other.msp);
}

test "bank reads either state's copy wherever it lives" {
    var r = Regs{ .msp = 0x10 };
    var b = banked.Banked{};
    b.other.msp = 0x20;
    try std.testing.expectEqual(@as(u32, 0x10), b.bank(&r, .secure).msp);
    try std.testing.expectEqual(@as(u32, 0x20), b.bank(&r, .non_secure).msp);
    b.switchTo(&r, .non_secure);
    try std.testing.expectEqual(@as(u32, 0x10), b.bank(&r, .secure).msp);
    try std.testing.expectEqual(@as(u32, 0x20), b.bank(&r, .non_secure).msp);
}

test "Secure code reaches the Non-secure copy through the _NS encodings" {
    const s = banked.sysm;
    var r = Regs{};
    var b = banked.Banked{};
    try std.testing.expect(b.writeNs(&r, s.msp_ns, 0x3000_1003));
    try std.testing.expect(b.writeNs(&r, s.psp_ns, 0x3000_2002));
    try std.testing.expect(b.writeNs(&r, s.msplim_ns, 0x3000_0007));
    try std.testing.expect(b.writeNs(&r, s.psplim_ns, 0x3000_0105));
    try std.testing.expect(b.writeNs(&r, s.primask_ns, 3));
    try std.testing.expect(b.writeNs(&r, s.basepri_ns, 0x1E0));
    try std.testing.expect(b.writeNs(&r, s.faultmask_ns, 2));
    const ns_enables = regs.control_bits.pac_en | regs.control_bits.bti_en |
        regs.control_bits.upac_en | regs.control_bits.ubti_en;
    try std.testing.expect(b.writeNs(&r, s.control_ns, 0xFF));
    try std.testing.expectEqual(@as(?u32, 0x3000_1000), b.readNs(&r, s.msp_ns));
    try std.testing.expectEqual(@as(?u32, 0x3000_2000), b.readNs(&r, s.psp_ns));
    try std.testing.expectEqual(@as(?u32, 0x3000_0000), b.readNs(&r, s.msplim_ns));
    try std.testing.expectEqual(@as(?u32, 0x3000_0100), b.readNs(&r, s.psplim_ns));
    try std.testing.expectEqual(@as(?u32, 1), b.readNs(&r, s.primask_ns));
    try std.testing.expectEqual(@as(?u32, 0xE0), b.readNs(&r, s.basepri_ns));
    try std.testing.expectEqual(@as(?u32, 0), b.readNs(&r, s.faultmask_ns));
    try std.testing.expectEqual(@as(?u32, 0b11 | ns_enables), b.readNs(&r, s.control_ns));
    // The running (Secure) copy is untouched.
    try std.testing.expectEqual(@as(u32, 0), r.msp);
    try std.testing.expectEqual(@as(u32, 0), r.control);
}

test "SP_NS follows the Non-secure SPSEL and the shared mode" {
    const s = banked.sysm;
    var r = Regs{};
    var b = banked.Banked{};
    b.other = .{ .msp = 0x100, .psp = 0x200, .control = banked.control_banked };
    try std.testing.expectEqual(@as(?u32, 0x200), b.readNs(&r, s.sp_ns));
    try std.testing.expect(b.writeNs(&r, s.sp_ns, 0x204));
    try std.testing.expectEqual(@as(u32, 0x204), b.other.psp);
    r.xpsr = 3; // Handler mode always uses the Main stack.
    try std.testing.expectEqual(@as(?u32, 0x100), b.readNs(&r, s.sp_ns));
}

test "the _NS encodings are not this file's from Non-secure state" {
    var r = Regs{};
    var b = banked.Banked{ .current = .non_secure };
    try std.testing.expectEqual(@as(?u32, null), b.readNs(&r, banked.sysm.msp_ns));
    try std.testing.expect(!b.writeNs(&r, banked.sysm.msp_ns, 4));
    var s = banked.Banked{};
    try std.testing.expectEqual(@as(?u32, null), s.readNs(&r, 0x08));
    try std.testing.expect(!s.writeNs(&r, 0x92, 0));
}

// RA8EMU-242: each of MSPLIM_S, PSPLIM_S, MSPLIM_NS and PSPLIM_NS stops a
// push in its own state and is parked, unchecked, in the other.

const fixture = @import("cpu/exception/ram.zig");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Stop = ra8.chip.core.cpu.cpu.Stop;
const State = ra8.chip.core.cpu.cpu.attribution.State;
const usgfaultena: u32 = 1 << 18;

/// Attributes every address to one state, so the core runs where it is put.
const Everywhere = struct {
    state: State,

    fn of(context: *anyopaque, address: u32) State {
        _ = address;
        const self: *Everywhere = @ptrCast(@alignCast(context));
        return self.state;
    }
};

const Stack = enum { main, process };

/// One state's limit for `stack` at the top of that stack, the other's at 0.
const Limits = struct { secure: u32, non_secure: u32 };

/// Steps `push {r0}` in `run` on `stack`, with the limits set in their own
/// states before the switch, and reports whether it retired normally.
fn pushRetires(run: banked.State, stack: Stack, limits: Limits) !bool {
    var ram: fixture.Ram = .{};
    ram.putWord(fixture.base + 6 * 4, fixture.handler | 1);
    ram.putWord(ra8.chip.core.memmap.scb.shcsr, usgfaultena);
    ram.putHalf(fixture.code, 0xB401); // push {r0}
    var cpu: Cpu = try fixture.boot(&ram);
    var where: Everywhere = .{ .state = if (run == .secure) .secure else .non_secure };
    cpu.attribution = .{ .context = &where, .stateFn = Everywhere.of };
    switch (stack) {
        .main => {
            cpu.regs.msplim = limits.secure;
            cpu.banked.other.msplim = limits.non_secure;
        },
        .process => {
            cpu.regs.psplim = limits.secure;
            cpu.banked.other.psplim = limits.non_secure;
        },
    }
    cpu.banked.switchTo(&cpu.regs, run);
    const top = if (stack == .main) fixture.msp_top else fixture.psp_top;
    if (stack == .process) cpu.regs.control |= regs.control_bits.spsel;
    if (stack == .main) cpu.regs.msp = top else cpu.regs.psp = top;
    const stop = cpu.step();
    const retired = stop == null and cpu.regs.pc == fixture.code + 2;
    if (retired) try std.testing.expectEqual(top - 4, cpu.regs.sp());
    return retired;
}

test "MSPLIM_S and PSPLIM_S stop a Secure push and are not checked Non-secure" {
    for ([_]Stack{ .main, .process }) |stack| {
        const top = if (stack == .main) fixture.msp_top else fixture.psp_top;
        const limits: Limits = .{ .secure = top, .non_secure = 0 };
        try std.testing.expect(!try pushRetires(.secure, stack, limits));
        try std.testing.expect(try pushRetires(.non_secure, stack, limits));
    }
}

test "MSPLIM_NS and PSPLIM_NS stop a Non-secure push and are not checked Secure" {
    for ([_]Stack{ .main, .process }) |stack| {
        const top = if (stack == .main) fixture.msp_top else fixture.psp_top;
        const limits: Limits = .{ .secure = 0, .non_secure = top };
        try std.testing.expect(!try pushRetires(.non_secure, stack, limits));
        try std.testing.expect(try pushRetires(.secure, stack, limits));
    }
}

test "a state switch carries the running limits out and the parked ones in" {
    var r = Regs{ .msplim = 0x2000_0100, .psplim = 0x2000_0200 };
    var b = banked.Banked{};
    b.other.msplim = 0x3000_0100;
    b.other.psplim = 0x3000_0200;
    b.switchTo(&r, .non_secure);
    try std.testing.expectEqual(@as(u32, 0x3000_0100), r.msplim);
    try std.testing.expectEqual(@as(u32, 0x3000_0200), r.psplim);
    try std.testing.expectEqual(@as(u32, 0x2000_0100), b.other.msplim);
    try std.testing.expectEqual(@as(u32, 0x2000_0200), b.other.psplim);
}

test "each state keeps its own stack low-water marks across a switch" {
    var r: Regs = .{};
    var b = banked.Banked{};
    r.setMsp(0x3000_0800);
    b.switchTo(&r, .non_secure);
    try std.testing.expectEqual(regs.never_low, r.low_msp);
    r.setMsp(0x2000_0400);
    b.switchTo(&r, .secure);
    try std.testing.expectEqual(@as(u32, 0x3000_0800), r.low_msp);
    try std.testing.expectEqual(@as(u32, 0x2000_0400), b.other.low_msp);
}

test "MSR MSP_NS from Secure lowers the Non-secure mark only" {
    var r: Regs = .{};
    var b = banked.Banked{};
    r.setMsp(0x3000_0800);
    try std.testing.expect(b.writeNs(&r, banked.sysm.msp_ns, 0x2000_0400));
    try std.testing.expectEqual(@as(u32, 0x2000_0400), b.other.low_msp);
    try std.testing.expectEqual(@as(u32, 0x3000_0800), r.low_msp);
}
