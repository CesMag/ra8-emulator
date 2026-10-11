//! Conformance vectors for the decode group `fp_system` (RA8EMU-278):
//! VCMP and VCMPE (T1 register, T2 against +0.0) in half, single and
//! double precision, and the VMRS/VMSR transfers. Expected values are
//! worked from the Arm ARM (DDI0553): compares write FPSCR.NZCV as 1000
//! less, 0110 equal (+0 equals -0), 0010 greater, 0011 unordered; a
//! signalling NaN raises IOC, and VCMPE raises it for a quiet NaN too.
//! VMRS APSR_nzcv copies NZCV into the APSR and keeps the rest of xPSR;
//! VMSR FPSCR keeps only implemented bits (0xFFCF_009F); FPSCR_nzcvqc
//! moves bits 31:27; VPR writes drop the reserved top byte; P0 moves
//! VPR[15:0]; FPCXT is UNDEFINED from Non-secure, VMSR FPCXT_S loads
//! CONTROL.SFPA from bit 31 and FPSCR from bits 27:0, and VMRS FPCXT_S
//! returns SFPA:FPSCR[27:0], then loads FPSCR from FPDSCR and clears SFPA.
//! SP as Rt, PC for VMSR and the MVE registers, VCMP against zero with a
//! non-zero Vm, D16 and up, other register fields and the 16-bit space
//! are left unclaimed. Only the group's own decode runs here.
const vector = @import("../../vector.zig");

pub const fpscr_reset: u32 = 0x0004_0000;
pub const r1_in: u32 = 0x1111_1111;
pub const xpsr_in: u32 = 0x0100_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// S0 and S1, or D0 and D1 when `double` is set.
    a: u64 = 0,
    b: u64 = 0,
    double: bool = false,
    fpscr: u32 = fpscr_reset,
    r1: u32 = r1_in,
    xpsr: u32 = xpsr_in,
    vpr: u32 = 0,
    secure: bool = true,
    sfpa: bool = false,
};

pub const Fault = enum { none, undefined_instr, other };

pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    fpscr: u32 = fpscr_reset,
    r1: u32 = r1_in,
    xpsr: u32 = xpsr_in,
    vpr: u32 = 0,
    sfpa: bool = false,
};

const V = vector.Vector(In, Out);
const group = "fp_system";
pub const none: Out = .{ .claimed = false, .fpscr = 0, .r1 = 0, .xpsr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

fn flags(nzcv: u4, ioc: bool) u32 {
    return (@as(u32, nzcv) << 28) | fpscr_reset | @intFromBool(ioc);
}

const less: u4 = 0b1000;
const equal: u4 = 0b0110;
const greater: u4 = 0b0010;
const unordered: u4 = 0b0011;

const one: u64 = 0x3F80_0000;
const two: u64 = 0x4000_0000;
const qnan: u64 = 0x7FC0_0000;
const snan: u64 = 0x7F80_0001;

pub const all = compare ++ transfer ++ context ++ unclaimed;

const compare = [_]V{
    vec("vcmp.f32 1 < 2", .{ .hw1 = 0xEEB4, .hw2 = 0x0A60, .a = one, .b = two }, .{ .fpscr = flags(less, false) }),
    vec("vcmp.f32 2 > 1", .{ .hw1 = 0xEEB4, .hw2 = 0x0A60, .a = two, .b = one }, .{ .fpscr = flags(greater, false) }),
    vec("vcmp.f32 1 == 1", .{ .hw1 = 0xEEB4, .hw2 = 0x0A60, .a = one, .b = one }, .{ .fpscr = flags(equal, false) }),
    vec("vcmp.f32 +0 == -0", .{ .hw1 = 0xEEB4, .hw2 = 0x0A60, .a = 0, .b = 0x8000_0000 }, .{ .fpscr = flags(equal, false) }),
    vec("vcmp.f32 +inf > 1", .{ .hw1 = 0xEEB4, .hw2 = 0x0A60, .a = 0x7F80_0000, .b = one }, .{ .fpscr = flags(greater, false) }),
    vec("vcmp.f32 quiet nan is unordered without ioc", .{ .hw1 = 0xEEB4, .hw2 = 0x0A60, .a = qnan, .b = one }, .{ .fpscr = flags(unordered, false) }),
    vec("vcmpe.f32 quiet nan raises ioc", .{ .hw1 = 0xEEB4, .hw2 = 0x0AE0, .a = qnan, .b = one }, .{ .fpscr = flags(unordered, true) }),
    vec("vcmp.f32 signalling nan raises ioc", .{ .hw1 = 0xEEB4, .hw2 = 0x0A60, .a = one, .b = snan }, .{ .fpscr = flags(unordered, true) }),
    vec("vcmp.f32 s1, s0 takes D as the low bit", .{ .hw1 = 0xEEF4, .hw2 = 0x0A40, .a = one, .b = two }, .{ .fpscr = flags(greater, false) }),
    vec("vcmp.f32 -1 against zero", .{ .hw1 = 0xEEB5, .hw2 = 0x0A40, .a = 0xBF80_0000 }, .{ .fpscr = flags(less, false) }),
    vec("vcmp.f32 -0 against zero is equal", .{ .hw1 = 0xEEB5, .hw2 = 0x0A40, .a = 0x8000_0000 }, .{ .fpscr = flags(equal, false) }),
    vec("vcmp.f64 1 < 2", .{ .hw1 = 0xEEB4, .hw2 = 0x0B41, .double = true, .a = 0x3FF0_0000_0000_0000, .b = 0x4000_0000_0000_0000 }, .{ .fpscr = flags(less, false) }),
    vec("vcmpe.f64 quiet nan against zero", .{ .hw1 = 0xEEB5, .hw2 = 0x0BC0, .double = true, .a = 0x7FF8_0000_0000_0000 }, .{ .fpscr = flags(unordered, true) }),
    vec("vcmp.f16 1 < 2", .{ .hw1 = 0xEEB4, .hw2 = 0x0960, .a = 0x3C00, .b = 0x4000 }, .{ .fpscr = flags(less, false) }),
    vec("vcmp.f16 2 > 1", .{ .hw1 = 0xEEB4, .hw2 = 0x0960, .a = 0x4000, .b = 0x3C00 }, .{ .fpscr = flags(greater, false) }),
};

const transfer = [_]V{
    vec("vmrs r1, fpscr", .{ .hw1 = 0xEEF1, .hw2 = 0x1A10, .fpscr = 0x6004_0001 }, .{ .fpscr = 0x6004_0001, .r1 = 0x6004_0001 }),
    vec("vmrs apsr_nzcv, fpscr keeps q and thumb", .{ .hw1 = 0xEEF1, .hw2 = 0xFA10, .fpscr = 0x6004_0001, .xpsr = 0x0900_0000 }, .{ .fpscr = 0x6004_0001, .xpsr = 0x6900_0000 }),
    vec("vmsr fpscr, r1 keeps implemented bits", .{ .hw1 = 0xEEE1, .hw2 = 0x1A10, .r1 = 0xFFFF_FFFF }, .{ .fpscr = 0xFFCF_009F, .r1 = 0xFFFF_FFFF }),
    vec("vmsr fpscr, r1 with zero", .{ .hw1 = 0xEEE1, .hw2 = 0x1A10, .r1 = 0 }, .{ .fpscr = 0, .r1 = 0 }),
    vec("vmrs r1, vpr", .{ .hw1 = 0xEEFC, .hw2 = 0x1A10, .vpr = 0x00AB_1234 }, .{ .r1 = 0x00AB_1234, .vpr = 0x00AB_1234 }),
    vec("vmsr vpr, r1 drops the top byte", .{ .hw1 = 0xEEEC, .hw2 = 0x1A10, .r1 = 0xFFFF_FFFF }, .{ .r1 = 0xFFFF_FFFF, .vpr = 0x00FF_FFFF }),
    vec("vmrs r1, p0", .{ .hw1 = 0xEEFD, .hw2 = 0x1A10, .vpr = 0x00AB_1234 }, .{ .r1 = 0x1234, .vpr = 0x00AB_1234 }),
    vec("vmsr p0, r1 keeps the masks", .{ .hw1 = 0xEEED, .hw2 = 0x1A10, .r1 = 0xDEAD_BEEF, .vpr = 0x00AB_1234 }, .{ .r1 = 0xDEAD_BEEF, .vpr = 0x00AB_BEEF }),
    vec("vmrs r1, fpscr_nzcvqc", .{ .hw1 = 0xEEF2, .hw2 = 0x1A10, .fpscr = 0x6804_0001 }, .{ .fpscr = 0x6804_0001, .r1 = 0x6800_0000 }),
    vec("vmsr fpscr_nzcvqc, r1", .{ .hw1 = 0xEEE2, .hw2 = 0x1A10, .r1 = 0xF800_00FF, .fpscr = 0x0004_0001 }, .{ .fpscr = 0xF804_0001, .r1 = 0xF800_00FF }),
};

const context = [_]V{
    vec("vmsr fpcxt_s, r1 loads sfpa and fpscr", .{ .hw1 = 0xEEEF, .hw2 = 0x1A10, .r1 = 0x8004_0010 }, .{ .r1 = 0x8004_0010, .fpscr = 0x0004_0010, .sfpa = true }),
    vec("vmrs r1, fpcxt_s saves then resets", .{ .hw1 = 0xEEFF, .hw2 = 0x1A10, .fpscr = 0x6004_0001, .sfpa = true }, .{ .r1 = 0x8004_0001 }),
    vec("vmrs fpcxt_s from non-secure is undefined", .{ .hw1 = 0xEEFF, .hw2 = 0x1A10, .secure = false }, .{ .fault = .undefined_instr }),
    vec("vmsr fpcxt_ns from non-secure is undefined", .{ .hw1 = 0xEEEE, .hw2 = 0x1A10, .secure = false }, .{ .fault = .undefined_instr }),
};

const unclaimed = [_]V{
    bad("vmrs sp, fpscr is unclaimed", 0xEEF1, 0xDA10),
    bad("vmsr fpscr, pc is unclaimed", 0xEEE1, 0xFA10),
    bad("vmrs pc, vpr is unclaimed", 0xEEFC, 0xFA10),
    bad("vmsr p0, sp is unclaimed", 0xEEED, 0xDA10),
    bad("register field 0011 is unclaimed", 0xEEF3, 0x1A10),
    bad("compare with zero and a non-zero vm is unclaimed", 0xEEB5, 0x0A41),
    bad("vcmp.f64 d16, d1 is unclaimed", 0xEEF4, 0x0B41),
    bad("vcmp with hw2 bit 4 set is unclaimed", 0xEEB4, 0x0A50),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEEF1, .hw2 = 0x1A10, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
