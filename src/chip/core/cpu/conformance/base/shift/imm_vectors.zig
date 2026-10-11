//! Conformance vectors for the decode group `shift_imm` (RA8EMU-279): the
//! 16-bit LSL, LSR and ASR by an immediate, and MOV Rd, Rm (T2, LSL #0).
//! Each expected value is worked from Shift_C() and DecodeImmShift() in the
//! Arm ARM (DDI0553): LSR and ASR #0 shift by 32, the carry out is the last
//! bit shifted out, LSL #0 keeps C, and inside an IT block the flags stay
//! as they were.
const vector = @import("../../vector.zig");

/// The instruction, the value in its Rm, and NZCV and ITSTATE beforehand.
pub const In = struct {
    hw1: u16,
    rm: u32,
    nzcv: u4 = 0,
    it: u8 = 0,
};

/// Rd and NZCV afterwards.
pub const Out = struct {
    rd: u32,
    nzcv: u4,
};

const V = vector.Vector(In, Out);
const group = "shift_imm";

const n: u4 = 0b1000;
const z: u4 = 0b0100;
const c: u4 = 0b0010;
const v: u4 = 0b0001;

pub const all = [_]V{
    .{ .encoding = group, .name = "lsls r0, r1, #1: bit 31 into C", .input = .{ .hw1 = 0x0048, .rm = 0xC000_0000 }, .expect = .{ .rd = 0x8000_0000, .nzcv = n | c } },
    .{ .encoding = group, .name = "lsls r0, r1, #31: carry is bit 1", .input = .{ .hw1 = 0x07C8, .rm = 0x0000_0003 }, .expect = .{ .rd = 0x8000_0000, .nzcv = n | c } },
    .{ .encoding = group, .name = "lsls r0, r1, #4: carry is bit 28", .input = .{ .hw1 = 0x0108, .rm = 0x0FFF_FFFF, .nzcv = c }, .expect = .{ .rd = 0xFFFF_FFF0, .nzcv = n } },
    .{ .encoding = group, .name = "lsls r1, r1, #1: Rd is Rm", .input = .{ .hw1 = 0x0049, .rm = 0x4000_0001 }, .expect = .{ .rd = 0x8000_0002, .nzcv = n } },
    .{ .encoding = group, .name = "movs r0, r1: Z set, C and V kept", .input = .{ .hw1 = 0x0008, .rm = 0, .nzcv = c | v }, .expect = .{ .rd = 0, .nzcv = z | c | v } },
    .{ .encoding = group, .name = "movs r0, r1: N set, C clear kept", .input = .{ .hw1 = 0x0008, .rm = 0x8000_0000 }, .expect = .{ .rd = 0x8000_0000, .nzcv = n } },
    .{ .encoding = group, .name = "lsrs r0, r1, #1: bit 0 into C", .input = .{ .hw1 = 0x0848, .rm = 1 }, .expect = .{ .rd = 0, .nzcv = z | c } },
    .{ .encoding = group, .name = "lsrs r0, r1, #4: carry is bit 3", .input = .{ .hw1 = 0x0908, .rm = 0xF000_0008 }, .expect = .{ .rd = 0x0F00_0000, .nzcv = c } },
    .{ .encoding = group, .name = "lsrs #0 is #32: bit 31 into C", .input = .{ .hw1 = 0x0808, .rm = 0x8000_0000 }, .expect = .{ .rd = 0, .nzcv = z | c } },
    .{ .encoding = group, .name = "lsrs #32 with bit 31 clear", .input = .{ .hw1 = 0x0808, .rm = 0x7FFF_FFFF, .nzcv = c }, .expect = .{ .rd = 0, .nzcv = z } },
    .{ .encoding = group, .name = "asrs r0, r1, #1: sign kept", .input = .{ .hw1 = 0x1048, .rm = 0x8000_0001 }, .expect = .{ .rd = 0xC000_0000, .nzcv = n | c } },
    .{ .encoding = group, .name = "asrs r0, r1, #31: carry is bit 30", .input = .{ .hw1 = 0x17C8, .rm = 0x4000_0000 }, .expect = .{ .rd = 0, .nzcv = z | c } },
    .{ .encoding = group, .name = "asrs #0 is #32 on a negative", .input = .{ .hw1 = 0x1008, .rm = 0x8000_0000 }, .expect = .{ .rd = 0xFFFF_FFFF, .nzcv = n | c } },
    .{ .encoding = group, .name = "asrs #32 on a positive", .input = .{ .hw1 = 0x1008, .rm = 0x4000_0000, .nzcv = c }, .expect = .{ .rd = 0, .nzcv = z } },
    .{ .encoding = group, .name = "lsl in an IT block leaves NZCV", .input = .{ .hw1 = 0x0048, .rm = 0xC000_0000, .nzcv = v, .it = 0x08 }, .expect = .{ .rd = 0x8000_0000, .nzcv = v } },
    .{ .encoding = group, .name = "asr #32 in an IT block leaves NZCV", .input = .{ .hw1 = 0x1008, .rm = 0x8000_0000, .nzcv = z, .it = 0x08 }, .expect = .{ .rd = 0xFFFF_FFFF, .nzcv = z } },
};

pub const covered = vector.encodingsOf(In, Out, &all);
