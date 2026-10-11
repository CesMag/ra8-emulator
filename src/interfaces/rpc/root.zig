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
pub const session = @import("session/session.zig");
pub const backtrace_wire = @import("backtrace_wire.zig");
pub const socket_transport = @import("socket_transport.zig");
pub const stdio_transport = @import("stdio_transport.zig");
