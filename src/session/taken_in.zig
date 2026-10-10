//! Every exception taken inside one named function, kept in full.
//!
//! src/session/tally.zig counts (interrupted program counter, exception
//! number) pairs and displaces its weakest row when the table fills. That
//! is the right shape for finding where a run spends its interrupts, and
//! the wrong one for finding an interrupt that happened ONCE, because a
//! one-off is precisely the row a weakest-first policy throws away.
//!
//! The ThreadX freeze on `threadx_blink` is a one-off. Of 452 sleeps,
//! exactly one incremented `_tx_thread_preempt_disable` in
//! `_tx_thread_sleep` and never reached the decrement in
//! `_tx_thread_system_suspend`, and the thread stopped in between holds
//! the flag up, which stops the timer handler ever issuing a PendSV. The
//! tally could not show that entry and never could. This can: name the
//! function, keep every exception taken inside it, evict nothing.
//!
//! Bounded by keeping the FIRST entries rather than the most frequent. A
//! window that fires a handful of times a run fits whole; one that fires
//! constantly says how many it could not keep, and the answer to that is
//! a narrower window, not a longer list.

const std = @import("std");
const elf = @import("../board/image/elf.zig");
const symbols = @import("symbols.zig");

/// What the window costs.
pub const limits = struct {
    /// Entries kept, oldest first. A window drawn around a few dozen
    /// instructions is not expected to catch many.
    pub const kept: usize = 32;
};

/// One exception taken inside the window.
pub const Entry = struct {
    /// Where the interrupted instruction sits.
    pc: u32,
    /// Which vector was entered.
    number: u32,
    /// Which entry into this window it was, counting from one, so a run
    /// that keeps only the first few can still say where they fell.
    at: u64,
};

/// A named function, and the exceptions taken while it was running.
pub const Window = struct {
    /// The first instruction of the function.
    base: u32 = 0,
    /// How long it is, in bytes.
    size: u32 = 0,
    /// Every exception taken inside it, whether or not it was kept.
    seen: u64 = 0,
    entries: [limits.kept]Entry = undefined,

    /// Is this program counter inside the window?
    pub fn holds(self: *const Window, pc: u32) bool {
        return pc >= self.base and pc < self.base + self.size;
    }

    /// Record one exception taken at `pc`. Callers check `holds` first;
    /// this checks again so a wired window cannot be fed the whole run.
    pub fn record(self: *Window, pc: u32, number: u32) void {
        if (!self.holds(pc)) return;
        self.seen += 1;
        if (self.seen <= limits.kept) {
            self.entries[self.seen - 1] = .{ .pc = pc, .number = number, .at = self.seen };
        }
    }

    /// The entries kept, oldest first.
    pub fn kept(self: *const Window) []const Entry {
        return self.entries[0..@min(self.seen, limits.kept)];
    }

    /// Entries counted but not kept, so a full window says so.
    pub fn missed(self: *const Window) u64 {
        return self.seen -| limits.kept;
    }
};

/// Where `--taken-in` named, resolved before the run starts.
///
/// A spelling the image cannot answer is reported and watched as nothing:
/// a run that silently watches the wrong function is worse than one that
/// watches none. Only a sized function is accepted, because a window
/// needs a length and guessing one from the next symbol along would put a
/// wrong length on a real function.
pub fn resolve(image: elf.Image, spec: ?[]const u8) ?Window {
    const asked = spec orelse return null;
    const extent = symbols.extentOf(image, asked) orelse {
        std.debug.print("--taken-in {s}: no sized function by that name\n", .{asked});
        return null;
    };
    return .{ .base = extent.address, .size = extent.size };
}
