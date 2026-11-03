//! Object writes remain live until a durable log's references account for them.
const std = @import("std");
const history = @import("ra8_host").history;
const ObjectId = @import("ra8_session").history_object_id.ObjectId;
const Bind = @import("history_bind.zig").Bind;
const refs = @import("ra8_session").history_refs;
const log = @import("ra8_session").history_log;
const format = @import("ra8_session").history_format;
const record = @import("ra8_session").history_record;
const history_live = @import("history_live.zig");

pub const Pending = struct {
    names: std.StringHashMap(void),

    pub fn init(gpa: std.mem.Allocator) Pending {
        return .{ .names = .init(gpa) };
    }

    pub fn clear(self: *Pending) void {
        var keys = self.names.keyIterator();
        while (keys.next()) |key| self.names.allocator.free(key.*);
        self.names.clearRetainingCapacity();
    }

    pub fn deinit(self: *Pending) void {
        self.clear();
        self.names.deinit();
    }

    pub fn protect(self: *Pending, name: []const u8) !void {
        try add(self.names.allocator, &self.names, name);
    }

    /// Prepare only references in the incoming complete batch, never the old
    /// log. Failure disables acknowledgment conservatively without rejecting
    /// raw append fixtures or introducing errors after a successful sync.
    /// False means the incoming bytes are not complete valid frames.
    pub fn prepare(self: *Pending, store: history.storage.Store, bytes: []const u8) bool {
        var gather: Gather = .{ .pending = self };
        var check: FrameCheck = .{};
        const scanned = log.scan(bytes, &check, FrameCheck.visit) catch {
            self.clear();
            return false;
        };
        if (scanned.torn or check.invalid) {
            self.clear();
            return false;
        }
        refs.scanCheckpointObjects(bytes, &gather, Gather.visit) catch {
            self.clear();
            return true;
        };
        if (gather.failed) {
            self.clear();
            return true;
        }
        if (self.names.count() == 0) return true;
        history_live.addManifestObjects(store, self.names.allocator, &self.names) catch self.clear();
        return true;
    }

    /// Only refs from successfully appended bytes may acknowledge a durable
    /// sync. Failed/unreferenced capture writes keep their seen-ID protection.
    pub fn acknowledge(self: *Pending, prepared: *const Pending) void {
        var keys = prepared.names.keyIterator();
        while (keys.next()) |key| {
            if (self.names.fetchRemove(key.*)) |entry| self.names.allocator.free(entry.key);
        }
    }

    pub fn collect(context: *anyopaque, gpa: std.mem.Allocator, names: *std.StringHashMap(void)) anyerror!void {
        const self: *Pending = @ptrCast(@alignCast(context));
        var keys = self.names.keyIterator();
        while (keys.next()) |key| try add(gpa, names, key.*);
    }
};

/// Certify an existing segment once when switching to it. A read/allocation
/// failure keeps acknowledgment disabled; it never prevents the switch.
pub fn validSegment(gpa: std.mem.Allocator, byte: history.storage.ByteFile, length: u64) bool {
    return validateSegment(gpa, byte, length) catch false;
}

fn validateSegment(gpa: std.mem.Allocator, byte: history.storage.ByteFile, length: u64) !bool {
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(gpa);
    var offset: u64 = 0;
    var header: [format.header_len]u8 = undefined;
    while (offset < length) {
        if (length - offset < header.len) return false;
        try readExact(byte, offset, &header);
        const payload = std.mem.readInt(u32, header[0..4], .little);
        if (payload > format.max_len) return false;
        const total = format.header_len + @as(usize, payload);
        if (total > length - offset) return false;
        try frame.ensureTotalCapacityPrecise(gpa, total);
        frame.items.len = total;
        @memcpy(frame.items[0..header.len], &header);
        try readExact(byte, offset + header.len, frame.items[header.len..]);
        var check: FrameCheck = .{};
        const scanned = try log.scan(frame.items, &check, FrameCheck.visit);
        if (scanned.torn or check.invalid) return false;
        offset += total;
    }
    return true;
}

fn readExact(byte: history.storage.ByteFile, offset: u64, bytes: []u8) !void {
    var got: usize = 0;
    while (got < bytes.len) {
        const count = try byte.vtable.read(byte.context, offset + got, bytes[got..]);
        if (count == 0) return error.Truncated;
        got += count;
    }
}

const FrameCheck = struct {
    invalid: bool = false,

    fn visit(self: *FrameCheck, boundary: log.Boundary) void {
        if (record.mandatory(boundary.kind) and !record.known(boundary.kind)) self.invalid = true;
    }
};

const Gather = struct {
    pending: *Pending,
    failed: bool = false,

    fn visit(self: *Gather, name: refs.Name) void {
        if (self.failed) return;
        self.pending.protect(&name) catch {
            self.failed = true;
        };
    }
};

fn add(gpa: std.mem.Allocator, names: *std.StringHashMap(void), name: []const u8) !void {
    if (names.contains(name)) return;
    const key = try gpa.dupe(u8, name);
    errdefer gpa.free(key);
    try names.put(key, {});
}

pub fn putObject(context: *anyopaque, name: []const u8, bytes: []const u8) anyerror!void {
    const bind: *Bind = @ptrCast(@alignCast(context));
    try bind.pending.protect(name);
    const store = history.storage.Store.from(&bind.session);
    var file = store.vtable.open(store.context, .objects, name, .create) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
    defer file.vtable.close(file.context);
    try file.vtable.write(file.context, 0, bytes);
    try file.vtable.sync(file.context);
}

pub fn putPacked(context: *anyopaque, id: [16]u8, bytes: []const u8) anyerror!void {
    const bind: *Bind = @ptrCast(@alignCast(context));
    const object: ObjectId = .{ .bytes = id };
    var name: [ObjectId.hex_len]u8 = undefined;
    object.formatHex(&name);
    try bind.pending.protect(&name);
    try bind.packs.put(object, bytes);
}
