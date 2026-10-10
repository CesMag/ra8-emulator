//! The MPU's enforcement state the board keeps: the table enforcement reads
//! and the latch of what it caught.
//!
//! src/chip/periph/mpu/mpu.zig captures what the firmware programmed and
//! src/chip/periph/mpu/fault.zig holds what enforcement caught. The Zig core
//! enforces through src/chip/core/cpu/mpu_check.zig, which turns a refused access
//! away before it reaches memory.
//!
//! The board, CPU1 and the reports still hold a Guard
//! for the table pointer and the latch, which is all that is left.
const mpu = @import("../periph/mpu/mpu.zig");
const mpu_fault = @import("../periph/mpu/fault.zig");

/// The enforcement side of the MPU: the table it enforces and what it caught.
pub const Guard = struct {
    /// The table, set when the window hook is attached. A guard nobody
    /// attached enforces nothing rather than guessing at a table.
    unit: ?*mpu.Mpu = null,
    latch: mpu_fault.Latch = .{},

    pub fn init() Guard {
        return .{};
    }
};
