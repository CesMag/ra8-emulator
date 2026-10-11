//! CPU1 brought up beside an opened harness (RA8EMU-1147), shared by the
//! debug front and the session server. CPU1 reads its own image, runs on
//! its own Zig core paired with CPU0 for exclusive access, and waits
//! parked in the session until it is given the session or run by core.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const board_wiring = @import("ra8_board").wiring;
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const exclusive_peer = @import("ra8_chip").core.cpu.exclusive_peer;
const second_core = @import("ra8_chip").core.second_core;
const cpu1_image = @import("cpu1_image.zig");
const harness = @import("harness/harness.zig");
const step_hook = @import("step_hook.zig");
const stop_machine = @import("stop_machine.zig");
const watch_bus = @import("watch_bus.zig");

/// Holds what CPU1 runs on; it stays put while the session has it.
pub const Cpu1 = struct {
    pair: second_core.zig_run.Driver = undefined,
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,
    watching: watch_bus.WatchBus = undefined,
    bytes: []u8 = &.{},
    /// CPU1's image, for its names, frames and lines.
    image: ?elf.Image = null,
    paired: ?*cpu_mod.Cpu = null,

    /// Bring CPU1 up from the ELF at `path` beside `opened`, park it in the
    /// session and give the session back to CPU0.
    pub fn open(self: *Cpu1, allocator: std.mem.Allocator, io: std.Io, opened: *harness.Harness, path: []const u8) !void {
        self.bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(second_core.limits.image_bytes));
        errdefer allocator.free(self.bytes);
        try cpu1_image.open(&self.pair, allocator, io, board_wiring.cpu1(opened.board()), path, opened.guest());
        self.image = try elf.Image.init(self.bytes);
        const cpu1 = &self.pair.core.cpu;
        self.driver = .{ .machine = &self.machine };
        self.watching = .{ .inner = cpu1.bus, .driver = &self.driver };
        cpu1.bus = self.watching.view();
        exclusive_peer.pair(opened.primaryCpu(), cpu1);
        self.paired = opened.primaryCpu();
        const live = opened.session();
        live.live.other = .{ .core = .{ .cpu = cpu1 }, .machine = &self.machine, .watch = &self.watching, .index = 1, .budget = live.live.budget };
        opened.attachCore(.cpu1, cpu1, self.pair.guest());
        opened.bindSecond(&self.pair.second, self.pair.guest());
        try live.load(.cpu1, self.bytes);
        try live.switchTo(.cpu0);
    }

    pub fn cpu(self: *Cpu1) *cpu_mod.Cpu {
        return &self.pair.core.cpu;
    }

    pub fn close(self: *Cpu1, allocator: std.mem.Allocator) void {
        if (self.paired) |cpu0| exclusive_peer.unpair(cpu0, &self.pair.core.cpu);
        if (self.image != null) self.pair.close();
        allocator.free(self.bytes);
        self.* = .{};
    }
};
