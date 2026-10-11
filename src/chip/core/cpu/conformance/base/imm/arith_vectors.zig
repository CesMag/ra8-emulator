//! Conformance vectors for the decode group `imm_arith` (RA8EMU-280): ADD,
//! ADC, SBC, SUB and RSB with a modified immediate, CMN and CMP (ADDS and
//! SUBS with Rd of PC) and the SP forms of ADD and SUB. Expected values are
//! worked from the Arm ARM (DDI0553): ThumbExpandImm's four byte patterns
//! and rotations, AddWithCarry for the result and, with S, all of NZCV
//! (the rotation's carry is never used). SP or PC where the ARM calls it
//! UNPREDICTABLE, a zero byte in a repeating pattern, the undefined opcode
//! 1001 and the logical opcodes are left unclaimed.
const vector = @import("../../vector.zig");

/// The flags held before the instruction (N and C), which must survive
/// unless S is set.
pub const flags: u32 = 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// Rn (or SP) before the instruction.
    n: u32 = 0,
};

/// Whether the group claims the encoding, then Rd (0 when Rd is PC) and
/// the NZCV flags after.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "imm_arith";
const none: Out = .{ .claimed = false, .flags = 0 };
const sp: u32 = 0x2000_0400;

/// Each opcode with Rn r1, plain and with S.
const add = 0xF101;
const adds = 0xF111;
const adc = 0xF141;
const adcs = 0xF151;
const sbc = 0xF161;
const sbcs = 0xF171;
const sub = 0xF1A1;
const subs = 0xF1B1;
const rsb = 0xF1C1;
const rsbs = 0xF1D1;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn in(hw1: u16, hw2: u16, n: u32) In {
    return .{ .hw1 = hw1, .hw2 = hw2, .n = n };
}

pub const all = [_]V{
    vec("add r0, r1, #1 leaves the flags", in(add, 0x0001, 5), .{ .rd = 6 }),
    vec("adds carries out to zero", in(adds, 0x0001, 0xFFFF_FFFF), .{ .flags = 0x6000_0000 }),
    vec("adds overflows to negative", in(adds, 0x0001, 0x7FFF_FFFF), .{ .rd = 0x8000_0000, .flags = 0x9000_0000 }),
    vec("adds clears every flag", in(adds, 0x0001, 1), .{ .rd = 2, .flags = 0 }),
    vec("adds ignores the rotation's carry", in(adds, 0x4000, 0), .{ .rd = 0x8000_0000, .flags = 0x8000_0000 }),
    vec("pattern 00XY00XY", in(add, 0x10AB, 0), .{ .rd = 0x00AB_00AB }),
    vec("pattern XY00XY00", in(add, 0x20AB, 0), .{ .rd = 0xAB00_AB00 }),
    vec("pattern XYXYXYXY", in(add, 0x30AB, 0), .{ .rd = 0xABAB_ABAB }),
    vec("rotation by 16 from i", in(0xF501, 0x007F, 0), .{ .rd = 0x00FF_0000 }),
    vec("rotation by 31", in(0xF501, 0x70FF, 0), .{ .rd = 0x0000_01FE }),
    vec("adc adds the carry", in(adc, 0x0001, 5), .{ .rd = 7 }),
    vec("adcs wraps to zero", in(adcs, 0x0001, 0xFFFF_FFFE), .{ .flags = 0x6000_0000 }),
    vec("sbc with carry set subtracts", in(sbc, 0x0001, 5), .{ .rd = 4 }),
    vec("sbcs 0 - 0 with carry set", in(sbcs, 0x0000, 0), .{ .flags = 0x6000_0000 }),
    vec("sub r0, r1, #1", in(sub, 0x0001, 5), .{ .rd = 4 }),
    vec("subs borrows", in(subs, 0x0001, 0), .{ .rd = 0xFFFF_FFFF, .flags = 0x8000_0000 }),
    vec("subs overflows to positive", in(subs, 0x0001, 0x8000_0000), .{ .rd = 0x7FFF_FFFF, .flags = 0x3000_0000 }),
    vec("rsb r0, r1, #0 negates", in(rsb, 0x0000, 5), .{ .rd = 0xFFFF_FFFB }),
    vec("rsbs to zero", in(rsbs, 0x0001, 1), .{ .flags = 0x6000_0000 }),
    vec("cmp r1, #5", in(subs, 0x0F05, 5), .{ .flags = 0x6000_0000 }),
    vec("cmn r1, #1", in(adds, 0x0F01, 0xFFFF_FFFF), .{ .flags = 0x6000_0000 }),
    vec("add r0, sp, #4", in(0xF10D, 0x0004, sp), .{ .rd = sp + 4 }),
    vec("add sp, sp, #8", in(0xF10D, 0x0D08, sp), .{ .rd = sp + 8 }),
    vec("sub sp, sp, #0x10", in(0xF1AD, 0x0D10, sp), .{ .rd = sp - 0x10 }),
    vec("add with Rd of pc and no S is unclaimed", in(add, 0x0F01, 0), none),
    vec("cmp with Rn of pc is unclaimed", in(0xF1BF, 0x0F01, 0), none),
    vec("adds Rd of sp from r1 is unclaimed", in(adds, 0x0D01, 0), none),
    vec("adc Rd of sp is unclaimed", in(adc, 0x0D01, 0), none),
    vec("adc Rn of sp is unclaimed", in(0xF14D, 0x0001, 0), none),
    vec("sbc Rn of pc is unclaimed", in(0xF16F, 0x0001, 0), none),
    vec("a zero byte in a pattern is unclaimed", in(add, 0x1000, 0), none),
    vec("opcode 1001 is unclaimed", in(0xF121, 0x0001, 0), none),
    vec("and belongs to imm_logic", in(0xF001, 0x0001, 0), none),
    vec("a set hw2[15] is unclaimed", in(add, 0x8001, 0), none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = add, .hw2 = 0x0001, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
