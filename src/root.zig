//! The `ra8` umbrella for tests and embedders (ADR 0004 in the knowledge
//! base, RA8EMU-A-2): one name per library module and nothing else. The
//! embedding API is `session` (`ra8.session.harness.open`). The two
//! applications are not here: they are the cli_app and gui_app modules.
pub const host = @import("ra8_host");
pub const snapshot = @import("ra8_snapshot");
pub const chip = @import("ra8_chip");
pub const components = @import("ra8_components");
pub const board = @import("ra8_board");
pub const session = @import("ra8_session");
pub const render = @import("ra8_render");
pub const rpc = @import("ra8_rpc");
pub const gdb = @import("ra8_gdb");
pub const usbip = @import("ra8_usbip");
