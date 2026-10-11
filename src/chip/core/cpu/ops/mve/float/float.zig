//! MVE VADD, VSUB, VMUL and VABD on F16 and F32 lanes (vector, T1),
//! predicated by VPR (RA8EMU-23). hw1 is 111U 1111 0 D op sz Qn 0 and hw2
//! is Qd 0 1101 N 1 M x Qm 0: VADD is U=0 op=0 x=0, VSUB is U=0 op=1 x=0,
//! VMUL is U=1 op=0 x=1 and VABD is U=1 op=1 x=0. sz=1 is F16. D, N and M
//! would name Q8 and above, so they must be zero. The lane semantics,
//! flags and predication rule are in src/chip/core/cpu/mve/float/float.zig.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const mve_int = @import("../int/int.zig");
pub const cvt = @import("cvt/cvt.zig");
pub const fma = @import("fma.zig");
pub const maxnm = @import("maxnm.zig");
pub const maxnma = @import("maxnma.zig");
pub const maxnmv = @import("maxnmv.zig");
pub const rint = @import("rint.zig");
pub const scalar = @import("scalar.zig");
pub const unary = @import("unary.zig");
pub const vcadd = @import("vcadd.zig");
pub const vcmla = @import("vcmla.zig");
pub const vcmul = @import("vcmul.zig");
const Size = mve.float.Size;
const Op = mve.float.Op;

pub const group: op.Group = .{ .name = "mve_float", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with U (bit 12), op (5), sz (4) and Qn (3:1) masked out.
    pub const hw1: u16 = 0xEF00;
    pub const hw1_mask: u16 = 0xEFC1;
    /// hw2 with Qd (15:13) and Qm (3:1) masked out.
    pub const hw2_mask: u16 = 0x1FF1;
    pub const plain_hw2: u16 = 0x0D40;
    pub const mul_hw2: u16 = 0x0D50;
};

/// The operation an encoding names, or null when it names another one.
pub fn which(instr: Instr) ?Op {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    const unsigned = instr.hw1 >> 12 & 1 == 1;
    const second = instr.hw1 >> 5 & 1 == 1;
    const tail = instr.hw2 & encodings.hw2_mask;
    if (tail == encodings.plain_hw2) {
        if (!unsigned) return if (second) .sub else .add;
        return if (second) .abd else null;
    }
    if (tail == encodings.mul_hw2 and unsigned and !second) return .mul;
    return null;
}

fn decode(instr: Instr) ?op.Exec {
    const w = which(instr) orelse return null;
    const half = instr.hw1 >> 4 & 1 == 1;
    return switch (w) {
        inline else => |c| if (half) execFor(c, .half) else execFor(c, .word),
    };
}

fn execFor(comptime w: Op, comptime size: Size) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const r = mve_int.regs(instr);
            const bank = &cpu.fp.bank;
            const old = mve.qreg.read(bank, r[0]);
            const n = mve.qreg.read(bank, r[1]);
            const m = mve.qreg.read(bank, r[2]);
            const result = mve.float.binary(old, n, m, size, w, mve_beats.mask(cpu), &cpu.fp.fpscr);
            mve.qreg.write(bank, r[0], result);
            mve_beats.finish(cpu);
        }
    }.exec;
}
