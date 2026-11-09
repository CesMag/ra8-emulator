//! Existing immutable bytes and snapshot-keyed metadata have different reuse rules.
const std = @import("std");
const manifest = @import("manifest.zig");
const position = @import("position.zig");
const dirty = @import("dirty_pages.zig");

pub const Kind = enum { data, manifest, touched };

/// Never repairs or replaces a collision. Metadata retains the first writer.
pub fn validate(gpa: std.mem.Allocator, kind: Kind, old: []const u8, incoming: []const u8) !void {
    if (old.len != incoming.len) return error.ObjectConflict;
    switch (kind) {
        .data => if (!std.mem.eql(u8, old, incoming)) return error.ObjectConflict,
        .manifest => try sameManifest(gpa, old, incoming),
        .touched => try sameTouched(old, incoming),
    }
}

fn sameManifest(gpa: std.mem.Allocator, old: []const u8, incoming: []const u8) !void {
    try manifestShape(old);
    try manifestShape(incoming);
    var a = try manifest.decode(gpa, old);
    defer a.deinit(gpa);
    if (std.mem.eql(u8, old, incoming)) return;
    var b = try manifest.decode(gpa, incoming);
    defer b.deinit(gpa);
    if (!std.meta.eql(a.position, b.position) or !std.meta.eql(a.picture, b.picture)) return error.ObjectConflict;
    if (a.pages.len != b.pages.len or a.blobs.len != b.blobs.len) return error.ObjectConflict;
    for (a.pages, b.pages) |x, y| if (!x.eql(y)) return error.ObjectConflict;
    for (a.blobs, b.blobs) |x, y| if (!x.eql(y)) return error.ObjectConflict;
}

/// Bound codec allocations by the actual input and refuse trailing bytes.
fn manifestShape(bytes: []const u8) !void {
    const flag_at = manifest.magic.len + 4 + position.encoded_len + 4;
    if (bytes.len <= flag_at or bytes[flag_at] > 1) return error.ObjectConflict;
    var at = flag_at + 1;
    if (bytes[flag_at] == 1) at += 16;
    for (0..2) |_| {
        if (at > bytes.len or bytes.len - at < 4) return error.ObjectConflict;
        const count = std.mem.readInt(u32, bytes[at..][0..4], .little);
        at += 4;
        if (count > (bytes.len - at) / 21) return error.ObjectConflict;
        at += @as(usize, count) * 21;
    }
    if (bytes.len - at != 20) return error.ObjectConflict;
}

fn sameTouched(old: []const u8, incoming: []const u8) !void {
    if (old.len < 4) return error.ObjectConflict;
    const same_since = std.mem.eql(u8, old[0..4], incoming[0..4]);
    var at: usize = 4;
    for (0..dirty.space_count) |_| {
        if (old.len - at < 4) return error.ObjectConflict;
        const count = std.mem.readInt(u32, old[at..][0..4], .little);
        if (count != std.mem.readInt(u32, incoming[at..][0..4], .little)) return error.ObjectConflict;
        at += 4;
        if (count > (old.len - at) / 8) return error.ObjectConflict;
        const end = at + @as(usize, count) * 8;
        // An older interval is safe: value search sees a since mismatch and
        // replays. The same interval must never lose a write from its mask.
        if (same_since and !std.mem.eql(u8, old[at..end], incoming[at..end])) return error.ObjectConflict;
        at = end;
    }
    if (at != old.len) return error.ObjectConflict;
}
