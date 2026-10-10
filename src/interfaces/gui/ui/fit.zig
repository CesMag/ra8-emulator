//! Aspect-kept placement for an image inside a body rect (RA8EMU-1081):
//! pure layout, shared by the board pane, the board touch mapping and the
//! shell's board leaf.
const draw_list = @import("ra8_render").draw_list;

/// The largest area with the image's aspect that fits `body`, centred in it.
pub fn fitIn(body: draw_list.Rect, width: u32, height: u32) draw_list.Rect {
    if (body.empty() or width == 0 or height == 0) return .{ .x = body.x, .y = body.y, .w = 0, .h = 0 };
    const bw: u64 = @intCast(body.w);
    const bh: u64 = @intCast(body.h);
    const by_width = bw * height <= bh * width;
    const w: i32 = @intCast(if (by_width) bw else bh * width / height);
    const h: i32 = @intCast(if (by_width) bw * height / width else bh);
    return .{ .x = body.x + @divTrunc(body.w - w, 2), .y = body.y + @divTrunc(body.h - h, 2), .w = w, .h = h };
}
