//! What a run asked for on top of the machine, as `ra8_board.run`: real-time
//! pacing, the speed factor and what ends a soak. `run_policy.RunPolicy`
//! holds them on the board. The index file for src/board/run.
pub const pacer = @import("pacer.zig");
pub const pacing = @import("pacing.zig");
pub const soak = @import("soak/soak.zig");
pub const soak_fault = @import("soak/fault.zig");
pub const speed = @import("speed.zig");
