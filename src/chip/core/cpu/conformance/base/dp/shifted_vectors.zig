//! Conformance vectors for the decode group `dp_shifted` (RA8EMU-280): the
//! 32-bit data processing (shifted register) forms AND, BIC, ORR, ORN, EOR,
//! ADD, ADC, SBC, SUB and RSB, with MOV and its shift aliases, MVN, TST,
//! TEQ, CMN and CMP. Expected values are worked from the Arm ARM (DDI0553):
//! DecodeImmShift (LSR and ASR #0 mean #32, ROR #0 is RRX), Shift_C's carry
//! for the logical ops under S, and AddWithCarry's NZCV for the arithmetic
//! ones (the shifter's carry unused). SP or PC where the ARM calls it
//! UNPREDICTABLE, the unallocated opcodes and PKH are left unclaimed.
const vector = @import("../../vector.zig");

/// The flags held before the instruction (N and C), which must survive
/// unless S is set.
pub const flags: u32 = 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// Rn (or SP), then Rm, before the instruction.
    n: u32 = 0,
    m: u32 = 0,
};

/// Whether the group claims the encoding, then Rd (0 when Rd is PC) and
/// the NZCV flags after.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "dp_shifted";
const none: Out = .{ .claimed = false, .flags = 0 };
const sp: u32 = 0x2000_0400;

/// Each opcode with Rn r1 (Rd r0 and Rm r2 live in hw2), and MOV/MVN.
const and_ = 0xEA01;
const ands = 0xEA11;
const movs = 0xEA5F;
const eors = 0xEA91;
const add = 0xEB01;
const adds = 0xEB11;
const subs = 0xEBB1;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn in(hw1: u16, hw2: u16, n: u32, m: u32) In {
    return .{ .hw1 = hw1, .hw2 = hw2, .n = n, .m = m };
}

pub const all = [_]V{
    vec("and r0, r1, r2 leaves the flags", in(and_, 0x0002, 0xFF, 0x0F), .{ .rd = 0x0F }),
    vec("ands lsl #4 takes C from bit 28", in(ands, 0x1002, 0xF0, 0x0F), .{ .rd = 0xF0, .flags = 0 }),
    vec("ands lsl #0 keeps the carry", in(ands, 0x0002, 1, 1), .{ .rd = 1, .flags = 0x2000_0000 }),
    vec("movs lsr #1", in(movs, 0x0052, 0, 3), .{ .rd = 1, .flags = 0x2000_0000 }),
    vec("movs lsr #32", in(movs, 0x0012, 0, 0x8000_0000), .{ .flags = 0x6000_0000 }),
    vec("movs asr #32 of a positive value", in(movs, 0x0022, 0, 0x7FFF_FFFF), .{ .flags = 0x4000_0000 }),
    vec("movs asr #4 of a negative value", in(movs, 0x1022, 0, 0x8000_0000), .{ .rd = 0xF800_0000, .flags = 0x8000_0000 }),
    vec("movs ror #8", in(movs, 0x2032, 0, 0xFF), .{ .rd = 0xFF00_0000, .flags = 0xA000_0000 }),
    vec("movs rrx shifts the carry in", in(movs, 0x0032, 0, 2), .{ .rd = 0x8000_0001, .flags = 0x8000_0000 }),
    vec("mov lsl #31 leaves the flags", in(0xEA4F, 0x70C2, 0, 1), .{ .rd = 0x8000_0000 }),
    vec("bic r0, r1, r2", in(0xEA21, 0x0002, 0xFF, 0x0F), .{ .rd = 0xF0 }),
    vec("orr r0, r1, r2, lsl #8", in(0xEA41, 0x2002, 0x0F, 0x0F), .{ .rd = 0x0F0F }),
    vec("orn r0, r1, r2", in(0xEA61, 0x0002, 0, 0x0F), .{ .rd = 0xFFFF_FFF0 }),
    vec("mvns to zero", in(0xEA7F, 0x0002, 0, 0xFFFF_FFFF), .{ .flags = 0x6000_0000 }),
    vec("eors to zero", in(eors, 0x0002, 0x55, 0x55), .{ .flags = 0x6000_0000 }),
    vec("tst r1, r2", in(ands, 0x0F02, 1, 2), .{ .flags = 0x6000_0000 }),
    vec("teq r1, r2, lsr #1 clears C", in(eors, 0x0F52, 1, 2), .{ .flags = 0x4000_0000 }),
    vec("add r0, r1, r2, lsl #2", in(add, 0x0082, 1, 3), .{ .rd = 13 }),
    vec("adds overflows to negative", in(adds, 0x0002, 0x7FFF_FFFF, 1), .{ .rd = 0x8000_0000, .flags = 0x9000_0000 }),
    vec("adds ignores the shifter's carry", in(adds, 0x0012, 5, 0x8000_0000), .{ .rd = 5, .flags = 0 }),
    vec("adc adds the carry", in(0xEB41, 0x0002, 5, 1), .{ .rd = 7 }),
    vec("adcs wraps to zero", in(0xEB51, 0x0002, 0xFFFF_FFFE, 1), .{ .flags = 0x6000_0000 }),
    vec("sbc with carry set subtracts", in(0xEB61, 0x0002, 5, 1), .{ .rd = 4 }),
    vec("sub r0, r1, r2, asr #1", in(0xEBA1, 0x0062, 0, 0xFFFF_FFFE), .{ .rd = 1 }),
    vec("subs borrows", in(subs, 0x0002, 0, 1), .{ .rd = 0xFFFF_FFFF, .flags = 0x8000_0000 }),
    vec("rsb r0, r1, r2", in(0xEBC1, 0x0002, 3, 10), .{ .rd = 7 }),
    vec("rsbs to zero", in(0xEBD1, 0x0002, 5, 5), .{ .flags = 0x6000_0000 }),
    vec("cmp r1, r2", in(subs, 0x0F02, 5, 5), .{ .flags = 0x6000_0000 }),
    vec("cmn r1, r2", in(adds, 0x0F02, 0xFFFF_FFFF, 1), .{ .flags = 0x6000_0000 }),
    vec("add r0, sp, r2", in(0xEB0D, 0x0002, sp, 4), .{ .rd = sp + 4 }),
    vec("sub sp, sp, r2", in(0xEBAD, 0x0D02, sp, 16), .{ .rd = sp - 16 }),
    vec("Rm of sp is unclaimed", in(and_, 0x000D, 0, 0), none),
    vec("Rm of pc is unclaimed", in(and_, 0x000F, 0, 0), none),
    vec("and Rd of sp is unclaimed", in(and_, 0x0D02, 0, 0), none),
    vec("and Rn of pc is unclaimed", in(0xEA0F, 0x0002, 0, 0), none),
    vec("and Rd of pc without S is unclaimed", in(and_, 0x0F02, 0, 0), none),
    vec("tst Rn of pc is unclaimed", in(0xEA1F, 0x0F02, 0, 0), none),
    vec("mov Rd of sp is unclaimed", in(0xEA4F, 0x0D02, 0, 0), none),
    vec("mov Rd of pc is unclaimed", in(0xEA4F, 0x0F02, 0, 0), none),
    vec("adc Rn of sp is unclaimed", in(0xEB4D, 0x0002, 0, 0), none),
    vec("add Rd of pc from sp without S is unclaimed", in(0xEB0D, 0x0F02, 0, 0), none),
    vec("opcode 0101 is unclaimed", in(0xEAA1, 0x0002, 0, 0), none),
    vec("pkh belongs to its own group", in(0xEAC1, 0x0002, 0, 0), none),
    vec("opcode 1001 is unclaimed", in(0xEB21, 0x0002, 0, 0), none),
    vec("opcode 1100 is unclaimed", in(0xEB81, 0x0002, 0, 0), none),
    vec("opcode 1111 is unclaimed", in(0xEBE1, 0x0002, 0, 0), none),
    vec("a set hw2[15] is unclaimed", in(and_, 0x8002, 0, 0), none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = and_, .hw2 = 0x0002, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
