//! Conformance vectors for the decode group `mve_vmaxv` (RA8EMU-278):
//! VMAXV, VMINV, VMAXAV and VMINAV. Expected values are worked from the
//! Arm ARM (DDI0553) pseudocode: Rda's low esize bits start the fold
//! (signed for .S, unsigned for .U and the A forms), every active element
//! of Qm joins it (signed unless .U, absolute for the A forms) and the
//! result goes back to Rda extended to 32 bits. Active means the VPT
//! element mask, the loop tail and the beats EPSR.ECI leaves; the block
//! then advances. Qm is Q1 and holds `qm`. Size 11 (VMAXNMV), U with an A
//! form, op 01 or 11, M set, Rda of SP or PC, other fixed bits and the
//! 16-bit space are left unclaimed.
const vector = @import("../../vector.zig");

/// Bytes 05, F0, 7F, 80 then zeros.
pub const bytes: u128 = 0x807F_F005;
/// Halves 8000, 7FFF, 0001, FFFF then zeros.
pub const halves: u128 = 0xFFFF_0001_7FFF_8000;
/// Words 8000_0000, 7FFF_FFFF, FFFF_FFFF, 0000_0001.
pub const words: u128 = 0x00000001_FFFFFFFF_7FFFFFFF_80000000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    qm: u128 = bytes,
    rda: u32 = 0,
    vpr: u32 = 0,
    it: u8 = 0,
    ltpsize: u3 = 4,
    lr: u32 = 0,
};

pub const Out = struct {
    claimed: bool = true,
    rda: u32,
    vpr: u32 = 0,
    it: u8 = 0,
};

const V = vector.Vector(In, Out);
const group = "mve_vmaxv";
pub const none: Out = .{ .claimed = false, .rda = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = byte_forms ++ wide_forms ++ predicated ++ unclaimed;

const byte_forms = [_]V{
    vec("vmaxv.s8 r0, q1", .{ .hw1 = 0xEEE2, .hw2 = 0x0F02, .rda = 0x80 }, .{ .rda = 0x7F }),
    vec("vminv.s8 r0, q1 sign-extends", .{ .hw1 = 0xEEE2, .hw2 = 0x0F82 }, .{ .rda = 0xFFFF_FF80 }),
    vec("vmaxv.u8 r0, q1", .{ .hw1 = 0xFEE2, .hw2 = 0x0F02 }, .{ .rda = 0xF0 }),
    vec("vminv.u8 r0, q1 finds a zero lane", .{ .hw1 = 0xFEE2, .hw2 = 0x0F82, .rda = 0xFF }, .{ .rda = 0 }),
    vec("vmaxv.s8 reads only rda's low byte", .{ .hw1 = 0xEEE2, .hw2 = 0x0F02, .rda = 0x1234_567F }, .{ .rda = 0x7F }),
    vec("vmaxav.s8 takes |-128| as 128", .{ .hw1 = 0xEEE0, .hw2 = 0x0F02 }, .{ .rda = 0x80 }),
    vec("vminav.s8 starts from an unsigned rda", .{ .hw1 = 0xEEE0, .hw2 = 0x0F82, .rda = 0xFF }, .{ .rda = 0 }),
};

const wide_forms = [_]V{
    vec("vmaxv.s16 r3, q1", .{ .hw1 = 0xEEE6, .hw2 = 0x3F02, .qm = halves, .rda = 0x8000 }, .{ .rda = 0x7FFF }),
    vec("vminv.u16 r3, q1", .{ .hw1 = 0xFEE6, .hw2 = 0x3F82, .qm = halves, .rda = 0xFFFF }, .{ .rda = 0 }),
    vec("vmaxav.s16 takes |-32768|", .{ .hw1 = 0xEEE4, .hw2 = 0x0F02, .qm = halves }, .{ .rda = 0x8000 }),
    vec("vmaxv.s32 lr, q1", .{ .hw1 = 0xEEEA, .hw2 = 0xEF02, .qm = words, .rda = 0x8000_0000 }, .{ .rda = 0x7FFF_FFFF }),
    vec("vminv.s32 lr, q1", .{ .hw1 = 0xEEEA, .hw2 = 0xEF82, .qm = words }, .{ .rda = 0x8000_0000 }),
    vec("vmaxv.u32 r0, q1", .{ .hw1 = 0xFEEA, .hw2 = 0x0F02, .qm = words }, .{ .rda = 0xFFFF_FFFF }),
    vec("vmaxav.s32 takes |-2^31|", .{ .hw1 = 0xEEE8, .hw2 = 0x0F02, .qm = words }, .{ .rda = 0x8000_0000 }),
    vec("vminav.s32 finds the smallest magnitude", .{ .hw1 = 0xEEE8, .hw2 = 0x0F82, .qm = words, .rda = 0xFFFF_FFFF }, .{ .rda = 1 }),
};

const predicated = [_]V{
    vec("vpt p0 0x0001 folds byte 0 only", .{ .hw1 = 0xEEE2, .hw2 = 0x0F02, .rda = 0x80, .vpr = 0x0088_0001 }, .{ .rda = 5, .vpr = 0x0000_0001 }),
    vec("no active lanes extends rda", .{ .hw1 = 0xEEE2, .hw2 = 0x0F02, .rda = 0x1234_5680, .vpr = 0x0088_0000 }, .{ .rda = 0xFFFF_FF80 }),
    vec("the loop tail folds word 0 only", .{ .hw1 = 0xFEEA, .hw2 = 0x0F02, .qm = words, .ltpsize = 2, .lr = 1 }, .{ .rda = 0x8000_0000 }),
    vec("eci a0a1 folds beats 2 and 3", .{ .hw1 = 0xFEEA, .hw2 = 0x0F82, .qm = words, .rda = 0xFFFF_FFFF, .it = 0x20 }, .{ .rda = 1 }),
};

const unclaimed = [_]V{
    vec("size 11 is vmaxnmv's", .{ .hw1 = 0xEEEE, .hw2 = 0x0F02 }, none),
    vec("u with an a form is unclaimed", .{ .hw1 = 0xFEE0, .hw2 = 0x0F02 }, none),
    vec("op 01 is unclaimed", .{ .hw1 = 0xEEE1, .hw2 = 0x0F02 }, none),
    vec("op 11 is unclaimed", .{ .hw1 = 0xEEE3, .hw2 = 0x0F02 }, none),
    vec("m set is unclaimed", .{ .hw1 = 0xEEE2, .hw2 = 0x0F22 }, none),
    vec("rda = sp is unclaimed", .{ .hw1 = 0xEEE2, .hw2 = 0xDF02 }, none),
    vec("rda = pc is unclaimed", .{ .hw1 = 0xEEE2, .hw2 = 0xFF02 }, none),
    vec("hw2[0] set is unclaimed", .{ .hw1 = 0xEEE2, .hw2 = 0x0F03 }, none),
    vec("hw2[4] set is unclaimed", .{ .hw1 = 0xEEE2, .hw2 = 0x0F12 }, none),
    vec("hw1[5] clear is unclaimed", .{ .hw1 = 0xEEC2, .hw2 = 0x0F02 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEEE2, .hw2 = 0x0F02, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
