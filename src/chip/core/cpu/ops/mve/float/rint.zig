//! MVE VRINTN, VRINTX, VRINTA, VRINTZ, VRINTM and VRINTP on F16 and F32
//! lanes (T1), predicated by VPR (RA8EMU-23). hw1 is 1111 1111 1 D 11 size
//! 10 and hw2 is Qd 001 op 1 M 0 Qm 0, per QEMU's mve.decode and LLVM's
//! assembler. op is 000 N, 001 X, 010 A, 011 Z, 101 M and 111 P; 100 and
//! 110 are left unclaimed. size 1 is F16 and size 2 is F32; sizes 0 and 3
//! are left unclaimed. D and M would name Q8 and above, so they must be
//! zero. The lane semantics are in src/chip/core/cpu/mve/float/rint/rint.zig.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const Kind = mve.float.rint.Kind;

pub const group: op.Group = .{ .name = "mve_float_rint", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with size (3:2) masked out.
    pub const hw1: u16 = 0xFFB2;
    pub const hw1_mask: u16 = 0xFFF3;
    /// hw2 with Qd (15:13), op (9:7) and Qm (3:1) masked out.
    pub const hw2: u16 = 0x0440;
    pub const hw2_mask: u16 = 0x1C71;
};

/// The fields one encoding names.
pub const Fields = struct { qd: u3, qm: u3, size: mve.float.Size, kind: Kind };

pub fn fields(instr: Instr) ?Fields {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    const size: mve.float.Size = switch (instr.hw1 >> 2 & 3) {
        1 => .half,
        2 => .word,
        else => return null,
    };
    const kind: Kind = switch (instr.hw2 >> 7 & 7) {
        0 => .n,
        1 => .x,
        2 => .a,
        3 => .z,
        5 => .m,
        7 => .p,
        else => return null,
    };
    return .{ .qd = @intCast(instr.hw2 >> 13 & 7), .qm = @intCast(instr.hw2 >> 1 & 7), .size = size, .kind = kind };
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
    const result = mve.float.rint.rint(old, m, f.size, f.kind, mve_beats.mask(cpu), &cpu.fp.fpscr);
    mve.qreg.write(bank, f.qd, result);
    mve_beats.finish(cpu);
}
