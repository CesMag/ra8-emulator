//! MVE VAND, VBIC, VORR, VORN and VEOR (vector, T1), predicated by VPR
//! (RA8EMU-630). hw1 is 111U 1111 0 D sz Qn 0 and hw2 is Qd 0 0001 N 1 M 1
//! Qm 0. With U clear, sz picks VAND, VBIC, VORR or VORN; with U set only
//! sz 0 (VEOR) is MVE. D, N and M would name Q8 and above, so they must be
//! zero. `vmov qd, qm` is VORR qd, qm, qm. The semantics are in
//! src/chip/core/cpu/mve/bitwise/bitwise.zig.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const mve = @import("../../mve/all.zig");
const mve_int = @import("int/int.zig");
const Op = mve.bitwise.Op;

pub const group: op.Group = .{ .name = "mve_bitwise", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with U (bit 12), sz (5:4) and Qn (3:1) masked out.
    pub const hw1: u16 = 0xEF00;
    pub const hw1_mask: u16 = 0xEFC1;
    /// hw2 with Qd (15:13) and Qm (3:1) masked out.
    pub const hw2: u16 = 0x0150;
    pub const hw2_mask: u16 = 0x1FF1;
};

/// The operation an encoding names, or null when it is not an MVE one.
pub fn which(instr: Instr) ?Op {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    const sz = instr.hw1 >> 4 & 3;
    if (instr.hw1 >> 12 & 1 == 1) return if (sz == 0) .eor else null;
    return switch (sz) {
        0 => .@"and",
        1 => .bic,
        2 => .orr,
        else => .orn,
    };
}

fn decode(instr: Instr) ?op.Exec {
    return switch (which(instr) orelse return null) {
        inline else => |w| execFor(w),
    };
}

fn execFor(comptime w: Op) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const r = mve_int.regs(instr);
            const bank = &cpu.fp.bank;
            const result = mve.bitwise.apply(mve.qreg.read(bank, r[1]), mve.qreg.read(bank, r[2]), w);
            mve_int.writePredicated(cpu, r[0], result);
        }
    }.exec;
}
