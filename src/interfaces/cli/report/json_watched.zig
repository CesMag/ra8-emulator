//! The `watch` entry of the `dumps` object (RA8EMU-391): the `--watch`
//! store log, the same facts debug/watchpoint.zig print() writes: the
//! opening and closing stores, how many fell between, how they spaced out
//! over periods, and who wrote what. Every tally row is listed (no top-N).
const elf = @import("ra8_board").image.elf;
const symbols = @import("../../../session/symbols.zig");
const watchpoint = @import("../../../session/watchpoint.zig");
const tally_mod = @import("../../../session/tally.zig");
const symbol = @import("json_where.zig").symbol;

/// Null unless `--watch` named a place the image resolves.
pub fn log(j: anytype, image: ?elf.Image, spec: ?[]const u8, found: ?*const watchpoint.Watched) !void {
    const one = found orelse return j.field("watch", null);
    try j.open("watch", '{');
    try j.field("place", spec);
    try j.field("address", one.address);
    try j.field("stores", one.seen);
    try stores(j, "opening", image, one.opening());
    try j.field("dropped", one.dropped());
    var room: [watchpoint.limits.tail]watchpoint.Store = undefined;
    try stores(j, "closing", image, one.closing(&room));
    const gaps = one.spacing;
    try j.open("spacing", '{');
    try j.field("groups", if (gaps.quiet()) 0 else gaps.groups());
    try j.field("together", gaps.together);
    try j.field("apart", gaps.apart);
    try j.field("shortest", gaps.shortest);
    try j.field("longest", gaps.longest);
    try j.field("mean", gaps.mean());
    try j.close('}');
    try writers(j, image, &one.tally);
    try j.close('}');
}

fn stores(j: anytype, key: []const u8, image: ?elf.Image, list: []const watchpoint.Store) !void {
    try j.open(key, '[');
    for (list) |store| {
        try j.open(null, '{');
        try j.field("byte", store.offset);
        try j.field("width", store.width);
        try j.field("value", store.value);
        try j.field("tick", store.when);
        try j.field("pc", store.pc);
        try symbol(j, image, store.pc);
        const caller = if (image) |loaded| symbols.inside(loaded, store.lr & ~@as(u32, 1)) else null;
        try j.field("caller", if (caller) |at| at.name else null);
        try j.field("caller_offset", if (caller) |at| at.offset else null);
        try j.close('}');
    }
    try j.close(']');
}

fn writers(j: anytype, image: ?elf.Image, counted: *const tally_mod.Tally) !void {
    try j.open("writers", '{');
    try j.open("sites", '[');
    var room: [tally_mod.limits.kept]tally_mod.Site = undefined;
    for (counted.ranked(&room)) |site| {
        try j.open(null, '{');
        try j.field("value", site.value);
        try j.field("pc", site.pc);
        try j.field("stores", site.writes);
        try symbol(j, image, site.pc);
        try j.close('}');
    }
    try j.close(']');
    try j.field("displaced", counted.displaced);
    try j.close('}');
}
