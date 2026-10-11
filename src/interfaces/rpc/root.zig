//! ra8_rpc: the remote adapter onto the Session (ADR 0004 sections 2 and
//! 3, knowledge base article RA8EMU-A-2). The session wire, the server and
//! its handlers, the served setup for one opened image, and the transports
//! (stdio, sockets, a child process). A local application calls the Session
//! in-process; this is for a session in another process or on another host.
//!
//! It imports the session, the components (whose endpoint, request and
//! fault types the wire carries), the host, and the firmware's wire library
//! as `ra8_rpc_wire`.
pub const child_transport = @import("child_transport.zig");
pub const served_setup = @import("served_setup.zig");
pub const session_advance = @import("session_advance.zig");
pub const session_camera = @import("session_camera.zig");
pub const session_event_feed = @import("session_event_feed.zig");
pub const session_files = @import("session_files.zig");
pub const session_input = @import("session_input.zig");
pub const session_lcd_feed = @import("session_lcd_feed.zig");
pub const session_parts = @import("session_parts.zig");
pub const session_rpc = @import("session_rpc.zig");
pub const session_rtc = @import("session_rtc.zig");
pub const session_server = @import("session_server.zig");
pub const session_stack = @import("session_stack.zig");
pub const session_backtrace = @import("session_backtrace.zig");
pub const session_periph = @import("session_periph.zig");
pub const session_folded = @import("session_folded.zig");
pub const backtrace_wire = @import("backtrace_wire.zig");
pub const socket_transport = @import("socket_transport.zig");
pub const stdio_transport = @import("stdio_transport.zig");
