//! How long a run lasts in modelled time.
const std = @import("std");
const ra8 = @import("ra8");

const deadline = ra8.chip.core.deadline;

test "a deadline is not met before its periods have gone by" {
    var due = deadline.Deadline{ .periods = 4000 };
    try std.testing.expect(!due.met(0));
    try std.testing.expect(!due.met(3999));
    try std.testing.expect(!due.reached);
}

test "a deadline is met on the period it asked for" {
    var due = deadline.Deadline{ .periods = 4000 };
    try std.testing.expect(due.met(4000));
    try std.testing.expect(due.reached);
}

test "passing the deadline between two boundaries still meets it" {
    var due = deadline.Deadline{ .periods = 10 };
    try std.testing.expect(due.met(97));
    try std.testing.expect(due.reached);
}

test "a zero deadline is met by the first boundary" {
    var due = deadline.Deadline{ .periods = 0 };
    try std.testing.expect(due.met(0));
    try std.testing.expect(due.reached);
}

test "an unmet deadline leaves reached alone for the report" {
    var due = deadline.Deadline{ .periods = 2 };
    _ = due.met(1);
    try std.testing.expect(!due.reached);
    _ = due.met(2);
    try std.testing.expect(due.reached);
}
