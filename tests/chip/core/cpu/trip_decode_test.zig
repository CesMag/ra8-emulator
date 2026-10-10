//! Covers src/chip/core/cpu/trip_decode.zig. The encodings are GNU as 13.3
//! output, most of them read off the two bounded polls RA8EMU-602 is for.
const std = @import("std");
const ra8 = @import("ra8");
const td = ra8.chip.core.cpu.cpu.trip_decode;

fn one(hw1: u16, hw2: u16) td.Step {
    return td.decode(hw1, hw2);
}

fn expectStep(want: td.Step, got: td.Step) !void {
    try std.testing.expectEqualDeep(want, got);
}

test "narrow loads and stores name rt, the base, the offset and the size" {
    try expectStep(.{ .form = .store, .rd = 0, .rn = 7, .imm = 16 }, one(0x6138, 0));
    try expectStep(.{ .form = .load, .rd = 3, .rn = 7, .imm = 16 }, one(0x693B, 0));
    try expectStep(.{ .form = .load, .rd = 2, .rn = 15, .imm = 12 }, one(0x4A03, 0));
    try expectStep(.{ .form = .load, .rd = 1, .rn = 2, .imm = 3, .size = 1 }, one(0x78D1, 0));
    try expectStep(.{ .form = .store, .rd = 1, .rn = 2, .imm = 6, .size = 2 }, one(0x80D1, 0));
    try expectStep(.{ .form = .load, .rd = 3, .rn = 5, .imm = 4 }, one(0x686B, 0));
}

test "narrow moves, adds and compares, and which of them set the flags" {
    try expectStep(.{ .form = .move, .rd = 0, .rm = 3 }, one(0x4618, 0));
    try expectStep(.{ .form = .move, .rd = 13, .rm = 7 }, one(0x46BD, 0));
    try expectStep(.{ .form = .move, .rd = 1, .rm = 2, .sets_flags = true }, one(0x0011, 0));
    try expectStep(.{ .form = .move, .rd = 3, .imm = 0, .sets_flags = true }, one(0x2300, 0));
    try expectStep(.{ .form = .add, .rd = 3, .rn = 3, .imm = 12, .sets_flags = true }, one(0x330C, 0));
    try expectStep(.{ .form = .add, .rd = 0, .rn = 0, .imm = 1, .sets_flags = true }, one(0x3001, 0));
    try expectStep(.{ .form = .sub, .rd = 13, .rn = 13, .imm = 12 }, one(0xB083, 0));
    try expectStep(.{ .form = .add, .rd = 7, .rn = 13, .imm = 0 }, one(0xAF00, 0));
    try expectStep(.{ .form = .compare, .rn = 3, .imm = 9, .sets_flags = true }, one(0x2B09, 0));
    try expectStep(.{ .form = .compare, .rn = 2, .rm = 3, .sets_flags = true }, one(0x429A, 0));
    try expectStep(.{ .form = .compare, .rn = 1, .rm = 0, .sets_flags = true }, one(0x4281, 0));
}

test "TST and ANDS are opaque, and only ANDS writes" {
    try expectStep(.{ .form = .opaque_alu, .rn = 1, .rm = 2, .sets_flags = true }, one(0x4211, 0));
    try expectStep(.{ .form = .opaque_alu, .rd = 1, .rn = 1, .rm = 2, .sets_flags = true }, one(0x4011, 0));
}

test "narrow control: branches, CBNZ, BX, push, pop and hints" {
    try expectStep(.{ .form = .cond_branch, .reads_flags = true }, one(0xD9E4, 0));
    try expectStep(.{ .form = .cond_branch, .reads_flags = true }, one(0xD00A, 0));
    try expectStep(.{ .form = .branch }, one(0xE007, 0));
    try expectStep(.{ .form = .cbz, .rn = 1 }, one(0xB909, 0));
    try expectStep(.{ .form = .bx, .rm = 14 }, one(0x4770, 0));
    try expectStep(.{ .form = .push, .imm = 0x80 }, one(0xB480, 0));
    try expectStep(.{ .form = .pop, .imm = 0x8080 }, one(0xBD80, 0));
    try expectStep(.{ .form = .hint }, one(0xBF00, 0));
    try expectStep(.{ .form = .hint }, one(0xB672, 0));
    try expectStep(.{ .form = .hint }, one(0xB662, 0));
}

test "wide forms bounded polls use" {
    try expectStep(.{ .form = .call, .len = 4 }, one(0xF7FF, 0xFFC5));
    try expectStep(.{ .form = .load, .len = 4, .rd = 7, .rn = 13, .imm = 4, .writeback = true, .post_index = true }, one(0xF85D, 0x7B04));
    try expectStep(.{ .form = .load, .len = 4, .rd = 1, .rn = 2, .imm = 0 -% @as(u32, 8), .writeback = true }, one(0xF852, 0x1D08));
    try expectStep(.{ .form = .store, .len = 4, .rd = 3, .rn = 13, .imm = 0 -% @as(u32, 4), .writeback = true }, one(0xF84D, 0x3D04));
    try expectStep(.{ .form = .store, .len = 4, .rd = 7, .rn = 8, .imm = 0xD04 }, one(0xF8C8, 0x7D04));
    try expectStep(.{ .form = .opaque_alu, .len = 4, .rd = 3, .rn = 3 }, one(0xF403, 0x3380));
    try expectStep(.{ .form = .compare, .len = 4, .rn = 3, .imm = 0x10000, .sets_flags = true }, one(0xF5B3, 0x3F80));
    try expectStep(.{ .form = .move, .len = 4, .rd = 2, .imm = 0x423F }, one(0xF244, 0x223F));
    try expectStep(.{ .form = .move, .len = 4, .rd = 7, .imm = 0x0800_0000 }, one(0xF04F, 0x6700));
    try expectStep(.{ .form = .add, .len = 4, .rd = 1, .rn = 2, .imm = 0x100 }, one(0xF502, 0x7180));
    try expectStep(.{ .form = .sub, .len = 4, .rd = 4, .rn = 4, .imm = 1, .sets_flags = true }, one(0xF1B4, 0x0401));
    try expectStep(.{ .form = .add, .len = 4, .rd = 5, .rn = 6, .imm = 0x123 }, one(0xF206, 0x1523));
}

test "IT, SVC, UDF and other encodings stay unknown" {
    for ([_]u16{ 0xBF08, 0xDF00, 0xDE00, 0x4380 }) |hw| {
        try std.testing.expectEqual(td.Form.unknown, one(hw, 0).form);
    }
    try std.testing.expectEqual(td.Form.unknown, one(0xF3EF, 0x8009).form);
    try std.testing.expectEqual(td.Form.unknown, one(0xF85F, 0x1004).form);
}
