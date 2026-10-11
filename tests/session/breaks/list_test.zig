//! `info breakpoints` in gdb's layout.
const std = @import("std");
const ra8 = @import("ra8");
const break_list = ra8.session.breaks.list;
const break_table = ra8.session.breaks.table;
const watch_table = ra8.session.watch.table;

fn listed(view: break_list.View) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer text.deinit();
    try break_list.write(&text.writer, view);
    return text.toOwnedSlice();
}

test "nothing set says so the way gdb does" {
    const breaks = break_table.Table{};
    const watches = watch_table.Table{};
    const text = try listed(.{ .breaks = &breaks, .watches = &watches });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(break_list.empty, text);
}

test "breaks list with disposition, enable and hit count in gdb's columns" {
    var breaks = break_table.Table{};
    const watches = watch_table.Table{};
    _ = try breaks.add(.{ .address = 0x100 });
    const second = try breaks.add(.{ .address = 0x2200_001c, .seen = 1 });
    _ = try breaks.add(.{ .address = 0x200, .arrival = 4, .seen = 1 });
    try breaks.setEnabled(1, false);
    const text = try listed(.{ .breaks = &breaks, .watches = &watches, .temporary = &.{second} });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(break_list.header ++
        "1       breakpoint      keep n   0x00000100 \n" ++
        "2       breakpoint      del  y   0x2200001c \n" ++
        "\tbreakpoint already hit 1 time\n" ++
        "3       breakpoint      keep y   0x00000200 \n" ++
        "\tbreakpoint already hit 1 time\n" ++
        "\tWill ignore next 2 crossings of breakpoint.\n", text);
}

test "watches list by kind with a blank address column" {
    const breaks = break_table.Table{};
    var watches = watch_table.Table{};
    _ = try watches.add(try watch_table.Watch.span(0x2000_0000, 4, .write));
    _ = try watches.add(try watch_table.Watch.span(0x2000_0004, 4, .read));
    var hit = try watch_table.Watch.span(0x2000_0008, 4, .access);
    hit.seen = 2;
    _ = try watches.add(hit);
    const text = try listed(.{ .breaks = &breaks, .watches = &watches });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(break_list.header ++
        "1       hw watchpoint   keep y              *(int*)0x20000000\n" ++
        "2       read watchpoint keep y              *(int*)0x20000004\n" ++
        "3       acc watchpoint  keep y              *(int*)0x20000008\n" ++
        "\tbreakpoint already hit 2 times\n", text);
}

test "breaks and watches interleave by number, breaks first on a tie" {
    var breaks = break_table.Table{};
    var watches = watch_table.Table{};
    _ = try breaks.add(.{ .address = 0x100 });
    _ = try watches.add(try watch_table.Watch.span(0x2000_0000, 4, .write));
    _ = try watches.add(try watch_table.Watch.span(0x2000_0004, 4, .write));
    const text = try listed(.{ .breaks = &breaks, .watches = &watches });
    defer std.testing.allocator.free(text);
    const first_break = std.mem.indexOf(u8, text, "1       breakpoint").?;
    const first_watch = std.mem.indexOf(u8, text, "1       hw watchpoint").?;
    const second_watch = std.mem.indexOf(u8, text, "2       hw watchpoint").?;
    try std.testing.expect(first_break < first_watch and first_watch < second_watch);
}
