//! MVE VCVT between float and integer lanes (T1) and VCVTA/N/P/M, float to
//! integer with a named rounding, predicated by VPR (RA8EMU-23). hw1 is
//! 1111 1111 1 D 11 size 11; size 1 pairs F16 with 16-bit integers, size 2
//! pairs F32 with 32-bit ones, and sizes 0 and 3 are left unclaimed. hw2
//! is Qd 0 011 op 1 M 0 Qm 0 for VCVT, where op is 00 S->F, 01 U->F, 10
//! F->S and 11 F->U (toward zero), or Qd 000 rm U 1 M 0 Qm 0 for VCVTA/N/
//! P/M, where rm 00 is ties away, 01 nearest, 10 toward +inf and 11 toward
//! -inf. Both layouts follow QEMU's mve.decode and LLVM's assembler. D and
//! M would name Q8 and above, so they must be zero. The lane semantics are
//! in src/chip/core/cpu/mve/float/int/int.zig.
const op = @import("../../../../op.zig");
const Cpu = @import("../../../../cpu.zig").Cpu;
const Instr = @import("../../../../instr.zig").Instr;
const mve = @import("../../../../mve/all.zig");
const fpu = @import("../../../../fpu/all.zig");
const mve_beats = @import("../../beats.zig");
const Rounding = fpu.rounding.Rounding;

pub const group: op.Group = .{ .name = "mve_float_cvt_int", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with size (3:2) masked out.
    pub const hw1: u16 = 0xFFB3;
    pub const hw1_mask: u16 = 0xFFF3;
    /// VCVT: hw2 with Qd, op (8:7) and Qm masked out.
    pub const plain_hw2: u16 = 0x0640;
    pub const plain_mask: u16 = 0x1E71;
    /// VCVTA/N/P/M: hw2 with Qd, rm (9:8), U (7) and Qm masked out.
    pub const rmode_hw2: u16 = 0x0040;
    pub const rmode_mask: u16 = 0x1C71;
};

/// The fields one encoding names. `rounding` is null for an int-to-float
/// conversion.
pub const Fields = struct { qd: u3, qm: u3, size: mve.float.Size, unsigned: bool, rounding: ?Rounding };

pub fn fields(instr: Instr) ?Fields {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    const size: mve.float.Size = switch (instr.hw1 >> 2 & 3) {
        1 => .half,
        2 => .word,
        else => return null,
    };
    const rounding: ?Rounding = if (instr.hw2 & encodings.plain_mask == encodings.plain_hw2)
        (if (instr.hw2 >> 8 & 1 == 1) .zero else null)
    else if (instr.hw2 & encodings.rmode_mask == encodings.rmode_hw2)
        rmode(@intCast(instr.hw2 >> 8 & 3))
    else
        return null;
    return .{
        .qd = @intCast(instr.hw2 >> 13 & 7),
        .qm = @intCast(instr.hw2 >> 1 & 7),
        .size = size,
        .unsigned = instr.hw2 >> 7 & 1 == 1,
        .rounding = rounding,
    };
}

/// The rounding a VCVTA/N/P/M rm field names.
pub fn rmode(rm: u2) Rounding {
    return switch (rm) {
        0 => .ties_away,
        1 => .nearest,
        2 => .plus_inf,
        3 => .minus_inf,
    };
}

fn decode(instr: Instr) ?op.Exec {
    _ = fields(instr) orelse return null;
    return run;
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    const bank = &cpu.fp.bank;
    const old = mve.qreg.read(bank, f.qd);
    const m = mve.qreg.read(bank, f.qm);
    const mask = mve_beats.mask(cpu);
    const fpscr = &cpu.fp.fpscr;
    const result = if (f.rounding) |r|
        mve.float.int.toInt(old, m, f.size, f.unsigned, r, 0, mask, fpscr)
    else
        mve.float.int.fromInt(old, m, f.size, f.unsigned, 0, mask, fpscr);
    mve.qreg.write(bank, f.qd, result);
    mve_beats.finish(cpu);
}
