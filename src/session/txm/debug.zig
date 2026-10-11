//! Which paired module ELF each loaded ThreadX module is (RA8EMU-1141, part
//! of RA8EMU-1084).
//!
//! `--app FILE.ra8app=MODULE.elf` pairs an app with its ELF under the app
//! header's display name, the name ra8-firmware's loader hands the Module
//! Manager. When the session sees an instance load (txm_publish), the
//! instance's name picks the pair and its code_start places the ELF's code
//! (txm_symbols.Module); when it unloads, the placement goes. Lookups ask
//! every live module, so a debugger names a module PC and finds a module
//! function by name only while that module is loaded.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const symbols = @import("../symbols.zig");
const txm_symbols = @import("symbols.zig");

/// The most modules live at once; a later load past this is not placed.
pub const most = 16;

/// The core a break watches, the session's own.
pub const Core = @import("../event/stream.zig").Core;

/// The most characters a deferred break's name keeps.
pub const max_name = 128;
/// The most breaks waiting for their module to load.
pub const max_deferred = 16;
/// Pending ids start here, above the break table's own numbering.
pub const pending_base: u32 = 0x8000_0000;

/// A break named before its module loaded, waiting to arm (RA8EMU-1141).
pub const Deferred = struct {
    core: Core,
    name: [max_name]u8,
    name_len: usize,
    id: u32,
    /// The real breakpoint once the module loaded and the name resolved.
    armed_id: ?u32 = null,
    armed_address: u32 = 0,
};

/// Places and clears real breakpoints for pending names, so the table
/// never reaches into the session.
pub const Armer = struct {
    ctx: *anyopaque,
    arm: *const fn (*anyopaque, Core, u32) anyerror!u32,
    drop: *const fn (*anyopaque, Core, u32) anyerror!void,
};

/// A module ELF and the display name it is paired under.
pub const Pair = struct { label: []const u8, image: elf.Image };

/// A loaded instance and where its ELF's code runs.
pub const Live = struct { instance: u32, module: txm_symbols.Module };

pub const Table = struct {
    pairs: []const Pair,
    count: usize = 0,
    live: [most]Live = undefined,
    deferred: [max_deferred]Deferred = undefined,
    deferred_count: usize = 0,
    next_pending: u32 = pending_base,
    armer: ?Armer = null,

    /// Place the instance at `instance`, named `name`, whose code the
    /// manager put at `code_start`. False when no pair has that name, the
    /// ELF has no code to place, or the table is full. An instance address
    /// reused by a later load replaces the earlier placement.
    pub fn loaded(self: *Table, instance: u32, name: []const u8, code_start: u32) bool {
        self.unloaded(instance);
        const pair = self.pairOf(name) orelse return false;
        const module = txm_symbols.Module.at(pair.image, code_start) orelse return false;
        if (self.count == most) return false;
        self.live[self.count] = .{ .instance = instance, .module = module };
        self.count += 1;
        self.armPending();
        return true;
    }

    /// Forget the instance at `instance`, if it was placed.
    pub fn unloaded(self: *Table, instance: u32) void {
        for (self.live[0..self.count], 0..) |one, index| {
            if (one.instance != instance) continue;
            self.dropArmed(one.module);
            self.count -= 1;
            self.live[index] = self.live[self.count];
            return;
        }
    }

    /// Where a live module runs the code symbol `name`, or null.
    pub fn addressOf(self: *const Table, name: []const u8) ?u32 {
        for (self.live[0..self.count]) |one| {
            if (one.module.addressOf(name)) |address| return address;
        }
        return null;
    }

    /// The live module function `address` falls inside, or null.
    pub fn inside(self: *const Table, address: u32) ?symbols.Inside {
        for (self.live[0..self.count]) |one| {
            if (one.module.inside(address)) |found| return found;
        }
        return null;
    }

    /// Name a break that cannot be placed yet; it arms once its module
    /// loads and a name lookup resolves it. Ids count from pending_base.
    pub fn deferBreak(self: *Table, of: Core, name: []const u8) error{ NameTooLong, NoRoom }!u32 {
        if (name.len > max_name) return error.NameTooLong;
        if (self.deferred_count == max_deferred) return error.NoRoom;
        const id = self.next_pending;
        self.next_pending += 1;
        self.deferred[self.deferred_count] = .{ .core = of, .name = undefined, .name_len = name.len, .id = id };
        @memcpy(self.deferred[self.deferred_count].name[0..name.len], name);
        self.deferred_count += 1;
        return id;
    }

    /// Forget the pending break `id`, dropping the real breakpoint when it
    /// armed. False when no pending break carries that id.
    pub fn remove(self: *Table, id: u32) bool {
        for (self.deferred[0..self.deferred_count], 0..) |one, index| {
            if (one.id != id) continue;
            if (one.armed_id) |armed| if (self.armer) |armer| armer.drop(armer.ctx, one.core, armed) catch {};
            self.deferred_count -= 1;
            self.deferred[index] = self.deferred[self.deferred_count];
            return true;
        }
        return false;
    }

    /// Arm pending breaks the live table can now resolve.
    fn armPending(self: *Table) void {
        const armer = self.armer orelse return;
        for (self.deferred[0..self.deferred_count]) |*one| {
            if (one.armed_id != null) continue;
            const address = self.addressOf(one.name[0..one.name_len]) orelse continue;
            one.armed_id = armer.arm(armer.ctx, one.core, address) catch null;
            one.armed_address = address;
        }
    }

    /// Drop the real breakpoints the dropped module's code armed; the
    /// pending entries stay, so a reload arms them again.
    fn dropArmed(self: *Table, module: txm_symbols.Module) void {
        const armer = self.armer orelse return;
        for (self.deferred[0..self.deferred_count]) |*one| {
            const armed = one.armed_id orelse continue;
            if (module.inside(one.armed_address) == null) continue;
            armer.drop(armer.ctx, one.core, armed) catch {};
            one.armed_id = null;
        }
    }

    fn pairOf(self: *const Table, name: []const u8) ?Pair {
        for (self.pairs) |pair| {
            if (std.mem.eql(u8, pair.label, name)) return pair;
        }
        return null;
    }
};
