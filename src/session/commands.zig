//! One line of the debugger's command language, parsed.
//!
//! The command layer reads lines from a terminal or a script file, and a
//! session applies them to the stop machine. This file only turns text into
//! a `Command`. It holds no state and needs no image or core, so a whole
//! script can be checked line by line before anything runs.
//!
//! A place (`target`, `0x22000054`, `target+4`, `@s_open+0x40`, `fw.zig:8`)
//! is kept as written. src/session/place/place.zig parses it, and the session
//! resolves it against the image, because only the session holds one.
//!
//! The words follow gdb's where gdb has one, so a session reads the way a
//! gdb user would type it:
//!
//! ```
//! break PLACE [N]     b       stop on the Nth arrival at PLACE
//! tbreak PLACE [N]            the same, deleted once it stops
//! delete ID           d       forget a break
//! watch PLACE                 stop after a store to PLACE
//! rwatch PLACE                stop after a load from PLACE
//! awatch PLACE                stop after either
//! run | continue      r | c   start, or carry on
//! step | next | finish s | n  one instruction, over a call, out of one
//! info registers      i r     the core registers
//! info line PLACE             the source line PLACE belongs to
//! x PLACE [N]                 N words at PLACE
//! print PLACE         p       the word at PLACE
//! disassemble [PLACE [N]]     N instructions from PLACE, or the pc
//! backtrace           bt      the call chain
//! list [PLACE]        l       the source around PLACE, or the pc
//! core 0|1                    which CPU the next commands act on
//! plug NAME@ENDPOINT          wire a fresh part in mid-run
//! unplug ENDPOINT             take the part on ENDPOINT off mid-run
//! speed FACTOR                pace the run at FACTOR times real time, or max
//! quit                q
//! ```
//!
//! A `#` starts a comment, and a blank line is nothing at all, so a script
//! can explain itself.
const std = @import("std");
const watch_table = @import("watch/table.zig");

pub const Error = error{ UnknownCommand, MissingArgument, ExtraArgument, BadNumber, BadCore, BadSwitch };

pub const limits = struct {
    /// Words `x` prints when no count is given.
    pub const default_words: u32 = 4;
    /// Instructions `disassemble` prints when no count is given.
    pub const default_instructions: u32 = 8;
    /// How many CPUs `core` can pick between.
    pub const cores: u8 = 2;
    /// Everything from this character on is a comment.
    pub const comment: u8 = '#';
};

/// Where a break goes, and which arrival it stops on.
pub const At = struct {
    place: []const u8,
    arrival: u32 = 1,
};

pub const Watch = struct {
    place: []const u8,
    kind: watch_table.Kind,
};

pub const Examine = struct {
    place: []const u8,
    words: u32 = limits.default_words,
};

pub const Disassemble = struct {
    /// Null means from the program counter.
    place: ?[]const u8 = null,
    count: u32 = limits.default_instructions,
};

pub const Command = union(enum) {
    /// `info breakpoints`: the breaks and watches this core holds.
    breakpoints,
    brk: At,
    tbreak: At,
    delete: u32,
    watch: Watch,
    run,
    cont,
    step,
    next,
    finish,
    registers,
    /// `info line PLACE`: the source line the place's address belongs to.
    line: []const u8,
    examine: Examine,
    print: []const u8,
    disassemble: Disassemble,
    backtrace,
    /// `list [PLACE]`: the source around a place, or around the pc.
    list: ?[]const u8,
    core: u8,
    /// `halting on|off`: DHCSR.C_DEBUGEN for the selected core. Off, the
    /// firmware's FPB and DWT events go to DebugMonitor instead of halting.
    halting: bool,
    /// `plug NAME@ENDPOINT`, kept as written: the board parses it, as the
    /// session resolves a place (RA8EMU-212).
    plug: []const u8,
    /// `unplug ENDPOINT`, kept as written.
    unplug: []const u8,
    /// `speed FACTOR`: the session checks the range (RA8EMU-184). Null is
    /// `speed max`, an unpaced run as with `--speed max` (RA8EMU-714).
    speed: ?f64,
    quit,
};

/// The first word of a line, before its arguments are read.
const Verb = enum {
    brk,
    tbreak,
    delete,
    watch,
    rwatch,
    awatch,
    run,
    cont,
    step,
    next,
    finish,
    info,
    registers,
    examine,
    print,
    disassemble,
    backtrace,
    list,
    core,
    halting,
    plug,
    unplug,
    speed,
    quit,
};

const verbs = std.StaticStringMap(Verb).initComptime(.{
    .{ "break", .brk },         .{ "b", .brk },
    .{ "tbreak", .tbreak },     .{ "delete", .delete },
    .{ "d", .delete },          .{ "watch", .watch },
    .{ "rwatch", .rwatch },     .{ "awatch", .awatch },
    .{ "run", .run },           .{ "r", .run },
    .{ "continue", .cont },     .{ "c", .cont },
    .{ "step", .step },         .{ "s", .step },
    .{ "stepi", .step },        .{ "si", .step },
    .{ "next", .next },         .{ "n", .next },
    .{ "nexti", .next },        .{ "ni", .next },
    .{ "finish", .finish },     .{ "info", .info },
    .{ "i", .info },            .{ "regs", .registers },
    .{ "x", .examine },         .{ "print", .print },
    .{ "p", .print },           .{ "disassemble", .disassemble },
    .{ "disas", .disassemble }, .{ "backtrace", .backtrace },
    .{ "list", .list },         .{ "l", .list },
    .{ "bt", .backtrace },      .{ "where", .backtrace },
    .{ "core", .core },         .{ "quit", .quit },
    .{ "q", .quit },            .{ "halting", .halting },
    .{ "plug", .plug },         .{ "unplug", .unplug },
    .{ "speed", .speed },
});

/// The names `info` lists breaks and watches under.
const info_breakpoints = std.StaticStringMap(void).initComptime(.{
    .{"breakpoints"}, .{"break"}, .{"br"}, .{"b"},
});

/// What `info` can be asked about.
const info_registers = std.StaticStringMap(void).initComptime(.{
    .{"registers"}, .{"reg"}, .{"r"},
});

const Words = std.mem.TokenIterator(u8, .any);

/// Parse one line. Null is a line with nothing to do: blank, or only a
/// comment.
pub fn parse(line: []const u8) Error!?Command {
    const text = strip(line);
    if (text.len == 0) return null;
    var words = std.mem.tokenizeAny(u8, text, " \t");
    const verb = verbs.get(words.next().?) orelse return Error.UnknownCommand;
    return try build(verb, &words);
}

fn build(verb: Verb, words: *Words) Error!Command {
    const command: Command = switch (verb) {
        .brk => .{ .brk = try at(words) },
        .tbreak => .{ .tbreak = try at(words) },
        .delete => .{ .delete = try number(try required(words)) },
        .watch => .{ .watch = .{ .place = try required(words), .kind = .write } },
        .rwatch => .{ .watch = .{ .place = try required(words), .kind = .read } },
        .awatch => .{ .watch = .{ .place = try required(words), .kind = .access } },
        .run => .run,
        .cont => .cont,
        .step => .step,
        .next => .next,
        .finish => .finish,
        .info => try info(words),
        .registers => .registers,
        .examine => .{ .examine = try examine(words) },
        .print => .{ .print = try required(words) },
        .disassemble => .{ .disassemble = try disassemble(words) },
        .backtrace => .backtrace,
        .list => .{ .list = words.next() },
        .core => .{ .core = try core(try required(words)) },
        .halting => .{ .halting = try onOff(try required(words)) },
        .plug => .{ .plug = try required(words) },
        .unplug => .{ .unplug = try required(words) },
        .speed => .{ .speed = try speedFactor(try required(words)) },
        .quit => .quit,
    };
    if (words.next() != null) return Error.ExtraArgument;
    return command;
}

fn at(words: *Words) Error!At {
    const place = try required(words);
    const arrival = if (words.next()) |text| try number(text) else 1;
    if (arrival == 0) return Error.BadNumber;
    return .{ .place = place, .arrival = arrival };
}

fn info(words: *Words) Error!Command {
    const what = try required(words);
    if (std.mem.eql(u8, what, "line")) return .{ .line = try required(words) };
    if (info_breakpoints.get(what) != null) return .breakpoints;
    if (info_registers.get(what) == null) return Error.UnknownCommand;
    return .registers;
}

fn examine(words: *Words) Error!Examine {
    const place = try required(words);
    const count = if (words.next()) |text| try number(text) else limits.default_words;
    return .{ .place = place, .words = count };
}

fn disassemble(words: *Words) Error!Disassemble {
    const place = words.next() orelse return .{};
    const count = if (words.next()) |text| try number(text) else limits.default_instructions;
    return .{ .place = place, .count = count };
}

fn core(text: []const u8) Error!u8 {
    const index = std.fmt.parseInt(u8, text, 0) catch return Error.BadCore;
    if (index >= limits.cores) return Error.BadCore;
    return index;
}

fn onOff(text: []const u8) Error!bool {
    if (std.mem.eql(u8, text, "on")) return true;
    if (std.mem.eql(u8, text, "off")) return false;
    return Error.BadSwitch;
}

fn required(words: *Words) Error![]const u8 {
    return words.next() orelse Error.MissingArgument;
}

/// A speed factor, or null for `max`.
fn speedFactor(text: []const u8) Error!?f64 {
    if (std.mem.eql(u8, text, "max")) return null;
    return std.fmt.parseFloat(f64, text) catch Error.BadNumber;
}

/// A count or an id, decimal or `0x` hex.
fn number(text: []const u8) Error!u32 {
    return std.fmt.parseInt(u32, text, 0) catch Error.BadNumber;
}

/// The line without its comment, its line ending or its outer spaces.
fn strip(line: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, line, limits.comment) orelse line.len;
    return std.mem.trim(u8, line[0..end], " \t\r\n");
}
