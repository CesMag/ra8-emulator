//! Snapshot and restore for a served session (RA8EMU-768): the file
//! `--save-state` writes (src/board/snapshot/run.zig, the two SysTick bases and
//! a stretch section), written from and read back into a live harness.
//!
//! This file encodes and decodes it; the harness opens the file on the
//! serving host (harness/files.zig, RA8EMU-1020).
//!
//! A session's boundary charges whole chunks, so nothing is owed and the
//! stretch section says so; `--load-state` reads the file as its own, and
//! a session restores one `--save-state` wrote. A second core is refused,
//! as the CLI refuses it: its state is not in the file yet.
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const BoardBoundary = @import("board_boundary.zig").BoardBoundary;
const Cpu = @import("ra8_chip").core.cpu.cpu.Cpu;
const Store = @import("ra8_chip").core.cpu.memory.store.Store;
const run_file = @import("ra8_board").snapshot.run;
const systick = @import("ra8_chip").snapshot.systick;
const stretch = @import("ra8_board").snapshot.stretch;

pub const Error = error{SecondCoreNotSaved};

/// What the serve handlers call; paths are on the serving host.
pub const Hook = struct {
    context: *anyopaque,
    saveFn: *const fn (*anyopaque, []const u8) anyerror!void,
    restoreFn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn save(self: Hook, path: []const u8) anyerror!void {
        return self.saveFn(self.context, path);
    }

    pub fn restore(self: Hook, path: []const u8) anyerror!void {
        return self.restoreFn(self.context, path);
    }
};

/// The parts of a harness the file holds.
pub const Files = struct {
    store: *Store,
    cpu: *Cpu,
    board: *Board,
    edge: *BoardBoundary,

    /// Writes the run file to `writer`; the caller flushes it.
    pub fn writeTo(self: *Files, writer: *std.Io.Writer) !void {
        try self.single();
        try run_file.save(writer, self.store, &.{self.cpu}, self.board);
        try systick.save(.{ &self.edge.timebase, &self.edge.ns_timebase }, writer);
        try stretch.save(.{}, writer);
    }

    /// Puts the run back as `bytes` hold it. The store is wiped first: a
    /// page the file leaves out was zero when it was saved, whatever the
    /// run wrote there since.
    pub fn readFrom(self: *Files, bytes: []const u8) !void {
        try self.single();
        try run_file.check(bytes, self.board);
        self.store.wipe();
        try run_file.load(bytes, self.store, &.{self.cpu}, self.board);
        try systick.load(.{ &self.edge.timebase, &self.edge.ns_timebase }, bytes);
    }

    /// Refuses a run with CPU1 attached: its state is not in the file yet.
    pub fn single(self: *const Files) Error!void {
        if (self.edge.second != null) return Error.SecondCoreNotSaved;
    }
};
