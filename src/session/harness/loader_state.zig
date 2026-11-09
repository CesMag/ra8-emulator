//! The session's per-core load hook: maps a freshly loaded image onto a
//! core's memory and reboots it at the new image's vector table.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const read_image = @import("ra8_board").image.load;
const memory_load = @import("ra8_chip").core.cpu.memory.load;
const memmap = @import("ra8_chip").core.memmap;
const Reboot = @import("ra8_chip").core.reboot.Reboot;
const run_file = @import("ra8_board").snapshot.run;
const session_api = @import("../api.zig");

pub const LoaderState = struct {
    allocator: std.mem.Allocator,
    cpu: [2]?*cpu_mod.Cpu = .{ null, null },
    memory: [2]?Guest = .{ null, null },
    /// An owned copy of each core's last loaded image (RA8EMU-794); replaced on every load.
    loaded: [2]?[]u8 = .{ null, null },
    /// Precomputed 16-byte image identity for each core's last loaded image.
    hashes: [2]?[16]u8 = .{ null, null },
    /// Where a reset the firmware asks for restarts CPU0; a load moves it to
    /// the new image's vector table (RA8EMU-959), or the replaced image would boot.
    reboot: ?*Reboot = null,

    pub fn load(context: *anyopaque, core: session_api.Core, bytes: []const u8) anyerror!void {
        const self: *LoaderState = @ptrCast(@alignCast(context));
        const image = try elf.Image.init(bytes);
        const index = @backingInt(core);
        const cpu = self.cpu[index] orelse return error.CoreNotAttached;
        const memory = self.memory[index] orelse return error.CoreNotAttached;
        // The same map and option-window claim a `--cpu zig` run loads with (RA8EMU-760).
        const loaded = try read_image.read(image);
        _ = try memory_load.image(memory, loaded.image());
        const base = image.vectorBase() orelse return error.NoVectorTable;
        try cpu.reset(base);
        // CPU1 exposes its initial table through VTOR after reset clears SCS.
        if (core == .cpu1) try cpu.bus.writeWord(memmap.scb.vtor, base);
        if (core == .cpu0) if (self.reboot) |reboot| {
            reboot.vector_base = base;
        };
        const copy = try self.allocator.dupe(u8, bytes);
        if (self.loaded[index]) |old| self.allocator.free(old);
        self.loaded[index] = copy;
        self.hashes[index] = run_file.imageIdentity(copy);
    }

    pub fn deinit(self: *LoaderState) void {
        for (self.loaded) |kept| if (kept) |bytes| self.allocator.free(bytes);
    }
};
