//! MRCPS and the code-MRAM program-control page: what it answers, and what
//! it refuses.
//!
//! The code-MRAM program path does not go through the MACI sequencer at all.
//! The driver opens the per-world program gate on this page, stores the
//! bytes straight into the mapped MRAM window, and then polls MRCPS for
//! buffer-ready and commit-done. The machine's own memory serves those
//! stores, so the only thing this page has to get right is the word the
//! driver polls.
//!
//! MRCPS reads idle-and-ready, carried from board_periph_mram.c on dev
//! unchanged and for dev's stated reason: the mapped MRAM window already
//! takes the stores the program path makes, so a status word reporting busy
//! would hold a DFU image at a poll with nothing left to wait for.
//!
//! THE STATUS WORD IS THE CONTROLLER'S. What this model does not carry is
//! dev's treatment of a store to it. dev keeps the whole page in one shadow
//! array and files any store anywhere in it, MRCPS included, while the read
//! of MRCPS answers the ready constant regardless. So a driver that writes
//! MRCPS, to clear an error bit or force a state, is told nothing: the store
//! is kept, the read-back shows a value the store never set, and the run
//! reports none of it. On silicon MRCPS is status the controller writes.
//! Here a store to it is refused and counted, the way this tree already
//! treats MSTATR, MASTAT, CETCR, SRAMESR and INTS. Every other word on the
//! page is the program gate and stays a shadow, because a gate is exactly
//! what firmware writes and reads back.
//!
//! NOT MODELLED, AND NOT GUESSED: which bits of which word open that gate.
//! MRCPC0, MRCPC1 and MRCFLR are named in dev's header and given an offset
//! in neither tree, so the gate is shadowed rather than judged, and nothing
//! here decides whether a program was allowed to happen. MRCPS reports ready
//! whether or not a gate was ever opened.

/// The R_MRMS 0x3000 page: the code-MRAM program-control window.
pub const page = struct {
    pub const base: u32 = 0x4013_F000;
    pub const span: u32 = 0x100;
    /// MRCPS: Code MRAM Program Status.
    pub const off_mrcps: u32 = 0x10;
    /// ABUFEMP set; PRGBSYC, ABUFFULL and the error bits clear.
    pub const ready: u32 = 0x20;
};

const words: usize = page.span / 4;

pub const Page = struct {
    /// The gate words, which firmware writes and reads back.
    shadow: [words]u32 = @splat(0),
    /// Stores to MRCPS: the controller owns that word, firmware does not.
    refused: u32 = 0,

    pub fn quiet(self: *const Page) bool {
        return self.refused == 0;
    }

    pub fn read(self: *const Page, address: u32, width: u3) u32 {
        const at = address -% page.base;
        if (at >= page.span) return 0;
        if (names_mrcps(at)) return part_of(page.ready, at % 4, width);
        return part_of(self.shadow[at / 4], at % 4, width);
    }

    pub fn write(self: *Page, address: u32, width: u3, value: u32) void {
        const at = address -% page.base;
        if (at >= page.span) return;
        if (names_mrcps(at)) {
            self.refused +%= 1;
            return;
        }
        const word = at / 4;
        self.shadow[word] = merge(self.shadow[word], at % 4, width, value);
    }
};

/// Whether an access lands anywhere in the MRCPS word, including a byte or
/// halfword naming only part of it.
fn names_mrcps(at: u32) bool {
    return at & ~@as(u32, 3) == page.off_mrcps;
}

fn width_mask(width: u3) u32 {
    return switch (width) {
        1 => 0xFF,
        2 => 0xFFFF,
        else => 0xFFFF_FFFF,
    };
}

/// The part of a 32-bit register a narrow access names.
fn part_of(value: u32, byte_offset: u32, width: u3) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    return (value >> shift) & width_mask(width);
}

/// Fold a narrow write into a 32-bit register, leaving the bytes the access
/// does not name where they were.
fn merge(current: u32, byte_offset: u32, width: u3, value: u32) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    const bits = width_mask(width);
    const slot: u32 = bits << shift;
    return (current & ~slot) | ((value & bits) << shift);
}
