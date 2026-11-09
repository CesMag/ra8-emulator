//! The Zig core's bus over its store, retaining the Guest initiator identity for
//! external-memory timing and instrumentation.
const bus = @import("../bus.zig");
const memmap = @import("../../memmap.zig");
const Initiator = @import("initiator.zig").Initiator;
const Store = @import("store.zig").Store;

pub const MemoryBus = struct {
    store: *Store,
    initiator: Initiator = .none,
    fast_enabled: bool = false,
    direct: bus.DirectMemory = .{},

    pub fn view(self: *MemoryBus) bus.Bus {
        self.direct = .{
            .touched = self.store.touches(),
            .flash = self.store.mutRegion(memmap.mram_base),
            .sram = self.store.mutRegion(memmap.sram_base),
            .enabled = self.fast_enabled,
            .checking = self.direct.checking,
            .observer = self.store.trail(),
            .initiator = self.initiator,
            .lines = self.store.fan(),
        };
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write }, .direct = &self.direct, .lines = self.store.fanMut() };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *MemoryBus = @ptrCast(@alignCast(ctx));
        self.store.read(self.initiator, address, into) catch return bus.Error.Unmapped;
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *MemoryBus = @ptrCast(@alignCast(ctx));
        self.store.write(self.initiator, address, bytes) catch return bus.Error.Unmapped;
    }
};
