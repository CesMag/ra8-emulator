//! RA8EMU-207 done condition: `--faults FILE` on a soak run. The flag is
//! read, a malformed file is refused before the run with its line, and a
//! good one applies each event at its exact virtual time on a `--run-for`
//! style run of tests/fixtures/plug/gauge_poll.elf.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const store_board = @import("../interfaces/cli/store_board.zig");

const parse = cli_app.cli.parse;
const fault_file = ra8.session.fault_file;
const boot = ra8.chip.core.cpu.boot;
const elf = ra8.board.image.elf;
const loader = ra8.chip.core.cpu.memory.load;
const zig_run = cli_app.zig_run;

const image_bytes = @embedFile("../fixtures/plug/gauge_poll.elf");
const counts_at: u32 = 0x2200_0100;

const good =
    \\# a short soak: the gauge goes for a while and comes back faulty
    \\0s        plug   i2c:riic@0x36 max17048
    \\150001ns  unplug i2c:riic@0x36
    \\300us     plug   i2c:riic@0x36 max17048
    \\333333ns  fault  i2c:riic@0x36 nack:2
    \\420us     clear  i2c:riic@0x36
;

fn writeFile(dir: std.Io.Dir, name: []const u8, text: []const u8, buffer: []u8) ![]const u8 {
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = text });
    return buffer[0..try dir.realPathFile(std.testing.io, name, buffer)];
}

test "--faults takes a file" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--faults", "soak.faults" });
    try std.testing.expectEqualStrings("soak.faults", options.faults.?);
    const plain = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expect(plain.faults == null);
}

test "a malformed or missing schedule is refused before the run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const bad = try writeFile(tmp.dir, "bad.faults", "2m unplug i2c:riic@0x36\n1m plug i2c:riic@0x36 max17048\n", &buffer);
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var run: fault_file.Run = undefined;
    try std.testing.expectError(error.TimeBackwards, run.open(&board, std.testing.io, bad));
    try std.testing.expectError(error.FileNotFound, run.open(&board, std.testing.io, "/nonexistent/ra8.faults"));
}

test "a soak run applies every scheduled event at its exact virtual time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try writeFile(tmp.dir, "soak.faults", good, &buffer);

    const image = try elf.Image.init(image_bytes);
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try store_board.attach(&board, core);
    const loaded = try ra8.board.image.load.read(image);
    _ = try loader.image(core, loaded.image());
    board.run.soak.armed = true; // as `--run-for` arms it

    var run: fault_file.Run = undefined;
    try run.open(&board, std.testing.io, path);
    defer run.deinit();
    var applied: [5]u64 = .{ 0, 0, 0, 0, 0 };
    run.applier.applied_ns = &applied;

    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 5_000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase };
    var ran: u64 = 0;
    var output: [256]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    const vector_base = image.vectorBase() orelse return error.MissingVectorTable;
    _ = try boot.start(&stream, .zig, core, &board.bus, vector_base, 500_000, &ran, .{
        .boundary = try fault_file.boundary(&run.applier, clock.boundary()),
        .partitions = &board.partitions,
        .idau = &board.idau,
        .regions = &board.regions,
        .regions_ns = &board.regions_ns,
        .clears = &board.clears,
    });
    try std.testing.expect(run.applier.finished());
    for (run.plan.events, applied) |event, at| try std.testing.expectEqual(event.at_ns, at);
    try std.testing.expect(!board.run.soak.ended());
    try std.testing.expect(try core.readWord(counts_at + 4) > 0);
    try std.testing.expect(try core.readWord(counts_at + 8) > 0);
}
