//! What each byte of a ULPT channel belongs to.
//!
//! The channel window is not one width. ULPTCNT, ULPTCMA and ULPTCMB are
//! 32-bit and sit one after another, and then ULPTCR, ULPTMR1, ULPTMR2 and
//! ULPTMR3 are four single-byte registers SHARING THE WORD AT +0x0C. So an
//! access here can name part of one register (the high half of a 32-bit
//! reload) or several whole registers at once (a halfword store that starts
//! the channel and selects its count source), and the answer has to be
//! assembled a byte at a time.
//!
//! This file is only the map: which register owns a byte offset inside a
//! channel, and which byte of that register it is. The byte arithmetic is
//! `src/chip/periph/bytelanes.zig`, and what each register MEANS stays in
//! `src/chip/periph/ulpt/ulpt.zig`.

/// The registers a channel answers for.
pub const Reg = enum { cnt, cma, cmb, cr, mr1, mr2, mr3, ioc };

/// A byte offset resolved: the register it belongs to, and which byte of that
/// register it is. `index` is 0 for the low byte.
pub const Place = struct {
    reg: Reg,
    index: u32,
};

/// Register offsets inside a channel (ra8_ulpt_regs.h; HUM Ch 25.1 p 1187).
pub const at = struct {
    pub const cnt: u32 = 0x00;
    pub const cma: u32 = 0x04;
    pub const cmb: u32 = 0x08;
    pub const cr: u32 = 0x0C;
    pub const mr1: u32 = 0x0D;
    pub const mr2: u32 = 0x0E;
    pub const mr3: u32 = 0x0F;
    pub const ioc: u32 = 0x10;
};

const bytes = struct {
    const wide: u32 = 4;
    const narrow: u32 = 1;
};

/// Which register owns `offset` bytes into the channel, or null when nothing
/// does: everything past ULPTIOC reads zero and holds nothing.
pub fn owner(offset: u32) ?Place {
    if (within(offset, at.cnt, bytes.wide)) |index| return .{ .reg = .cnt, .index = index };
    if (within(offset, at.cma, bytes.wide)) |index| return .{ .reg = .cma, .index = index };
    if (within(offset, at.cmb, bytes.wide)) |index| return .{ .reg = .cmb, .index = index };
    if (within(offset, at.cr, bytes.narrow)) |index| return .{ .reg = .cr, .index = index };
    if (within(offset, at.mr1, bytes.narrow)) |index| return .{ .reg = .mr1, .index = index };
    if (within(offset, at.mr2, bytes.narrow)) |index| return .{ .reg = .mr2, .index = index };
    if (within(offset, at.mr3, bytes.narrow)) |index| return .{ .reg = .mr3, .index = index };
    if (within(offset, at.ioc, bytes.narrow)) |index| return .{ .reg = .ioc, .index = index };
    return null;
}

/// Whether a register is one of the two compare values. The pair counts the
/// accesses that reach it, and an access is one touch however many of its
/// bytes land there.
pub fn isCompare(reg: Reg) bool {
    return reg == .cma or reg == .cmb;
}

fn within(offset: u32, base: u32, width: u32) ?u32 {
    if (offset < base or offset >= base + width) return null;
    return offset - base;
}
