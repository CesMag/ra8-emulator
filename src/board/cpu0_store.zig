//! CPU0's memory for a single-core `--cpu zig` run: the Zig core's own
//! store (RA8EMU-580, slice 4d-2 of
//! RA8EMU-481). Board code since RA8EMU-996: the harness and the CLI both put
//! CPU0 on its store through here.
//!
//! The board's blocks attach over the store, CPU0's PPB windows are primed
//! into it, and the image (and any `--ns` half) is loaded into it, in the
//! order the engine path does all three. Since RA8EMU-592 a `--cpu zig` run
//! opens no engine at all: src/interfaces/cli/zig/main.zig attaches with
//! `attachStore` and reads everything back off the store.
//!
//! A run with a second core goes on the store too: CPU1 gets a store of its
//! own that borrows this one's shared SRAM (RA8EMU-588). Since RA8EMU-607
//! there is no engine arm left here: every run is on the store.
const elf = @import("image/elf.zig");
const read_image = @import("image/load.zig");
const Store = @import("ra8_chip").core.cpu.memory.store.Store;
const external = @import("external/memory.zig");
const backing = @import("external/backing.zig");
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const loader = @import("ra8_chip").core.cpu.memory.load;
const wiring = @import("wiring.zig");
const Board = @import("board.zig").Board;

pub const Cpu0 = struct {
    /// Null until `attachStore` makes it.
    store: ?Store = null,
    /// The board's SDRAM and fabric behind the store's external port.
    external: ?backing.Backing = null,

    /// Put CPU0 on a store of its own: the board's blocks, its windows, then
    /// the image. Returns the bytes the image wrote, for the opening line.
    pub fn attachStore(self: *Cpu0, board: *Board, image: elf.Image) !u32 {
        self.store = try Store.init(null);
        const layout = try external.Layout.init(board.external_memory);
        self.external = try backing.Backing.init(layout, board.nor.window());
        self.store.?.attachExternal(self.external.?.port());
        const memory = self.own();
        try wiring.attachBlocks(board, memory);
        try wiring.primeWindows(board, memory, wiring.cpu0Windows(board));
        const loaded = try read_image.read(image);
        return loader.image(memory, loaded.image());
    }

    /// The store, once `attachStore` has made it.
    pub fn own(self: *Cpu0) Guest {
        return .{ .store = &self.store.? };
    }

    /// Load a second image (the `--ns` half) into the store, if there is one.
    pub fn load(self: *Cpu0, image: elf.Image) !void {
        if (self.store == null) return;
        const loaded = try read_image.read(image);
        _ = try loader.image(.{ .store = &self.store.? }, loaded.image());
    }

    pub fn close(self: *Cpu0) void {
        if (self.store) |*held| held.deinit();
        self.store = null;
        if (self.external) |*held| held.deinit();
        self.external = null;
    }
};
