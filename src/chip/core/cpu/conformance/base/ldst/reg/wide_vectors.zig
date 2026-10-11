//! Conformance vectors for the decode group `ldst_reg_wide` (RA8EMU-278):
//! STR/STRH/STRB, LDR/LDRH/LDRB and LDRSB/LDRSH [Rn, Rm, LSL #imm2] (T2).
//! Expected values are worked from the Arm ARM (DDI0553): the address is
//! Rn + (Rm << imm2) modulo 2^32 with no writeback, bytes and halfwords
//! zero- or sign-extend, an unaligned word goes through as bytes with
//! CCR.UNALIGN_TRP clear, LDR into PC branches with interworking, and an
//! access outside memory faults with Rt kept. Rn = PC, Rm of SP or PC, a
//! store of PC, a narrow Rt of SP or PC, hw2[11:6] non-zero, the opcode
//! values outside the eight forms and the 16-bit space are left unclaimed.
const vector = @import("../../../vector.zig");

/// Rn = r0 points at `base`; Rt = r1 holds `src`; Rm = r2 holds In.rm; the
/// word placed at `at` is `literal` (bytes A9 C3 65 87) unless `lit` says.
pub const base: u32 = 0x2000_0200;
pub const src: u32 = 0x1122_3344;
pub const fill: u32 = 0x5555_5555;
pub const literal: u32 = 0x8765_C3A9;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    rm: u32 = 1,
    at: u32 = 0,
    lit: u32 = literal,
    /// The word read back after the instruction (0 for none).
    probe: u32 = 0,
};

/// How the instruction ended.
pub const Fault = enum { none, unmapped, other };

/// Whether the group claims the encoding, how it ended, Rt afterwards (SP
/// for 13, the PC for 15) and the probed word.
pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    rt: u32 = src,
    mem: u32 = 0,
};

const V = vector.Vector(In, Out);
const group = "ldst_reg_wide";
const none: Out = .{ .claimed = false, .rt = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn ld(name: []const u8, hw1: u16, hw2: u16, rm: u32, at: u32, rt: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2, .rm = rm, .at = at }, .{ .rt = rt });
}

fn st(name: []const u8, hw1: u16, hw2: u16, rm: u32, at: u32, probe: u32, mem: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2, .rm = rm, .at = at, .probe = probe }, .{ .mem = mem });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = loads ++ stores ++ unclaimed;

const loads = [_]V{
    ld("ldr.w r1, [r0, r2, lsl #2]", 0xF850, 0x1022, 1, 0x2000_0204, literal),
    ld("ldr.w r1, [r0, r2, lsl #3]", 0xF850, 0x1032, 1, 0x2000_0208, literal),
    ld("ldr.w r1, [r0, r2] unaligned goes through as bytes", 0xF850, 0x1002, 1, 0x2000_0200, 0x0087_65C3),
    ld("ldr.w with a negative rm wraps below rn", 0xF850, 0x1022, 0xFFFF_FFFF, 0x2000_01FC, literal),
    ld("ldrb.w r1, [r0, r2, lsl #2]", 0xF810, 0x1022, 1, 0x2000_0204, 0xA9),
    ld("ldrb.w r1, [r0, r2] reads byte 1", 0xF810, 0x1002, 5, 0x2000_0204, 0xC3),
    ld("ldrh.w r1, [r0, r2, lsl #1] reads the high half", 0xF830, 0x1012, 3, 0x2000_0204, 0x8765),
    ld("ldrsb.w r1, [r0, r2, lsl #2] sign-extends", 0xF910, 0x1022, 1, 0x2000_0204, 0xFFFF_FFA9),
    ld("ldrsb.w r1, [r0, r2] keeps a positive byte", 0xF910, 0x1002, 6, 0x2000_0204, 0x65),
    ld("ldrsh.w r1, [r0, r2, lsl #2] sign-extends", 0xF930, 0x1022, 1, 0x2000_0204, 0xFFFF_C3A9),
    vec("ldrsh.w keeps a positive half", .{ .hw1 = 0xF930, .hw2 = 0x1022, .at = 0x2000_0204, .lit = 0x1234_5678 }, .{ .rt = 0x5678 }),
    vec("ldr.w pc branches to the Thumb target", .{ .hw1 = 0xF850, .hw2 = 0xF022, .at = 0x2000_0204, .lit = 0x2000_0301 }, .{ .rt = 0x2000_0300 }),
    vec("ldr.w sp loads sp", .{ .hw1 = 0xF850, .hw2 = 0xD022, .at = 0x2000_0204, .lit = 0x2000_0300 }, .{ .rt = 0x2000_0300 }),
    vec("ldr.w past RAM faults and keeps rt", .{ .hw1 = 0xF850, .hw2 = 0x1002, .rm = 0x1000 }, .{ .fault = .unmapped }),
    vec("ldrh.w past RAM faults and keeps rt", .{ .hw1 = 0xF830, .hw2 = 0x1032, .rm = 0x200 }, .{ .fault = .unmapped }),
};

const stores = [_]V{
    st("str.w r1, [r0, r2, lsl #2]", 0xF840, 0x1022, 1, 0, 0x2000_0204, src),
    st("strb.w r1, [r0, r2] writes one byte", 0xF800, 0x1002, 5, 0x2000_0204, 0x2000_0204, 0x8765_44A9),
    st("strb.w r1, [r0, r2, lsl #3]", 0xF800, 0x1032, 1, 0, 0x2000_0208, 0x44),
    st("strh.w r1, [r0, r2, lsl #1] writes the high half", 0xF820, 0x1012, 3, 0x2000_0204, 0x2000_0204, 0x3344_C3A9),
    st("str.w unaligned goes through as bytes", 0xF840, 0x1002, 1, 0, 0x2000_0200, 0x2233_4400),
    st("str.w with a negative rm wraps below rn", 0xF840, 0x1022, 0xFFFF_FFFF, 0, 0x2000_01FC, src),
    vec("str.w sp stores sp", .{ .hw1 = 0xF840, .hw2 = 0xD022, .probe = 0x2000_0204 }, .{ .rt = fill & ~@as(u32, 3), .mem = fill & ~@as(u32, 3) }),
    vec("str.w past RAM faults", .{ .hw1 = 0xF840, .hw2 = 0x1002, .rm = 0x1000 }, .{ .fault = .unmapped }),
};

const unclaimed = [_]V{
    bad("rn = pc is the literal group", 0xF85F, 0x1022),
    bad("rm = sp is unclaimed", 0xF850, 0x102D),
    bad("rm = pc is unclaimed", 0xF850, 0x102F),
    bad("a store of pc is unclaimed", 0xF840, 0xF022),
    bad("ldrb with rt = pc is pld", 0xF810, 0xF022),
    bad("ldrb into sp is unclaimed", 0xF810, 0xD022),
    bad("strh of sp is unclaimed", 0xF820, 0xD022),
    bad("ldrsh with rt = pc is unclaimed", 0xF930, 0xF022),
    bad("hw2[6] set is unclaimed", 0xF850, 0x1042),
    bad("hw2[11] set is the imm8 space", 0xF850, 0x1822),
    bad("size 11 is unclaimed", 0xF860, 0x1022),
    bad("a signed word is unclaimed", 0xF950, 0x1022),
    bad("a signed store is unclaimed", 0xF900, 0x1022),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xF850, .hw2 = 0x1022, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
