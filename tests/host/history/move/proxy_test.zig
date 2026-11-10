const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");
const move = ra8.host.history.move;
const Proxy = move.proxy.Proxy;
const Stage = move.proxy.Stage;
const io = std.testing.io;
const linux = std.os.linux;

fn spawn(argv: []const []const u8) !std.process.Child {
    return std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
}

fn start(argv: []const []const u8) !Proxy {
    return Proxy.own(io, try spawn(argv), 300, null);
}

fn commit() move.wire.Commit {
    return .{ .version = move.wire.version, .nonce = @splat('c'), .operation = @splat('d'), .proof = .{ .anchor = move.wire.digest("a"), .note = move.wire.digest("n") }, .commit = true };
}

fn alive(pid: i32) bool {
    var info: linux.siginfo_t = undefined;
    info.fields.common.first.piduid.pid = 0;
    return linux.errno(linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null)) == .SUCCESS and info.fields.common.first.piduid.pid == 0;
}

/// True once `pid` is no longer this process's child: its owner reaped it.
fn collected(pid: i32) bool {
    var info: linux.siginfo_t = undefined;
    for (0..300) |_| {
        if (linux.errno(linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null)) == .CHILD) return true;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

/// The process state letter from /proc, or null once `pid` is gone.
fn state(pid: i32) ?u8 {
    var path: [32]u8 = undefined;
    var bytes: [512]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(io, std.fmt.bufPrint(&path, "/proc/{d}/stat", .{pid}) catch return null, &bytes) catch return null;
    const end = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    return if (end + 2 < text.len) text[end + 2] else null;
}

fn becomes(pid: i32, letter: u8) bool {
    for (0..300) |_| {
        if (state(pid) == letter) return true;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

test "the running child's executable digest is a capability, not a path claim" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.Io.Dir.cwd().copyFile("/bin/cat", tmp.dir, "cat", io, .{});
    const cat = try tmp.dir.realPathFileAlloc(io, "cat", std.testing.allocator);
    defer std.testing.allocator.free(cat);
    var child = try start(&.{cat});
    try child.fits();
    const expected = try move.provider.digest(io, cat);
    try child.verifyExecutable(cat, expected);
    var wrong: [32]u8 = expected;
    wrong[0] ^= 0xff;
    try std.testing.expectError(error.PeerDigestMismatch, child.verifyExecutable(cat, wrong));
    try std.testing.expect(child.reap().?.success());
    child.close();
}

test "a child that ends with its input is reaped inside the bound unsignalled" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var child = try start(&.{"/bin/cat"});
    try child.fits();
    try std.testing.expect(child.reap().?.success());
    child.close();
    try std.testing.expectEqual(Stage.reaped, child.stage);
    try std.testing.expectEqual(@as(linux.fd_t, -1), child.handle);
}

test "before COMMIT a child that outlives the bound is killed inside it and leaves no zombie" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var child = try start(&.{ "/bin/sleep", "600" });
    const pid = child.child.id.?;
    const begun = std.Io.Timestamp.now(io, .awake);
    child.close();
    // Half the reap phase, then the kill and the rest of it to reap.
    try std.testing.expect(begun.untilNow(io, .awake).toMilliseconds() < 1000);
    try std.testing.expectEqual(Stage.reaped, child.stage);
    try std.testing.expect(collected(pid));
}

test "a child that ends while the one reap bound still runs is reaped by the caller" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var child = try Proxy.own(io, try spawn(&.{ "/bin/sleep", "0.1" }), 2_000, null);
    child.close();
    try std.testing.expectEqual(Stage.reaped, child.stage);
}

test "before COMMIT a stopped child is killed through its handle and leaves no zombie" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var child = try start(&.{ "/bin/sleep", "600" });
    const pid = child.child.id.?;
    // The fixture is this test's own unreaped child.
    _ = linux.kill(pid, .STOP);
    try std.testing.expect(becomes(pid, 'T'));
    child.close();
    try std.testing.expectEqual(Stage.reaped, child.stage);
    try std.testing.expect(collected(pid));
}

test "after COMMIT a child that outlives the bound is left running, never killed, and reaped once it ends" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var child = try start(&.{ "/bin/sleep", "600" });
    const pid = child.child.id.?;
    try child.commit(std.testing.allocator, commit());
    const begun = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectEqual(@as(?std.process.Child.Term, null), child.reap());
    child.close();
    try std.testing.expect(begun.untilNow(io, .awake).toMilliseconds() < 3000);
    try std.testing.expectEqual(Stage.abandoned, child.stage);
    try std.testing.expectEqual(@as(?std.process.Child.Id, null), child.child.id);
    try std.testing.expectEqual(@as(linux.fd_t, -1), child.handle);
    std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    try std.testing.expect(alive(pid));
    // The fixture is this test's own child; its collector, not the test, reaps it.
    _ = linux.kill(pid, .KILL);
    try std.testing.expect(collected(pid));
}

test "after COMMIT a stopped child is continued and reaped inside the bound without a kill" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var child = try start(&.{"/bin/cat"});
    const pid = child.child.id.?;
    // The fixture is this test's own unreaped child.
    _ = linux.kill(pid, .STOP);
    try std.testing.expect(becomes(pid, 'T'));
    try child.commit(std.testing.allocator, commit());
    try std.testing.expectEqual(@as(?u8, 'T'), state(pid));
    // Continued, cat reads the end of its input and exits by itself.
    child.close();
    try std.testing.expectEqual(Stage.reaped, child.stage);
    try std.testing.expect(collected(pid));
}

test "after COMMIT a child stopped through the whole reap bound is continued by its collector" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var child = try start(&.{"/bin/cat"});
    const pid = child.child.id.?;
    // The fixture is this test's own unreaped child.
    _ = linux.kill(pid, .STOP);
    try std.testing.expect(becomes(pid, 'T'));
    try child.commit(std.testing.allocator, commit());
    try std.testing.expectEqual(@as(?std.process.Child.Term, null), child.reap());
    try std.testing.expectEqual(@as(?u8, 'T'), state(pid));
    // The bound is spent: close continues it and hands it over unkilled.
    child.close();
    try std.testing.expectEqual(Stage.abandoned, child.stage);
    try std.testing.expect(collected(pid));
}

test "an abandoned child stopped later is continued by its collector and never killed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var child = try start(&.{ "/bin/sleep", "600" });
    const pid = child.child.id.?;
    try child.commit(std.testing.allocator, commit());
    child.close();
    try std.testing.expectEqual(Stage.abandoned, child.stage);
    // The fixture is this test's own child.
    _ = linux.kill(pid, .STOP);
    try std.testing.expect(becomes(pid, 'S'));
    _ = linux.kill(pid, .KILL);
    try std.testing.expect(collected(pid));
}

test "an exhausted admission leaves no reap time and still leaves no zombie" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const spent: move.deadline.Admission = .begin(io, 0);
    var killed = try Proxy.own(io, try spawn(&.{ "/bin/sleep", "600" }), 2_000, spent);
    const killed_pid = killed.child.id.?;
    const begun = std.Io.Timestamp.now(io, .awake);
    killed.close();
    try std.testing.expect(begun.untilNow(io, .awake).toMilliseconds() < 1000);
    try std.testing.expectEqual(Stage.abandoned, killed.stage);
    try std.testing.expect(collected(killed_pid));
    var committed = try Proxy.own(io, try spawn(&.{ "/bin/sleep", "600" }), 2_000, spent);
    const committed_pid = committed.child.id.?;
    try committed.commit(std.testing.allocator, commit());
    committed.close();
    try std.testing.expectEqual(Stage.abandoned, committed.stage);
    std.Io.sleep(io, .fromMilliseconds(200), .awake) catch {};
    try std.testing.expect(alive(committed_pid));
    _ = linux.kill(committed_pid, .KILL);
    try std.testing.expect(collected(committed_pid));
}

test "closing a proxy signals only its own child, never a bystander" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var bystander = try spawn(&.{ "/bin/sleep", "600" });
    const other = bystander.id.?;
    var child = try start(&.{ "/bin/sleep", "600" });
    const pid = child.child.id.?;
    child.close();
    try std.testing.expect(collected(pid));
    try std.testing.expect(alive(other));
    // The bystander is this test's own unreaped child.
    _ = linux.kill(other, .KILL);
    _ = try bystander.wait(io);
}

fn failedWait(userdata: ?*anyopaque, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    // Exercise the real wait cleanup, then inject its documented error.
    _ = try io.vtable.childWait(userdata, child);
    return error.Canceled;
}

test "failed wait drops child ownership before close or another reap" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var child = try start(&.{"/bin/true"});
    defer child.close();
    var vtable = io.vtable.*;
    vtable.childWait = failedWait;
    child.io.vtable = &vtable;
    try std.testing.expectEqual(@as(?std.process.Child.Term, null), child.reap());
    try std.testing.expectEqual(@as(?std.process.Child.Id, null), child.child.id);
    child.close();
    try std.testing.expectEqual(Stage.abandoned, child.stage);
    try std.testing.expectEqual(@as(?std.process.Child.Term, null), child.reap());
    try std.testing.expect(child.child.stdin == null and child.child.stdout == null);
}

test "insufficient request pipe capacity is rejected before use" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var child = try start(&.{"/bin/cat"});
    defer child.close();
    const size = linux.fcntl(child.child.stdin.?.handle, linux.F.SETPIPE_SZ, 4096);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(size));
    try std.testing.expectError(error.PipeTooSmall, child.fits());
    try std.testing.expectEqual(Stage.open, child.stage);
}

test "a caller whose children the kernel reaps by itself is refused" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try move.proxy.reapable();
    var saved: linux.Sigaction = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.sigaction(.CHLD, null, &saved)));
    defer _ = linux.sigaction(.CHLD, &saved, null);
    var ignored = saved;
    ignored.handler.handler = linux.SIG.IGN;
    _ = linux.sigaction(.CHLD, &ignored, null);
    try std.testing.expectError(error.ChildReapingDisabled, move.proxy.reapable());
    var unwaited = saved;
    unwaited.flags |= linux.SA.NOCLDWAIT;
    _ = linux.sigaction(.CHLD, &unwaited, null);
    try std.testing.expectError(error.ChildReapingDisabled, move.proxy.reapable());
    _ = linux.sigaction(.CHLD, &saved, null);
    try move.proxy.reapable();
}
