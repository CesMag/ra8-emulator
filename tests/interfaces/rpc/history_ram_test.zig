//! Tests for src/interfaces/rpc/history_ram.zig (RA8EMU-1196): the
//! RAM-only history serves the recorder's log storage and object space
//! from allocator-owned bytes, capped by the share the application
//! passes, and nothing it writes touches a disk.
const std = @import("std");
const ram_mod = @import("ra8").rpc.history_ram;

test "the RAM history takes the log's appends and answers the share's remainder" {
    const gpa = std.testing.allocator;
    const share: u64 = 1024;
    const ram = try ram_mod.RamHistory.open(gpa, share);
    defer ram.deinit();
    try std.testing.expectEqual(share, ram.budget.cap);
    try std.testing.expectEqual(@as(u64, 0), ram.budget.floor);
    try std.testing.expectEqual(@as(u64, share), try ram.budget.free(ram.budget.context));

    try ram.storage.append(ram.storage.context, "first frame");
    try ram.storage.append(ram.storage.context, " second");
    try ram.storage.flush(ram.storage.context);
    try std.testing.expectEqualStrings("first frame second", ram.log_bytes.items);
    try std.testing.expectEqual(@as(u64, 18), ram.used());
    try std.testing.expectEqual(@as(u64, share - 18), try ram.budget.free(ram.budget.context));

    try ram.storage.truncate(ram.storage.context, 5);
    try std.testing.expectEqualStrings("first", ram.log_bytes.items);
    try std.testing.expectEqual(@as(u64, 5), ram.used());
}

test "the RAM history keeps objects under their names" {
    const gpa = std.testing.allocator;
    const ram = try ram_mod.RamHistory.open(gpa, 4096);
    defer ram.deinit();
    try ram.object_space.put(ram.object_space.context, .data, "0123456789abcdef0123456789abcdef", "checkpoint bytes");
    try ram.object_space.sync(ram.object_space.context);
    try std.testing.expectEqualStrings("checkpoint bytes", ram.get("0123456789abcdef0123456789abcdef").?);
    try std.testing.expect(ram.get("ffffffffffffffffffffffffffffffff") == null);
    try std.testing.expectEqual(@as(u64, 16), ram.used());
}

test "the share's remainder never dips below zero" {
    const gpa = std.testing.allocator;
    const ram = try ram_mod.RamHistory.open(gpa, 8);
    defer ram.deinit();
    try ram.storage.append(ram.storage.context, "way more than eight");
    try std.testing.expectEqual(@as(u64, 0), try ram.budget.free(ram.budget.context));
}

test "RAM object reuse retains first bytes without duplicate allocation or collision acceptance" {
    const ram = try ram_mod.RamHistory.open(std.testing.allocator, 4096);
    defer ram.deinit();
    const name = "0123456789abcdef0123456789abcdef";
    try ram.object_space.put(ram.object_space.context, .data, name, "original");
    try ram.object_space.put(ram.object_space.context, .data, name, "original");
    try std.testing.expectEqual(@as(u64, 8), ram.used());
    try std.testing.expectError(error.ObjectConflict, ram.object_space.put(ram.object_space.context, .data, name, "Original"));
    try std.testing.expectEqualStrings("original", ram.get(name).?);
    try std.testing.expectEqual(@as(u64, 8), ram.used());
}
