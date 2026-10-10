//! What ends a soak run before its duration (RA8EMU-186, slice 2).
//!
//! `--run-for` arms it. A watchdog reset while armed is the soak's first
//! event: the run ends at the boundary that asked for it, before the reboot,
//! so the report says when the firmware stopped feeding the dog rather than
//! carrying on into a second boot. The first event is the one kept; whatever
//! follows from it is not news. A fault the core latched into CFSR, HFSR
//! or SFSR is an event too (slice 2b, src/board/run/soak_fault.zig), and so
//! is a watched stack canary or heap guard word that changed (RA8EMU-619,
//! src/board/run/soak_watch.zig).
const std = @import("std");
const timebase = @import("../../chip/periph/time/timebase.zig");
const Calendar = @import("../../chip/periph/rtc/rtc_clock.zig").Calendar;
pub const soak_watch = @import("soak_watch.zig");
pub const soak_threads = @import("soak_threads.zig");

pub const Kind = enum {
    watchdog_reset,
    iwdt_reset,
    stack_overflow,
    mem_manage,
    bus_fault,
    usage_fault,
    secure_fault,
    hard_fault,
    stack_canary,
    heap_guard,

    pub fn text(self: Kind) []const u8 {
        return switch (self) {
            .watchdog_reset => "watchdog reset (WDT)",
            .iwdt_reset => "watchdog reset (IWDT)",
            .stack_overflow => "stack overflow (UsageFault STKOF)",
            .mem_manage => "MemManage fault (MPU)",
            .bus_fault => "BusFault",
            .usage_fault => "UsageFault",
            .secure_fault => "SecureFault",
            .hard_fault => "HardFault",
            .stack_canary => "stack canary overwritten",
            .heap_guard => "heap guard word changed",
        };
    }
};

pub const Event = struct {
    kind: Kind,
    /// Virtual nanoseconds since reset when it happened.
    at_ns: u64,
    /// Where the run stopped (slice 3): the core whose fault or reset it
    /// was, its PC, and the RTC's date when the clock was running.
    core: u8 = 0,
    pc: ?u32 = null,
    date: ?Calendar = null,
    /// The watched word that changed, for a canary or guard event.
    word: ?u32 = null,
};

pub const Soak = struct {
    armed: bool = false,
    event: ?Event = null,
    /// Canary and guard words read at each boundary while armed.
    watch: soak_watch.Watch = .{},
    /// ThreadX's created-thread list, whose stack canaries join `watch`.
    threads: soak_threads.Threads = .{},

    /// Keep the first event of an armed run; anything else is ignored.
    pub fn note(self: *Soak, kind: Kind, at_ns: u64) void {
        if (!self.armed or self.event != null) return;
        self.event = .{ .kind = kind, .at_ns = at_ns };
    }

    /// Note the first watched word found changed as the event, naming it;
    /// with none changed, pick up threads ThreadX created since the last look.
    pub fn check(self: *Soak, memory: anytype, at_ns: u64) void {
        if (!self.armed or self.event != null) return;
        if (self.watch.changed(memory)) |found| {
            self.note(found.kind, at_ns);
            self.event.?.word = found.address;
            return;
        }
        self.threads.refresh(&self.watch, memory);
    }

    /// Say where the run stopped, once it has: the PC the core ended on and
    /// the RTC date, null when the clock was not running.
    pub fn place(self: *Soak, pc: u32, date: ?Calendar) void {
        if (self.event) |*event| {
            event.pc = pc;
            event.date = date;
        }
    }

    /// Has an event ended the run?
    pub fn ended(self: *const Soak) bool {
        return self.event != null;
    }

    /// The soak line: nothing for a run without --run-for.
    pub fn line(self: *const Soak, out: anytype) !void {
        if (!self.armed) return;
        const event = self.event orelse return out.print("soak: no events\n", .{});
        const s = event.at_ns / timebase.ns_per_s;
        const ns = event.at_ns % timebase.ns_per_s;
        try out.print("soak: stopped on {s} at {d}.{d:0>9} s virtual, core {d}", .{ event.kind.text(), s, ns, event.core });
        if (event.word) |word| try out.print(", word 0x{X:0>8}", .{word});
        if (event.pc) |pc| try out.print(", pc 0x{X:0>8}", .{pc});
        if (event.date) |d| try out.print(", rtc 20{d:0>2}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ d.year, d.month, d.day, d.hour, d.minute, d.second });
        try out.print("\n", .{});
    }
};
