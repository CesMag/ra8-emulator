//! Conformance vectors for the MVE vector-base gather/scatter addresses
//! (gather.vectorAddress), worked from the Arm ARM (DDI0553) pseudocode
//! by /workspace/tools/mve_gather_imm.py on the lane's box.
const vector = @import("../../conformance/vector.zig");
const gather = @import("gather.zig");

const V = vector.Vector(gather.VectorBase, u32);

pub const vectors = [_]V{
    .{ .encoding = "VLDRW.U32 vector base", .name = "add", .input = .{ .element = 0x20000000, .imm7 = 2, .add = true, .double = false }, .expect = 0x20000008 },
    .{ .encoding = "VLDRW.U32 vector base", .name = "subtract", .input = .{ .element = 0x20000010, .imm7 = 1, .add = false, .double = false }, .expect = 0x2000000C },
    .{ .encoding = "VLDRW.U32 vector base", .name = "imm 127", .input = .{ .element = 0x20000000, .imm7 = 127, .add = true, .double = false }, .expect = 0x200001FC },
    .{ .encoding = "VLDRD.U64 vector base", .name = "add", .input = .{ .element = 0x20000000, .imm7 = 2, .add = true, .double = true }, .expect = 0x20000010 },
    .{ .encoding = "VLDRD.U64 vector base", .name = "subtract wraps", .input = .{ .element = 0x4, .imm7 = 1, .add = false, .double = true }, .expect = 0xFFFFFFFC },
    .{ .encoding = "VSTRW.32 vector base", .name = "add", .input = .{ .element = 0x20000040, .imm7 = 3, .add = true, .double = false }, .expect = 0x2000004C },
    .{ .encoding = "VSTRW.32 vector base", .name = "add wraps", .input = .{ .element = 0xFFFFFFFC, .imm7 = 1, .add = true, .double = false }, .expect = 0x0 },
    .{ .encoding = "VSTRD.64 vector base", .name = "subtract", .input = .{ .element = 0x20000020, .imm7 = 2, .add = false, .double = true }, .expect = 0x20000010 },
    .{ .encoding = "VSTRD.64 vector base", .name = "imm 127", .input = .{ .element = 0x20000000, .imm7 = 127, .add = true, .double = true }, .expect = 0x200003F8 },
};

pub const claimed = [_][]const u8{ "VLDRW.U32 vector base", "VLDRD.U64 vector base", "VSTRW.32 vector base", "VSTRD.64 vector base" };

pub const covered = vector.encodingsOf(gather.VectorBase, u32, &vectors);
