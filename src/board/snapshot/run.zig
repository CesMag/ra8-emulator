//! A whole run in one snapshot file (RA8EMU-689): the header, the board
//! (part first, RA8EMU-688), guest memory, then one cpu section per core,
//! 0 for CPU0 and 1 for CPU1.
//!
//! Load into a freshly built run: a fresh store, fresh cores and a freshly
//! attached board. A file from another part is refused before anything
//! changes; any later error leaves the run partly loaded, so drop it, the
//! same rule as cpu/snapshot.zig and board.zig.
const file = @import("ra8_snapshot").file;
const memory = @import("memory.zig");
const cpu = @import("ra8_chip").core.cpu.cpu_snapshot;
const board_snap = @import("board.zig");
const Store = @import("ra8_chip").core.cpu.memory.store.Store;
const Cpu = @import("ra8_chip").core.cpu.cpu.Cpu;

pub const Error = file.Error || memory.Error || cpu.Error || board_snap.Error;

pub fn save(writer: anytype, store: *const Store, cores: []const *const Cpu, board: anytype) !void {
    try file.writeHeader(writer);
    try board_snap.save(board, writer);
    try memory.save(store, writer);
    for (cores, 0..) |core, index| try cpu.save(core, @intCast(index), writer);
}

/// Refuses a file a load would refuse before touching anything: another
/// part, or no memory section. A live restore checks before it wipes.
pub fn check(bytes: []const u8, board: anytype) !void {
    try board_snap.partOf(board.part, bytes);
    _ = try file.Reader.find(bytes, .memory) orelse return Error.Missing;
}

/// Fills a fresh run from a whole file. Every core asked for must have its
/// section; extra cores in the file are ignored.
pub fn load(bytes: []const u8, store: *Store, cores: []const *Cpu, board: anytype) !void {
    try board_snap.partOf(board.part, bytes);
    const section = try file.Reader.find(bytes, .memory) orelse return Error.Missing;
    try memory.load(store, section.payload);
    for (cores, 0..) |core, index| try cpu.load(core, @intCast(index), bytes);
    try board_snap.load(board, bytes);
}
