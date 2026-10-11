//! The loaded-modules section of the text report (RA8EMU-1139).
//!
//! Printed only when the image names the Module Manager's list head and the
//! list holds at least one module, so every run without ThreadX modules
//! reports exactly what it did before. Layout and walk live in
//! src/session/txm_modules.zig.
const std = @import("std");
const txm = @import("txm_modules.zig");

/// Modules the report lists; a longer list is cut short.
pub const most = 16;

/// The section for the list whose head pointer lives at `head_at`, read
/// through `memory`. Nothing when `head_at` is null or the list is empty.
pub fn print(out: anytype, head_at: ?u32, memory: anytype) !void {
    const head = head_at orelse return;
    var found: [most]txm.Module = undefined;
    const count = txm.loaded(memory, head, &found);
    if (count == 0) return;
    try out.print("modules: {d} loaded\n", .{count});
    for (found[0..count]) |entry| try line(out, entry, memory);
}

/// One module: name, state, then where its code and data sit.
pub fn line(out: anytype, entry: txm.Module, memory: anytype) !void {
    var buffer: [txm.longest]u8 = undefined;
    const name = txm.name(memory, entry, &buffer) orelse "?";
    try out.print("  {s} {s} code 0x{x:0>8} size {d} data 0x{x:0>8} size {d}\n", .{
        name,             entry.state.text(),
        entry.code_start, entry.code_size,
        entry.data_start, entry.data_size,
    });
}
