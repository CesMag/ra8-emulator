//! The address a place names, for either CPU (RA8EMU-114): a FILE:LINE
//! from the line table, or a symbol or literal, one optional dereference,
//! then its offset. The session resolves
//! through this, so `break`, `x` and `print` take the same places.
const elf = @import("ra8_board").image.elf;
const core_view = @import("core_view.zig");
const place = @import("place.zig");
const session_source = @import("source.zig");
const symbols = @import("symbols.zig");

pub const Error = error{ NoSymbols, Unresolved };

pub fn resolve(view: core_view.View, image: ?elf.Image, text: []const u8) !u32 {
    if (session_source.fileLine(text)) |at| {
        return session_source.breakAt(image, at) orelse Error.Unresolved;
    }
    const want = try place.parse(text);
    var base = want.address;
    if (want.name) |name| {
        const found = image orelse return Error.NoSymbols;
        base = symbols.addressOf(found, name) orelse return Error.Unresolved;
    }
    if (want.deref) base = try view.readWord(base);
    return want.apply(base);
}
