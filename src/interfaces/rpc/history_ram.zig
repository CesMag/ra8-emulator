//! The RAM-only history a served session records through when it keeps
//! no history root (`--history off`): the same recorder interfaces the
//! disk bind answers, backed by allocator-owned bytes and capped by the
//! application's RAM share, so an off history keeps its checkpoint and
//! window ability while nothing it writes lands on the host's disk
//! (RA8EMU-1196).
const std = @import("std");
const session_recorder = @import("ra8_session").history_recorder;
const object_reuse = @import("ra8_session").history_object_reuse;

/// A checkpoint object's stored bytes, keyed by its 32-character name.
const Named = struct { name: [32]u8, bytes: []u8 };

/// The recorder's host side for a history that never touches the disk.
/// Its budget answers with this history's own remaining share the way a
/// volume watch would answer with the volume's, so the recorder's usual
/// checks refuse at the share's edge and warn at 80% of it.
pub const RamHistory = struct {
    gpa: std.mem.Allocator,
    /// The RAM share this history may take, the budget's cap.
    share: u64,
    log_bytes: std.ArrayList(u8) = .empty,
    objects: std.ArrayList(Named) = .empty,
    /// The shapes the harness's open options take; all point into this
    /// history, which stays put until deinit.
    storage: session_recorder.Storage = undefined,
    object_space: session_recorder.Objects = undefined,
    budget: session_recorder.Budget = undefined,

    /// Open a RAM-only history under `share` bytes, the application's
    /// RAM share for this session (the host budget's ram answer).
    pub fn open(gpa: std.mem.Allocator, share: u64) !*RamHistory {
        const self = try gpa.create(RamHistory);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .share = share };
        self.storage = .{ .context = self, .append = &appendLog, .flush = &flushLog, .truncate = &truncateLog };
        self.object_space = .{ .context = self, .put = &putObject, .sync = &syncObjects };
        self.budget = .{ .context = self, .free = &freeRam, .cap = share, .floor = 0, .relief = null };
        return self;
    }

    pub fn deinit(self: *RamHistory) void {
        self.log_bytes.deinit(self.gpa);
        for (self.objects.items) |one| self.gpa.free(one.bytes);
        self.objects.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// The bytes this history holds, its log and its objects together.
    pub fn used(self: *const RamHistory) u64 {
        var total: u64 = self.log_bytes.items.len;
        for (self.objects.items) |one| total += one.bytes.len;
        return total;
    }

    /// The bytes one name holds, or null when nothing was put under it.
    pub fn get(self: *const RamHistory, name: []const u8) ?[]const u8 {
        for (self.objects.items) |one| {
            if (std.mem.eql(u8, &one.name, name)) return one.bytes;
        }
        return null;
    }

    fn appendLog(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *RamHistory = @ptrCast(@alignCast(context));
        try self.log_bytes.appendSlice(self.gpa, bytes);
    }

    fn flushLog(context: *anyopaque) anyerror!void {
        _ = context;
    }

    fn truncateLog(context: *anyopaque, len: u64) anyerror!void {
        const self: *RamHistory = @ptrCast(@alignCast(context));
        self.log_bytes.shrinkRetainingCapacity(@intCast(len));
    }

    fn putObject(context: *anyopaque, kind: session_recorder.Objects.Kind, name: []const u8, bytes: []const u8) anyerror!void {
        const self: *RamHistory = @ptrCast(@alignCast(context));
        if (self.get(name)) |old| return object_reuse.validate(self.gpa, kind, old, bytes);
        var slot: Named = .{ .name = undefined, .bytes = try self.gpa.dupe(u8, bytes) };
        errdefer self.gpa.free(slot.bytes);
        std.debug.assert(name.len == slot.name.len);
        @memcpy(&slot.name, name);
        try self.objects.append(self.gpa, slot);
    }

    fn syncObjects(context: *anyopaque) anyerror!void {
        _ = context;
    }

    /// The RAM this history may still take: the share's remainder, read
    /// fresh per check the way a volume's free space would be.
    fn freeRam(context: *anyopaque) anyerror!u64 {
        const self: *RamHistory = @ptrCast(@alignCast(context));
        return self.share -| self.used();
    }
};
