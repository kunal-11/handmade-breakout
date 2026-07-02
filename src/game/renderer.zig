const util = @import("util.zig");
const math = @import("math.zig");

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

    pub fn render(group: *Group, draw_buffer: *const DrawBuffer) void {
        for (group.items[0..group.item_count]) |item| {
            switch (item) {
                .clear => |clear| drawClear(draw_buffer, clear.color),
                .rectangle => |rect| drawRectangle(draw_buffer, rect.rect, rect.color),
            }
        }
        if (linear_blending_enabled) {
            linearToSrgb(draw_buffer);
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

fn drawClear(draw_buffer: *const DrawBuffer, color: util.Color) void {
    const color_linear = if (linear_blending_enabled) color.srgbToLinear() else color;
    const color_u32 = color_linear.multiplyAlpha().toPackedU32();
    for (0..draw_buffer.height) |y| {
        const row_start: [*]u32 = @ptrCast(@alignCast(draw_buffer.memory + y * draw_buffer.pitch));
        @memset(row_start[0..draw_buffer.width], color_u32);
    }
}

fn drawRectangle(draw_buffer: *const DrawBuffer, rect: math.Rectangle, color: util.Color) void {
    const screen_dims = math.Vec2.init(@floatFromInt(draw_buffer.width), @floatFromInt(draw_buffer.height));

    const min_x_f = @max(0, rect.min.x);
    const min_y_f = @max(0, rect.min.y);
    const max_x_f = @min(screen_dims.x, rect.max.x);
    const max_y_f = @min(screen_dims.y, rect.max.y);

    if (min_x_f >= max_x_f or min_y_f >= max_y_f) return;

    const min_x: u32 = @round(min_x_f);
    const min_y: u32 = @round(min_y_f);

    const max_x: u32 = @round(max_x_f);
    const max_y: u32 = @round(max_y_f);

    const color_linear = if (linear_blending_enabled) color.srgbToLinear() else color;
    const color_u32 = color_linear.multiplyAlpha().toPackedU32();
    for (min_y..max_y) |y| {
        const row_start: [*]u32 = @ptrCast(@alignCast(draw_buffer.memory + y * draw_buffer.pitch + min_x * 4));
        const len = max_x - min_x;
        @memset(row_start[0..len], color_u32);
    }
}

const lanes = 4;

const WideF32 = @Vector(lanes, f32);
const WideU8 = @Vector(lanes, u8);

const wide_255_f: WideF32 = @splat(255);
const wide_255: WideU8 = @splat(255);
const wide_1: WideF32 = @splat(1);
const wide_0: WideF32 = @splat(0);

fn linearToSrgb(draw_buffer: *const DrawBuffer) void {
    for (0..draw_buffer.height) |y| {
        var x: u32 = 0;
        while (x + lanes <= draw_buffer.width) : (x += lanes) {
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
        while (x < draw_buffer.width) : (x += 1) {
            const pixel_ptr = draw_buffer.memory + y * draw_buffer.pitch + x * 4;
            inline for (0..3) |i| {
                const c_255: f32 = @floatFromInt(pixel_ptr[i]);
                const c_srgb = math.clamp(@sqrt(c_255 / 255), 0, 1);
                pixel_ptr[i] = @round(c_srgb * 255);
            }
        }
    }
}
