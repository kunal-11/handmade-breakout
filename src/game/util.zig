pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub const red = init(1, 0, 0, 1);
    pub const blue = init(0, 0, 1, 1);
    pub const green = init(0, 1, 0, 1);
    pub const black = init(0, 0, 0, 1);

    pub inline fn init(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub inline fn multiplyAlpha(color: Color) Color {
        return .{
            .r = color.r * color.a,
            .g = color.g * color.a,
            .b = color.b * color.a,
            .a = color.a,
        };
    }

    pub inline fn toPackedU32(color: Color) u32 {
        return @bitCast([4]u8{
            @round(color.r * 255),
            @round(color.g * 255),
            @round(color.b * 255),
            @round(color.a * 255),
        });
    }

    pub inline fn srgbToLinear(color: Color) Color {
        return .{
            .r = color.r * color.r,
            .g = color.g * color.g,
            .b = color.b * color.b,
            .a = color.a,
        };
    }

    pub inline fn vector(color: Color) @Vector(4, f32) {
        return .{ color.r, color.g, color.b, color.a };
    }
};

pub inline fn assert(check: bool, msg: []const u8) void {
    if (!check) @panic(msg);
}

// std lib stuff
const std = @import("std");

pub const Atomic = std.atomic.Value;
