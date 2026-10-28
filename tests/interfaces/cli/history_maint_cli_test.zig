//! Covers src/interfaces/cli/history_maint_cli.zig and the rpc history_maint
//! it drives, on a kept disk history a served session recorded: thin drops
//! checkpoints (and their objects) and keeps the log readable, reroot
//! refuses without confirmation and otherwise drops what precedes the new
//! root, and the history command line parses both.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const maint = cli_app.history_maint_cli;
const history_cli = cli_app.history_cli;
const history = ra8.host.history;
const seek_facts = ra8.session.history_seek_facts;

const short_image = "tests/fixtures/dfu/dfu_bootloader.elf";
const long_image = "tests/fixtures/gpio/blink.elf";

/// Records a kept session with many checkpoints and returns its root.
/// `per_run` caps each run's slots when given, so a busy image reaches
/// its checkpoints without running the default budget every time.
fn record(gpa: std.mem.Allocator, root: []const u8, image: []const u8, runs: usize, per_run: ?u64) !void {
    var served: ra8.rpc.served_setup.Served = undefined;
    try served.open(gpa, std.testing.io, image, null, .{ .root = root, .checkpoint_every = 1, .kept = true });
    defer served.deinit();
    const session = served.owner.session();
    if (per_run) |cap| try session.setRunBudget(.cpu0, cap);
    _ = try session.run(.cpu0, .run);
    for (1..runs) |_| _ = try session.run(.cpu0, .cont);
}

/// Slots per run for the long recording: above the reverse window's live
/// recording limit, and enough that each run passes a checkpoint.
const long_run_slots: u64 = 40_000;

const Session = struct {
    base: history.base.Base,
    name: [64]u8 = undefined,
    len: usize = 0,

    fn find(gpa: std.mem.Allocator, root: []const u8) !Session {
        var found: Session = .{ .base = try history.base.Base.existing(gpa, std.testing.io, root, .cache) };
        errdefer found.base.close();
        var entries = try history.catalog.Iterator.init(&found.base);
        while (try entries.next()) |entry| {
            if (entry.kind != .session) continue;
            @memcpy(found.name[0..entry.name.len], entry.name);
            found.len = entry.name.len;
            return found;
        }
        return error.NoSession;
    }

    fn checkpoints(self: *Session, gpa: std.mem.Allocator) !usize {
        var dir = try self.base.dir.openDir(self.base.io, self.name[0..self.len], .{ .iterate = true, .follow_symlinks = false });
        defer dir.close(self.base.io);
        var opened = try maint.Open.open(&self.base, self.name[0..self.len], true);
        defer opened.close();
        const bytes = try ra8.rpc.history_segments.readAll(gpa, opened.store());
        defer gpa.free(bytes);
        const facts = try seek_facts.gather(gpa, bytes);
        defer gpa.free(facts.checkpoints);
        return facts.checkpoints.len;
    }
};

test "reroot refuses without confirmation and otherwise drops the history before the new root" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    try record(gpa, root, short_image, 1, null);
    var session = try Session.find(gpa, root);
    defer session.base.close();
    const before = try session.checkpoints(gpa);
    try std.testing.expect(before >= 4);

    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    const name = session.name[0..session.len];
    try std.testing.expectError(error.NotConfirmed, maint.reroot(gpa, &session.base, name, true, 2, false, &sink.writer));
    try std.testing.expectEqual(before, try session.checkpoints(gpa));

    try std.testing.expectEqual(@as(u8, 0), try maint.reroot(gpa, &session.base, name, true, 2, true, &sink.writer));
    try std.testing.expectEqual(before - 2, try session.checkpoints(gpa));
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "re-rooted at checkpoint 2") != null);
}

test "thin drops checkpoints far from the newest and keeps the survivors' gap" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    try record(gpa, root, long_image, 65, long_run_slots);
    var session = try Session.find(gpa, root);
    defer session.base.close();
    const before = try session.checkpoints(gpa);
    try std.testing.expect(before > 40);

    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    const name = session.name[0..session.len];
    try std.testing.expectEqual(@as(u8, 0), try maint.thin(gpa, &session.base, name, true, 8, &sink.writer));
    const after = try session.checkpoints(gpa);
    try std.testing.expect(after < before);
    try std.testing.expect(after >= 3);
}

test "the history command line parses thin and reroot" {
    const thin = try history_cli.parse(&.{ "ra8_emulator", "history", "--root", "r", "thin", "--gap", "16", "s" });
    try std.testing.expectEqual(history_cli.Op.thin, thin.op);
    try std.testing.expectEqual(@as(u64, 16), thin.gap);
    const re = try history_cli.parse(&.{ "ra8_emulator", "history", "--root", "r", "reroot", "--confirm", "s", "7" });
    try std.testing.expectEqual(history_cli.Op.reroot, re.op);
    try std.testing.expect(re.confirm);
    try std.testing.expectEqual(@as(u32, 7), re.checkpoint);
    try std.testing.expectError(error.Usage, history_cli.parse(&.{ "ra8_emulator", "history", "--root", "r", "thin", "--gap", "0", "s" }));
    try std.testing.expectError(error.Usage, history_cli.parse(&.{ "ra8_emulator", "history", "--root", "r", "reroot", "s" }));
}
