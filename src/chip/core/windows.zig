//! The windows a Cortex-M core keeps to itself rather than on the shared
//! bus (RA8EMU-1012): its SAU, its MPU table and guard, its AIRCR and its
//! owed fault clears. A chip type, so CPU1's bring-up names it without
//! importing the board that primes it.
const sau = @import("../periph/sau.zig");
const mpu = @import("../periph/mpu/mpu.zig");
const mpu_guard = @import("mpu_guard.zig");
const scb = @import("../periph/scb.zig");
const fault_clear = @import("../periph/fault_clear.zig");

/// The state that lives inside one core rather than on the bus: its SAU,
/// its MPU table and the guard that enforces that table. CPU0's are the
/// board's own; CPU1 brings its own set.
pub const CoreWindows = struct {
    partitions: *sau.Sau,
    regions: *mpu.Mpu,
    guard: *mpu_guard.Guard,
    /// The Non-secure MPU table the MPU_NS alias files into, when this core
    /// has one wired (RA8EMU-445).
    regions_ns: ?*mpu.Mpu = null,
    /// The CPUID word this core answers with: a Cortex-M85 on CPU0, a
    /// Cortex-M33 on CPU1.
    identity: u32,
    /// The AIRCR model this core's writes are judged by. CPU0's is the
    /// board's own; CPU1 brings its own, so a PRIGROUP one core programs is
    /// never the split the other reports.
    control: *scb.Scb,
    /// The CFSR/HFSR clears this core's stores owe, applied at its boundary.
    clears: *fault_clear.Clears,
};
