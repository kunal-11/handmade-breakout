const util = @import("util.zig");
const mem = @import("mem.zig");
const math = @import("math.zig");

const assets = @import("assets.zig");

const api = @import("game_api");

const linear_blending_enabled = true;

const Item = union(enum) {
    clear: struct {
        color: util.Color,
    },
    rectangle: struct {
        rect: math.Rectangle,
        texture: ?*assets.LoadedBitmap,
        tint: util.Color,
    },
};

pub const Group = struct {
    items: [2048]Item = undefined,
    item_count: u32 = 0,

    asset_store: *assets.Store,

    camera_scale: math.Vec2,
    camera_translate: math.Vec2,

    pub fn init(arena: *mem.Arena, asset_store: *assets.Store, world_dim: math.Vec2, screen_dim: math.Vec2) *Group {
        const group = arena.pushStruct(Group);
        const camera_scale = @min(screen_dim.x / world_dim.x, screen_dim.y / world_dim.y);
        group.* = .{
            .asset_store = asset_store,
            .camera_scale = .init(camera_scale, -camera_scale),
            .camera_translate = screen_dim.scale(0.5),
        };
        return group;
    }

    fn transformPoint(group: *Group, world_p: math.Vec2) math.Vec2 {
        return world_p.hadamard(group.camera_scale).add(group.camera_translate);
    }

    fn transformRect(group: *Group, world_rect: math.Rectangle) math.Rectangle {
        const screen_min = group.transformPoint(world_rect.min);
        const screen_max = group.transformPoint(world_rect.max);
        return .init(.init(screen_min.x, screen_max.y), .init(screen_max.x, screen_min.y));
    }

    pub fn addClear(group: *Group, color: util.Color) void {
        group.addItem(.{ .clear = .{ .color = color } });
    }

    pub fn addRectangle(group: *Group, rect: math.Rectangle, color: util.Color) void {
        group.addItem(.{ .rectangle = .{
            .rect = group.transformRect(rect),
            .tint = color,
            .texture = null,
        } });
    }

    pub fn addBitmap(group: *Group, rect: math.Rectangle, bitmap_id: assets.Id, tint: util.Color) void {
        if (group.asset_store.getBitmap(bitmap_id)) |bitmap| {
            group.addItem(.{ .rectangle = .{
                .rect = group.transformRect(rect),
                .tint = tint,
                .texture = bitmap,
            } });
        } else group.asset_store.loadBitmap(bitmap_id);
    }

    fn addItem(group: *Group, item: Item) void {
        util.assert(group.item_count < group.items.len, "render group OOM");
        group.items[group.item_count] = item;
        group.item_count += 1;
    }

    const tile_height = 64;
    const tile_width = 64;
    pub fn render(group: *Group, trans_arena: *mem.Arena, draw_buffer: *const DrawBuffer, work_queue: *api.WorkQueue) void {
        const flusher = mem.Flusher.init(trans_arena);
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
                .rectangle => |rect| {
                    if (rect.texture) |texture| {
                        drawRectangle(tile.draw_buffer, tile.clip_rect, rect.rect, rect.tint, true, texture);
                    } else {
                        drawRectangle(tile.draw_buffer, tile.clip_rect, rect.rect, rect.tint, false, {});
                    }
                },
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

fn drawRectangle(
    draw_buffer: *const DrawBuffer,
    clip_rect: math.Rectangle,
    rect: math.Rectangle,
    tint: util.Color,
    comptime has_texture: bool,
    texture: if (has_texture) *assets.LoadedBitmap else void,
) void {
    const min_f = @max(clip_rect.min.vector(), rect.min.vector());
    const max_f = @min(clip_rect.max.vector(), rect.max.vector());

    if (@reduce(.Or, min_f >= max_f)) return;

    const min: @Vector(2, u32) = @round(min_f);
    const max: @Vector(2, u32) = @round(max_f);

    const color_linear = if (linear_blending_enabled) tint.srgbToLinear() else tint;
    const tint_f = color_linear.multiplyAlpha().vector();

    const px_to_tx = if (has_texture) blk: {
        const texture_dim = math.Vec2.init(@floatFromInt(texture.width), @floatFromInt(texture.height));
        const rect_dim = rect.getDim();
        break :blk math.Vec2.init((texture_dim.x - 2) / rect_dim.x, (texture_dim.y - 2) / rect_dim.y);
    };

    for (min[1]..max[1]) |y| {
        const y_f: f32 = @floatFromInt(y);
        var x: u32 = min[0];
        while (x + lanes <= max[0]) : (x += lanes) {
            const pixel_ptr = draw_buffer.memory + y * draw_buffer.pitch + x * 4;

            // sample texture
            var sample: [4]WideF32 = undefined;
            if (has_texture) {
                const x_f: f32 = @floatFromInt(x);

                const px = x_f + 0.5 - rect.min.x;
                const py = y_f + 0.5 - rect.min.y;

                const wide_px = @as(WideF32, @splat(px)) + wide_iota;
                const wide_py: WideF32 = @splat(py);

                const wide_tx = wide_px * @as(WideF32, @splat(px_to_tx.x)) + wide_half;
                const wide_ty = wide_py * @as(WideF32, @splat(px_to_tx.y)) + wide_half;

                const sample_x: WideU32 = @floor(wide_tx);
                const sample_y: WideU32 = @floor(wide_ty);

                const frac_x = wide_tx - @floor(wide_tx);
                const frac_y = wide_ty - @floor(wide_ty);

                var sample00_u32: WideU32 = undefined;
                var sample10_u32: WideU32 = undefined;
                var sample01_u32: WideU32 = undefined;
                var sample11_u32: WideU32 = undefined;
                inline for (0..lanes) |lane| {
                    sample00_u32[lane] = @bitCast((texture.memory + sample_y[lane] * texture.pitch + sample_x[lane] * 4)[0..4].*);
                    sample01_u32[lane] = @bitCast((texture.memory + sample_y[lane] * texture.pitch + (sample_x[lane] + 1) * 4)[0..4].*);
                    sample10_u32[lane] = @bitCast((texture.memory + (sample_y[lane] + 1) * texture.pitch + sample_x[lane] * 4)[0..4].*);
                    sample11_u32[lane] = @bitCast((texture.memory + (sample_y[lane] + 1) * texture.pitch + (sample_x[lane] + 1) * 4)[0..4].*);
                }

                inline for (0..4) |c| {
                    const color_shift: WideU32 = @splat(c * 8);

                    var sample00: WideF32 = @floatFromInt((sample00_u32 >> color_shift) & wide_255_u32);
                    var sample01: WideF32 = @floatFromInt((sample01_u32 >> color_shift) & wide_255_u32);
                    var sample10: WideF32 = @floatFromInt((sample10_u32 >> color_shift) & wide_255_u32);
                    var sample11: WideF32 = @floatFromInt((sample11_u32 >> color_shift) & wide_255_u32);

                    sample00 *= wide_1_255;
                    sample01 *= wide_1_255;
                    sample10 *= wide_1_255;
                    sample11 *= wide_1_255;

                    const sample0 = sample01 * frac_x + sample00 * (wide_1 - frac_x);
                    const sample1 = sample11 * frac_x + sample10 * (wide_1 - frac_x);
                    sample[c] = sample1 * frac_y + sample0 * (wide_1 - frac_y);
                }
            } else {
                sample = @splat(wide_1);
            }
            inline for (0..4) |c| {
                sample[c] *= @splat(tint_f[c]);
            }

            var result_pixel: WideU32 = @splat(0);

            const src_pixel: WideU32 = @bitCast(pixel_ptr[0 .. lanes * 4].*);
            inline for (0..4) |c| {
                const color_shift: WideU32 = @splat(c * 8);

                var color_f: WideF32 = @floatFromInt((src_pixel >> color_shift) & wide_255_u32);
                color_f *= wide_1_255;

                // blend
                color_f = sample[c] + color_f * (wide_1 - sample[3]);

                // write blended color
                color_f = math.clamp(color_f, wide_0, wide_1) * wide_255_f;
                const color_u32: WideU32 = @round(color_f);

                result_pixel |= color_u32 << color_shift;
            }

            pixel_ptr[0 .. lanes * 4].* = @bitCast(result_pixel);
        }

        while (x < max[0]) : (x += 1) {
            const pixel_ptr = draw_buffer.memory + y * draw_buffer.pitch + x * 4;

            // sample texture
            var sample: [4]f32 = undefined;
            if (has_texture) {
                const x_f: f32 = @floatFromInt(x);

                const px = x_f + 0.5 - rect.min.x;
                const py = y_f + 0.5 - rect.min.y;

                const tx = px * px_to_tx.x + 0.5;
                const ty = py * px_to_tx.y + 0.5;

                const sample_x: u32 = @floor(tx);
                const sample_y: u32 = @floor(ty);

                const frac_x = tx - @floor(tx);
                const frac_y = ty - @floor(ty);

                const sample00_u32: u32 = @bitCast((texture.memory + sample_y * texture.pitch + sample_x * 4)[0..4].*);
                const sample01_u32: u32 = @bitCast((texture.memory + sample_y * texture.pitch + (sample_x + 1) * 4)[0..4].*);
                const sample10_u32: u32 = @bitCast((texture.memory + (sample_y + 1) * texture.pitch + sample_x * 4)[0..4].*);
                const sample11_u32: u32 = @bitCast((texture.memory + (sample_y + 1) * texture.pitch + (sample_x + 1) * 4)[0..4].*);
                inline for (0..4) |c| {
                    const color_shift: u32 = c * 8;

                    var sample00: f32 = @floatFromInt((sample00_u32 >> color_shift) & 255);
                    var sample01: f32 = @floatFromInt((sample01_u32 >> color_shift) & 255);
                    var sample10: f32 = @floatFromInt((sample10_u32 >> color_shift) & 255);
                    var sample11: f32 = @floatFromInt((sample11_u32 >> color_shift) & 255);

                    sample00 *= scalar_1_255;
                    sample01 *= scalar_1_255;
                    sample10 *= scalar_1_255;
                    sample11 *= scalar_1_255;

                    const sample0 = sample01 * frac_x + sample00 * (1 - frac_x);
                    const sample1 = sample11 * frac_x + sample10 * (1 - frac_x);
                    sample[c] = sample1 * frac_y + sample0 * (1 - frac_y);
                }
            } else {
                sample = @splat(1);
            }
            inline for (0..4) |c| {
                sample[c] *= tint_f[c];
            }

            var result_pixel: u32 = 0;
            const src_pixel: u32 = @bitCast(pixel_ptr[0..4].*);
            inline for (0..4) |c| {
                const color_shift: u32 = c * 8;

                var color_f: f32 = @floatFromInt((src_pixel >> color_shift) & 255);
                color_f *= scalar_1_255;

                // blend
                color_f = sample[c] + color_f * (1 - sample[3]);

                // write blended color
                color_f = math.clamp(color_f, 0, 1) * 255;
                const color_u32: u32 = @round(color_f);
                result_pixel |= color_u32 << color_shift;
            }
            pixel_ptr[0..4].* = @bitCast(result_pixel);
        }
    }
}

const lanes = 4;

const WideF32 = @Vector(lanes, f32);
const WideU32 = @Vector(lanes, u32);

const wide_iota: WideF32 = .{ 0, 1, 2, 3 };

const scalar_1_255 = 1.0 / 255.0;
const wide_1_255: WideF32 = @splat(scalar_1_255);

const wide_255_u32: WideU32 = @splat(255);
const wide_255_f: WideF32 = @splat(255);

const wide_1: WideF32 = @splat(1);
const wide_0: WideF32 = @splat(0);
const wide_half: WideF32 = @splat(0.5);

fn linearToSrgb(draw_buffer: *const DrawBuffer, clip_rect: math.Rectangle) void {
    const min: @Vector(2, u32) = @round(clip_rect.min.vector());
    const max: @Vector(2, u32) = @round(clip_rect.max.vector());

    for (min[1]..max[1]) |y| {
        var x: u32 = min[0];
        while (x + lanes <= max[0]) : (x += lanes) {
            const pixel_ptr = draw_buffer.memory + y * draw_buffer.pitch + x * 4;

            const src_pixel: WideU32 = @bitCast(pixel_ptr[0 .. lanes * 4].*);
            var result_pixel: WideU32 = src_pixel & (wide_255_u32 << @splat(24));
            inline for (0..3) |c| {
                const color_shift: WideU32 = @splat(c * 8);

                var color: WideF32 = @floatFromInt((src_pixel >> color_shift) & wide_255_u32);
                color *= wide_1_255;

                color = math.clamp(color, wide_0, wide_1);
                color = math.clamp(@sqrt(color), wide_0, wide_1);

                const color_u32: WideU32 = @round(color * wide_255_f);
                result_pixel |= color_u32 << color_shift;
            }
            pixel_ptr[0 .. lanes * 4].* = @bitCast(result_pixel);
        }
        while (x < max[0]) : (x += 1) {
            const pixel_ptr = draw_buffer.memory + y * draw_buffer.pitch + x * 4;

            const src_pixel: u32 = @bitCast(pixel_ptr[0..4].*);
            var result_pixel: u32 = src_pixel & (255 << 24);
            inline for (0..3) |c| {
                const color_shift: u32 = c * 8;

                var color: f32 = @floatFromInt((src_pixel >> color_shift) & 255);
                color *= scalar_1_255;

                color = math.clamp(color, 0, 1);
                color = math.clamp(@sqrt(color), 0, 1);

                const color_u32: u32 = @round(color * 255);
                result_pixel |= color_u32 << color_shift;
            }
            pixel_ptr[0..4].* = @bitCast(result_pixel);
        }
    }
}
