//! The decode table: every instruction group the Zig core knows, in the order
//! the decoder tries them.
//!
//! This is the one registration point. A group is a file under
//! src/chip/core/cpu/ops/ holding a `pub const group: op.Group`, plus one line in
//! this list. Groups must not claim each other's encodings; the first one that
//! answers wins, so an overlap is a bug in the group, not an ordering choice.
//! FP and MVE groups go through fp_gate.gated, which runs ExecuteFPCheck().
const op = @import("../op.zig");
const gate = @import("fp/gate.zig");
const Feature = @import("../profile.zig").Feature;
const Instr = @import("../instr.zig").Instr;
const eci_use = @import("eci_use.zig");

pub const groups = [_]op.Group{
    @import("hint.zig").group,
    @import("barrier.zig").group,
    eci(.restarts, @import("push_pop.zig").group),
    @import("sp_arith.zig").group,
    @import("ldr/literal/literal.zig").group,
    @import("ldst/imm.zig").group,
    @import("ldst/reg/reg.zig").group,
    eci(.restarts, @import("ldm/stm/stm.zig").group),
    @import("shift/imm.zig").group,
    @import("add/sub/sub.zig").group,
    @import("dp/reg.zig").group,
    @import("special_data.zig").group,
    @import("cps.zig").group,
    @import("cbz.zig").group,
    @import("extend/extend.zig").group,
    @import("reverse.zig").group,
    @import("it.zig").group,
    @import("branch/branch.zig").group,
    @import("mov_wide.zig").group,
    @import("divide.zig").group,
    @import("dp/shifted.zig").group,
    @import("shift/reg.zig").group,
    @import("add/sub/wide.zig").group,
    @import("long/mul.zig").group,
    @import("mrs_msr.zig").group,
    @import("ldst/reg/wide.zig").group,
    @import("bitfield.zig").group,
    @import("mul_acc.zig").group,
    @import("saturate.zig").group,
    @import("misc_wide.zig").group,
    @import("extend/wide.zig").group,
    @import("pkh.zig").group,
    @import("parallel.zig").group,
    @import("sel.zig").group,
    @import("sat_arith.zig").group,
    @import("extend/b16.zig").group,
    @import("sat16.zig").group,
    @import("usad8.zig").group,
    @import("umaal.zig").group,
    @import("dsp/mul16.zig").group,
    @import("dsp/dual.zig").group,
    @import("dsp/mulhi.zig").group,
    @import("dsp/long_mul.zig").group,
    needs(.v8_1m, @import("csel.zig").group),
    eciBy(eci_use.lob, needs(.lob, @import("lob.zig").group)),
    needs(.mve, @import("long/shift/shift.zig").group),
    needs(.mve, @import("long/shift/reg.zig").group),
    needs(.mve, @import("long/shift/sat.zig").group),
    needs(.mve, @import("long/shift/sat64.zig").group),
    @import("udf.zig").group,
    eci(.keeps, @import("bkpt.zig").group),
    @import("svc.zig").group,
    @import("branch/table.zig").group,
    @import("blxns.zig").group,
    @import("bxns.zig").group,
    @import("sg.zig").group,
    @import("tt.zig").group,
    @import("imm/logic.zig").group,
    @import("imm/arith.zig").group,
    @import("branch/wide.zig").group,
    needs(.lob, @import("branch/future.zig").group),
    @import("ldst/wide.zig").group,
    @import("ldr/literal/wide.zig").group,
    @import("preload.zig").group,
    gate.gated(@import("fp/arith.zig").group),
    gate.gated(@import("fp/unary.zig").group),
    gate.gated(@import("fp/system.zig").group),
    gate.gated(@import("fp/convert.zig").group),
    gate.gated(@import("fp/directed.zig").group),
    gate.gated(@import("fp/move.zig").group),
    needs(.v8_1m, @import("vscclrm.zig").group),
    @import("vlldm_vlstm.zig").group,
    needs(.v8_1m, @import("vlldm_vlstm.zig").group_t2),
    eciBy(eci_use.fpMem, gate.gatedFpMemory(@import("fp/mem.zig").group)),
    beatWise(@import("mve/vpst.zig").group),
    beatWise(@import("mve/int/int.zig").group),
    beatWise(@import("mve/bitwise.zig").group),
    beatWise(@import("mve/modimm.zig").group),
    beatWise(@import("mve/widen.zig").group),
    beatWise(@import("mve/shift_imm.zig").group),
    beatWise(@import("mve/int/pair.zig").group),
    beatWise(@import("mve/int/shift.zig").group),
    beatWise(@import("mve/int/mulh.zig").group),
    needs(.mve, gate.gated(@import("mve/int/vmla.zig").group)),
    beatWise(@import("mve/int/scalar.zig").group),
    beatWise(@import("mve/vcmp/vcmp.zig").group),
    beatWise(@import("mve/vpred.zig").group),
    beatWise(@import("mve/vctp.zig").group),
    eciBy(eci_use.lobTp, needs(.mve, gate.gated(@import("mve/lob_tp.zig").group))),
    beatWise(@import("mve/vdup.zig").group),
    beatWise(@import("mve/lane/move.zig").group),
    beatWise(@import("mve/lane/pair.zig").group),
    beatWise(@import("mve/vmaxv.zig").group),
    beatWise(@import("mve/reduce.zig").group),
    beatWise(@import("mve/int/vqdmlah.zig").group),
    beatWise(@import("mve/vldr/vldr.zig").group),
    beatWise(@import("mve/vldr/wide.zig").group),
    beatWise(@import("mve/gather/gather.zig").group),
    beatWise(@import("mve/gather64.zig").group),
    beatWise(@import("mve/gather/imm.zig").group),
    beatWise(@import("mve/vld_il.zig").group),
    beatWise(@import("mve/float/float.zig").group),
    beatWise(@import("mve/float/scalar.zig").group),
    beatWise(@import("mve/vcmp/fp.zig").group),
    beatWise(@import("mve/float/fma.zig").group),
    beatWise(@import("mve/float/unary.zig").group),
    beatWise(@import("mve/float/cvt/half.zig").group),
    beatWise(@import("mve/float/cvt/int.zig").group),
    beatWise(@import("mve/float/cvt/fixed.zig").group),
    beatWise(@import("mve/float/rint.zig").group),
    beatWise(@import("mve/float/maxnm.zig").group),
    beatWise(@import("mve/float/maxnma.zig").group),
    beatWise(@import("mve/float/maxnmv.zig").group),
    beatWise(@import("mve/float/vcadd.zig").group),
    beatWise(@import("mve/float/vcmla.zig").group),
    beatWise(@import("mve/float/vcmul.zig").group),
    @import("ldrd_strd.zig").group,
    @import("exclusive.zig").group,
    @import("acq_rel.zig").group,
    needs(.v8_1m, @import("clrm.zig").group),
    eci(.restarts, @import("ldm/stm/wide.zig").group),
    needs(.v8_1m, @import("pac.zig").group),
};

fn needs(comptime feature: Feature, comptime group: op.Group) op.Group {
    var tagged = group;
    tagged.needs = feature;
    return tagged;
}

/// An MVE group whose encodings are all beat-wise (RA8EMU-453).
fn beatWise(comptime group: op.Group) op.Group {
    return eci(.beat_wise, needs(.mve, gate.gated(group)));
}

fn eci(comptime use: op.Eci, comptime group: op.Group) op.Group {
    var tagged = group;
    tagged.eci = use;
    return tagged;
}

fn eciBy(comptime of: *const fn (instr: Instr) op.Eci, comptime group: op.Group) op.Group {
    var tagged = group;
    tagged.eci_of = of;
    return tagged;
}
