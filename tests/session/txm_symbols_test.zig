//! Tests for src/session/txm_symbols.zig: a module ELF's code symbols moved
//! to where the manager placed the code, and a guest PC named back. The
//! ThreadX fixture stands in for a module: its code is linked at
//! 0x0200_0000, and the tests pretend the manager put it at `placed`.
const std = @import("std");
const ra8 = @import("ra8");
const elf = ra8.board.image.elf;
const txm_symbols = ra8.session.txm_symbols;

const fixture = "tests/fixtures/threadx/threadx_stkof.elf";
const placed: u32 = 0x2200_10a0;
const linked: u32 = 0x0200_0000;
/// tx_application_define in the fixture: 0x0200_0200, 0x64 bytes.
const define_linked: u32 = 0x0200_0200;

fn read() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture, std.testing.allocator, .limited(1 << 24));
}

test "the module's code segment is the executable load segment" {
    const bytes = try read();
    defer std.testing.allocator.free(bytes);
    const module = txm_symbols.Module.at(try elf.Image.init(bytes), placed) orelse return error.NoCode;
    try std.testing.expectEqual(linked, module.link_code);
    try std.testing.expectEqual(@as(u32, 0xd190), module.link_size);
}

test "a code symbol resolves where the manager placed the code" {
    const bytes = try read();
    defer std.testing.allocator.free(bytes);
    const module = txm_symbols.Module.at(try elf.Image.init(bytes), placed) orelse return error.NoCode;
    const at = module.addressOf("tx_application_define") orelse return error.Missing;
    try std.testing.expectEqual(placed + (define_linked - linked), at & ~@as(u32, 1));
    try std.testing.expectEqual(@as(?u32, null), module.addressOf("no_such_symbol"));
}

test "a guest PC inside the moved code names the ELF's function" {
    const bytes = try read();
    defer std.testing.allocator.free(bytes);
    const module = txm_symbols.Module.at(try elf.Image.init(bytes), placed) orelse return error.NoCode;
    const found = module.inside(placed + (define_linked - linked) + 6) orelse return error.Missing;
    try std.testing.expectEqualStrings("tx_application_define", found.name);
    try std.testing.expectEqual(@as(u32, 6), found.offset);
}

test "addresses outside the moved code are not the module's" {
    const bytes = try read();
    defer std.testing.allocator.free(bytes);
    const module = txm_symbols.Module.at(try elf.Image.init(bytes), placed) orelse return error.NoCode;
    try std.testing.expectEqual(@as(?ra8.session.symbols.Inside, null), module.inside(placed - 2));
    try std.testing.expectEqual(@as(?ra8.session.symbols.Inside, null), module.inside(placed + 0xd190));
    try std.testing.expectEqual(@as(?ra8.session.symbols.Inside, null), module.inside(define_linked));
}
