//! What a run asked for on top of the machine, as `ra8_session.run`:
//! real-time pacing, the speed factor and what ends a soak. The session's
//! `run.policy.RunPolicy` holds them (RA8EMU-1047). The index file for src/session/run.
pub const loop = @import("loop.zig");
pub const policy = @import("policy.zig");
pub const pacer = @import("pacer.zig");
pub const pacing = @import("pacing.zig");
pub const soak = @import("soak/soak.zig");
pub const speed = @import("speed.zig");
