//! The extra-MRAM option window as memory the firmware can read.
//!
//! HUM Ch 59.7.4.5 Table 59.15 p 3592 puts every cell a Program command may
//! target between 0x02E0_7600 and 0x02E1_79F0 (otp.zig). On silicon
//! that range is memory-mapped and an ordinary load reads it. Here nothing
//! mapped it: a landed program was written through to guest memory only if
//! something had already mapped the page, and nothing had, so the write
//! through failed and counted as faulted, and a plain read stopped the run
//! on an unmapped access.
//!
//! ra8_ftl_demo is the example that found it. Its FTL keeps its blocks in
//! this window and reads them with memcpy, so the run stopped in memcpy at
//! 0x0200C956 on a byte read of 0x02E0_A400 before the first act began.
//!
//! The pages covering the window are mapped when the controller is
//! attached and filled with the erased value, so a cell nobody has
//! programmed reads the same here as mram_otp.Cells.byte says it does.
//! Images link option-setting segments into this window (0x02E0_7600 and
//! 0x02E1_7700 in most of the corpus), so the order matters both ways: a
//! page an image already mapped is left alone, and the image loader skips
//! a page attach already mapped and writes its bytes over the fill.
const Guest = @import("../../core/cpu/memory/guest.zig");
const cells = @import("otp.zig");

pub const page: u32 = 0x1000;

/// The page-aligned span that covers the whole Program window.
pub const span = struct {
    pub const base: u32 = cells.window.lo & ~(page - 1);
    pub const end: u32 = (cells.window.hi + page) & ~(page - 1);
    pub const size: u32 = end - base;
};

/// Whether a page range lies wholly inside the window's span. The image
/// loader asks this so it neither re-maps a window page attach already
/// mapped nor skips one it did not.
pub fn covers(base: u32, size: u32) bool {
    if (base < span.base) return false;
    return @as(u64, base) + size <= span.end;
}

/// The image loader's half: a range inside the window is mapped if attach
/// has not mapped it yet, and either way the loader does not map it again.
/// Returns false for a range outside the window, which the loader maps
/// itself as before.
pub fn claim(machine: Guest.Guest, base: u32, size: u32) bool {
    if (!covers(base, size)) return false;
    machine.map(base, size) catch {};
    return true;
}

/// Map each page of the window that is not mapped yet and fill it with the
/// erased value. A page something already mapped (an image segment that
/// loaded first) keeps its bytes. Returns how many pages were mapped here.
pub fn map(machine: Guest.Guest) Guest.Error!u32 {
    const erased = @as([page]u8, @splat(cells.window.erased));
    var mapped: u32 = 0;
    var at: u32 = span.base;
    while (at < span.end) : (at += page) {
        machine.map(at, page) catch continue;
        try machine.write(at, &erased);
        mapped += 1;
    }
    return mapped;
}
