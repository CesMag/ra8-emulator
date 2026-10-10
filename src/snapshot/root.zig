//! ra8_snapshot: the snapshot file format (ADR 0004 section 2, knowledge
//! base article RA8EMU-A-2). The file with its sections, plain state
//! encoded field by field, sparse contents, a card's written blocks, and a
//! list of units as one section. It imports only std. What goes into each
//! section lives with the model it saves, in the chip, the components and
//! the board (RA8EMU-1023).
pub const file = @import("file.zig");
pub const fields = @import("fields.zig");
pub const sparse = @import("sparse.zig");
pub const blocks = @import("blocks.zig");
pub const units = @import("units.zig");
