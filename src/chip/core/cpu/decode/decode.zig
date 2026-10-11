//! The decoder: asks each group in src/chip/core/cpu/ops/table.zig in turn and
//! returns the first one that recognises the encoding.
const op = @import("../op.zig");
const table = @import("../ops/table.zig");
const Instr = @import("../instr.zig").Instr;

pub const Hit = struct {
    /// The class the instruction was decoded under.
    group: []const u8,
    exec: op.Exec,
    /// Whether a lockstep oracle checks it; see `op.Group`.
    oracle: bool,
    /// How it treats a nonzero EPSR.ECI (RA8EMU-453).
    eci: op.Eci = .refuses,
};

/// The core feature profiles (RA8EMU-233).
pub const profile = @import("../profile.zig");

/// Decode as the Cortex-M85 does: every group in the table.
pub fn decode(instr: Instr) ?Hit {
    return decodeFor(profile.Profile.m85, instr);
}

/// Decode as a core with `core` does: a group whose feature it lacks is
/// not asked.
pub fn decodeFor(core: profile.Profile, instr: Instr) ?Hit {
    for (table.groups) |group| {
        if (!core.has(group.needs)) continue;
        if (group.decode(instr)) |exec| return .{ .group = group.name, .exec = exec, .oracle = group.oracle, .eci = group.eciOf(instr) };
    }
    return null;
}

/// True when the M85 decodes `instr` but `core` does not: an encoding
/// UNDEFINED on this core, which takes UsageFault UNDEFINSTR.
pub fn refused(core: profile.Profile, instr: Instr) bool {
    return decodeFor(core, instr) == null and decode(instr) != null;
}

/// The decoded-instruction cache in front of `decode` (RA8EMU-317).
pub const cache = @import("cache.zig");

/// Straight-line runs of decoded instructions (RA8EMU-403).
pub const block = @import("../block/block.zig");
pub const block_cache = @import("../block/cache.zig");
pub const code_lines = @import("../code_lines.zig");

/// The disassembler built on this table (RA8EMU-17).
pub const text = @import("../text/all.zig");
