//! ra8_board: the board as a library (ADR 0004 sections 2 and 3, knowledge
//! base article RA8EMU-A-2). Board construction and wiring, the boundary,
//! the core clock, the event sink, the plug layer, the board profile, the
//! image loader, board memory and sizing, run policy, and the snapshot of a
//! whole board and run. It imports the chip, the components and the
//! snapshot format, and nothing above it.
//!
//! The board's own files are exported by name. Each namespace below is the
//! index file beside its directory.
pub const run = @import("run.zig");
pub const image = @import("image.zig");
pub const snapshot = @import("snapshot.zig");
pub const sizing = @import("sizing.zig");
pub const board = @import("board.zig");
pub const boundary = @import("boundary.zig");
pub const camera_install = @import("camera_install.zig");
pub const core_clock = @import("core_clock.zig");
pub const cpu0_store = @import("cpu0_store.zig");
pub const display_settled = @import("display_settled.zig");
pub const event_sink = @import("event_sink.zig");
pub const external_backing = @import("external_backing.zig");
pub const external_memory = @import("external_memory.zig");
pub const frame_capture = @import("frame_capture.zig");
pub const i2c = @import("i2c.zig");
pub const net = @import("net.zig");
pub const plug = @import("plug.zig");
pub const profile = @import("profile.zig");
pub const quiet_due = @import("quiet_due.zig");
pub const run_hook = @import("run_hook.zig");
pub const switches = @import("switches.zig");
pub const usb = @import("usb.zig");
pub const usb_plug = @import("usb_plug.zig");
pub const wiring = @import("wiring.zig");
