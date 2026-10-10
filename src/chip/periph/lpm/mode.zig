//! The encodings the low-power control registers carry: LPSCR.LPMD and
//! DPSBYCR.DCSSMODE.
//!
//! Both are small fields whose defined values are listed in the HUM and whose
//! remaining values are not. Keeping the two tables here rather than inside
//! lpm.zig means the block holds bytes and counters, and the question "is this
//! a mode the chip defines?" has one answer in one place.

/// LPSCR.LPMD[3:0]: which low-power state a WFI drops the part into
/// (HUM Ch 11.2.20 p 457, with the split between the deep variants from
/// Ch 11.1 Table 11.3 p 431-432).
pub const Mode = enum(u4) {
    /// LPMD = 0. System Active: a WFI is a plain CPU sleep, peripherals run.
    /// This is also the reset state, which is what makes it the value the
    /// reset path restores.
    active = 0x0,
    software_standby = 0x5,
    deep_standby_1 = 0x8,
    deep_standby_2 = 0x9,
    deep_standby_3 = 0xA,

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .active => "sleep",
            .software_standby => "software standby",
            .deep_standby_1 => "deep software standby 1",
            .deep_standby_2 => "deep software standby 2",
            .deep_standby_3 => "deep software standby 3",
        };
    }

    /// Whether this state is entered by stopping more than the CPU. Sleep
    /// leaves the peripherals running; everything else does not.
    pub fn stopsPeripherals(self: Mode) bool {
        return self != .active;
    }
};

/// The LPMD code firmware wrote, as a mode when the HUM defines one. The
/// eleven other codes are not reserved-and-harmless, they are simply not
/// documented, so the caller is told `null` rather than handed a guess.
pub fn modeOf(code: u4) ?Mode {
    return switch (code) {
        0x0 => .active,
        0x5 => .software_standby,
        0x8 => .deep_standby_1,
        0x9 => .deep_standby_2,
        0xA => .deep_standby_3,
        else => null,
    };
}

/// DPSBYCR.DCSSMODE[1:0]: the DCDC soft-start time on the way out of deep
/// software standby (HUM Ch 11.2.21 p 458). Encoding 0 is marked "Setting
/// prohibited" there, which is why it is named rather than dropped.
pub const SoftStart = enum(u2) {
    prohibited = 0x0,
    us_128 = 0x1,
    us_256 = 0x2,
    us_512 = 0x3,

    pub fn name(self: SoftStart) []const u8 {
        return switch (self) {
            .prohibited => "prohibited",
            .us_128 => "128 us",
            .us_256 => "256 us",
            .us_512 => "512 us",
        };
    }
};

pub fn softStartOf(code: u2) SoftStart {
    return @fromBackingInt(@intCast(code));
}
