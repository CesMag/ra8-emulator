//! Memory for the peripheral tests: the Zig core's store, which backs every
//! memmap RAM region (board SRAM, SDRAM and the rest), held on the heap so a
//! fixture can be returned by value without its handle dangling.
const std = @import("std");
const ra8 = @import("ra8");

const Store = ra8.chip.core.cpu.memory.store.Store;
pub const Guest = ra8.chip.core.cpu.memory.guest.Guest;

pub fn open() !Guest {
    const store = try std.testing.allocator.create(Store);
    errdefer std.testing.allocator.destroy(store);
    store.* = try Store.init(null);
    return .{ .store = store };
}

pub fn close(memory: Guest) void {
    memory.store.deinit();
    std.testing.allocator.destroy(memory.store);
}
