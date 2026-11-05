//! Fakes the history acceptance scenarios share: an in-memory log sink
//! and an in-memory object space (RA8EMU-1196).

const std = @import("std");
const ra8 = @import("ra8");
const recorder_mod = ra8.session.history_recorder;

/// The in-memory log storage: the recorder's committed frames land in
/// one buffer, and the walk reads it back.
pub const Sink = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn append(context: *anyopaque, data: []const u8) anyerror!void {
        const self: *Sink = @ptrCast(@alignCast(context));
        try self.bytes.appendSlice(self.gpa, data);
    }

    pub fn flush(context: *anyopaque) anyerror!void {
        _ = context;
    }

    pub fn truncate(context: *anyopaque, len: u64) anyerror!void {
        const self: *Sink = @ptrCast(@alignCast(context));
        self.bytes.shrinkRetainingCapacity(@intCast(len));
    }

    pub fn storage(self: *Sink) recorder_mod.Storage {
        return .{ .context = self, .append = append, .flush = flush, .truncate = truncate };
    }

    pub fn deinit(self: *Sink) void {
        self.bytes.deinit(self.gpa);
    }
};

/// The in-memory object space: names keep the bytes they were put with.
pub const Objects = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Named) = .empty,

    const Named = struct { name: [32]u8, bytes: []u8 };

    pub fn put(context: *anyopaque, _: @import("ra8").session.history_recorder.Objects.Kind, name: []const u8, bytes: []const u8) anyerror!void {
        const self: *Objects = @ptrCast(@alignCast(context));
        var slot: Named = .{ .name = undefined, .bytes = try self.gpa.dupe(u8, bytes) };
        @memcpy(&slot.name, name);
        try self.items.append(self.gpa, slot);
    }

    pub fn sync(context: *anyopaque) anyerror!void {
        _ = context;
    }

    pub fn objects(self: *Objects) recorder_mod.Objects {
        return .{ .context = self, .put = put, .sync = sync };
    }

    /// The bytes one name holds, or null when nothing was put under it.
    pub fn get(self: *const Objects, name: []const u8) ?[]const u8 {
        for (self.items.items) |one| {
            if (std.mem.eql(u8, &one.name, name)) return one.bytes;
        }
        return null;
    }

    pub fn deinit(self: *Objects) void {
        for (self.items.items) |one| self.gpa.free(one.bytes);
        self.items.deinit(self.gpa);
    }
};
