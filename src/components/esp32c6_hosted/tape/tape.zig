//! Recorded C6 host traffic for `--net-record` and `--net-replay` (RA8EMU-560).
//! One file per host connection or DNS question. Each file is a run of
//! records: a direction byte, a u32 little-endian length, then the bytes.
const std = @import("std");
const store_file = @import("store.zig");

pub const Store = store_file.Store;
pub const Handle = store_file.Handle;

pub const Mode = enum { live, record, replay };
pub const Proto = enum { tcp, udp };

/// `--net-record DIR` or `--net-replay DIR` from the command line.
pub const Spec = struct { dir: []const u8, mode: Mode };
pub const Dir = enum(u8) { guest = '>', host = '<', closed = '.' };

/// A host endpoint; the n-th connection to it gets the n-th tape.
pub const Key = struct { proto: Proto, ip: [4]u8, port: u16 };

pub const key_capacity: usize = 64;
const header_len: usize = 5;
const file_max: usize = 64 * 1024 * 1024;

pub const Record = struct { dir: Dir, bytes: []const u8 };

/// Where a run's tapes live and which way they go. `misses` counts every
/// replay request with no recording; a run with misses must fail.
pub const Tape = struct {
    mode: Mode = .live,
    store: ?Store = null,
    keys: [key_capacity]Key = undefined,
    counts: [key_capacity]u32 = undefined,
    key_len: usize = 0,
    misses: std.atomic.Value(u32) = .init(0),

    /// A recording or replay over `store`, which the application fills
    /// from its host files (RA8EMU-1020).
    pub fn init(mode: Mode, store: Store) Tape {
        return .{ .mode = mode, .store = store };
    }

    pub fn deinit(self: *Tape) void {
        if (self.store) |store| store.release(store.root);
        self.store = null;
    }

    pub fn missed(self: *const Tape) u32 {
        return self.misses.load(.acquire);
    }

    /// Starts the next recording for `key`.
    pub fn create(self: *Tape, key: Key) !Writer {
        var buf: [64]u8 = undefined;
        const name = try self.nextName(&buf, key);
        const store = self.store.?;
        return .{ .store = store, .file = try store.create(store.root, name) };
    }

    /// Loads the next recording for `key`; a missing one is a miss.
    pub fn load(self: *Tape, key: Key) !Reader {
        var buf: [64]u8 = undefined;
        const name = try self.nextName(&buf, key);
        const store = self.store.?;
        const data = store.readAlloc(store.root, name, std.heap.page_allocator, file_max) catch |err| {
            self.miss("no recording for {s}", .{name});
            return err;
        };
        return .{ .data = data };
    }

    /// Saves one DNS answer under its question (the bytes after the id).
    pub fn storeDns(self: *Tape, request: []const u8, answer: []const u8) void {
        if (request.len < 2) return;
        var buf: [64]u8 = undefined;
        const store = self.store.?;
        const file = store.create(store.root, dnsName(&buf, request)) catch |err| return warnWrite(err);
        defer store.close(file);
        store.append(file, answer) catch |err| warnWrite(err);
    }

    /// The recorded answer to `request`, its id patched to match; null is a miss.
    pub fn loadDns(self: *Tape, request: []const u8, out: []u8) ?[]const u8 {
        if (request.len < 2) return null;
        var buf: [64]u8 = undefined;
        const name = dnsName(&buf, request);
        const store = self.store.?;
        const answer = store.readInto(store.root, name, out) catch {
            self.miss("no recording for {s}", .{name});
            return null;
        };
        if (answer.len < 2) return null;
        @memcpy(out[0..2], request[0..2]);
        return answer;
    }

    /// Counts a replay failure and says why; the run must then fail.
    pub fn miss(self: *Tape, comptime why: []const u8, args: anytype) void {
        _ = self.misses.fetchAdd(1, .acq_rel);
        std.log.warn("net-replay: " ++ why, args);
    }

    fn nextName(self: *Tape, buf: []u8, key: Key) ![]const u8 {
        const n = try self.bump(key);
        const ip = key.ip;
        return std.fmt.bufPrint(buf, "{s}-{d}.{d}.{d}.{d}-{d}-{d}.tape", .{ @tagName(key.proto), ip[0], ip[1], ip[2], ip[3], key.port, n });
    }

    fn bump(self: *Tape, key: Key) !u32 {
        for (self.keys[0..self.key_len], 0..) |seen, index| {
            if (!std.meta.eql(seen, key)) continue;
            self.counts[index] += 1;
            return self.counts[index] - 1;
        }
        if (self.key_len == key_capacity) return error.TooManyEndpoints;
        self.keys[self.key_len] = key;
        self.counts[self.key_len] = 1;
        self.key_len += 1;
        return 0;
    }
};

fn dnsName(buf: *[64]u8, request: []const u8) []const u8 {
    const hash = std.hash.Wyhash.hash(0, request[2..]);
    return std.fmt.bufPrint(buf, "dns-{x:0>16}.tape", .{hash}) catch unreachable;
}

fn warnWrite(err: anyerror) void {
    std.log.warn("net-record: {s}", .{@errorName(err)});
}

/// Appends records to one connection's tape.
pub const Writer = struct {
    store: Store,
    file: Handle,

    pub fn put(self: *Writer, dir: Dir, bytes: []const u8) void {
        if (bytes.len == 0 and dir != .closed) return;
        var head: [header_len]u8 = undefined;
        head[0] = @backingInt(dir);
        std.mem.writeInt(u32, head[1..5], @intCast(bytes.len), .little);
        self.store.append(self.file, &head) catch |err| return warnWrite(err);
        self.store.append(self.file, bytes) catch |err| warnWrite(err);
    }

    pub fn close(self: *Writer) void {
        self.store.close(self.file);
    }
};

/// Walks one connection's tape: guest bytes are checked, host bytes handed out.
pub const Reader = struct {
    data: []u8,
    at: usize = 0,
    used: usize = 0,

    pub fn deinit(self: *Reader) void {
        std.heap.page_allocator.free(self.data);
    }

    /// The unconsumed part of the current record, null at the end.
    pub fn current(self: *const Reader) ?Record {
        if (self.at + header_len > self.data.len) return null;
        const start = self.at + header_len;
        const end = start + std.mem.readInt(u32, self.data[self.at + 1 ..][0..4], .little);
        if (end > self.data.len) return null;
        const dir = std.enums.fromInt(Dir, self.data[self.at]) orelse return null;
        return .{ .dir = dir, .bytes = self.data[start + self.used .. end] };
    }

    /// True when `sent` is exactly what the guest sent next when recording.
    pub fn expect(self: *Reader, sent: []const u8) bool {
        var rest = sent;
        while (rest.len != 0) {
            const record = self.current() orelse return false;
            if (record.dir != .guest) return false;
            const n = @min(rest.len, record.bytes.len);
            if (!std.mem.eql(u8, rest[0..n], record.bytes[0..n])) return false;
            self.advance(n);
            rest = rest[n..];
        }
        return true;
    }

    /// Copies the next recorded host bytes into `out`; 0 when none are due.
    pub fn take(self: *Reader, out: []u8) usize {
        const record = self.current() orelse return 0;
        if (record.dir != .host) return 0;
        const n = @min(out.len, record.bytes.len);
        @memcpy(out[0..n], record.bytes[0..n]);
        self.advance(n);
        return n;
    }

    /// True once the host's close is next or the tape has ended.
    pub fn closed(self: *const Reader) bool {
        const record = self.current() orelse return true;
        return record.dir == .closed;
    }

    fn advance(self: *Reader, n: usize) void {
        const record = self.current().?;
        if (n < record.bytes.len) {
            self.used += n;
            return;
        }
        self.at = @intFromPtr(record.bytes.ptr) - @intFromPtr(self.data.ptr) + record.bytes.len;
        self.used = 0;
    }
};
