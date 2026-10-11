//! Stepping out of a handler: from an EXC_RETURN back to the code the
//! exception interrupted.
//!
//! Entry stacked r0-r3, r12, lr, the interrupted pc and xPSR, eight words,
//! on whichever stack that code was using; EXC_RETURN says which, and how
//! big the frame was (DDI0553 B3.19):
//!
//!   [2] SPSEL  1 = the frame is on the Process stack, 0 = the Main stack
//!   [4] FTYPE  0 = s0-s15, FPSCR and one more word follow (18 words)
//!   [5] DCRS   0 = r4-r11 and the integrity signature sit below (10 words)
//!
//! xPSR bit 9 records the four bytes of padding entry added to align the
//! frame, so the interrupted sp is past the frame plus that pad. A handler
//! always runs on the Main stack, so a Main-stack frame starts at the CFA
//! the handler's own row gave; a Process-stack frame starts at PSP.
const std = @import("std");

pub const field = struct {
    pub const spsel: u32 = 1 << 2;
    pub const ftype: u32 = 1 << 4;
    pub const dcrs: u32 = 1 << 5;
};

pub const bytes = struct {
    pub const basic: u32 = 8 * 4;
    pub const extended: u32 = 26 * 4;
    pub const callee: u32 = 10 * 4;
    pub const pad: u32 = 4;
};

/// Bit 9 of the stacked xPSR: entry padded the frame by four bytes.
pub const xpsr_pad: u32 = 1 << 9;

/// Where each stacked word goes, by DWARF register number.
const slots = [_]usize{ 0, 1, 2, 3, 12, 14, 15 };

/// The interrupted code's registers. `registers` are the handler's caller
/// row with sp at the CFA; r4-r11 it already holds stay as they are.
pub fn interrupted(exc_return: u32, registers: [16]u32, psp: u32, memory: anytype) ![16]u32 {
    var frame = if (exc_return & field.spsel != 0) psp else registers[13];
    if (exc_return & field.dcrs == 0) frame +%= bytes.callee;
    var next = registers;
    for (slots, 0..) |register, index| {
        next[register] = try memory.readWord(frame +% @as(u32, @intCast(index * 4)));
    }
    const xpsr = try memory.readWord(frame +% 28);
    var size = if (exc_return & field.ftype == 0) bytes.extended else bytes.basic;
    if (xpsr & xpsr_pad != 0) size += bytes.pad;
    next[13] = frame +% size;
    next[15] &= ~@as(u32, 1);
    return next;
}
