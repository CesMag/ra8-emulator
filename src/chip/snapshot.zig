//! The snapshot sections that save several on-chip blocks, as
//! `ra8_chip.snapshot` (RA8EMU-1023). A section that saves one block sits
//! beside that block instead (cpu_snapshot.zig, sci_snapshot.zig and so on).
//! The index file for src/chip/snapshot.
pub const channels = @import("snapshot/channels.zig");
pub const clocks = @import("snapshot/clocks.zig");
pub const controllers = @import("snapshot/controllers.zig");
pub const datapath = @import("snapshot/datapath.zig");
pub const media = @import("snapshot/media.zig");
pub const security = @import("snapshot/security.zig");
pub const signals = @import("snapshot/signals.zig");
pub const systick = @import("snapshot/systick.zig");
pub const time = @import("snapshot/time.zig");
pub const timers = @import("snapshot/timers.zig");
