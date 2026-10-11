//! Conformance vectors for the decode group `mve_modimm` (RA8EMU-633):
//! VMOV, VMVN, VORR and VBIC (immediate) T1. Expected values are worked
//! from AdvSIMDExpandImm in the Arm ARM (DDI0553); encodings match LLVM's
//! assembler for cortex-m85. Results merge byte by byte under the VPT
//! mask, the loop tail and the beats EPSR.ECI marks done. cmode 1111 with
//! op set, D set, fixed bits flipped and the 16-bit space stay unclaimed.
const vector = @import("../../vector.zig");
const mve_int = @import("int/vectors.zig");

pub const In = mve_int.In;
pub const Out = mve_int.Out;

const V = vector.Vector(In, Out);
const group = "mve_modimm";
pub const none = mve_int.none;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

const qd: u128 = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF;

fn on(hw1: u16, hw2: u16) In {
    return .{ .hw1 = hw1, .hw2 = hw2, .qd = qd };
}

pub const all = ops ++ predicated ++ unclaimed;

const ops = [_]V{
    vec("vmov.i32 q0, #0xab", on(0xFF82, 0x005B), .{ .qd = 0x000000AB_000000AB_000000AB_000000AB }),
    vec("vmov.i32 q3, #0xbe000000", on(0xFF83, 0x665E), .{ .qd = 0xBE000000_BE000000_BE000000_BE000000 }),
    vec("vmov.i16 q5, #0x8000", on(0xFF80, 0xAA50), .{ .qd = 0x80008000_80008000_80008000_80008000 }),
    vec("vmov.i32 q7, #0x12ffff", on(0xEF81, 0xED52), .{ .qd = 0x0012FFFF_0012FFFF_0012FFFF_0012FFFF }),
    vec("vmov.i8 q0, #0x5a", on(0xEF85, 0x0E5A), .{ .qd = 0x5A5A5A5A_5A5A5A5A_5A5A5A5A_5A5A5A5A }),
    vec("vmov.i64 q1, #0xff00ff0000ff00ff", on(0xFF82, 0x2E75), .{ .qd = 0xFF00FF00_00FF00FF_FF00FF00_00FF00FF }),
    vec("vmov.f32 q2, #-3.0", on(0xFF80, 0x4F58), .{ .qd = 0xC0400000_C0400000_C0400000_C0400000 }),
    vec("vmov.f32 q3, #1.0", on(0xEF87, 0x6F50), .{ .qd = 0x3F800000_3F800000_3F800000_3F800000 }),
    vec("vmvn.i32 q0, #0xab", on(0xFF82, 0x007B), .{ .qd = 0xFFFFFF54_FFFFFF54_FFFFFF54_FFFFFF54 }),
    vec("vmvn.i16 q1, #0x8000", on(0xFF80, 0x2A70), .{ .qd = 0x7FFF7FFF_7FFF7FFF_7FFF7FFF_7FFF7FFF }),
    vec("vmvn.i32 q2, #0x12ff", on(0xEF81, 0x4C72), .{ .qd = 0xFFFFED00_FFFFED00_FFFFED00_FFFFED00 }),
    vec("vorr.i32 q3, #0xf", on(0xEF80, 0x615F), .{ .qd = 0xDEADBEEF_CAFEF00F_0123456F_89ABCDEF }),
    vec("vorr.i16 q4, #0xf", on(0xEF80, 0x895F), .{ .qd = 0xDEAFBEEF_CAFFF00F_012F456F_89AFCDEF }),
    vec("vbic.i32 q5, #0xf000", on(0xFF87, 0xA370), .{ .qd = 0xDEAD0EEF_CAFE000D_01230567_89AB0DEF }),
    vec("vbic.i16 q6, #0xf000", on(0xFF87, 0xCB70), .{ .qd = 0x0EAD0EEF_0AFE000D_01230567_09AB0DEF }),
};

const predicated = [_]V{
    vec("vpt p0 0xff00 writes the high half and ends the block", .{ .hw1 = 0xFF82, .hw2 = 0x005B, .qd = qd, .vpr = 0x0088FF00 }, .{ .qd = 0x000000AB_000000AB_01234567_89ABCDEF, .vpr = 0x0000FF00 }),
    vec("the loop tail writes the first bytes", .{ .hw1 = 0xEF85, .hw2 = 0x0E5A, .qd = qd, .ltpsize = 0, .lr = 5 }, .{ .qd = 0xDEADBEEF_CAFEF00D_0123455A_5A5A5A5A }),
    vec("eci a0a1a2b0 hands beat 0 of the next instruction on", .{ .hw1 = 0xFF82, .hw2 = 0x005B, .qd = qd, .it = 0x50 }, .{ .qd = 0x000000AB_CAFEF00D_01234567_89ABCDEF, .it = 0x10 }),
};

const unclaimed = [_]V{
    vec("cmode 1111 with op set is undefined", .{ .hw1 = 0xFF80, .hw2 = 0x0F78 }, none),
    vec("d set is unclaimed", .{ .hw1 = 0xFFC2, .hw2 = 0x005B }, none),
    vec("hw1[3] set is unclaimed", .{ .hw1 = 0xFF8A, .hw2 = 0x005B }, none),
    vec("hw2[12] set is unclaimed", .{ .hw1 = 0xFF82, .hw2 = 0x105B }, none),
    vec("hw2[7] set is unclaimed", .{ .hw1 = 0xFF82, .hw2 = 0x00DB }, none),
    vec("hw2[6] clear is unclaimed", .{ .hw1 = 0xFF82, .hw2 = 0x001B }, none),
    vec("hw2[4] clear is unclaimed", .{ .hw1 = 0xFF82, .hw2 = 0x004B }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFF82, .hw2 = 0x005B, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
