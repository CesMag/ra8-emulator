//! A place in memory whose stores are worth naming.
//!
//! `--break-at` answers "was this function reached"; `--dump-mem` answers
//! "what does it hold at the end". Neither answers the question a wall
//! actually raises, which is who put this value here. A run that ends with
//! `g_eoh_err = 5` says the firmware gave up and says nothing about where,
//! and finding out by hand means breaking on one candidate after another.
//!
//! A watched place records every store that lands in it, with the program
//! counter that made it. The recording knows nothing about the engine
//! that runs the code, so it can be tested without one.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const place = @import("place/place.zig");
const symbols = @import("symbols.zig");
const spacing_mod = @import("spacing.zig");
const tally_mod = @import("tally.zig");

pub const limits = struct {
    /// Stores kept from the start of the run. The opening of a sequence is
    /// where a place is set up, and it names the code that owns it.
    pub const head: usize = 4;
    /// Stores kept from the end of the run. A value written once at the end
    /// of a failed path is one case this flag is for, but the sharper one is
    /// a place written in a loop that STOPS being written, or that latches:
    /// there the opening is setup noise and the last few stores are the
    /// whole answer. Measured on `threadx_blink`, where
    /// `_tx_thread_preempt_disable` takes 920 stores and the only ones worth
    /// reading are the last four, which show an increment from
    /// `_tx_thread_sleep` that never gets its matching decrement. Keeping
    /// the oldest stores alone could not show that at any list length a run
    /// could afford.
    pub const tail: usize = 4;
    /// The width of the window watched around the named address: a word,
    /// so a byte store anywhere in it is caught.
    pub const window: u32 = 4;
};

/// One store that landed in the watched place.
pub const Store = struct {
    /// Where the instruction that made it sits.
    pc: u32 = 0,
    /// The link register as the store happened. A value set through a
    /// shared failure helper has the same pc every time and the helper's
    /// name answers nothing; the caller is what the reader wanted, and
    /// this is where it is. Meaningless when the storing function has
    /// already pushed lr and reused it, so it is reported as the return
    /// address it is and never as a certainty.
    lr: u32 = 0,
    /// The value it wrote, as wide as it wrote it.
    value: u32 = 0,
    /// How many bytes it wrote.
    width: u8 = 0,
    /// Which byte of the watched word it started at.
    offset: u8 = 0,
    /// Modelled time as the store landed, in SysTick periods. A store list
    /// says who wrote and what; on a place a scheduler drives, the question
    /// under that is how far apart the writes are, and the pc cannot answer
    /// it. Zero for a run with no timebase wired, which is every unit test
    /// and every image that never arms SysTick.
    when: u64 = 0,
};

/// The place, and what has been written to it so far.
pub const Watched = struct {
    /// The address the command line named, already resolved.
    address: u32 = 0,
    /// Every store that landed in the window, counted whether or not it
    /// was kept: a count that stops at the list length would understate a
    /// value written in a loop, which is exactly when the count matters.
    seen: usize = 0,
    /// The first stores of the run, in order.
    first: [limits.head]Store = undefined,
    /// The most recent stores, held in a ring so the cost of a watch does
    /// not grow with the run however long it writes.
    last: [limits.tail]Store = undefined,
    /// Who wrote here and how often, for the places that take hundreds of
    /// stores from a dozen sites. src/session/tally.zig carries why
    /// the two ends of the list are not enough there.
    tally: tally_mod.Tally = .{},
    /// The period counter each store is stamped from, borrowed from the
    /// clocks rather than copied, so the stamp is read as the store lands
    /// instead of at the end of the run. Null leaves every stamp zero,
    /// which is every unit test and every image that never arms SysTick.
    now: ?*const u64 = null,
    /// How far apart in modelled time the stores landed. The list keeps
    /// only both ends, so this is the only thing that says whether the
    /// middle was spread out or bunched. src/session/spacing.zig carries why.
    spacing: spacing_mod.Spacing = .{},

    /// Record a store. Everything between the two ends is counted and
    /// dropped, so the memory a watch costs is fixed.
    pub fn record(self: *Watched, pc: u32, lr: u32, address: u32, width: u8, value: u32) void {
        const one: Store = .{
            .pc = pc,
            .lr = lr,
            .value = value,
            .width = width,
            .offset = @truncate(address -% self.address),
            .when = if (self.now) |clock| clock.* else 0,
        };
        self.tally.record(pc, value);
        self.spacing.record(one.when);
        if (self.seen < limits.head) self.first[self.seen] = one;
        self.last[self.seen % limits.tail] = one;
        self.seen += 1;
    }

    /// The stores that opened the run, oldest first.
    pub fn opening(self: *const Watched) []const Store {
        return self.first[0..@min(self.seen, limits.head)];
    }

    /// The stores that closed the run, oldest first, never repeating one
    /// the opening already carries. Written into the caller's buffer
    /// because the ring holds them out of order.
    pub fn closing(self: *const Watched, into: *[limits.tail]Store) []const Store {
        if (self.seen <= limits.head) return into[0..0];
        const held = @min(self.seen - limits.head, limits.tail);
        for (0..held) |index| {
            into[index] = self.last[(self.seen - held + index) % limits.tail];
        }
        return into[0..held];
    }

    /// Stores that fell between the two ends and were counted only.
    pub fn dropped(self: *const Watched) usize {
        var room: [limits.tail]Store = undefined;
        return self.seen - self.opening().len - self.closing(&room).len;
    }

    /// The last address of the watched window.
    pub fn end(self: Watched) u32 {
        return self.address + limits.window - 1;
    }
};

/// Where `--watch` named, resolved before the run starts.
///
/// A place with a dereference is refused the same way a break refuses one:
/// the pointer it would read has not been written yet when the hook has to
/// be attached, so the address it names does not exist. A spelling the
/// image cannot answer is reported and watched as nothing, because a run
/// that silently watches the wrong word is worse than one that watches
/// none.
pub fn resolve(image: elf.Image, spec: ?[]const u8) ?Watched {
    const asked = spec orelse return null;
    const parsed = place.parse(asked) catch |err| {
        std.debug.print("--watch {s}: {s}\n", .{ asked, @errorName(err) });
        return null;
    };
    if (parsed.deref) {
        std.debug.print("--watch {s}: a watched place cannot dereference\n", .{asked});
        return null;
    }
    const base = if (parsed.name) |name|
        symbols.addressOf(image, name) orelse {
            std.debug.print("--watch {s}: no symbol named {s}\n", .{ asked, name });
            return null;
        }
    else
        parsed.address;
    return .{ .address = parsed.apply(base) };
}

/// What landed in the watched word, once the run is over.
///
/// Each store names the function its program counter sits in, so the
/// answer to "who wrote this" is in the report rather than one objdump
/// away. A run in which nothing wrote there says so: that is an answer,
/// and often the surprising one.
pub fn print(out: anytype, image: elf.Image, spec: ?[]const u8, watched: ?Watched) !void {
    const one = watched orelse return;
    try out.print(
        "  watch         : {s} @0x{X:0>8}, {d} store(s)\n",
        .{ spec orelse "", one.address, one.seen },
    );
    for (one.opening()) |store| try line(out, image, store);
    const skipped = one.dropped();
    if (skipped > 0) {
        try out.print("                  and {d} more, ending with\n", .{skipped});
    }
    var room: [limits.tail]Store = undefined;
    for (one.closing(&room)) |store| try line(out, image, store);
    try spaced(out, one.spacing);
    try tallied(out, image, one.tally);
}

/// The shape of the writing over modelled time.
///
/// Printed above the tally because it answers a different question: the
/// tally divides the stores by who made them, this divides them by when.
/// A place written in bursts and a place written steadily look the same
/// in every other line of the report.
fn spaced(out: anytype, gaps: spacing_mod.Spacing) !void {
    if (gaps.quiet()) return;
    try out.print(
        "                  {d} group(s), {d} store(s) landed in the period before them\n",
        .{ gaps.groups(), gaps.together },
    );
    if (gaps.apart == 0) return;
    try out.print(
        "                  gaps of {d} to {d} period(s), {d} on average\n",
        .{ gaps.shortest, gaps.longest, gaps.mean() },
    );
}

/// Who wrote here, most often first.
///
/// Printed under the list rather than instead of it: the list says what
/// the run opened and closed with, the tally says how the writes divide
/// up, and on a busy kernel word the second is what pairs an increment
/// against its decrement.
fn tallied(out: anytype, image: elf.Image, counted: tally_mod.Tally) !void {
    if (counted.quiet()) return;
    var room: [tally_mod.limits.kept]tally_mod.Site = undefined;
    const ranked = counted.ranked(&room);
    var listed: usize = 0;
    for (ranked) |site| {
        if (listed >= tally_mod.limits.listed) break;
        listed += 1;
        try out.print(
            "                  {d} store(s) of 0x{X:0>8} from pc 0x{X:0>8}",
            .{ site.writes, site.value, site.pc },
        );
        if (symbols.inside(image, site.pc)) |at| {
            try out.print(" {s}+0x{X}", .{ at.name, at.offset });
        }
        try out.print("\n", .{});
    }
    if (counted.displaced > 0) {
        try out.print(
            "                  and {d} write(s) from sites that did not stay in the tally\n",
            .{counted.displaced},
        );
    }
}

/// One store, named.
fn line(out: anytype, image: elf.Image, store: Store) !void {
    try out.print(
        "                  +{d} {d}-byte 0x{X:0>8} at tick {d} from pc 0x{X:0>8}",
        .{ store.offset, store.width, store.value, store.when, store.pc },
    );
    if (symbols.inside(image, store.pc)) |at| {
        try out.print(" {s}+0x{X}", .{ at.name, at.offset });
    }
    // The return address, minus the Thumb bit, names the caller. A
    // shared helper is the common case and the pc alone is useless
    // there, so this is printed whenever it resolves to a function.
    if (symbols.inside(image, store.lr & ~@as(u32, 1))) |at| {
        try out.print(" via {s}+0x{X}", .{ at.name, at.offset });
    }
    try out.print("\n", .{});
}
