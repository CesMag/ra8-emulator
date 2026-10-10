const std = @import("std");
const ra8 = @import("ra8");
const select = ra8.chip.core.cpu.fpu.select;

test "the cc field values match the encoding" {
    try std.testing.expectEqual(@as(u2, 0b00), @backingInt(select.Cond.eq));
    try std.testing.expectEqual(@as(u2, 0b01), @backingInt(select.Cond.vs));
    try std.testing.expectEqual(@as(u2, 0b10), @backingInt(select.Cond.ge));
    try std.testing.expectEqual(@as(u2, 0b11), @backingInt(select.Cond.gt));
}

test "C never changes the outcome" {
    inline for (.{ select.Cond.eq, select.Cond.vs, select.Cond.ge, select.Cond.gt }) |cond| {
        var nzcv: u4 = 0;
        while (true) : (nzcv += 1) {
            try std.testing.expectEqual(select.passed(cond, nzcv), select.passed(cond, nzcv ^ 0b0010));
            if (nzcv == 15) break;
        }
    }
}

test "GT is GE without Z" {
    var nzcv: u4 = 0;
    while (true) : (nzcv += 1) {
        const z = nzcv & 0b0100 != 0;
        try std.testing.expectEqual(select.passed(.ge, nzcv) and !z, select.passed(.gt, nzcv));
        if (nzcv == 15) break;
    }
}
