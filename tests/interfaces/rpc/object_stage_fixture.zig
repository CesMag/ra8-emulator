const std = @import("std");
const ra8 = @import("ra8");
const storage = ra8.host.history.storage;
const reuse = ra8.rpc.object_reuse;
const gpa = std.testing.allocator;

pub const NativeProbe = struct {
    session: *ra8.host.history.session.Session,
    mode: enum { intent, replace, replace_error, published, fallback_link, fallback_unlink },
    from: [96]u8 = undefined,
    len: usize = 0,

    pub fn hook(self: *NativeProbe) ra8.host.history.move.probe.Probe {
        return .{ .context = self, .reached = reach, .force_fallback = self.mode == .fallback_link or self.mode == .fallback_unlink };
    }

    fn reach(ctx: *anyopaque, phase: ra8.host.history.move.probe.Phase, dir: std.Io.Dir, from: []const u8, _: std.Io.Dir, to: []const u8) !void {
        const self: *NativeProbe = @ptrCast(@alignCast(ctx));
        const h = ra8.host.history;
        if (phase == .native_before) {
            @memcpy(self.from[0..from.len], from);
            self.len = from.len;
            switch (self.mode) {
                .intent => {
                    try h.rename.begin(std.testing.io, self.session.dir, dir, .objects, from, to);
                    return error.InjectedIntent;
                },
                .replace, .replace_error => {
                    try dir.writeFile(std.testing.io, .{ .sub_path = "foreign-seed", .data = "foreign bytes" });
                    try dir.deleteFile(std.testing.io, from);
                    try h.move.preserve(std.testing.io, dir, "foreign-seed", dir, from);
                    if (self.mode == .replace_error) return error.InjectedProbe;
                },
                else => {},
            }
        }
        if (phase == .native_moved and self.mode == .published) return error.InjectedPublished;
        if (phase == .file_linked and self.mode == .fallback_link) return error.InjectedLinked;
        if (phase == .file_unlinked and self.mode == .fallback_unlink) return error.InjectedUnlinked;
    }
};

pub const StageStore = struct {
    temp_name: [64]u8 = undefined,
    temp_len: usize = 0,
    temp_live: bool = false,
    temp_bytes: std.ArrayListUnmanaged(u8) = .empty,
    temp_synced: bool = false,
    foreign_name: []const u8 = "",
    foreign_removed: bool = false,
    final_name: [96]u8 = undefined,
    final_len: usize = 0,
    final_live: bool = false,
    final_bytes: std.ArrayListUnmanaged(u8) = .empty,
    final_syncs: usize = 0,
    final_reads: usize = 0,
    dir_syncs: usize = 0,
    open_handles: usize = 0,
    renames: usize = 0,
    write_limit: ?usize = null,
    fail_sync_temp: bool = false,
    fail_sync_final: bool = false,
    fail_rename: ?anyerror = null,
    fail_remove: ?anyerror = null,
    fail_dir_sync: bool = false,

    const Handle = struct { parent: *StageStore, is_temp: bool };

    pub fn deinit(self: *StageStore) void {
        self.temp_bytes.deinit(gpa);
        self.final_bytes.deinit(gpa);
    }
    pub fn store(self: *StageStore) storage.Store {
        return .{ .context = self, .vtable = &.{ .open = open, .remove = remove, .rename = rename, .list = list } };
    }
    pub fn dirSync(self: *StageStore) reuse.DirSync {
        return .{ .context = self, .sync = syncDir };
    }
    fn syncDir(ctx: *anyopaque) !void {
        const self: *StageStore = @ptrCast(@alignCast(ctx));
        try std.testing.expect(self.final_syncs > 0);
        self.dir_syncs += 1;
        if (self.fail_dir_sync) return error.InjectedDirSync;
    }
    pub fn seedFinal(self: *StageStore, name: []const u8, bytes: []const u8) !void {
        @memcpy(self.final_name[0..name.len], name);
        self.final_len = name.len;
        self.final_live = true;
        self.final_bytes.clearRetainingCapacity();
        try self.final_bytes.appendSlice(gpa, bytes);
    }
    pub fn finalSlice(self: *const StageStore) []const u8 {
        return self.final_bytes.items;
    }

    fn open(ctx: *anyopaque, space: ra8.host.history.layout.Space, name: []const u8, mode: storage.Mode) !storage.ByteFile {
        const self: *StageStore = @ptrCast(@alignCast(ctx));
        try std.testing.expectEqual(.objects, space);
        switch (mode) {
            .create => {
                if (self.foreign_name.len != 0 and std.mem.eql(u8, name, self.foreign_name)) return error.PathAlreadyExists;
                if (self.final_live and std.mem.eql(u8, name, self.final_name[0..self.final_len])) return error.PathAlreadyExists;
                if (self.temp_live and std.mem.eql(u8, name, self.temp_name[0..self.temp_len])) return error.PathAlreadyExists;
                try std.testing.expect(std.mem.startsWith(u8, name, reuse.prefix));
                @memcpy(self.temp_name[0..name.len], name);
                self.temp_len = name.len;
                self.temp_live = true;
                self.temp_synced = false;
                self.temp_bytes.clearRetainingCapacity();
                return makeHandle(self, true);
            },
            .update, .read => {
                if (!self.final_live or !std.mem.eql(u8, name, self.final_name[0..self.final_len])) return error.FileNotFound;
                return makeHandle(self, false);
            },
        }
    }

    fn makeHandle(self: *StageStore, is_temp: bool) !storage.ByteFile {
        const h = try gpa.create(Handle);
        h.* = .{ .parent = self, .is_temp = is_temp };
        self.open_handles += 1;
        return .{ .context = h, .vtable = &.{ .read = readH, .write = writeH, .length = lengthH, .truncate = truncateH, .sync = syncH, .close = closeH } };
    }

    fn readH(ctx: *anyopaque, offset: u64, out: []u8) !usize {
        const h: *Handle = @ptrCast(@alignCast(ctx));
        try std.testing.expect(!h.is_temp);
        h.parent.final_reads += 1;
        const src = h.parent.final_bytes.items;
        const at: usize = @intCast(offset);
        const n = @min(out.len, src.len - at);
        @memcpy(out[0..n], src[at..][0..n]);
        return n;
    }

    fn writeH(ctx: *anyopaque, offset: u64, bytes: []const u8) !void {
        const h: *Handle = @ptrCast(@alignCast(ctx));
        try std.testing.expect(h.is_temp);
        try std.testing.expectEqual(@as(u64, 0), offset);
        if (h.parent.write_limit) |limit| {
            try h.parent.temp_bytes.appendSlice(gpa, bytes[0..@min(limit, bytes.len)]);
            return error.InjectedWrite;
        }
        try h.parent.temp_bytes.appendSlice(gpa, bytes);
    }

    fn lengthH(ctx: *anyopaque) !u64 {
        const h: *Handle = @ptrCast(@alignCast(ctx));
        return if (h.is_temp) h.parent.temp_bytes.items.len else h.parent.final_bytes.items.len;
    }

    fn truncateH(_: *anyopaque, _: u64) !void {
        return error.UnexpectedMutation;
    }

    fn syncH(ctx: *anyopaque) !void {
        const h: *Handle = @ptrCast(@alignCast(ctx));
        if (h.is_temp) {
            if (h.parent.fail_sync_temp) return error.InjectedSync;
            h.parent.temp_synced = true;
            return;
        }
        h.parent.final_syncs += 1;
        if (h.parent.fail_sync_final) return error.InjectedFinalSync;
    }

    fn closeH(ctx: *anyopaque) void {
        const h: *Handle = @ptrCast(@alignCast(ctx));
        h.parent.open_handles -= 1;
        gpa.destroy(h);
    }

    fn remove(ctx: *anyopaque, space: ra8.host.history.layout.Space, name: []const u8) !void {
        const self: *StageStore = @ptrCast(@alignCast(ctx));
        try std.testing.expectEqual(.objects, space);
        if (self.foreign_name.len != 0 and std.mem.eql(u8, name, self.foreign_name)) {
            self.foreign_removed = true;
            return error.ForeignTempRemoved;
        }
        try std.testing.expect(self.temp_live);
        try std.testing.expectEqualStrings(self.temp_name[0..self.temp_len], name);
        if (self.fail_remove) |err| return err;
        self.temp_live = false;
    }

    fn rename(ctx: *anyopaque, space: ra8.host.history.layout.Space, from: []const u8, to: []const u8) !void {
        const self: *StageStore = @ptrCast(@alignCast(ctx));
        try std.testing.expectEqual(.objects, space);
        try std.testing.expect(self.temp_live);
        try std.testing.expect(self.temp_synced);
        try std.testing.expectEqualStrings(self.temp_name[0..self.temp_len], from);
        self.renames += 1;
        if (self.fail_rename) |err| return err;
        if (self.final_live and std.mem.eql(u8, to, self.final_name[0..self.final_len])) return error.PathAlreadyExists;
        @memcpy(self.final_name[0..to.len], to);
        self.final_len = to.len;
        self.final_live = true;
        self.final_bytes.clearRetainingCapacity();
        try self.final_bytes.appendSlice(gpa, self.temp_bytes.items);
        self.temp_live = false;
    }

    fn list(_: *anyopaque, _: ra8.host.history.layout.Space, _: storage.Visitor) !void {
        return error.UnexpectedOperation;
    }
};
