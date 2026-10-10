//! The MPU half of a TT response on the Zig core (RA8EMU-276).
//!
//! TT, TTT, TTA and TTAT report what the MPU would let an access to the
//! target do. The rules are the ones RA8EMU-369's data check enforces
//! (src/chip/core/cpu/mpu_check.zig), read from the same table:
//!   - the highest-numbered enabled region covering the target decides; R is
//!     set when a load is allowed there, RW when a store is too;
//!   - an address no region covers falls to the background, readable and
//!     writable only by privileged code with CTRL.PRIVDEFENA;
//!   - a disabled MPU, an absent one, or the PPB is the default map: R and RW.
//! MREGION and MRVALID name the deciding region, and read as zero when the
//! TT itself runs unprivileged: the region number is privileged information
//! (Armv8-M ARM DDI0553, TT_RESP). NSR and NSRW are R and RW for an address
//! attributed Non-secure, so `merge` recomputes them from this half.
//!
//! The A bit asks for the Non-secure MPU. The model keeps one MPU bank per
//! core, so TTA and TTAT read that bank.
const mpu = @import("../../periph/mpu/mpu.zig");
const background = @import("../../periph/mpu/background.zig");
const mpu_check = @import("mpu_check.zig");
const tt = @import("../tt.zig");

const f = tt.field;
pub const mregion_mask: u32 = 0xFF;
pub const mrvalid: u32 = 1 << 16;
const default_map: u32 = f.r | f.rw;
/// Every bit this half owns, cleared from the security half before merging.
const owned: u32 = mregion_mask | mrvalid | f.r | f.rw | f.nsr | f.nsrw;

/// How the TT looks at the MPU.
pub const View = struct {
    /// The privilege the access is checked at: the core's, or unprivileged
    /// for TTT and TTAT.
    privileged: bool,
    /// Whether the TT itself runs privileged, which decides if the region
    /// number is reported.
    reports_region: bool,
};

/// MREGION, MRVALID, R and RW for `target`.
pub fn half(unit: ?*const mpu.Mpu, target: u32, view: View) u32 {
    const table = unit orelse return default_map;
    if (!table.on()) return default_map;
    if (target >= mpu_check.ppb.first and target <= mpu_check.ppb.last) return default_map;
    const index = regionIndex(table, target) orelse
        return if (background.refuses(table, view.privileged)) 0 else default_map;
    const region = table.table[index];
    var word: u32 = 0;
    if (view.reports_region) word |= mrvalid | @as(u32, @intCast(index));
    if (region.refuses(.load, view.privileged) == .allowed) {
        word |= f.r;
        if (region.refuses(.store, view.privileged) == .allowed) word |= f.rw;
    }
    return word;
}

/// The security half with this half laid over it. NSR and NSRW follow R and
/// RW for an address the security half attributes Non-secure.
pub fn merge(security: u32, mpu_half: u32) u32 {
    const non_secure = security & f.nsr != 0;
    var word = (security & ~owned) | mpu_half;
    if (non_secure) {
        if (mpu_half & f.r != 0) word |= f.nsr;
        if (mpu_half & f.rw != 0) word |= f.nsrw;
    }
    return word;
}

/// The highest-numbered enabled region covering `at`, the one that decides.
fn regionIndex(table: *const mpu.Mpu, at: u32) ?usize {
    var i: usize = table.table.len;
    while (i > 0) {
        i -= 1;
        if (table.table[i].covers(at)) return i;
    }
    return null;
}
