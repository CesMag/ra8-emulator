//! The encodings of a mixed group that leave EPSR.ECI for the next
//! instruction (RA8EMU-453): LE in the lob group and LETP in mve_lob_tp.
//! The rest of each group (DLS, WLS, DLSTP, WLSTP, LCTP) refuses a
//! nonzero ECI and takes INVSTATE, as QEMU's translate.c has it.
const op = @import("../op.zig");
const Instr = @import("../instr.zig").Instr;
const lob_group = @import("lob.zig");
const lob_tp = @import("mve/lob_tp.zig");
const fp_mem = @import("fp/mem.zig");

pub fn lob(instr: Instr) op.Eci {
    const f = lob_group.fields(instr) orelse return .refuses;
    return if (f.kind == .le) .keeps else .refuses;
}

pub fn lobTp(instr: Instr) op.Eci {
    const f = lob_tp.fields(instr) orelse return .refuses;
    return if (f.kind == .letp) .keeps else .refuses;
}

/// VLDM/VSTM and VPUSH/VPOP restart from the first register with ICI cleared.
pub fn fpMem(instr: Instr) op.Eci {
    return if (fp_mem.isMultiple(instr)) .restarts else .refuses;
}
