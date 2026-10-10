//! `--audio-out PATH [--audio-rate HZ]` (RA8EMU-649, part of RA8EMU-570):
//! what SSIE0 transmitted during a Zig run, written as a WAV.
//!
//! A listener on SSIE0's shift (ssie.tap, RA8EMU-648) hands each sample to
//! the WAV recorder (RA8EMU-647) along with the board's virtual time. The
//! first sample fixes the stream's shape from SSICR. If DWL, FRM or PDTA
//! changes later, recording stops there and the report says so, because one
//! WAV can only hold one shape. A prohibited DWL is reported, not guessed.
//!
//! The model has no audio clock (no AUDIO_CLK and no CKDV divide), so the
//! rate is a flag with a 48 kHz default rather than something derived.
//! Container width follows DWL: 8 and 16 bits go out as 16-bit, 18 to 24 as
//! 24-bit, 32 as 32-bit. A narrower word is shifted up so full scale stays
//! full scale, and 8-bit WAV (which is unsigned) never comes up.
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const ssie = @import("ra8_chip").periph.ssie;
const wav = @import("ra8_render").wav;
const world_flags = @import("world_flags.zig");

pub const default_rate: u32 = 48_000;

pub const Options = struct {
    path: ?[]const u8 = null,
    rate: u32 = default_rate,
};

/// Whether the argument at `index` was one of these flags; true walks
/// `index` past its value.
pub fn parse(options: *Options, argv: []const []const u8, index: *usize) !bool {
    const flag = argv[index.*];
    if (std.mem.eql(u8, flag, "--audio-out")) {
        options.path = try world_flags.next(argv, index);
    } else if (std.mem.eql(u8, flag, "--audio-rate")) {
        options.rate = try std.fmt.parseInt(u32, try world_flags.next(argv, index), 10);
        if (options.rate == 0) return error.BadAudioRate;
    } else return false;
    return true;
}

/// Why recording stopped before the run did.
pub const Stop = enum {
    none,
    prohibited_dwl,
    shape_changed,
    bad_format,
    out_of_memory,

    fn said(self: Stop) []const u8 {
        return switch (self) {
            .none => "",
            .prohibited_dwl => "SSICR.DWL is the prohibited 111b",
            .shape_changed => "SSICR changed DWL, FRM or PDTA mid-stream",
            .bad_format => "the stream's format cannot be a WAV",
            .out_of_memory => "out of memory",
        };
    }
};

/// The WAV container width for `data_bits` significant bits.
pub fn container(data_bits: u6) u16 {
    if (data_bits <= 16) return 16;
    if (data_bits <= 24) return 24;
    return 32;
}

/// One sample's significant bits, moved up to fill its container.
pub fn widen(shape: ssie.tap.Shape, word: u32) u32 {
    const shift: u5 = @intCast(container(shape.data_bits) - shape.data_bits);
    return shape.value(word) << shift;
}

pub const Run = struct {
    options: Options = .{},
    allocator: std.mem.Allocator = std.heap.page_allocator,
    board: ?*Board = null,
    shape: ?ssie.tap.Shape = null,
    recorder: ?wav.Recorder = null,
    stop: Stop = .none,

    /// Start listening on SSIE0 when a path was asked for. `self` must stay
    /// put until `deinit`, because the listener points at it.
    pub fn arm(self: *Run, board: *Board, options: Options) void {
        self.options = options;
        if (options.path == null) return;
        self.board = board;
        board.audio.channels[0].listener = .{ .context = self, .sample = hear };
    }

    pub fn deinit(self: *Run) void {
        if (self.board) |board| board.audio.channels[0].listener = null;
        if (self.recorder) |*recorder| recorder.deinit(self.allocator);
        self.board = null;
        self.recorder = null;
    }

    fn hear(context: *anyopaque, word: u32) void {
        const self: *Run = @ptrCast(@alignCast(context));
        self.take(word);
    }

    fn take(self: *Run, word: u32) void {
        if (self.stop != .none) return;
        const board = self.board.?;
        const now = ssie.tap.shape(board.audio.channels[0].ssicr) orelse return self.halt(.prohibited_dwl);
        if (self.shape) |was| {
            if (!std.meta.eql(was, now)) return self.halt(.shape_changed);
        } else {
            self.recorder = wav.Recorder.init(.{
                .rate = self.options.rate,
                .bits = container(now.data_bits),
                .channels = now.channels,
            }) catch return self.halt(.bad_format);
            self.shape = now;
        }
        const at = board.time.base.now();
        self.recorder.?.push(self.allocator, at, widen(now, word)) catch return self.halt(.out_of_memory);
    }

    fn halt(self: *Run, why: Stop) void {
        self.stop = why;
    }

    /// Write the WAV and say what went into it. A run where SSIE0 sent
    /// nothing writes no file, because a WAV needs a shape and nothing set one.
    pub fn finish(self: *Run, out: anytype, io: std.Io) !void {
        const path = self.options.path orelse return;
        const recorder = if (self.recorder) |*found| found else {
            const why = if (self.stop == .none) "SSIE0 sent no samples" else self.stop.said();
            return out.print("audio-out: {s}; {s} not written\n", .{ why, path });
        };
        writeFile(recorder, io, path) catch |err| {
            return out.print("audio-out: could not write {s}: {s}\n", .{ path, @errorName(err) });
        };
        const f = recorder.format;
        try out.print("audio-out: {d} sample(s), {d} Hz, {d}-bit, {d} channel(s), {d} silent, written to {s}\n", .{
            recorder.samples.items.len, f.rate, f.bits, f.channels, recorder.silent, path,
        });
        if (self.stop != .none) try out.print("audio-out: recording stopped early: {s}\n", .{self.stop.said()});
    }
};

fn writeFile(recorder: *const wav.Recorder, io: std.Io, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var staging: [4096]u8 = undefined;
    var writer = file.writer(io, &staging);
    try recorder.write(&writer.interface);
    try writer.interface.flush();
}
