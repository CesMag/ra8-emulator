//! The Zig core's memory bus over a memory.Guest (RA8EMU-534).
const bus = @import("../bus.zig");
const MemoryBus = @import("bus.zig").MemoryBus;
const Guest = @import("guest.zig").Guest;

pub const GuestBus = union(enum) {
    store: MemoryBus,

    /// The bus over `memory`. `fast` opens direct internal MRAM/SRAM only;
    /// external memory remains on the vtable so timing is never bypassed.
    pub fn of(memory: *const Guest, fast: bool) GuestBus {
        return .{ .store = .{ .store = memory.store, .initiator = memory.initiator, .fast_enabled = fast } };
    }

    pub fn view(self: *GuestBus) bus.Bus {
        return switch (self.*) {
            .store => |*memory| memory.view(),
        };
    }
};
