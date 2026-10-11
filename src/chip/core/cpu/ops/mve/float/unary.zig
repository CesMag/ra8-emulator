//! MVE VABS and VNEG on F16 and F32 lanes (T1), predicated by VPR
//! (RA8EMU-23). hw1 is 1111 1111 1 D 11 size 01 and hw2 is Qd 0 0111 op 1
//! M 0 Qm 0, per QEMU's mve.decode and LLVM's assembler: op=0 is VABS,
//! op=1 is VNEG, size 1 is F16 and size 2 is F32; sizes 0 and 3 are left
//! unclaimed. D and M would name Q8 and above, so they must be zero. Both
//! only touch the sign bit and leave FPSCR alone; the lane semantics are in
//! src/chip/core/cpu/mve/float/float.zig.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const Size = mve.float.Size;
const Unary = mve.float.Unary;

pub const group: op.Group = .{ .name = "mve_float_unary", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with size (3:2) masked out.
    pub const hw1: u16 = 0xFFB1;
    pub const hw1_mask: u16 = 0xFFF3;
    /// hw2 with Qd (15:13), op (7) and Qm (3:1) masked out.
    pub const hw2: u16 = 0x0740;
    pub const hw2_mask: u16 = 0x1F71;
};

/// The fields one encoding names, or null when it names another op.
pub const Fields = struct { qd: u3, qm: u3, size: Size, op: Unary };

pub fn fields(instr: Instr) ?Fields {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    const size: Size = switch (instr.hw1 >> 2 & 3) {
        1 => .half,
        2 => .word,
        else => return null,
    };
    return .{
        .qd = @intCast(instr.hw2 >> 13 & 7),
        .qm = @intCast(instr.hw2 >> 1 & 7),
        .size = size,
        .op = if (instr.hw2 >> 7 & 1 == 1) .neg else .abs,
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
    mve.qreg.write(bank, f.qd, mve.float.unary(old, m, f.size, f.op, mve_beats.mask(cpu)));
    mve_beats.finish(cpu);
}
