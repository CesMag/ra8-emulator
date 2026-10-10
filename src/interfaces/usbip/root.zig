//! ra8_usbip: the board's full-speed USB device exported to usbip hosts
//! (ADR 0004 section 2, knowledge base article RA8EMU-A-2). It imports the
//! board, the chip (the USBFS device model it drives) and the host.
pub const exported = @import("exported.zig");
pub const wire = @import("wire.zig");
