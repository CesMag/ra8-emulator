//! What a run asked for on top of the machine, as `ra8_board.run`: real-time
//! pacing, the speed factor and what ends a soak. The session's
//! `run_policy.RunPolicy` holds them (RA8EMU-1047). The index file for src/board/run.
pub const pacer = @import("run/pacer.zig");
pub const pacing = @import("run/pacing.zig");
pub const soak = @import("run/soak/soak.zig");
pub const soak_fault = @import("run/soak_fault.zig");
pub const speed = @import("run/speed.zig");
