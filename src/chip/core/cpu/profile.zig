//! Which instruction groups a core implements (RA8EMU-233).
//!
//! One Zig core, two configurations. CPU0 is a Cortex-M85: Armv8.1-M with
//! MVE and the low-overhead branches. CPU1 is a Cortex-M33: Armv8.0-M
//! Mainline with DSP and FPv5-SP only, so an Armv8.1-M encoding there is
//! UNDEFINED and takes UsageFault UNDEFINSTR, as it would on silicon.
//! src/chip/core/part/part.zig picks the profile for each CPU.

/// What a decode group needs from the core before it may claim an encoding.
pub const Feature = enum {
    /// Armv8-M Mainline with DSP and the FP extension: both cores.
    base,
    /// The Armv8.1-M Mainline additions outside MVE and LOB: CSEL and its
    /// family, CLRM, VSCCLRM.
    v8_1m,
    /// The M-profile Vector Extension, and the scalar long shifts that come
    /// with it (ASRL, LSLL, LSRL, UQSHLL, ...).
    mve,
    /// The low-overhead loop and branch instructions: WLS, DLS, LE, LCTP.
    lob,
};

pub const Profile = struct {
    v8_1m: bool,
    mve: bool,
    lob: bool,

    /// Cortex-M85: everything the decode table has.
    pub const m85: Profile = .{ .v8_1m = true, .mve = true, .lob = true };
    /// Cortex-M33: Armv8.0-M Mainline, DSP, FPv5-SP.
    pub const m33: Profile = .{ .v8_1m = false, .mve = false, .lob = false };

    pub fn has(self: Profile, feature: Feature) bool {
        return switch (feature) {
            .base => true,
            .v8_1m => self.v8_1m,
            .mve => self.mve,
            .lob => self.lob,
        };
    }
};
