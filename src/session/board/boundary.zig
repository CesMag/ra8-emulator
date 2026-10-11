//! The board's boundary as the debugger's run passes it (RA8EMU-709).
//! Board.tick wants the guest events are pended on; under the debugger
//! that is CPU0's memory, the same guest a plain run ticks with. CPU1's
//! lines are re-pended by the boundary itself (events.rependOn).
//! A sleeping CPU0 may reach to the board's next edge (RA8EMU-767), as a
//! plain run's idle skip does (src/interfaces/cli/zig/run.zig asleepWidth).
const Board = @import("ra8_board").board.Board;
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const Cpu = @import("ra8_chip").core.cpu.cpu.Cpu;
const Reboot = @import("ra8_chip").core.reboot.Reboot;
const systick_bank = @import("ra8_chip").core.systick_bank;
const clocks = @import("ra8_chip").periph.clocks;
const zig_boundary = @import("../zig/boundary.zig");
const second_core = @import("ra8_chip").core.second.core;
const chunk_clock = @import("../chunk_clock.zig");
const registry = @import("ra8_chip").periph.registry;
const quiet_due = @import("ra8_board").quiet_due;
const board_edge = @import("ra8_board").boundary;
const sleep_pace = @import("ra8_chip").core.sleep_pace;

pub const BoardBoundary = struct {
    board: *Board,
    core: Guest,
    cpu: ?*Cpu = null,
    reboot: ?*Reboot = null,
    timebase: clocks.Clocks = .{},
    ns_timebase: clocks.Clocks = .{ .words = systick_bank.non_secure_words },
    selected: ?*const u8 = null,
    second: ?*second_core.Second = null,
    second_memory: ?Guest = null,
    /// Told when the board takes a chunk, so events inside the next one are
    /// stamped with the board time they happened at (RA8EMU-1120).
    chunk: ?*chunk_clock.ChunkClock = null,

    pub fn hook(self: *BoardBoundary) zig_boundary.Boundary {
        return .{ .context = self, .tickFn = tick, .sleepFn = asleep, .awakeFn = awake };
    }

    /// An awake CPU0's width: up to a plain run's stretch, cut to the
    /// nearest edge `asleep` would wait for or the input script's next
    /// event, so each lands on its own boundary (RA8EMU-1120). A found RTT
    /// block drains per boundary, so it keeps `normal`, as do the cases
    /// `asleep` keeps it for.
    fn awake(context: *anyopaque, normal: u32) u32 {
        const self: *BoardBoundary = @ptrCast(@alignCast(context));
        if (!self.wide() or self.board.trace.found != null) return normal;
        var width = @max(normal, self.timebase.per_chunk);
        for (self.edges()) |edge| {
            if (edge != 0 and edge < width) width = @intCast(edge);
        }
        return @max(normal, width);
    }

    /// CPU0 alone and selected, and no block moving per boundary.
    fn wide(self: *const BoardBoundary) bool {
        if (self.second != null) return false;
        if (self.selected) |selected| if (selected.* != @backingInt(registry.Issuer.cpu0)) return false;
        return quiet_due.quietUntilDue(self.board);
    }

    /// Cycles to each edge a chunk must not cross; zero for none.
    fn edges(self: *const BoardBoundary) [6]u64 {
        const script = if (self.board.input_script.nextDue()) |at| self.board.time.base.cyclesUntil(at) else 0;
        return .{
            self.timebase.untilWrap(self.core),
            self.ns_timebase.untilWrap(self.core),
            board_edge.cyclesToDue(self.board),
            quiet_due.vsyncDue(self.board),
            quiet_due.gptDue(self.board),
            script,
        };
    }

    /// A sleeping CPU0's width: whole chunks to the nearest SysTick wrap of
    /// either bank, queued board event, vsync or GPT edge. Board time here
    /// is one cycle per instruction, so the edges need no scaling. CPU1
    /// bound or selected, or a block that moves per boundary, keeps `normal`.
    fn asleep(context: *anyopaque, normal: u32) u32 {
        const self: *BoardBoundary = @ptrCast(@alignCast(context));
        if (!self.wide()) return normal;
        const all = self.edges();
        return sleep_pace.width(normal, true, all[0..5]);
    }

    fn tick(context: *anyopaque, instructions: u32) anyerror!void {
        const self: *BoardBoundary = @ptrCast(@alignCast(context));
        if (self.chunk) |chunk| chunk.handOver();
        try self.timebase.advance(self.core, instructions);
        try self.ns_timebase.advanceSysTick(self.core, instructions);
        const issuer: registry.Issuer = if (self.selected) |selected| @fromBackingInt(@intCast(selected.*)) else .cpu0;
        try self.board.tickFrom(self.core, instructions, issuer);
        if (issuer == .cpu1) if (self.second) |unit| unit.takeResetRequest(self.second_memory.?);
        const pending = self.reboot orelse return;
        if (!pending.requested) return;
        const cpu = self.cpu orelse return error.NoRebootCore;
        pending.requested = false;
        pending.performed +%= 1;
        const retired = cpu.retired;
        try cpu.reset(pending.vector_base);
        cpu.retired = retired;
    }
};
