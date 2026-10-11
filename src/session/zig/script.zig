//! Debugger commands on the Zig core (RA8EMU-114). This carries the
//! commands out on a ZigSession, and
//! prints through session_report and session_view, so one script gives one
//! transcript on either CPU. `core 0|1` hands the session to the other
//! core (RA8EMU-337), its image and temporary breaks with it.
const std = @import("std");
const Bounded = @import("ra8_chip").core.bounded.Bounded;
const break_table = @import("../breaks/table.zig");
const commands = @import("../commands.zig");
const elf = @import("ra8_board").image.elf;
const session = @import("../session.zig");
const session_place = @import("../place/address.zig");
const session_report = @import("../report.zig");
const session_view = @import("../view.zig");
const watch_table = @import("../watch/table.zig");
const session_api = @import("../api.zig");
const endpoint = @import("ra8_components").endpoint;

pub const Error = error{ Unsupported, MissingPart };

const Temporary = Bounded(break_table.Id, break_table.limits.capacity);

pub const ZigScript = struct {
    session: *session_api.Session,
    image: ?elf.Image = null,
    temporary: Temporary = .{},
    /// The parked core's image and temporary breaks, swapped in by `core`.
    other_image: ?elf.Image = null,
    other_temporary: Temporary = .{},

    /// Carry out one command. A command that fails prints why and the
    /// script carries on.
    pub fn apply(self: *ZigScript, command: commands.Command, out: anytype) !session.Outcome {
        if (command == .quit) {
            try self.session.flushItm(self.session.currentCore(), out, true);
            return .quit;
        }
        self.dispatch(command, out) catch |err| {
            try out.print("error: {s}\n", .{@errorName(err)});
        };
        return .more;
    }

    fn dispatch(self: *ZigScript, command: commands.Command, out: anytype) !void {
        switch (command) {
            .plug => |text| return self.plug(text, out),
            .unplug => |text| return self.unplug(text, out),
            .speed => |wanted| return self.speed(wanted, out),
            else => {},
        }
        const view = try self.session.view(self.session.currentCore());
        switch (command) {
            .brk => |at| try self.setBreak(at, false, out),
            .tbreak => |at| try self.setBreak(at, true, out),
            .delete => |id| try self.deleteBreak(id, out),
            .run => try self.go(.run, out),
            .cont => try self.go(.cont, out),
            .step => try self.go(.step, out),
            .next => try self.go(.next, out),
            .finish => try self.go(.finish, out),
            .registers => try session_view.registers(out, view),
            .examine => |want| try session_view.words(out, view, try self.resolve(want.place), want.words),
            .print => |text| try session_view.word(out, view, text, try self.resolve(text)),
            .backtrace => try session_report.backtrace(view, self.image, out),
            .watch => |want| try self.setWatch(want, out),
            .core => |index| try self.switchTo(index, out),
            else => return Error.Unsupported,
        }
    }

    /// `plug NAME@ENDPOINT`: the board wires a fresh NAME onto ENDPOINT.
    fn plug(self: *ZigScript, text: []const u8, out: anytype) !void {
        const split = std.mem.indexOfScalar(u8, text, '@') orelse return Error.MissingPart;
        if (split == 0) return Error.MissingPart;
        const at = try endpoint.parse(text[split + 1 ..]);
        try self.session.plug(self.session.currentCore(), at, text[0..split]);
        try out.print("Plugged {s} into {s}\n", .{ text[0..split], text[split + 1 ..] });
    }

    /// `unplug ENDPOINT`: the line behaves as if nothing were on it.
    fn unplug(self: *ZigScript, text: []const u8, out: anytype) !void {
        try self.session.unplug(self.session.currentCore(), try endpoint.parse(text));
        try out.print("Unplugged {s}\n", .{text});
    }

    /// `speed FACTOR`: the run budget scales, and a paced run's pacer moves
    /// to the new rate from here on (RA8EMU-184).
    fn speed(self: *ZigScript, wanted: ?f64, out: anytype) !void {
        try self.session.setSpeed(self.session.currentCore(), wanted);
        if (wanted) |factor| return out.print("Speed {d}x\n", .{factor});
        try out.writeAll("Speed max\n");
    }

    /// As session.zig's switchTo: say which core has the session and where
    /// it stands.
    fn switchTo(self: *ZigScript, index: u8, out: anytype) !void {
        if (index != @backingInt(self.session.currentCore())) {
            try self.session.switchTo(@fromBackingInt(@intCast(index)));
            std.mem.swap(?elf.Image, &self.image, &self.other_image);
            std.mem.swap(Temporary, &self.temporary, &self.other_temporary);
        }
        const view = try self.session.view(self.session.currentCore());
        try out.print("Core {d}, ", .{@backingInt(self.session.currentCore())});
        try session_report.line(view, self.image, try view.register(.pc), out);
    }

    fn resolve(self: *ZigScript, text: []const u8) !u32 {
        return session_place.resolve(try self.session.view(self.session.currentCore()), self.image, text);
    }

    fn setBreak(self: *ZigScript, at: commands.At, temporary: bool, out: anytype) !void {
        const address = try self.resolve(at.place) & ~@as(u32, 1);
        const id = try self.session.setBreakpoint(self.session.currentCore(), .{ .address = address, .arrival = at.arrival });
        if (temporary) try self.temporary.append(id);
        try out.print("{s} {d} at ", .{ if (temporary) "Temporary breakpoint" else "Breakpoint", id });
        try session_report.where(self.image, address, out);
        if (at.arrival > 1) try out.print(", arrival {d}", .{at.arrival});
        try out.print("\n", .{});
    }

    /// As session.zig's setWatch. It stops only when the session has a
    /// listening bus (ZigSession.watch).
    fn setWatch(self: *ZigScript, want: commands.Watch, out: anytype) !void {
        const address = try self.resolve(want.place);
        const span = try watch_table.Watch.span(address, session.limits.watch_bytes, want.kind);
        const id = try self.session.setWatchpoint(self.session.currentCore(), span);
        try out.print("Watchpoint {d} ({s}) at 0x{X:0>8}\n", .{ id, @tagName(want.kind), address });
    }

    fn deleteBreak(self: *ZigScript, id: break_table.Id, out: anytype) !void {
        const removed = try self.session.removePoint(self.session.currentCore(), id);
        if (removed == .watchpoint) return out.print("Deleted watchpoint {d}\n", .{id});
        self.forget(id);
        try out.print("Deleted breakpoint {d}\n", .{id});
    }

    fn forget(self: *ZigScript, id: break_table.Id) void {
        const index = std.mem.indexOfScalar(break_table.Id, self.temporary.constSlice(), id) orelse return;
        _ = self.temporary.swapRemove(index);
    }

    /// Run under `command` and say how it ended, in session.zig's words.
    fn go(self: *ZigScript, command: session_api.Run, out: anytype) !void {
        const core = self.session.currentCore();
        const ended = try self.session.run(core, command);
        const view = try self.session.view(core);
        const pc = try view.register(.pc);
        try self.session.flushItm(core, out, false);
        const stop = switch (ended) {
            .stop => |why| why,
            .count => {
                try out.print("Budget of {d} instructions spent at ", .{self.session.live.budget});
                try session_report.where(self.image, pc, out);
                return out.print("\n", .{});
            },
            .core => |why| {
                try out.print("Fault: {s} at ", .{@tagName(why)});
                try session_report.where(self.image, pc, out);
                return out.print("\n", .{});
            },
        };
        const temporary = stop == .breakpoint and std.mem.indexOfScalar(break_table.Id, self.temporary.constSlice(), stop.breakpoint) != null;
        if (temporary) {
            try self.session.clearBreakpoint(core, stop.breakpoint);
            self.forget(stop.breakpoint);
        }
        try session_report.prefix(out, stop, temporary);
        try session_report.line(view, self.image, pc, out);
    }
};
