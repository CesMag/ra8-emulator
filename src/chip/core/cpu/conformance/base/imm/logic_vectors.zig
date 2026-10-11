//! Conformance vectors for the decode group `imm.logic` (RA8EMU-280): AND,
//! BIC, ORR, ORN and EOR with a modified immediate, MOV and MVN (ORR and ORN
//! with Rn of PC) and TST and TEQ (ANDS and EORS with Rd of PC). Expected
//! values are worked from the Arm ARM (DDI0553): ThumbExpandImm_C gives the
//! immediate and, with S, the carry (the carry in for a byte pattern, bit 31
//! of a rotated value), N and Z follow the result and V is untouched. SP or
//! PC where the ARM calls it UNPREDICTABLE, a zero byte in a repeating
//! pattern, opcodes above EOR and the arithmetic opcodes are unclaimed.
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
const group = "imm_logic";
const none: Out = .{ .claimed = false, .flags = 0 };

/// Each opcode with Rn r1, plain and with S, and MOV/MVN (Rn of PC).
const and_ = 0xF001;
const ands = 0xF011;
const bic = 0xF021;
const bics = 0xF031;
const orr = 0xF041;
const orrs = 0xF051;
const orn = 0xF061;
const eor = 0xF081;
const eors = 0xF091;
const mov = 0xF04F;
const movs = 0xF05F;
const mvn = 0xF06F;
const mvns = 0xF07F;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn in(hw1: u16, hw2: u16, n: u32) In {
    return .{ .hw1 = hw1, .hw2 = hw2, .n = n };
}

pub const all = [_]V{
    vec("and r0, r1, #0xf0 leaves the flags", in(and_, 0x00F0, 0xFF), .{ .rd = 0xF0 }),
    vec("ands keeps the carry for a byte", in(ands, 0x000F, 0xFF), .{ .rd = 0x0F, .flags = 0x2000_0000 }),
    vec("ands to zero", in(ands, 0x000F, 0xF0), .{ .flags = 0x6000_0000 }),
    vec("ands takes C from a rotated bit 31", in(0xF411, 0x007F, 0xFFFF_FFFF), .{ .rd = 0x00FF_0000, .flags = 0 }),
    vec("bic r0, r1, #0xff", in(bic, 0x00FF, 0x1234), .{ .rd = 0x1200 }),
    vec("bics to zero", in(bics, 0x00FF, 0xFF), .{ .flags = 0x6000_0000 }),
    vec("orr with pattern 00XY00XY", in(orr, 0x10AB, 0x1100), .{ .rd = 0x00AB_11AB }),
    vec("orrs with pattern XY00XY00 is negative", in(orrs, 0x20AB, 0), .{ .rd = 0xAB00_AB00, .flags = 0xA000_0000 }),
    vec("mov r0, #0xab", in(mov, 0x00AB, 0x55), .{ .rd = 0xAB }),
    vec("movs r0, #0", in(movs, 0x0000, 0x55), .{ .flags = 0x6000_0000 }),
    vec("movs a rotated value clears C", in(0xF45F, 0x007F, 0), .{ .rd = 0x00FF_0000, .flags = 0 }),
    vec("mvn r0, #0", in(mvn, 0x0000, 0), .{ .rd = 0xFFFF_FFFF }),
    vec("mvns r0, #0xff", in(mvns, 0x00FF, 0), .{ .rd = 0xFFFF_FF00, .flags = 0xA000_0000 }),
    vec("orn r0, r1, #0xff", in(orn, 0x00FF, 0x0F), .{ .rd = 0xFFFF_FF0F }),
    vec("eor with pattern XYXYXYXY", in(eor, 0x30FF, 0x0F0F_0F0F), .{ .rd = 0xF0F0_F0F0 }),
    vec("eors to zero", in(eors, 0x0055, 0x55), .{ .flags = 0x6000_0000 }),
    vec("tst r1, #1", in(ands, 0x0F01, 2), .{ .flags = 0x6000_0000 }),
    vec("teq r1 with a rotated value clears C", in(0xF491, 0x0F7F, 0x00FF_0000), .{ .flags = 0x4000_0000 }),
    vec("and Rd of sp is unclaimed", in(and_, 0x0D01, 0), none),
    vec("and Rn of sp is unclaimed", in(0xF00D, 0x0001, 0), none),
    vec("and Rd of pc without S is unclaimed", in(and_, 0x0F01, 0), none),
    vec("bics Rd of pc is unclaimed", in(bics, 0x0F01, 0), none),
    vec("tst Rn of pc is unclaimed", in(0xF01F, 0x0F01, 0), none),
    vec("mov Rd of sp is unclaimed", in(mov, 0x0D01, 0), none),
    vec("mov Rd of pc is unclaimed", in(mov, 0x0F01, 0), none),
    vec("a zero byte in a pattern is unclaimed", in(and_, 0x1000, 0), none),
    vec("opcode 0101 is unclaimed", in(0xF0A1, 0x0001, 0), none),
    vec("add belongs to imm.arith", in(0xF101, 0x0001, 0), none),
    vec("a set hw2[15] is unclaimed", in(and_, 0x8001, 0), none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = and_, .hw2 = 0x0001, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
