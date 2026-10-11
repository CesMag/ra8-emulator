//! Conformance vectors for the decode group `pkh` (RA8EMU-280): PKHBT and
//! PKHTB (T1). Expected values are worked from the Arm ARM (DDI0553):
//! PKHBT keeps Rn[15:0] and takes the top halfword of Rm LSL #0..31, PKHTB
//! keeps Rn[31:16] and takes the bottom halfword of Rm ASR #1..32 (#0
//! encodes #32), with no flag changes. SP or PC in any register, a set
//! hw2[4] or hw2[15], S set and the dp.shifted rows are left unclaimed.
const vector = @import("../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// Rn, then Rm, before the instruction.
    n: u32 = 0,
    m: u32 = 0,
};

/// Whether the group claims the encoding, then Rd and the NZCV flags after.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "pkh";
const none: Out = .{ .claimed = false, .flags = 0 };

/// Rn r1; hw2 values carry Rd r0 and Rm r2.
const pkh = 0xEAC1;
const n: u32 = 0x1111_2222;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn in(hw2: u16, m: u32) In {
    return .{ .hw1 = pkh, .hw2 = hw2, .n = n, .m = m };
}

pub const all = [_]V{
    vec("pkhbt with no shift", in(0x0002, 0x3333_4444), .{ .rd = 0x3333_2222 }),
    vec("pkhbt lsl #8", in(0x2002, 0x0012_3400), .{ .rd = 0x1234_2222 }),
    vec("pkhbt lsl #16", in(0x4002, 0x0000_4444), .{ .rd = 0x4444_2222 }),
    vec("pkhbt lsl #31", in(0x70C2, 1), .{ .rd = 0x8000_2222 }),
    vec("pkhtb asr #1", in(0x0062, 0x0000_8888), .{ .rd = 0x1111_4444 }),
    vec("pkhtb asr #16 sign-extends", in(0x4022, 0x8888_0000), .{ .rd = 0x1111_8888 }),
    vec("pkhtb asr #31", in(0x70E2, 0x8000_0000), .{ .rd = 0x1111_FFFF }),
    vec("pkhtb #0 is asr #32 of a negative", in(0x0022, 0x8000_0000), .{ .rd = 0x1111_FFFF }),
    vec("pkhtb #0 is asr #32 of a positive", in(0x0022, 0x7FFF_FFFF), .{ .rd = 0x1111_0000 }),
    vec("pkhbt r12, lr, r4", .{ .hw1 = 0xEACE, .hw2 = 0x0C04, .n = 0xAAAA_BBBB, .m = 0xCCCC_DDDD }, .{ .rd = 0xCCCC_BBBB }),
    vec("pkhtb r1, r1, r1, asr #16 reads before writing", .{ .hw1 = pkh, .hw2 = 0x4121, .n = 0x1234_5678, .m = 0x1234_5678 }, .{ .rd = 0x1234_1234 }),
    vec("Rd of sp is unclaimed", in(0x0D02, 0), none),
    vec("Rd of pc is unclaimed", in(0x0F02, 0), none),
    vec("Rn of sp is unclaimed", .{ .hw1 = 0xEACD, .hw2 = 0x0002 }, none),
    vec("Rn of pc is unclaimed", .{ .hw1 = 0xEACF, .hw2 = 0x0002 }, none),
    vec("Rm of sp is unclaimed", in(0x000D, 0), none),
    vec("Rm of pc is unclaimed", in(0x000F, 0), none),
    vec("a set hw2[4] is unclaimed", in(0x0012, 0), none),
    vec("a set hw2[15] is unclaimed", in(0x8002, 0), none),
    vec("S set is unclaimed", .{ .hw1 = 0xEAD1, .hw2 = 0x0002 }, none),
    vec("orr belongs to dp.shifted", .{ .hw1 = 0xEA41, .hw2 = 0x0002 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = pkh, .hw2 = 0x0002, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
