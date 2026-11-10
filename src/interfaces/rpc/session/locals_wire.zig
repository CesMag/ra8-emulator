//! The locals wire messages (RA8EMU-805). Split out of the protocol
//! vocabulary file so the file stays small; rpc.zig re-exports these under
//! the same names.
const proto = @import("rpc.zig");

/// A function's locals at a stopped core (RA8EMU-805): `count` rows in
/// `rows`, each a LocalRow as locals_wire.zig packs it.
pub const Locals = struct {
    core: proto.Core,
    count: u8,
    rows: []const u8,
    pub const max_len = .{ .rows = locals_bytes };
};

/// One local of a function's locals. `where_kind` says where the local's
/// bytes live (where_kinds), with `where_a` and `where_b` carrying what
/// that kind needs; a type with no answer keeps `size` 0.
pub const LocalRow = struct {
    name: []const u8,
    type_name: []const u8,
    size: u32,
    where_kind: u8,
    where_a: u64,
    where_b: u64,
    pub const max_len = .{ .name = local_name_cap, .type_name = local_type_cap };
};

/// Where kinds a LocalRow's bytes live at.
pub const where_kinds = struct {
    pub const none: u8 = 0;
    /// At an offset (signed, in `where_a`) from the frame base.
    pub const frame: u8 = 1;
    /// In the register in `where_a` holding an address plus the signed
    /// offset in `where_b`.
    pub const register: u8 = 2;
    /// In the register in `where_a` outright.
    pub const in_register: u8 = 3;
    /// At the fixed address in `where_a`.
    pub const address: u8 = 4;
};

/// The most locals one answer carries, and the characters a local's name
/// and its type's name keep.
pub const locals_rows = 32;
pub const local_name_cap = 40;
pub const local_type_cap = 40;
/// One row's widest encoding plus the length byte before it.
pub const local_row_bytes = 1 + local_name_cap + 4 + local_type_cap + 4 + 4 + 1 + 8 + 8;
pub const locals_bytes = locals_rows * local_row_bytes;
