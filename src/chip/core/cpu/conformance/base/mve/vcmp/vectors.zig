//! Conformance vectors for the decode group `mve_vcmp` (RA8EMU-278): the
//! integer VCMP and VPT forms, vector by vector and vector by scalar, at
//! every size and condition. Expected values are worked from the Arm ARM
//! (DDI0553) pseudocode: each element's compare (EQ and NE on the raw
//! bits, CS and HI unsigned, GE, LT, GT and LE signed) sets or clears the
//! P0 bits of its bytes, ANDed with the element mask (VPT P0, the loop
//! tail); P0 bytes of beats EPSR.ECI marks done keep their value. A VCMP
//! inside a block advances it; a VPT then opens its mask in each pair whose
//! odd beat has not run. Qn is written, then Qm for the vector forms only
//! (in the scalar forms those bits are Rm's). Size 11, Rm
//! of SP or PC, fixed bits flipped and the 16-bit space are left unclaimed.
const vector = @import("../../../vector.zig");

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    qn: u128 = 0,
    qm: u128 = 0,
    rm: u32 = 0,
    vpr: u32 = 0,
    it: u8 = 0,
    ltpsize: u3 = 4,
    lr: u32 = 0,
};

pub const Out = struct {
    claimed: bool = true,
    vpr: u32,
    it: u8 = 0,
};

const V = vector.Vector(In, Out);
const group = "mve_vcmp";
pub const none: Out = .{ .claimed = false, .vpr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = by_vector ++ by_scalar ++ blocks ++ unclaimed;

const by_vector = [_]V{
    vec("vcmp.i8 eq", .{ .hw1 = 0xFE03, .hw2 = 0x0F04, .qn = 0xC040FF00_807F5555_F0901001_FF807F00, .qm = 0x40C000FF_807F5456_0F101002_FF7F8000 }, .{ .vpr = 0x00000C29 }),
    vec("vcmp.i8 ne", .{ .hw1 = 0xFE03, .hw2 = 0x0F84, .qn = 0xC040FF00_807F5555_F0901001_FF807F00, .qm = 0x40C000FF_807F5456_0F101002_FF7F8000 }, .{ .vpr = 0x0000F3D6 }),
    vec("vcmp.u8 cs", .{ .hw1 = 0xFE03, .hw2 = 0x0F05, .qn = 0xC040FF00_807F5555_F0901001_FF807F00, .qm = 0x40C000FF_807F5456_0F101002_FF7F8000 }, .{ .vpr = 0x0000AEED }),
    vec("vcmp.u8 hi", .{ .hw1 = 0xFE03, .hw2 = 0x0F85, .qn = 0xC040FF00_807F5555_F0901001_FF807F00, .qm = 0x40C000FF_807F5456_0F101002_FF7F8000 }, .{ .vpr = 0x0000A2C4 }),
    vec("vcmp.s8 ge", .{ .hw1 = 0xFE03, .hw2 = 0x1F04, .qn = 0xC040FF00_807F5555_F0901001_FF807F00, .qm = 0x40C000FF_807F5456_0F101002_FF7F8000 }, .{ .vpr = 0x00005E2B }),
    vec("vcmp.s8 lt", .{ .hw1 = 0xFE03, .hw2 = 0x1F84, .qn = 0xC040FF00_807F5555_F0901001_FF807F00, .qm = 0x40C000FF_807F5456_0F101002_FF7F8000 }, .{ .vpr = 0x0000A1D4 }),
    vec("vcmp.s8 gt", .{ .hw1 = 0xFE03, .hw2 = 0x1F05, .qn = 0xC040FF00_807F5555_F0901001_FF807F00, .qm = 0x40C000FF_807F5456_0F101002_FF7F8000 }, .{ .vpr = 0x00005202 }),
    vec("vcmp.s8 le", .{ .hw1 = 0xFE03, .hw2 = 0x1F85, .qn = 0xC040FF00_807F5555_F0901001_FF807F00, .qm = 0x40C000FF_807F5456_0F101002_FF7F8000 }, .{ .vpr = 0x0000ADFD }),
    vec("vcmp.i16 eq", .{ .hw1 = 0xFE13, .hw2 = 0x0F04, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .qm = 0xF0000F00_12351234_00017FFF_80000000 }, .{ .vpr = 0x00000303 }),
    vec("vcmp.i16 ne", .{ .hw1 = 0xFE13, .hw2 = 0x0F84, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .qm = 0xF0000F00_12351234_00017FFF_80000000 }, .{ .vpr = 0x0000FCFC }),
    vec("vcmp.u16 cs", .{ .hw1 = 0xFE13, .hw2 = 0x0F05, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .qm = 0xF0000F00_12351234_00017FFF_80000000 }, .{ .vpr = 0x000033F3 }),
    vec("vcmp.u16 hi", .{ .hw1 = 0xFE13, .hw2 = 0x0F85, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .qm = 0xF0000F00_12351234_00017FFF_80000000 }, .{ .vpr = 0x000030F0 }),
    vec("vcmp.s16 ge", .{ .hw1 = 0xFE13, .hw2 = 0x1F04, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .qm = 0xF0000F00_12351234_00017FFF_80000000 }, .{ .vpr = 0x0000C30F }),
    vec("vcmp.s16 lt", .{ .hw1 = 0xFE13, .hw2 = 0x1F84, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .qm = 0xF0000F00_12351234_00017FFF_80000000 }, .{ .vpr = 0x00003CF0 }),
    vec("vcmp.s16 gt", .{ .hw1 = 0xFE13, .hw2 = 0x1F05, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .qm = 0xF0000F00_12351234_00017FFF_80000000 }, .{ .vpr = 0x0000C00C }),
    vec("vcmp.s16 le", .{ .hw1 = 0xFE13, .hw2 = 0x1F85, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .qm = 0xF0000F00_12351234_00017FFF_80000000 }, .{ .vpr = 0x00003FF3 }),
    vec("vcmp.i32 eq", .{ .hw1 = 0xFE23, .hw2 = 0x0F04, .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF, .qm = 0x00000001_12345678_7FFFFFFF_80000000 }, .{ .vpr = 0x00000F00 }),
    vec("vcmp.i32 ne", .{ .hw1 = 0xFE23, .hw2 = 0x0F84, .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF, .qm = 0x00000001_12345678_7FFFFFFF_80000000 }, .{ .vpr = 0x0000F0FF }),
    vec("vcmp.u32 cs", .{ .hw1 = 0xFE23, .hw2 = 0x0F05, .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF, .qm = 0x00000001_12345678_7FFFFFFF_80000000 }, .{ .vpr = 0x0000FFF0 }),
    vec("vcmp.u32 hi", .{ .hw1 = 0xFE23, .hw2 = 0x0F85, .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF, .qm = 0x00000001_12345678_7FFFFFFF_80000000 }, .{ .vpr = 0x0000F0F0 }),
    vec("vcmp.s32 ge", .{ .hw1 = 0xFE23, .hw2 = 0x1F04, .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF, .qm = 0x00000001_12345678_7FFFFFFF_80000000 }, .{ .vpr = 0x00000F0F }),
    vec("vcmp.s32 lt", .{ .hw1 = 0xFE23, .hw2 = 0x1F84, .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF, .qm = 0x00000001_12345678_7FFFFFFF_80000000 }, .{ .vpr = 0x0000F0F0 }),
    vec("vcmp.s32 gt", .{ .hw1 = 0xFE23, .hw2 = 0x1F05, .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF, .qm = 0x00000001_12345678_7FFFFFFF_80000000 }, .{ .vpr = 0x0000000F }),
    vec("vcmp.s32 le", .{ .hw1 = 0xFE23, .hw2 = 0x1F85, .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF, .qm = 0x00000001_12345678_7FFFFFFF_80000000 }, .{ .vpr = 0x0000FFF0 }),
    vec("vcmp eq of a register with itself is all ones", .{ .hw1 = 0xFE07, .hw2 = 0x0F06, .qn = 0xC040FF00_807F5555_F0901001_FF807F00 }, .{ .vpr = 0x0000FFFF }),
};

const by_scalar = [_]V{
    vec("vcmp.i16 eq against r2", .{ .hw1 = 0xFE13, .hw2 = 0x0F42, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .rm = 0x1234 }, .{ .vpr = 0x00000F00 }),
    vec("vcmp.i16 ne against r2", .{ .hw1 = 0xFE13, .hw2 = 0x0FC2, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .rm = 0x1234 }, .{ .vpr = 0x0000F0FF }),
    vec("vcmp.u16 cs against r2", .{ .hw1 = 0xFE13, .hw2 = 0x0F62, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .rm = 0x1234 }, .{ .vpr = 0x00003FFC }),
    vec("vcmp.u16 hi against r2", .{ .hw1 = 0xFE13, .hw2 = 0x0FE2, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .rm = 0x1234 }, .{ .vpr = 0x000030FC }),
    vec("vcmp.s16 ge against r2", .{ .hw1 = 0xFE13, .hw2 = 0x1F42, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .rm = 0x1234 }, .{ .vpr = 0x00000F0C }),
    vec("vcmp.s16 lt against r2", .{ .hw1 = 0xFE13, .hw2 = 0x1FC2, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .rm = 0x1234 }, .{ .vpr = 0x0000F0F3 }),
    vec("vcmp.s16 gt against r2", .{ .hw1 = 0xFE13, .hw2 = 0x1F62, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .rm = 0x1234 }, .{ .vpr = 0x0000000C }),
    vec("vcmp.s16 le against r2", .{ .hw1 = 0xFE13, .hw2 = 0x1FE2, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .rm = 0x1234 }, .{ .vpr = 0x0000FFF3 }),
    vec("vcmp.s8 ge against r12 uses its low bits", .{ .hw1 = 0xFE03, .hw2 = 0x1F4C, .qn = 0xC040FF00_807F5555_F0901001_FF807F00, .rm = 0xAB80 }, .{ .vpr = 0x0000FFFF }),
    vec("vcmp.s32 ge against r12 uses its low bits", .{ .hw1 = 0xFE23, .hw2 = 0x1F4C, .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF, .rm = 0x80000000 }, .{ .vpr = 0x0000FFFF }),
    vec("vcmp.i32 ne q7 against lr", .{ .hw1 = 0xFE2F, .hw2 = 0x0FCE, .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF, .rm = 0x12345678 }, .{ .vpr = 0x0000F0FF }),
};

const blocks = [_]V{
    vec("vpt.s32 ge opens a one-instruction block", .{ .hw1 = 0xFE63, .hw2 = 0x1F04, .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF, .qm = 0x00000001_12345678_7FFFFFFF_80000000 }, .{ .vpr = 0x00880F0F }),
    vec("vptt.i16 ne opens a two-instruction block", .{ .hw1 = 0xFE13, .hw2 = 0x8F84, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .qm = 0xF0000F00_12351234_00017FFF_80000000 }, .{ .vpr = 0x0044FCFC }),
    vec("vpteee.u8 hi against r2", .{ .hw1 = 0xFE43, .hw2 = 0xCFE2, .qn = 0xC040FF00_807F5555_F0901001_FF807F00, .rm = 0x40 }, .{ .vpr = 0x00EEAFCE }),
    vec("vpttte.u32 cs keeps mask 0001", .{ .hw1 = 0xFE23, .hw2 = 0x2F05, .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF, .qm = 0x00000001_12345678_7FFFFFFF_80000000 }, .{ .vpr = 0x0011FFF0 }),
    vec("vcmp in a vpt block ands the compare with p0", .{ .hw1 = 0xFE13, .hw2 = 0x0F04, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .qm = 0xF0000F00_12351234_00017FFF_80000000, .vpr = 0x00880FF0 }, .{ .vpr = 0x00000300 }),
    vec("the loop tail clears p0 past the tail", .{ .hw1 = 0xFE03, .hw2 = 0x1F05, .qn = 0xC040FF00_807F5555_F0901001_FF807F00, .qm = 0x40C000FF_807F5456_0F101002_FF7F8000, .vpr = 0x0000FFFF, .ltpsize = 0, .lr = 6 }, .{ .vpr = 0x00000002 }),
    vec("eci a0a1 keeps the done beats of p0", .{ .hw1 = 0xFE03, .hw2 = 0x1F85, .qn = 0xC040FF00_807F5555_F0901001_FF807F00, .qm = 0x40C000FF_807F5456_0F101002_FF7F8000, .vpr = 0x0000A5A5, .it = 0x20 }, .{ .vpr = 0x0000ADA5 }),
    vec("vpt with eci a0a1a2 opens only mask23", .{ .hw1 = 0xFE63, .hw2 = 0x0F04, .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF, .qm = 0x00000001_12345678_7FFFFFFF_80000000, .vpr = 0x00001234, .it = 0x40 }, .{ .vpr = 0x00800234 }),
    vec("vpt with eci a0 opens both masks", .{ .hw1 = 0xFE63, .hw2 = 0x0F04, .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF, .qm = 0x00000001_12345678_7FFFFFFF_80000000, .it = 0x10 }, .{ .vpr = 0x00880F00 }),
};

const unclaimed = [_]V{
    vec("size 11 is unclaimed", .{ .hw1 = 0xFE33, .hw2 = 0x0F04 }, none),
    vec("rm = sp is unclaimed", .{ .hw1 = 0xFE23, .hw2 = 0x0F4D }, none),
    vec("rm = pc is unclaimed", .{ .hw1 = 0xFE23, .hw2 = 0x0F4F }, none),
    vec("the vector form with hw2[5] set is unclaimed", .{ .hw1 = 0xFE23, .hw2 = 0x0F24 }, none),
    vec("hw2[4] set is unclaimed", .{ .hw1 = 0xFE23, .hw2 = 0x0F14 }, none),
    vec("hw2[11:8] other than 1111 is unclaimed", .{ .hw1 = 0xFE23, .hw2 = 0x0E04 }, none),
    vec("hw1[0] clear is unclaimed", .{ .hw1 = 0xFE22, .hw2 = 0x0F04 }, none),
    vec("hw1[12] clear is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0F04 }, none),
    vec("hw1[7] set is unclaimed", .{ .hw1 = 0xFEA3, .hw2 = 0x0F04 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFE23, .hw2 = 0x0F04, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
