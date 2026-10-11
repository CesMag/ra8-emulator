//! MVE VMOV between two 32-bit lanes and two general-purpose registers
//! (RA8EMU-25): VMOV Qd[2+i], Qd[i], Rt, Rt2 and VMOV Rt, Rt2, Qd[2+i],
//! Qd[i]. Per LLVM's assembler the encoding is hw1 1110 1100 000 op Rt2
//! (op set moves into the vector) and hw2 Qd 0 1111 000 i Rt. Rt pairs with
//! lane 2+i and Rt2 with lane i. Following QEMU's trans_VMOV_to_2gp and
//! trans_VMOV_from_2gp, neither form is predicated or advances a VPT block.
//! They are beat-wise: a lane in a beat EPSR.ECI marks done is not moved,
//! and ECI moves on after.
//! Rt or Rt2 of 13 or 15, and the same register twice when reading into
//! the core, are UNPREDICTABLE and left unclaimed.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");

pub const group: op.Group = .{ .name = "mve_lane_pair", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// The direction bit (4) and Rt2 masked out.
    pub const hw1_mask: u16 = 0xFFE0;
    pub const hw1: u16 = 0xEC00;
    /// Qd, the index bit (4) and Rt masked out.
    pub const hw2_mask: u16 = 0x1FE0;
    pub const hw2: u16 = 0x0F00;
};

/// The operands an encoding names: Rt pairs with lane 2+i, Rt2 with lane i.
pub const Fields = struct { qd: u3, high: u8, low: u8, rt: u4, rt2: u4, to_vector: bool };

pub fn fields(instr: Instr) Fields {
    const i: u8 = @intCast(instr.hw2 >> 4 & 1);
    return .{
        .qd = @intCast(instr.hw2 >> 13),
        .high = 2 + i,
        .low = i,
        .rt = @intCast(instr.hw2 & 0xF),
        .rt2 = @intCast(instr.hw1 & 0xF),
        .to_vector = instr.hw1 >> 4 & 1 == 1,
    };
}

fn unpredictable(r: u4) bool {
    return r == 13 or r == 15;
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    if (instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    const f = fields(instr);
    if (unpredictable(f.rt) or unpredictable(f.rt2)) return null;
    if (f.to_vector) return toVector;
    if (f.rt == f.rt2) return null;
    return toCore;
}

fn toVector(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr);
    const bank = &cpu.fp.bank;
    var q = mve.qreg.read(bank, f.qd);
    if (pending(cpu, f.high)) q = mve.qreg.setElem(q, .word, f.high, cpu.regs.get(f.rt));
    if (pending(cpu, f.low)) q = mve.qreg.setElem(q, .word, f.low, cpu.regs.get(f.rt2));
    mve.qreg.write(bank, f.qd, q);
    mve_beats.finishEci(cpu);
}

/// Whether word lane `e`'s beat is still to run under EPSR.ECI.
fn pending(cpu: *const Cpu, e: u8) bool {
    return mve_beats.pending(cpu) >> @intCast(e * 4) & 1 == 1;
}

fn toCore(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr);
    const q = mve.qreg.read(&cpu.fp.bank, f.qd);
    if (pending(cpu, f.high)) cpu.regs.set(f.rt, mve.qreg.elem(q, .word, f.high));
    if (pending(cpu, f.low)) cpu.regs.set(f.rt2, mve.qreg.elem(q, .word, f.low));
    mve_beats.finishEci(cpu);
}
