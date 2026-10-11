//! The registers pane (RA8EMU-741): one core's registers, RAD Debugger
//! style, a name column and an eight-digit hex value, run down a column and
//! then across as many columns as the area holds. A value that differs from
//! the snapshot taken before the last run or step draws in `changed`, so a
//! step shows what it touched.
//!
//! The pane names its registers as text and never imports the session;
//! gui/registers_capture.zig turns the names into session registers and
//! fills a Snapshot. `draw` reads only the snapshot, so the shell redraws
//! without touching a core.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const colors = @import("colors.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const background = colors.background;
pub const muted = colors.muted;
pub const ink = colors.ink;
pub const changed = colors.highlight;
/// The pc cell is always marked: it moves on every step, so `changed` would say nothing.
pub const pc_mark = colors.pc_cyan;
pub const heading = colors.accent;
pub const pad: i32 = 4;
/// A row is one text line with a pixel of air above and below.
pub const row_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;
/// Characters a name takes: "faultmask" (or a lane, "q7[3]") plus a gap.
pub const name_len: usize = 10;
/// Characters one column takes: the name, eight hex digits and a gap.
pub const column_len: usize = name_len + 8 + 2;

/// The order the pane shows, group by group: the core group (the general
/// registers, the three that say where execution is, and status), the
/// system group (both stack pointers and their limits, the masks, CONTROL),
/// the FPU group (FPSCR and the single-precision bank, Ozone's order), then
/// VPR, which opens the MVE group. Each name is a session register's tag;
/// gui/registers_capture.zig checks that at comptime.
pub const names = [_][]const u8{
    "r0",  "r1",   "r2",  "r3",  "r4",     "r5",     "r6",      "r7",      "r8",        "r9",      "r10",   "r11", "r12", "sp",  "lr",
    "pc",  "xpsr", "msp", "psp", "msplim", "psplim", "primask", "basepri", "faultmask", "control", "fpscr", "s0",  "s1",  "s2",  "s3",
    "s4",  "s5",   "s6",  "s7",  "s8",     "s9",     "s10",     "s11",     "s12",       "s13",     "s14",   "s15", "s16", "s17", "s18",
    "s19", "s20",  "s21", "s22", "s23",    "s24",    "s25",     "s26",     "s27",       "s28",     "s29",   "s30", "s31", "vpr",
};

/// MVE's q0-q7 alias the FP bank (src/chip/core/cpu/mve/qreg.zig): lane k of qN
/// is S[4N+k]. The MVE group draws each q as four lane cells from the S
/// values already read, so a vector costs no extra read and its changed
/// mark is per lane (RA8EMU-947).
pub const lanes: usize = 32;
/// Every cell the pane can draw: one per named register, then the q lanes.
pub const cells: usize = names.len + lanes;
const s0_at = indexOf("s0");

/// Where `name` sits in `names`.
fn indexOf(comptime name: []const u8) usize {
    for (names, 0..) |each, index| {
        if (std.mem.eql(u8, each, name)) return index;
    }
    @compileError("no register named " ++ name);
}

const lane_names: [lanes][]const u8 = blk: {
    // 32 comptimePrint calls run past the default comptime branch budget.
    @setEvalBranchQuota(20_000);
    var out: [lanes][]const u8 = undefined;
    for (0..lanes) |k| out[k] = std.fmt.comptimePrint("q{d}[{d}]", .{ k / 4, k % 4 });
    break :blk out;
};

/// Which value in a Snapshot cell `cell` draws.
pub fn valueIndex(cell: usize) usize {
    return if (cell < names.len) cell else s0_at + (cell - names.len);
}

/// The name cell `cell` draws.
pub fn label(cell: usize) []const u8 {
    return if (cell < names.len) names[cell] else lane_names[cell - names.len];
}

/// Only CPU0, the Cortex-M85 (core profile m85), has MVE; CPU1 runs the
/// M33 profile, so its pane has no MVE group and never reads VPR.
pub fn hasMve(core: anytype) bool {
    return core == .cpu0;
}

/// A run of cells under one header that folds it away.
pub const Group = struct { name: []const u8, first: usize, len: usize };

pub const groups = [_]Group{
    .{ .name = "core", .first = 0, .len = 17 },
    .{ .name = "system", .first = 17, .len = 8 },
    .{ .name = "fpu", .first = 25, .len = 33 },
    .{ .name = "mve", .first = 58, .len = 1 + lanes },
};

/// The groups a pane draws: all of them on an MVE core, all but the last
/// (MVE) otherwise.
pub fn groupCount(mve: bool) usize {
    return if (mve) groups.len else groups.len - 1;
}

comptime {
    var next: usize = 0;
    for (groups) |group| {
        std.debug.assert(group.first == next);
        next += group.len;
    }
    std.debug.assert(next == cells);
    std.debug.assert(std.mem.eql(u8, groups[groups.len - 1].name, "mve"));
}

/// Which groups are folded down to their header.
pub const Fold = [groups.len]bool;
pub const open: Fold = @splat(false);

pub const Snapshot = struct {
    values: [names.len]u32 = @splat(0),
    /// The core has MVE: VPR was read and the MVE group draws.
    mve: bool = false,

    /// Did register `index` change since `before`? Nothing has changed
    /// when there is no earlier snapshot.
    pub fn changedAt(self: Snapshot, before: ?Snapshot, index: usize) bool {
        const old = before orelse return false;
        return old.values[index] != self.values[index];
    }
};

/// How many cells fit down one column of `area`.
pub fn rows(area: Rect) usize {
    const inner = area.h - 2 * pad;
    if (inner < row_h) return 0;
    return @intCast(@divTrunc(inner, row_h));
}

/// How many columns fit across `area`.
pub fn columns(area: Rect) usize {
    const inner = area.w - 2 * pad;
    const width: i32 = @intCast(font.textWidth(column_len));
    if (inner < width) return 0;
    return @intCast(@divTrunc(inner, width));
}

/// Cell `index`'s rectangle, or null when its group is folded or it does
/// not fit.
pub fn cellRect(area: Rect, fold: Fold, index: usize) ?Rect {
    return slotRect(area, slotOf(fold, index) orelse return null);
}

/// Group `which`'s header, or null when it does not fit.
pub fn headerRect(area: Rect, fold: Fold, which: usize) ?Rect {
    return slotRect(area, headerSlot(fold, which));
}

/// The group whose header holds (`x`, `y`), or null. `mve` says whether
/// the MVE group is drawn.
pub fn headerAt(area: Rect, fold: Fold, mve: bool, x: i32, y: i32) ?usize {
    for (0..groupCount(mve)) |which| {
        const header = headerRect(area, fold, which) orelse return null;
        if (header.contains(x, y)) return which;
    }
    return null;
}

/// Headers and cells share one run of slots, down a column and then
/// across; a folded group keeps only its header slot.
fn slotRect(area: Rect, slot: usize) ?Rect {
    const down = rows(area);
    if (down == 0) return null;
    const column = slot / down;
    if (column >= columns(area)) return null;
    const width: i32 = @intCast(font.textWidth(column_len));
    return .{
        .x = area.x + pad + @as(i32, @intCast(column)) * width,
        .y = area.y + pad + @as(i32, @intCast(slot % down)) * row_h,
        .w = width,
        .h = row_h,
    };
}

fn slotOf(fold: Fold, index: usize) ?usize {
    var slot: usize = 0;
    for (groups, fold) |group, folded| {
        if (index < group.first + group.len) return if (folded) null else slot + 1 + (index - group.first);
        slot += slots(group, folded);
    }
    return null;
}

fn headerSlot(fold: Fold, which: usize) usize {
    var slot: usize = 0;
    for (groups[0..which], fold[0..which]) |group, folded| slot += slots(group, folded);
    return slot;
}

fn slots(group: Group, folded: bool) usize {
    return if (folded) 1 else 1 + group.len;
}

/// Where register `index`'s value text starts inside its cell.
pub fn valueOrigin(cell: Rect) struct { x: i32, y: i32 } {
    return .{ .x = cell.x + 2 + @as(i32, @intCast(font.textWidth(name_len))), .y = cell.y + 2 };
}

pub fn draw(list: *draw_list.DrawList, area: Rect, now: Snapshot, before: ?Snapshot, fold: Fold) !void {
    if (slotRect(area, 0) == null) return;
    try list.fill(area, background);
    try list.pushClip(area);
    defer list.popClip();
    const count = groupCount(now.mve);
    for (groups[0..count], fold[0..count], 0..) |group, folded, which| {
        const header = headerRect(area, fold, which) orelse break;
        try drawHeader(list, header, group.name, folded);
        if (folded) continue;
        for (group.first..group.first + group.len) |index| {
            const cell = cellRect(area, fold, index) orelse break;
            const at = valueIndex(index);
            try drawCell(list, cell, label(index), now.values[at], now.changedAt(before, at));
        }
    }
}

fn drawHeader(list: *draw_list.DrawList, cell: Rect, name: []const u8, folded: bool) !void {
    try font.draw(list, cell.x + 2, cell.y + 2, if (folded) "+" else "-", heading);
    try font.draw(list, cell.x + 2 + @as(i32, @intCast(font.textWidth(2))), cell.y + 2, name, heading);
}

fn drawCell(list: *draw_list.DrawList, cell: Rect, name: []const u8, value: u32, moved: bool) !void {
    const is_pc = std.mem.eql(u8, name, "pc");
    if (is_pc) {
        try list.fill(cell, colors.pc_band_bg);
    } else if (moved) {
        try list.fill(cell, colors.dirty_cell_bg);
    }
    const name_color = if (is_pc) pc_mark else muted;
    try font.draw(list, cell.x + 2, cell.y + 2, name, name_color);
    var buffer: [8]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{X:0>8}", .{value});
    const at = valueOrigin(cell);
    const val_color = if (is_pc) pc_mark else if (moved) changed else ink;
    try font.draw(list, at.x, at.y, text, val_color);
}
