//! ra8_rpc: the remote adapter onto the Session (ADR 0004 sections 2 and
//! 3, knowledge base article RA8EMU-A-2). The session wire, the server and
//! its handlers, the served setup for one opened image, and the transports
//! (stdio, sockets, a child process). A local application calls the Session
//! in-process; this is for a session in another process or on another host.
//!
//! It imports the session, the components (whose endpoint, request and
//! fault types the wire carries), the host, and the firmware's wire library
//! as `ra8_rpc_wire`.
pub const card_apps = @import("card_apps.zig");
pub const child_transport = @import("child_transport.zig");
pub const host_listener = @import("host_listener.zig");
pub const served_setup = @import("served_setup.zig");
pub const served_history = @import("served_history.zig");
pub const regression_replay = @import("regression_replay.zig");
pub const served_prefetch = @import("served_prefetch.zig");
pub const prefetch_pool = @import("prefetch_pool.zig");
pub const prefetch_hook = @import("prefetch_hook.zig");
pub const frame_pipeline = @import("frame_pipeline.zig");
pub const history_bind = @import("history_bind.zig");
pub const history_bridge = @import("history_bridge.zig");
pub const object_read = @import("object_read.zig");
pub const pack_store = @import("pack_store.zig");
pub const history_live = @import("history_live.zig");
pub const history_maint = @import("history_maint.zig");
pub const history_segments = @import("history_segments.zig");
pub const history_ram = @import("history_ram.zig");
pub const session = @import("session/session.zig");
pub const backtrace_wire = @import("backtrace_wire.zig");
pub const locals_wire = @import("locals_wire.zig");
pub const socket_transport = @import("socket_transport.zig");
pub const stdio_transport = @import("stdio_transport.zig");
