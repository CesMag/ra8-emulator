//! Which part a run models.
//!
//! The RA8P1 and the RA8D2 share a register map and a memory map, so one set
//! of peripheral models serves both and an RA8P1-linked ELF boots exactly as
//! an RA8D2 one does. The one difference is that the RA8P1 carries an Arm
//! Ethos-U55 micro-NPU and the RA8D2 does not, so the choice of part decides
//! whether the NPU window answers at all. Everything else on the board is
//! identical, which is why this is an enum; the memory geometry, cited per
//! part, is in src/chip/core/part/map.zig.
const std = @import("std");

const profile = @import("../cpu/profile.zig");
pub const map = @import("map.zig");
pub const clock = @import("clock.zig");

/// SysTick timers on CPU0, the Cortex-M85 both parts carry: two, one Secure
/// and one Non-secure. Arm's Cortex-M85 Devices Generic User Guide (101928,
/// issue 0101), "System timer, SysTick": "There are two 24-bit system
/// timers, a Non-secure SysTick timer and a Secure SysTick timer." The RA8P1
/// (R01DS0439EJ0130) and RA8D2 (R01DS0493EJ0130) datasheets, Rev.1.30 p2,
/// say the same: "Embeds two Systick timers: Secure and Non-secure
/// instance". With two, SHPR3.PRI_15 and SHCSR.SYSTICKACT are banked
/// (src/chip/periph/scb_bank.zig).
pub const cpu0_systicks: u2 = 2;

/// SysTick timers on CPU1, the Cortex-M33: also two. A Cortex-M33 has two
/// only with the Security Extension (Arm 100235, issue 0100), and both
/// datasheets above list it for CPU1, Rev.1.30 p2: "Armv8-M Security
/// Extension" and "Embeds two Systick timers: Secure instance (SysTick_S)
/// and Non-secure instance (SysTick_NS)".
pub const cpu1_systicks: u2 = 2;

/// The instruction set each CPU decodes on the Zig core (RA8EMU-233): CPU0
/// is the Cortex-M85 (Armv8.1-M, MVE, LOB), CPU1 the Cortex-M33 (Armv8.0-M
/// Mainline, DSP, FPv5-SP), on both parts.
pub const cpu0_profile = profile.Profile.m85;
pub const cpu1_profile = profile.Profile.m33;

pub const Part = enum {
    ra8d2,
    ra8p1,

    /// The part named on the command line, or null for a name this emulator
    /// does not model. Nothing is guessed: an unknown name is refused rather
    /// than quietly falling back to the default part.
    pub fn parse(text: []const u8) ?Part {
        if (std.mem.eql(u8, text, "ra8d2")) return .ra8d2;
        if (std.mem.eql(u8, text, "ra8p1")) return .ra8p1;
        return null;
    }

    pub fn label(self: Part) []const u8 {
        return switch (self) {
            .ra8d2 => "RA8D2",
            .ra8p1 => "RA8P1",
        };
    }

    /// Whether this part has the Ethos-U55 NPU behind 0x4014_0000.
    pub fn hasNpu(self: Part) bool {
        return self == .ra8p1;
    }
};
