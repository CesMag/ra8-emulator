//! The loaded-modules section of the text report (RA8EMU-1139).
//!
//! Printed only when the image names the Module Manager's list head and the
//! list holds at least one module, so every run without ThreadX modules
//! reports exactly what it did before. Layout and walk live in
//! src/session/txm_modules.zig; `--report json` writes the same `Listed`.
const std = @import("std");
const txm = @import("txm_modules.zig");

/// Modules the report lists; a longer list is cut short.
pub const most = 16;

/// The loaded modules as the run ends, each with the name it gave.
pub const Listed = struct {
    count: usize = 0,
    modules: [most]txm.Module = undefined,
    names: [most][txm.longest]u8 = undefined,
    name_lens: [most]?usize = undefined,

    pub fn rows(self: *const Listed) []const txm.Module {
        return self.modules[0..self.count];
    }

    /// Module `index`'s name, or null when it could not be read.
    pub fn name(self: *const Listed, index: usize) ?[]const u8 {
        const len = self.name_lens[index] orelse return null;
        return self.names[index][0..len];
    }
};

/// The modules on the list whose head pointer lives at `head_at`, read
/// through `memory`. Empty when `head_at` is null.
pub fn list(head_at: ?u32, memory: anytype) Listed {
    var listed: Listed = .{};
    const head = head_at orelse return listed;
    listed.count = txm.loaded(memory, head, &listed.modules);
    for (listed.modules[0..listed.count], 0..) |entry, index| {
        const found = txm.name(memory, entry, &listed.names[index]);
        listed.name_lens[index] = if (found) |text| text.len else null;
    }
    return listed;
}

/// The section for the list at `head_at`. Nothing when it is empty.
pub fn print(out: anytype, head_at: ?u32, memory: anytype) !void {
    const listed = list(head_at, memory);
    try write(out, &listed);
}

/// `listed` as text: a header, then one line per module.
pub fn write(out: anytype, listed: *const Listed) !void {
    if (listed.count == 0) return;
    try out.print("modules: {d} loaded\n", .{listed.count});
    for (listed.rows(), 0..) |entry, index| {
        try out.print("  {s} {s} code 0x{x:0>8} size {d} data 0x{x:0>8} size {d}\n", .{
            listed.name(index) orelse "?", entry.state.text(),
            entry.code_start,              entry.code_size,
            entry.data_start,              entry.data_size,
        });
    }
}
