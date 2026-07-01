pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub const zero = Vec2.init(0, 0);

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn scale(v: Vec2, val: f32) Vec2 {
        return .init(v.x * val, v.y * val);
    }

    pub fn add(v1: Vec2, v2: Vec2) Vec2 {
        return .init(v1.x + v2.x, v1.y + v2.y);
    }

    pub fn subtract(v1: Vec2, v2: Vec2) Vec2 {
        return .init(v1.x - v2.x, v1.y - v2.y);
    }

    pub fn hadamard(v1: Vec2, v2: Vec2) Vec2 {
        return .init(v1.x * v2.x, v1.y * v2.y);
    }

    pub fn dot(v1: Vec2, v2: Vec2) f32 {
        return v1.x * v2.x + v1.y * v2.y;
    }

    pub fn lenSq(v: Vec2) f32 {
        return v.dot(v);
    }

    pub fn transpose(v: Vec2) Vec2 {
        return .init(v.y, v.x);
    }
};

pub const Rectangle = struct {
    min: Vec2,
    max: Vec2,

    pub fn init(min: Vec2, max: Vec2) Rectangle {
        return .{ .min = min, .max = max };
    }

    pub fn initCenterDim(center: Vec2, dim: Vec2) Rectangle {
        const half_dim = dim.scale(0.5);
        return .{ .min = center.subtract(half_dim), .max = center.add(half_dim) };
    }

    pub fn getDim(rect: Rectangle) Vec2 {
        return rect.max.subtract(rect.min);
    }
};

pub fn clamp(val: f32, low: f32, high: f32) f32 {
    return @min(@max(val, low), high);
}
