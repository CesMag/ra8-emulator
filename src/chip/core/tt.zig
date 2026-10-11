//! TT, TTT, TTA and TTAT: the answer the firmware's own SAU gives.
//!
//! The CPU model runs these instructions against its own SAU, which nothing
//! programs: the board keeps the SAU the firmware writes in
//! src/chip/periph/sau/sau.zig, and the PPB the registers live in is plain RAM to the
//! CPU model. So its TT said every address was Secure, and
//! cmse_check_address_range refused every Non-secure buffer a veneer was
//! handed. This file builds the response word from the board's map instead;
//! The Zig core's TT executor (src/chip/core/cpu/ops/tt.zig) and its SAU
//! source answer from it.
//!
//! THE MPU HALF IS THE DISABLED-MPU ANSWER: MRVALID clear, R and RW set. The
//! CPU model's MPU was never programmed either (the board keeps the table
//! the firmware writes), so that is what its TT gave too. Taking
//! R and RW from the board's MPU table is a later slice.
const sau = @import("../periph/sau/sau.zig");
const sau_attr = @import("../periph/sau/attribution.zig");

/// Both halfwords, so the PC moves past it in one step.
pub const width: u32 = 4;

/// One decoded TT. `alternate` is the A bit (TTA, TTAT), `unprivileged` the
/// T bit (TTT, TTAT).
pub const Form = struct {
    rn: u4,
    rd: u4,
    alternate: bool,
    unprivileged: bool,
};

/// The TT_RESP bits, Armv8-M ARM D1.2.
pub const field = struct {
    pub const sregion_shift: u5 = 8;
    pub const srvalid: u32 = 1 << 17;
    pub const r: u32 = 1 << 18;
    pub const rw: u32 = 1 << 19;
    pub const nsr: u32 = 1 << 20;
    pub const nsrw: u32 = 1 << 21;
    pub const s: u32 = 1 << 22;
    pub const irvalid: u32 = 1 << 23;
    pub const iregion_shift: u5 = 24;
};

/// T1: 1110 1000 0100 Rn | 1111 Rd A T 00 0000. Rn = PC and Rd = SP or PC
/// are UNPREDICTABLE and left to the CPU model.
pub fn decode(first: u16, second: u16) ?Form {
    if (first & 0xFFF0 != 0xE840) return null;
    if (second & 0xF03F != 0xF000) return null;
    const rn: u4 = @truncate(first);
    const rd: u4 = @truncate(second >> 8);
    if (rn == 15 or rd == 13 or rd == 15) return null;
    return .{
        .rn = rn,
        .rd = rd,
        .alternate = second & 0x80 != 0,
        .unprivileged = second & 0x40 != 0,
    };
}

/// Whether the instruction at `pc` runs in the Secure state. Code runs in
/// the state its memory is attributed to; a fetch from Secure memory in the
/// Non-secure state faults, so a TT that executes at all tells this way.
pub fn executingSecure(unit: *const sau.Sau, pc: u32) bool {
    return sau_attr.attribute(unit, .{}, pc).state != .non_secure;
}

/// The response word for `target`. From the Non-secure state only the MPU
/// half is reported; the security half reads as zero.
pub fn respond(unit: *const sau.Sau, target: u32, secure: bool) u32 {
    return respondWith(unit, .{}, target, secure);
}

/// As `respond`, with the IDAU's answer for `target` (RA8EMU-277).
pub fn respondWith(unit: *const sau.Sau, idau: sau_attr.Idau, target: u32, secure: bool) u32 {
    var word: u32 = field.r | field.rw;
    if (!secure) return word;
    const answer = sau_attr.attribute(unit, idau, target);
    if (answer.region) |region| {
        word |= field.srvalid | @as(u32, region) << field.sregion_shift;
    }
    if (answer.idau_region) |region| {
        word |= field.irvalid | @as(u32, region) << field.iregion_shift;
    }
    if (answer.state == .non_secure) {
        word |= field.nsr | field.nsrw;
    } else {
        word |= field.s;
    }
    return word;
}
