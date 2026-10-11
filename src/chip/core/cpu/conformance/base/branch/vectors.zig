//! Conformance vectors for the decode group `branch` (RA8EMU-279): 16-bit
//! B<cond> (T1) and B (T2). Each expected value is worked from the Arm ARM
//! (DDI0553): the target is the instruction address plus 4 plus
//! SignExtend(imm8:'0') or SignExtend(imm11:'0'), the T1 branch is taken
//! only when ConditionPassed() holds for NZCV, and conditions 0b1110 and
//! 0b1111 of the T1 space (UDF, SVC) are not branches.
const vector = @import("../../vector.zig");

/// The instruction at `address` and NZCV beforehand.
pub const In = struct {
    hw1: u16,
    nzcv: u4 = 0,
};

/// Whether the group claims the encoding, then the PC afterwards.
pub const Out = struct {
    claimed: bool = true,
    pc: u32 = 0,
};

pub const address: u32 = 0x1000;
pub const next: u32 = address + 2;

const V = vector.Vector(In, Out);
const group = "branch";

const n: u4 = 0b1000;
const z: u4 = 0b0100;
const c: u4 = 0b0010;
const v: u4 = 0b0001;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("b +0 lands at address + 4", .{ .hw1 = 0xE000 }, .{ .pc = 0x1004 }),
    vec("b to itself", .{ .hw1 = 0xE7FE }, .{ .pc = 0x1000 }),
    vec("b furthest forward, +2046", .{ .hw1 = 0xE3FF }, .{ .pc = 0x1802 }),
    vec("b furthest back, -2048", .{ .hw1 = 0xE400 }, .{ .pc = 0x0804 }),
    vec("beq taken on Z", .{ .hw1 = 0xD001, .nzcv = z }, .{ .pc = 0x1006 }),
    vec("beq not taken", .{ .hw1 = 0xD001 }, .{ .pc = next }),
    vec("bne taken", .{ .hw1 = 0xD101 }, .{ .pc = 0x1006 }),
    vec("bcs furthest forward, +254", .{ .hw1 = 0xD27F, .nzcv = c }, .{ .pc = 0x1102 }),
    vec("bmi furthest back, -256", .{ .hw1 = 0xD480, .nzcv = n }, .{ .pc = 0x0F04 }),
    vec("bvs not taken", .{ .hw1 = 0xD610 }, .{ .pc = next }),
    vec("bhi taken on C and not Z", .{ .hw1 = 0xD810, .nzcv = c }, .{ .pc = 0x1024 }),
    vec("bhi not taken with Z", .{ .hw1 = 0xD810, .nzcv = c | z }, .{ .pc = next }),
    vec("bge taken on N == V", .{ .hw1 = 0xDA00, .nzcv = n | v }, .{ .pc = 0x1004 }),
    vec("blt taken on N != V", .{ .hw1 = 0xDB00, .nzcv = n }, .{ .pc = 0x1004 }),
    vec("bgt not taken with Z", .{ .hw1 = 0xDC00, .nzcv = z }, .{ .pc = next }),
    vec("ble taken with Z", .{ .hw1 = 0xDD00, .nzcv = z }, .{ .pc = 0x1004 }),
    vec("cond 0b1110 is UDF, not a branch", .{ .hw1 = 0xDE00 }, .{ .claimed = false }),
    vec("cond 0b1111 is SVC, not a branch", .{ .hw1 = 0xDF00 }, .{ .claimed = false }),
};

pub const covered = vector.encodingsOf(In, Out, &all);
