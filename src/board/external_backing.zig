//! The board's off-chip memory behind the chip's external port
//! (RA8EMU-1041): the SDRAM backing bytes and the fabric that meters every
//! SDRAM and OSPI access. CPU0's store attaches the port and CPU1's borrows
//! it, so both cores share one SDRAM and one timing model.
const std = @import("std");
const external = @import("external_memory.zig");
const external_port = @import("ra8_chip").core.cpu.memory.external_port;
const mapped = @import("ra8_chip").core.cpu.mapped;
const Store = @import("ra8_chip").core.cpu.memory.store.Store;
const Initiator = @import("ra8_chip").core.cpu.memory.initiator.Initiator;

pub const Error = error{OutOfMemory};

pub const Backing = struct {
    sdram: []u8,
    fabric: *external.Fabric,
    flash: mapped.Mapped,

    /// Size the OSPI device and allocate zeroed SDRAM for the layout.
    pub fn init(layout: external.Layout, flash: mapped.Mapped) Error!Backing {
        try flash.resize(layout.size(.ospi));
        const allocator = std.heap.page_allocator;
        const sdram = allocator.alloc(u8, layout.size(.sdram)) catch return Error.OutOfMemory;
        errdefer allocator.free(sdram);
        @memset(sdram, 0);
        const fabric = allocator.create(external.Fabric) catch return Error.OutOfMemory;
        fabric.* = external.Fabric.init(layout);
        return .{ .sdram = sdram, .fabric = fabric, .flash = flash };
    }

    /// Free the backing. Every store that attached it must be gone first.
    pub fn deinit(self: *Backing) void {
        std.heap.page_allocator.free(self.sdram);
        std.heap.page_allocator.destroy(self.fabric);
        self.* = undefined;
    }

    pub fn port(self: *const Backing) external_port.Port {
        return .{
            .geometry = self.fabric.layout.geometry(),
            .sdram = self.sdram,
            .flash = self.flash,
            .meter = .{ .context = self.fabric, .charge = charge },
        };
    }
};

/// The fabric metering a store's external port, if a board backing is
/// attached to it.
pub fn fabricOf(store: *const Store) ?*external.Fabric {
    const attached = store.port orelse return null;
    if (attached.meter.charge != &charge) return null;
    return @ptrCast(@alignCast(attached.meter.context));
}

fn charge(context: *anyopaque, initiator: Initiator, hit: external.Hit, direction: external.Direction, len: usize) void {
    const fabric: *external.Fabric = @ptrCast(@alignCast(context));
    fabric.note(initiator, hit, direction, len);
}
