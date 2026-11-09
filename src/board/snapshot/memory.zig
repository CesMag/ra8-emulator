//! The guest-memory section of a snapshot (RA8EMU-659): every region a
//! memory.store.Store owns, and each window it mapped outside memmap.
//!
//! WHAT A STORE OWNS IS WHAT IT SAVES. A Non-secure view is the same bytes
//! as the region it views, and a second core borrows the shared SRAM and
//! SDRAM from the first, so neither is owned and neither is saved twice.
//!
//! ONLY NON-ZERO PAGES ARE WRITTEN. A fresh store is zeroed (store.zig), so
//! a page left out reads back as zero; SDRAM has the board profile's size.
//!
//! Layout: a region count, then per region its base, length, how many pages
//! follow, and each page as its offset and bytes.
const std = @import("std");
const memmap = @import("ra8_chip").core.memmap;
const store_mod = @import("ra8_chip").core.cpu.memory.store;
const external = @import("../external/memory.zig");
const external_backing = @import("../external/backing.zig");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;

pub const Store = store_mod.Store;
pub const page: u32 = 0x1000;
pub const FabricState = ?external.State;

pub const Error = fields.Error || error{ Unbacked, SizeMismatch, LayoutMismatch, OutOfMemory };

/// Writes the memory section of `store`.
pub fn save(store: *const Store, writer: anytype) !void {
    return saveAs(store, .memory, writer);
}

pub fn saveAs(store: *const Store, kind: file.Kind, writer: anytype) !void {
    var live: LiveCounts = undefined;
    try file.writeSectionHeader(writer, kind, payloadLen(store, &live));
    try writer.writeInt(u32, regionCount(store), .little);
    for (memmap.ram, 0..) |entry, index| {
        if (!store.owned[index]) continue;
        try saveRegion(entry.base, store.pages[index].?, live[index], writer);
    }
    if (store.owns_port) try saveRegion(memmap.sdram_base, store.region(memmap.sdram_base).?, live[memmap.ram.len], writer);
    for (store.extra.windows, 0..) |held, index| {
        const window = held orelse continue;
        try saveRegion(window.base, window.bytes, live[memmap.ram.len + 1 + index], writer);
    }
    const state: ?external.State = if (external_backing.fabricOf(store)) |fabric| fabric.state() else null;
    try fields.write(writer, state);
}

/// The fabric section: the external memory fabric's timing state alone,
/// for a save that leaves the guest bytes out.
pub fn saveFabric(store: *const Store, writer: anytype) !void {
    const state: ?external.State = if (external_backing.fabricOf(store)) |fabric| fabric.state() else null;
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try fields.write(&counter.writer, state);
    try file.writeSectionHeader(writer, .fabric, counter.fullCount());
    try fields.write(writer, state);
}

/// Reads and checks a fabric section against `store`'s fabric.
pub fn prepareFabric(store: *const Store, bytes: []const u8) !?external.State {
    const section = try file.Reader.find(bytes, .fabric) orelse return error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    const state = try fields.read(?external.State, &cursor);
    if (!cursor.done()) return Error.Truncated;
    const fabric = external_backing.fabricOf(store);
    if ((state != null) != (fabric != null)) return Error.LayoutMismatch;
    if (state) |saved| if (!std.meta.eql(saved.config, fabric.?.layout.config)) return Error.LayoutMismatch;
    return state;
}

/// Puts a prepared fabric state back.
pub fn commitFabric(store: *Store, state: ?external.State) void {
    if (state) |saved| external_backing.fabricOf(store).?.restore(saved);
}

/// Fills `store`, freshly made, from a memory section's payload.
pub fn load(store: *Store, payload: []const u8) Error!void {
    var staged = try prepare(store, payload);
    defer staged.deinit();
    staged.commit(store);
}

pub const Prepared = struct {
    payload: []const u8,
    extra: @TypeOf(@as(Store, .{}).extra) = .{},

    pub fn deinit(self: *Prepared) void {
        self.extra.deinit();
    }

    /// All parsing and window allocation completed before this point.
    pub fn commit(self: *Prepared, store: *Store) void {
        store.barrier(.snapshot_load);
        for (store.pages, store.owned) |held, mine| if (mine) {
            if (held) |bytes| @memset(bytes, 0);
        };
        if (store.owns_port) @memset(store.port.?.sdram, 0);
        store.extra.deinit();
        store.extra = self.extra;
        self.extra = .{};
        apply(store, self.payload);
        store.notifyCodeRanges();
    }
};

/// Keep page bytes borrowed from the file; only new window allocations are
/// owned by the preparation. Fixed backing is never changed during parsing.
pub fn prepare(store: *const Store, payload: []const u8) Error!Prepared {
    try validate(store, payload);
    var staged: Prepared = .{ .payload = payload };
    errdefer staged.deinit();
    var scratch = store.*;
    scratch.extra = .{};
    var at: usize = 0;
    const count = try int(payload, &at);
    for (0..count) |_| {
        const base = try int(payload, &at);
        const len = try int(payload, &at);
        _ = try backing(&scratch, base, len);
        staged.extra = scratch.extra;
        const pages = try int(payload, &at);
        for (0..pages) |_| {
            const offset = try int(payload, &at);
            at += @min(page, len - offset);
        }
    }
    return staged;
}

fn apply(store: *Store, payload: []const u8) void {
    var at: usize = 0;
    const count = int(payload, &at) catch unreachable;
    for (0..count) |_| {
        const base = int(payload, &at) catch unreachable;
        const len = int(payload, &at) catch unreachable;
        const bytes = backing(store, base, len) catch unreachable;
        const pages = int(payload, &at) catch unreachable;
        for (0..pages) |_| {
            const offset = int(payload, &at) catch unreachable;
            const size = @min(page, len - offset);
            @memcpy(bytes[offset..][0..size], payload[at..][0..size]);
            at += size;
        }
    }
    var cursor: fields.Cursor = .{ .bytes = payload, .at = at };
    const state = fields.read(?external.State, &cursor) catch unreachable;
    if (state) |saved| external_backing.fabricOf(store).?.restore(saved);
}

pub fn validate(store: *const Store, payload: []const u8) Error!void {
    var at: usize = 0;
    const count = try int(payload, &at);
    if (count > store.pages.len + store.extra.windows.len + 1) return Error.BadValue;
    var bases: [memmap.ram.len + 33]u32 = undefined;
    var fixed_seen: [memmap.ram.len]bool = @splat(false);
    var sdram_seen = false;
    for (0..count) |index| {
        const base = try int(payload, &at);
        const len = try int(payload, &at);
        if (len == 0 or @as(u64, base) + len > 0x1_0000_0000) return Error.BadValue;
        for (bases[0..index]) |previous| if (previous == base) return Error.BadValue;
        bases[index] = base;
        if (fixedBacking(store, base)) |bytes| {
            if (bytes.len != len) return Error.SizeMismatch;
            for (memmap.ram, 0..) |entry, slot| if (entry.base == base) {
                if (!store.owned[slot] and !(base == memmap.sdram_base and store.owns_port)) return Error.Unbacked;
                fixed_seen[slot] = true;
            };
            if (base == memmap.sdram_base) sdram_seen = true;
        } else {
            for (memmap.ram) |entry| if (base < entry.end() and entry.base < @as(u64, base) + len) return Error.Unbacked;
        }
        const pages = try int(payload, &at);
        var previous: ?u32 = null;
        for (0..pages) |_| {
            const offset = try int(payload, &at);
            if (offset >= len or offset % page != 0) return Error.BadValue;
            if (previous) |last| if (offset <= last) return Error.BadValue;
            previous = offset;
            const size = @min(page, len - offset);
            if (payload.len - at < size) return Error.Truncated;
            at += size;
        }
    }
    for (store.owned, fixed_seen) |mine, seen| if (mine and !seen) return Error.Unbacked;
    if (store.owns_port and !sdram_seen) return Error.Unbacked;
    var cursor: fields.Cursor = .{ .bytes = payload, .at = at };
    const state = try fields.read(?external.State, &cursor);
    if ((state != null) != (external_backing.fabricOf(store) != null)) return Error.LayoutMismatch;
    if (state) |saved| {
        if (!std.meta.eql(saved.config, external_backing.fabricOf(store).?.layout.config)) return Error.LayoutMismatch;
    }
    if (!cursor.done()) return Error.Truncated;
}

fn fixedBacking(store: *const Store, base: u32) ?[]u8 {
    for (memmap.ram, 0..) |entry, index| if (entry.base == base) return store.pages[index];
    return null;
}

fn saveRegion(base: u32, bytes: []const u8, live: u32, writer: anytype) !void {
    try writer.writeInt(u32, base, .little);
    try writer.writeInt(u32, @intCast(bytes.len), .little);
    try writer.writeInt(u32, live, .little);
    var left: u32 = live;
    var offset: usize = 0;
    while (left > 0 and offset < bytes.len) : (offset += page) {
        const chunk = bytes[offset..@min(offset + page, bytes.len)];
        if (zero(chunk)) continue;
        try writer.writeInt(u32, @intCast(offset), .little);
        try writer.writeAll(chunk);
        left -= 1;
    }
}

/// The host bytes a saved region goes back into, mapping a window outside
/// memmap the way its peripheral did at attach.
fn backing(store: *Store, base: u32, len: u32) Error![]u8 {
    for (memmap.ram, 0..) |entry, index| {
        if (entry.base != base) continue;
        const bytes = store.pages[index] orelse return Error.Unbacked;
        if (bytes.len != len) return Error.SizeMismatch;
        return bytes;
    }
    if (store.extra.locate(base, len) == null) {
        store.map(base, len) catch |err| return switch (err) {
            error.OutOfMemory => Error.OutOfMemory,
            else => Error.Unbacked,
        };
    }
    return (store.extra.locate(base, len) orelse return Error.Unbacked).bytes;
}

const LiveCounts = [memmap.ram.len + 1 + @as(Store, .{}).extra.windows.len]u32;

fn payloadLen(store: *const Store, live: *LiveCounts) u64 {
    var len: u64 = 4;
    for (memmap.ram, 0..) |_, index| {
        if (store.owned[index]) len += regionLen(store.pages[index].?, &live[index]);
    }
    if (store.owns_port) len += regionLen(store.region(memmap.sdram_base).?, &live[memmap.ram.len]);
    for (store.extra.windows, 0..) |held, index| {
        if (held) |window| len += regionLen(window.bytes, &live[memmap.ram.len + 1 + index]);
    }
    len += stateLen(store);
    return len;
}

fn stateLen(store: *const Store) u64 {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    const state: ?external.State = if (external_backing.fabricOf(store)) |fabric| fabric.state() else null;
    fields.write(&counter.writer, state) catch unreachable;
    return counter.fullCount();
}

fn regionLen(bytes: []const u8, live: *u32) u64 {
    var len: u64 = 12;
    live.* = 0;
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += page) {
        const chunk = bytes[offset..@min(offset + page, bytes.len)];
        if (!zero(chunk)) {
            len += 4 + chunk.len;
            live.* += 1;
        }
    }
    return len;
}

fn regionCount(store: *const Store) u32 {
    var count: u32 = 0;
    for (store.owned) |mine| count += @intFromBool(mine);
    count += @intFromBool(store.owns_port);
    for (store.extra.windows) |held| count += @intFromBool(held != null);
    return count;
}

/// Tests every byte, including unaligned input and a partial final block.
pub fn zero(bytes: []const u8) bool {
    var at: usize = 0;
    while (bytes.len - at >= 32) : (at += 32) {
        const block: @Vector(32, u8) = bytes[at..][0..32].*;
        if (@reduce(.Or, block) != 0) return false;
    }
    return std.mem.allEqual(u8, bytes[at..], 0);
}

fn int(payload: []const u8, at: *usize) Error!u32 {
    if (payload.len - at.* < 4) return Error.Truncated;
    const value = std.mem.readInt(u32, payload[at.*..][0..4], .little);
    at.* += 4;
    return value;
}
