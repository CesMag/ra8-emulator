//! Existing-file verification never mutates a collision and closes on all paths.
const std = @import("std");
const ra8 = @import("ra8");
const storage = ra8.host.history.storage;
const reuse = ra8.rpc.object_reuse;
const gpa = std.testing.allocator;

const Fake = struct {
    bytes: []const u8,
    fault: enum { none, open, length, read, sync, eof } = .none,
    closes: usize = 0,
    syncs: usize = 0,
    max_read: usize = 3,

    fn cast(ctx: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }
    fn store(self: *Fake) storage.Store {
        return .{ .context = self, .vtable = &.{ .open = open, .remove = remove, .rename = rename, .list = list } };
    }
    fn open(ctx: *anyopaque, space: ra8.host.history.layout.Space, name: []const u8, mode: storage.Mode) !storage.ByteFile {
        try std.testing.expectEqual(.objects, space);
        try std.testing.expectEqualStrings("object", name);
        try std.testing.expectEqual(.update, mode);
        if (cast(ctx).fault == .open) return error.Injected;
        return .{ .context = ctx, .vtable = &.{ .read = read, .write = write, .length = length, .truncate = truncate, .sync = sync, .close = close } };
    }
    fn read(ctx: *anyopaque, offset: u64, out: []u8) !usize {
        const self = cast(ctx);
        if (self.fault == .read) return error.Injected;
        if (self.fault == .eof) return 0;
        const at: usize = @intCast(offset);
        const count = @min(out.len, self.bytes.len - at, self.max_read);
        @memcpy(out[0..count], self.bytes[at..][0..count]);
        return count;
    }
    fn length(ctx: *anyopaque) !u64 {
        if (cast(ctx).fault == .length) return error.Injected;
        return cast(ctx).bytes.len;
    }
    fn sync(ctx: *anyopaque) !void {
        const self = cast(ctx);
        self.syncs += 1;
        if (self.fault == .sync) return error.Injected;
    }
    fn close(ctx: *anyopaque) void {
        cast(ctx).closes += 1;
    }
    fn write(_: *anyopaque, _: u64, _: []const u8) !void {
        return error.UnexpectedMutation;
    }
    fn truncate(_: *anyopaque, _: u64) !void {
        return error.UnexpectedMutation;
    }
    fn remove(_: *anyopaque, _: ra8.host.history.layout.Space, _: []const u8) !void {
        return error.UnexpectedMutation;
    }
    fn rename(_: *anyopaque, _: ra8.host.history.layout.Space, _: []const u8, _: []const u8) !void {
        return error.UnexpectedMutation;
    }
    fn list(_: *anyopaque, _: ra8.host.history.layout.Space, _: storage.Visitor) !void {
        return error.UnexpectedOperation;
    }
};

test "existing data handles short reads multiple chunks and zero bytes before syncing" {
    var bytes: [8193]u8 = @splat(42);
    var fake: Fake = .{ .bytes = &bytes };
    try reuse.existing(gpa, fake.store(), "object", .data, &bytes);
    try std.testing.expectEqual(@as(usize, 1), fake.closes);
    try std.testing.expectEqual(@as(usize, 1), fake.syncs);
    var empty: Fake = .{ .bytes = "" };
    try reuse.existing(gpa, empty.store(), "object", .data, "");
    try std.testing.expectEqual(@as(usize, 1), empty.syncs);
}

test "partial and same-size corrupted existing data are refused without repair" {
    for ([_][]const u8{ "pa", "Partial" }) |old| {
        var fake: Fake = .{ .bytes = old };
        try std.testing.expectError(error.ObjectConflict, reuse.existing(gpa, fake.store(), "object", .data, "partial"));
        try std.testing.expectEqual(@as(usize, 1), fake.closes);
        try std.testing.expectEqual(@as(usize, 0), fake.syncs);
        try std.testing.expectEqualStrings(old, fake.bytes);
    }
}

test "existing-file IO failures propagate and close once including failed sync retry" {
    const faults = [_]@FieldType(Fake, "fault"){ .open, .length, .read, .sync };
    for (faults) |fault| {
        var fake: Fake = .{ .bytes = "partial", .fault = fault };
        try std.testing.expectError(error.Injected, reuse.existing(gpa, fake.store(), "object", .data, "partial"));
        try std.testing.expectEqual(@as(usize, if (fault == .open) 0 else 1), fake.closes);
        if (fault == .sync) {
            fake.fault = .none;
            try reuse.existing(gpa, fake.store(), "object", .data, "partial");
            try std.testing.expectEqual(@as(usize, 2), fake.syncs);
            try std.testing.expectEqual(@as(usize, 2), fake.closes);
        }
    }
    var short: Fake = .{ .bytes = "partial", .fault = .eof };
    try std.testing.expectError(error.ObjectConflict, reuse.existing(gpa, short.store(), "object", .data, "partial"));
    try std.testing.expectEqual(@as(usize, 1), short.closes);
    try std.testing.expectEqual(@as(usize, 0), short.syncs);
}
