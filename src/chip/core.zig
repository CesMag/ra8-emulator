//! The machine, as `ra8_chip.core`: the cores, their memory map, the second
//! core's bring-up and what a run reads off them. The index file for
//! src/chip/core; the CPU itself is under `cpu`.
pub const cpu = @import("core/cpu.zig");
pub const banked = @import("core/banked.zig");
pub const bounded = @import("core/bounded.zig");
pub const cadence = @import("core/cadence.zig");
pub const event = @import("core/event.zig");
pub const windows = @import("core/windows.zig");
pub const csel = @import("core/csel.zig");
pub const deadline = @import("core/deadline.zig");
pub const fault = @import("core/fault.zig");
pub const idle = @import("core/idle.zig");
pub const loaded_image = @import("core/loaded_image.zig");
pub const lob = @import("core/lob.zig");
pub const long_shift = @import("core/long_shift.zig");
pub const memmap = @import("core/memmap.zig");
pub const module_place = @import("core/module_place.zig");
pub const mpu_guard = @import("core/mpu_guard.zig");
pub const part = @import("core/part.zig");
pub const pend_clear = @import("core/pend_clear.zig");
pub const reboot = @import("core/reboot.zig");
pub const second_core = @import("core/second_core.zig");
pub const second_wiring = @import("core/second_wiring.zig");
pub const second_zig_run = @import("core/second_zig_run.zig");
pub const session = @import("core/session.zig");
pub const sleep_pace = @import("core/sleep_pace.zig");
pub const stop = @import("core/stop.zig");
pub const systick_bank = @import("core/systick_bank.zig");
pub const tick = @import("core/tick.zig");
pub const tz = @import("core/tz.zig");
pub const undefined_ops = @import("core/undefined_ops.zig");
pub const until = @import("core/until.zig");
