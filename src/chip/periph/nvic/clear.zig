//! Folding the write-to-clear halves of the interrupt controller by hand.
//!
//! Its own file rather than a tail on src/chip/periph/nvic/nvic.zig for the reason
//! AGENTS.md gives: nvic.zig had reached the gate's 400 lines, and undoing a
//! clear-register write is one job with one shape, nothing to do with
//! picking or entering an exception.
const memmap = @import("../../core/memmap.zig");

/// ICSR's four pend and unpend bits, handed in rather than imported, so this
/// file does not have to import the module that imports it.
pub const Bits = struct {
    pendstclr: u32,
    pendstset: u32,
    pendsvclr: u32,
    pendsvset: u32,
};

/// The clear-side registers only work on hardware because the NVIC sees the
/// write. Against a plain-RAM PPB the word just sits there, so the fold is
/// done here instead: whatever the firmware put in ICER is removed from ISER,
/// whatever it put in ICPR is removed from ISPR, and the clear register is
/// emptied. A firmware that disables a line therefore stops seeing it from
/// the next chunk boundary, which is the same seam everything else moves on.
///
/// The one behaviour this cannot give back is the read side: on hardware ICER
/// reads as the enable state, here it reads as zero.
/// Both halves: the IRQ lines' clear registers, then ICSR's.
pub fn registers(core: anytype, irq_words: u16, bits: Bits) !void {
    try lines(core, irq_words);
    try pends(core, bits);
}

/// ICER into ISER and ICPR into ISPR, word by word.
pub fn lines(core: anytype, irq_words: u16) !void {
    var word: u16 = 0;
    while (word < irq_words) : (word += 1) {
        const offset = 4 * @as(u32, word);
        try fold(core, memmap.nvic.icer + offset, memmap.nvic.iser + offset);
        try fold(core, memmap.nvic.icpr + offset, memmap.nvic.ispr + offset);
    }
}

/// ICSR's PENDSTCLR and PENDSVCLR into their set bits.
pub fn pends(core: anytype, bits: Bits) !void {
    const icsr = try core.readWord(memmap.scb.icsr);
    var next = icsr;
    if (icsr & bits.pendstclr != 0) next &= ~(bits.pendstclr | bits.pendstset);
    if (icsr & bits.pendsvclr != 0) next &= ~(bits.pendsvclr | bits.pendsvset);
    if (next != icsr) try core.writeWord(memmap.scb.icsr, next);
}

fn fold(core: anytype, clear_register: u32, set_register: u32) !void {
    const clear = try core.readWord(clear_register);
    if (clear == 0) return;
    try core.writeWord(set_register, (try core.readWord(set_register)) & ~clear);
    try core.writeWord(clear_register, 0);
}
