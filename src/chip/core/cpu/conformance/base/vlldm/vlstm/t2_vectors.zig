//! Conformance vectors for the decode group `vlldm_vlstm_t2` (RA8EMU-278),
//! the Armv8.1-M T2 VLLDM/VLSTM (hw2[7] set, D0-D31 in the list). Per the
//! Arm ARM (DDI0553) they move the same frame as T1 and take the same
//! checks, so the inputs and outputs are vlldm_vlstm_vectors'. Rn = PC,
//! the T1 form, hw2 bits outside T and the 16-bit space are unclaimed.
const vector = @import("../../../vector.zig");
const t1 = @import("vectors.zig");

pub const In = t1.In;
pub const Out = t1.Out;
const V = t1.V;
const a = t1.a;
const sfpa = t1.sfpa;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = "vlldm_vlstm_t2", .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("vlstm t2 stores s0-s15, fpscr and vpr", .{ .hw1 = 0xEC20, .hw2 = 0x0A80 }, .{ .m0 = t1.bankAt(0), .mfpscr = t1.fpscr_in, .mvpr = t1.vpr_in, .control = sfpa }),
    vec("vlstm t2 with ts stores s16-s31 and clears", .{ .hw1 = 0xEC20, .hw2 = 0x0A80, .ts = 1 }, .{ .m0 = t1.bankAt(0), .m16 = t1.bankAt(16), .mfpscr = t1.fpscr_in, .mvpr = t1.vpr_in, .control = sfpa, .s0 = 0, .s16 = 0, .fpscr = 0, .vpr = 0 }),
    vec("vlstm t2 with lspen arms lazy preservation", .{ .hw1 = 0xEC20, .hw2 = 0x0A80, .lspen = 1 }, .{ .control = sfpa, .lspact = 1, .fpcar = a }),
    vec("vlldm t2 loads the frame", .{ .hw1 = 0xEC30, .hw2 = 0x0A80, .control = sfpa, .ts = 1 }, .{ .s0 = t1.memAt(a), .s16 = t1.memAt(a + 0x48), .fpscr = t1.frame_fpscr, .vpr = t1.frame_vpr }),
    vec("vlldm t2 with lspact set only clears it", .{ .hw1 = 0xEC30, .hw2 = 0x0A80, .control = sfpa, .lspact = 1 }, .{}),
    vec("vlstm t2 from non-secure is undefined", .{ .hw1 = 0xEC20, .hw2 = 0x0A80, .secure = false }, .{ .fault = .undefined_instr }),
    vec("vlstm t2 with lspact set is lserr", .{ .hw1 = 0xEC20, .hw2 = 0x0A80, .lspact = 1 }, .{ .fault = .lserr, .lspact = 1 }),
    vec("rn = pc is unclaimed", .{ .hw1 = 0xEC2F, .hw2 = 0x0A80 }, t1.none),
    vec("the t1 form is not t2's", .{ .hw1 = 0xEC20, .hw2 = 0x0A00 }, t1.none),
    vec("hw2[0] set is unclaimed", .{ .hw1 = 0xEC20, .hw2 = 0x0A81 }, t1.none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEC20, .hw2 = 0x0A80, .size = 2 }, t1.none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
