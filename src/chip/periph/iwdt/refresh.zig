//! The IWDT refresh protocol: two bytes, in order, or nothing happens.
//!
//! IWDTRR is not a value register. HUM Ch 28.2.1 p 1273 (quoted in
//! ra8-firmware `libs/ra8_hal/inc/ra8_iwdt_regs.h`) gives the counter one way
//! to reload: a write of 0x00 followed by a write of 0xFF. The header states
//! the failure outright, "A SINGLE write to IWDTRR does NOT refresh the
//! counter; both bytes are required, in order", and silicon drops anything
//! else silently: the firmware sees no error, and the next underflow resets
//! the part.
//!
//! That is exactly the kind of bug an emulator has to be able to show. A
//! register cell keeps whatever it is given, so a firmware that refreshes
//! with one write looks healthy against a plain shadow and dies on the
//! bench. The sequence is a state machine here, and priming is a fact of its
//! own rather than "the last byte happened to be zero": IWDTRR's reset value
//! is 0x00, so a reset-state compare would accept a lone 0xFF as the first
//! refresh of the run, which is the one case the header warns about.
/// The two bytes, in the order they have to arrive.
pub const byte = struct {
    pub const first: u8 = 0x00;
    pub const second: u8 = 0xFF;
};

/// What a write to IWDTRR did.
pub const Step = enum {
    /// Nothing: not part of a sequence, and any half-finished one is lost.
    ignored,
    /// The first byte landed; the counter reloads if 0xFF follows.
    primed,
    /// The pair completed and the counter reloads.
    reloaded,

    pub fn name(self: Step) []const u8 {
        return switch (self) {
            .ignored => "dropped",
            .primed => "primed",
            .reloaded => "reloaded",
        };
    }
};

/// The half-written state between the two bytes.
pub const Sequence = struct {
    primed: bool = false,

    /// Feed one byte written to IWDTRR and say what it amounted to. Anything
    /// other than the two bytes, in order, drops the sequence on the floor.
    pub fn accept(self: *Sequence, value: u8) Step {
        if (value == byte.first) {
            self.primed = true;
            return .primed;
        }
        if (value == byte.second and self.primed) {
            self.primed = false;
            return .reloaded;
        }
        self.primed = false;
        return .ignored;
    }

    /// True between the two bytes, when 0xFF would complete a refresh.
    pub fn pending(self: Sequence) bool {
        return self.primed;
    }
};
