//! Tail-predicated low-overhead loops (RA8EMU-236): DLSTP, WLSTP, LETP and
//! LCTP. The arithmetic lives in mve/tail.zig; this group decodes the four
//! and applies it to LR, PC and FPSCR.LTPSIZE. Each runs ExecuteFPCheck()
//! through fp_gate, as the Arm ARM asks.
//!
//! The non-predicated DLS, WLS and LE stay with ops/lob.zig, whose decode
//! refuses every form claimed here. Refused here as well: SP or PC as the
//! count register (PC is a related encoding: LCTP, LE or LE forever).
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const lob = @import("../../../lob.zig");
const tail = @import("../../mve/all.zig").tail;

pub const encodings = struct {
    /// DLSTP, WLSTP and VCTP share 0xF0sn: s the element size, n Rn.
    pub const setup_mask: u16 = 0xFFC0;
    pub const setup: u16 = 0xF000;
    pub const size_shift: u4 = 4;
    pub const rn_mask: u16 = 0x000F;
    pub const dlstp_second: u16 = 0xE001;
    /// WLSTP and LETP carry a branch: 0b1100 xxxx xxxx xxx1.
    pub const branch_mask: u16 = 0xF001;
    pub const branch: u16 = 0xC001;
    pub const letp_first: u16 = 0xF01F;
    pub const lctp_first: u16 = 0xF00F;
    pub const lctp_second: u16 = 0xE001;
    pub const sp: u4 = 13;
    pub const pc: u4 = 15;
};

pub const Kind = enum { dlstp, wlstp, letp, lctp };

pub const Fields = struct {
    kind: Kind,
    size: u2 = 0,
    rn: u4 = 0,
    /// Branch distance in bytes: forward for WLSTP, backward for LETP.
    offset: u32 = 0,
};

pub const group: op.Group = .{ .name = "mve_lob_tp", .decode = decode, .oracle = false };

fn distance(hw2: u16) u32 {
    const e = lob.encoding;
    const halfwords: u32 = (hw2 & e.distance_mask) | ((hw2 >> e.distance_lsb) & 1);
    return halfwords * 2;
}

/// The decoded instruction, or null when this group does not claim it.
pub fn fields(instr: Instr) ?Fields {
    const e = encodings;
    if (instr.size != 4) return null;
    const hw1 = instr.hw1;
    const hw2 = instr.hw2;
    if (hw1 == e.letp_first and hw2 & e.branch_mask == e.branch)
        return .{ .kind = .letp, .offset = distance(hw2) };
    if (hw1 == e.lctp_first and hw2 == e.lctp_second) return .{ .kind = .lctp };
    if (hw1 & e.setup_mask != e.setup) return null;
    const rn: u4 = @truncate(hw1 & e.rn_mask);
    if (rn == e.sp or rn == e.pc) return null;
    const size: u2 = @truncate(hw1 >> e.size_shift);
    if (hw2 == e.dlstp_second) return .{ .kind = .dlstp, .size = size, .rn = rn };
    if (hw2 & e.branch_mask == e.branch)
        return .{ .kind = .wlstp, .size = size, .rn = rn, .offset = distance(hw2) };
    return null;
}

fn decode(instr: Instr) ?op.Exec {
    _ = fields(instr) orelse return null;
    return exec;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    const after = instr.address +% 4;
    const fpscr = &cpu.fp.fpscr;
    switch (f.kind) {
        .dlstp, .wlstp => {
            const s = tail.start(f.size, cpu.regs.get(f.rn), f.kind == .wlstp, cpu.regs.lr, fpscr.ltpsize);
            cpu.regs.lr = s.lr;
            fpscr.ltpsize = s.ltpsize;
            cpu.regs.pc = if (s.enter) after else after +% f.offset;
        },
        .letp => {
            const e = tail.end(cpu.regs.lr, fpscr.ltpsize);
            cpu.regs.lr = e.lr;
            fpscr.ltpsize = e.ltpsize;
            cpu.regs.pc = if (e.again) after -% f.offset else after;
        },
        .lctp => {
            fpscr.ltpsize = tail.none;
            cpu.regs.pc = after;
        },
    }
}
