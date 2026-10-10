//! A board attached the way a `--cpu zig` run attaches it, for the
//! `--report json` tests: every block over CPU0's own store, then CPU0's
//! windows primed into it. Some blocks (the DMAC among them) are only built
//! by attaching, exactly as in a real run, so a bare Board.init() is not a
//! board the report can read.
const std = @import("std");
const ra8 = @import("ra8");

const wiring = ra8.board.wiring;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;

pub const Fixture = struct {
    store: Store,
    board: ra8.board.board.Board,

    /// Open in place: the board keeps pointers into itself once attached.
    pub fn open(self: *Fixture) !void {
        self.store = try Store.init(null);
        errdefer self.store.deinit();
        self.board = ra8.board.board.Board.init(std.testing.allocator);
        errdefer self.board.deinit();
        try wiring.attachBlocks(&self.board, self.memory());
        try wiring.primeWindows(&self.board, self.memory(), wiring.cpu0Windows(&self.board));
    }

    /// CPU0's memory, as the report's readers take it.
    pub fn memory(self: *Fixture) Guest {
        return .{ .store = &self.store };
    }

    pub fn close(self: *Fixture) void {
        self.board.deinit();
        self.store.deinit();
    }
};
