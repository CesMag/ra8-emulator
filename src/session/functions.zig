//! Which FUNCTION a run spent itself in.
//!
//! src/session/hotspots.zig samples raw program counters, and on a run that
//! is doing anything at all that is too fine to answer "who burned this
//! run". Measured on `threadx_blink` at two seconds: the pc table reports
//! 47% in one spin and then "17426 other address(es) did not stay in the
//! table", so nearly half the run is accounted for by a remainder with no
//! name on it. Sixteen slots cannot hold a working thread's addresses.
//!
//! A function is the granularity the question is actually asked at, and
//! there are a few hundred of them against tens of thousands of
//! addresses, so the same sixteen slots stop churning and the remainder
//! shrinks to something a reader can trust.
//!
//! The counting policy is NOT duplicated here. A site is still an address
//! and a count, still evicts the weakest slot when full, still reports a
//! share of the whole run: this keys hotspots.Table by the function's
//! start address instead of by the pc, and that is the entire difference.
//!
//! The symbol scan runs once per chunk boundary rather than once per
//! instruction, which is the same place the pc sample already happens.
//! Deliberately uncached: the image carries a few hundred functions and a
//! boundary already costs tens of thousands of instructions, so a cache
//! would buy nothing worth the state it would have to keep correct.
const elf = @import("ra8_board").image.elf;
const hotspots = @import("hotspots.zig");
const symbols = @import("symbols.zig");
pub const profile = @import("profile.zig");

/// The sampled functions of one run.
pub const Table = struct {
    image: elf.Image,
    /// The counting policy, keyed by function start address.
    sites: hotspots.Table = .{},
    /// Boundaries that landed outside every sized function symbol. Kept
    /// so a run that spends itself in code the image cannot name says so
    /// rather than quietly reporting a smaller total.
    unnamed: u64 = 0,

    /// Record one boundary's program counter against the function holding
    /// it. A pc with no function keeps its own address, so the line still
    /// appears and the totals still add up.
    pub fn sample(self: *Table, pc: u32) void {
        if (symbols.inside(self.image, pc)) |found| {
            self.sites.sample(pc -% found.offset);
            return;
        }
        self.unnamed += 1;
        self.sites.sample(pc);
    }
};
