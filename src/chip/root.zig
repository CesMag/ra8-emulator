//! ra8_chip: the emulated RA8 chip as a library of its own (ADR 0004
//! sections 2 and 3, knowledge base article RA8EMU-A-2). Both cores, their
//! memory, the System Control Space and the on-chip blocks. It imports only
//! the snapshot format: no board, no fitted part, no host and no frontend.
//!
//! Each namespace is the index file beside its directory.
pub const core = @import("core.zig");
pub const periph = @import("periph.zig");
pub const snapshot = @import("snapshot.zig");
