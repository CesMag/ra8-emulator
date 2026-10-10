//! The background region: every address the firmware left outside all of its
//! enabled MPU regions.
//!
//! An enabled MPU does not leave the rest of the address space alone. Inside
//! a region RBAR/RLAR say what is allowed; outside every one of them there is
//! no region to consult, so CTRL.PRIVDEFENA alone decides. Clear, and the
//! background is refused to privileged and unprivileged code alike. Set, and
//! privileged code gets the default memory map back while unprivileged code
//! is still refused, which is the whole point of the bit: a supervisor that
//! wants its own free run of memory without handing the same to its threads.
//!
//! WHY THE SPANS AND NOT JUST THE RULE. Enforcement traps address ranges, so
//! refusing the background needs the ranges it occupies, and those are the
//! complement of what the table covers. Regions may overlap and arrive in any
//! order, so the spans are sorted and merged before the complement is taken.
//! At most one gap opens below the lowest region, one above the highest, and
//! one between each neighbouring pair.

const mpu = @import("mpu.zig");

pub const limits = struct {
    /// The most gaps a full table can leave.
    pub const spans: usize = mpu.geometry.regions + 1;
    /// The highest address, and so the top of a gap that runs to the end.
    pub const top: u32 = 0xFFFF_FFFF;
};

/// One stretch of address space no enabled region covers, inclusive at both
/// ends the way a region's own base and limit are.
pub const Span = struct {
    base: u32,
    limit: u32,
};

/// Whether an access landing outside every enabled region is refused. A
/// disabled MPU refuses nothing at all, so the background only exists while
/// CTRL.ENABLE stands.
pub fn refuses(unit: *const mpu.Mpu, privileged: bool) bool {
    if (!unit.on()) return false;
    if (!privileged) return true;
    return !unit.privilegedDefault();
}

/// The spans no enabled region covers, lowest first, written into `out` and
/// returned as the slice of it that was filled.
pub fn gaps(unit: *const mpu.Mpu, out: *[limits.spans]Span) []Span {
    var covered: [mpu.geometry.regions]Span = undefined;
    const taken = collect(unit, &covered);
    sortByBase(taken);
    var found: usize = 0;
    // The lowest address not yet accounted for, kept a word wider than an
    // address so a region ending at the very top can step past it.
    var next: u64 = 0;
    for (taken) |span| {
        if (span.base > next) {
            out[found] = .{ .base = @intCast(next), .limit = span.base - 1 };
            found += 1;
        }
        const after: u64 = @as(u64, span.limit) + 1;
        if (after > next) next = after;
    }
    if (next <= limits.top) {
        out[found] = .{ .base = @intCast(next), .limit = limits.top };
        found += 1;
    }
    return out[0..found];
}

/// The span of every enabled region, in table order. An entry programmed with
/// no bytes covers nothing and is left out.
fn collect(unit: *const mpu.Mpu, out: *[mpu.geometry.regions]Span) []Span {
    var count: usize = 0;
    for (unit.table) |region| {
        if (region.bytes() == 0) continue;
        out[count] = .{ .base = region.base, .limit = region.limit };
        count += 1;
    }
    return out[0..count];
}

/// Insertion sort: the table is eight entries long, so the simple one is the
/// right one.
fn sortByBase(spans: []Span) void {
    var i: usize = 1;
    while (i < spans.len) : (i += 1) {
        const held = spans[i];
        var j: usize = i;
        while (j > 0 and spans[j - 1].base > held.base) : (j -= 1) {
            spans[j] = spans[j - 1];
        }
        spans[j] = held;
    }
}
