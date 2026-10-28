//! `ra8_emulator history --root DIR replay-elf SESSION --elf PATH [--json]`:
//! runs a recorded history's inputs against a rebuilt ELF and says whether
//! the rebuild is compatible with what was recorded. The history is opened
//! read-only and left as it was. Exit 0 for a compatible rebuild, 3 for a
//! diverged one; any other failure is the history command's exit 1.
const std = @import("std");
const rpc = @import("ra8_rpc");
const usbip_run = @import("ra8_usbip").exported.run;
const history = @import("ra8_host").history;

const replay = rpc.regression_replay;

pub const exit_diverged: u8 = 3;

/// Puts a bridge with no host behind it on the board's USB tick, so the
/// traffic the history recorded has a device to be fed to. Nothing listens:
/// a replay never polls the bridge.
const Hosts = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,

    fn prepare(context: *anyopaque, served: *rpc.served_setup.Served, _: []const u8) anyerror!void {
        const self: *Hosts = @ptrCast(@alignCast(context));
        try usbip_run.install(&served.owner.board().usb, self.arena.allocator(), self.io, 0);
        try served.attachUsbip();
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, base: *const history.base.Base, session: []const u8, elf_path: []const u8, json: bool, out: *std.Io.Writer) !u8 {
    var hosts: Hosts = .{ .arena = .init(allocator), .io = io };
    defer hosts.arena.deinit();
    var result = try replay.run(allocator, io, base, session, elf_path, .{ .prepare = .{ .context = &hosts, .prepareFn = Hosts.prepare } });
    defer result.deinit();
    if (json) try writeJson(out, result) else try writeText(out, session, elf_path, result);
    return if (result.verdict == .compatible) 0 else exit_diverged;
}

fn hex(identity: [16]u8) [32]u8 {
    return std.fmt.bytesToHex(identity, .lower);
}

pub fn writeText(out: *std.Io.Writer, session: []const u8, elf_path: []const u8, result: replay.Result) !void {
    const e = result.elf;
    try out.print("{s}: replayed against {s}\n", .{ session, elf_path });
    try out.print("elf: {s} -> {s}{s}\n", .{ hex(e.original.identity)[0..12], hex(e.rebuilt.identity)[0..12], if (e.identical()) " (same image)" else "" });
    try out.print("  entry 0x{x} -> 0x{x}, flags 0x{x} -> 0x{x}, segments {d} -> {d} ({d} moved, {d} changed)\n", .{ e.original.entry, e.rebuilt.entry, e.original.flags, e.rebuilt.flags, e.original.segments, e.rebuilt.segments, e.segments_moved, e.segments_changed });
    if (e.first_changed_address) |address| try out.print("  first changed byte at 0x{x}\n", .{address});
    try out.print("  symbols {d} -> {d}: {d} added, {d} removed, {d} moved, {d} resized\n", .{ e.original.symbols, e.rebuilt.symbols, e.symbols_added, e.symbols_removed, e.symbols_moved, e.symbols_resized });
    try out.print("checkpoints: {d} of {d} match, last round {d}\n", .{ result.matched, result.checkpoints, result.round });
    try out.writeAll("  (addresses either image loads as read-only, or as a load-time copy, are not compared: RAM-resident code and flash programming go unchecked)\n");
    const d = result.divergence orelse return out.writeAll("compatible\n");
    try out.print("diverged at checkpoint {d}, round {d} ({s} +{d}), core {d}, pc 0x{x} (recorded 0x{x})", .{ d.checkpoint, d.position.r, @tagName(d.position.phase), d.position.o, d.core, d.pc_actual, d.pc_expected });
    if (d.symbol) |s| try out.print(" in {s}+0x{x}", .{ s.name, s.offset });
    try out.writeAll("\n");
    if (d.stopped) |reason| return out.print("the rebuilt run stopped first: {s}\n", .{reason});
    const place = d.place orelse return out.writeAll("the state digests differ\n");
    switch (place) {
        .register => |r| try out.print("first difference: register {s}, recorded 0x{x}, rebuilt 0x{x}\n", .{ r.name, r.expected, r.actual }),
        .memory => |m| try out.print("first difference: memory 0x{x}, recorded 0x{x:0>2}, rebuilt 0x{x:0>2}\n", .{ m.address, m.expected, m.actual }),
        .section => |kind| try out.print("first difference: {s} state\n", .{@tagName(kind)}),
    }
}

pub fn writeJson(out: *std.Io.Writer, result: replay.Result) !void {
    const e = result.elf;
    try out.print("{{\"verdict\":\"{s}\",\"checkpoints\":{d},\"matched\":{d},\"round\":{d},", .{ @tagName(result.verdict), result.checkpoints, result.matched, result.round });
    try out.print("\"elf\":{{\"original\":\"{s}\",\"rebuilt\":\"{s}\",\"identical\":{},", .{ hex(e.original.identity), hex(e.rebuilt.identity), e.identical() });
    try out.print("\"entry\":[{d},{d}],\"flags\":[{d},{d}],\"segments\":[{d},{d}],\"segments_moved\":{d},\"segments_changed\":{d},", .{ e.original.entry, e.rebuilt.entry, e.original.flags, e.rebuilt.flags, e.original.segments, e.rebuilt.segments, e.segments_moved, e.segments_changed });
    try out.writeAll("\"first_changed_address\":");
    if (e.first_changed_address) |address| try out.print("{d}", .{address}) else try out.writeAll("null");
    try out.print(",\"symbols\":[{d},{d}],\"symbols_added\":{d},\"symbols_removed\":{d},\"symbols_moved\":{d},\"symbols_resized\":{d},\"first_changed_symbol\":", .{ e.original.symbols, e.rebuilt.symbols, e.symbols_added, e.symbols_removed, e.symbols_moved, e.symbols_resized });
    try writeName(out, e.first_changed_symbol);
    try out.writeAll("},\"divergence\":");
    if (result.divergence) |d| try writeDivergence(out, d) else try out.writeAll("null");
    try out.writeAll("}\n");
}

fn writeName(out: *std.Io.Writer, name: ?[]const u8) !void {
    if (name) |text| try out.print("{f}", .{std.json.fmt(text, .{})}) else try out.writeAll("null");
}

fn writeDivergence(out: *std.Io.Writer, d: replay.Divergence) !void {
    try out.print("{{\"checkpoint\":{d},\"round\":{d},\"position\":{{\"r\":{d},\"phase\":\"{s}\",\"o\":{d}}},\"core\":{d},\"pc_expected\":{d},\"pc_actual\":{d},\"symbol\":", .{ d.checkpoint, d.position.r, d.position.r, @tagName(d.position.phase), d.position.o, d.core, d.pc_expected, d.pc_actual });
    if (d.symbol) |s| {
        try out.writeAll("{\"name\":");
        try writeName(out, s.name);
        try out.print(",\"offset\":{d}}}", .{s.offset});
    } else try out.writeAll("null");
    try out.writeAll(",\"where\":");
    if (d.stopped) |reason| {
        try out.print("{{\"kind\":\"stopped\",\"reason\":\"{s}\"}}}}", .{reason});
        return;
    }
    const place = d.place orelse {
        try out.writeAll("{\"kind\":\"digest\"}}");
        return;
    };
    switch (place) {
        .register => |r| try out.print("{{\"kind\":\"register\",\"name\":\"{s}\",\"expected\":{d},\"actual\":{d}}}", .{ r.name, r.expected, r.actual }),
        .memory => |m| try out.print("{{\"kind\":\"memory\",\"address\":{d},\"expected\":{d},\"actual\":{d}}}", .{ m.address, m.expected, m.actual }),
        .section => |kind| try out.print("{{\"kind\":\"section\",\"name\":\"{s}\"}}", .{@tagName(kind)}),
    }
    try out.writeAll("}");
}
