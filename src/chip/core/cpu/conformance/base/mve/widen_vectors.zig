//! Conformance vectors for the decode group `mve_widen` (RA8EMU-635):
//! VMOVLB/VMOVLT and VSHLLB/VSHLLT T1 and T2. Expected values are worked
//! from the Arm ARM (DDI0553) pseudocode: each bottom or top source lane
//! is sign or zero extended to twice its width and shifted left. The
//! encodings match LLVM's assembler for cortex-m85. Results merge byte by
//! byte under the VPT mask, the loop tail and the beats EPSR.ECI marks
//! done. imm5 00xxx, D or M set, T2 size 1x, VMOVN's bit and the 16-bit
//! space stay unclaimed. Qd is written before Qm.
const vector = @import("../../vector.zig");
const mve_int = @import("int/vectors.zig");

pub const In = mve_int.In;
pub const Out = mve_int.Out;

const V = vector.Vector(In, Out);
const group = "mve_widen";
pub const none = mve_int.none;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

const qd: u128 = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF;
const qm: u128 = 0x80FF7F01_FEDCBA98_76543210_0102FF80;

fn on(hw1: u16, hw2: u16) In {
    return .{ .hw1 = hw1, .hw2 = hw2, .qd = qd, .qm = qm };
}

pub const all = ops ++ predicated ++ unclaimed;

const ops = [_]V{
    vec("vmovlb.s8 q1, q2", on(0xEEA8, 0x2F44), .{ .qd = 0xFFFF0001_FFDCFF98_00540010_0002FF80 }),
    vec("vmovlt.s8 q1, q2", on(0xEEA8, 0x3F44), .{ .qd = 0xFF80007F_FFFEFFBA_00760032_0001FFFF }),
    vec("vmovlb.u8 q1, q2", on(0xFEA8, 0x2F44), .{ .qd = 0x00FF0001_00DC0098_00540010_00020080 }),
    vec("vmovlt.u8 q1, q2", on(0xFEA8, 0x3F44), .{ .qd = 0x0080007F_00FE00BA_00760032_000100FF }),
    vec("vmovlb.s16 q0, q0", on(0xEEB0, 0x0F40), .{ .qd = 0x00007F01_FFFFBA98_00003210_FFFFFF80 }),
    vec("vmovlt.s16 q3, q4", on(0xEEB0, 0x7F48), .{ .qd = 0xFFFF80FF_FFFFFEDC_00007654_00000102 }),
    vec("vmovlb.u16 q5, q6", on(0xFEB0, 0xAF4C), .{ .qd = 0x00007F01_0000BA98_00003210_0000FF80 }),
    vec("vmovlt.u16 q7, q0", on(0xFEB0, 0xFF40), .{ .qd = 0x000080FF_0000FEDC_00007654_00000102 }),
    vec("vshllb.s8 q1, q2, #3", on(0xEEAB, 0x2F44), .{ .qd = 0xFFF80008_FEE0FCC0_02A00080_0010FC00 }),
    vec("vshllt.u16 q1, q2, #5", on(0xFEB5, 0x3F44), .{ .qd = 0x00101FE0_001FDB80_000ECA80_00002040 }),
    vec("vshllb.s8 q1, q2, #8 (T2)", on(0xEE31, 0x2E05), .{ .qd = 0xFF000100_DC009800_54001000_02008000 }),
    vec("vshllt.u16 q1, q2, #16 (T2)", on(0xFE35, 0x3E05), .{ .qd = 0x80FF0000_FEDC0000_76540000_01020000 }),
};

const predicated = [_]V{
    vec("vpt p0 0xff00 writes the high half and ends the block", .{ .hw1 = 0xEEA8, .hw2 = 0x2F44, .qd = qd, .qm = qm, .vpr = 0x0088FF00 }, .{ .qd = 0xFFFF0001_FFDCFF98_01234567_89ABCDEF, .vpr = 0x0000FF00 }),
    vec("the loop tail writes the first bytes", .{ .hw1 = 0xEEA8, .hw2 = 0x2F44, .qd = qd, .qm = qm, .ltpsize = 0, .lr = 5 }, .{ .qd = 0xDEADBEEF_CAFEF00D_01234510_0002FF80 }),
    vec("eci a0a1a2b0 hands beat 0 of the next instruction on", .{ .hw1 = 0xEEA8, .hw2 = 0x2F44, .qd = qd, .qm = qm, .it = 0x50 }, .{ .qd = 0xFFFF0001_CAFEF00D_01234567_89ABCDEF, .it = 0x10 }),
};

const unclaimed = [_]V{
    vec("imm5 00xxx is unclaimed", .{ .hw1 = 0xEEA4, .hw2 = 0x2F44 }, none),
    vec("d set is unclaimed", .{ .hw1 = 0xEEE8, .hw2 = 0x2F44 }, none),
    vec("m set is unclaimed", .{ .hw1 = 0xEEA8, .hw2 = 0x2F64 }, none),
    vec("t1 hw2[0] set is unclaimed", .{ .hw1 = 0xEEA8, .hw2 = 0x2F45 }, none),
    vec("t2 size 10 is unclaimed", .{ .hw1 = 0xEE39, .hw2 = 0x2E05 }, none),
    vec("t2 with VMOVN's hw2[7] is unclaimed", .{ .hw1 = 0xEE31, .hw2 = 0x2E85 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEEA8, .hw2 = 0x2F44, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
