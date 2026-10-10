//! The R-Switch mode machine shared by ETHA and GWCA. Both agents reset
//! into DISABLE and follow the transition graphs in HUM chapters 32.4.1.1
//! and 34.4.1.1. This records accepted transitions immediately; timing and
//! transition prerequisites are handled by the peripherals that own them.
//!
//! OPERATION also steps straight back to CONFIG: ra8_eth_gwca_default_open
//! brings GWCA up to OPERATION and then asks for CONFIG without passing
//! DISABLE, and eth_open_probe passes that path on the EK-RA8D2 bench.
const std = @import("std");

pub const Mode = enum(u2) {
    reset = 0,
    disable = 1,
    config = 2,
    operation = 3,
};

/// Whether the request follows the ETHA/GWCA transition graph in the manual.
pub fn reachable(from: Mode, to: Mode) bool {
    if (from == to) return true;
    return switch (from) {
        .reset => to == .disable,
        .disable => to == .reset or to == .config or to == .operation,
        .config => to == .disable or to == .operation,
        .operation => to == .disable or to == .config,
    };
}

/// One mode machine: what it was commanded, where it is, and the steps it
/// would not take.
pub const Machine = struct {
    mode: Mode = .disable,
    /// Mode commands the firmware wrote.
    commands: u32 = 0,
    /// Commands that moved the machine.
    changes: u32 = 0,
    /// Commands refused because the step does not exist.
    refused: u32 = 0,
    /// The mode the last refused command asked for.
    last_refused: ?Mode = null,

    pub fn command(self: *Machine, value: u32) void {
        self.commands += 1;
        const wanted: Mode = @fromBackingInt(@intCast(@as(u2, @truncate(value))));
        if (!reachable(self.mode, wanted)) {
            self.refused += 1;
            self.last_refused = wanted;
            return;
        }
        if (wanted != self.mode) self.changes += 1;
        self.mode = wanted;
    }

    /// What the status register reports: where the machine actually is, not
    /// what it was last asked for.
    pub fn status(self: *const Machine) u32 {
        return @backingInt(self.mode);
    }

    pub fn operational(self: *const Machine) bool {
        return self.mode == .operation;
    }

    pub fn quiet(self: *const Machine) bool {
        return self.commands == 0;
    }
};
