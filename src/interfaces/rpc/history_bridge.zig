//! The served session's history bridge (RA8EMU-1196, slice 17): the
//! application half of the transport's bridge. A served session that
//! records history binds it, so a seek plans from the committed log and
//! puts the machine back through the checkpoint objects; a session with
//! no history binds nothing and its seeks stay refused.
const std = @import("std");
const ra8_session = @import("ra8_session");
const history = @import("ra8_host").history;
const history_bind = @import("history_bind.zig");
const history_ram = @import("history_ram.zig");
const history_segments = @import("history_segments.zig");
const prefetch_pool = @import("prefetch_pool.zig");
const object_read = @import("object_read.zig");

const seek_engine = ra8_session.history_seek_engine;
const seek_facts = ra8_session.history_seek_facts;
const touched_pages = ra8_session.history_touched_pages;

/// The bridge a served session binds: it reads the committed log for the
/// transport's planner and restores checkpoint objects into the session's
/// history. `disk` and `ram` are the two history kinds a served open
/// makes; exactly one is present.
pub const Bridge = struct {
    gpa: std.mem.Allocator,
    session: *ra8_session.api.Session,
    disk: ?*history_bind.Bind = null,
    ram: ?*history_ram.RamHistory = null,
    /// The facts the last gather returned; the bridge owns their memory
    /// until the next gather (the transport's bridge contract).
    facts_scratch: ?seek_facts.Facts = null,
    /// The disk log's bytes the last logBytes read, owned until the next
    /// read or teardown.
    log_scratch: ?[]u8 = null,
    touched_scratch: std.ArrayList(*touched_pages.Touched) = .empty,
    /// The prefetch pool a disk history opened; a restore takes the
    /// checkpoint's snapshot from it when a worker already loaded it.
    prefetched: ?*prefetch_pool.Pool = null,

    /// Drop the facts and log memory still owned at teardown.
    pub fn deinit(self: *Bridge) void {
        if (self.facts_scratch) |old| self.gpa.free(old.checkpoints);
        self.facts_scratch = null;
        if (self.log_scratch) |old| self.gpa.free(old);
        self.log_scratch = null;
        for (self.touched_scratch.items) |t| {
            t.deinit();
            self.gpa.destroy(t);
        }
        self.touched_scratch.deinit(self.gpa);
    }

    /// The committed log's facts for the transport's planner: the
    /// checkpoints the log names, with the live cursor from the session's
    /// grid (the log proves the rest; the cursor is the run's own).
    pub fn facts(context: *anyopaque) anyerror!seek_engine.Facts {
        const self: *Bridge = @ptrCast(@alignCast(context));
        if (self.session.persistent_recorder) |rec| try rec.force();
        if (self.facts_scratch) |old| self.gpa.free(old.checkpoints);
        self.facts_scratch = null;
        for (self.touched_scratch.items) |t| {
            t.deinit();
            self.gpa.destroy(t);
        }
        self.touched_scratch.clearRetainingCapacity();
        var disk_buf: ?[]u8 = null;
        defer if (disk_buf) |b| self.gpa.free(b);
        const bytes: []const u8 = blk: {
            if (self.ram) |r| break :blk r.log_bytes.items;
            if (self.disk) |d| {
                // Every line's segments: a line's prefix checkpoints sit in
                // its ancestors' segments.
                disk_buf = try history_segments.readAll(self.gpa, history.storage.Store.from(&d.session));
                break :blk disk_buf.?;
            }
            return error.NoHistory;
        };
        const gathered = try seek_facts.gather(self.gpa, bytes);
        self.facts_scratch = gathered;
        try self.loadTouchedRecords(gathered.checkpoints);
        // A never-run machine has no grid: its cursor sits at or before
        // every checkpoint, which a zeroed position says. A session with
        // no log still refuses above.
        const window = windowFacts(self.session);
        if (self.session.grid) |grid| return .{ .current = grid.at, .checkpoints = gathered.checkpoints, .window = window };
        return .{ .current = .{}, .checkpoints = gathered.checkpoints, .window = window };
    }

    /// The session's reverse window as the planners see it: its span, the
    /// cursor and the line it was built on. Null while it holds no run.
    pub fn windowFacts(session: *ra8_session.api.Session) ?seek_engine.WindowFacts {
        const w = session.window orelse return null;
        if (!w.ready()) return null;
        return .{ .start = w.start() orelse return null, .end = w.end() orelse return null, .at = w.at() orelse return null, .line = w.line, .slots = w.count() };
    }

    pub fn loadTouchedRecords(self: *Bridge, checkpoints: []seek_engine.Checkpoint) !void {
        for (checkpoints) |*c| {
            const t_name = touched_pages.objectName(c.object);
            if (self.ram) |r| {
                if (r.get(&t_name)) |bytes| {
                    if (touched_pages.Touched.decodeSlice(self.gpa, bytes)) |t| {
                        var t_val = t;
                        errdefer t_val.deinit();
                        const ptr = try self.gpa.create(touched_pages.Touched);
                        errdefer self.gpa.destroy(ptr);
                        ptr.* = t_val;
                        try self.touched_scratch.append(self.gpa, ptr);
                        c.touched = ptr;
                    } else |_| {}
                }
            } else if (self.disk) |d| {
                const store = history.storage.Store.from(&d.session);
                if (store.vtable.open(store.context, .objects, &t_name, .read)) |file| {
                    defer file.vtable.close(file.context);
                    if (file.vtable.length(file.context)) |len| {
                        if (self.gpa.alloc(u8, @intCast(len))) |buf| {
                            defer self.gpa.free(buf);
                            if (readAll(file, buf)) |total| {
                                if (touched_pages.Touched.decodeSlice(self.gpa, buf[0..total])) |t| {
                                    var t_val = t;
                                    errdefer t_val.deinit();
                                    const ptr = try self.gpa.create(touched_pages.Touched);
                                    errdefer self.gpa.destroy(ptr);
                                    ptr.* = t_val;
                                    try self.touched_scratch.append(self.gpa, ptr);
                                    c.touched = ptr;
                                } else |_| {}
                            } else |_| {}
                        } else |_| {}
                    } else |_| {}
                } else |_| {}
            }
        }
    }

    /// Put the machine back at a checkpoint's saved state; `object` is
    /// the checkpoint record's 128-bit digest as its 32-hex object name.
    pub fn restore(context: *anyopaque, object: []const u8) anyerror!void {
        const self: *Bridge = @ptrCast(@alignCast(context));
        const session_history = self.session.history orelse return error.NoHistory;
        if (self.ram) |r| {
            const bytes = r.get(object) orelse return error.ObjectMissing;
            return session_history.restoreBytes(bytes);
        }
        if (self.prefetched) |pool| {
            if (prefetch_pool.ObjectId.fromHex(object)) |id| {
                if (pool.take(id)) |bytes| {
                    defer self.gpa.free(bytes);
                    return session_history.restoreBytes(bytes);
                }
            } else |_| {}
        }
        if (self.disk) |d| {
            const store = history.storage.Store.from(&d.session);
            var file = try store.vtable.open(store.context, .objects, object, .read);
            defer file.vtable.close(file.context);
            const len = try file.vtable.length(file.context);
            const buf = try self.gpa.alloc(u8, @intCast(len));
            defer self.gpa.free(buf);
            const total = try readAll(file, buf);
            return session_history.restoreBytes(buf[0..total]);
        }
        return error.NoHistory;
    }

    /// One object's bytes by its 32-hex name: how a pinned checkpoint
    /// picture is read back for the rewind.
    pub const objectBytes = readObject;

    /// One object of the history's object space by name, owned by the caller.
    pub fn readObject(context: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror![]u8 {
        const self: *Bridge = @ptrCast(@alignCast(context));
        if (self.ram) |r| return allocator.dupe(u8, r.get(name) orelse return error.ObjectMissing);
        const d = self.disk orelse return error.NoHistory;
        return object_read.read(history.storage.Store.from(&d.session), allocator, name) catch |err| {
            // A page or blob object lives in the pack store, not as a file.
            const id = prefetch_pool.ObjectId.fromHex(name) catch return err;
            return (try d.packs.get(allocator, id)) orelse err;
        };
    }

    /// The committed log's bytes across every segment, for the replay
    /// feeder; the bridge owns them until the next call.
    pub fn logBytes(context: *anyopaque) anyerror![]const u8 {
        const self: *Bridge = @ptrCast(@alignCast(context));
        // Interventions stage between commits; a replay needs every one
        // the line holds, so the staged ones commit before the read.
        if (self.session.persistent_recorder) |rec| try rec.force();
        if (self.ram) |r| return r.log_bytes.items;
        const d = self.disk orelse return error.NoHistory;
        const bytes = try history_segments.readAll(self.gpa, history.storage.Store.from(&d.session));
        if (self.log_scratch) |old| self.gpa.free(old);
        self.log_scratch = bytes;
        return bytes;
    }
};

/// Read the file's bytes into `buf` from its start; a short file stops
/// at its end.
fn readAll(file: history.storage.ByteFile, buf: []u8) anyerror!usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try file.vtable.read(file.context, @intCast(total), buf[total..]);
        if (n == 0) break;
        total += n;
    }
    return total;
}
