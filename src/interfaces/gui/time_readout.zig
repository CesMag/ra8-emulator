//! The time bar's clock readout (RA8EMU-806): the session's virtual elapsed
//! time and the achieved speed, shown only when it falls short of the speed
//! asked for. A model, no paint: poll() asks, observe() takes the answers,
//! text() reads the line. The board's RTC date leads the line when the
//! session has one (RA8EMU-809); a server without the rtc method refuses it
//! once and is not asked again.
const std = @import("std");
const proto = @import("../rpc/session_rpc.zig");
const session_link = @import("session_link.zig");
const speed_field = @import("speed_field.zig");
const session_rtc = @import("ra8_session").session_rtc;
const Link = session_link.Link;
const Arrival = session_link.Arrival;

/// How far short of the request the achieved speed must be to show, in
/// percent: pacing jitters by a little, and a readout that flickers on every
/// refresh says nothing.
pub const short_percent: u64 = 95;

pub const Sample = struct { wall_ns: u64, virtual_ns: u64 };

/// The speed achieved between two samples in thousandths, or null when the
/// wall clock did not move or virtual time went backwards (a restore).
pub fn achieved(from: Sample, to: Sample) ?u64 {
    if (to.wall_ns <= from.wall_ns or to.virtual_ns < from.virtual_ns) return null;
    const virtual: u128 = to.virtual_ns - from.virtual_ns;
    return @intCast(@min(virtual * 1000 / (to.wall_ns - from.wall_ns), std.math.maxInt(u64)));
}

/// Short of the request: never for `max`, which asks for no particular speed.
pub fn short(achieved_milli: u64, requested_milli: u64) bool {
    if (requested_milli == speed_field.max_wire) return false;
    return @as(u128, achieved_milli) * 100 < @as(u128, requested_milli) * short_percent;
}

pub const Readout = struct {
    core: proto.Core = .cpu0,
    virtual_ns: ?u64 = null,
    last: ?Sample = null,
    achieved_milli: ?u64 = null,
    now_id: ?u32 = null,
    /// The RTC date at the last answer; null when the counters hold none.
    date: ?session_rtc.Calendar = null,
    rtc_id: ?u32 = null,
    /// The server refused rtc: it has no clock, so stop asking.
    no_rtc: bool = false,

    /// Ask for the virtual time and the RTC date, unless still waiting.
    pub fn poll(self: *Readout, link: *Link) !void {
        if (self.now_id == null) self.now_id = try link.send(proto.Now, .now, .{ .core = self.core });
        if (self.rtc_id == null and !self.no_rtc) self.rtc_id = try link.send(proto.CoreOnly, .rtc, .{ .core = self.core });
    }

    /// Still waiting on an answer to the last poll.
    pub fn waiting(self: *const Readout) bool {
        return self.now_id != null or self.rtc_id != null;
    }

    /// Take one answer; `wall_ns` is the host's monotonic clock as it arrived.
    pub fn observe(self: *Readout, arrival: Arrival, wall_ns: u64) void {
        const response = switch (arrival) {
            .response => |response| response,
            .event => return,
        };
        if (self.rtc_id != null and response.id == self.rtc_id.?) return self.observeRtc(response.result);
        if (response.id != self.now_id) return;
        self.now_id = null;
        if (response.result == .err) return;
        const time = proto.decode(proto.U64, response.result.ok) catch return;
        const sample: Sample = .{ .wall_ns = wall_ns, .virtual_ns = time.value };
        if (self.last) |last| self.achieved_milli = achieved(last, sample) orelse self.achieved_milli;
        self.last = sample;
        self.virtual_ns = time.value;
    }

    fn observeRtc(self: *Readout, result: proto.Client.Env.Result) void {
        self.rtc_id = null;
        const bytes = switch (result) {
            .ok => |bytes| bytes,
            .err => {
                self.no_rtc = true;
                self.date = null;
                return;
            },
        };
        const report = proto.decode(proto.RtcReport, bytes) catch return;
        self.date = if (report.valid == 0) null else .{
            .year = report.year,
            .month = report.month,
            .day = report.day,
            .hour = report.hour,
            .minute = report.minute,
            .second = report.second,
        };
    }

    /// "yyyy-mm-dd hh:mm:ss | " when the RTC holds a date, "T+h:mm:ss.mmm", then "| 0.42x of 1x" when short of the request.
    pub fn text(self: *const Readout, requested_milli: u64, buf: []u8) ![]const u8 {
        var stream: std.Io.Writer = .fixed(buf);
        const w = &stream;
        if (self.date) |date| {
            var date_buf: [19]u8 = undefined;
            try w.print("{s} | ", .{date.format(&date_buf)});
        }
        if (self.virtual_ns) |ns| {
            const ms = ns / std.time.ns_per_ms;
            try w.print("T+{d}:{d:0>2}:{d:0>2}.{d:0>3}", .{ ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000 });
        } else try w.writeAll("T+--");
        if (self.achieved_milli) |got| if (short(got, requested_milli)) {
            var got_buf: [24]u8 = undefined;
            var want_buf: [24]u8 = undefined;
            try w.print(" | {s} of {s}", .{ try speed_field.format(got, &got_buf), try speed_field.format(requested_milli, &want_buf) });
        };
        return stream.buffered();
    }
};
