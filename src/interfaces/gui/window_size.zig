//! How big the window is and how its pixels map to the shell (RA8EMU-966).
//! The shell lays out in points: the drawable's pixels divided by a whole
//! UI scale, so a Retina screen draws every glyph, line and gutter at two
//! pixels per point and the bitmap font stays sharp instead of blurring.
//! Pure arithmetic, so the host tests cover it without SDL.
const std = @import("std");
const Size = @import("platform.zig").Size;

/// The smallest window, in points: every pane of the two-core layout
/// keeps its minimum size with room for titles and the status rows.
pub const min: Size = .{ .width = 800, .height = 500 };

/// The share of the screen's usable area a new window opens at.
const opening_share = 0.8;

/// The window size for a screen whose usable area is `usable` points:
/// most of it, never under `min`, never over the screen itself.
pub fn initial(usable: Size) Size {
    return .{ .width = opening(usable.width, min.width), .height = opening(usable.height, min.height) };
}

fn opening(screen: u32, floor: u32) u32 {
    if (screen == 0) return floor;
    const share: u32 = @intFromFloat(@as(f32, @floatFromInt(screen)) * opening_share);
    return @min(screen, @max(share, floor));
}

/// The whole UI scale for a display scale: 1.0 and 1.25 stay at one pixel
/// per point, 1.5 to 2.49 draw at two, and so on. Nonsense reads as one.
pub fn uiScale(display: f32) u32 {
    if (!(display > 0) or std.math.isInf(display)) return 1;
    return @max(1, @as(u32, @intFromFloat(@round(@min(display, 8.0)))));
}

/// The layout size for `pixels` drawn at `scale` pixels per point.
pub fn points(pixels: Size, scale: u32) Size {
    const k = @max(scale, 1);
    return .{ .width = pixels.width / k, .height = pixels.height / k };
}
