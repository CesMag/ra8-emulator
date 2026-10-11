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
const symbols = @import("symbols.zig");
const txm_symbols = @import("txm_symbols.zig");

/// The most modules live at once; a later load past this is not placed.
pub const most = 16;

/// A module ELF and the display name it is paired under.
pub const Pair = struct { label: []const u8, image: elf.Image };

/// A loaded instance and where its ELF's code runs.
pub const Live = struct { instance: u32, module: txm_symbols.Module };

pub const Table = struct {
    pairs: []const Pair,
    count: usize = 0,
    live: [most]Live = undefined,

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
        return true;
    }

    /// Forget the instance at `instance`, if it was placed.
    pub fn unloaded(self: *Table, instance: u32) void {
        for (self.live[0..self.count], 0..) |one, index| {
            if (one.instance != instance) continue;
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

    fn pairOf(self: *const Table, name: []const u8) ?Pair {
        for (self.pairs) |pair| {
            if (std.mem.eql(u8, pair.label, name)) return pair;
        }
        return null;
    }
};
