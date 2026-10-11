//! Conformance vectors for the decode group `mve_shift_imm` (RA8EMU-636):
//! VSHR, VRSHR, VSHL, VQSHL, VQSHLU, VSRI and VSLI by immediate. Expected
//! values are worked from the Arm ARM (DDI0553) pseudocode; the encodings
//! match LLVM's assembler for cortex-m85. Results merge byte by byte under
//! the VPT mask, the loop tail and the beats EPSR.ECI marks done, and only
//! active lanes set FPSCR.QC. imm6 000xxx (modified immediate), D or M
//! set, the spare opcodes and the 16-bit space stay unclaimed. Qd is
//! written before Qm.
const vector = @import("../../vector.zig");
const mve_int = @import("int/vectors.zig");

pub const In = mve_int.In;
pub const Out = mve_int.Out;

const V = vector.Vector(In, Out);
const group = "mve_shift_imm";
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
    vec("vshr.u32 q0, q0, #15", on(0xFFB1, 0x0050), .{ .qd = 0x000101FE_0001FDB9_0000ECA8_00000205 }),
    vec("vshr.s8 q1, q2, #1", on(0xEF8F, 0x2054), .{ .qd = 0xC0FF3F00_FFEEDDCC_3B2A1908_0001FFC0 }),
    vec("vshr.s16 q1, q2, #16", on(0xEF90, 0x2054), .{ .qd = 0xFFFF0000_FFFFFFFF_00000000_0000FFFF }),
    vec("vshr.u32 q1, q2, #32", on(0xFFA0, 0x2054), .{ .qd = 0 }),
    vec("vrshr.s32 q1, q2, #3", on(0xEFBD, 0x2254), .{ .qd = 0xF01FEFE0_FFDB9753_0ECA8642_00205FF0 }),
    vec("vrshr.u8 q1, q2, #8", on(0xFF88, 0x2254), .{ .qd = 0x01010000_01010101_00000000_00000101 }),
    vec("vshl.i8 q1, q2, #0", on(0xEF88, 0x2554), .{ .qd = qm }),
    vec("vshl.i16 q1, q2, #5", on(0xEF95, 0x2554), .{ .qd = 0x1FE0E020_DB805300_CA804200_2040F000 }),
    vec("vshl.i32 q1, q2, #31", on(0xEFBF, 0x2554), .{ .qd = 0x80000000_00000000_00000000_00000000 }),
    vec("vqshl.s8 q1, q2, #3", on(0xEF8B, 0x2754), .{ .qd = 0x80F87F08_F0808080_7F7F7F7F_0810F880, .qc = 1 }),
    vec("vqshl.u16 q1, q2, #4", on(0xFF94, 0x2754), .{ .qd = 0xFFFFFFFF_FFFFFFFF_FFFFFFFF_1020FFFF, .qc = 1 }),
    vec("vqshlu.s32 q1, q2, #2", on(0xFFA2, 0x2654), .{ .qd = 0x00000000_00000000_FFFFFFFF_040BFE00, .qc = 1 }),
    vec("vsri.8 q1, q2, #3", on(0xFF8D, 0x2454), .{ .qd = 0xD0BFAFE0_DFFBF713_0E2A4662_80A0DFF0 }),
    vec("vsri.32 q1, q2, #32 keeps qd", on(0xFFA0, 0x2454), .{ .qd = qd }),
    vec("vsli.16 q1, q2, #4", on(0xFF94, 0x2554), .{ .qd = 0x0FFDF01F_EDCEA98D_65432107_102BF80F }),
    vec("vsli.32 q1, q2, #0", on(0xFFA0, 0x2554), .{ .qd = qm }),
};

const predicated = [_]V{
    vec("vpt p0 0xff00 writes the high half and ends the block", .{ .hw1 = 0xEF95, .hw2 = 0x2554, .qd = qd, .qm = qm, .vpr = 0x0088FF00 }, .{ .qd = 0x1FE0E020_DB805300_01234567_89ABCDEF, .vpr = 0x0000FF00 }),
    vec("vqshl lanes the mask turns off set no qc", .{ .hw1 = 0xEF8B, .hw2 = 0x2754, .qd = qd, .qm = qm, .vpr = 0x0088000E }, .{ .qd = 0xDEADBEEF_CAFEF00D_01234567_0810F8EF, .vpr = 0x0000000E }),
    vec("the loop tail writes the first bytes", .{ .hw1 = 0xEF95, .hw2 = 0x2554, .qd = qd, .qm = qm, .ltpsize = 0, .lr = 5 }, .{ .qd = 0xDEADBEEF_CAFEF00D_01234500_2040F000 }),
    vec("eci a0a1a2b0 hands beat 0 of the next instruction on", .{ .hw1 = 0xEF95, .hw2 = 0x2554, .qd = qd, .qm = qm, .it = 0x50 }, .{ .qd = 0x1FE0E020_CAFEF00D_01234567_89ABCDEF, .it = 0x10 }),
};

const unclaimed = [_]V{
    vec("imm6 000xxx is the modified-immediate space", .{ .hw1 = 0xEF87, .hw2 = 0x2054 }, none),
    vec("d set is unclaimed", .{ .hw1 = 0xEFCF, .hw2 = 0x2054 }, none),
    vec("m set is unclaimed", .{ .hw1 = 0xEF8F, .hw2 = 0x2074 }, none),
    vec("hw2[0] set is unclaimed", .{ .hw1 = 0xEF8F, .hw2 = 0x2055 }, none),
    vec("vsri with u clear is unclaimed", .{ .hw1 = 0xEF8D, .hw2 = 0x2454 }, none),
    vec("vqshlu with u clear is unclaimed", .{ .hw1 = 0xEFA2, .hw2 = 0x2654 }, none),
    vec("opcode 0001 is unclaimed", .{ .hw1 = 0xEF8F, .hw2 = 0x2154 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEF8F, .hw2 = 0x2054, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
