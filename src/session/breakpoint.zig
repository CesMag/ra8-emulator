//! The instruction address a run stops at, and which arrival to stop on.
//!
//! `--stop-sym` watches a counter in RAM, which answers "did the firmware
//! get as far as counting N of something". It cannot answer the question a
//! wall actually raises, which is whether a given function was entered at
//! all. Reading the C to decide that is guesswork, and on the SD provision
//! wall it has now been wrong twice.
//!
//! So this is the other half: an address execution stops at. The first
//! arrival is rarely the interesting one. A block read that fails does so
//! after a mount's worth of reads have already succeeded, so the question
//! is not "was the reader entered" but "what was different about the tenth
//! time", and only a count can ask that.
//!
//! The counting is done by the frontend's break hook, which the Zig
//! core's run hands each retired instruction. An earlier cut handed the
//! address to the emulator as the point to run until, which stops on the
//! first arrival and cannot be resumed past: restarting a run AT the
//! address it is told to stop before either spins or steps over the very
//! instruction being counted.
//!
//! The interesting verdict is still the negative one. A run that ends
//! having arrived fewer times than asked reports how many it did see,
//! which is evidence a command trace cannot give: a function that issues
//! no bus access leaves no trace either way.
//!
//! Where to stop is named the same way `--dump-mem` names where to read,
//! so a break is not limited to a function's own first instruction. That
//! matters for a value a function RETURNS: the only place a return value
//! is still in r0 is the instruction after the call, which has no symbol
//! of its own and is reached as `caller+offset`.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const place = @import("place.zig");
const symbols = @import("symbols.zig");

/// How the address is compared, and what an unset count means.
pub const limits = struct {
    /// The Thumb interworking bit. A symbol may carry it and a program
    /// counter may carry it; neither says anything about which address
    /// was meant, so it is cleared on both sides of the comparison.
    pub const thumb_bit: u32 = 1;
    /// Which arrival a break with no count given stops on.
    pub const first_arrival: u32 = 1;
    /// What a run with no break asks to run until: an address no image
    /// reaches, so the emulator stops on the instruction count alone.
    pub const unreachable_address: u64 = 0xFFFF_FFFF;
};

pub const Break = struct {
    /// Where to stop, resolved from the image's symbol table before the
    /// run starts.
    address: u32,
    /// Which arrival ends the run. One is the first.
    arrival: u32 = limits.first_arrival,
    /// How many times execution has reached the address so far. Kept past
    /// the stop so a run that never got there can say how close it came.
    seen: u32 = 0,
    /// Set when the wanted arrival happened. This is what tells the report
    /// the run ended at the break rather than spending its budget.
    reached: bool = false,

    /// Count one arrival, and say whether this is the one that ends the run.
    ///
    /// Called from the hook on the break's own instruction. Stopping is a
    /// one-way latch: arrivals past the wanted one keep counting, but they
    /// cannot un-reach a break that was already met.
    pub fn count(self: *Break) bool {
        self.seen += 1;
        if (self.seen < self.arrival) return false;
        self.reached = true;
        return self.seen == self.arrival;
    }

    /// The address the hook watches, as the emulator numbers instructions.
    pub fn watchedAddress(self: Break) u64 {
        return @as(u64, entry(self.address));
    }
};

/// An address with the interworking bit cleared.
fn entry(address: u32) u32 {
    return address & ~limits.thumb_bit;
}

/// Where a break named on the command line actually is.
///
/// A place may name a symbol, a literal address, or either with an offset
/// applied. It may not dereference: a break is resolved before the run
/// starts, when there is no memory to read a pointer out of.
pub fn resolve(image: elf.Image, spec: []const u8, arrival: u32) !Break {
    const want = try place.parse(spec);
    if (want.deref) return error.NoDerefInBreak;
    var base = want.address;
    if (want.name) |name| base = symbols.addressOf(image, name) orelse return error.Unresolved;
    return .{ .address = want.apply(base), .arrival = arrival };
}
