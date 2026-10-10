//! Covers src/chip/periph/cpuid.zig: each core names its own processor, and the
//! word a core is primed with is the one it reads back.
const std = @import("std");
const ra8 = @import("ra8");

const cpuid = ra8.chip.periph.cpuid;

/// One core's CPUID word, standing in for its PPB.
const Ppb = struct {
    word: u32 = 0,

    pub fn writeWord(self: *Ppb, address: u32, value: u32) !void {
        try std.testing.expectEqual(cpuid.address, address);
        self.word = value;
    }
};

test "CPU0 reports a Cortex-M85 and CPU1 a Cortex-M33" {
    try std.testing.expectEqual(cpuid.partno.cortex_m85, cpuid.part(cpuid.cpu0));
    try std.testing.expectEqual(cpuid.partno.cortex_m33, cpuid.part(cpuid.cpu1));
}

test "both words carry Arm's implementer and the Armv8-M scheme at r0p0" {
    try std.testing.expectEqual(@as(u32, 0x410F_D230), cpuid.cpu0);
    try std.testing.expectEqual(@as(u32, 0x410F_D210), cpuid.cpu1);
}

test "each core reads the word it was primed with, not the other's" {
    var cpu0 = Ppb{};
    var cpu1 = Ppb{};
    try cpuid.prime(&cpu0, cpuid.cpu0);
    try cpuid.prime(&cpu1, cpuid.cpu1);
    try std.testing.expectEqual(cpuid.cpu0, cpu0.word);
    try std.testing.expectEqual(cpuid.cpu1, cpu1.word);
}

test "a primed word is never zero, which names no processor" {
    try std.testing.expect(cpuid.cpu0 != 0);
    try std.testing.expect(cpuid.cpu1 != 0);
}
