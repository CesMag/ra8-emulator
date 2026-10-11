//! mve: the files of src/chip/core/cpu/ops/mve/.

pub const beats = @import("beats.zig");
pub const bitwise = @import("bitwise.zig");
pub const float = @import("float/float.zig");
pub const gather = @import("gather/gather.zig");
pub const gather64 = @import("gather64.zig");
pub const int = @import("int/int.zig");
pub const lane = @import("lane/lane.zig");
pub const lob_tp = @import("lob_tp.zig");
pub const modimm = @import("modimm.zig");
pub const reduce = @import("reduce.zig");
pub const shift_imm = @import("shift_imm.zig");
pub const vcmp = @import("vcmp/vcmp.zig");
pub const vctp = @import("vctp.zig");
pub const vdup = @import("vdup.zig");
pub const vld_il = @import("vld_il.zig");
pub const vldr = @import("vldr/vldr.zig");
pub const vmaxv = @import("vmaxv.zig");
pub const vpred = @import("vpred.zig");
pub const vpst = @import("vpst.zig");
pub const widen = @import("widen.zig");
