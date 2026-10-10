const std = @import("std");
const ra8 = @import("ra8");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const geometry = ra8.render.geometry;
const Color = draw_list.Color;
const Rect = draw_list.Rect;

const red = Color.rgb(255, 0, 0);
const blue = Color.rgb(0, 0, 255);
const coverage = @as([8 * 4]u8, @splat(0xff));
const atlas = raster.Atlas{ .width = 8, .height = 4, .coverage = &coverage };
const pixels = @as([4]Color, @splat(red));
const picture = draw_list.Image{ .width = 2, .height = 2, .pixels = &pixels };
const other_pixels = @as([4]Color, @splat(blue));
const other_picture = draw_list.Image{ .width = 2, .height = 2, .pixels = &other_pixels };

fn build(list: *const draw_list.DrawList, cells: ?raster.Atlas) !geometry.Batch {
    var batch = geometry.Batch.init(std.testing.allocator);
    errdefer batch.deinit();
    try batch.build(list, cells);
    return batch;
}

test "a fill is two triangles over its clipped area in one untextured run" {
    var list = draw_list.DrawList.init(std.testing.allocator, 10, 10);
    defer list.deinit();
    try list.fill(.{ .x = 6, .y = 2, .w = 8, .h = 3 }, red);
    var batch = try build(&list, null);
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 4), batch.vertices.items.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 2, 1, 3 }, batch.indices.items);
    try std.testing.expectEqual(@as(usize, 1), batch.runs.items.len);
    try std.testing.expect(batch.runs.items[0].texture == .none);
    const last = batch.vertices.items[3];
    try std.testing.expectEqual(@as(f32, 10), last.x);
    try std.testing.expectEqual(@as(f32, 5), last.y);
    try std.testing.expectEqual(@as(f32, 1), last.r);
    try std.testing.expectEqual(@as(f32, 0), last.b);
}

/// Every pixel the batch's quads cover, as a grid.
fn covered(batch: *const geometry.Batch, comptime size: usize) [size][size]bool {
    var grid: [size][size]bool = @splat(@splat(false));
    var index: usize = 0;
    while (index < batch.vertices.items.len) : (index += 4) {
        const top_left = batch.vertices.items[index];
        const bottom_right = batch.vertices.items[index + 3];
        var y: usize = @intFromFloat(top_left.y);
        while (y < @as(usize, @intFromFloat(bottom_right.y))) : (y += 1) {
            var x: usize = @intFromFloat(top_left.x);
            while (x < @as(usize, @intFromFloat(bottom_right.x))) : (x += 1) grid[y][x] = true;
        }
    }
    return grid;
}

test "line spans cover exactly the pixels raster.zig draws, clip included" {
    const size = 16;
    const lines = [_][4]i32{ .{ 0, 0, 15, 0 }, .{ 1, 1, 14, 6 }, .{ 2, 15, 5, 0 }, .{ 15, 3, 0, 12 } };
    for (lines) |ends| {
        var list = draw_list.DrawList.init(std.testing.allocator, size, size);
        defer list.deinit();
        try list.pushClip(.{ .x = 2, .y = 0, .w = 10, .h = 14 });
        try list.line(ends[0], ends[1], ends[2], ends[3], red);
        var frame = try raster.Framebuffer.init(std.testing.allocator, size, size);
        defer frame.deinit(std.testing.allocator);
        raster.draw(&frame, &list, null);
        var batch = try build(&list, null);
        defer batch.deinit();
        const grid = covered(&batch, size);
        for (0..size) |y| for (0..size) |x| {
            const drawn = frame.at(@intCast(x), @intCast(y)).a != 0;
            try std.testing.expectEqual(drawn, grid[y][x]);
        };
    }
}

test "a horizontal line is one quad and a diagonal one quad per row" {
    var list = draw_list.DrawList.init(std.testing.allocator, 10, 10);
    defer list.deinit();
    try list.line(1, 2, 8, 2, red);
    try list.line(0, 4, 3, 7, red);
    var batch = try build(&list, null);
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 5 * 4), batch.vertices.items.len);
    try std.testing.expectEqual(@as(f32, 9), batch.vertices.items[3].x);
}

test "a glyph samples its atlas cell with edges on texel edges" {
    var list = draw_list.DrawList.init(std.testing.allocator, 20, 20);
    defer list.deinit();
    try list.glyph(.{ .x = 3, .y = 5, .w = 4, .h = 2 }, 4, 2, blue);
    var batch = try build(&list, atlas);
    defer batch.deinit();
    try std.testing.expect(batch.runs.items[0].texture == .atlas);
    const first = batch.vertices.items[0];
    const last = batch.vertices.items[3];
    try std.testing.expectEqual(@as(f32, 0.5), first.u);
    try std.testing.expectEqual(@as(f32, 0.5), first.v);
    try std.testing.expectEqual(@as(f32, 1), last.u);
    try std.testing.expectEqual(@as(f32, 1), last.v);
}

test "a clipped glyph keeps the matching part of its cell" {
    var list = draw_list.DrawList.init(std.testing.allocator, 20, 20);
    defer list.deinit();
    try list.pushClip(.{ .x = 5, .y = 0, .w = 20, .h = 20 });
    try list.glyph(.{ .x = 3, .y = 0, .w = 4, .h = 4 }, 0, 0, blue);
    var batch = try build(&list, atlas);
    defer batch.deinit();
    try std.testing.expectEqual(@as(f32, 5), batch.vertices.items[0].x);
    try std.testing.expectEqual(@as(f32, 2.0 / 8.0), batch.vertices.items[0].u);
}

test "glyphs without an atlas draw nothing, as in raster.zig" {
    var list = draw_list.DrawList.init(std.testing.allocator, 20, 20);
    defer list.deinit();
    try list.glyph(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, 0, 0, blue);
    var batch = try build(&list, null);
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 0), batch.runs.items.len);
    try std.testing.expectEqual(@as(usize, 0), batch.indices.items.len);
}

test "an image is a white quad on its own texture, scaled whole" {
    var list = draw_list.DrawList.init(std.testing.allocator, 20, 20);
    defer list.deinit();
    try list.image(.{ .x = 2, .y = 2, .w = 8, .h = 8 }, picture);
    var batch = try build(&list, null);
    defer batch.deinit();
    const run = batch.runs.items[0];
    try std.testing.expect(run.texture.eql(.{ .image = picture }));
    try std.testing.expectEqual(@as(f32, 1), batch.vertices.items[0].g);
    try std.testing.expectEqual(@as(f32, 0), batch.vertices.items[0].u);
    try std.testing.expectEqual(@as(f32, 1), batch.vertices.items[3].v);
}

test "runs break when the texture or the clip changes" {
    var list = draw_list.DrawList.init(std.testing.allocator, 20, 20);
    defer list.deinit();
    try list.fill(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, red);
    try list.line(0, 5, 9, 5, red);
    try list.pushClip(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    try list.fill(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, red);
    list.popClip();
    try list.image(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, picture);
    try list.image(.{ .x = 4, .y = 0, .w = 4, .h = 4 }, picture);
    try list.image(.{ .x = 8, .y = 0, .w = 4, .h = 4 }, other_picture);
    try list.glyph(.{ .x = 0, .y = 8, .w = 4, .h = 4 }, 0, 0, blue);
    var batch = try build(&list, atlas);
    defer batch.deinit();
    const runs = batch.runs.items;
    try std.testing.expectEqual(@as(usize, 5), runs.len);
    try std.testing.expectEqual(@as(u32, 12), runs[0].count);
    try std.testing.expectEqual(@as(i32, 10), runs[1].clip.w);
    try std.testing.expectEqual(@as(u32, 12), runs[2].count);
    try std.testing.expect(runs[3].texture.eql(.{ .image = other_picture }));
    try std.testing.expect(runs[4].texture == .atlas);
    var next: u32 = 0;
    for (runs) |run| {
        try std.testing.expectEqual(next, run.first);
        next += run.count;
    }
    try std.testing.expectEqual(@as(usize, next), batch.indices.items.len);
}

test "commands whose clip misses the surface are dropped" {
    var list = draw_list.DrawList.init(std.testing.allocator, 10, 10);
    defer list.deinit();
    const outside = Rect{ .x = 20, .y = 20, .w = 5, .h = 5 };
    try list.commands.append(std.testing.allocator, .{ .shape = .{ .fill = .{ .area = outside, .color = red } }, .clip = outside });
    var batch = try build(&list, null);
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 0), batch.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 0), batch.runs.items.len);
}

test "build starts each frame over" {
    var list = draw_list.DrawList.init(std.testing.allocator, 10, 10);
    defer list.deinit();
    try list.fill(.{ .x = 0, .y = 0, .w = 4, .h = 4 }, red);
    var batch = try build(&list, null);
    defer batch.deinit();
    try batch.build(&list, null);
    try std.testing.expectEqual(@as(usize, 4), batch.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 1), batch.runs.items.len);
}
