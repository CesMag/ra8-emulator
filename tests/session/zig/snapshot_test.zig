//! Covers src/session/zig/snapshot.zig: a run saved part way and
//! restored ends where the uninterrupted run ends (RA8EMU-696), wherever the
//! split falls: a save holds the chunk it stopped in open instead of closing
//! it short, and the load picks it up there (RA8EMU-700).
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const memmap = ra8.chip.core.memmap;
const elf = ra8.board.image.elf;
const zig_run = cli_app.zig.run;
const main_path = zig_run.main_path;
const Cpu0 = ra8.board.cpu0_store.Cpu0;
const Parts = cli_app.parts.Parts;
const Options = cli_app.cli.Options;

const stkof = @embedFile("../../fixtures/threadx/threadx_stkof.elf");
const page: usize = 0x1000;
const vectors: u32 = memmap.mram_base;
const stack: u32 = memmap.sram_base + 0x800;

/// SP, reset, then a loop that counts r0 up and stores it to SRAM, so the
/// core, memory and the run's time all move.
fn image() [page * 2]u8 {
    var file: [page * 2]u8 align(@alignOf(elf.Header)) = @splat(0);
    const head: *elf.Header = @ptrCast(@alignCast(&file[0]));
    head.* = .{ .magic = .{ 0x7f, 'E', 'L', 'F' }, .class = 1, .data = 1, .version = 1, .osabi = 0, .abiversion = 0, .pad = @splat(0), .e_type = 2, .e_machine = elf.em_arm, .e_version = 1, .e_entry = vectors + 9, .e_phoff = @sizeOf(elf.Header), .e_shoff = 0, .e_flags = 0, .e_ehsize = @sizeOf(elf.Header), .e_phentsize = @sizeOf(elf.ProgramHeader), .e_phnum = 1, .e_shentsize = 0, .e_shnum = 0, .e_shstrndx = 0 };
    const header: *elf.ProgramHeader = @ptrCast(@alignCast(&file[@sizeOf(elf.Header)]));
    header.* = .{ .p_type = elf.pt_load, .p_offset = page, .p_vaddr = vectors, .p_paddr = vectors, .p_filesz = 0x10, .p_memsz = 0x10, .p_flags = 5, .p_align = 4 };
    std.mem.writeInt(u32, file[page..][0..4], stack, .little);
    std.mem.writeInt(u32, file[page + 4 ..][0..4], vectors + 9, .little);
    // adds r0, #1 ; str r0, [sp] ; b .-4
    for ([_]u16{ 0x3001, 0x9000, 0xE7FC }, 0..) |half, at| std.mem.writeInt(u16, file[page + 8 + at * 2 ..][0..2], half, .little);
    return file;
}

/// Runs the loop image; returns the virtual time the run ended at.
fn run(dir: std.Io.Dir, instructions: usize, state: zig_run.state_args.Options) !u64 {
    var file = image();
    return runImage(dir, &file, instructions, state);
}

fn runImage(dir: std.Io.Dir, file: []const u8, instructions: usize, state: zig_run.state_args.Options) !u64 {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    const options: Options = .{ .path = "cpu0.elf", .cpu = .zig, .instructions = instructions, .state = state };
    try main_path.fit(&board, std.testing.allocator, std.testing.io, options);
    var cpu0: Cpu0 = .{};
    defer cpu0.close();
    var parts = Parts{};
    const loaded = try elf.Image.init(file);
    _ = try main_path.prepare(&cpu0, &board, std.testing.io, loaded, &parts, options);
    var log = try dir.createFile(std.testing.io, "run.log", .{});
    defer log.close(std.testing.io);
    var buffer: [4096]u8 = undefined;
    var writer = log.writer(std.testing.io, &buffer);
    defer writer.interface.flush() catch {};
    _ = try zig_run.run(&writer.interface, std.testing.io, cpu0.own(), &board, &parts.timebase, loaded, options, vectors, null, parts.tap.waiting(), .{});
    return board.time.base.now();
}

fn read(dir: std.Io.Dir, name: []const u8) ![]u8 {
    return dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(1 << 28));
}

test "two chunks straight end where one chunk, saved, then one restored end" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const paths = [_][]const u8{ "straight", "half", "resumed" };
    var full: [3][]u8 = undefined;
    for (paths, 0..) |name, at| full[at] = try std.fs.path.join(std.testing.allocator, &.{ root, name });
    defer for (full) |one| std.testing.allocator.free(one);
    const chunk: usize = ra8.chip.periph.clocks.chunk_instructions;
    _ = try run(tmp.dir, chunk * 2, .{ .save = full[0] });
    _ = try run(tmp.dir, chunk, .{ .save = full[1] });
    _ = try run(tmp.dir, chunk, .{ .load = full[1], .save = full[2] });
    const straight = try read(tmp.dir, "straight");
    defer std.testing.allocator.free(straight);
    const resumed = try read(tmp.dir, "resumed");
    defer std.testing.allocator.free(resumed);
    const half = try read(tmp.dir, "half");
    defer std.testing.allocator.free(half);
    try std.testing.expect(!std.mem.eql(u8, straight, half));
    try std.testing.expectEqualSlices(u8, straight, resumed);
}

test "a split off a chunk boundary ends where the straight run ends too" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const paths = [_][]const u8{ "straight", "half", "resumed" };
    var full: [3][]u8 = undefined;
    for (paths, 0..) |name, at| full[at] = try std.fs.path.join(std.testing.allocator, &.{ root, name });
    defer for (full) |one| std.testing.allocator.free(one);
    const chunk: usize = ra8.chip.periph.clocks.chunk_instructions;
    _ = try run(tmp.dir, chunk * 2, .{ .save = full[0] });
    _ = try run(tmp.dir, chunk + 1000, .{ .save = full[1] });
    _ = try run(tmp.dir, chunk - 1000, .{ .load = full[1], .save = full[2] });
    const straight = try read(tmp.dir, "straight");
    defer std.testing.allocator.free(straight);
    const resumed = try read(tmp.dir, "resumed");
    defer std.testing.allocator.free(resumed);
    try std.testing.expectEqualSlices(u8, straight, resumed);
}

// RA8EMU-699: a real ThreadX image (tests/fixtures/threadx, RA8FW-503's
// threadx_stkof) split part way ends with the same console lines and the
// same state bytes as the run left alone: mid-run, and during boot before
// the firmware arms SysTick, where a loaded run hands its carried
// instructions back to the budget (RA8EMU-701).
test "threadx_stkof split mid-run or during boot ends where the straight run ends" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const paths = [_][]const u8{ "straight", "half", "resumed" };
    var full: [3][]u8 = undefined;
    for (paths, 0..) |name, at| full[at] = try std.fs.path.join(std.testing.allocator, &.{ root, name });
    defer for (full) |one| std.testing.allocator.free(one);
    const total: usize = 100_000;
    _ = try runImage(tmp.dir, stkof, total, .{ .save = full[0] });
    const straight = try read(tmp.dir, "straight");
    defer std.testing.allocator.free(straight);
    try std.testing.expect(std.mem.indexOf(u8, straight, "stkof: PASS") != null);
    for ([_]usize{ 20_000, 50_001 }) |split| {
        _ = try runImage(tmp.dir, stkof, split, .{ .save = full[1] });
        _ = try runImage(tmp.dir, stkof, total - split, .{ .load = full[1], .save = full[2] });
        const resumed = try read(tmp.dir, "resumed");
        defer std.testing.allocator.free(resumed);
        try std.testing.expectEqualSlices(u8, straight, resumed);
    }
}

// RA8EMU-769: `--snapshot-at` writes at the boundary its time falls on and
// the run goes on; restoring that file and running the rest ends where the
// straight run ends, and the file is the one a run stopped there saves.
test "snapshot-at mid-run restores to the straight run's end" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const paths = [_][]const u8{ "straight", "half", "mid", "resumed" };
    var full: [4][]u8 = undefined;
    for (paths, 0..) |name, at| full[at] = try std.fs.path.join(std.testing.allocator, &.{ root, name });
    defer for (full) |one| std.testing.allocator.free(one);
    const chunk: usize = ra8.chip.periph.clocks.chunk_instructions;
    const half_ns = try run(tmp.dir, chunk * 2, .{ .save = full[1] });
    try std.testing.expect(half_ns > 0);
    _ = try run(tmp.dir, chunk * 4, .{ .save = full[0], .at = .{ .ns = half_ns, .path = full[2] } });
    _ = try run(tmp.dir, chunk * 2, .{ .load = full[2], .save = full[3] });
    var bytes: [4][]u8 = undefined;
    for (paths, 0..) |name, at| bytes[at] = try read(tmp.dir, name);
    defer for (bytes) |one| std.testing.allocator.free(one);
    try std.testing.expectEqualSlices(u8, bytes[1], bytes[2]);
    try std.testing.expect(!std.mem.eql(u8, bytes[0], bytes[2]));
    try std.testing.expectEqualSlices(u8, bytes[0], bytes[3]);
}

test "no flag, no hook" {
    var store = try ra8.chip.core.cpu.memory.store.Store.init(null);
    defer store.deinit();
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var timebase: ra8.chip.periph.clocks.Clocks = .{};
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = .{ .store = &store }, .board = &board, .timebase = &timebase };
    try std.testing.expect(zig_run.zig_snapshot.hook(&clock) == null);
    clock.state = .{ .save = "x" };
    const hook = zig_run.zig_snapshot.hook(&clock).?;
    try std.testing.expect(hook.loadFn == null and hook.saveFn != null);
    try std.testing.expect(hook.dueFn == null and hook.atFn == null);
    clock.state = .{ .at = .{ .ns = 1, .path = "y" } };
    const at = zig_run.zig_snapshot.hook(&clock).?;
    try std.testing.expect(at.saveFn == null and at.dueFn != null and at.atFn != null);
}
