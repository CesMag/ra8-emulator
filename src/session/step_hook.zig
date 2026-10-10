//! The debugger's driver state and the Zig core's debug entry points.
//!
//! src/session/stop_machine.zig decides when a session stops. Driver holds
//! the machine a run is driven by and how the last run ended, and routes the
//! firmware's stores to the debug units (FPB, DWT, ITM, DCB). The Zig core
//! feeds it through watch_bus.zig and zig_drive.zig.
const stop_machine = @import("stop_machine.zig");
const breakpoint = @import("breakpoint.zig");
const fpb = @import("fpb.zig");
/// Re-exported for tests/session/cycle_count_test.zig; src/root.zig is full.
pub const cycle_count = @import("cycle_count.zig");
/// Re-exported for tests/session/zig_core_test.zig, for the same reason.
pub const zig_core = @import("zig_core.zig");
/// Re-exported for tests/session/zig_drive_test.zig, for the same reason.
pub const zig_drive = @import("zig_drive.zig");
pub const zig_boundary = @import("zig_boundary.zig");
/// Re-exported for tests/session/core_view_test.zig, for the same reason.
pub const core_view = @import("core_view.zig");
/// A debugger read split over peripheral windows (RA8EMU-948).
pub const debug_read = @import("debug_read.zig");
/// Tagged call-stack samples and their fold (RA8EMU-952).
pub const stack_samples = @import("stack_samples.zig");
/// One call stack for a sample, CFI first, else the frame records (RA8EMU-956).
pub const stack_walk = @import("stack_walk.zig");
/// Stacks sampled every Nth retired instruction (RA8EMU-953).
pub const stack_sampler = @import("stack_sampler.zig");
/// Re-exported for tests/session/zig_session_test.zig, for the same reason.
pub const zig_session = @import("zig_session.zig");
/// Re-exported for tests/session/report_test.zig, for the same reason.
pub const session_report = @import("report.zig");
/// Re-exported for tests/session/zig_script_test.zig, for the same reason.
pub const zig_script = @import("zig_script.zig");
/// Re-exported for tests/session/watch_bus_test.zig, for the same reason.
pub const watch_bus = @import("watch_bus.zig");
/// `--watch` matched through the stop machine's watch table (RA8EMU-58).
pub const watch_link = @import("watch_link.zig");
/// Re-exported for tests/session/rtos_trace_test.zig (RA8EMU-222).
pub const rtos_trace = @import("rtos_trace.zig");
pub const rtos_stream = @import("rtos_stream.zig");
pub const rtos_publish = @import("rtos_publish.zig");
/// `--trace-rtos`: the tracer and its report (RA8EMU-221).
pub const rtos_hook = @import("rtos_hook.zig");
const dwt = @import("ra8_chip").periph.dwt;
const itm = @import("ra8_chip").periph.itm;
const dcb = @import("ra8_chip").periph.dcb;

/// The machine a run is driven by, and how the last run ended.
pub const Driver = struct {
    machine: *stop_machine.Machine,
    /// Why the last run stopped, or null when it spent its budget.
    last: ?stop_machine.Stop = null,
    /// Set as reached when the machine stops, so a run loop driving the
    /// core ends at the stop instead of starting its next stretch. Null on
    /// a bare run, where stopping the engine is enough.
    latch: ?*breakpoint.Break = null,
    /// The firmware wrote the FPB since its registers were last put back
    /// into memory. The PPB is plain memory, so the word just stored is
    /// what a read would see until the register file is written over it.
    unit_dirty: bool = false,
    /// DWT_CYCCNT counted per instruction while a cycle watch is live.
    cycles: cycle_count.Count = .{},

    /// Clear the previous verdict before a run is started.
    pub fn arm(self: *Driver) void {
        self.last = null;
    }

    /// A store the firmware made, handed to the FPB when it lands there.
    pub fn stored(self: *Driver, address: u32, value: u32, width: u8) void {
        if (inside(address, itm.base, itm.limits.span)) {
            _ = self.machine.itm.write(address - itm.base, value, width);
        } else if (inside(address, fpb.base, fpb.limits.span)) {
            if (self.machine.fpb.write(address - fpb.base, value)) self.unit_dirty = true;
        } else if (address == dwt.base + dwt.offsets.cyccnt and width == 4) {
            if (self.machine.dwt.cycleWritten(value)) |index| self.machine.onUnitMatch(index);
        } else if (inside(address, dwt.base, dwt.limits.end)) {
            // A DWT_CTRL store lands after this hook, so NUMCOMP is put
            // back over it before the next instruction reads it.
            if (!self.machine.dwt.write(address - dwt.base, value) and address - dwt.base < 4) self.machine.dwt.changed = true;
        } else if (inside(address, dcb.demcr_address, 4)) {
            if (traceEnabled(address, value, width)) |on| self.machine.dwt.trcena = on;
        } else if (address == dcb.dfsr_address) {
            self.machine.dcb.clearStatus(value);
        } else if (inside(address, dcb.base, dcb.span)) {
            _ = self.machine.dcb.write(address - dcb.base, value);
            if (self.machine.dcb.takeHalt()) self.machine.requestHalt();
        }
    }

    /// A load the firmware made, which may clear a DWT MATCHED flag.
    pub fn loaded(self: *Driver, address: u32) void {
        if (inside(address, dwt.base, dwt.limits.end)) self.machine.dwt.loaded(address - dwt.base);
    }
};

/// DEMCR.TRCENA as a store of `width` bytes at `address` in DEMCR sets it,
/// or null when the store leaves that bit alone.
fn traceEnabled(address: u32, value: u32, width: u8) ?bool {
    const shift: u6 = @intCast((address - dcb.demcr_address) * 8);
    const span = (@as(u64, 1) << @intCast(@as(u32, width) * 8)) - 1;
    if ((span << shift) & dcb.demcr_bits.trcena == 0) return null;
    return (@as(u64, value) << shift) & dcb.demcr_bits.trcena != 0;
}

fn inside(address: u32, from: u32, span: u32) bool {
    return address >= from and address < from + span;
}
