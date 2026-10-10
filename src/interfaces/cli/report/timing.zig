//! The time bases at the end of a run: what elapsed, what the firmware was
//! watching, and what it was never told about.
//!
//! Two cycle numbers rather than one, because they answer different
//! questions. How far the run got is a property of the run. What DWT_CYCCNT
//! holds is a property of the firmware, which only counts once it arms the
//! counter, and on this corpus most images never do. Printing only the
//! second made a run that covered two million instructions report zero.
//!
//! A third number when a run spent time in a spin: the cycles that were
//! charged without being executed, because the machine had been stepped back
//! to the state it started in and nothing it did on the way could be seen.
//! It is reported rather than hidden because it is the difference between a
//! run that idled and a run that worked, and the reader cannot tell them
//! apart from the elapsed count alone. The rest of the file names the
//! sites behind the run's counters: counted pcs and where exceptions
//! were taken.
const clocks = @import("ra8_chip").periph.clocks;
const tally_mod = @import("ra8_session").tally;
const taken_in_mod = @import("ra8_session").taken_in;
const elf = @import("ra8_board").image.elf;
const symbols = @import("ra8_session").symbols;
const pc_hits = @import("ra8_session").pc_hits;

const Writer = @import("../report.zig").Writer;

/// The time lines of a run report: cycles, SysTick periods and pends from the
/// run's own timebase, plus the warnings when periods collapsed, DWT_CYCCNT
/// ran short or boundaries ended where the firmware armed SysTick. The
/// `--cpu zig` report prints these (RA8EMU-470).
pub fn clock(out: Writer, timebase: clocks.Clocks) !void {
    try out.print(
        "time: {d} cycles elapsed, {d} SysTick periods, {d} pended",
        .{ timebase.elapsed, timebase.ticks, timebase.pends },
    );
    if (timebase.collapsed != 0) {
        try out.print(
            ", {d} PERIOD(S) THE FIRMWARE WAS NEVER TOLD ABOUT",
            .{timebase.collapsed},
        );
    }
    try out.print("\n", .{});
    if (timebase.cycles != timebase.elapsed) {
        try out.print(
            "time: DWT_CYCCNT counted {d} of them; the firmware armed it late or never\n",
            .{timebase.cycles},
        );
    }
    if (timebase.rearms != 0) {
        try out.print(
            "time: {d} boundary(ies) ended where the firmware armed SysTick\n",
            .{timebase.rearms},
        );
    }
}

/// Where the machine was when each exception was taken.
///
/// A count of entries says the vectors fired; it cannot say whether one of
/// them cut a sequence that had to run whole. Naming the interrupted
/// function is what makes that answerable: an exception taken inside
/// `_tx_thread_sleep` or `_tx_thread_system_suspend` lands between the
/// increment of `_tx_thread_preempt_disable` and its matching decrement,
/// and a thread stopped in there holds the scheduler shut.
pub fn takenFrom(out: anytype, image: elf.Image, counted: tally_mod.Tally) !void {
    if (counted.quiet()) return;
    var room: [tally_mod.limits.kept]tally_mod.Site = undefined;
    const ranked = counted.ranked(&room);
    var listed: usize = 0;
    for (ranked) |site| {
        if (listed >= tally_mod.limits.listed) break;
        listed += 1;
        try out.print(
            "interrupts: {d} entry(ies) of exception {d} from pc 0x{X:0>8}",
            .{ site.writes, site.value, site.pc },
        );
        if (symbols.inside(image, site.pc)) |at| {
            try out.print(" {s}+0x{X}", .{ at.name, at.offset });
        }
        try out.print("\n", .{});
    }
    if (counted.displaced > 0) {
        try out.print(
            "interrupts: and {d} entry(ies) from places that did not stay in the tally\n",
            .{counted.displaced},
        );
    }
}

/// Every exception taken inside the function `--taken-in` named.
///
/// Printed whole, oldest first, with nothing dropped in the middle: this
/// exists for the entry that happens once in a run, which is the one a
/// tally cannot hold. A window that caught nothing says so, because "no
/// exception was taken in there" is an answer and usually the surprising
/// one.
pub fn takenIn(out: anytype, image: elf.Image, spec: ?[]const u8, window: ?taken_in_mod.Window) !void {
    const asked = spec orelse return;
    const one = window orelse return;
    try out.print(
        "taken-in: {s} @0x{X:0>8}+0x{X}, {d} exception(s) taken inside\n",
        .{ asked, one.base, one.size, one.seen },
    );
    for (one.kept()) |entry| {
        try out.print(
            "                  #{d} exception {d} at pc 0x{X:0>8}",
            .{ entry.at, entry.number, entry.pc },
        );
        if (symbols.inside(image, entry.pc)) |at| {
            try out.print(" {s}+0x{X}", .{ at.name, at.offset });
        }
        try out.print("\n", .{});
    }
    if (one.missed() > 0) {
        try out.print("                  and {d} more not kept\n", .{one.missed()});
    }
}

/// How many times each counted instruction ran.
///
/// Every other counter in the report is a side effect of something else:
/// stores that landed in a word, stores that found a pend standing,
/// exceptions taken. When two of those disagree about the same stretch of
/// code there is nothing in the tree to settle it, because neither of them
/// measures the execution. This does, and nothing else, so a count here is
/// the one number that can call another one wrong.
pub fn pcHits(out: anytype, image: elf.Image, hits: pc_hits.Hits) !void {
    if (hits.quiet()) return;
    for (hits.asked()) |one| {
        try out.print("time: pc 0x{X:0>8}", .{one.at});
        if (symbols.inside(image, one.at)) |at| {
            try out.print(" {s}+0x{X}", .{ at.name, at.offset });
        }
        try out.print(" ran {d} time(s)\n", .{one.hits});
    }
    if (hits.refused != 0) {
        try out.print(
            "time: {d} more address(es) asked for than the {d} a run can count\n",
            .{ hits.refused, pc_hits.limits.places },
        );
    }
}
