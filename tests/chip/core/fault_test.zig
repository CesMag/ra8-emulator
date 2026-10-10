//! The faulting access and the latch the hook records it in.
const std = @import("std");
const ra8 = @import("ra8");

const fault = ra8.chip.core.fault;

test "a fresh watch has caught nothing" {
    const watch = fault.Watch{};
    try std.testing.expect(watch.last == null);
}

test "clearing a watch drops the access it was holding" {
    var watch = fault.Watch{ .last = .{ .kind = .write, .address = 0x4013_C004, .size = 4, .value = 250 } };
    watch.clear();
    try std.testing.expect(watch.last == null);
}

test "a watch keeps every part of the access the hook saw" {
    var watch = fault.Watch{};
    watch.last = .{ .kind = .fetch, .address = 0x0200_16AA, .size = 2, .value = 0 };
    const seen = watch.last.?;
    try std.testing.expectEqual(@as(u64, 0x0200_16AA), seen.address);
    try std.testing.expectEqual(@as(u8, 2), seen.size);
    try std.testing.expect(seen.kind == .fetch);
}

test "a fault carries no access until one is found" {
    const taken = fault.Fault{ .pc = 0x0200_0910, .detail = "unmapped" };
    try std.testing.expect(taken.access == null);
}
