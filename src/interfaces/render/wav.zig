//! The SSIE's transmit stream as a PCM WAV (RA8EMU-647, for `--audio-out`,
//! RA8EMU-570).
//!
//! A Recorder takes each sample the SSIE shifts out together with the virtual
//! time it left, and lays it in the slot that time names: elapsed time times
//! rate times channels, counted from the first sample. Slots the stream
//! skipped because the FIFO ran dry are written as silence, padded to a whole
//! frame, so the file runs as long as the run did and an underrun can be heard
//! where it happened. A sample that turns up early for its slot goes where the
//! stream already is. The FIFO drained faster than the frame clock, and the
//! model does not pace it, so moving the sample later would invent timing.
//!
//! Each sample is one SSIFTDR word, and the WAV keeps its low `bits` bits,
//! little-endian. Whether the word is left- or right-justified depends on the
//! SSIE configuration, so the tap that feeds this (RA8EMU-648) shifts the word
//! before it gets here.
const std = @import("std");

const ns_per_s: u128 = std.time.ns_per_s;
const header_len: u32 = 44;

/// What the stream is: frames per second, bits per sample, interleaved
/// channels. 8-bit WAV is unsigned while SSIE samples are signed, so it is
/// refused rather than converted.
pub const Format = struct {
    rate: u32,
    bits: u16,
    channels: u16,

    pub fn valid(self: Format) bool {
        const width = self.bits == 16 or self.bits == 24 or self.bits == 32;
        return width and self.rate != 0 and self.channels != 0;
    }

    pub fn bytesPerSample(self: Format) u16 {
        return self.bits / 8;
    }

    pub fn blockAlign(self: Format) u16 {
        return self.bytesPerSample() * self.channels;
    }
};

pub const Error = error{ BadFormat, TooLong } || std.mem.Allocator.Error;

pub const Recorder = struct {
    format: Format,
    samples: std.ArrayListUnmanaged(u32) = .empty,
    /// Virtual time of the first sample. Slot 0 belongs to it.
    start_ns: ?u64 = null,
    /// Silent samples written where the stream underran.
    silent: u64 = 0,

    pub fn init(format: Format) Error!Recorder {
        if (!format.valid()) return error.BadFormat;
        return .{ .format = format };
    }

    pub fn deinit(self: *Recorder, allocator: std.mem.Allocator) void {
        self.samples.deinit(allocator);
        self.* = undefined;
    }

    /// One sample shifted out at `now_ns` (virtual).
    pub fn push(self: *Recorder, allocator: std.mem.Allocator, now_ns: u64, sample: u32) Error!void {
        const start = self.start_ns orelse now_ns;
        self.start_ns = start;
        const due = self.slot(now_ns -| start);
        const frame_start = due - due % self.format.channels;
        while (self.samples.items.len < frame_start) {
            try self.samples.append(allocator, 0);
            self.silent += 1;
        }
        try self.samples.append(allocator, sample);
    }

    /// The sample index `elapsed_ns` names, counting every channel.
    fn slot(self: *const Recorder, elapsed_ns: u64) u64 {
        const per_s = @as(u128, self.format.rate) * self.format.channels;
        return @intCast(@as(u128, elapsed_ns) * per_s / ns_per_s);
    }

    /// Bytes of sample data the WAV will carry, whole frames only.
    pub fn dataLen(self: *const Recorder) Error!u32 {
        const frames = self.samples.items.len / self.format.channels;
        const bytes = @as(u64, frames) * self.format.blockAlign();
        if (bytes > std.math.maxInt(u32) - header_len) return error.TooLong;
        return @intCast(bytes);
    }

    /// The whole file: RIFF header, then every complete frame. A trailing
    /// partial frame (the run stopped between channels) is left out, because
    /// a WAV cannot hold half a frame.
    pub fn write(self: *const Recorder, writer: anytype) !void {
        const f = self.format;
        const data = try self.dataLen();
        try writer.writeAll("RIFF");
        try writer.writeInt(u32, header_len - 8 + data, .little);
        try writer.writeAll("WAVEfmt ");
        try writer.writeInt(u32, 16, .little);
        try writer.writeInt(u16, 1, .little);
        try writer.writeInt(u16, f.channels, .little);
        try writer.writeInt(u32, f.rate, .little);
        try writer.writeInt(u32, f.rate * f.blockAlign(), .little);
        try writer.writeInt(u16, f.blockAlign(), .little);
        try writer.writeInt(u16, f.bits, .little);
        try writer.writeAll("data");
        try writer.writeInt(u32, data, .little);
        const count = data / f.bytesPerSample();
        for (self.samples.items[0..count]) |sample| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, sample, .little);
            try writer.writeAll(bytes[0..f.bytesPerSample()]);
        }
    }
};
