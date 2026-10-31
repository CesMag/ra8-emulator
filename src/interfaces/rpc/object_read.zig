//! Reading one object out of a disk history's object space by name: the
//! one door the bridge, the prefetch pool and the prune's reference walk
//! read objects through.
const std = @import("std");
const history = @import("ra8_host").history;

/// The bytes of the object `name` (loose file) in `store`'s object space;
/// the caller owns them.
pub fn read(store: history.storage.Store, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return readLimited(store, allocator, name, std.math.maxInt(usize));
}

/// Bounded read for immutable root inputs, before allocating their payload.
pub fn readLimited(store: history.storage.Store, allocator: std.mem.Allocator, name: []const u8, limit: usize) ![]u8 {
    const file = try store.vtable.open(store.context, .objects, name, .read);
    defer file.vtable.close(file.context);
    const len: usize = @intCast(try file.vtable.length(file.context));
    if (len > limit) return error.ObjectTooLarge;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    var total: usize = 0;
    while (total < buf.len) {
        const n = try file.vtable.read(file.context, total, buf[total..]);
        if (n == 0) break;
        total += n;
    }
    if (total != buf.len) return error.ObjectTruncated;
    return buf;
}

/// The frozen root read through the same bounded storage interface.
pub fn readTopRoot(store: history.storage.Store, allocator: std.mem.Allocator) ![]u8 {
    const file = try store.vtable.open(store.context, .top, history.layout.files.root, .read);
    defer file.vtable.close(file.context);
    const len: usize = @intCast(try file.vtable.length(file.context));
    if (len > history.branches_file.max_file_size) return error.ObjectTooLarge;
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    var total: usize = 0;
    while (total < len) {
        const n = try file.vtable.read(file.context, total, bytes[total..]);
        if (n == 0) return error.ObjectTruncated;
        total += n;
    }
    return bytes;
}
