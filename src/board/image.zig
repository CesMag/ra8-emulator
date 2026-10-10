//! The image loader, as `ra8_board.image`: ELF and .ra8app images read into
//! the chip's loaded-image value, and the pages an image asks to have
//! mapped. The index file for src/board/image.
pub const elf = @import("image/elf.zig");
pub const load = @import("image/load.zig");
pub const pages = @import("image/pages.zig");
pub const ra8app = @import("image/ra8app.zig");
