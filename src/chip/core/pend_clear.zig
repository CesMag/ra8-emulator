//! Which firmware stores wipe a PendSV pend that was still standing.
//!
//! WHY THIS EXISTS. src/chip/periph/standing.zig counts the chunk boundaries that
//! find `ICSR.PENDSVSET` up. On `wdt_supervisor_demo` over 200 modelled ms it
//! reads 18 boundaries against 376 stores that landed on a bit already
//! standing, longest unbroken run two. So the bit is not sitting up being
//! declined by the controller: it is GONE by the time the loop looks, and the
//! question is who takes it down.
//!
//! Three writers can. The controller clears it on entry, which is the
//! architecture and is counted as an entry already. The model's own
//! read-modify-writes of the register (the SysTick pend in
//! src/chip/periph/clocks.zig, `clearPending` in src/chip/periph/nvic/nvic.zig) go through
//! the model and so cannot be seen from a store hook at all. And the
//! FIRMWARE can, because against a plain-RAM PPB a store of a whole word is
//! just a store: on silicon `PENDSVSET` is write-one-to-set and a zero in
//! that lane does nothing, while here it overwrites the bit.
//!
//! That last one is invisible today and is the only one a hook can settle, so
//! this counts it. A zero here says the losses are the model's own writes and
//! the next place to look is the engine side; a number near the 368 missing
//! says the write-one-to-set lane is the hole.
const std = @import("std");

/// Stores that took a standing PendSV pend down.
pub const Cleared = struct {
    /// Stores into ICSR that found the bit up and did not carry it along.
    count: usize = 0,
    /// Of those, the ones made while an exception was executing.
    in_handler: usize = 0,
    /// The address of the first one, and whether one has been seen.
    first_at: u32 = 0,
    placed: bool = false,
    /// How many of the rest came from a different address.
    elsewhere: usize = 0,
    /// Stores that asked for the clear the way the architecture does, with
    /// `PENDSVCLR` rather than by writing a word with the lane at zero.
    ///
    /// Worth telling apart: a firmware using the clear bit means to unpend
    /// and the model should honour it, while a word store that happens to
    /// carry a zero there means nothing of the kind and is the bug.
    asked: usize = 0,

    /// Called from the hook: a store at `pc` wiped a standing pend.
    /// `executing` is the IPSR at the store, zero in Thread mode, and
    /// `with_clear_bit` says the store named PENDSVCLR.
    pub fn record(self: *Cleared, pc: u32, executing: u16, with_clear_bit: bool) void {
        self.count +%= 1;
        if (executing != 0) self.in_handler +%= 1;
        if (with_clear_bit) self.asked +%= 1;
        if (!self.placed) {
            self.placed = true;
            self.first_at = pc;
            return;
        }
        if (pc != self.first_at) self.elsewhere +%= 1;
    }

    /// Nothing to say: no store ever took a standing pend down.
    pub fn quiet(self: Cleared) bool {
        return self.count == 0;
    }

    /// Stores that wiped the bit without ever asking to.
    pub fn silent(self: Cleared) usize {
        return self.count -| self.asked;
    }
};
