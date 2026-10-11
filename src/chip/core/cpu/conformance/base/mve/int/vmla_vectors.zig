//! Conformance vectors for the decode group `mve_int_vmla` (RA8EMU-278):
//! VMLA and VMLAS, vector by scalar. Expected values are worked from the
//! Arm ARM (DDI0553) pseudocode: VMLA sets each Qda element to
//! Qda + Qn * Rm, VMLAS to Qda * Qn + Rm, with Rm's low esize bits as the
//! scalar and the result modulo the lane width (so U changes nothing).
//! The write goes byte by byte under the VPT element mask, the loop tail
//! and the beats EPSR.ECI leaves, and the block then advances. Qda and Qn
//! are written in that order before the instruction runs. Size 11, Rm of
//! SP or PC, D, N or M set, other fixed bits, VMULH's encoding and the
//! 16-bit space are left unclaimed.
const vector = @import("../../../vector.zig");

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    qda: u128 = 0,
    qn: u128 = 0,
    rm: u32 = 0,
    vpr: u32 = 0,
    it: u8 = 0,
    ltpsize: u3 = 4,
    lr: u32 = 0,
};

pub const Out = struct {
    claimed: bool = true,
    qda: u128,
    vpr: u32 = 0,
    it: u8 = 0,
};

const V = vector.Vector(In, Out);
const group = "mve_int_vmla";
pub const none: Out = .{ .claimed = false, .qda = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = scalar ++ predicated ++ unclaimed;

const scalar = [_]V{
    vec("vmla.i32 q0, q1, r2", .{ .hw1 = 0xEE23, .hw2 = 0x0E42, .qda = 0xFFFFFFFF_00000003_00000002_00000001, .qn = 0x00000002_0000001E_00000014_0000000A, .rm = 0x3 }, .{ .qda = 0x00000005_0000005D_0000003E_0000001F }),
    vec("vmla.i16 uses the low half of rm and wraps", .{ .hw1 = 0xEE13, .hw2 = 0x0E42, .qda = 0xFFFF0006_00050004_00030002_00017FFF, .qn = 0x00090008_00070006_00050004_00030002, .rm = 0x10003 }, .{ .qda = 0x001A001E_001A0016_0012000E_000A8005 }),
    vec("vmla.i8 by -1 subtracts", .{ .hw1 = 0xEE03, .hw2 = 0x0E42, .qda = 0x968C8278_6E645A50_463C3228_1E140A00, .qn = 0x100F0E0D_0C0B0A09_08070605_04030201, .rm = 0xFF }, .{ .qda = 0x867D746B_62595047_3E352C23_1A1108FF }),
    vec("vmlas.i32 q0, q1, r2", .{ .hw1 = 0xEE23, .hw2 = 0x1E42, .qda = 0xFFFFFFFF_00000003_00000002_00000001, .qn = 0x00000002_0000001E_00000014_0000000A, .rm = 0x80000000 }, .{ .qda = 0x7FFFFFFE_8000005A_80000028_8000000A }),
    vec("vmlas.i8 adds rm low byte", .{ .hw1 = 0xEE03, .hw2 = 0x1E42, .qda = 0x968C8278_6E645A50_463C3228_1E140A00, .qn = 0x100F0E0D_0C0B0A09_08070605_04030201, .rm = 0x12345601 }, .{ .qda = 0x61351D19_294D85D1_31A52DC9_793D1501 }),
    vec("u set changes nothing", .{ .hw1 = 0xFE23, .hw2 = 0x0E42, .qda = 0xFFFFFFFF_00000003_00000002_00000001, .qn = 0x00000002_0000001E_00000014_0000000A, .rm = 0x3 }, .{ .qda = 0x00000005_0000005D_0000003E_0000001F }),
    vec("qda = qn reads the same register", .{ .hw1 = 0xEE23, .hw2 = 0x2E42, .qda = 0xFFFFFFFF_00000003_00000002_00000001, .qn = 0x00000002_0000001E_00000014_0000000A, .rm = 0x2 }, .{ .qda = 0x00000006_0000005A_0000003C_0000001E }),
    vec("vmla.i16 q7, q6, r12", .{ .hw1 = 0xEE1D, .hw2 = 0xEE4C, .qda = 0xFFFF0006_00050004_00030002_00017FFF, .qn = 0x00090008_00070006_00050004_00030002, .rm = 0xFFFE }, .{ .qda = 0xFFEDFFF6_FFF7FFF8_FFF9FFFA_FFFB7FFB }),
    vec("vmlas.i32 q3, q2, lr", .{ .hw1 = 0xEE25, .hw2 = 0x7E4E, .qda = 0xFFFFFFFF_00000003_00000002_00000001, .qn = 0x00000002_0000001E_00000014_0000000A, .rm = 0x7 }, .{ .qda = 0x00000005_00000061_0000002F_00000011 }),
};

const predicated = [_]V{
    vec("vpt p0 0x00ff writes the low beats and ends the block", .{ .hw1 = 0xEE23, .hw2 = 0x0E42, .qda = 0xFFFFFFFF_00000003_00000002_00000001, .qn = 0x00000002_0000001E_00000014_0000000A, .rm = 0x3, .vpr = 0x008800FF }, .{ .qda = 0xFFFFFFFF_00000003_0000003E_0000001F, .vpr = 0x000000FF }),
    vec("vpt p0 0x5555 predicates bytes", .{ .hw1 = 0xEE03, .hw2 = 0x0E42, .qda = 0x968C8278_6E645A50_463C3228_1E140A00, .qn = 0x100F0E0D_0C0B0A09_08070605_04030201, .rm = 0x2, .vpr = 0x00885555 }, .{ .qda = 0x96AA8292_6E7A5A62_464A3232_1E1A0A02, .vpr = 0x00005555 }),
    vec("the loop tail leaves later elements", .{ .hw1 = 0xEE23, .hw2 = 0x0E42, .qda = 0xFFFFFFFF_00000003_00000002_00000001, .qn = 0x00000002_0000001E_00000014_0000000A, .rm = 0x3, .ltpsize = 2, .lr = 2 }, .{ .qda = 0xFFFFFFFF_00000003_0000003E_0000001F }),
    vec("eci a0a1 keeps the done beats", .{ .hw1 = 0xEE23, .hw2 = 0x0E42, .qda = 0xFFFFFFFF_00000003_00000002_00000001, .qn = 0x00000002_0000001E_00000014_0000000A, .rm = 0x3, .it = 0x20 }, .{ .qda = 0x00000005_0000005D_00000002_00000001 }),
};

const unclaimed = [_]V{
    vec("size 11 is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0E42 }, none),
    vec("rm = sp is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0E4D }, none),
    vec("rm = pc is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0E4F }, none),
    vec("n set is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0EC2 }, none),
    vec("m set is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0E62 }, none),
    vec("hw2[4] set is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0E52 }, none),
    vec("d set is unclaimed", .{ .hw1 = 0xEE63, .hw2 = 0x0E42 }, none),
    vec("hw1[0] clear is unclaimed", .{ .hw1 = 0xEE22, .hw2 = 0x0E42 }, none),
    vec("vmulh is not vmla", .{ .hw1 = 0xEE23, .hw2 = 0x0E02 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEE23, .hw2 = 0x0E42, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
