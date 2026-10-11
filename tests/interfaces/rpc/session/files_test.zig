//! RA8EMU-768 through the serve handlers on a real harness: snapshot
//! writes the run file and restore puts the core, guest memory and virtual
//! time back where it was, a page written since included.
const std = @import("std");
const ra8 = @import("ra8");

const server = ra8.rpc.session_server;
const files = ra8.rpc.session_files;
const memmap = ra8.chip.core.memmap;

const image = "tests/fixtures/uart/uart_irq_echo.elf";
/// A word in SRAM the fixture never touches, so it reads zero when saved.
const spare = memmap.sram_base + 0x0004_0000;

fn runFor(harness: *ra8.session.harness.Harness, instructions: u64) !void {
    const session = harness.session();
    session.live.budget = instructions;
    _ = try session.run(.cpu0, .cont);
}

fn word(harness: *ra8.session.harness.Harness) !u32 {
    var bytes: [4]u8 = undefined;
    try harness.session().read(.cpu0, spare, &bytes);
    return std.mem.readInt(u32, &bytes, .little);
}

test "restore puts pc, guest memory and virtual time back where snapshot left them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "run.ra8snap" });
    defer std.testing.allocator.free(path);

    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch, .state = opened.stateFiles() };

    try runFor(&opened, 20_000);
    const pc = try opened.session().register(.cpu0, .pc);
    const at = try opened.session().now();
    const kept = try word(&opened);
    try std.testing.expect(files.snapshot(&context, .{ .path = path }) == .ok);

    try runFor(&opened, 20_000);
    try opened.session().write(.cpu0, spare, &.{ 0xef, 0xbe, 0xad, 0xde });
    try std.testing.expect(try opened.session().now() > at);

    try std.testing.expect(files.restore(&context, .{ .path = path }) == .ok);
    try std.testing.expectEqual(pc, try opened.session().register(.cpu0, .pc));
    try std.testing.expectEqual(at, try opened.session().now());
    try std.testing.expectEqual(kept, try word(&opened));

    // The restored run carries on as the saved one did.
    try runFor(&opened, 20_000);
    try std.testing.expect(try opened.session().now() > at);
}

test "snapshot and restore are refused with no state hook or no such file" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var bare: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    try std.testing.expect(files.snapshot(&bare, .{ .path = "unused" }) == .err);
    var served: server.Context = .{ .session = opened.session(), .scratch = &scratch, .state = opened.stateFiles() };
    try std.testing.expect(files.restore(&served, .{ .path = "tests/fixtures/uart/no-such.ra8snap" }) == .err);
}
