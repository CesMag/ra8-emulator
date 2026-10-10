//! Covers src/chip/core/cpu/conformance/base/vlldm_vlstm_t2_vectors.zig: each
//! vector runs through the `vlldm_vlstm_t2` group with the T1 test's runner.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const vectors = ra8.chip.core.cpu.conformance_base.vlldm_vlstm_t2_vectors;
const cpu_ns = ra8.chip.core.cpu;
const t1 = @import("vlldm_vlstm_vectors_test.zig");

fn run(in: vectors.In) vectors.Out {
    return t1.runWith(cpu_ns.ops.vlldm_vlstm.group_t2, in);
}

test "vlldm_vlstm_t2 matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("vlldm_vlstm_t2", name);
}
