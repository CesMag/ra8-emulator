//! The Zig core's disassembler (RA8EMU-17), built on the decode table.
pub const text = @import("text.zig");
pub const table = @import("table.zig");
pub const disasm = @import("disasm.zig");
pub const mve_vpst = @import("mve/vpst.zig");
pub const mve_vcmp = @import("mve/vcmp/vcmp.zig");
pub const mve_vcmp_fp = @import("mve/vcmp/fp.zig");
