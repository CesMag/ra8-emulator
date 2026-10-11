//! Conformance vectors for VSELEQ, VSELVS, VSELGE and VSELGT, worked from
//! the VSEL pseudocode in the Arm ARM (DDI0553): each condition both held
//! and failed (including flags that must not matter), and NaNs, signalling
//! ones included, moved as raw bits with no flags raised.
const vector = @import("../../conformance/vector.zig");
const case = @import("../case.zig");

pub const V32 = vector.Vector(case.Select(u32), case.Result(u32));
pub const V64 = vector.Vector(case.Select(u64), case.Result(u64));

pub const select32 = [_]V32{
    .{ .encoding = "VSEL", .name = "Z set takes Sn", .input = .{ .condition = .eq, .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b0100 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VSEL", .name = "Z clear takes Sm", .input = .{ .condition = .eq, .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b0000 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VSEL", .name = "only Z matters", .input = .{ .condition = .eq, .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b1011 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VSEL", .name = "V set takes Sn", .input = .{ .condition = .vs, .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b0001 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VSEL", .name = "V clear takes Sm", .input = .{ .condition = .vs, .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b1110 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VSEL", .name = "N=V=0 takes Sn", .input = .{ .condition = .ge, .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b0000 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VSEL", .name = "N=V=1 takes Sn", .input = .{ .condition = .ge, .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b1001 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VSEL", .name = "N set, V clear takes Sm", .input = .{ .condition = .ge, .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b1000 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VSEL", .name = "N clear, V set takes Sm", .input = .{ .condition = .ge, .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b0001 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VSEL", .name = "N=V, Z clear takes Sn", .input = .{ .condition = .gt, .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b0000 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VSEL", .name = "Z set takes Sm", .input = .{ .condition = .gt, .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b0100 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VSEL", .name = "N=V=1, Z clear takes Sn", .input = .{ .condition = .gt, .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b1001 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VSEL", .name = "N!=V takes Sm", .input = .{ .condition = .gt, .a = 0x3F80_0000, .b = 0x4000_0000, .nzcv = 0b1000 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VSEL", .name = "an sNaN moves untouched, no IOC", .input = .{ .condition = .eq, .a = 0x7F80_0001, .b = 0x4000_0000, .nzcv = 0b0100 }, .expect = .{ .bits = 0x7F80_0001 } },
};

pub const select64 = [_]V64{
    .{ .encoding = "VSEL", .name = "Z set takes Dn", .input = .{ .condition = .eq, .a = 0x3FF0_0000_0000_0000, .b = 0x4000_0000_0000_0000, .nzcv = 0b0100 }, .expect = .{ .bits = 0x3FF0_0000_0000_0000 } },
    .{ .encoding = "VSEL", .name = "Z clear takes Dm", .input = .{ .condition = .eq, .a = 0x3FF0_0000_0000_0000, .b = 0x4000_0000_0000_0000, .nzcv = 0b0000 }, .expect = .{ .bits = 0x4000_0000_0000_0000 } },
    .{ .encoding = "VSEL", .name = "V set takes Dn", .input = .{ .condition = .vs, .a = 0x3FF0_0000_0000_0000, .b = 0x4000_0000_0000_0000, .nzcv = 0b0001 }, .expect = .{ .bits = 0x3FF0_0000_0000_0000 } },
    .{ .encoding = "VSEL", .name = "V clear takes Dm", .input = .{ .condition = .vs, .a = 0x3FF0_0000_0000_0000, .b = 0x4000_0000_0000_0000, .nzcv = 0b1110 }, .expect = .{ .bits = 0x4000_0000_0000_0000 } },
    .{ .encoding = "VSEL", .name = "N=V=0 takes Dn", .input = .{ .condition = .ge, .a = 0x3FF0_0000_0000_0000, .b = 0x4000_0000_0000_0000, .nzcv = 0b0000 }, .expect = .{ .bits = 0x3FF0_0000_0000_0000 } },
    .{ .encoding = "VSEL", .name = "N=V=1 takes Dn", .input = .{ .condition = .ge, .a = 0x3FF0_0000_0000_0000, .b = 0x4000_0000_0000_0000, .nzcv = 0b1001 }, .expect = .{ .bits = 0x3FF0_0000_0000_0000 } },
    .{ .encoding = "VSEL", .name = "N=V, Z clear takes Dn", .input = .{ .condition = .gt, .a = 0x3FF0_0000_0000_0000, .b = 0x4000_0000_0000_0000, .nzcv = 0b0000 }, .expect = .{ .bits = 0x3FF0_0000_0000_0000 } },
    .{ .encoding = "VSEL", .name = "Z set takes Dm", .input = .{ .condition = .gt, .a = 0x3FF0_0000_0000_0000, .b = 0x4000_0000_0000_0000, .nzcv = 0b0100 }, .expect = .{ .bits = 0x4000_0000_0000_0000 } },
    .{ .encoding = "VSEL", .name = "an sNaN moves untouched, no IOC", .input = .{ .condition = .vs, .a = 0x3FF0_0000_0000_0000, .b = 0x7FF0_0000_0000_0001, .nzcv = 0b0000 }, .expect = .{ .bits = 0x7FF0_0000_0000_0001 } },
};

pub const claimed = [_][]const u8{"VSEL"};

pub const covered = vector.encodingsOf(case.Select(u32), case.Result(u32), &select32) ++
    vector.encodingsOf(case.Select(u64), case.Result(u64), &select64);
