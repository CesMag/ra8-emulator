//! Sorted per-function instruction and cycle counts.
const std = @import("std");
const elf = @import("../../../board/image/elf.zig");
const profile = @import("../../../session/profile.zig");
const symbols = @import("../../../session/symbols.zig");
const stack_samples = @import("../../../session/stack_samples.zig");
const stack_profile = @import("../../../session/stack_profile.zig");
const Writer = @import("../report.zig").Writer;

pub fn write(out: Writer, io: std.Io, image: elf.Image, table: profile.Table, path: ?[]const u8) !void {
    try print(out, image, table);
    if (path) |destination| {
        const file = try std.Io.Dir.cwd().createFile(io, destination, .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try folded(&writer.interface, image, table);
        try writer.interface.flush();
    }
}

pub fn print(out: Writer, image: elf.Image, table: profile.Table) !void {
    var rows: [profile.limits.functions]profile.Site = undefined;
    const ranked = table.ranked(&rows);
    const shown = @min(ranked.len, profile.limits.listed);
    for (ranked[0..shown]) |site| {
        const found = symbols.inside(image, site.address) orelse continue;
        try out.print("profile: {s} {d} cycle(s), {d} instruction(s)\n", .{ found.name, site.cycles, site.instructions });
    }
    if (table.missed != 0) try out.print("profile: {d} instruction(s) outside sized functions or beyond table capacity\n", .{table.missed});
}

/// Folded format accepts a single frame when the emulator has no call stack
/// source; consumers can still compare where total execution accumulated.
/// With sampled call stacks it writes those instead, each row rooted at its
/// core (`cpu0;outer;...;inner n`, RA8EMU-971).
pub fn folded(out: anytype, image: elf.Image, table: profile.Table) !void {
    if (table.samples) |store| if (store.count != 0) return sampled(out, .{ &image, if (table.second) |*found| found else &image }, store);
    var rows: [profile.limits.functions]profile.Site = undefined;
    for (table.ranked(&rows)) |site| {
        const found = symbols.inside(image, site.address) orelse continue;
        try out.print("{s} {d}\n", .{ found.name, site.cycles });
    }
}

/// `images` name each core's rows: CPU0's, then CPU1's (RA8EMU-972).
fn sampled(out: anytype, images: [2]*const elf.Image, store: *const stack_samples.Store) !void {
    const allocator = std.heap.page_allocator;
    const scratch = try allocator.alloc(usize, store.count);
    defer allocator.free(scratch);
    for (0..2) |core| {
        var rows: std.Io.Writer.Allocating = .init(allocator);
        defer rows.deinit();
        try stack_samples.fold(store, .{ .core = @intCast(core) }, stack_profile.names(images[core]), &rows.writer, scratch);
        try named(out, allocator, @intCast(core), rows.written());
    }
}

const Row = struct {
    stack: []const u8,
    count: u64,

    fn before(_: void, lhs: Row, rhs: Row) bool {
        return std.mem.lessThan(u8, lhs.stack, rhs.stack);
    }
};

/// Stacks of different addresses in the same functions are one row: merge
/// them, in name order, so the same run always writes the same bytes.
fn named(out: anytype, allocator: std.mem.Allocator, core: u8, folded_rows: []const u8) !void {
    var list: std.ArrayList(Row) = .empty;
    defer list.deinit(allocator);
    var lines = std.mem.splitScalar(u8, folded_rows, '\n');
    while (lines.next()) |line| {
        const gap = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
        try list.append(allocator, .{ .stack = line[0..gap], .count = try std.fmt.parseInt(u64, line[gap + 1 ..], 10) });
    }
    std.mem.sort(Row, list.items, {}, Row.before);
    var at: usize = 0;
    while (at < list.items.len) {
        var count: u64 = 0;
        var next = at;
        while (next < list.items.len and std.mem.eql(u8, list.items[next].stack, list.items[at].stack)) : (next += 1) count += list.items[next].count;
        try out.print("cpu{d};{s} {d}\n", .{ core, list.items[at].stack, count });
        at = next;
    }
}
