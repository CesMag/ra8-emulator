//! The Zig core's own memory (RA8EMU-480/485), one import for src/root.zig.
pub const store = @import("store.zig");
pub const memory_bus = @import("bus.zig");
pub const guest = @import("guest/guest.zig");
pub const load = @import("load.zig");
pub const extra = @import("extra.zig");
pub const initiator = @import("initiator.zig");
pub const external_port = @import("external_port.zig");
