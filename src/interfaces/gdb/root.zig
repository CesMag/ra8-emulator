//! ra8_gdb: the GDB remote serial protocol server, a second adapter onto
//! the Session (ADR 0004 sections 2 and 3, knowledge base article
//! RA8EMU-A-2). It imports the session, the chip (the ITM console and the
//! DWT and DCB units it reads) and the host.
pub const rsp_dispatch = @import("rsp/dispatch.zig");
pub const rsp_features = @import("rsp/features.zig");
pub const rsp_packet = @import("rsp/packet.zig");
pub const rsp_poll = @import("rsp/poll.zig");
