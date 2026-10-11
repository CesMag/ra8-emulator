//! Pluggable device models (RA8EMU-210): where a model attaches, the
//! catalog that makes one, the parts it knows, and a run's ask for one.
pub const endpoint = @import("endpoint.zig");
pub const catalog = @import("catalog.zig");
pub const parts = @import("parts.zig");
pub const request = @import("request.zig");
pub const fault = @import("fault/fault.zig");
