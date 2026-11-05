//! Verifies existing loose bytes before a successful object-store reuse.
const std = @import("std");
const storage = @import("ra8_host").history.storage;
const reuse = @import("ra8_session").history_object_reuse;

pub fn existing(gpa: std.mem.Allocator, store: storage.Store, name: []const u8, kind: reuse.Kind, bytes: []const u8) !void {
    const file = try store.vtable.open(store.context, .objects, name, .update);
    defer file.vtable.close(file.context);
    if (try file.vtable.length(file.context) != bytes.len) return error.ObjectConflict;
    if (kind == .data) {
        var buffer: [4096]u8 = undefined;
        var at: usize = 0;
        while (at < bytes.len) {
            const part = buffer[0..@min(buffer.len, bytes.len - at)];
            try readExact(file, at, part);
            if (!std.mem.eql(u8, part, bytes[at..][0..part.len])) return error.ObjectConflict;
            at += part.len;
        }
    } else {
        // Metadata is bounded by the incoming capture, not an on-disk count.
        const old = try gpa.alloc(u8, bytes.len);
        defer gpa.free(old);
        try readExact(file, 0, old);
        try reuse.validate(gpa, kind, old, bytes);
    }
    // A previous put may have written all bytes but failed its sync.
    try file.vtable.sync(file.context);
}

fn readExact(file: storage.ByteFile, offset: u64, bytes: []u8) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        const count = try file.vtable.read(file.context, offset + at, bytes[at..]);
        if (count == 0) return error.ObjectConflict;
        if (count > bytes.len - at) return error.ObjectConflict;
        at += count;
    }
}
