//! MVE VMOVLB/VMOVLT and VSHLLB/VSHLLT, predicated by VPR (RA8EMU-635).
//! T1 is 111U 1110 1 D 1 imm5 / Qd T 1111 0 1 M 0 Qm 0: imm5 01xxx is a
//! byte source and 1xxxx a halfword source, the low bits are the left
//! shift, and a shift of zero is VMOVL. T2 is 111U 1110 0 D 11 sz 01 /
//! Qd T 1110 0 0 M 0 Qm 1 and shifts by the source width. D and M would
//! name Q8 and above, so both must be zero. The semantics are widen in
//! src/chip/core/cpu/mve/int.width.zig.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const mve = @import("../../mve/all.zig");
const mve_int = @import("int/int.zig");
const Size = mve.qreg.Size;

pub const group: op.Group = .{ .name = "mve_widen", .decode = decode, .oracle = false };

pub const encodings = struct {
    pub const t1_hw1: u16 = 0xEEA0;
    pub const t1_hw1_mask: u16 = 0xEFE0;
    pub const t1_hw2: u16 = 0x0F40;
    pub const t2_hw1: u16 = 0xEE31;
    pub const t2_hw1_mask: u16 = 0xEFF3;
    pub const t2_hw2: u16 = 0x0E01;
    /// Shared by both: Qd (15:13), T (12) and Qm (3:1) masked out.
    pub const hw2_mask: u16 = 0x0FF1;
};

pub const Fields = struct { qd: u3, qm: u3, size: Size, half: mve.int.width.Half, unsigned: bool, left: u6 };

/// The fields of a VMOVL or VSHLL encoding, or null when it is neither.
pub fn fields(instr: Instr) ?Fields {
    if (instr.size != 4) return null;
    const shape = shift(instr) orelse return null;
    return .{
        .qd = @intCast(instr.hw2 >> 13),
        .qm = @intCast(instr.hw2 >> 1 & 7),
        .size = shape.size,
        .half = @fromBackingInt(@intCast(instr.hw2 >> 12 & 1)),
        .unsigned = instr.hw1 >> 12 & 1 == 1,
        .left = shape.left,
    };
}

const Shape = struct { size: Size, left: u6 };

fn shift(instr: Instr) ?Shape {
    const hw1 = instr.hw1;
    if (hw1 & encodings.t1_hw1_mask == encodings.t1_hw1 and instr.hw2 & encodings.hw2_mask == encodings.t1_hw2) {
        const imm5: u6 = @intCast(hw1 & 0x1F);
        if (imm5 >= 16) return .{ .size = .half, .left = imm5 - 16 };
        if (imm5 >= 8) return .{ .size = .byte, .left = imm5 - 8 };
        return null;
    }
    if (hw1 & encodings.t2_hw1_mask == encodings.t2_hw1 and instr.hw2 & encodings.hw2_mask == encodings.t2_hw2) {
        return switch (hw1 >> 2 & 3) {
            0 => .{ .size = .byte, .left = 8 },
            1 => .{ .size = .half, .left = 16 },
            else => null,
        };
    }
    return null;
}

fn decode(instr: Instr) ?op.Exec {
    _ = fields(instr) orelse return null;
    return exec;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    const m = mve.qreg.read(&cpu.fp.bank, f.qm);
    mve_int.writePredicated(cpu, f.qd, mve.int.width.widen(m, f.size, f.half, f.unsigned, f.left));
}
