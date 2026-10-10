//! `--faults FILE` on a Zig run (RA8EMU-207): the schedule is read and
//! checked before the run starts, so a soak with a typo on its last line
//! fails in the first second rather than days in. A bad file says
//! `--faults FILE:LINE: reason` and the run ends with status 2, as a bad
//! flag does. A good one drives a session of its own over the board's
//! plug and fault hooks (src/session/board_schedule.zig), and the run's
//! boundary is wrapped so each event lands on its exact virtual time.
const std = @import("std");
const boot = @import("ra8_chip").core.cpu.boot;
const api = @import("api.zig");
const Board = @import("ra8_board").board.Board;
const session_plug = @import("board_plug.zig");
const session_faults = @import("board_faults.zig");
const session_schedule = @import("board_schedule.zig");
const fault_schedule = @import("ra8_components").fault_schedule;

pub const Applier = session_schedule.Applier;

/// Bigger than any schedule a person writes by hand.
pub const max_bytes: usize = 1024 * 1024;

/// One run's schedule and what it drives. Lives where `open` put it until
/// `deinit`: the session points into it.
pub const Run = struct {
    arena: std.heap.ArenaAllocator,
    plan: fault_schedule.Schedule,
    plugs: session_plug.Plugs,
    faults: session_faults.Faults,
    session: api.Session,
    applier: Applier,

    pub fn open(self: *Run, board: *Board, io: std.Io, path: []const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch |err| {
            std.debug.print("--faults {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        var diag = fault_schedule.Diagnostic{};
        self.plan = fault_schedule.parse(arena, text, &diag) catch |err| {
            std.debug.print("--faults {s}:{d}: {s}\n", .{ path, diag.line, @errorName(err) });
            return err;
        };
        self.plugs = session_plug.Plugs.init(board, arena);
        self.faults = session_faults.Faults.init(board, arena);
        self.session = .{ .live = undefined };
        self.session.attachTimeBase(&board.time.base);
        self.session.attachPlugs(self.plugs.hook());
        self.session.attachFaults(&self.faults);
        // The run's own boundary is only known once it starts: `boundary`.
        self.applier = .{ .events = self.plan.events, .session = &self.session, .clock = &board.time.base, .inner = undefined };
    }

    pub fn deinit(self: *Run) void {
        self.arena.deinit();
    }
};

/// The boundary a run uses: its own, or, with a schedule, its own wrapped
/// by the schedule once the 0s events are applied.
pub fn boundary(schedule: ?*Applier, inner: boot.Boundary) !boot.Boundary {
    const applier = schedule orelse return inner;
    applier.inner = inner;
    try applier.start();
    return applier.boundary();
}
