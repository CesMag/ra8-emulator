//! RA8EMU-271: every banked core register keeps its own value in each state
//! across a Secure -> Non-secure -> Secure round trip through Cpu.step
//! (BXNS out, SG back in at an NSC entry), on both the M85 and M33 profiles.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("../exception/ram.zig");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Profile = ra8.chip.core.cpu.decode.profile.Profile;
const Attribution = ra8.chip.core.cpu.cpu.attribution.Attribution;
const State = ra8.chip.core.cpu.cpu.attribution.State;
const Bank = ra8.chip.core.banked.Bank;

const entry: u32 = fixture.code + 0x20;

/// Every address is Non-secure callable, so the SG at `entry` is a gateway.
fn callable(context: *anyopaque, address: u32) State {
    _ = context;
    _ = address;
    return .callable;
}

const secure: Bank = .{
    .msp = fixture.msp_top,
    .psp = fixture.psp_top,
    .msplim = fixture.base + 0x200,
    .psplim = fixture.base + 0x2C0,
    .primask = 1,
    .basepri = 0x40,
    .faultmask = 0,
    .control = 0b01, // nPRIV, SPSEL clear
};

const non_secure: Bank = .{
    .msp = fixture.base + 0x280,
    .psp = fixture.base + 0x260,
    .msplim = fixture.base + 0x240,
    .psplim = fixture.base + 0x220,
    .primask = 0,
    .basepri = 0x80,
    .faultmask = 1,
    .control = 0b00,
};

fn running(cpu: *const Cpu) Bank {
    return cpu.banked.bank(&cpu.regs, cpu.banked.current);
}

fn roundTrip(profile: Profile) !void {
    var ram: fixture.Ram = .{};
    ram.putHalf(fixture.code, 0x4704); // bxns r0
    ram.putHalf(entry, 0xE97F); // sg
    ram.putHalf(entry + 2, 0xE97F);
    var cpu = try fixture.boot(&ram);
    var unused: u8 = 0;
    cpu.profile = profile;
    cpu.attribution = Attribution{ .context = &unused, .stateFn = callable };
    cpu.regs.msp = secure.msp;
    cpu.regs.psp = secure.psp;
    cpu.regs.msplim = secure.msplim;
    cpu.regs.psplim = secure.psplim;
    cpu.regs.primask = secure.primask;
    cpu.regs.basepri = secure.basepri;
    cpu.regs.faultmask = secure.faultmask;
    cpu.regs.control = secure.control;
    // Reset left its own low-water marks; the round trip carries this bank's.
    cpu.regs.low_msp = secure.low_msp;
    cpu.regs.low_psp = secure.low_psp;
    cpu.banked.other = non_secure;
    cpu.regs.low[0] = entry; // bit 0 clear: a Non-secure target

    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(ra8.chip.core.banked.State.non_secure, cpu.banked.current);
    try std.testing.expectEqual(entry, cpu.regs.pc);
    try std.testing.expectEqual(non_secure, running(&cpu));
    try std.testing.expectEqual(secure, cpu.banked.other);

    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(ra8.chip.core.banked.State.secure, cpu.banked.current);
    try std.testing.expectEqual(entry + 4, cpu.regs.pc);
    try std.testing.expectEqual(secure, running(&cpu));
    try std.testing.expectEqual(non_secure, cpu.banked.other);
}

test "a BXNS and SG round trip keeps each state's banked registers on CPU0 (M85)" {
    try roundTrip(Profile.m85);
}

test "a BXNS and SG round trip keeps each state's banked registers on CPU1 (M33)" {
    try roundTrip(Profile.m33);
}
