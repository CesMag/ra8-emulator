const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const fpu = ra8.chip.core.cpu.fpu;
const case = fpu.case;
const vectors = fpu.select.vectors;
const Cond = fpu.select.Cond;

fn expectAll(comptime B: type, list: []const vector.Vector(case.Select(B), case.Result(B))) !void {
    for (list) |v| {
        const got = fpu.select.select(B, v.input.condition, v.input.nzcv, v.input.a, v.input.b);
        std.testing.expectEqual(v.expect.bits, got) catch |err| {
            std.debug.print("conformance: {s} ({s})\n", .{ v.encoding, v.name });
            return err;
        };
        try std.testing.expectEqual(@as(u32, 0), v.expect.flags);
    }
}

test "VSEL .F32 matches the pseudocode" {
    try expectAll(u32, &vectors.select32);
}

test "VSEL .F64 matches the pseudocode" {
    try expectAll(u64, &vectors.select64);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.select32.len + vectors.select64.len, vectors.covered.len);
}
