//! The session's control plane (time-travel design section 3): one
//! single-threaded transport that fronts the Session's data plane for the
//! GUI, CLI, GDB and RPC alike.
//!
//! `command` validates and queues a job without running a core and hands
//! back a ticket; `pump` drives that job in bounded slices and never sleeps;
//! `report` carries phase, position, progress and epoch; `finish` is the
//! blocking helper a CLI or GDB loop calls with an injected wall and poll.
//! The newest command preempts the running job the way a Cancel would, so a
//! preempted job's ticket goes dead and its waiter gets Cancelled. Pause
//! stops at the gap the current slice ends on, so pause then play is
//! byte-identical to never pausing. A play's speed only changes scheduling:
//! it maps onto the run budget and never touches guest state.
//!
//! Seek and run-to are part of the command language. A seek's target text
//! is parsed at the door, so a malformed one is InvalidArgs, not a silent
//! refusal. With no history bridge bound a seek stays NotReady; with one
//! bound the transport plans it from the committed log's facts and
//! executes it: restore the chosen base's checkpoint object, then run
//! forward until the landing position, reached in the position's own
//! order (round, then phase, offset, gap), never before it within the
//! target's round. A run-to lands where a breakpoint would, which is its
//! own stop-ordering case, and stays NotReady.

const std = @import("std");
const api = @import("../api.zig");
const command_mod = @import("command.zig");
const debug_session = @import("../session.zig");
const seek_engine = @import("../history/seek_engine.zig");
const play_mod = @import("play.zig");
const seek_mod = @import("seek.zig");
const back_mod = @import("back.zig");
const reverse_mod = @import("reverse.zig");
const report_mod = @import("report.zig");

pub const Command = command_mod.Command;
pub const Direction = command_mod.Direction;
pub const Ticket = command_mod.Ticket;
pub const Phase = command_mod.Phase;
pub const Progress = command_mod.Progress;
pub const Report = command_mod.Report;
pub const State = command_mod.State;
pub const Pumped = command_mod.Pumped;
pub const Finished = command_mod.Finished;
pub const Wall = command_mod.Wall;
pub const Poll = command_mod.Poll;
pub const Error = command_mod.Error;
pub const Hook = seek_mod.Hook;

/// One blocking `finish` pump is at most this much host time between polls.
const finish_slice_ns: u64 = 50_000_000;

/// The committed-log bridge the application binds (RA8EMU-1196, unit 17):
/// how the transport reads the served history. Null keeps the seek
/// refusal; bound, a seek plans from the bridge's facts and executes
/// through it.
pub const Bridge = struct {
    context: *anyopaque,
    /// The committed log's facts for planning, gathered fresh per call.
    /// The bridge owns the returned memory until the next call.
    facts: *const fn (*anyopaque) anyerror!seek_engine.Facts,
    /// Put the machine back at a checkpoint's saved state. The name is
    /// the checkpoint record's 128-bit digest as its 32-hex object name.
    restore: *const fn (*anyopaque, object: []const u8) anyerror!void,
    /// Returns the committed log's raw bytes, when available.
    logBytes: ?*const fn (*anyopaque) anyerror![]const u8 = null,
    /// Reads one object of the history's object space by its 32-hex name;
    /// the caller owns the bytes. Null when the bridge cannot.
    readObject: ?*const fn (*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror![]u8 = null,
};

pub const Job = struct {
    ticket: Ticket,
    epoch: u64,
    core: api.Core,
    kind: Kind,
    /// Slices the job has driven so far.
    slices: u64 = 0,
    /// The budget the job replaced, put back when it ends or is preempted.
    prior_budget: u64 = 0,
    /// A play's per-run instruction budget; 0 leaves the session's alone.
    budget: u64 = 0,
    /// An advance's virtual target.
    target_ns: u64 = 0,
    /// A step's remaining instructions.
    left: u64 = 0,
    /// Where a play or continue moves; backward is refused until the
    /// history contracts land, so forward is the only value today.
    dir: command_mod.Direction = .fwd,
    /// A play's pace, when one was asked for; null is `max`.
    speed: ?f64 = null,
    /// The wall moment the job's last backward slice ran at.
    last_ns: u64 = 0,
    /// A backward step's resolved plan, set when the job queues.
    back: ?back_mod.Back = null,
    /// A reverse-continue's resolved plan, set when the job queues.
    rc: ?reverse_mod.Rc = null,

    pub const Kind = union(enum) { play, cont, step, advance, seek: seek_mod.SeekKind, rcont };
};

/// The state payload a job reports with, from the payloads it really
/// holds (section 2.1). Shared by the report and the read gate.
pub fn jobState(job: *const Job) command_mod.State {
    return switch (job.kind) {
        .play => .{ .playing = .{ .dir = job.dir, .speed = job.speed } },
        .cont => .{ .continuing = .{ .dir = job.dir } },
        .advance => .{ .advancing = .{ .target_ns = job.target_ns } },
        .step => .{ .stepping = .{ .core = job.core, .count = job.left, .dir = job.dir } },
        .seek => .{ .seeking = .{ .target = job.kind.seek.target } },
        .rcont => .{ .reverse_continuing = .{ .core = job.core } },
    };
}

pub const Transport = struct {
    session: *api.Session,
    epoch: u64 = 0,
    next_ticket: Ticket = 1,
    job: ?Job = null,
    /// The newest job that finished, so a late `finish` still answers.
    done: ?Finished = null,
    /// A settled job whose final history flush must succeed before delivery.
    pending_finish: ?Finished = null,
    /// The bound history bridge (unit 17), when the application serves
    /// one. Null keeps a seek refused.
    history: ?Bridge = null,
    /// The wall moment of the slice being driven, for a reverse clock.
    wall_ns: u64 = 0,
    /// Told of every command and planned seek; the application's prefetcher binds it.
    hook: ?seek_mod.Hook = null,
    cancelled: bool = false,

    /// Validate and queue a command. Nothing runs until the next `pump`.
    pub fn command(self: *Transport, cmd: Command) !Ticket {
        if (self.hook) |hook| hook.commandFn(hook.context);
        self.cancelled = false;
        switch (cmd) {
            .pause => {
                if (self.session.persistent_recorder) |rec| try rec.force();
                self.cancel();
                self.epoch += 1;
                return self.issue();
            },
            .cont => return play_mod.queue(self, null, .cont, .fwd),
            .play => |play| return play_mod.queue(self, play.speed, .play, play.dir),
            .step => |step| return self.queueStep(step),
            .advance => |advance| return self.queueAdvance(advance),
            .seek => |seek| return seek_mod.queue(self, seek.target),
            .rcont => return reverse_mod.queue(self),
            .run_to => return Error.NotReady,
        }
    }

    fn queueStep(self: *Transport, step: command_mod.Step) !Ticket {
        if (step.count == 0) return Error.InvalidArgs;
        if (step.dir == .back) return back_mod.queue(self, step);
        const prior = budgetOf(self.session, step.core);
        self.cancel();
        self.epoch += 1;
        const ticket = self.issue();
        self.job = .{ .ticket = ticket, .epoch = self.epoch, .core = step.core, .kind = .step, .prior_budget = prior, .left = step.count, .dir = step.dir };
        return ticket;
    }

    fn queueAdvance(self: *Transport, advance: command_mod.Advance) !Ticket {
        if (advance.ns == 0) return Error.InvalidArgs;
        const from = try self.session.now();
        const target = std.math.add(u64, from, advance.ns) catch return Error.InvalidArgs;
        const prior = budgetOf(self.session, advance.core);
        self.cancel();
        self.epoch += 1;
        const ticket = self.issue();
        self.job = .{ .ticket = ticket, .epoch = self.epoch, .core = advance.core, .kind = .advance, .prior_budget = prior, .target_ns = target };
        return ticket;
    }

    pub fn issue(self: *Transport) Ticket {
        const ticket = self.next_ticket;
        self.next_ticket += 1;
        self.cancelled = false;
        return ticket;
    }

    /// Preempt the running job the way a Cancel would: its ticket goes dead.
    pub fn cancel(self: *Transport) void {
        seek_mod.disarm(self);
        self.cancelled = true;
        if (self.job) |job| {
            self.session.setRunBudget(job.core, job.prior_budget) catch {};
            // A backward job's cancel returns the machine to the origin
            // checkpoint it queued at, whatever its replay rebased to
            // meanwhile (the seek contract's cancel rule, prompt 17).
            if (job.back) |*back| self.restoreBase(back.origin) catch {};
            if (job.rc) |*rc| self.restoreBase(rc.origin) catch {};
            if (job.dir == .back) {
                if (self.session.smooth_rewind) |rewind| rewind.pause() catch {};
            }
            self.job = null;
        }
    }

    /// Drive the queued job in slices bounded by the wall until `until_ns`,
    /// a stop, or the job's own end. Never sleeps.
    pub fn pump(self: *Transport, wall: Wall, until_ns: u64) !Pumped {
        if (self.session.persistent_recorder) |rec| try rec.maybeCommit(rec.now());
        var finished = self.pending_finish;
        if (finished == null) if (self.job) |*job| {
            finished = try self.drive(job, wall, until_ns);
            self.pending_finish = finished;
        };
        if (self.session.persistent_recorder) |rec| {
            if (finished != null) try rec.force() else try rec.maybeCommit(rec.now());
        }
        self.pending_finish = null;
        return .{ .report = self.report(), .finished = finished, .drain = self.drainNeeded() };
    }

    /// The transport state now, without running anything.
    pub const report = report_mod.report;

    /// The read gate (the contract's "reads return busy{state}" while
    /// moving): the running job's state when a read must not touch the
    /// machine, null when it may. A job between slices is in flight; a
    /// queued job has driven no slice yet, so it has moved the machine
    /// nowhere and reads are free until its first pump.
    pub fn busy(self: *const Transport) ?command_mod.State {
        if (self.job) |*job| {
            if (job.slices == 0) return null;
            return jobState(job);
        }
        // A rewind still settling after its job ended keeps reads gated.
        if (self.session.smooth_rewind) |rewind| {
            if (rewind.isBusy()) return .{ .playing = .{ .dir = .back, .speed = null } };
        }
        return null;
    }

    /// Block on one ticket until its job ends, polling between slices.
    /// A ticket that was preempted, or one the poll cancels, is Cancelled.
    pub fn finish(self: *Transport, ticket: Ticket, wall: Wall, poll: ?Poll) !api.Ended {
        while (true) {
            if (self.done) |done| {
                if (done.ticket == ticket) {
                    if (self.session.persistent_recorder) |rec| try rec.force();
                    if (self.pending_finish) |pending| if (pending.ticket == ticket) {
                        self.pending_finish = null;
                    };
                    return done.ended;
                }
            }
            if (self.job == null or self.job.?.ticket != ticket) return Error.Cancelled;
            const start = wall.nowFn(wall.context);
            _ = try self.pump(wall, start + finish_slice_ns);
            // The pump may have finished the job; only a live one interrupts.
            if (self.job == null or self.job.?.ticket != ticket) continue;
            if (poll) |p| {
                if (p.pollFn(p.context)) {
                    // The application wants the thread back: halt the core
                    // like a front end's interrupt and settle the job with
                    // that stop, so the machine is stopped and reported.
                    const stopped = try self.session.interrupt(self.job.?.core);
                    const job = &self.job.?;
                    const finished = self.settle(job, .{ .stop = stopped });
                    return finished.ended;
                }
            }
        }
    }

    fn drive(self: *Transport, job: *Job, wall: Wall, until_ns: u64) !?Finished {
        while (true) {
            const now_ns = wall.nowFn(wall.context);
            if (now_ns >= until_ns) break;
            self.wall_ns = now_ns;
            const ended: ?api.Ended = switch (job.kind) {
                .play, .cont => try play_mod.slice(self, job),
                .advance => try self.advanceSlice(job),
                .step => try self.stepSlice(job),
                .seek => try seek_mod.slice(self, job),
                .rcont => try reverse_mod.slice(self, job),
            };
            job.slices += 1;
            if (job.kind == .seek) seek_mod.sampleRate(self, job, now_ns);
            if (ended) |stop| return self.settle(job, stop);
        }
        return null;
    }

    fn stepSlice(self: *Transport, job: *Job) !?api.Ended {
        if (job.dir == .back) return back_mod.slice(self, job);
        if (self.session.window) |w| {
            if (w.cursor() < w.count()) {
                const canonical = @import("../history/canonical_step.zig");
                const tc: @import("../history/trail.zig").Core = if (job.core == .cpu0) .cpu0 else .cpu1;
                if (canonical.stepForward(w, tc)) |_| {
                    job.left -= 1;
                    return if (job.left == 0) .{ .stop = .stepped } else null;
                } else |err| switch (err) {
                    error.OutsideWindow => try w.walkTo(w.count()),
                    else => return err,
                }
            }
        }
        const ended = try self.session.run(job.core, .step);
        job.left -= 1;
        const point = ended == .stop and ended.stop != .stepped;
        if (job.left == 0 or point) return ended;
        return null;
    }

    /// Restores one base's checkpoint object through the bridge;
    /// `.current` needs no restore, the machine's own state being the
    /// history's beginning.
    pub fn restoreBase(self: *Transport, base: seek_engine.Base) !void {
        const bridge = self.history orelse return Error.NotReady;
        switch (base) {
            .current, .window => {},
            .checkpoint => |checkpoint| {
                var name: [32]u8 = undefined;
                objectName(checkpoint.object, &name);
                try bridge.restore(bridge.context, &name);
                // The restored position names the line it is replayed on,
                // and the line's interventions from there on are due again.
                self.session.stampLine();
                // The window described the run before the restore: it
                // starts over at the restored state, on the stamped line.
                self.session.replantWindow();
                if (bridge.logBytes) |read| try self.session.loadReplayInterventions(try read(bridge.context));
            },
        }
    }

    fn advanceSlice(self: *Transport, job: *Job) !?api.Ended {
        const session = self.session;
        if (session.window) |w| {
            while (w.cursor() < w.count() and (try session.now()) < job.target_ns) {
                if (!try w.redo()) break;
            }
            if ((try session.now()) >= job.target_ns) return reached();
        }
        const before = try session.now();
        const base = session.time_base orelse return error.NoTime;
        const left = base.cyclesUntil(job.target_ns) -| saved(session);
        if (left == 0) return reached();
        try session.setRunBudget(job.core, left);
        session.advancing = true;
        defer session.advancing = false;
        const ended = try session.run(job.core, .cont);
        if (ended != .count) return ended;
        const after = try session.now();
        if (after == before or after >= job.target_ns) return reached();
        return null;
    }

    /// Close a finished job: put its budget back, forget it, and remember
    /// the result. The result is captured before the job is cleared, since
    /// the caller's pointer lives inside the optional being cleared.
    fn settle(self: *Transport, job: *Job, ended: api.Ended) Finished {
        seek_mod.disarm(self);
        const finished: Finished = .{ .ticket = job.ticket, .epoch = job.epoch, .core = job.core, .ended = ended };
        self.session.setRunBudget(job.core, job.prior_budget) catch {};
        self.job = null;
        self.done = finished;
        return finished;
    }

    fn drainNeeded(self: *const Transport) bool {
        return self.session.event_stream.nearFull();
    }
};

/// A checkpoint record's 128-bit digest as its object name: the lowercase
/// hex the object space files carry (refs.zig's encoding).
pub fn objectName(digest: [16]u8, name: *[32]u8) void {
    for (digest, 0..) |byte, i| {
        _ = std.fmt.bufPrint(name[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
    }
}

pub fn reached() ?api.Ended {
    const count: api.Ended = .count;
    return count;
}

/// The run budget `core` holds now, whether it has the session or is parked.
pub fn budgetOf(session: *const api.Session, core: api.Core) u64 {
    const live = &session.live;
    if (live.index == @backingInt(core)) return live.budget;
    const parked = live.other orelse return debug_session.limits.default_budget;
    return parked.budget;
}

/// Cycles the open stretch has saved, which the board's closed time lacks.
pub fn saved(session: *const api.Session) u64 {
    const grid = session.grid orelse return 0;
    return grid.stretch.carry;
}
