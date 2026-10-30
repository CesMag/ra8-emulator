//! A recorded history and a rebuilt ELF for the regression replay tests: a
//! kept session of the blink fixture with a checkpoint every round, and a
//! copy of that fixture with one instruction's immediate patched, written
//! to a temporary directory.
const std = @import("std");
const ra8 = @import("ra8");

const history = ra8.host.history;

pub const image = "tests/fixtures/gpio/blink.elf";

/// The second byte of the literal that holds the counter's address, 0x22000100.
const patched_at: usize = 0x135;

pub const Recorded = struct {
    temp: std.testing.TmpDir,
    root: [:0]u8,
    name: [64]u8 = undefined,
    len: usize = 0,
    base: history.base.Base,

    pub fn open(gpa: std.mem.Allocator, runs: usize) !*Recorded {
        return openProfile(gpa, runs, null);
    }

    pub fn openProfile(gpa: std.mem.Allocator, runs: usize, profile: ?[]const u8) !*Recorded {
        const self = try gpa.create(Recorded);
        errdefer gpa.destroy(self);
        self.temp = std.testing.tmpDir(.{});
        errdefer self.temp.cleanup();
        self.root = try self.temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
        errdefer gpa.free(self.root);
        {
            var served: ra8.rpc.served_setup.Served = undefined;
            try served.open(gpa, std.testing.io, image, profile, .{ .root = self.root, .checkpoint_every = 1, .kept = true });
            defer served.deinit();
            const session = served.owner.session();
            try session.setRunBudget(.cpu0, 40_000);
            _ = try session.run(.cpu0, .run);
            for (1..runs) |_| _ = try session.run(.cpu0, .cont);
        }
        self.base = try history.base.Base.existing(gpa, std.testing.io, self.root, .cache);
        errdefer self.base.close();
        var entries = try history.catalog.Iterator.init(&self.base);
        while (try entries.next()) |entry| {
            if (entry.kind != .session) continue;
            @memcpy(self.name[0..entry.name.len], entry.name);
            self.len = entry.name.len;
            return self;
        }
        return error.NoSession;
    }

    pub fn close(self: *Recorded, gpa: std.mem.Allocator) void {
        self.base.close();
        gpa.free(self.root);
        self.temp.cleanup();
        gpa.destroy(self);
    }

    pub fn sessionName(self: *const Recorded) []const u8 {
        return self.name[0..self.len];
    }

    pub fn rootBytes(self: *const Recorded, gpa: std.mem.Allocator) ![]u8 {
        const dir = try self.base.dir.openDir(std.testing.io, self.sessionName(), .{});
        defer dir.close(std.testing.io);
        return dir.readFileAlloc(std.testing.io, "root.bin", gpa, .unlimited);
    }

    pub fn writeRoot(self: *const Recorded, value: ra8.session.history_root.Root) !void {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try ra8.session.history_root.encode(&value, &out.writer);
        try self.writeFile("root.bin", out.written());
    }

    pub fn writeFile(self: *const Recorded, path: []const u8, bytes: []const u8) !void {
        const dir = try self.base.dir.openDir(std.testing.io, self.sessionName(), .{});
        defer dir.close(std.testing.io);
        try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    }

    /// A single checkpoint record for rejection tests, with no live source.
    pub fn checkpointLog(self: *const Recorded, at: ra8.session.history_position.Position, snapshot: ?[]const u8) !void {
        var object: [16]u8 = @splat(0);
        if (snapshot) |bytes| {
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
            object = hash[0..16].*;
            var name: [40]u8 = undefined;
            const hex = std.fmt.bytesToHex(object, .lower);
            try self.writeFile(try std.fmt.bufPrint(&name, "objects/{s}", .{hex}), bytes);
        }
        var payload: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer payload.deinit();
        try ra8.session.history_record.encodeCheckpoint(&payload.writer, .{ .position = at, .seq = 0 }, .{ .id = 0, .object = object });
        var log: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer log.deinit();
        try ra8.session.history_format.encode(&log.writer, @backingInt(ra8.session.history_record.Kind.checkpoint), payload.written());
        try self.writeFile("log/events-0", log.written());
    }
};

/// Writes the fixture with the counter's address patched to
/// 0x22000200, as `name` in `dir`, and answers its absolute path.
pub fn patched(gpa: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) ![:0]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, image, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    bytes[patched_at] += 1;
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
    return dir.realPathFileAlloc(std.testing.io, name, gpa);
}

/// A digest of every file in the tree under `dir`: names and contents.
pub fn hashTree(gpa: std.mem.Allocator, dir: std.Io.Dir) ![32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.path));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    for (names.items) |path| {
        const bytes = try dir.readFileAlloc(std.testing.io, path, gpa, .unlimited);
        defer gpa.free(bytes);
        hasher.update(path);
        hasher.update(std.mem.asBytes(&bytes.len));
        hasher.update(bytes);
    }
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}
