//! MVE VADD, VSUB and VMUL (vector, T1), predicated by VPR (RA8EMU-25).
//! hw1 is 111U 1111 0 D size Qn 0 and hw2 is Qd 0 1000 N 1 M 0 Qm 0 for
//! VADD (U=0) and VSUB (U=1), or Qd 0 1001 N 1 M 1 Qm 0 for VMUL (U=0).
//! D, N and M would name Q8 and above, which do not exist, so they must be
//! zero; size 0b11 is another instruction. The result is written only to
//! the bytes the VPT block enables, and the block advances as each one
//! retires. The lane semantics are in src/chip/core/cpu/mve/int/int.zig.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
pub const mulh = @import("mulh.zig");
pub const pair = @import("pair.zig");
pub const scalar = @import("scalar.zig");
pub const shift = @import("shift.zig");
pub const vmla = @import("vmla.zig");
pub const vqdmlah = @import("vqdmlah.zig");
const Size = mve.qreg.Size;
const Op = mve.int.Op;

pub const group: op.Group = .{ .name = "mve_int", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with U (bit 12), size (5:4) and Qn (3:1) masked out.
    pub const hw1: u16 = 0xEF00;
    pub const hw1_mask: u16 = 0xEFC1;
    /// hw2 with Qd (15:13) and Qm (3:1) masked out.
    pub const hw2_mask: u16 = 0x1FF1;
    pub const add_sub_hw2: u16 = 0x0840;
    pub const mul_hw2: u16 = 0x0950;
};

/// The Q register numbers an instruction names: d, n and m.
pub fn regs(instr: Instr) [3]u3 {
    return .{ @intCast(instr.hw2 >> 13), @intCast(instr.hw1 >> 1 & 7), @intCast(instr.hw2 >> 1 & 7) };
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    const size = instr.hw1 >> 4 & 3;
    if (size == 3) return null;
    const unsigned = instr.hw1 >> 12 & 1 == 1;
    const tail = instr.hw2 & encodings.hw2_mask;
    const which: Op = if (tail == encodings.add_sub_hw2)
        (if (unsigned) .sub else .add)
    else if (tail == encodings.mul_hw2 and !unsigned) .mul else return null;
    return switch (which) {
        inline else => |w| switch (size) {
            0 => execFor(w, .byte),
            1 => execFor(w, .half),
            else => execFor(w, .word),
        },
    };
}

fn execFor(comptime which: Op, comptime size: Size) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const r = regs(instr);
            const bank = &cpu.fp.bank;
            const result = mve.int.lanewise(mve.qreg.read(bank, r[1]), mve.qreg.read(bank, r[2]), size, which);
            writePredicated(cpu, r[0], result);
        }
    }.exec;
}

/// Writes Qd under the VPT block's byte mask, then advances the block.
pub fn writePredicated(cpu: *Cpu, qd: u3, value: u128) void {
    const bank = &cpu.fp.bank;
    const mask = mve_beats.mask(cpu);
    mve.qreg.write(bank, qd, mve.predicate.merge(mve.qreg.read(bank, qd), value, mask));
    mve_beats.finish(cpu);
}
