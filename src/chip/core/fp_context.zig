//! VLDR and VSTR of the floating-point system registers, decoded and applied
//! to a plain register pair (RA8EMU-342).
//!
//! The CMSE entry stub a compiler emits for a cmse_nonsecure_entry function
//! opens with `vstr FPCXTNS, [sp, #-4]!` and closes with
//! `vldr FPCXTNS, [sp], #4`. An Armv8.0-M model
//! raises an exception on both, which ends the run on the first call from the
//! Non-Secure world into the Secure one. The Zig core executes them; this
//! file knows the encoding and the effect, and nothing about the core, so
//! the semantics are tested on their own.
//!
//! Encoding T1 (DDI0553 VLDR/VSTR system register): hw1 = 1110 110 P U D W L
//! Rn, hw2 = reg[2:0] 0 1111 1 imm7. The register is D:reg, and P = 0 with
//! W = 0 is a different instruction. Decoded here: FPSCR (1), FPCXT_NS (14)
//! and FPCXT_S (15). FPSCR_nzcvqc, VPR and P0 are left to stop the run.
//!
//! The effects follow the Zig core's VMRS/VMSR of the same registers
//! (src/chip/core/cpu/ops/fp.system.zig). Two things are fixed: FPCCR.ASPEN is taken as its reset
//! value 1, so CONTROL.FPCA alone says whether a context is active, and
//! FPDSCR as its reset value 0, the FPSCR a fresh context starts with.

pub const Register = enum(u4) { fpscr = 1, fpcxt_ns = 14, fpcxt_s = 15 };

pub const width: u32 = 4;
pub const control_fpca: u32 = 1 << 2;
pub const control_sfpa: u32 = 1 << 3;
pub const default_fpscr: u32 = 0;
const context_fpscr: u32 = 0x0FFF_FFFF;

pub const Transfer = struct {
    register: Register,
    load: bool,
    pre: bool,
    add: bool,
    writeback: bool,
    base: u4,
    offset: u32,

    /// The base register after the offset is applied.
    pub fn moved(self: Transfer, rn: u32) u32 {
        return if (self.add) rn +% self.offset else rn -% self.offset;
    }

    /// The word the transfer reads or writes.
    pub fn address(self: Transfer, rn: u32) u32 {
        return if (self.pre) self.moved(rn) else rn;
    }
};

pub fn decode(hw1: u16, hw2: u16) ?Transfer {
    if (hw1 & 0xFE00 != 0xEC00) return null;
    if (hw2 & 0x1F80 != 0x0F80) return null;
    const pre = hw1 & 0x0100 != 0;
    const writeback = hw1 & 0x0020 != 0;
    if (!pre and !writeback) return null;
    const base: u4 = @truncate(hw1);
    if (base == 15) return null;
    const index: u4 = @intCast(((hw1 >> 6) & 1) << 3 | hw2 >> 13);
    const register: Register = switch (index) {
        1 => .fpscr,
        14 => .fpcxt_ns,
        15 => .fpcxt_s,
        else => return null,
    };
    return .{
        .register = register,
        .load = hw1 & 0x0010 != 0,
        .pre = pre,
        .add = hw1 & 0x0080 != 0,
        .writeback = writeback,
        .base = base,
        .offset = @as(u32, hw2 & 0x7F) * 4,
    };
}

/// The two registers the transfers read and write.
pub const State = struct {
    fpscr: u32,
    control: u32,

    fn active(self: State) bool {
        return self.control & control_fpca != 0;
    }

    fn secureContext(self: State) bool {
        return self.control & control_sfpa != 0;
    }

    fn take(self: *State, word: u32) void {
        self.control = (self.control & ~control_sfpa) | ((word >> 31) << 3);
        self.fpscr = word & context_fpscr;
    }
};

pub fn payload(sfpa: bool, fpscr: u32) u32 {
    return (@as(u32, @intFromBool(sfpa)) << 31) | (fpscr & context_fpscr);
}

/// The word a VSTR writes, applying the store's side effects to `state`.
pub fn store(register: Register, state: *State) u32 {
    switch (register) {
        .fpscr => return state.fpscr,
        .fpcxt_ns => {
            if (!state.active()) return payload(false, default_fpscr);
            const secure = state.secureContext();
            const saved = payload(secure, state.fpscr);
            if (!secure) state.fpscr = default_fpscr;
            return saved;
        },
        .fpcxt_s => {
            const saved = payload(state.secureContext(), state.fpscr);
            state.fpscr = default_fpscr;
            state.control &= ~control_sfpa;
            return saved;
        },
    }
}

/// Apply the word a VLDR read to `state`.
pub fn load(register: Register, state: *State, value: u32) void {
    switch (register) {
        .fpscr => state.fpscr = value,
        // With no FP context active the write is a NOP (DDI0553).
        .fpcxt_ns => if (state.active()) state.take(value),
        .fpcxt_s => state.take(value),
    }
}
