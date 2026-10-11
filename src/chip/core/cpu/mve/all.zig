//! The M85 MVE (Helium) semantics, one namespace so root.zig carries a
//! single line for them: pure functions over Q registers and VPR, with
//! their vectors (RA8EMU-25, RA8EMU-23).
pub const qreg = @import("qreg.zig");
pub const predicate = @import("predicate.zig");
pub const vpt = @import("vpt.zig");
pub const tail = @import("tail.zig");
pub const int = @import("int/int.zig");
pub const reduce = @import("reduce/reduce.zig");
pub const compare = @import("compare/compare.zig");
pub const bit = @import("bit/bit.zig");
pub const bitwise = @import("bitwise/bitwise.zig");
pub const modimm = @import("modimm/modimm.zig");
pub const contiguous = @import("contiguous/contiguous.zig");
pub const memory_alignment_vectors = @import("memory_alignment_vectors.zig");
pub const gather = @import("gather/gather.zig");
pub const gather64_vectors = @import("gather64_vectors.zig");
pub const interleave = @import("interleave/interleave.zig");
pub const eci = @import("eci.zig");
pub const beats = @import("beats.zig");
pub const float = @import("float/float.zig");
