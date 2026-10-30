//! Persisted dual roots and reopen startup use both initial images.
const std = @import("std");
const ra8 = @import("ra8");
const rig = @import("regression_rig.zig");
const gpa = std.testing.allocator;

test "dual reopen preserves frozen root and the initial checkpoint" {
    const recorded = try rig.Recorded.openDual(gpa, 3);
    defer recorded.close(gpa);
    const before = try recorded.rootBytes(gpa);
    defer gpa.free(before);
    const root = try ra8.session.history_root.decode(before);
    {
        var served: ra8.rpc.served_setup.Served = undefined;
        try served.openInitial(gpa, std.testing.io, "absent-original-cpu0.elf", null, .{ .root = recorded.root, .reopen = recorded.sessionName(), .elf_bytes = root.elf0.bytes }, .{ .bytes = root.elf1.?.bytes });
        defer served.deinit();
        try std.testing.expect(served.second != null);
        try std.testing.expect(served.owner.session().persistent_recorder != null);
        const bridge = served.owner.transport().history.?;
        const facts = try bridge.facts(bridge.context);
        try std.testing.expectEqual(@as(usize, 3), facts.checkpoints.len);
        try std.testing.expectEqual(@as(u64, 0), served.owner.session().currentPosition().r);
        try std.testing.expectEqual(@as(u64, 0), served.second.?.cpu().slots);
        try std.testing.expectError(error.SecondCoreAlreadyOpen, served.openSecond("absent-original-cpu1.elf"));
    }
    const after = try recorded.rootBytes(gpa);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

test "reopen cannot silently add or remove CPU1 or replace a missing root" {
    const recorded = try rig.Recorded.openDual(gpa, 3);
    defer recorded.close(gpa);
    const before = try recorded.rootBytes(gpa);
    defer gpa.free(before);
    var served: ra8.rpc.served_setup.Served = undefined;
    try std.testing.expectError(error.ImageMismatch, served.open(gpa, std.testing.io, rig.dual_image, null, .{ .root = recorded.root, .reopen = recorded.sessionName() }));
    const after = try recorded.rootBytes(gpa);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try recorded.writeFile("root.bin", "invalid root");
    try std.testing.expectError(error.NoRoot, served.open(gpa, std.testing.io, rig.dual_image, null, .{ .root = recorded.root, .reopen = recorded.sessionName() }));
    const invalid = try recorded.rootBytes(gpa);
    defer gpa.free(invalid);
    try std.testing.expectEqualStrings("invalid root", invalid);
}
