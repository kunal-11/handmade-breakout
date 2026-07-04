const util = @import("util.zig");
const math = @import("math.zig");

const api = @import("game_api");

const linear_blending_enabled = false;

const Item = union(enum) {
    clear: struct {
        color: util.Color,
    },
    rectangle: struct {
        rect: math.Rectangle,
        color: util.Color,
    },
};

pub const Group = struct {
    items: [2048]Item = undefined,
    item_count: u32 = 0,

    screen_dims: math.Vec2,

    // world coordinates: origin at screen center, y is up, screen height = 1 unit
    // screen coordinates: origin at top left, y is down, pixels
    fn worldToScreen(group: *Group, world_p: math.Vec2) math.Vec2 {
        return world_p.hadamard(.init(group.screen_dims.y, -group.screen_dims.y)).add(group.screen_dims.scale(0.5));
    }

    pub fn addClear(group: *Group, color: util.Color) void {
        group.addItem(.{ .clear = .{ .color = color } });
    }

    pub fn addRectangle(group: *Group, rect: math.Rectangle, color: util.Color) void {
        const screen_min = group.worldToScreen(rect.min);
        const screen_max = group.worldToScreen(rect.max);
        const screen_rect = math.Rectangle.init(.init(screen_min.x, screen_max.y), .init(screen_max.x, screen_min.y));
        group.addItem(.{ .rectangle = .{ .rect = screen_rect, .color = color } });
    }

    fn addItem(group: *Group, item: Item) void {
        util.assert(group.item_count < group.items.len, "render group OOM");
        group.items[group.item_count] = item;
        group.item_count += 1;
    }

    const tile_height = 128;
    const tile_width = 128;
    pub fn render(group: *Group, trans_arena: *util.Arena, draw_buffer: *const DrawBuffer, work_queue: *api.WorkQueue) void {
        const flusher = util.Arena.Flusher.init(trans_arena);
        defer flusher.flush();

        const screen_dims = math.Vec2.init(@floatFromInt(draw_buffer.width), @floatFromInt(draw_buffer.height));
        var y: u32 = 0;
        while (y < draw_buffer.height) : (y += tile_height) {
            var x: u32 = 0;
            while (x < draw_buffer.width) : (x += tile_width) {
                const tile_start = math.Vec2.init(@floatFromInt(x), @floatFromInt(y));
                const tile_end = tile_start.add(.init(tile_width, tile_height));
                const tile_end_clipped = math.Vec2.init(@min(screen_dims.x, tile_end.x), @min(screen_dims.y, tile_end.y));

                const tile_data = trans_arena.pushStruct(RenderTile);
                tile_data.* = .{
                    .group = group,
                    .draw_buffer = draw_buffer,
                    .clip_rect = .init(tile_start, tile_end_clipped),
                };
                work_queue.add_entry(work_queue.high_priority_queue, &renderWorker, tile_data);
            }
        }
        work_queue.complete_all_work(work_queue.high_priority_queue);
    }

    const RenderTile = extern struct {
        group: *Group,
        clip_rect: math.Rectangle,
        draw_buffer: *const DrawBuffer,
    };

    fn renderWorker(data: ?*anyopaque) callconv(.c) void {
        const tile: *RenderTile = @ptrCast(@alignCast(data.?));
        for (tile.group.items[0..tile.group.item_count]) |item| {
            switch (item) {
                .clear => |clear| drawClear(tile.draw_buffer, tile.clip_rect, clear.color),
                .rectangle => |rect| drawRectangle(tile.draw_buffer, tile.clip_rect, rect.rect, rect.color),
            }
        }
        if (linear_blending_enabled) {
            linearToSrgb(tile.draw_buffer, tile.clip_rect);
        }
    }
};

/// origin is top left corner, 4 bytes per pixel - RGBA
/// all rendering in linear premul-alpha, converted to srgb at the end
pub const DrawBuffer = struct {
    height: u32,
    width: u32,
    pitch: u32,
    memory: [*]u8,
};

fn drawClear(draw_buffer: *const DrawBuffer, clip_rect: math.Rectangle, color: util.Color) void {
    const color_linear = if (linear_blending_enabled) color.srgbToLinear() else color;
    const color_u32 = color_linear.multiplyAlpha().toPackedU32();

    const min: @Vector(2, u32) = @round(clip_rect.min.vector());
    const max: @Vector(2, u32) = @round(clip_rect.max.vector());

    for (min[1]..max[1]) |y| {
        const row_start: [*]u32 = @ptrCast(@alignCast(draw_buffer.memory + y * draw_buffer.pitch));
        @memset(row_start[min[0]..max[0]], color_u32);
    }
}

fn drawRectangle(draw_buffer: *const DrawBuffer, clip_rect: math.Rectangle, rect: math.Rectangle, color: util.Color) void {
    const min_f = @max(clip_rect.min.vector(), rect.min.vector());
    const max_f = @min(clip_rect.max.vector(), rect.max.vector());

    if (@reduce(.Or, min_f >= max_f)) return;

    const min: @Vector(2, u32) = @round(min_f);
    const max: @Vector(2, u32) = @round(max_f);

    const color_linear = if (linear_blending_enabled) color.srgbToLinear() else color;
    const color_u32 = color_linear.multiplyAlpha().toPackedU32();
    for (min[1]..max[1]) |y| {
        const row_start: [*]u32 = @ptrCast(@alignCast(draw_buffer.memory + y * draw_buffer.pitch));
        @memset(row_start[min[0]..max[0]], color_u32);
    }
}

const lanes = 4;

const WideF32 = @Vector(lanes, f32);
const WideU8 = @Vector(lanes, u8);

const wide_255_f: WideF32 = @splat(255);
const wide_255: WideU8 = @splat(255);
const wide_1: WideF32 = @splat(1);
const wide_0: WideF32 = @splat(0);

fn linearToSrgb(draw_buffer: *const DrawBuffer, clip_rect: math.Rectangle) void {
    const min: @Vector(2, u32) = @round(clip_rect.min.vector());
    const max: @Vector(2, u32) = @round(clip_rect.max.vector());

    for (min[1]..max[1]) |y| {
        var x: u32 = min[0];
        while (x + lanes <= max[0]) : (x += lanes) {
            const pixel_ptr = draw_buffer.memory + y * draw_buffer.pitch + x * 4;
            inline for (0..3) |c_i| {
                var c_255: WideF32 = undefined;
                inline for (0..lanes) |lane_i| {
                    c_255[lane_i] = @floatFromInt(pixel_ptr[lane_i * 4 + c_i]);
                }

                const c_srgb = @min(wide_1, @max(wide_0, @sqrt(c_255 / wide_255_f)));
                const c_u8: WideU8 = @round(c_srgb * wide_255);

                inline for (0..lanes) |lane_i| {
                    pixel_ptr[lane_i * 4 + c_i] = c_u8[lane_i];
                }
            }
        }
        while (x < max[0]) : (x += 1) {
            const pixel_ptr = draw_buffer.memory + y * draw_buffer.pitch + x * 4;
            inline for (0..3) |i| {
                const c_255: f32 = @floatFromInt(pixel_ptr[i]);
                const c_srgb = math.clamp(@sqrt(c_255 / 255), 0, 1);
                pixel_ptr[i] = @round(c_srgb * 255);
            }
        }
    }
}
