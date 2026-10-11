//! The maximum core clock of each core on each part, cited.
//!
//! Both datasheets' function-comparison tables give the same rows for the
//! dual-core parts the emulator models: CPU0 (Cortex-M85) 1 GHz max and
//! CPU1 (Cortex-M33) 250 MHz max. RA8D2 R01DS0493EJ0130 Table 1.14 p 11,
//! RA8P1 R01DS0439EJ0130 Table 1.15 p 11. These are ceilings, not the rate
//! a run's clock setup picks; per-core time accounting divides down from
//! them once the clock tree (SCKDIVCR/SCKDIVCR2) is modelled per part.

const Part = @import("part.zig").Part;

pub const Core = enum { cpu0, cpu1 };

pub const Clocks = struct {
    cpu0_max_hz: u32,
    cpu1_max_hz: u32,
    /// Where the ceilings come from.
    source: []const u8,

    pub fn maxHz(self: Clocks, core: Core) u32 {
        return switch (core) {
            .cpu0 => self.cpu0_max_hz,
            .cpu1 => self.cpu1_max_hz,
        };
    }
};

const cpu0_max_hz: u32 = 1_000_000_000;
const cpu1_max_hz: u32 = 250_000_000;

/// The core clock ceilings of `part`.
pub fn of(part: Part) Clocks {
    return switch (part) {
        .ra8d2 => .{
            .cpu0_max_hz = cpu0_max_hz,
            .cpu1_max_hz = cpu1_max_hz,
            .source = "RA8D2 DS R01DS0493EJ0130 Table 1.14 p 11",
        },
        .ra8p1 => .{
            .cpu0_max_hz = cpu0_max_hz,
            .cpu1_max_hz = cpu1_max_hz,
            .source = "RA8P1 DS R01DS0439EJ0130 Table 1.15 p 11",
        },
    };
}
