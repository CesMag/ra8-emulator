//! `info breakpoints`: the breaks and watches one core holds, in the
//! layout gdb prints them in, so a script that reads one reads the other.
//!
//! Breaks and watches keep their own numbers (src/session/break_table.zig,
//! src/session/watch_table.zig), so the list interleaves them by number.
const std = @import("std");
const break_table = @import("break_table.zig");
const watch_table = @import("watch_table.zig");
const elf = @import("ra8_board").image.elf;
const symbols = @import("symbols.zig");
const session_source = @import("source.zig");
const dwarf_line = @import("dwarf_line.zig");

pub const header = "Num     Type            Disp Enb Address    What\n";
pub const empty = "No breakpoints or watchpoints.\n";

/// What the list is drawn from.
pub const View = struct {
    breaks: *const break_table.Table,
    watches: *const watch_table.Table,
    /// Breaks set with `tbreak`: gdb shows them as `del`.
    temporary: []const break_table.Id = &.{},
    image: ?elf.Image = null,
};

pub fn write(out: anytype, view: View) !void {
    const breaks = view.breaks.entries();
    const watches = view.watches.entries();
    if (breaks.len == 0 and watches.len == 0) return out.writeAll(empty);
    try out.writeAll(header);
    var next_break: usize = 0;
    var next_watch: usize = 0;
    while (next_break < breaks.len or next_watch < watches.len) {
        const take_break = next_watch == watches.len or
            (next_break < breaks.len and breaks[next_break].id <= watches[next_watch].id);
        if (take_break) {
            try breakRow(out, view, breaks[next_break]);
            next_break += 1;
        } else {
            try watchRow(out, view, watches[next_watch]);
            next_watch += 1;
        }
    }
}

fn breakRow(out: anytype, view: View, slot: anytype) !void {
    const disposition = if (temporary(view.temporary, slot.id)) "del" else "keep";
    try out.print("{d:<8}{s:<16}{s:<5}{s:<4}0x{x:0>8} ", .{ slot.id, "breakpoint", disposition, enabled(slot.enabled), slot.point.address });
    try where(out, view.image, slot.point.address);
    try out.writeAll("\n");
    try hits(out, slot.point.seen);
    if (slot.point.arrival > slot.point.seen + 1) {
        try out.print("\tWill ignore next {d} crossings of breakpoint.\n", .{slot.point.arrival - slot.point.seen - 1});
    }
}

fn watchRow(out: anytype, view: View, slot: anytype) !void {
    const kind = switch (slot.watch.kind) {
        .write => "hw watchpoint",
        .read => "read watchpoint",
        .access => "acc watchpoint",
    };
    try out.print("{d:<8}{s:<16}{s:<5}{s:<4}{s:<11}", .{ slot.id, kind, "keep", enabled(slot.enabled), "" });
    try expression(out, view.image, slot.watch.first);
    try out.writeAll("\n");
    try hits(out, slot.watch.seen);
}

/// `in FUNCTION at FILE:LINE` when the line table covers the address,
/// `<SYMBOL+OFFSET>` when only the symbol table does, otherwise nothing.
fn where(out: anytype, image: ?elf.Image, address: u32) !void {
    const loaded = image orelse return;
    const found = symbols.inside(loaded, address) orelse return;
    const line = dwarf_line.lookup(session_source.of(image), address) catch null;
    if (line) |place| return out.print("in {s} at {s}:{d}", .{ found.name, place.file.name, place.line });
    if (found.offset == 0) return out.print("<{s}>", .{found.name});
    try out.print("<{s}+{d}>", .{ found.name, found.offset });
}

/// A watch covers one word: the symbol that starts there, or the word as
/// gdb writes it.
fn expression(out: anytype, image: ?elf.Image, address: u32) !void {
    if (image) |loaded| {
        if (symbols.inside(loaded, address)) |found| {
            if (found.offset == 0) return out.print("{s}", .{found.name});
        }
    }
    try out.print("*(int*)0x{x:0>8}", .{address});
}

fn hits(out: anytype, seen: u32) !void {
    if (seen == 0) return;
    const plural = if (seen == 1) "" else "s";
    try out.print("\tbreakpoint already hit {d} time{s}\n", .{ seen, plural });
}

fn enabled(on: bool) []const u8 {
    return if (on) "y" else "n";
}

fn temporary(held: []const break_table.Id, id: break_table.Id) bool {
    return std.mem.indexOfScalar(break_table.Id, held, id) != null;
}
