//! The responder half of the I3C channel: what happens when the firmware
//! claims its own address and waits to be addressed instead of driving the
//! bus itself.
//!
//! Nothing else on this board is a controller, so the model plays one. Each
//! synthetic cycle is a controller write the firmware drains through the
//! data buffer, then a controller read the firmware answers with its echo,
//! paced by the firmware's own polling rather than by a clock here.
//!
//! dev counted a cycle whenever the firmware pushed a byte, whether or not
//! it had taken one first, and compared that byte against a stimulus the
//! firmware had never seen. A responder that never read anything came out of
//! the run with a clean echo record.
const bus = @import("../riic/bus.zig");
const flag = @import("flags.zig");

/// The byte stream the synthetic controller writes. This model's own: the
/// value rotates per cycle so an echo is a round trip rather than a constant
/// the firmware could return by accident.
pub const stimulus = struct {
    pub const seed: u8 = 0xA5;
    pub const step: u8 = 0x11;
};

/// Where one synthetic cycle stands.
pub const Phase = enum {
    /// Nothing in flight; the next status poll starts a cycle.
    idle,
    /// The controller wrote a byte and the firmware has not taken it yet.
    written,
    /// The firmware took it and the controller is reading the echo.
    reading,
};

pub const Target = struct {
    armed: bool = false,
    own_address: u7 = 0,
    phase: Phase = .idle,
    /// The byte the synthetic controller wrote for this cycle.
    byte: u8 = 0,
    /// Write-then-read cycles the firmware completed.
    cycles: u32 = 0,
    /// An echo came back as something other than what was written.
    mismatched: bool = false,
    /// Echoes pushed with no read in flight. dev counted each one as a
    /// completed cycle and checked it against a byte nobody had read.
    unprompted: u32 = 0,
    /// Buffer reads with nothing written to take. dev handed over the last
    /// cycle's byte again.
    starved: u32 = 0,
    /// Own addresses I2C keeps for itself. A part may not answer at one.
    refused: u32 = 0,

    pub fn quiet(self: *const Target) bool {
        return self.cycles == 0 and self.unprompted == 0 and self.starved == 0 and
            self.refused == 0 and !self.mismatched;
    }

    /// The firmware programmed its own address. Zero is how it gives the
    /// address back up, which is the only way out of this role.
    pub fn open(self: *Target, msdvad: u32) void {
        const claimed = bus.wire.addressOf(@truncate(msdvad));
        if (claimed == 0) {
            self.armed = false;
            self.phase = .idle;
            return;
        }
        if (bus.reserved.holds(claimed)) {
            self.refused += 1;
            return;
        }
        self.own_address = claimed;
        self.armed = true;
        self.phase = .idle;
    }

    /// NTST while the firmware is the addressed part. An idle poll is where
    /// the next cycle begins.
    pub fn status(self: *Target) u32 {
        if (self.phase == .idle) {
            self.byte = stimulus.seed +% @as(u8, @truncate(self.cycles)) *% stimulus.step;
            self.phase = .written;
        }
        return switch (self.phase) {
            .written => flag.ntst.rdbff0,
            .reading, .idle => flag.ntst.tdbef0,
        };
    }

    /// The firmware drains the byte the controller wrote.
    pub fn receive(self: *Target) u32 {
        if (self.phase != .written) {
            self.starved += 1;
            return 0;
        }
        self.phase = .reading;
        return self.byte;
    }

    /// The firmware answers with its echo, which ends the cycle.
    pub fn transmit(self: *Target, echo: u8) void {
        if (self.phase != .reading) {
            self.unprompted += 1;
            return;
        }
        if (echo != self.byte) self.mismatched = true;
        self.cycles += 1;
        self.phase = .idle;
    }
};
