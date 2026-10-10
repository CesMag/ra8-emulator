//! Draws a geometry.Batch through SDL's renderer (RA8EMU-733,
//! ADR 0001 in the knowledge base, RA8EMU-A-8 step 4). The glyph atlas is one RGBA texture
//! with the coverage in alpha. Each image gets its own texture, keyed by
//! pixel pointer and size, refilled once per frame and dropped once a frame
//! no longer draws it. Every run sets its clip rect and then draws its
//! indices, blending straight alpha source-over as raster.zig does.
const std = @import("std");
const render = @import("ra8_render");
const c = @import("sdl_c.zig").c;

const geometry = render.geometry;
const draw_list = render.draw_list;
const raster = render.raster;

pub const Error = error{ SdlTexture, SdlDraw, OutOfMemory };

comptime {
    std.debug.assert(@sizeOf(geometry.Vertex) == @sizeOf(c.SDL_Vertex));
    std.debug.assert(@sizeOf(u32) == @sizeOf(c_int));
}

const Key = struct { ptr: usize, width: u32, height: u32 };
const Entry = struct { texture: *c.SDL_Texture, frame: u64 };

pub const Textures = struct {
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    atlas: ?*c.SDL_Texture = null,
    images: std.AutoHashMapUnmanaged(Key, Entry) = .{},
    frame: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, renderer: *c.SDL_Renderer) Textures {
        return .{ .allocator = allocator, .renderer = renderer };
    }

    pub fn deinit(self: *Textures) void {
        if (self.atlas) |texture| c.SDL_DestroyTexture(texture);
        var it = self.images.valueIterator();
        while (it.next()) |entry| c.SDL_DestroyTexture(entry.texture);
        self.images.deinit(self.allocator);
    }

    /// Upload the glyph atlas once: white texels whose alpha is coverage.
    pub fn setAtlas(self: *Textures, atlas: raster.Atlas) Error!void {
        const texels = try self.allocator.alloc(draw_list.Color, atlas.coverage.len);
        defer self.allocator.free(texels);
        for (texels, atlas.coverage) |*texel, coverage| {
            texel.* = .{ .r = 255, .g = 255, .b = 255, .a = coverage };
        }
        const texture = try create(self.renderer, atlas.width, atlas.height);
        errdefer c.SDL_DestroyTexture(texture);
        try upload(texture, texels, atlas.width);
        if (self.atlas) |old| c.SDL_DestroyTexture(old);
        self.atlas = texture;
    }

    /// Drop the image textures the last frame did not draw, then count
    /// a new frame, so each image is refilled on its next draw.
    pub fn beginFrame(self: *Textures) Error!void {
        var stale: std.ArrayListUnmanaged(Key) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.images.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.frame != self.frame) try stale.append(self.allocator, kv.key_ptr.*);
        }
        for (stale.items) |key| {
            if (self.images.fetchRemove(key)) |kv| c.SDL_DestroyTexture(kv.value.texture);
        }
        self.frame += 1;
    }

    /// The texture for `source`, filled with its pixels once this frame.
    fn image(self: *Textures, source: draw_list.Image) Error!*c.SDL_Texture {
        const key = Key{ .ptr = @intFromPtr(source.pixels.ptr), .width = source.width, .height = source.height };
        const slot = try self.images.getOrPut(self.allocator, key);
        if (!slot.found_existing) {
            const texture = create(self.renderer, source.width, source.height) catch |err| {
                self.images.removeByPtr(slot.key_ptr);
                return err;
            };
            slot.value_ptr.* = .{ .texture = texture, .frame = self.frame -% 1 };
        }
        if (slot.value_ptr.frame != self.frame) {
            try upload(slot.value_ptr.texture, source.pixels, source.width);
            slot.value_ptr.frame = self.frame;
        }
        return slot.value_ptr.texture;
    }
};

/// One window's geometry path: the batch rebuilt each frame and the
/// textures it draws with.
pub const Presenter = struct {
    renderer: *c.SDL_Renderer,
    batch: geometry.Batch,
    textures: Textures,
    atlas_coverage: ?[*]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, renderer: *c.SDL_Renderer) Presenter {
        return .{
            .renderer = renderer,
            .batch = geometry.Batch.init(allocator),
            .textures = Textures.init(allocator, renderer),
        };
    }

    pub fn deinit(self: *Presenter) void {
        self.textures.deinit();
        self.batch.deinit();
    }

    /// Clear to opaque black and draw `list`; the caller presents. The
    /// atlas uploads again only when its coverage moves.
    pub fn frame(self: *Presenter, list: *const draw_list.DrawList, atlas: ?raster.Atlas) Error!void {
        if (atlas) |cells| {
            if (self.atlas_coverage != cells.coverage.ptr) {
                try self.textures.setAtlas(cells);
                self.atlas_coverage = cells.coverage.ptr;
            }
        }
        try self.batch.build(list, atlas);
        try self.textures.beginFrame();
        _ = c.SDL_SetRenderDrawColor(self.renderer, 0, 0, 0, 255);
        if (!c.SDL_RenderClear(self.renderer)) return fail(Error.SdlDraw);
        try draw(self.renderer, &self.textures, &self.batch);
    }
};

/// Draw every run of `batch` in order, then clear the clip rect. Glyph
/// runs draw nothing until an atlas is set, as raster.draw without one.
pub fn draw(renderer: *c.SDL_Renderer, textures: *Textures, batch: *const geometry.Batch) Error!void {
    if (!c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND)) return fail(Error.SdlDraw);
    defer _ = c.SDL_SetRenderClipRect(renderer, null);
    const vertices: [*]const c.SDL_Vertex = @ptrCast(batch.vertices.items.ptr);
    const indices: [*]const c_int = @ptrCast(batch.indices.items.ptr);
    const vertex_count: c_int = @intCast(batch.vertices.items.len);
    for (batch.runs.items) |run| {
        const texture: ?*c.SDL_Texture = switch (run.texture) {
            .none => null,
            .atlas => textures.atlas orelse continue,
            .image => |source| try textures.image(source),
        };
        const clip = c.SDL_Rect{ .x = run.clip.x, .y = run.clip.y, .w = run.clip.w, .h = run.clip.h };
        if (!c.SDL_SetRenderClipRect(renderer, &clip)) return fail(Error.SdlDraw);
        const first = indices + run.first;
        if (!c.SDL_RenderGeometry(renderer, texture, vertices, vertex_count, first, @intCast(run.count))) {
            return fail(Error.SdlDraw);
        }
    }
}

/// A static RGBA32 texture sampled nearest and blended source-over.
fn create(renderer: *c.SDL_Renderer, width: u32, height: u32) Error!*c.SDL_Texture {
    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_RGBA32,
        c.SDL_TEXTUREACCESS_STATIC,
        @intCast(width),
        @intCast(height),
    ) orelse return fail(Error.SdlTexture);
    _ = c.SDL_SetTextureScaleMode(texture, c.SDL_SCALEMODE_NEAREST);
    _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);
    return texture;
}

fn upload(texture: *c.SDL_Texture, pixels: []const draw_list.Color, width: u32) Error!void {
    if (!c.SDL_UpdateTexture(texture, null, pixels.ptr, @intCast(width * 4))) return fail(Error.SdlTexture);
}

fn fail(err: Error) Error {
    std.log.err("{s}: {s}", .{ @errorName(err), c.SDL_GetError() });
    return err;
}
