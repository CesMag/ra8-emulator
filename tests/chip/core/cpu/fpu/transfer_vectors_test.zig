const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const transfer = ra8.chip.core.cpu.fpu.transfer;
const vectors = ra8.chip.core.cpu.fpu.transfer_vectors;

test "VLDM, VSTM, VPUSH and VPOP match the pseudocode" {
    try vector.expectAll(transfer.Multiple, transfer.Plan, transfer.multiple, &vectors.multiple);
}

test "VLDR and VSTR match the pseudocode" {
    try vector.expectAll(transfer.Single, transfer.Plan, transfer.single, &vectors.single);
}

test "VPUSH and VPOP vectors use SP with writeback" {
    for (vectors.multiple) |v| {
        if (!std.mem.startsWith(u8, v.encoding, "VPUSH") and !std.mem.startsWith(u8, v.encoding, "VPOP")) continue;
        try std.testing.expectEqual(@as(u4, 13), v.input.rn);
        try std.testing.expectEqual(@as(u1, 1), v.input.w);
    }
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.multiple.len + vectors.single.len, vectors.covered.len);
}
