//! MVE shift by immediate (RA8EMU-636): VSHR, VRSHR, VSHL, VQSHL, VQSHLU,
//! VSRI and VSLI T1. All share 111U 1111 1 D imm6 | Qd 0 opc 0 1 M 1 Qm 0;
//! the top set bit of imm6 gives the lane size, and the rest the amount
//! (2*esize - imm6 rightwards, imm6 - esize leftwards). imm6 000xxx is the
//! modified-immediate space and stays with mve_modimm. The arithmetic is
//! src/chip/core/cpu/mve/int/shift/shift.zig and src/chip/core/cpu/mve/int/insert/insert.zig; this file only decodes.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const mve = @import("../../mve/all.zig");
const mve_beats = @import("beats.zig");
const mve_int = @import("int/int.zig");
const pair = @import("int/pair.zig");
const Size = mve.qreg.Size;
const Mode = mve.int.shift.Mode;

pub const group: op.Group = .{ .name = "mve_shift_imm", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with U (12) and imm6 (5:0) masked out; D (6) must be 0.
    pub const hw1: u16 = 0xEF80;
    pub const hw1_mask: u16 = 0xEFC0;
    /// hw2 with Qd (15:13), the opcode (11:8) and Qm (3:1) masked out;
    /// M (5) must be 0.
    pub const hw2: u16 = 0x0050;
    pub const hw2_mask: u16 = 0x10F1;
};

pub const Kind = enum { vshr, vrshr, vshl, vqshl, vqshlu, vsri, vsli };

pub const Fields = struct { qd: u3, qm: u3, size: Size, unsigned: bool, kind: Kind, amount: u6 };

fn kindOf(opcode: u4, unsigned: bool) ?Kind {
    return switch (opcode) {
        0b0000 => .vshr,
        0b0010 => .vrshr,
        0b0100 => if (unsigned) .vsri else null,
        0b0101 => if (unsigned) .vsli else .vshl,
        0b0110 => if (unsigned) .vqshlu else null,
        0b0111 => .vqshl,
        else => null,
    };
}

fn rightward(kind: Kind) bool {
    return kind == .vshr or kind == .vrshr or kind == .vsri;
}

/// The fields of a shift-by-immediate encoding, or null when it is not one.
pub fn fields(instr: Instr) ?Fields {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    const imm6: u7 = @intCast(instr.hw1 & 0x3F);
    if (imm6 < 8) return null;
    const unsigned = instr.hw1 >> 12 & 1 == 1;
    const kind = kindOf(@intCast(instr.hw2 >> 8 & 0xF), unsigned) orelse return null;
    const size: Size = if (imm6 >= 32) .word else if (imm6 >= 16) .half else .byte;
    const esize: u7 = @as(u7, 8) << @backingInt(size);
    return .{
        .qd = @intCast(instr.hw2 >> 13),
        .qm = @intCast(instr.hw2 >> 1 & 7),
        .size = size,
        .unsigned = unsigned,
        .kind = kind,
        .amount = @intCast(if (rightward(kind)) 2 * esize - imm6 else imm6 - esize),
    };
}

fn decode(instr: Instr) ?op.Exec {
    _ = fields(instr) orelse return null;
    return exec;
}

fn modeOf(f: Fields) Mode {
    return switch (f.kind) {
        .vshr, .vrshr => .{ .unsigned = f.unsigned, .round = f.kind == .vrshr },
        .vqshl => .{ .unsigned = f.unsigned, .saturate = true },
        .vqshlu => .{ .saturate = true, .saturate_unsigned = true },
        else => .{},
    };
}

fn shifted(f: Fields, m: u128) mve.int.Sat {
    const n: i8 = @intCast(f.amount);
    return mve.int.shift.byImmediate(m, if (rightward(f.kind)) -n else n, f.size, modeOf(f));
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    const m = mve.qreg.read(&cpu.fp.bank, f.qm);
    const d = mve.qreg.read(&cpu.fp.bank, f.qd);
    const result = switch (f.kind) {
        .vsri => mve.int.insert.sri(d, m, f.size, f.amount),
        .vsli => mve.int.insert.sli(d, m, f.size, f.amount),
        else => shifted(f, m).value,
    };
    if (f.kind == .vqshl or f.kind == .vqshlu) {
        const live = pair.activeLanes(mve_beats.mask(cpu), f.size);
        if (shifted(f, m & live).saturated) cpu.fp.fpscr.qc = 1;
    }
    mve_int.writePredicated(cpu, f.qd, result);
}
