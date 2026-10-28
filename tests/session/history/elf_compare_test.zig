//! Covers src/session/history/elf_compare.zig: the same image compares
//! identical, an image with one patched byte differs in one segment at that
//! address and in nothing else, and unrelated images differ in layout and
//! symbols.
const std = @import("std");
const ra8 = @import("ra8");

const elf_compare = ra8.session.history_elf_compare;

const gpa = std.testing.allocator;

fn load(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(1 << 22));
}

test "the same image compares identical" {
    const bytes = try load("tests/fixtures/dfu/dfu_bootloader.elf");
    defer gpa.free(bytes);
    const report = try elf_compare.compare(gpa, bytes, bytes);
    try std.testing.expect(report.identical());
    try std.testing.expect(report.sameShape());
    try std.testing.expectEqual(report.original.symbols, report.rebuilt.symbols);
    try std.testing.expect(report.original.symbols > 0);
    try std.testing.expectEqual(@as(?u32, null), report.first_changed_address);
}

test "a patched byte changes one segment at its address and nothing else" {
    const original = try load("tests/fixtures/gpio/blink.elf");
    defer gpa.free(original);
    const rebuilt = try gpa.dupe(u8, original);
    defer gpa.free(rebuilt);
    rebuilt[0x112] += 1;
    const report = try elf_compare.compare(gpa, original, rebuilt);
    try std.testing.expect(!report.identical());
    try std.testing.expect(report.sameShape());
    try std.testing.expectEqual(@as(u32, 1), report.segments_changed);
    try std.testing.expectEqual(@as(?u32, 0x200001e), report.first_changed_address);
    try std.testing.expectEqual(report.original.entry, report.rebuilt.entry);
}

test "unrelated images differ in entry, layout and symbols" {
    const original = try load("tests/fixtures/dfu/dfu_bootloader.elf");
    defer gpa.free(original);
    const rebuilt = try load("tests/fixtures/gpio/blink.elf");
    defer gpa.free(rebuilt);
    const report = try elf_compare.compare(gpa, original, rebuilt);
    try std.testing.expect(!report.sameShape());
    try std.testing.expect(report.original.entry != report.rebuilt.entry);
    try std.testing.expectEqual(@as(usize, 0), report.rebuilt.symbols);
    try std.testing.expect(report.symbols_removed > 0);
    try std.testing.expectEqual(@as(u32, 0), report.symbols_added);

    const reverse = try elf_compare.compare(gpa, rebuilt, original);
    try std.testing.expect(reverse.symbols_added > 0);
    try std.testing.expect(reverse.first_changed_symbol != null);
}
