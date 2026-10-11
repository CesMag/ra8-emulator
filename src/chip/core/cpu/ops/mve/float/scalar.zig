//! MVE VADD, VSUB, VMUL, VFMA and VFMAS on F16 and F32 lanes with Rm as
//! the second operand (by scalar), predicated by VPR (RA8EMU-23). hw1 is
//! 111s 1110 0 D 11 Qn B and hw2 is Qd T 111C N 1S0 Rm, per QEMU's
//! mve.decode and LLVM's assembler: s=1 is F16, and size 0b11 is what
//! keeps these apart from the integer by-scalar forms, which reject it.
//! B clear is VADD (T=0) and VSUB (T=1) with C=1; B set with C=0 is VMUL
//! (S=1), VFMA (T=0) and VFMAS (T=1). Rm of SP or PC is CONSTRAINED
//! UNPREDICTABLE and left unclaimed. The semantics are in
//! src/chip/core/cpu/mve/float/scalar/scalar.zig.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const Size = mve.float.Size;

pub const group: op.Group = .{ .name = "mve_float_scalar", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with s (bit 12) and Qn (3:1) masked out: B clear, then B set.
    pub const hw1_mask: u16 = 0xEFF1;
    pub const add_sub_hw1: u16 = 0xEE30;
    pub const mul_fma_hw1: u16 = 0xEE31;
    /// hw2 with Qd (15:13) and Rm (3:0) masked out.
    pub const hw2_mask: u16 = 0x1FF0;
    pub const vadd: u16 = 0x0F40;
    pub const vsub: u16 = 0x1F40;
    pub const vmul: u16 = 0x0E60;
    pub const vfma: u16 = 0x0E40;
    pub const vfmas: u16 = 0x1E40;
};

pub const Kind = enum { vadd, vsub, vmul, vfma, vfmas };

/// Which instruction an encoding is, or null outside this group.
pub fn kindOf(instr: Instr) ?Kind {
    if (instr.size != 4) return null;
    const rm = instr.hw2 & 0xF;
    if (rm == 13 or rm == 15) return null;
    const e = encodings;
    const tail = instr.hw2 & e.hw2_mask;
    return switch (instr.hw1 & e.hw1_mask) {
        e.add_sub_hw1 => switch (tail) {
            e.vadd => .vadd,
            e.vsub => .vsub,
            else => null,
        },
        e.mul_fma_hw1 => switch (tail) {
            e.vmul => .vmul,
            e.vfma => .vfma,
            e.vfmas => .vfmas,
            else => null,
        },
        else => null,
    };
}

fn decode(instr: Instr) ?op.Exec {
    const kind = kindOf(instr) orelse return null;
    const half = instr.hw1 >> 12 & 1 == 1;
    return switch (kind) {
        inline else => |k| if (half) execFor(k, .half) else execFor(k, .word),
    };
}

fn execFor(comptime kind: Kind, comptime size: Size) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const bank = &cpu.fp.bank;
            const qd: u3 = @intCast(instr.hw2 >> 13);
            const old = mve.qreg.read(bank, qd);
            const n = mve.qreg.read(bank, @intCast(instr.hw1 >> 1 & 7));
            const rm = cpu.regs.get(@intCast(instr.hw2 & 0xF));
            const mask = mve_beats.mask(cpu);
            const fpscr = &cpu.fp.fpscr;
            const result = switch (kind) {
                .vadd => mve.float.scalar.binary(old, n, rm, size, .add, mask, fpscr),
                .vsub => mve.float.scalar.binary(old, n, rm, size, .sub, mask, fpscr),
                .vmul => mve.float.scalar.binary(old, n, rm, size, .mul, mask, fpscr),
                .vfma => mve.float.scalar.fused(old, n, rm, size, .fma, mask, fpscr),
                .vfmas => mve.float.scalar.fused(old, n, rm, size, .fmas, mask, fpscr),
            };
            mve.qreg.write(bank, qd, result);
            mve_beats.finish(cpu);
        }
    }.exec;
}
