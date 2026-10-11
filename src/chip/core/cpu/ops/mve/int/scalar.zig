//! MVE integer vector-by-scalar forms (T2), predicated by VPR (RA8EMU-25):
//! VADD, VSUB, VMUL, VQADD, VQSUB, VHADD, VHSUB, VQDMULH and VQRDMULH with
//! Rm as the second operand, its bottom lane-width bits used in every lane.
//! hw1 is 111U 1110 0 D size Qn B and hw2 is Qd T 1 1 1 1/0 N 1 S 0 Rm, per
//! LLVM's assembler; B picks the modulo group (VADD/VSUB/VMUL/VQDMULH) from
//! the saturating/halving one. U is unsigned for the second group, rounding
//! for VQDMULH, ignored by VADD/VSUB, and makes VMUL into VBRSR, whose
//! Rm[7:0] is a bit count rather than a lane value. Rm of SP or PC is CONSTRAINED UNPREDICTABLE and left unclaimed.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const mve_int = @import("int.zig");
const pair = @import("pair.zig");
const Size = mve.qreg.Size;

pub const group: op.Group = .{ .name = "mve_int_scalar", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 under mve_int.encodings.hw1_mask: B set, then B clear.
    pub const modulo_hw1: u16 = 0xEE01;
    pub const sat_hw1: u16 = 0xEE00;
    /// hw2 with Qd (15:13) and Rm (3:0) masked out.
    pub const hw2_mask: u16 = 0x1FF0;
    pub const vadd: u16 = 0x0F40;
    pub const vsub: u16 = 0x1F40;
    pub const vmul: u16 = 0x1E60;
    pub const vqdmulh: u16 = 0x0E60;
    pub const vqadd: u16 = 0x0F60;
    pub const vqsub: u16 = 0x1F60;
    pub const vhadd: u16 = 0x0F40;
    pub const vhsub: u16 = 0x1F40;
};

pub const Kind = enum { vadd, vsub, vmul, vbrsr, vqdmulh, vqrdmulh, vqadd, vqsub, vhadd, vhsub };

/// Which instruction an encoding is, or null outside this group.
pub fn kindOf(instr: Instr) ?Kind {
    const e = encodings;
    const u = instr.hw1 >> 12 & 1 == 1;
    const tail = instr.hw2 & e.hw2_mask;
    return switch (instr.hw1 & mve_int.encodings.hw1_mask) {
        e.modulo_hw1 => switch (tail) {
            e.vadd => .vadd,
            e.vsub => .vsub,
            e.vmul => if (u) .vbrsr else .vmul,
            e.vqdmulh => if (u) .vqrdmulh else .vqdmulh,
            else => null,
        },
        e.sat_hw1 => switch (tail) {
            e.vqadd => .vqadd,
            e.vqsub => .vqsub,
            e.vhadd => .vhadd,
            e.vhsub => .vhsub,
            else => null,
        },
        else => null,
    };
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    const size = instr.hw1 >> 4 & 3;
    const rm = instr.hw2 & 0xF;
    if (size == 3 or rm == 13 or rm == 15) return null;
    const kind = kindOf(instr) orelse return null;
    const unsigned = instr.hw1 >> 12 & 1 == 1;
    return switch (kind) {
        inline else => |k| switch (size) {
            0 => if (unsigned) execFor(k, .byte, true) else execFor(k, .byte, false),
            1 => if (unsigned) execFor(k, .half, true) else execFor(k, .half, false),
            else => if (unsigned) execFor(k, .word, true) else execFor(k, .word, false),
        },
    };
}

/// The scalar in every lane of a vector.
pub fn splat(scalar: u32, size: Size) u128 {
    var out: u128 = 0;
    for (0..mve.qreg.lanes(size)) |k| out = mve.qreg.setElem(out, size, @intCast(k), scalar);
    return out;
}

fn execFor(comptime kind: Kind, comptime size: Size, comptime unsigned: bool) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const qd: u3 = @intCast(instr.hw2 >> 13);
            const a = mve.qreg.read(&cpu.fp.bank, @intCast(instr.hw1 >> 1 & 7));
            const b = splat(cpu.regs.get(@intCast(instr.hw2 & 0xF)), size);
            const live = pair.activeLanes(mve_beats.mask(cpu), size);
            const result = switch (kind) {
                .vadd => mve.int.lanewise(a, b, size, .add),
                .vsub => mve.int.lanewise(a, b, size, .sub),
                .vmul => mve.int.lanewise(a, b, size, .mul),
                .vbrsr => mve.bit.reverse.reverseShift(a, cpu.regs.get(@intCast(instr.hw2 & 0xF)), size),
                .vhadd => mve.int.pairwise(a, b, size, unsigned, .hadd),
                .vhsub => mve.int.pairwise(a, b, size, unsigned, .hsub),
                .vqadd, .vqsub => blk: {
                    const sub = kind == .vqsub;
                    if (mve.int.saturating(a & live, b, size, unsigned, sub).saturated) cpu.fp.fpscr.qc = 1;
                    break :blk mve.int.saturating(a, b, size, unsigned, sub).value;
                },
                .vqdmulh, .vqrdmulh => blk: {
                    const h: mve.int.mul.High = .{ .double = true, .round = kind == .vqrdmulh };
                    if (mve.int.mul.multiplyHigh(a & live, b, size, h).saturated) cpu.fp.fpscr.qc = 1;
                    break :blk mve.int.mul.multiplyHigh(a, b, size, h).value;
                },
            };
            mve_int.writePredicated(cpu, qd, result);
        }
    }.exec;
}
