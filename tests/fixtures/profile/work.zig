//! The unit of work both halves of the RA8EMU-955 fixture count in: a
//! loop the optimizer keeps, so a unit costs the same wherever it runs.
pub const unit: u32 = 200;

/// Spin `count` times; inlined so the time lands in the caller's frame.
pub inline fn spin(count: u32) void {
    var left = count;
    while (left != 0) : (left -= 1) asm volatile ("nop");
}
